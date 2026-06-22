// ============================================================================
// Blockfall — Renderer (Track E, M1 + M5 Cinematic Lighting)
// Owns the engine + Metal queue. Per frame: read GameView input -> drive the
// engine -> acquire the render frame -> draw each chunk mesh (greedy-meshed
// BFVertex buffers, UMA storageModeShared, referenced by handle) with a
// runtime-compiled stylized shader. Buffers freed by the engine are retired
// for a few frames so the GPU never reads a released buffer (threading.md §2).
//
// M5 lighting additions:
//   • Ambient occlusion from packed vertex bits [3:5]
//   • Sun shadow mapping  (2048²  depth32Float, PCF 3×3)
//   • HDR offscreen scene (rgba16Float + depth32Float)
//   • Bloom (bright-pass → half-res Gaussian blur H + V × 2 iterations)
//   • Composite / tonemap: ACES filmic + colour grade + vignette → drawable
// ============================================================================
import MetalKit
import simd
import CBlockcore
#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - GPU buffer registry (Swift owns MTLBuffers; engine refs by handle)

final class BufferRegistry {
    private var buffers: [UInt64: MTLBuffer] = [:]
    private var retired: [(buf: MTLBuffer, frame: Int)] = []
    private var next: UInt64 = 1
    private let lock = NSLock()
    let device: MTLDevice
    var currentFrame = 0
    init(device: MTLDevice) { self.device = device }

    func make(_ bytes: Int) -> (handle: UInt64, ptr: UnsafeMutableRawPointer)? {
        guard let buf = device.makeBuffer(length: max(bytes, 16), options: .storageModeShared) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let h = next; next += 1
        buffers[h] = buf
        return (h, buf.contents())
    }
    func free(_ handle: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if let b = buffers.removeValue(forKey: handle) { retired.append((b, currentFrame)) }
    }
    func lookup(_ handle: UInt64) -> MTLBuffer? {
        lock.lock(); defer { lock.unlock() }
        return buffers[handle]
    }
    // One-shot copy for the encode window: buffers are only added/freed between
    // frame_end and the next frame_begin, so a per-frame snapshot lets the three
    // render passes resolve handles lock-free (was ~1500 NSLock calls/frame).
    func snapshot() -> [UInt64: MTLBuffer] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }
    // Release buffers retired more than a few frames ago (GPU done with them).
    func collect() {
        lock.lock(); defer { lock.unlock() }
        retired.removeAll { currentFrame - $0.frame > 3 }
    }
}

func allocTrampoline(_ user: UnsafeMutableRawPointer?, _ bytes: UInt32) -> bf_gpu_buffer {
    guard let user = user else { return bf_gpu_buffer() }
    let reg = Unmanaged<BufferRegistry>.fromOpaque(user).takeUnretainedValue()
    guard let made = reg.make(Int(bytes)) else { return bf_gpu_buffer() }
    var out = bf_gpu_buffer(); out.handle = made.handle; out.contents = made.ptr; out.bytes = bytes
    return out
}
func freeTrampoline(_ user: UnsafeMutableRawPointer?, _ handle: UInt64) {
    guard let user = user else { return }
    Unmanaged<BufferRegistry>.fromOpaque(user).takeUnretainedValue().free(handle)
}

// Engine gameplay effects (BF_EVT_SFX, ev.i = effect code) -> Renderer.
func eventTrampoline(_ user: UnsafeMutableRawPointer?, _ ev: UnsafePointer<bf_event>?) {
    guard let user = user, let ev = ev else { return }
    Unmanaged<Renderer>.fromOpaque(user).takeUnretainedValue().handleEvent(ev.pointee)
}

// MARK: - Uniforms (must match the MSL struct byte layout)

/// Terrain pass uniforms (64 bytes).
/// Swift layout: viewProj(64) + chunkOrigin(16) + sunDirTime(16) + lightViewProj(64) + dimSatN(16) = 176 bytes.
struct Uniforms {
    var viewProj:      simd_float4x4           // 64 bytes
    var chunkOrigin:   SIMD4<Float>            // 16 bytes  xyz=origin, w=dim_saturation (min corner)
    var sunDirTime:    SIMD4<Float>            // 16 bytes  xyz=sun_dir, w=time_of_day
    var lightViewProj: simd_float4x4           // 64 bytes  sun light-space VP matrix
    var dimSatN:       SIMD4<Float>            // 16 bytes  x=+X corner, y=+Z, z=+XZ (for grey bilerp)
}

/// Matches the MSL SkyUniforms struct.
struct SkyUniforms {
    var sunDirTime: SIMD4<Float>    // xyz sun dir (pointing FROM sun, i.e. downward), w time-of-day
    var camRight:   SIMD4<Float>    // xyz world-space camera right, w = tanHalfFov
    var camUp:      SIMD4<Float>    // xyz world-space camera up,    w = aspect ratio
    var camFwd:     SIMD4<Float>    // xyz world-space camera forward (into scene), w unused
}

/// Extra per-frame uniforms passed as fragment bytes at index 2 for terrain pass,
/// and as both vertex+fragment bytes for the underwater post pass.
/// 32 bytes — not seen by the engine, set in draw(in:).
struct WaterUniforms {
    var wallClockSecs: Float
    var underwater:    Float
    var pad0:          Float = 0
    var pad1:          Float = 0
    var cameraPosW:    SIMD4<Float> = .zero   // xyz = world-space camera pos, w unused
}

/// Uniforms for the HDR composite / tonemap pass (32 bytes).
struct PostUniforms {
    var bloomStrength:  Float   // fraction of bloom added
    var vignetteStr:    Float   // vignette strength
    var satBoost:       Float   // colour grade saturation multiplier
    var rainStrength:   Float   // 0..1 — drives precipitation overlay
    var wallClockSecs:  Float   // animation time for precipitation
    var pad0:           Float = 0
    var pad1:           Float = 0
    var pad2:           Float = 0
}

/// Wind + weather uniforms passed to terrain vertex shaders (both vmain and shadowVmain).
/// 16 bytes. Keeps foliage sway + rain factor in a dedicated buffer (index 3) so
/// Uniforms / WaterUniforms signatures stay unchanged (runPerfTest safe).
struct WindUniforms {
    var wallClockSecs: Float    //  4 — wall-clock seconds for sway animation
    var rainStrength:  Float    //  4 — 0..1 how hard it's raining (scales sway amp)
    var pad0:          Float = 0
    var pad1:          Float = 0
}

/// Uniforms for the world-space precipitation pass (rain streaks / snow flakes).
/// Swift layout: viewProj(64) + camPosW(16) + params(16) = 96 bytes. Must match MSL PrecipUniforms.
struct PrecipUniforms {
    var viewProj:  simd_float4x4 = .init(diagonal: .one)   // 64 bytes — camera VP
    var camPosW:   SIMD4<Float>  = .zero                   // 16 bytes — xyz world cam pos, w unused
    var wallClock: Float         = 0                       // 4 — animation time (seconds)
    var mode:      Float         = 0                       // 4 — 0=clear, 1=rain, 2=snow
    var boxSize:   Float         = 0                       // 4 — full edge length of spawn volume (world units)
    var pad0:      Float         = 0                       // 4
}

/// Uniforms for the ambient-life sprite pass (birds / fireflies). 32 bytes.
struct AmbientLifeUniforms {
    var viewProj:      simd_float4x4 = .init(diagonal: .one)   // 64 bytes — camera VP
    var camPosW:       SIMD4<Float>  = .zero                   // 16 bytes — world cam pos
    var timeOfDay:     Float         = 0                       // 4 — 0..1 day cycle
    var wallClock:     Float         = 0                       // 4 — animation time
    var pad0:          Float         = 0
    var pad1:          Float         = 0
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let registry: BufferRegistry
    // Scene pipelines (chunk terrain + sky + underwater)
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var skyPipeline: MTLRenderPipelineState!
    private var skyDepthState: MTLDepthStencilState!
    private var underwaterPipeline: MTLRenderPipelineState!
    // Shadow depth-only pipeline
    private var shadowPipeline: MTLRenderPipelineState!
    private var shadowDepthState: MTLDepthStencilState!
    // Post-processing pipelines
    private var bloomBrightPipeline: MTLRenderPipelineState!  // bright-pass (HDR → half-res)
    private var bloomBlurHPipeline: MTLRenderPipelineState!  // horizontal Gaussian
    private var bloomBlurVPipeline: MTLRenderPipelineState!  // vertical Gaussian
    private var compositePipeline: MTLRenderPipelineState!   // ACES + grade + vignette → drawable
    // Ambient life (birds + fireflies) — renderer-owned, no engine data needed
    private var ambientLifePipeline: MTLRenderPipelineState!
    private var ambientLifeDepthState: MTLDepthStencilState!
    private var ambientLifeBuffer: MTLBuffer!   // AmbientSprite array (CPU-updated each frame)
    private let kMaxAmbientSprites = 80
    // World-space precipitation (rain streaks / snow flakes) — renderer-owned,
    // instanced billboards in a volume around the camera. Drives off frame.camera.weather.
    private var precipPipeline: MTLRenderPipelineState!
    private var precipDepthState: MTLDepthStencilState!
    private var precipBuffer: MTLBuffer!           // PrecipParticlePod array (filled once at init)
    private let kPrecipCount = 6000                // #32: doubled (was 3000) — denser rain/snow; recycled in-shader
    private let kPrecipBox: Float = 48.0           // edge length of the spawn cube around the camera
    // Water translucency pass — re-draws chunks with alpha blend, water-only
    private var waterPipeline: MTLRenderPipelineState!
    private var waterDepthState: MTLDepthStencilState!
    // Sub-systems
    private var entityRenderer: EntityRenderer!
    private var particles: ParticleSystem!
    // Engine state
    private var engine: OpaquePointer?
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var frameCounter = 0
    private weak var gameView: GameView?
    weak var hud: HUDView?
    weak var audio: GameAudio?
    private var lastUnderwater = false
    private let saveDir: String
    private let freshWorld: Bool       // true = start a brand-new world (ignore any save)
    private let worldSeed: UInt64

    // ---- HDR offscreen textures (rebuilt on resize) --------------------------
    private var hdrColor: MTLTexture?     // rgba16Float  — scene rendered here
    private var hdrDepth: MTLTexture?     // depth32Float — shared by shadow + scene
    // Bloom intermediates (half scene size)
    private var bloomBright: MTLTexture?  // rgba16Float half-res bright pass
    private var bloomBlurA:  MTLTexture?  // rgba16Float blur ping
    private var bloomBlurB:  MTLTexture?  // rgba16Float blur pong
    private var currentDrawableSize: CGSize = .zero
    // Capped internal render size (the long edge is limited to kRenderLongEdge).
    // The final composite upscales to the full drawable; only the HDR/scene/bloom
    // textures are at this reduced size — saves ~4× fragment cost on Retina.
    // Lowered to 1280 now that MetalFX spatial upscaling recovers quality.
    private let kRenderLongEdge: CGFloat = 1280
    private var sceneSize: CGSize = .zero   // actual HDR texture size (≤ drawable)

    // ---- MetalFX spatial upscaler (optional — macOS 13+, Apple GPU) ---------
    // compositeLowRes: ACES composite writes here at sceneSize (LDR bgra8Unorm).
    // spatialScaler:   upscales compositeLowRes → full drawable texture.
    // If MetalFX is unavailable the composite writes straight to the drawable (bilinear fallback).
    private var compositeLowRes: MTLTexture?
#if canImport(MetalFX)
    @available(macOS 13.0, *)
    private var _spatialScaler: MTLFXSpatialScaler?
#endif
    // True when the scaler was successfully created and can be used this frame.
    private var metalFXEnabled: Bool = false
    // Debug toggles for bisecting the "washout when turning" report (#33). Flipped
    // live from GameView (keys B / N) so the user can identify which subsystem causes
    // it. Defaults: everything on (normal rendering).
    static var dbgBloom = true       // 'B' — bloom on/off
    static var dbgMetalFX = true     // 'N' — MetalFX spatial upscaler on/off

    // ---- Shadow map (fixed 1536×1536) ----------------------------------------
    private let kShadowRes = 1536
    private var shadowMap: MTLTexture!    // depth32Float
    private var shadowSampler: MTLSamplerState!

    // ---- No-write depth state (sky + bloom quads) ----------------------------
    private var noDepthState: MTLDepthStencilState!

    init(view: MTKView, device: MTLDevice, saveDir: String, audio: GameAudio?,
         fresh: Bool = false, seed: UInt64 = 0) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.registry = BufferRegistry(device: device)
        self.gameView = view as? GameView
        self.saveDir = saveDir
        self.freshWorld = fresh
        self.worldSeed = seed
        self.audio = audio
        super.init()
        view.depthStencilPixelFormat = .depth32Float
#if canImport(MetalFX)
        if #available(macOS 13.0, *) {
            // MTLFXSpatialScaler writes to the drawable via a compute kernel that
            // requires MTLTextureUsageShaderWrite. MTKView's default framebufferOnly=true
            // restricts drawable textures to renderTarget-only usage, blocking the
            // compute write. Clearing framebufferOnly allows both. On Apple Silicon
            // UMA there is no meaningful performance cost for doing this.
            if MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                view.framebufferOnly = false
            }
        }
#endif
        buildPipeline(colorFormat: view.colorPixelFormat)
        buildShadowMap()
        entityRenderer = EntityRenderer(device: device, colorFormat: .rgba16Float)
        particles = ParticleSystem(device: device, colorFormat: .rgba16Float)
        createEngine()
    }

    // MARK: Pipeline build

    private func buildPipeline(colorFormat: MTLPixelFormat) {
        let src = Renderer.shaderSource
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: src, options: nil) }
        catch { fatalError("shader compile failed: \(error)") }

        // ---- Terrain pipeline (renders into rgba16Float HDR target) ----------
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        desc.depthAttachmentPixelFormat = .depth32Float
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { fatalError("terrain pipeline failed: \(error)") }

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)

        // ---- Sky pipeline (HDR target, no depth write) -----------------------
        let sdesc = MTLRenderPipelineDescriptor()
        sdesc.vertexFunction   = lib.makeFunction(name: "skyVmain")
        sdesc.fragmentFunction = lib.makeFunction(name: "skyFmain")
        sdesc.colorAttachments[0].pixelFormat = .rgba16Float
        sdesc.depthAttachmentPixelFormat = .depth32Float
        do { skyPipeline = try device.makeRenderPipelineState(descriptor: sdesc) }
        catch { fatalError("sky pipeline failed: \(error)") }

        let sdd = MTLDepthStencilDescriptor()
        sdd.depthCompareFunction = .always
        sdd.isDepthWriteEnabled  = false
        skyDepthState = device.makeDepthStencilState(descriptor: sdd)

        // ---- No-depth state (used by bloom quads too) ------------------------
        let ndd = MTLDepthStencilDescriptor()
        ndd.depthCompareFunction = .always
        ndd.isDepthWriteEnabled  = false
        noDepthState = device.makeDepthStencilState(descriptor: ndd)

        // ---- Underwater post-pass pipeline (HDR target, alpha blend) ---------
        let udesc = MTLRenderPipelineDescriptor()
        udesc.vertexFunction   = lib.makeFunction(name: "underwaterVmain")
        udesc.fragmentFunction = lib.makeFunction(name: "underwaterFmain")
        udesc.colorAttachments[0].pixelFormat = .rgba16Float
        udesc.colorAttachments[0].isBlendingEnabled = true
        udesc.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        udesc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        udesc.colorAttachments[0].sourceAlphaBlendFactor      = .one
        udesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
        udesc.depthAttachmentPixelFormat = .depth32Float
        do { underwaterPipeline = try device.makeRenderPipelineState(descriptor: udesc) }
        catch { fatalError("underwater pipeline failed: \(error)") }

        // ---- Water translucency pipeline (alpha blend, depth test, NO depth write) ----
        // Re-draws chunk meshes; fragment discards any fragment whose material != 9 (water).
        // Depth test lessEqual so water surfaces at the right depth blend over the lake bottom.
        let wdesc = MTLRenderPipelineDescriptor()
        wdesc.vertexFunction   = lib.makeFunction(name: "vmain")
        wdesc.fragmentFunction = lib.makeFunction(name: "waterFmain")
        wdesc.colorAttachments[0].pixelFormat = .rgba16Float
        wdesc.colorAttachments[0].isBlendingEnabled = true
        wdesc.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        wdesc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        wdesc.colorAttachments[0].sourceAlphaBlendFactor      = .one
        wdesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
        wdesc.depthAttachmentPixelFormat = .depth32Float
        do { waterPipeline = try device.makeRenderPipelineState(descriptor: wdesc) }
        catch { fatalError("water pipeline failed: \(error)") }

        let wdd = MTLDepthStencilDescriptor()
        wdd.depthCompareFunction = .lessEqual
        wdd.isDepthWriteEnabled  = false   // don't write depth — lake bottom must stay visible
        waterDepthState = device.makeDepthStencilState(descriptor: wdd)

        // ---- Shadow depth-only pipeline (no colour attachment) ---------------
        let shadDesc = MTLRenderPipelineDescriptor()
        shadDesc.vertexFunction   = lib.makeFunction(name: "shadowVmain")
        shadDesc.fragmentFunction = nil   // depth-only
        shadDesc.depthAttachmentPixelFormat = .depth32Float
        do { shadowPipeline = try device.makeRenderPipelineState(descriptor: shadDesc) }
        catch { fatalError("shadow pipeline failed: \(error)") }

        let shdd = MTLDepthStencilDescriptor()
        shdd.depthCompareFunction = .lessEqual
        shdd.isDepthWriteEnabled  = true
        shadowDepthState = device.makeDepthStencilState(descriptor: shdd)

        // ---- Bloom bright-pass (HDR → half-res rgba16Float) ------------------
        let bpd = MTLRenderPipelineDescriptor()
        bpd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bpd.fragmentFunction = lib.makeFunction(name: "bloomBrightFrag")
        bpd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBrightPipeline = try device.makeRenderPipelineState(descriptor: bpd) }
        catch { fatalError("bloom bright pipeline failed: \(error)") }

        // ---- Bloom blur H -------------------------------------------------------
        let bhd = MTLRenderPipelineDescriptor()
        bhd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bhd.fragmentFunction = lib.makeFunction(name: "bloomBlurHFrag")
        bhd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBlurHPipeline = try device.makeRenderPipelineState(descriptor: bhd) }
        catch { fatalError("bloom blurH pipeline failed: \(error)") }

        // ---- Bloom blur V -------------------------------------------------------
        let bvd = MTLRenderPipelineDescriptor()
        bvd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bvd.fragmentFunction = lib.makeFunction(name: "bloomBlurVFrag")
        bvd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBlurVPipeline = try device.makeRenderPipelineState(descriptor: bvd) }
        catch { fatalError("bloom blurV pipeline failed: \(error)") }

        // ---- Composite / tonemap (rgba16Float HDR + bloom → drawable bgra8) ---
        let cpd = MTLRenderPipelineDescriptor()
        cpd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        cpd.fragmentFunction = lib.makeFunction(name: "compositeFrag")
        cpd.colorAttachments[0].pixelFormat = colorFormat   // drawable bgra8
        do { compositePipeline = try device.makeRenderPipelineState(descriptor: cpd) }
        catch { fatalError("composite pipeline failed: \(error)") }

        // ---- Ambient life (birds / fireflies): additive blended point sprites --
        let ald = MTLRenderPipelineDescriptor()
        ald.vertexFunction   = lib.makeFunction(name: "ambientLifeVert")
        ald.fragmentFunction = lib.makeFunction(name: "ambientLifeFrag")
        ald.colorAttachments[0].pixelFormat = .rgba16Float
        ald.colorAttachments[0].isBlendingEnabled             = true
        ald.colorAttachments[0].sourceRGBBlendFactor          = .one
        ald.colorAttachments[0].destinationRGBBlendFactor     = .one   // additive
        ald.colorAttachments[0].sourceAlphaBlendFactor        = .one
        ald.colorAttachments[0].destinationAlphaBlendFactor   = .zero
        ald.depthAttachmentPixelFormat = .depth32Float
        do { ambientLifePipeline = try device.makeRenderPipelineState(descriptor: ald) }
        catch { fatalError("ambient life pipeline failed: \(error)") }

        // Birds: no depth test (sky sprites). Fireflies: less-equal depth test.
        // We handle both in one pipeline; fireflies use depth, birds skip via discard logic.
        let aldd = MTLDepthStencilDescriptor()
        aldd.depthCompareFunction = .lessEqual
        aldd.isDepthWriteEnabled  = false   // additive sprites never write depth
        ambientLifeDepthState = device.makeDepthStencilState(descriptor: aldd)

        // Allocate the CPU-writable sprite buffer (updated every frame)
        ambientLifeBuffer = device.makeBuffer(
            length: kMaxAmbientSprites * MemoryLayout<AmbientSpritePod>.stride,
            options: .storageModeShared)!

        // ---- World-space precipitation pipeline (alpha-blended billboards) -----
        // Rain = thin vertical streaks; snow = small soft flakes. Standard
        // src-alpha / one-minus-src-alpha blend over the scene; depth-tested so
        // particles behind terrain are hidden, but no depth write.
        let ppd = MTLRenderPipelineDescriptor()
        ppd.vertexFunction   = lib.makeFunction(name: "precipVert")
        ppd.fragmentFunction = lib.makeFunction(name: "precipFrag")
        ppd.colorAttachments[0].pixelFormat = .rgba16Float
        ppd.colorAttachments[0].isBlendingEnabled             = true
        ppd.colorAttachments[0].sourceRGBBlendFactor          = .sourceAlpha
        ppd.colorAttachments[0].destinationRGBBlendFactor     = .oneMinusSourceAlpha
        ppd.colorAttachments[0].sourceAlphaBlendFactor        = .one
        ppd.colorAttachments[0].destinationAlphaBlendFactor   = .zero
        ppd.depthAttachmentPixelFormat = .depth32Float
        do { precipPipeline = try device.makeRenderPipelineState(descriptor: ppd) }
        catch { fatalError("precip pipeline failed: \(error)") }

        let ppdd = MTLDepthStencilDescriptor()
        ppdd.depthCompareFunction = .lessEqual
        ppdd.isDepthWriteEnabled  = false   // precipitation never writes depth
        precipDepthState = device.makeDepthStencilState(descriptor: ppdd)

        // Fill the precipitation particle buffer ONCE: each particle gets a stable
        // pseudo-random offset within the unit box [-0.5..0.5]^3 plus a fall phase.
        // The vertex shader animates the world position from these each frame, so no
        // per-frame CPU work and the particles recycle (wrap) entirely on the GPU.
        precipBuffer = device.makeBuffer(
            length: kPrecipCount * MemoryLayout<PrecipParticlePod>.stride,
            options: .storageModeShared)!
        let pptr = precipBuffer.contents().bindMemory(to: PrecipParticlePod.self, capacity: kPrecipCount)
        func h(_ n: UInt32) -> Float {   // cheap deterministic hash → [0,1)
            var v = n &* 0x9E3779B1
            v ^= v >> 16; v = v &* 0x85EBCA6B
            v ^= v >> 13; v = v &* 0xC2B2AE35
            v ^= v >> 16
            return Float(v) / Float(UInt32.max)
        }
        for i in 0..<kPrecipCount {
            let n = UInt32(i)
            pptr[i] = PrecipParticlePod(seed: SIMD4<Float>(
                h(n &* 3 &+ 1) - 0.5,         // x offset in [-0.5, 0.5]
                h(n &* 7 &+ 13) - 0.5,        // y offset in [-0.5, 0.5]
                h(n &* 11 &+ 101) - 0.5,      // z offset in [-0.5, 0.5]
                h(n &* 17 &+ 271)))           // phase 0..1
        }
    }

    private func buildShadowMap() {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: kShadowRes, height: kShadowRes, mipmapped: false)
        td.usage        = [.renderTarget, .shaderRead]
        td.storageMode  = .private
        shadowMap = device.makeTexture(descriptor: td)!

        let sd = MTLSamplerDescriptor()
        sd.minFilter        = .linear
        sd.magFilter        = .linear
        sd.sAddressMode     = .clampToEdge
        sd.tAddressMode     = .clampToEdge
        sd.compareFunction  = .lessEqual   // comparison sampler for shadow PCF
        shadowSampler = device.makeSamplerState(descriptor: sd)!
    }

    // ---- Resize: rebuild HDR + bloom textures when drawable size changes -----
    // The HDR scene is rendered at a capped internal resolution so the long edge
    // never exceeds kRenderLongEdge pixels (e.g. 1280 on a 5K Retina display).
    // The ACES composite writes to compositeLowRes (bgra8Unorm at sceneSize), then
    // an MTLFXSpatialScaler upscales it to the full drawable with much higher quality
    // than bilinear. Falls back to bilinear if MetalFX is unavailable.
    private func rebuildHDRTextures(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }

        // Compute capped scene size: scale down if the long edge exceeds the cap.
        let longEdge = max(size.width, size.height)
        let scale = longEdge > kRenderLongEdge ? kRenderLongEdge / longEdge : 1.0
        let SW = max(1, Int((size.width  * scale).rounded()))
        let SH = max(1, Int((size.height * scale).rounded()))
        sceneSize = CGSize(width: SW, height: SH)

        let HW = max(1, SW / 2), HH = max(1, SH / 2)
        let DW = max(1, Int(size.width.rounded()))
        let DH = max(1, Int(size.height.rounded()))

        func make2D(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            td.usage = usage; td.storageMode = .private
            return device.makeTexture(descriptor: td)!
        }

        hdrColor    = make2D(.rgba16Float,  SW,  SH, usage: [.renderTarget, .shaderRead])
        hdrDepth    = make2D(.depth32Float, SW,  SH, usage: [.renderTarget])
        bloomBright = make2D(.rgba16Float, HW,  HH, usage: [.renderTarget, .shaderRead])
        bloomBlurA  = make2D(.rgba16Float, HW,  HH, usage: [.renderTarget, .shaderRead])
        bloomBlurB  = make2D(.rgba16Float, HW,  HH, usage: [.renderTarget, .shaderRead])
        currentDrawableSize = size

        // ---- MetalFX spatial upscaler setup ---------------------------------
        // compositeLowRes is the ACES composite output at sceneSize (LDR bgra8Unorm).
        // MetalFX requires its input texture to have .shaderRead + .renderTarget usage.
        // The scaler then writes to the full-resolution drawable texture.
        metalFXEnabled = false
        compositeLowRes = nil
#if canImport(MetalFX)
        if #available(macOS 13.0, *) {
            // Only build the scaler when the scene is actually smaller than the drawable
            // (if already 1:1 the spatial scaler would be a no-op but still costs memory).
            let needsUpscale = SW < DW || SH < DH
            if needsUpscale && MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                let scalerDesc = MTLFXSpatialScalerDescriptor()
                scalerDesc.inputWidth           = SW
                scalerDesc.inputHeight          = SH
                scalerDesc.outputWidth          = DW
                scalerDesc.outputHeight         = DH
                // bgra8Unorm: the ACES composite already produces a tone-mapped LDR image,
                // so we use .perceptual colour processing (designed for LDR gamma-correct input).
                scalerDesc.colorTextureFormat   = .bgra8Unorm
                scalerDesc.outputTextureFormat  = .bgra8Unorm
                scalerDesc.colorProcessingMode  = .perceptual

                if let scaler = scalerDesc.makeSpatialScaler(device: device) {
                    _spatialScaler = scaler
                    // compositeLowRes: MetalFX input — needs .shaderRead for the scaler to read it.
                    let td = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: SW, height: SH, mipmapped: false)
                    td.usage        = [.renderTarget, .shaderRead]
                    td.storageMode  = .private
                    compositeLowRes = device.makeTexture(descriptor: td)
                    if compositeLowRes != nil {
                        metalFXEnabled = true
                    }
                }
            }
        }
#endif
    }

    // MARK: Engine create

    private func createEngine() {
        var cfg = bf_engine_config()
        cfg.abi_version = BF_ABI_VERSION
        cfg.role = BF_ROLE_SINGLEPLAYER
        cfg.start_mode = BF_MODE_SURVIVAL
        cfg.render_distance_chunks = 24   // streaming radius (chunks); surface-priority makes it affordable (#25) + view-cone culling keep this affordable (#5)
        cfg.memory_budget_bytes = 10 * 1024 * 1024 * 1024
        // Content is bundled at Resources/content (build.sh copies it there).
        // The registry loads <dir>/blocks, <dir>/items, … so point at that folder,
        // not Resources itself — otherwise NO blocks/items/recipes load and there
        // are no drops, starter items, or recipes.
        let resDir = Bundle.main.resourcePath ?? "."
        let contentDir = FileManager.default.fileExists(atPath: resDir + "/content/blocks")
            ? resDir + "/content" : resDir
        cfg.content_dir = persistentCString(contentDir)
        cfg.save_dir = persistentCString(saveDir)
        cfg.player_name = persistentCString("kid")
        var err = BF_OK
        engine = bf_engine_create(&cfg, &err)
        guard let e = engine, err == BF_OK else {
            fatalError("engine create failed: \(String(cString: bf_last_error_global()))")
        }
        var alloc = bf_gpu_allocator()
        alloc.user = Unmanaged.passUnretained(registry).toOpaque()
        alloc.alloc = allocTrampoline
        alloc.free_ = freeTrampoline
        _ = bf_set_gpu_allocator(e, &alloc)
        bf_set_event_callback(e, eventTrampoline, Unmanaged.passUnretained(self).toOpaque())
        // A brand-new world starts fresh (ignore any stale save in this folder);
        // an existing world loads its save.
        if freshWorld {
            _ = bf_world_new(e, worldSeed)
            _ = bf_world_save(e)          // write an initial save so the world persists immediately
        } else {
            _ = bf_world_load(e)
        }
    }

    private let discovery = NetDiscovery()
    private let coopPort: Int32 = 27355

    func startHost() {
        guard let e = engine else { return }
        _ = bf_net_host_start(e, UInt16(coopPort))
        discovery.publish(port: coopPort)
    }
    func joinLAN() {
        discovery.onHostFound = { [weak self] ip, port in
            DispatchQueue.main.async {
                guard let self = self, let e = self.engine else { return }
                ip.withCString { _ = bf_net_client_connect(e, $0, port) }
                NSLog("Blockfall: joining \(ip):\(port)")
            }
        }
        discovery.browse()
    }

    func handleEvent(_ ev: bf_event) {
        guard ev.kind == BF_EVT_SFX else { return }
        switch ev.i {
        case 0:                                    // packed: (blockId<<4 | soundClass)
            let packed = Int(ev.j)
            audio?.playBreak(materialClass: packed & 0xF)
            spawnBreakParticles(ev.pos, blockId: packed >> 4)
        case 1: audio?.play(.place)
        case 2: audio?.play(.step)
        case 3: audio?.play(.jump)
        case 4: audio?.play(.craft)
        case 5: audio?.play(.befriend)
        case 6: audio?.play(.questComplete)
        case 7: audio?.play(.pickup)
        case 8: audio?.play(.mine)         // melee hit on a creature
        case 9: audio?.play(.hurt)         // player took damage
        default: break
        }
    }

    func spawnBreakParticles(_ pos: bf_ivec3, blockId: Int = 0) { particles.spawn(at: pos, blockId: blockId) }

    func shutdown() {
        guard let e = engine else { return }
        engine = nil   // stop draw(in:) from touching the engine from here on
        // The frame loop only waitUntilScheduled()s before present, so the GPU may
        // still be reading chunk mesh buffers that bf_engine_destroy is about to
        // free. Fence on a fresh command buffer to ensure all submitted work has
        // completed before we free those buffers (prevents a GPU use-after-free
        // when quitting to the menu mid-frame).
        let fence = queue.makeCommandBuffer()
        fence?.commit(); fence?.waitUntilCompleted()
        _ = bf_world_save(e); bf_engine_destroy(e)
    }
    deinit { shutdown() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildHDRTextures(size: size)
    }

    // MARK: Draw

    func draw(in view: MTKView) {
        guard let e = engine,
              let drawable = view.currentDrawable else { return }

        let now = CACurrentMediaTime()
        let dt = now - lastTime; lastTime = now
        frameCounter += 1
        registry.currentFrame = frameCounter

        // Lazy texture init / resize check
        let dSize = view.drawableSize
        if currentDrawableSize != dSize { rebuildHDRTextures(size: dSize) }
        guard let hdrColor = hdrColor, let hdrDepth = hdrDepth,
              let bloomBright = bloomBright, let bloomBlurA = bloomBlurA,
              let bloomBlurB = bloomBlurB else { return }

        // 1) input -> engine
        var input = gameView?.makeFrameInput() ?? bf_frame_input()
        _ = bf_frame_begin(e, &input, dt)
        if let actions = gameView?.drainActions() {
            for var a in actions { bf_input_action(e, &a) }
        }

        // 2) acquire render
        var frame = bf_render_frame()
        _ = bf_frame_acquire_render(e, &frame)

        // Snapshot the buffer registry AFTER acquire: this frame's update/remesh
        // (inside frame_begin/acquire) may have allocated brand-new mesh buffers,
        // and the draw list references them. Snapshotting earlier missed those, so
        // a just-remeshed chunk wasn't drawn for a frame — flashing holes that let
        // you see the caves below, especially while chunks stream/light settles.
        let bufs = registry.snapshot()

        // 3) camera matrices
        let aspect = Float(dSize.width / max(1, dSize.height))
        let fovy: Float = 1.20
        let proj  = Renderer.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 512)
        let viewM = Renderer.mat(frame.camera.view)
        let viewProj = proj * viewM
        let sun = frame.camera.sun_dir

        let wallClock = Float(now.truncatingRemainder(dividingBy: 3600.0))
        let isUnderwater = frame.camera.underwater

        // Feed the HUD the player's world position + facing so it can show
        // coordinates. facing = heading angle (radians) from forward.x/forward.z.
        hud?.setPlayerInfo(x: frame.camera.position.x,
                           y: frame.camera.position.y,
                           z: frame.camera.position.z,
                           facing: atan2(frame.camera.forward.x, frame.camera.forward.z))

        // Feed the HUD the time of day for a day/night indicator (HUDView method
        // added by another agent; guarded so it's a no-op until then).
        hud?.setTimeOfDay(frame.camera.time_of_day)

        // Weather is now fully engine-owned: frame.camera.weather = 0=clear, 1=rain, 2=snow.
        // Map that to a rain strength for wind/wet-darkening (0 when clear or snow, 1 when rain).
        let engineWeather = Int(frame.camera.weather)   // 0, 1, or 2
        let rainStrength: Float = (engineWeather == 1) ? 1.0 : 0.0

        // Wind uniforms (index 3 on vertex shaders — new dedicated buffer)
        var windU = WindUniforms(wallClockSecs: wallClock, rainStrength: rainStrength)

        // Camera basis for sky dome
        let camRight = SIMD3<Float>(viewM.columns.0.x, viewM.columns.1.x, viewM.columns.2.x)
        let camUp    = SIMD3<Float>(viewM.columns.0.y, viewM.columns.1.y, viewM.columns.2.y)
        let camFwd   = SIMD3<Float>(-viewM.columns.0.z, -viewM.columns.1.z, -viewM.columns.2.z)
        let tanHalfFov = tan(fovy * 0.5)

        let vt = viewM.columns.3
        let camPosW = SIMD4<Float>(
            -(viewM.columns.0.x * vt.x + viewM.columns.1.x * vt.y + viewM.columns.2.x * vt.z),
            -(viewM.columns.0.y * vt.x + viewM.columns.1.y * vt.y + viewM.columns.2.y * vt.z),
            -(viewM.columns.0.z * vt.x + viewM.columns.1.z * vt.y + viewM.columns.2.z * vt.z),
            0)

        // 4) Build sun light-space matrix for shadow pass
        let lightViewProj = Renderer.buildLightMatrix(
            sunDir: SIMD3<Float>(sun.x, sun.y, sun.z),
            camPos: SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z),
            camFwd: camFwd)

        // Must release the acquired frame even on this early-out, or `borrowed`
        // sticks true and every later acquire returns the same frame forever.
        guard let cmd = queue.makeCommandBuffer() else { bf_frame_end(e); return }

        // =====================================================================
        // PASS 1: Shadow depth pass (chunk meshes + entities → shadow map)
        // =====================================================================
        let shadowRP = MTLRenderPassDescriptor()
        shadowRP.depthAttachment.texture    = shadowMap
        shadowRP.depthAttachment.loadAction = .clear
        shadowRP.depthAttachment.storeAction = .store
        shadowRP.depthAttachment.clearDepth = 1.0

        if let shadowEnc = cmd.makeRenderCommandEncoder(descriptor: shadowRP) {
            shadowEnc.setRenderPipelineState(shadowPipeline)
            shadowEnc.setDepthStencilState(shadowDepthState)
            shadowEnc.setCullMode(.front)   // front-face culling reduces acne
            shadowEnc.setDepthBias(2.0, slopeScale: 2.0, clamp: 0.0)
            // Wind uniforms at index 2 (shadow pass only has buffer 0 = vertices, 1 = ShadowVertUniforms)
            shadowEnc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 2)

            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = bufs[d.vertex_buffer],
                      let ibuf = bufs[d.index_buffer] else { continue }
                var su = ShadowVertUniforms(
                    lightViewProj: lightViewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), 0))
                shadowEnc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                shadowEnc.setVertexBytes(&su, length: MemoryLayout<ShadowVertUniforms>.stride, index: 1)
                shadowEnc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                                indexType: .uint32, indexBuffer: ibuf,
                                                indexBufferOffset: Int(d.index_offset))
            }
            shadowEnc.endEncoding()
        }

        // =====================================================================
        // PASS 2: Main scene → HDR colour texture (rgba16Float)
        //   Sub-passes: sky, terrain, entities, particles, underwater
        // =====================================================================
        let sky = skyColor(frame.camera.time_of_day)
        let hdrRP = MTLRenderPassDescriptor()
        hdrRP.colorAttachments[0].texture     = hdrColor
        hdrRP.colorAttachments[0].loadAction  = .clear
        hdrRP.colorAttachments[0].storeAction = .store
        hdrRP.colorAttachments[0].clearColor  = MTLClearColor(red: sky.0, green: sky.1, blue: sky.2, alpha: 1)
        hdrRP.depthAttachment.texture         = hdrDepth
        hdrRP.depthAttachment.loadAction      = .clear
        hdrRP.depthAttachment.storeAction     = .dontCare
        hdrRP.depthAttachment.clearDepth      = 1.0

        if let enc = cmd.makeRenderCommandEncoder(descriptor: hdrRP) {

            // --- Sky pass ---
            if skyPipeline != nil {
                enc.setRenderPipelineState(skyPipeline)
                enc.setDepthStencilState(skyDepthState)
                enc.setCullMode(.none)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    camRight:   SIMD4<Float>(camRight.x, camRight.y, camRight.z, tanHalfFov),
                    camUp:      SIMD4<Float>(camUp.x,    camUp.y,    camUp.z,    aspect),
                    camFwd:     SIMD4<Float>(camFwd.x,   camFwd.y,   camFwd.z,   0))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                          cameraPosW: camPosW)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            // --- Terrain pass ---
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)

            var wu = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                   cameraPosW: camPosW)
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            enc.setFragmentTexture(shadowMap, index: 0)
            enc.setFragmentSamplerState(shadowSampler, index: 0)
            // Wind/weather available to terrain frag at index 3 (rain wet-darkening)
            enc.setFragmentBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            // Wind uniforms to terrain vertex shader at index 3 (foliage sway)
            enc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)

            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = bufs[d.vertex_buffer],
                      let ibuf = bufs[d.index_buffer] else { continue }
                var u = Uniforms(
                    viewProj:      viewProj,
                    chunkOrigin:   SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime:    SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: lightViewProj,
                    dimSatN:       SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ibuf,
                                          indexBufferOffset: Int(d.index_offset))
            }

            // Entities + particles
            enc.setDepthStencilState(depthState)
            entityRenderer.encode(enc, viewProj: viewProj, entities: frame.entities, count: Int(frame.entity_count))
            particles.update(Float(dt))
            particles.encode(enc, viewProj: viewProj)

            // --- Ambient life: birds (day) + fireflies (night) ---
            let spriteCount = updateAmbientSprites(
                wallClock: wallClock,
                timeOfDay: frame.camera.time_of_day,
                camPos: SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z))
            if spriteCount > 0 {
                enc.setRenderPipelineState(ambientLifePipeline)
                enc.setDepthStencilState(ambientLifeDepthState)
                enc.setCullMode(.none)
                var alU = AmbientLifeUniforms(
                    viewProj:   viewProj,
                    camPosW:    camPosW,
                    timeOfDay:  frame.camera.time_of_day,
                    wallClock:  wallClock,
                    pad0:       0,
                    pad1:       0)
                enc.setVertexBuffer(ambientLifeBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&alU, length: MemoryLayout<AmbientLifeUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: spriteCount * 6)
            }

            // --- Water translucency pass ---
            // Re-draw chunk meshes with the water pipeline: the fragment shader discards
            // all material IDs except 9 (water) and outputs alpha 0.55 so the lake
            // bottom (already in the colour buffer from the opaque terrain pass) shows
            // through. Depth write is OFF; depth test is lessEqual so only actual water
            // surface fragments are drawn (terrain below is already at lesser depth).
            enc.setRenderPipelineState(waterPipeline)
            enc.setDepthStencilState(waterDepthState)
            enc.setCullMode(.none)   // water seen from below should also be translucent
            enc.setFrontFacing(.counterClockwise)
            // Reuse the same WaterUniforms / shadow / wind bindings already set above
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            enc.setFragmentTexture(shadowMap, index: 0)
            enc.setFragmentSamplerState(shadowSampler, index: 0)
            enc.setFragmentBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = bufs[d.vertex_buffer],
                      let ibuf = bufs[d.index_buffer] else { continue }
                var u = Uniforms(
                    viewProj:      viewProj,
                    chunkOrigin:   SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime:    SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: lightViewProj,
                    dimSatN:       SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ibuf,
                                          indexBufferOffset: Int(d.index_offset))
            }

            // --- World-space precipitation (rain / snow) ---
            // Environmental falling particles in a volume around the camera. Driven
            // by engine weather (0=clear, 1=rain, 2=snow). Drawn after terrain+water
            // so it layers over the scene; depth-tested (lessEqual, no write) so
            // particles behind solid terrain are correctly hidden. Skipped entirely
            // when clear or when underwater (no rain underwater).
            if engineWeather != 0 && isUnderwater <= 0.5 {
                enc.setRenderPipelineState(precipPipeline)
                enc.setDepthStencilState(precipDepthState)
                enc.setCullMode(.none)
                var prU = PrecipUniforms(
                    viewProj:  viewProj,
                    camPosW:   camPosW,
                    wallClock: wallClock,
                    mode:      Float(engineWeather),   // 1=rain, 2=snow
                    boxSize:   kPrecipBox,
                    pad0:      0)
                enc.setVertexBuffer(precipBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&prU, length: MemoryLayout<PrecipUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: kPrecipCount * 6)
            }

            // --- Underwater post-pass ---
            if isUnderwater > 0.01 {
                enc.setRenderPipelineState(underwaterPipeline)
                enc.setDepthStencilState(skyDepthState)
                enc.setCullMode(.none)
                var wuPost = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                           cameraPosW: camPosW)
                enc.setVertexBytes(&wuPost, length: MemoryLayout<WaterUniforms>.stride, index: 0)
                enc.setFragmentBytes(&wuPost, length: MemoryLayout<WaterUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            enc.endEncoding()
        }

        // =====================================================================
        // PASS 3: Bloom — bright-pass (HDR → half-res bloomBright)
        // =====================================================================
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBrightPipeline,
                             inTexture: hdrColor, outTexture: bloomBright,
                             uniforms: nil, uniformsSize: 0)

        // Separable Gaussian blur, two H+V sweeps (ping-pong; can't alias in Metal).
        // Final result lands back in bloomBright for the composite pass.
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurHPipeline,
                             inTexture: bloomBright, outTexture: bloomBlurA,
                             uniforms: nil, uniformsSize: 0)
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurVPipeline,
                             inTexture: bloomBlurA, outTexture: bloomBlurB,
                             uniforms: nil, uniformsSize: 0)
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurHPipeline,
                             inTexture: bloomBlurB, outTexture: bloomBlurA,
                             uniforms: nil, uniformsSize: 0)
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurVPipeline,
                             inTexture: bloomBlurA, outTexture: bloomBright,
                             uniforms: nil, uniformsSize: 0)

        // Precipitation driven entirely by engine weather field (0=clear, 1=rain, 2=snow).
        // Pack: >0 = rain (strength), <0 = snow (abs = strength), 0 = clear.
        let precipPacked: Float
        switch engineWeather {
        case 1:  precipPacked =  1.0   // rain
        case 2:  precipPacked = -1.0   // snow
        default: precipPacked =  0.0   // clear
        }
        var pu = PostUniforms(bloomStrength: Renderer.dbgBloom ? 0.08 : 0.0, vignetteStr: 0.22, satBoost: 1.18,
                              rainStrength: precipPacked, wallClockSecs: wallClock)

        // =====================================================================
        // PASS 4a: Composite (ACES + colour grade + vignette)
        //   MetalFX path:  composite → compositeLowRes (bgra8Unorm at sceneSize)
        //   Fallback path: composite → drawable directly (bilinear upscale via sampler)
        // =====================================================================
#if canImport(MetalFX)
        let useMetalFX: Bool
        if #available(macOS 13.0, *) {
            useMetalFX = Renderer.dbgMetalFX && metalFXEnabled && _spatialScaler != nil && compositeLowRes != nil
        } else {
            useMetalFX = false
        }
#else
        let useMetalFX = false
#endif

        if useMetalFX, let lowResTarget = compositeLowRes {
            // --- Composite to the low-res intermediate ---
            let lowResRP = MTLRenderPassDescriptor()
            lowResRP.colorAttachments[0].texture    = lowResTarget
            lowResRP.colorAttachments[0].loadAction  = .dontCare
            lowResRP.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: lowResRP) {
                enc.setRenderPipelineState(compositePipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor,    index: 0)
                enc.setFragmentTexture(bloomBright, index: 1)
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
#if canImport(MetalFX)
            // --- PASS 4b: MetalFX spatial upscale → drawable ---
            if #available(macOS 13.0, *), let scaler = _spatialScaler {
                scaler.colorTexture  = lowResTarget
                scaler.outputTexture = drawable.texture
                scaler.encode(commandBuffer: cmd)
            }
#endif
        } else {
            // --- Fallback: composite straight to drawable (bilinear, original behaviour) ---
            if let passDesc = view.currentRenderPassDescriptor {
                passDesc.colorAttachments[0].loadAction  = .clear
                passDesc.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
                    enc.setRenderPipelineState(compositePipeline)
                    enc.setDepthStencilState(noDepthState)
                    enc.setCullMode(.none)
                    enc.setFragmentTexture(hdrColor,    index: 0)
                    enc.setFragmentTexture(bloomBright, index: 1)
                    enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
        }

        // Present inside the Core Animation transaction so the AppKit HUD overlay
        // (hotbar, hearts, inventory) composites ON TOP of the Metal layer. With
        // the default async present the metal content draws over the overlay and
        // the HUD is invisible. Requires view.presentsWithTransaction = true.
        // This path is unchanged regardless of whether MetalFX is active.
        if view.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }

        // Audio: drive day/evening music + splash when entering water.
        audio?.setTimeOfDay(frame.camera.time_of_day)
        let nowUnder = frame.camera.underwater > 0.5
        if nowUnder && !lastUnderwater { audio?.play(.splash) }
        lastUnderwater = nowUnder

        hud?.update(from: frame.hud)
        bf_frame_end(e)
        registry.collect()
    }

    // Helper: fullscreen triangle pass with one input + one output texture.
    private func encodeFullscreenPass(cmd: MTLCommandBuffer,
                                      pipeline: MTLRenderPipelineState,
                                      inTexture: MTLTexture,
                                      outTexture: MTLTexture,
                                      uniforms: UnsafeRawPointer?,
                                      uniformsSize: Int) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture     = outTexture
        rp.colorAttachments[0].loadAction  = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(noDepthState)
        enc.setCullMode(.none)
        enc.setFragmentTexture(inTexture, index: 0)
        if let u = uniforms, uniformsSize > 0 {
            enc.setFragmentBytes(u, length: uniformsSize, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: Ambient life sprite update (CPU procedural, ~80 sprites max)

    /// Fills ambientLifeBuffer with this frame's bird/firefly sprites.
    /// Returns the sprite count written (may be 0 when completely faded).
    @discardableResult
    private func updateAmbientSprites(wallClock: Float, timeOfDay: Float, camPos: SIMD3<Float>) -> Int {
        // dayT: 0=night, 1=noon
        let dayT  = max(0, sin(timeOfDay * .pi))
        // nightT: inverse
        let nightT = max(0, 1.0 - dayT * 2.0)   // 0 during day, >0 during dusk/night

        // Spawn budget
        let birdCount: Int     = Int((dayT * dayT * 12).rounded())    // 0..12 birds by day
        let fireflyCount: Int  = Int((nightT * nightT * 40).rounded()) // 0..40 fireflies by night
        let totalSprites = min(birdCount + fireflyCount, kMaxAmbientSprites)
        guard totalSprites > 0 else { return 0 }

        let ptr = ambientLifeBuffer.contents().bindMemory(to: AmbientSpritePod.self, capacity: kMaxAmbientSprites)

        // --- Birds (daytime, sky sprites, large) ---
        for i in 0..<birdCount {
            let fi = Float(i)
            // Each bird orbits the player slowly at a random angle offset
            let angle = wallClock * 0.06 + fi * 2.399              // golden-angle spacing
            let radius = 30.0 + sin(fi * 1.618 + wallClock * 0.02) * 18.0
            let height = camPos.y + 22.0 + sin(fi * 0.9 + wallClock * 0.07) * 6.0
            let bx = camPos.x + cos(angle) * radius
            let bz = camPos.z + sin(angle) * radius
            let by = height
            // Fade birds out at dawn/dusk edges
            let birdAlpha = min(1.0, dayT * 3.0)
            ptr[i] = AmbientSpritePod(
                posW:  SIMD4<Float>(bx, by, bz, 0.9),                        // w=size
                color: SIMD4<Float>(0.15, 0.12, 0.10, birdAlpha * 0.85))    // dark silhouette
        }

        // --- Fireflies (nighttime, near-ground, small emissive) ---
        for i in 0..<fireflyCount {
            let fi = Float(i)
            // Bob around the player at low altitude in a rough disc
            let angle = wallClock * 0.03 + fi * 2.399 + sin(fi * 1.1 + wallClock * 0.15) * 0.8
            let radius = 5.0 + fmod(fi * 3.14159, 18.0)
            let bobY = sin(fi * 0.87 + wallClock * (0.4 + fi * 0.003)) * 1.8
            let fx = camPos.x + cos(angle) * radius
            let fz = camPos.z + sin(angle) * radius
            let fy = camPos.y + 1.5 + bobY   // hover near ground level
            // Blink: each firefly has its own blink phase
            let blink = max(0.0, sin(wallClock * (1.0 + fi * 0.37) + fi * 2.1))
            let blink2 = blink * blink
            let ffAlpha = min(1.0, nightT * 2.0) * (0.4 + blink2 * 0.6)
            // Warm yellow-green, HDR overbright so they bloom
            let r = 1.2 + blink2 * 0.6
            let g = 1.8 + blink2 * 0.3
            let b = 0.3 + blink2 * 0.1
            let idx = birdCount + i
            ptr[idx] = AmbientSpritePod(
                posW:  SIMD4<Float>(fx, fy, fz, 0.22),              // w=size (tiny)
                color: SIMD4<Float>(r, g, b, ffAlpha))
        }

        return totalSprites
    }

    // MARK: Sky colour (clear colour tint — sky pass renders on top)

    private func skyColor(_ t: Float) -> (Double, Double, Double) {
        let dayT  = Double(max(0.0, sin(t * .pi)))
        let dawnT = Double(max(0.0, 1.0 - abs(t - 0.25) * 8.0))
        let duskT = Double(max(0.0, 1.0 - abs(t - 0.75) * 8.0))
        let sunsetT = min(dawnT + duskT, 1.0)
        let nr = 0.08; let ng = 0.10; let nb = 0.22
        let dr = 0.68; let dg = 0.84; let db = 1.00
        let sr = 1.00; let sg = 0.52; let sb = 0.18
        var r = nr + (dr - nr) * dayT
        var g = ng + (dg - ng) * dayT
        var b = nb + (db - nb) * dayT
        r = r + (sr - r) * sunsetT * 0.85
        g = g + (sg - g) * sunsetT * 0.85
        b = b + (sb - b) * sunsetT * 0.85
        return (min(r, 1.0), min(g, 1.0), min(b, 1.0))
    }

    // MARK: Matrix helpers

    // bf_mat4 (column-major float[16]) -> simd_float4x4
    static func mat(_ m: bf_mat4) -> simd_float4x4 {
        let c = m.m
        return simd_float4x4(columns: (
            SIMD4<Float>(c.0,  c.1,  c.2,  c.3),
            SIMD4<Float>(c.4,  c.5,  c.6,  c.7),
            SIMD4<Float>(c.8,  c.9,  c.10, c.11),
            SIMD4<Float>(c.12, c.13, c.14, c.15)))
    }

    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let t = tan(fovy * 0.5)
        var m = simd_float4x4(0)
        m.columns.0.x = 1 / (aspect * t)
        m.columns.1.y = 1 / t
        m.columns.2.z = far / (near - far)
        m.columns.2.w = -1
        m.columns.3.z = (far * near) / (near - far)
        return m
    }

    /// Build a sun orthographic light-space VP matrix centred on the camera.
    /// L = normalize(sunDir) points FROM sun downward into the scene.
    /// We place the eye 120 units "up" along L from a point 40 units in front of the camera.
    static func buildLightMatrix(sunDir: SIMD3<Float>, camPos: SIMD3<Float>, camFwd: SIMD3<Float>) -> simd_float4x4 {
        let L = normalize(sunDir)                         // points downward from sun
        // Centre the shadow frustum on the PLAYER, not ahead of the view — an
        // ahead-of-view centre made the covered region swing as you turned, so
        // shadows flipped across half the world when spinning. Snap to whole
        // blocks to reduce shimmer while moving.
        _ = camFwd
        let center = SIMD3<Float>(camPos.x.rounded(), camPos.y.rounded(), camPos.z.rounded())
        let eye    = center - L * 120.0                   // light eye position

        // lookAt: choose an up vector not parallel to L
        let worldUp: SIMD3<Float> = abs(L.y) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let f = normalize(center - eye)                   // forward
        let r = normalize(cross(f, worldUp))              // right
        let u = cross(r, f)                               // up (reorthogonalised)

        // Column-major view matrix (same convention as the engine)
        let lightView = simd_float4x4(columns: (
            SIMD4<Float>( r.x,  u.x, -f.x, 0),
            SIMD4<Float>( r.y,  u.y, -f.y, 0),
            SIMD4<Float>( r.z,  u.z, -f.z, 0),
            SIMD4<Float>(-dot(r, eye), -dot(u, eye), dot(f, eye), 1)))

        // Orthographic projection (R=90 world-units, near=0.1, far=300)
        let R: Float = 90.0
        let near: Float = 0.1
        let far:  Float = 300.0
        let lightProj = simd_float4x4(columns: (
            SIMD4<Float>(1/R,  0,    0,                      0),
            SIMD4<Float>(0,    1/R,  0,                      0),
            SIMD4<Float>(0,    0,    1/(near-far),            0),
            SIMD4<Float>(0,    0,    near/(near-far),         1)))

        return lightProj * lightView
    }

    // MARK: - Shaders (MSL, runtime compiled)
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // =========================================================
    // TERRAIN STRUCTS & HELPERS
    // =========================================================

    // PackedVertex: same layout as the C++ BFVertex.
    //   pos    : 18-bit packed voxel coord (6+6+6), bits [0..17]
    //   normuv : bits [0..2]=face normal (0-5),  bits [3..5]=AO (0..3), bits [6+]=UV hints
    //   material, sky, block, reserved as before.
    struct PackedVertex {
        uint     pos;
        uint     normuv;
        ushort   material;
        uchar    sky;
        uchar    block;
        uint     reserved;
    };

    // Terrain uniforms: must EXACTLY match Swift Uniforms struct (176 bytes).
    //   viewProj (64), chunkOrigin (16), sunDirTime (16), lightViewProj (64), dimSatN (16)
    struct Uniforms {
        float4x4 viewProj;
        float4   chunkOrigin;   // xyz=origin, w=dim_saturation (min corner)
        float4   sunDirTime;    // xyz=sun_dir, w=time_of_day
        float4x4 lightViewProj; // sun shadow matrix
        float4   dimSatN;       // x=+X corner, y=+Z, z=+XZ saturation (grey bilerp)
    };

    // WaterUniforms (32 bytes) — not engine-filled.
    struct WaterUniforms {
        float wallClockSecs;
        float underwater;
        float pad0;
        float pad1;
        float4 cameraPosW;   // xyz = world pos, w = pad
    };
    #define UW_CAM_POS(wu) (wu).cameraPosW.xyz

    // ---- Shared water palette (keeps every water-related path consistent) ----
    // One source of truth so the translucent surface, the submerged-solid depth
    // tint and the full-screen underwater overlay all read as the SAME body of
    // water. Kept bright/aqua (no near-black murk) per the kid-friendly look.
    //   WATER_SURFACE_COL : base albedo of the water surface (top + sides)
    //   WATER_FOG_COL      : colour distant submerged solids fade toward, and the
    //                        colour of the full-screen underwater overlay. Same
    //                        value in both places so entering/looking around is smooth.
    constant float3 WATER_SURFACE_COL = float3(0.11, 0.38, 0.78);
    constant float3 WATER_FOG_COL     = float3(0.10, 0.34, 0.62);

    // PostUniforms (32 bytes) — composite pass.
    // >0 rainStrength = rain, <0 = snow, 0 = clear.
    struct PostUniforms {
        float bloomStrength;
        float vignetteStr;
        float satBoost;
        float rainStrength;
        float wallClockSecs;
        float pad0;
        float pad1;
        float pad2;
    };

    // ShadowVertUniforms (80 bytes): light VP + chunk origin.
    struct ShadowVertUniforms {
        float4x4 lightViewProj;  // 64 bytes
        float4   chunkOrigin;    // 16 bytes
    };

    // WindUniforms (16 bytes) — foliage sway + weather.  buffer(3) on vertex AND frag.
    struct WindUniforms {
        float wallClockSecs;
        float rainStrength;   // 0..1
        float pad0;
        float pad1;
    };

    // Vertex output for terrain pass.
    struct VOut {
        float4 position  [[position]];
        float3 color;
        float  shade;
        float  sat;
        float3 worldPos;
        uint   faceNorm  [[flat]];
        uint   material  [[flat]];
        // Shadow-map clip-space position (computed in vmain, not interpolated as
        // a position but as a float4 so it interpolates correctly across the face).
        float4 shadowPos;
        float  ao;               // 0=fully occluded, 1=fully open (from bits [3:5])
    };

    // AmbientSprite: 32 bytes, matches Swift AmbientSpritePod.
    struct AmbientSprite {
        float4 posW;    // xyz=world pos, w=size
        float4 color;   // rgb=HDR colour (>1 ok), a=alpha
    };

    // AmbientLifeUniforms: matches Swift AmbientLifeUniforms.
    struct AmbientLifeUniforms {
        float4x4 viewProj;   // 64 bytes
        float4   camPosW;    // 16 bytes
        float    timeOfDay;
        float    wallClock;
        float    pad0;
        float    pad1;
    };

    // PrecipParticle: 16 bytes, matches Swift PrecipParticlePod.
    struct PrecipParticle {
        float4 seed;   // xyz = offset within box [-0.5..0.5]^3, w = phase 0..1
    };

    // PrecipUniforms: 96 bytes, matches Swift PrecipUniforms.
    struct PrecipUniforms {
        float4x4 viewProj;   // 64 bytes
        float4   camPosW;    // 16 bytes — xyz world cam pos
        float    wallClock;  // animation time (seconds)
        float    mode;       // 1=rain, 2=snow
        float    boxSize;    // full edge length of spawn volume (world units)
        float    pad0;
    };

    // =========================================================
    // LIGHT / SHADE HELPERS
    // =========================================================

    static float faceShade(uint n) {
        if (n == 2u) return 1.0;    // top
        if (n == 3u) return 0.40;   // bottom
        return 0.62;                // sides (wider top/side spread = more depth)
    }

    static float3 hashColor(uint m) {
        float h = fract(float(m) * 0.6180339887f);
        float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
        float3 p = abs(fract(float3(h,h,h) + k) * 6.0 - 3.0);
        return clamp(p - 1.0, 0.0, 1.0) * 0.5 + 0.4;
    }

    // Full per-block colour table (ids 1–40, same as before).
    static float3 materialColor(uint m) {
        switch (m) {
            case  1u: return float3(0.35, 0.75, 0.28);
            case  2u: return float3(0.54, 0.38, 0.24);
            case  3u: return float3(0.55, 0.55, 0.58);
            case  6u: return float3(0.80, 0.72, 0.50);   // sand — pulled down so deserts don't bleach
            case  9u: return float3(0.14, 0.42, 0.82);
            case 10u: return float3(0.44, 0.44, 0.46);
            case 11u: return float3(0.50, 0.47, 0.42);
            case 12u: return float3(0.93, 0.96, 1.00);
            case 13u: return float3(0.72, 0.86, 1.00);
            case 14u: return float3(0.60, 0.66, 0.78);
            case 15u: return float3(0.28, 0.24, 0.36);
            case 16u: return float3(0.32, 0.22, 0.18);
            case  4u: return float3(0.72, 0.54, 0.30);
            case  5u: return float3(0.28, 0.60, 0.24);
            case  8u: return float3(0.58, 0.58, 0.64);
            case 21u: return float3(0.46, 0.32, 0.18);
            case 22u: return float3(0.80, 0.78, 0.68);
            case 23u: return float3(0.82, 0.76, 0.58);
            case 24u: return float3(0.76, 0.38, 0.28);
            case 25u: return float3(0.75, 0.93, 1.00);
            case 26u: return float3(0.30, 0.85, 0.75);
            case 27u: return float3(0.55, 0.80, 0.35);
            case 28u: return float3(0.94, 0.92, 0.88);
            case 29u: return float3(0.42, 0.52, 0.38);
            case 17u: return float3(0.40, 0.40, 0.42);
            case 18u: return float3(0.65, 0.44, 0.30);
            case 19u: return float3(0.60, 0.58, 0.54);
            case 20u: return float3(0.52, 0.44, 0.72);
            case  7u: return float3(1.00, 0.92, 0.45);
            case 30u: return float3(0.60, 0.42, 0.22);
            case 31u: return float3(0.75, 0.58, 0.28);
            case 32u: return float3(1.00, 0.70, 0.20);
            case 33u: return float3(0.65, 0.48, 0.28);
            case 34u: return float3(0.60, 0.96, 0.98);
            case 35u: return float3(0.80, 0.70, 1.00);
            case 36u: return float3(0.95, 0.18, 0.18);
            case 37u: return float3(1.00, 0.90, 0.10);
            case 38u: return float3(0.40, 0.78, 0.25);
            case 39u: return float3(0.58, 0.38, 0.22);
            case 40u: return float3(0.95, 0.50, 0.90);
            default:  return hashColor(m);
        }
    }

    // =========================================================
    // PROCEDURAL TEXTURE HELPERS
    // =========================================================

    static float uhash(uint v) {
        v ^= v >> 17u; v *= 0xbf324c81u;
        v ^= v >> 11u; v *= 0x9f34a21du;
        v ^= v >> 16u;
        return float(v) * (1.0 / 4294967296.0);
    }
    static float voxelHash(int3 vi) {
        uint h = (uint(vi.x) * 73856093u) ^ (uint(vi.y) * 19349663u) ^ (uint(vi.z) * 83492791u);
        return uhash(h);
    }
    static float noise2(float2 p) {
        int2 i = int2(floor(p));
        float2 f = fract(p);
        float2 u = f*f*(3.0 - 2.0*f);
        float a = uhash(uint(i.x) + uint(i.y)*57u);
        float b = uhash(uint(i.x+1) + uint(i.y)*57u);
        float c = uhash(uint(i.x) + uint(i.y+1)*57u);
        float d = uhash(uint(i.x+1) + uint(i.y+1)*57u);
        return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
    }
    static float fbm2(float2 p) {
        return noise2(p)*0.60 + noise2(p*2.1+float2(3.7,1.1))*0.30 + noise2(p*4.3+float2(1.3,5.7))*0.10;
    }
    // Project world pos to 2D UV by dominant face axis (face 0/1=YZ, 2/3=XZ, 4/5=XY)
    static float2 faceUV(float3 wp, uint face) {
        if (face == 0u || face == 1u) return wp.yz;
        if (face == 2u || face == 3u) return wp.xz;
        return wp.xy;
    }

    // Cheap 2D Voronoi: returns distance to nearest cell centre (3x3 neighborhood).
    // p is already in "cell" coordinates (scale before calling).
    // Returns float2(distToNearest, distToSecondNearest) so caller can compute edge dist.
    static float2 voronoi2(float2 p) {
        int2 ip = int2(floor(p));
        float2 fp = fract(p);
        float d0 = 1e9, d1 = 1e9;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int2 nb = ip + int2(dx, dy);
                // jitter cell centre
                uint hx = uint(nb.x) * 1664525u + uint(nb.y) * 1013904223u;
                float jx = uhash(hx)         * 0.8 + 0.1;
                float jy = uhash(hx ^ 987u)  * 0.8 + 0.1;
                float2 diff = float2(float(dx) + jx, float(dy) + jy) - fp;
                float dist = dot(diff, diff);   // squared dist, fine for comparison
                if (dist < d0) { d1 = d0; d0 = dist; }
                else if (dist < d1) { d1 = dist; }
            }
        }
        return float2(sqrt(d0), sqrt(d1));
    }

    // Returns 0 near cell edges, 1 at cell centres.  edgeWidth in [0,1] (pre-sqrt scale).
    static float voronoiCell(float2 p, float scale) {
        float2 d = voronoi2(p * scale);
        float edge = d.y - d.x;         // wide in open areas, narrow at edges
        return smoothstep(0.0, 0.15, edge);
    }

    // ---- Per-material surface texture: returns float3 colour multiplier -------
    // Range roughly 0.78 .. 1.22.  Modulates base colour via multiply in fmain.
    // face: 2=top, 3=bottom, 0/1/4/5=sides.  worldPos is continuous across quads.
    static float3 blockDetail(float3 worldPos, uint face, uint matID) {
        float2 uv   = faceUV(worldPos, face);
        bool isTop  = (face == 2u);
        bool isBot  = (face == 3u);
        bool isSide = !isTop && !isBot;

        // Per-voxel random seed (adds block-level variation so adjacent blocks differ)
        int3  vi    = int3(floor(worldPos));
        float vH    = voxelHash(vi);                        // 0..1

        // ---- STONE / COBBLESTONE / ORES  (3,10,8,29,17-20) --------------------
        // Stone (3): mottled grey value noise + Voronoi crack lines
        if (matID == 3u) {
            // Base mottled noise
            float mot  = noise2(uv * 6.5) * 0.55 + noise2(uv * 13.0 + float2(4.1, 2.3)) * 0.30
                       + noise2(uv * 26.0 + float2(1.9, 6.7)) * 0.15;
            // Voronoi cracks: dark lines between cells
            float2 vd  = voronoi2(uv * 2.8 + float2(vH * 3.0, vH * 2.1));
            float crack = 1.0 - smoothstep(0.0, 0.18, vd.y - vd.x);   // 1=on crack
            // Combine: mottled brightness + darker cracks
            float bri  = mix(0.82, 1.18, mot);
            bri       -= crack * 0.28;
            return float3(clamp(bri, 0.78, 1.20));
        }

        // Cobblestone (10): rounded pebble cells with highlight on top
        if (matID == 10u) {
            float2 vd = voronoi2(uv * 2.2 + float2(vH * 2.0, vH * 1.5));
            float d0  = vd.x;
            // Pebble: light centre, dark edge ring, dark mortar gap
            float pebble = smoothstep(0.0, 0.38, d0);  // 0=mortar, 1=stone
            float highlight = smoothstep(0.24, 0.42, d0) * smoothstep(0.60, 0.35, d0) * (isTop ? 0.18 : 0.09);
            float grain  = (noise2(uv * 9.0) - 0.5) * 0.10;
            float bri  = mix(0.72, 1.08, pebble) + highlight + grain;
            return float3(clamp(bri, 0.72, 1.18));
        }

        // Ores (17-20, 29): stone base + bright mineral specks in ore hue
        if (matID==17u||matID==18u||matID==19u||matID==20u||matID==29u) {
            // Stone base (same as stone but slightly tighter)
            float mot  = noise2(uv * 7.0) * 0.55 + noise2(uv * 15.0 + float2(3.1, 1.7)) * 0.45;
            float2 vd  = voronoi2(uv * 3.0 + float2(vH * 2.5, vH * 1.9));
            float crack = 1.0 - smoothstep(0.0, 0.15, vd.y - vd.x);
            float stBase = mix(0.83, 1.15, mot) - crack * 0.22;

            // Mineral specks: small bright high-frequency dots
            float speck = noise2(uv * 22.0 + float2(vH * 5.0, 1.3));
            float mineralMask = step(0.78, speck);     // only bright dots
            // Each ore gets a distinct hue push on the speck
            float3 oreHue;
            if      (matID == 17u) oreHue = float3(0.6, 0.6, 0.7);   // silver/iron
            else if (matID == 18u) oreHue = float3(0.9, 0.7, 0.3);   // gold
            else if (matID == 19u) oreHue = float3(0.5, 0.8, 0.6);   // emerald
            else if (matID == 20u) oreHue = float3(0.7, 0.5, 1.0);   // amethyst
            else                   oreHue = float3(0.5, 0.8, 0.5);   // moss ore (29)
            float3 col = float3(clamp(stBase, 0.78, 1.18));
            col = mix(col, col * oreHue * 1.35, mineralMask * 0.65);
            return clamp(col, 0.75, 1.28);
        }

        // Mossy / decorated stone (15,16): irregular organic overgrowth noise
        if (matID==15u||matID==16u) {
            float blotch = fbm2(uv * 3.5 + float2(vH * 2.0, vH * 1.5));
            float grain  = (noise2(uv * 9.0) - 0.5) * 0.12;
            float bri    = mix(0.78, 1.22, blotch) + grain;
            // Mossy green tint in the darker blotches
            float mossy  = clamp(1.0 - blotch, 0.0, 0.6) * 0.30;
            float3 col   = float3(clamp(bri, 0.78, 1.20));
            col.g       += mossy;
            return clamp(col, 0.75, 1.25);
        }

        // ---- DIRT / GRAVEL / CLAY  (2, 11, 14) --------------------------------
        if (matID==2u||matID==11u||matID==14u) {
            // Coarse speckled noise + fine grit
            float coarse = fbm2(uv * 4.0 + float2(vH * 1.5, 0.7));
            float grit   = noise2(uv * 18.0 + float2(2.2, 7.1)) * 0.5
                         + noise2(uv * 26.0 + float2(5.0, 1.3)) * 0.5;
            float pebble = step(0.72, noise2(uv * 7.0 + float2(vH * 3.0, 2.1)));  // small pebble speck
            float bri    = mix(0.80, 1.15, coarse) + (grit - 0.5) * 0.10 + pebble * 0.06;
            // Clay (14) gets a slight blue-grey desaturation
            if (matID == 14u) {
                return clamp(float3(bri * 1.00, bri * 1.00, bri * 1.04), 0.78, 1.18);
            }
            return float3(clamp(bri, 0.78, 1.18));
        }

        // ---- GRASS  (1) -------------------------------------------------------
        if (matID == 1u) {
            if (isTop) {
                // Blade-noise: fine striped pattern at high frequency, green variation
                float blades = noise2(uv * 12.0 + float2(vH * 3.0, 0.9)) * 0.60
                             + noise2(uv * 24.0 + float2(1.3, vH * 2.5)) * 0.40;
                float hue    = (noise2(uv * 5.5) - 0.5) * 0.14;  // slight yellowing
                float bri    = mix(0.85, 1.18, blades);
                float3 col   = float3(bri + hue * (-0.03), bri + hue * (-0.06), bri + hue * 0.01);
                return clamp(col, 0.78, 1.22);
            } else {
                // Side: dirt base with grassy fringe at the very top edge of the block
                float dirt = fbm2(uv * 4.5 + float2(vH * 1.5, 0.7));
                float bri  = mix(0.82, 1.12, dirt);
                // uv.y fractional position on block side: near 0 = top of block face
                float localY = fract(worldPos.y);   // 0=bottom of block, 1=top
                float fringe = smoothstep(0.70, 0.95, localY);  // green at top edge
                float blades = noise2(uv * 10.0 + float2(vH * 2.0, 1.1));
                float3 col   = float3(bri);
                // blend green grass fringe
                col.g += fringe * blades * 0.22;
                col.r -= fringe * 0.08;
                col.b -= fringe * 0.04;
                return clamp(col, 0.78, 1.22);
            }
        }

        // ---- SAND  (6) --------------------------------------------------------
        if (matID == 6u) {
            // Dune micro-ripples: two overlapping sine waves at slight angles
            float ripple1 = sin((uv.x * 0.97 + uv.y * 0.25) * 12.0) * 0.5 + 0.5;
            float ripple2 = sin((uv.x * 0.18 + uv.y * 1.02) * 7.5 + 1.3) * 0.5 + 0.5;
            float ripple  = ripple1 * 0.55 + ripple2 * 0.45;
            // Fine grain over the ripple
            float grain   = noise2(uv * 20.0 + float2(vH * 4.0, 1.7)) * 0.30
                          + noise2(uv * 10.0 + float2(2.1, vH * 2.0)) * 0.70;
            float bri     = mix(0.85, 1.14, ripple) + (grain - 0.5) * 0.08;
            return float3(clamp(bri, 0.82, 1.15));
        }

        // ---- WOOD LOGS  (21, 22) ----------------------------------------------
        if (matID==21u||matID==22u) {
            if (isTop || isBot) {
                // End grain: concentric rings centred on block centre
                float2 ctr  = fract(worldPos.xz) - 0.5;   // -0.5..0.5 relative to block
                float  r    = length(ctr);
                // Ring spacing ~0.18 world units; noise wobbles the rings
                float wobble = (noise2(ctr * 5.0 + float2(vH * 2.0, 1.1)) - 0.5) * 0.06;
                float rings  = sin((r + wobble) * 28.0) * 0.5 + 0.5;
                float grain  = noise2(uv * 14.0 + float2(vH * 3.0, 2.1)) * 0.25;
                float bri    = mix(0.82, 1.18, rings * 0.65 + grain * 0.35);
                return float3(clamp(bri, 0.80, 1.18));
            } else {
                // Side faces: vertical grain lines
                float2 grainUV = float2(uv.x, worldPos.y);   // isolate X-axis for grain
                float stripe = sin(grainUV.x * 22.0) * 0.5 + 0.5;
                float vein   = noise2(float2(grainUV.x * 5.5, grainUV.y * 2.5 + vH * 3.0));
                float knot   = (1.0 - smoothstep(0.05, 0.25, abs(noise2(grainUV * float2(2.0, 0.5) + vH) - 0.5)))
                               * 0.15;
                float bri    = mix(0.84, 1.16, stripe * 0.40 + vein * 0.60) + knot;
                return float3(clamp(bri, 0.80, 1.18));
            }
        }

        // ---- PLANKS  (4, 23) --------------------------------------------------
        if (matID==4u||matID==23u) {
            // Plank seams: vertical lines every 0.33 units on sides, horizontal on top
            float plankU   = (isSide) ? uv.x : uv.x;
            float seam     = 1.0 - step(0.93, fract(plankU * 3.0));       // dark gap at seam
            float grain    = noise2(float2(uv.x * 4.0, worldPos.y * 0.8 + vH * 2.0)) * 0.55
                           + noise2(float2(uv.x * 9.0, worldPos.y * 2.0 + vH * 1.3)) * 0.45;
            float bri      = mix(0.85, 1.15, grain) * mix(0.82, 1.0, seam);
            return float3(clamp(bri, 0.79, 1.16));
        }

        // ---- LEAVES  (5, 27) --------------------------------------------------
        if (matID==5u||matID==27u) {
            // Clustered leafy blotches: large low-freq + medium detail + fine speck
            float blotch1 = noise2(uv * 3.5 + float2(vH * 2.5, 1.1));
            float blotch2 = noise2(uv * 7.0 + float2(1.7, vH * 1.8));
            float speck   = noise2(uv * 16.0 + float2(vH * 4.0, 2.3));
            float leaf    = blotch1 * 0.50 + blotch2 * 0.35 + speck * 0.15;
            // Hue: lighter patches are yellow-green, darker are deep green
            float bri     = mix(0.78, 1.22, leaf);
            float3 col    = float3(bri);
            float yellowing = (leaf - 0.5) * 0.14;
            col.r += yellowing * 0.8;
            col.g += yellowing * 0.1;
            col.b -= yellowing * 0.5;
            return clamp(col, 0.75, 1.25);
        }

        // ---- SNOW  (12) -------------------------------------------------------
        if (matID == 12u) {
            // Base compression noise + sparkle specks (bright white)
            float base  = noise2(uv * 8.0 + float2(vH * 2.5, 1.3)) * 0.60
                        + noise2(uv * 18.0 + float2(1.7, vH * 2.0)) * 0.40;
            float spk   = step(0.88, noise2(uv * 28.0 + float2(vH * 5.0, 3.1)));  // bright specks
            float bri   = mix(0.92, 1.10, base) + spk * 0.12;
            // Sparkles are slightly blue-white
            float3 col  = float3(bri);
            col.b      += spk * 0.06;
            return clamp(col, 0.88, 1.22);
        }

        // ---- ICE  (13) --------------------------------------------------------
        if (matID == 13u) {
            // Mostly smooth with faint blue-tinted Voronoi cracks
            float2 vd   = voronoi2(uv * 2.0 + float2(vH * 1.5, 0.8));
            float crack = 1.0 - smoothstep(0.0, 0.12, vd.y - vd.x);   // 1=on crack
            // Subtle surface gloss (high-freq noise, very low amplitude)
            float gloss = noise2(uv * 22.0 + float2(vH * 3.0, 2.1));
            float bri   = 1.0 + (gloss - 0.5) * 0.06 - crack * 0.18;
            float3 col  = float3(bri);
            // Cracks push slightly blue
            col.b      += crack * 0.06;
            col.r      -= crack * 0.04;
            return clamp(col, 0.82, 1.12);
        }

        // ---- BRICKS  (8, 24) --------------------------------------------------
        if (matID==8u||matID==24u) {
            // Offset brick courses: stagger alternate rows by half a brick
            float2 brickScale = float2(2.2, 1.1);
            float2 brickUV    = uv * brickScale;
            // Row offset: even rows stagger half a brick
            float row     = floor(brickUV.y);
            float offset  = fmod(row, 2.0) * 0.5;
            float2 cell   = fract(float2(brickUV.x + offset, brickUV.y));
            // Mortar lines: thin gap at cell edges
            float mortarX = smoothstep(0.0, 0.07, cell.x) * smoothstep(0.0, 0.07, 1.0 - cell.x);
            float mortarY = smoothstep(0.0, 0.10, cell.y) * smoothstep(0.0, 0.10, 1.0 - cell.y);
            float mortar  = mortarX * mortarY;  // 1=brick, 0=mortar
            // Brick surface variation
            uint  cellID  = uint(floor(brickUV.x + offset)) * 7u + uint(floor(brickUV.y)) * 13u;
            float bGrain  = uhash(cellID + uint(matID) * 31u);
            float surf    = (noise2(uv * 8.0) - 0.5) * 0.09;
            float bri     = mix(0.68, 1.08, bGrain) * mix(0.72, 1.0, mortar) + surf;
            return float3(clamp(bri, 0.70, 1.15));
        }

        // ---- GLASS  (25, 26) --------------------------------------------------
        if (matID==25u||matID==26u) {
            // Almost featureless; faint highlight sheen band
            float sheen = noise2(uv * 3.5 + float2(vH * 2.0, 1.3));
            float bri   = 1.0 + (sheen - 0.5) * 0.06;
            return float3(clamp(bri, 0.94, 1.06));
        }

        // ---- CRAFTING TABLE (30) -----------------------------------------------
        // Wood base everywhere.  TOP face: a 3×3 crafting grid overlay + saw-blade
        // centre motif.  SIDE faces: wood grain + a narrow tool-band across the
        // middle third (y ∈ [0.30, 0.70]) with a chisel/saw silhouette.
        if (matID == 30u) {
            // Shared wood grain base (same technique as planks/logs)
            float grain  = noise2(float2(uv.x * 4.0, worldPos.y * 0.8 + vH * 2.0)) * 0.55
                         + noise2(float2(uv.x * 9.0, worldPos.y * 2.0 + vH * 1.3)) * 0.45;
            float seam   = 1.0 - step(0.93, fract(uv.x * 3.0));
            float woodBri = mix(0.85, 1.15, grain) * mix(0.82, 1.0, seam);

            if (isTop) {
                // 3×3 grid: dark lines at 1/3 and 2/3 along each axis.
                // Use worldPos projected to [0,1] within the block.
                float2 cellUV = fract(worldPos.xz);   // 0..1 within block
                float2 gridLines;
                gridLines.x = 1.0 - smoothstep(0.0, 0.05, abs(fract(cellUV.x * 3.0) - 0.5) - 0.44);
                gridLines.y = 1.0 - smoothstep(0.0, 0.05, abs(fract(cellUV.y * 3.0) - 0.5) - 0.44);
                float grid   = max(gridLines.x, gridLines.y);   // 1 = on a line

                // Saw-blade: 8-tooth starburst centred on block top.
                float2 ctr  = cellUV - 0.5;   // -0.5..0.5
                float  r    = length(ctr);
                float  ang  = atan2(ctr.y, ctr.x);
                float  teeth = cos(ang * 8.0) * 0.5 + 0.5;   // 8 teeth
                float  blade = smoothstep(0.32, 0.26, r) * smoothstep(0.10, 0.18, r)
                             * mix(0.75, 1.0, teeth);

                // Combine: wood base, darken grid lines, brighten blade
                float bri = woodBri * (1.0 - grid * 0.35) * mix(1.0, 1.18, blade);
                return float3(clamp(bri, 0.70, 1.20));
            } else {
                // Side faces: wood grain + a horizontal dark band in middle third
                // with a simple chisel-slash pattern inside the band.
                float localY = fract(worldPos.y);
                float inBand = smoothstep(0.28, 0.32, localY) * smoothstep(0.72, 0.68, localY);
                // Diagonal chisel cuts inside the band
                float chisel = sin(uv.x * 18.0 + localY * 6.0) * 0.5 + 0.5;
                float bandBri = mix(woodBri, woodBri * (0.72 + chisel * 0.20), inBand);
                return float3(clamp(bandBri, 0.70, 1.18));
            }
        }

        // ---- CHEST (31) --------------------------------------------------------
        // Wood box: SIDE faces show a lid-seam line across the upper third + a
        // metal latch clasp centred on the face.  TOP face = lid planks with a
        // clasp hinge bar across the middle.  BOTTOM = plain wood planks.
        if (matID == 31u) {
            float grain  = noise2(float2(uv.x * 4.5, worldPos.y * 0.9 + vH * 2.0)) * 0.55
                         + noise2(float2(uv.x * 10.0, worldPos.y * 2.2 + vH * 1.4)) * 0.45;
            float seam   = 1.0 - step(0.92, fract(uv.x * 2.8));
            float woodBri = mix(0.84, 1.14, grain) * mix(0.80, 1.0, seam);

            if (isTop) {
                // Lid planks + a hinge bar across the middle
                float2 lidUV = fract(worldPos.xz);
                float plankS = 1.0 - step(0.92, fract(lidUV.x * 2.5));
                float hinge  = smoothstep(0.04, 0.0, abs(lidUV.y - 0.5));   // dark line at centre
                float bri    = woodBri * mix(0.78, 1.0, plankS) * (1.0 - hinge * 0.45);
                return float3(clamp(bri, 0.72, 1.16));
            } else if (isBot) {
                return float3(clamp(woodBri, 0.78, 1.12));
            } else {
                // Side: lid seam at ~70% of height (upper third = lid)
                float localY = fract(worldPos.y);
                float lidSeam = smoothstep(0.04, 0.0, abs(localY - 0.68));   // 1 = on seam
                // Metal clasp: small rectangular bright patch at centre-bottom of lid band
                float cx  = fract(uv.x);   // 0..1 across face
                float cy  = localY;
                float claspX = smoothstep(0.04, 0.0, abs(cx - 0.5));        // centred in X
                float claspY = smoothstep(0.02, 0.0, abs(cy - 0.60));       // just below seam
                float clasp  = claspX * claspY;
                // Lid slightly brighter than body
                float lidBri  = mix(woodBri, woodBri * 1.10, step(0.68, localY));
                float bri     = lidBri * (1.0 - lidSeam * 0.40);
                // Clasp is iron-grey: pull colour toward neutral brightness
                float3 col    = float3(clamp(bri, 0.70, 1.16));
                col           = mix(col, float3(0.88), clasp * 0.70);
                return clamp(col, 0.70, 1.16);
            }
        }

        // ---- TORCH (32) --------------------------------------------------------
        // Rendered as a full block face; fake a stick + glowing tip.
        // The stick occupies the bottom 70% (dark wood); the tip is the upper 30%
        // with a bright warm glow halo.  Emissive, so the tip feeds bloom.
        if (matID == 32u) {
            float localY = fract(worldPos.y);
            float2 cx    = fract(worldPos.xz) - 0.5;   // -0.5..0.5 within block
            float  dist2 = dot(cx, cx);                  // distance^2 from block centre

            // Stick: narrow dark column
            float stickR   = 0.10;
            float onStick  = smoothstep(stickR + 0.04, stickR, sqrt(dist2)) * step(localY, 0.70);
            float stickGrain = noise2(float2(sqrt(dist2) * 6.0, localY * 8.0 + vH * 3.0));
            float stickBri = mix(0.70, 0.95, stickGrain);

            // Flame tip: bright warm blob in upper 30%, glowing halo around centre
            float inTip   = smoothstep(0.75, 0.68, localY);
            float flamePulse = noise2(float2(worldPos.x * 4.0, worldPos.z * 4.0));
            float tipGlow = exp(-dist2 * 18.0) * (1.0 + flamePulse * 0.30);
            float halo    = exp(-dist2 *  5.0) * 0.55;

            // Combine: base is dark wood, glow tip overlaid
            float3 col = float3(stickBri * onStick + 0.15);
            col = mix(col, float3(1.6, 1.1, 0.4) * (tipGlow + halo), inTip * clamp(tipGlow + halo, 0.0, 1.0));
            return clamp(col, 0.0, 2.5);   // allow HDR for the tip (emissive branch multiplies again)
        }

        // ---- OAK DOOR (33) -----------------------------------------------------
        // Planked door look: two tall panels separated by a centre rail, a top rail
        // and a bottom rail.  A round door handle on the right side near mid height.
        // All faces share the same plank grain; door geometry is on the XY or ZY face.
        if (matID == 33u) {
            float grain = noise2(float2(uv.x * 4.0, uv.y * 1.2 + vH * 2.0)) * 0.55
                        + noise2(float2(uv.x * 9.0,  uv.y * 2.8 + vH * 1.3)) * 0.45;
            float woodBri = mix(0.84, 1.14, grain);

            if (isSide) {
                // The main visible face.  uv.x = horizontal across door, uv.y = vertical.
                float lx = fract(uv.x);   // 0..1 across block width
                float ly = fract(uv.y);   // 0..1 up the block

                // Panel grooves: vertical centre rail + top/bottom rails
                float centreRail = smoothstep(0.04, 0.0, abs(lx - 0.50));    // vertical seam
                float topRail    = smoothstep(0.04, 0.0, abs(ly - 0.82));    // near top
                float bottomRail = smoothstep(0.04, 0.0, abs(ly - 0.18));    // near bottom
                float midRail    = smoothstep(0.04, 0.0, abs(ly - 0.50));    // horizontal mid
                float rails      = max(max(centreRail, topRail), max(bottomRail, midRail));

                // Panel recesses: slight darkening of the panel interior
                float inPanel = (1.0 - centreRail) * (1.0 - topRail) * (1.0 - bottomRail) * (1.0 - midRail);
                float panelShade = mix(1.0, 0.88, inPanel * 0.4);

                // Round handle: small circle on right side at 55% height
                float2 hctr = float2(lx - 0.75, ly - 0.55);
                float hDist = length(hctr);
                float handle = smoothstep(0.07, 0.04, hDist);
                float handleRing = smoothstep(0.09, 0.07, hDist) * (1.0 - smoothstep(0.04, 0.03, hDist));

                float bri = woodBri * panelShade * (1.0 - rails * 0.30);
                float3 col = float3(clamp(bri, 0.72, 1.14));
                // Handle is iron: grey-bright disc with a slightly darker ring
                col = mix(col, float3(0.90, 0.88, 0.82), handle * 0.85);
                col = mix(col, float3(0.55, 0.54, 0.52), handleRing * 0.70);
                return clamp(col, 0.70, 1.15);
            } else {
                // Top/bottom of door: just wood grain, narrow (door is thin)
                return float3(clamp(woodBri, 0.78, 1.12));
            }
        }

        // ---- BEACON BLOCK (34) -------------------------------------------------
        // A glowing energy core with concentric animated rings and crystalline
        // facet lines.  Emissive (goes HDR); patterns modulate the brightness
        // so the beacon pulses visually but still reads as a distinct shape.
        if (matID == 34u) {
            float2 ctr  = fract(worldPos.xz) - 0.5;   // -0.5..0.5 within block top/side
            if (isTop || isBot) {
                float r     = length(ctr);
                // Concentric rings that animate (pretend T via vH for static version)
                float rings  = sin(r * 22.0 - vH * 6.28) * 0.5 + 0.5;
                // Radial spokes
                float ang    = atan2(ctr.y, ctr.x);
                float spokes = pow(abs(sin(ang * 6.0)) * 0.5 + 0.5, 2.0);
                // Core glow
                float core   = exp(-r * r * 28.0);
                float bri    = mix(0.80, 1.30, rings * 0.60 + spokes * 0.40) + core * 0.50;
                // Tint: aqua-white
                return clamp(float3(bri * 0.92, bri, bri * 1.05), 0.0, 2.0);
            } else {
                // Side faces: horizontal energy bands + diagonal facets
                float ly    = fract(worldPos.y);
                float bands = sin(ly * 14.0) * 0.5 + 0.5;
                float2 side2 = fract(uv) - 0.5;
                float facets = voronoiCell(side2 + float2(vH * 2.0, 0.5), 3.0);
                float bri   = mix(0.80, 1.30, bands * 0.50 + facets * 0.50);
                return clamp(float3(bri * 0.90, bri, bri * 1.06), 0.0, 2.0);
            }
        }

        // ---- CRYSTAL LAMP (35) -------------------------------------------------
        // Glowing crystalline facets with a bright inner core. Each face shows
        // Voronoi crystal cells with bright cell-centre highlights.
        if (matID == 35u) {
            float2 crystUV = uv + float2(vH * 1.3, vH * 0.7);
            float  cell   = voronoiCell(crystUV, 4.5);
            // Fine inner sparkle
            float  sparkle = step(0.88, noise2(uv * 18.0 + float2(vH * 5.0, 2.3)));
            // Gradient from edge (dim) to centre (bright) within each cell
            float  bri    = mix(0.75, 1.45, cell) + sparkle * 0.20;
            // Purple-white crystal tint
            float3 col    = float3(bri * 0.95, bri * 0.88, bri * 1.10);
            return clamp(col, 0.0, 2.0);
        }

        // ---- GLOW BLOCK (7) ----------------------------------------------------
        // Warm amber luminous block: smooth but with subtle hexagonal cell pattern
        // so it reads as a lamp tile rather than a flat coloured block.
        if (matID == 7u) {
            float  cell   = voronoiCell(uv + float2(vH * 1.1, vH * 0.8), 3.0);
            float  grain  = noise2(uv * 8.0 + float2(vH * 2.0, 1.3)) * 0.25;
            float  bri    = mix(0.85, 1.30, cell * 0.70 + grain * 0.30);
            // Warm amber tint (yellow-orange)
            float3 col    = float3(bri * 1.05, bri * 0.92, bri * 0.55);
            return clamp(col, 0.0, 2.0);
        }

        // ---- COLOR CRYSTAL (40) ------------------------------------------------
        // Bright magenta-violet faceted crystal with high-contrast Voronoi cells
        // and angular shards. Emissive, so overbright values feed bloom.
        if (matID == 40u) {
            float2 shardUV = uv * float2(1.3, 0.9) + float2(vH * 0.9, vH * 1.4);
            float2 vd      = voronoi2(shardUV * 4.2);
            float  edge    = smoothstep(0.0, 0.18, vd.y - vd.x);   // 0=edge, 1=centre
            float  sparkle = step(0.90, noise2(uv * 22.0 + float2(vH * 4.5, 1.7)));
            float  bri     = mix(0.72, 1.50, edge) + sparkle * 0.30;
            // Magenta-violet: high R and B, modest G
            float3 col     = float3(bri * 1.05, bri * 0.60, bri * 1.10);
            return clamp(col, 0.0, 2.2);
        }

        // ---- DEFAULT: gentle value noise for anything else --------------------
        float n = noise2(uv * 5.0 + float2(vH * 2.0, 1.1));
        return float3(mix(0.88, 1.12, n));
    }

    // =========================================================
    // WIND SWAY — foliage block classification + displacement
    // =========================================================

    // Returns sway amplitude factor for a given block material id (p.material).
    //   0   = not foliage, no sway
    //   1.0 = grass/flower/tall-grass  (full sway)
    //   0.4 = leaves                   (subtle rustle)
    //   0.3 = mushroom                 (minimal, stiff cap)
    static float foliageFactor(uint matID) {
        // Only ISOLATED decorative plants sway — these are single cubes, so a
        // gentle drift reads as a plant in the breeze. Leaves (5,27) and
        // mushrooms (39) are full/connected cubes that slide apart and look like
        // they're "rotating", so they do NOT sway.
        if (matID == 36u || matID == 37u || matID == 38u) return 1.0;  // flowers, tall grass
        return 0.0;
    }

    // Shared wind-sway displacement used by BOTH vmain and shadowVmain.
    // DISABLED: foliage sway is off for now (full cube blocks slide visibly).
    // Wind uniform plumbing is kept intact; just returns zero displacement.
    // Re-enable once proper cross/billboard foliage models are in place.
    static float2 windSway(float3 worldPos, uint matID, float T, float rainStr) {
        return float2(0.0);
    }

    // =========================================================
    // SHADOW MAP — depth-only vertex shader (applies foliage sway)
    // =========================================================
    vertex float4 shadowVmain(uint vid [[vertex_id]],
                              device const PackedVertex* verts [[buffer(0)]],
                              constant ShadowVertUniforms& su [[buffer(1)]],
                              constant WindUniforms& wu [[buffer(2)]]) {
        PackedVertex p = verts[vid];
        float x = float(p.pos & 0x3f)         + float((p.pos >> 18) & 0xf) / 16.0;
        float y = float((p.pos >> 6) & 0x3f)  + float((p.pos >> 22) & 0xf) / 16.0;
        float z = float((p.pos >> 12) & 0x3f) + float((p.pos >> 26) & 0xf) / 16.0;
        float3 world = su.chunkOrigin.xyz + float3(x, y, z);
        // Apply foliage sway — same formula as vmain so shadows track geometry.
        // p.material holds the block type id; p.block holds per-vertex light level.
        float2 sway = windSway(world, uint(p.material), wu.wallClockSecs, wu.rainStrength);
        world.x += sway.x;
        world.z += sway.y;
        return su.lightViewProj * float4(world, 1.0);
    }

    // =========================================================
    // TERRAIN VERTEX SHADER (applies foliage wind sway)
    // =========================================================
    vertex VOut vmain(uint vid [[vertex_id]],
                      device const PackedVertex* verts [[buffer(0)]],
                      constant Uniforms& u [[buffer(1)]],
                      constant WindUniforms& wu [[buffer(3)]]) {
        PackedVertex p = verts[vid];
        float x = float(p.pos & 0x3f)         + float((p.pos >> 18) & 0xf) / 16.0;
        float y = float((p.pos >> 6) & 0x3f)  + float((p.pos >> 22) & 0xf) / 16.0;
        float z = float((p.pos >> 12) & 0x3f) + float((p.pos >> 26) & 0xf) / 16.0;
        float3 world = u.chunkOrigin.xyz + float3(x, y, z);
        uint n = p.normuv & 7u;

        // --- Foliage wind sway ---
        // p.material = block type id, p.block = per-vertex block light (0..15).
        float2 sway = windSway(world, uint(p.material), wu.wallClockSecs, wu.rainStrength);
        float3 swayedWorld = world + float3(sway.x, 0.0, sway.y);

        // --- AO from bits [3:5] (0=fully occluded, 3=open) ---
        float ao = float((p.normuv >> 3u) & 3u) / 3.0;
        // Smooth the AO value slightly (gamma lift to soften corners)
        ao = pow(ao, 0.85);

        // --- Lighting: sky + block + day/night (same as before) ---
        float dayB   = 0.15 + 0.85 * max(0.0, sin(u.sunDirTime.w * 3.14159265f));
        float skyC   = (float(p.sky)   / 15.0) * dayB;
        float blockC = float(p.block)  / 15.0;
        float lightLevel = max(max(skyC, blockC), 0.08);
        float facing = 0.52 + 0.48 * faceShade(n);   // stronger directional contrast (depth w/o cast shadows)
        float shade  = clamp(lightLevel * facing, 0.0, 1.0);

        VOut o;
        o.position = u.viewProj * float4(swayedWorld, 1.0);

        float3 base = materialColor(uint(p.material));
        o.color    = mix(base, base * float3(1.15, 1.02, 0.8), clamp(blockC - skyC, 0.0, 1.0));
        o.shade    = shade;
        // Bilinearly blend saturation across the chunk's 4 corner regions so the
        // grey->colour edge feathers instead of snapping on the region grid.
        {
            float fx = clamp(x / float(16), 0.0, 1.0);
            float fz = clamp(z / float(16), 0.0, 1.0);
            float s00 = u.chunkOrigin.w, s10 = u.dimSatN.x, s01 = u.dimSatN.y, s11 = u.dimSatN.z;
            o.sat = mix(mix(s00, s10, fx), mix(s01, s11, fx), fz);
        }
        o.worldPos = swayedWorld;
        o.faceNorm = n;
        o.material = uint(p.material);
        o.ao       = ao;

        // Light-space position for shadow lookup (per-vertex, interpolated).
        // lightViewProj maps world → [−1,1] clip; NDC depth is in [0,1] on Metal.
        float4 lsClip = u.lightViewProj * float4(swayedWorld, 1.0);
        o.shadowPos = lsClip;   // perspective divide done in fmain

        return o;
    }

    // =========================================================
    // PCF SHADOW LOOKUP helper
    //   shadowTex: depth32Float texture bound with a comparison sampler.
    //   shadowPos: light-clip-space float4 (w=1 for ortho, but do divide anyway).
    //   Returns 1.0 = fully lit, 0.0 = fully in shadow.
    // =========================================================
    static float sampleShadowPCF(depth2d<float, access::sample> shadowTex,
                                  sampler shadowSamp,
                                  float4 shadowPos,
                                  float dayFactor) {
        // Perspective divide (light proj is ortho so w≈1, but do it correctly).
        float3 ndc = shadowPos.xyz / shadowPos.w;
        // Metal NDC: x,y in [-1,1], z in [0,1]. Convert to shadow UV [0,1].
        float2 uv = ndc.xy * 0.5 + 0.5;
        uv.y = 1.0 - uv.y;   // Metal Y-up NDC → texture V-down
        float depth = ndc.z;   // depth already in [0,1] for Metal

        // Outside the shadow frustum? Assume lit.
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
        if (depth >= 1.0) return 1.0;

        // PCF 3×3: use the comparison sampler (lessEqual) which returns 0 or 1
        // per sample; Metal's shadow sampler averages them for free.
        float texelSize = 1.0 / 1536.0;
        float shadow = 0.0;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                float2 off = uv + float2(dx, dy) * texelSize;
                shadow += shadowTex.sample_compare(shadowSamp, off, depth);
            }
        }
        shadow /= 9.0;
        return shadow;
    }

    // =========================================================
    // TERRAIN FRAGMENT SHADER
    // =========================================================
    fragment float4 fmain(VOut in [[stage_in]],
                          constant WaterUniforms& wu [[buffer(2)]],
                          constant WindUniforms& wind [[buffer(3)]],
                          depth2d<float, access::sample> shadowTex [[texture(0)]],
                          sampler shadowSamp [[sampler(0)]]) {
        uint mat = in.material;

        // ---- Glowing blocks skip shadowing (they emit light) ----
        bool isEmissive = (mat==7u||mat==32u||mat==34u||mat==35u||mat==40u);

        // ---- Shadows ----
        // Dynamic cast-shadow maps were removed: they wobbled/swam and washed out
        // relative to the view, which read worse than no shadows. Depth now comes
        // from per-vertex AO + the directional sun term (in.shade) + sky/block
        // light, which is consistent in every direction. (A proper cascaded shadow
        // map can be reintroduced later as a dedicated task.)
        float shadowFactor = 1.0;

        // ---- AO multiplier: fold into lit colour (multiplied with shade) ----
        // ao=0 → dark corner (multiply by 0.45), ao=1 → open (multiply by 1.0)
        float aoFactor = mix(0.45, 1.0, in.ao);

        // ---- Water block special path ----
        // Water is rendered ONLY by the dedicated translucent pass (waterFmain),
        // never here in the opaque pass. Previously this branch painted water as a
        // fully opaque surface AND wrote depth, then the translucency pass blended
        // 0.55 on top of it — a double-draw that (a) double-blended the surface,
        // (b) overwrote the lake bottom so the "see-through" alpha had nothing real
        // to reveal, and (c) used a slightly different base colour, so the surface
        // read inconsistently. Discarding here keeps the lake bottom in the colour
        // buffer (and the bottom's depth), so the single translucent pass blends
        // cleanly over real terrain with no z-fighting or double-blend.
        if (mat == 9u) {
            discard_fragment();
        }

        // =========================================================
        // PLANT ALPHA-TESTED PATH (material ids 36-39)
        // The mesher emits CROSS billboards for these; we render them
        // as procedural alpha-tested shapes on the quad UV.
        // UV derivation: V = fract(worldPos.y) gives 0(bottom)..1(top);
        // U = fract of the dominant horizontal axis for this face normal.
        // =========================================================
        bool isPlant = (mat==36u||mat==37u||mat==38u||mat==39u);
        if (isPlant) {
            // Derive plant UV from worldPos: V = vertical (0=bottom, 1=top of block)
            float plantV = fract(in.worldPos.y);
            // U: use whichever horizontal axis is more "across" this face.
            // For face normals 0/1 (±X), use Z; for 4/5 (±Z), use X; for top/bot use X.
            float plantU;
            uint fn = in.faceNorm;
            if (fn == 0u || fn == 1u)      plantU = fract(in.worldPos.z);
            else if (fn == 4u || fn == 5u) plantU = fract(in.worldPos.x);
            else                            plantU = fract(in.worldPos.x);

            float alpha = 0.0;
            float3 plantCol = float3(0.0);

            if (mat == 38u) {
                // ---- TALL GRASS: soft clumpy tuft of short, rounded blades ----
                // 5 blades, each short (only fills lower 55-70% of V so there are
                // no sharp spike tips), and with wide soft-rounded tops rather than
                // tapering to a point. Blades are slightly taller/shorter individually
                // for a natural clumped look, not uniform spikes.
                float3 grassBase = float3(0.28, 0.72, 0.18);
                float bladeMask = 0.0;
                float3 hue = float3(0.0);
                // cx=centre, topV=where the blade ends (0.55-0.70), roundR=top-round radius
                const float centres[5] = {0.12, 0.30, 0.50, 0.68, 0.85};
                const float topVs[5]   = {0.62, 0.68, 0.58, 0.65, 0.60};  // shorter than 1.0!
                const float hues[5]    = {0.04, -0.03, 0.05, -0.04, 0.02};
                for (int bi = 0; bi < 5; ++bi) {
                    float cx    = centres[bi];
                    float topV  = topVs[bi];
                    // Width: 0.07 at base, narrows slightly but stays wider than before
                    float bladeWidth = 0.065 * (0.6 + 0.4 * (1.0 - plantV / topV));
                    bladeWidth = max(bladeWidth, 0.012);
                    float dx = abs(plantU - cx);
                    // Only active in [0, topV] vertical range
                    float inRange = smoothstep(0.0, 0.05, plantV)        // fade in at base
                                  * smoothstep(topV + 0.04, topV - 0.01, plantV);  // fade out at top
                    // Round the tip: use a soft circle cap near topV
                    float2 tipDiff = float2(plantU - cx, plantV - (topV - 0.06));
                    float tipDist  = length(tipDiff * float2(1.0 / 0.08, 1.0 / 0.08));
                    float tipCap   = smoothstep(1.0, 0.5, tipDist);  // soft rounded top
                    // Body mask: within blade width OR within rounded cap
                    float bodyMask = smoothstep(bladeWidth + 0.015, bladeWidth, dx) * inRange;
                    float inBlade  = max(bodyMask, tipCap * inRange);
                    if (inBlade > bladeMask) {
                        bladeMask = inBlade;
                        hue = float3(-hues[bi]*0.5, hues[bi], -hues[bi]*0.3);
                    }
                }
                alpha = bladeMask;
                plantCol = clamp(grassBase + hue, 0.0, 1.0);
                // Apply gentle lighting: mostly ambient (bright) with a little shade
                float lightMix = mix(0.55, 1.0, in.shade);
                plantCol *= lightMix;

            } else if (mat == 36u || mat == 37u) {
                // ---- FLOWER (red 36 / yellow 37) ----
                float3 stemCol   = float3(0.22, 0.60, 0.14);
                float3 bloomCol  = (mat == 36u) ? float3(0.92, 0.12, 0.12)
                                                : float3(1.00, 0.90, 0.08);

                // Stem: thin vertical strip in the middle, lower 60% of V
                float stemMask = 0.0;
                {
                    float dx = abs(plantU - 0.50);
                    float inStem = smoothstep(0.035, 0.018, dx);
                    float stemRange = smoothstep(0.0, 0.04, plantV)
                                    * smoothstep(0.62, 0.56, plantV);
                    stemMask = inStem * stemRange;
                }

                // Bloom: cluster of petals at top (V > 0.55)
                // 5 petals around the centre at radius 0.14, plus a centre disc
                float bloomMask = 0.0;
                {
                    float bloomV = smoothstep(0.55, 0.60, plantV);
                    // Centre disc
                    float2 ctr = float2(plantU - 0.50, plantV - 0.78);
                    float centreD = length(ctr);
                    float centreMask = smoothstep(0.12, 0.06, centreD);
                    // 5 petals
                    float petalMask = 0.0;
                    for (int pi = 0; pi < 5; ++pi) {
                        float angle = float(pi) * (6.2831853 / 5.0);
                        float2 pCtr = float2(cos(angle) * 0.14, sin(angle) * 0.10) + float2(0.50, 0.78);
                        float pd = length(float2(plantU, plantV) - pCtr);
                        petalMask = max(petalMask, smoothstep(0.10, 0.04, pd));
                    }
                    bloomMask = max(centreMask, petalMask) * bloomV;
                }

                alpha = max(stemMask, bloomMask);
                plantCol = (bloomMask > stemMask) ? bloomCol : stemCol;
                float lightMix = mix(0.70, 1.0, in.shade);
                plantCol *= lightMix;

            } else if (mat == 39u) {
                // ---- MUSHROOM: short pale stem + domed red cap with speckles ----
                float3 stemCol = float3(0.88, 0.84, 0.76);
                float3 capCol  = float3(0.88, 0.14, 0.10);

                // Stem: narrow, lower 40% of height
                float stemMask = 0.0;
                {
                    float dx = abs(plantU - 0.50);
                    float inStem = smoothstep(0.045, 0.022, dx);
                    float stemRange = smoothstep(0.0, 0.04, plantV)
                                    * smoothstep(0.42, 0.36, plantV);
                    stemMask = inStem * stemRange;
                }

                // Cap: dome shape, upper 50% of height
                float capMask = 0.0;
                {
                    // Dome: circular cross-section, centred at (0.5, 0.70)
                    float2 ctr = float2(plantU - 0.50, plantV - 0.68);
                    // Scale Y so the dome is wider than tall
                    float2 scaled = float2(ctr.x * 1.0, ctr.y * 1.8);
                    float d = length(scaled);
                    capMask = smoothstep(0.34, 0.26, d)
                            * smoothstep(0.38, 0.42, plantV);  // only upper half
                    // White speckles on cap
                    float speckN = step(0.80, noise2(float2(plantU, plantV) * 14.0));
                    capMask = max(capMask, capMask * speckN * 0.0);   // mask stays same for alpha
                }

                alpha = max(stemMask, capMask);
                if (capMask > stemMask) {
                    // Speckle colouring on cap
                    float speckN = step(0.80, noise2(float2(plantU, plantV) * 14.0));
                    plantCol = mix(capCol, float3(0.95, 0.90, 0.85), speckN * 0.55);
                } else {
                    plantCol = stemCol;
                }
                float lightMix = mix(0.65, 0.95, in.shade);
                plantCol *= lightMix;
            }

            // Alpha test: discard background quads
            if (alpha < 0.5) discard_fragment();

            // Dim desaturation (match normal block path)
            float lumP = dot(plantCol, float3(0.299, 0.587, 0.114));
            plantCol = mix(float3(lumP), plantCol, clamp(in.sat, 0.0, 1.0));
            return float4(plantCol, 1.0);
        }

        // ---- Standard block path ----
        float3 detail = blockDetail(in.worldPos, in.faceNorm, in.material);

        // ---- Fake bump / normal perturbation from procedural height -----------
        // Derive a small per-fragment normal offset from finite-differencing the
        // same noise used by blockDetail so bumps are correlated with visible texture.
        // Only applies the bump to the sun (directional) lighting term, not AO/shadow,
        // keeping the effect subtle and tasteful.
        // Skip on emissive and water (they have their own shading).
        // FIX (#7): bumpStrength clamped so shade*bump never exceeds 1.0 on a
        // normally-lit face. The old clamp(sunTilt, 0.78, 1.22) allowed the bump
        // to push HDR output above 1.0, causing view-dependent bloom wash-out.
        // New: sunTilt capped at 1.0 so the bump can only darken, never brighten.
        float bumpLight = 1.0;
        {
            const float eps = 0.06;   // finite-difference step in world units
            float2 uv0 = faceUV(in.worldPos, in.faceNorm);
            float h00 = noise2(uv0 * 7.5);
            float h10 = noise2((uv0 + float2(eps, 0.0)) * 7.5);
            float h01 = noise2((uv0 + float2(0.0, eps)) * 7.5);
            float dHdX = (h10 - h00) / eps;
            float dHdY = (h01 - h00) / eps;
            // bumpStrength reduced to 0.06 (was 0.09) so the perturbation stays subtle.
            // sunTilt clamped to [0.82, 1.00] — bump can darken corners but never
            // pushes lit surfaces above 1.0 HDR, preventing bloom wash-out.
            float bumpStrength = 0.06;
            float sunTilt = clamp(1.0 - (dHdX + dHdY) * bumpStrength, 0.82, 1.00);
            bumpLight = (in.faceNorm == 3u) ? 1.0 : sunTilt;
        }

        // Combined: shade * AO * shadow * bump * detail
        // FIX (#7): clamp pre-bloom output to 1.0 for non-emissive blocks so
        // ordinary sunlit terrain never crosses the bloom bright-pass threshold.
        // Emissive blocks are still allowed to go overbright (they SHOULD bloom).
        float3 col = in.color * detail * (in.shade * bumpLight) * aoFactor * shadowFactor;
        if (!isEmissive) col = clamp(col, 0.0, 1.0);

        // Emissive blocks bloom in HDR: push them above 1.0
        if (isEmissive) {
            col *= 1.6;   // HDR overbright → bloom
        }

        // Dim desaturation
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(lum), col, clamp(in.sat, 0.0, 1.0));

        // --- Rain wet-darkening: top faces darken + desaturate slightly in rain ---
        if (wind.rainStrength > 0.01 && !isEmissive) {
            float topFace = (in.faceNorm == 2u) ? 1.0 : 0.3;   // mostly top faces
            // Wet surfaces: darken by ~15% at full rain, slight blue push
            float wetDark = 1.0 - wind.rainStrength * 0.15 * topFace;
            float3 wetTint = float3(0.96, 0.98, 1.02);          // faint cool tone
            col *= wetDark;
            col = mix(col, col * wetTint, wind.rainStrength * 0.35 * topFace);
        }

        // Underwater distance fog
        // FIX (#10): Gentler in-water fog so nearby blocks are clearly visible.
        // k = 0.030 gives ~63% scene colour at 15 blocks and ~55% at 20 blocks.
        // Additionally, smoothstep ramp means blocks 0-4 blocks away have near-zero
        // fog tint; tint builds gradually beyond that. This ensures walls, floor,
        // and ledges directly around the player are clearly readable.
        if (wu.underwater > 0.5) {
            // Flatten directional lighting underwater. Above water, `col` carries the
            // full sun term (in.shade) + bump, which makes a submerged wall flip
            // between bright/dim depending on which way the face points relative to
            // the sun — reading as inconsistent tint/dimming as you look around.
            // Underwater, light is scattered and effectively ambient, so blend the
            // lit colour heavily toward an AO-only flat version: the depth tint then
            // varies only with DISTANCE, never with face direction or view angle.
            // (AO is kept so concave corners still read; sun direction is dropped.)
            float3 flatCol = in.color * detail * aoFactor;   // no in.shade / bump
            if (!isEmissive) flatCol = clamp(flatCol, 0.0, 1.0);
            float flatLum = dot(flatCol, float3(0.299, 0.587, 0.114));
            flatCol = mix(float3(flatLum), flatCol, clamp(in.sat, 0.0, 1.0));
            col = mix(col, flatCol, 0.80);

            float dist = length(in.worldPos - UW_CAM_POS(wu));
            // FIX (#1): The submerged-SOLID fog was over-tinting the lake bottom:
            // at a grazing view the far part of a sandy floor sits 30-50 blocks
            // away, where exp(-0.030*dist) drove fogFactor down to ~0.3, blending
            // the sand ~70% toward WATER_FOG_COL — it blued out completely and
            // vanished into the water while the kelp (lit separately) stayed
            // visible. Two changes keep the bottom readable as SAND, just tinted:
            //   - Gentler coefficient (0.030 -> 0.018) so tint builds far slower
            //     with distance (e.g. at 30 blocks ~58% scene, was ~41%).
            //   - Floor the fog so a submerged solid is NEVER blended more than
            //     45% toward the fog colour. The base albedo always shows through,
            //     so sand stays sandy (just blue-tinted), never a flat blue wall.
            float rawFog = exp(-0.018 * dist);
            // Ramp: no tint at all within 4 blocks; smoothly add fog beyond that.
            float ramp = smoothstep(4.0, 14.0, dist);
            float fogFactor = clamp(mix(1.0, rawFog, ramp), 0.0, 1.0);
            // Keep at least 55% of the surface's own albedo at any distance so the
            // material (sand/dirt/stone) always stays distinguishable from water.
            fogFactor = max(fogFactor, 0.55);
            // Same colour the full-screen overlay uses (WATER_FOG_COL) so the
            // submerged-solid tint and the water volume read as one body of water.
            col = mix(WATER_FOG_COL, col, fogFactor);
        } else {
            // Atmospheric distance fog: fade distant terrain toward the horizon sky colour
            // so the far edge of the render distance (16 chunks = 256 blocks) reads as
            // haze rather than a hard pop-in cut. Nearby terrain (< ~40 blocks) is clear.
            // Exponential fog: fogFactor = exp(-k * dist). k = 0.010 gives:
            //   20 blocks → ~82% scene, 80 blocks → ~45%, 180 blocks → ~16%.
            // The horizon sky colour approximates a mid-morning blue-grey haze.
            // Only the FAR EDGE hazes (hides pop-in); the visible field stays clear
            // so open/flat biomes like desert don't wash to white. Capped at 0.5
            // so it can never fully white out, ever.
            float3 camPos3 = UW_CAM_POS(wu);
            float dist = length(in.worldPos - camPos3);
            float fog = smoothstep(150.0, 270.0, dist) * 0.5;
            float3 horizFogColor = float3(0.42, 0.55, 0.72);   // muted blue haze
            col = mix(col, horizFogColor, fog);
        }

        return float4(col, 1.0);
    }

    // =========================================================
    // WATER TRANSLUCENCY FRAGMENT SHADER
    // Same vertex shader as terrain (vmain). Discards any fragment whose material
    // is not 9 (water) so only water surfaces are drawn. Outputs alpha 0.55 for
    // translucent blending over the lake bottom already in the colour buffer.
    // Depth write is OFF (set by waterDepthState), depth test is lessEqual.
    // =========================================================
    fragment float4 waterFmain(VOut in [[stage_in]],
                               constant WaterUniforms& wu [[buffer(2)]],
                               constant WindUniforms& wind [[buffer(3)]],
                               depth2d<float, access::sample> shadowTex [[texture(0)]],
                               sampler shadowSamp [[sampler(0)]]) {
        // Only render water (material id 9); discard all other blocks.
        if (in.material != 9u) discard_fragment();

        float t = wu.wallClockSecs;
        float2 uv = in.worldPos.xz;
        float wave1 = noise2(uv * 0.8  + float2( t * 0.22,  t * 0.14));
        float wave2 = noise2(uv * 1.40 + float2(-t * 0.17,  t * 0.28));
        float wave3 = noise2(uv * 2.80 + float2( t * 0.35, -t * 0.19));
        float ripple = wave1 * 0.50 + wave2 * 0.35 + wave3 * 0.15;
        float rippleN = ripple * 2.0 - 1.0;

        // Single shared base colour (WATER_SURFACE_COL) so the surface always
        // matches the submerged-solid tint and the underwater overlay.
        float3 waterBase = WATER_SURFACE_COL;

        // Normal perturbation for specular
        float2 nAB = float2(
            noise2(uv * 1.2 + float2(t * 0.22 + 0.1, t * 0.14)) - wave1,
            noise2(uv * 1.2 + float2(t * 0.22, t * 0.14 + 0.1)) - wave1
        ) * 4.0;
        float3 perturbedN = normalize(float3(nAB.x, 1.4, nAB.y));
        float3 sunDir3 = normalize(float3(0.5, 0.9, 0.3));
        float spec = pow(max(0.0, dot(perturbedN, sunDir3)), 22.0);

        // Shadow + AO
        float aoFactor = mix(0.45, 1.0, in.ao);
        float dayFactor = clamp(in.shade * 1.5, 0.0, 1.0);
        float rawShadow = sampleShadowPCF(shadowTex, shadowSamp, in.shadowPos, dayFactor);
        float shadowStrength = 0.65 * dayFactor;
        float shadowFactor = 1.0 - shadowStrength * (1.0 - rawShadow);

        float3 col = waterBase * in.shade * aoFactor * shadowFactor;
        col *= 1.0 + rippleN * 0.18;

        // Surface highlights (sky reflection + sun specular) belong ONLY on the
        // top face. On side faces the old fresnelBias (0.06) still pushed a cool
        // brightening that, combined with cull-none double-sided side quads, made
        // edges flip/shimmer at grazing angles. Gate both highlight terms to the
        // up-facing surface so side faces stay a flat, stable water colour.
        bool topFace = (in.faceNorm == 2u);
        if (topFace) {
            float fresnelAmt = 0.28 + rippleN * 0.10;
            col = mix(col, float3(0.80, 0.92, 1.00), clamp(fresnelAmt, 0.0, 0.40));
            col += float3(1.0, 0.98, 0.88) * spec * 0.45 * in.shade;
        }

        // Saturation
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(lum), col, clamp(in.sat, 0.0, 1.0));
        col = clamp(col, 0.0, 1.0);

        // Alpha is constant per face orientation only (never view-angle dependent),
        // so the surface never vanishes at grazing angles and never double-blends
        // unevenly. Top face slightly more opaque (you mostly look down through it);
        // side faces a touch more see-through so shorelines read cleanly.
        // FIX (#1): Lowered (top 0.58 -> 0.42, side 0.50 -> 0.38) so the sandy
        // lake bottom is clearly visible THROUGH the surface from above instead of
        // being hidden behind a near-opaque blue sheet. The surface still reads as
        // water (colour + specular + fresnel on the top face) but no longer stacks
        // a heavy blue layer on top of the (now-readable) submerged terrain.
        float alpha = topFace ? 0.42 : 0.38;
        return float4(col, alpha);
    }

    // =========================================================
    // SKY PASS — fullscreen triangle, no depth write
    // =========================================================
    struct SkyUniforms {
        float4 sunDirTime;
        float4 camRight;
        float4 camUp;
        float4 camFwd;
    };
    struct SkyVOut { float4 position [[position]]; float2 ndc; };

    vertex SkyVOut skyVmain(uint vid [[vertex_id]],
                            constant SkyUniforms& su [[buffer(0)]]) {
        float2 pos;
        if      (vid == 0u) pos = float2(-1.0, -1.0);
        else if (vid == 1u) pos = float2( 3.0, -1.0);
        else                pos = float2(-1.0,  3.0);
        SkyVOut o;
        o.position = float4(pos, 0.9999, 1.0);
        o.ndc      = pos;
        return o;
    }

    static float cloudFbm(float2 p) { return fbm2(p); }

    fragment float4 skyFmain(SkyVOut in [[stage_in]],
                              constant SkyUniforms& su [[buffer(0)]],
                              constant WaterUniforms& wu [[buffer(1)]]) {
        float t   = su.sunDirTime.w;
        float3 sd = su.sunDirTime.xyz;
        float clk = wu.wallClockSecs;

        float tanHalfFov = su.camRight.w;
        float aspect     = su.camUp.w;
        float3 right     = su.camRight.xyz;
        float3 up        = su.camUp.xyz;
        float3 fwd       = su.camFwd.xyz;
        float3 ray = normalize(fwd
                               + right * (in.ndc.x * aspect * tanHalfFov)
                               + up    * (in.ndc.y * tanHalfFov));

        float dayT    = max(0.0, sin(t * 3.14159265f));
        float dawnT   = max(0.0, 1.0 - abs(t - 0.25) * 8.0);
        float duskT   = max(0.0, 1.0 - abs(t - 0.75) * 8.0);
        float sunsetT = dawnT + duskT;

        float3 zenithDay    = float3(0.16, 0.42, 0.88);
        float3 horizDay     = float3(0.58, 0.76, 0.92);   // warmer horizon (less cold-grey)
        float3 zenithSunset = float3(0.22, 0.14, 0.45);
        float3 horizSunset  = float3(1.00, 0.52, 0.18);
        float3 zenithNight  = float3(0.03, 0.04, 0.12);
        float3 horizNight   = float3(0.08, 0.10, 0.22);

        float3 zenith = mix(mix(zenithNight, zenithDay, dayT), zenithSunset, sunsetT * 0.7);
        float3 horiz  = mix(mix(horizNight,  horizDay,  dayT), horizSunset,  sunsetT * 0.85);

        float gradT  = smoothstep(0.0, 0.45, ray.y);
        float3 skyCol = mix(horiz, zenith, gradT);

        float3 groundCol = mix(float3(0.20, 0.16, 0.12), float3(0.35, 0.30, 0.22), dayT);
        skyCol = mix(groundCol, skyCol, smoothstep(-0.05, 0.08, ray.y));

        float horizBand = exp(-abs(ray.y) * 12.0);
        float3 hazeCol = mix(float3(0.62, 0.74, 0.92), float3(1.00, 0.70, 0.40), sunsetT * 0.7);
        skyCol = mix(skyCol, hazeCol, horizBand * 0.18 * dayT + horizBand * 0.25 * sunsetT);

        float3 sunDir3 = normalize(-sd);
        float sunDot = dot(ray, sunDir3);
        // FIX (#33, 2nd pass): SHRINK the disc. sunDisc/sunInner are now both
        // tighter than before so the visible sun is a small dot, not a wide blob.
        //   sunDisc:  smoothstep(0.9988,1.0) → ~2.8° half-angle (was 0.9975 / ~4°)
        //   sunInner: smoothstep(0.9996,1.0) → ~1.6° half-angle (was 0.9992 / ~2.3°)
        float sunDisc  = smoothstep(0.9988, 1.0000, sunDot);
        float sunInner = smoothstep(0.9996, 1.0000, sunDot);
        // FIX (#33): The washout when turning was direction-dependent — it only
        // happened when the view looked toward the sun's azimuth (E/W/diagonal,
        // since the sun arcs East-West). Facing N/S kept the sun off-frame so the
        // glow terms were ~0 and the scene looked fine.
        //
        // The remaining culprit after the 1st pass (capping broad sky to 0.92) was
        // the SUN DISC HDR: `discHDR` was ADDED AFTER the 0.92 cap and reached ~1.5
        // HDR — sitting right at the bloom bright-pass foot (smoothstep 1.60..2.80),
        // so when the sun was in frame its disc fed the bloom blur and smeared a
        // bright halo across the screen = washout. Facing N/S the disc was off-frame
        // so nothing bloomed.
        //
        // This pass: (1) shrink the disc (above); (2) DIM the glow cones further so
        // even the near-disc region stays modest; (3) lower the disc HDR so its peak
        // stays comfortably BELOW the bloom threshold (target ≤ ~1.25 vs 1.60 floor)
        // — a small bright sun that does NOT bloom; (4) keep the hard 0.92 cap on the
        // entire broad sky. Net: no sunDot-gated term can flood the frame, and the
        // disc no longer crosses the bright-pass threshold.
        float sunGlow1 = smoothstep(0.994,  1.0000, sunDot) * 0.035 * max(dayT, sunsetT * 0.5);  // dimmer + tighter (was 0.992/0.05)
        float sunGlow2 = smoothstep(0.998,  1.0000, sunDot) * 0.05  * max(dayT, sunsetT * 0.5);  // dimmer + tighter (was 0.997/0.08)
        float3 sunColor  = mix(float3(1.0, 0.72, 0.35), float3(1.0, 0.98, 0.85), dayT);
        float3 sunCorona = sunColor;
        float sunVis = max(dayT, sunsetT * 0.6);
        skyCol += sunGlow1 * sunCorona;
        skyCol += sunGlow2 * sunCorona;
        skyCol = mix(skyCol, sunColor,          sunDisc  * sunVis);
        skyCol = mix(skyCol, float3(1.0, 1.0, 0.96), sunInner * sunVis);

        // HDR: a SMALL boost on the tight inner disc so the sun reads as a crisp
        // bright dot — but kept BELOW the bloom bright-pass floor (1.60). Under
        // sunInner=1 the skyCol is already ~1.0 (mixed to near-white above); adding
        // 0.22 gives a disc peak of ~1.22 HDR < 1.60, so the disc no longer feeds
        // bloom. discHDR is gated on the TIGHT sunInner disc only, so this never
        // touches the broad sky.
        float3 discHDR = sunColor * 0.22 * sunInner * sunVis;   // was *0.5 (peaked ~1.5, fed bloom)
        skyCol += discHDR;

        // FIX (#33): Hard-cap EVERYTHING — including the disc HDR — to ≤1.25. This
        // guarantees no view direction (broad sky capped to 0.92 below; disc capped
        // to 1.25 here) can ever cross the 1.60 bloom threshold or reach the ACES
        // white point, so facing the sun reads the same exposure as facing N/S.
        // The broad sky (everything except the tight disc) is still pinned at ≤0.92.
        skyCol = clamp(skyCol - discHDR, 0.0, 0.92) + discHDR;
        skyCol = min(skyCol, float3(1.25));

        float3 moonDir3 = -sunDir3;
        float moonDot  = dot(ray, moonDir3);
        float moonDisc = smoothstep(0.9990, 1.000, moonDot) * (1.0 - dayT) * 0.9;
        skyCol = mix(skyCol, float3(0.90, 0.92, 1.00), moonDisc);

        if (dayT < 0.5) {
            float starFade = 1.0 - smoothstep(0.05, 0.35, dayT);
            // Only render stars well above the horizon — the perspective division
            // ray.xz/ray.y blows up at low elevation and produces long streaks.
            float starElev = smoothstep(0.10, 0.22, ray.y);  // zero below 10° elevation
            starFade *= starElev;
            if (starFade > 0.001) {
                // Project onto a flat sky dome: UV is stable for ray.y > 0.10.
                float2 starUV = floor((ray.xz / max(ray.y, 0.10)) * 60.0 + float2(200.0));
                // Hash must not mix x*y (that produces visible diagonal streaks).
                float starH = uhash(uint(starUV.x + 5000.0) * 3141u
                                    ^ uint(starUV.y + 5000.0) * 1618u);
                float starBright = step(0.986, starH);
                skyCol += float3(starBright * starFade * 0.90);
            }
        }

        float weatherCycle = sin(clk * (3.14159265f / 150.0f)) * 0.5f + 0.5f;
        float overcast = smoothstep(0.52, 0.80, weatherCycle) * 0.65;
        float rainStrength = smoothstep(0.60, 0.82, weatherCycle);

        if (overcast > 0.01) {
            float cloudPlaneHit = (ray.y > 0.02) ? (1.0 / ray.y) : 0.0;
            float2 ocUV = ray.xz * cloudPlaneHit * 0.35 + float2(clk * 0.006, clk * 0.003);
            float ocCloud = cloudFbm(ocUV * 1.5);
            // Storm clouds: thicker, darker underbellies when raining
            float stormDark = mix(0.55, 0.35, rainStrength);
            float stormBright = mix(0.80, 0.62, rainStrength);
            ocCloud = smoothstep(0.38 - rainStrength * 0.08, 0.62, ocCloud);
            float3 ocColor = mix(float3(stormDark, stormDark + 0.02, stormDark + 0.09),
                                 float3(stormBright, stormBright + 0.02, stormBright + 0.06),
                                 dayT);
            float ocFade = smoothstep(0.0, 0.12, ray.y);
            skyCol = mix(skyCol, ocColor, ocCloud * overcast * ocFade);
        }

        // Lightning: rare (appears ~every 45s during storm), brief full-sky flash.
        if (rainStrength > 0.5) {
            // Use a sawtooth phase in seconds, trigger a flash near the top.
            float ltPhase = fmod(clk * (1.0 / 45.0), 1.0);
            float ltFlash = smoothstep(0.97, 0.99, ltPhase) * smoothstep(1.00, 0.99, ltPhase);
            // Only light the sky-facing rays (not ground)
            ltFlash *= smoothstep(0.0, 0.15, ray.y);
            float ltAmp = rainStrength * ltFlash * 2.5;
            skyCol = mix(skyCol, float3(0.88, 0.92, 1.00), ltAmp);
        }

        // Rain/snow precipitation is now rendered as animated screen-space
        // streaks/flakes in the composite pass — not here in the sky.
        // (Kept the overcast / storm-cloud darkening above, which correctly
        //  dims the sky during rain; the actual falling precipitation is
        //  composited on top of the final LDR image for cheapness.)

        float fairCloud = clamp(1.0 - overcast * 1.6, 0.0, 1.0);
        float cloudVis  = smoothstep(0.12, 0.38, dayT)
                        * smoothstep(0.0, 0.10, ray.y)
                        * fairCloud;
        if (cloudVis > 0.001) {
            float ry = max(ray.y, 0.02);
            float2 cloudUV  = (ray.xz / ry) * 0.30 + float2(clk * 0.010,  clk * 0.004);
            float2 cloudUV2 = (ray.xz / ry) * 0.18 + float2(-clk * 0.007, clk * 0.003);
            float cloud  = cloudFbm(cloudUV);
            float cloud2 = cloudFbm(cloudUV2);
            float cloudD = smoothstep(0.48, 0.70, (cloud + cloud2 * 0.5) / 1.5);
            float3 cloudTop  = mix(float3(0.96, 0.96, 1.00),
                                   mix(float3(1.0, 0.82, 0.65), float3(0.96, 0.96, 1.0), dayT),
                                   sunsetT * 0.60);
            float underBelly = smoothstep(0.06, 0.35, ray.y);
            float3 cloudCol  = mix(cloudTop * float3(0.72, 0.73, 0.80), cloudTop, underBelly);
            skyCol = mix(skyCol, cloudCol, cloudD * cloudVis * 0.90);
        }

        return float4(skyCol, 1.0);
    }

    // =========================================================
    // UNDERWATER POST PASS — unchanged
    // =========================================================
    struct UWVOut { float4 position [[position]]; float2 uv; };

    vertex UWVOut underwaterVmain(uint vid [[vertex_id]],
                                  constant WaterUniforms& wu [[buffer(0)]]) {
        float2 pos;
        if      (vid == 0u) pos = float2(-1.0, -1.0);
        else if (vid == 1u) pos = float2( 3.0, -1.0);
        else                pos = float2(-1.0,  3.0);
        UWVOut o;
        o.position = float4(pos, 0.0, 1.0);
        o.uv = pos * 0.5 + 0.5;
        return o;
    }

    // FIX (#4 / #5): Underwater overlay is a FULLY STEADY light blue tint.
    // Alpha is constant (no per-frame or per-view variation) so there is zero
    // fuzziness or inconsistency frame-to-frame. Caustic patterns only affect
    // the colour (a subtle brightness shimmer), NEVER the alpha — that prevents
    // the flickering/fuzziness while still giving life to the water.
    // Terrain distance fog in fmain (exp(-0.046*dist)) handles depth-based
    // visibility (~15-20 block range) independently of this overlay.
    fragment float4 underwaterFmain(UWVOut in [[stage_in]],
                                    constant WaterUniforms& wu [[buffer(0)]]) {
        float uw = wu.underwater;
        if (uw < 0.01) { discard_fragment(); }
        float t = wu.wallClockSecs;
        // Caustic shimmer: only modulates colour, not alpha.
        float2 cUV1 = in.uv * float2(3.0, 2.5) + float2(t * 0.08, t * 0.05);
        float2 cUV2 = in.uv * float2(2.2, 3.1) + float2(-t * 0.06, t * 0.09);
        float caustic = noise2(cUV1) * 0.6 + noise2(cUV2) * 0.4;
        caustic = smoothstep(0.55, 0.80, caustic) * 0.08;   // very subtle
        // Same colour the in-water distance fog fades toward (WATER_FOG_COL) so the
        // full-screen overlay and the submerged-solid tint are the SAME blue — no
        // strobing/mismatch between the water volume and the tinted surfaces.
        float3 uwColor = WATER_FOG_COL;
        float3 col = uwColor + float3(caustic * 0.4, caustic * 0.6, caustic * 0.3);
        // Constant alpha — no variation of any kind.
        // FIX (#10): Reduced from 0.16 to 0.08 so the post-pass overlay is a
        // light blue wash rather than a blue wall. Nearby terrain blocks remain
        // clearly readable through the tint; depth-based fade in fmain handles
        // far-distance blue-out independently.
        float totalAlpha = 0.08 * clamp(uw, 0.0, 1.0);
        return float4(col, totalAlpha);
    }

    // =========================================================
    // SHARED FULLSCREEN VERTEX SHADER (bloom + composite)
    // =========================================================
    struct FSVOut { float4 position [[position]]; float2 uv; };

    vertex FSVOut fullscreenVert(uint vid [[vertex_id]]) {
        float2 pos;
        if      (vid == 0u) pos = float2(-1.0, -1.0);
        else if (vid == 1u) pos = float2( 3.0, -1.0);
        else                pos = float2(-1.0,  3.0);
        FSVOut o;
        o.position = float4(pos, 0.0, 1.0);
        // UV: Metal (0,0) top-left, NDC (-1,-1) bottom-left
        o.uv = pos * float2(0.5, -0.5) + 0.5;
        return o;
    }

    // =========================================================
    // BLOOM — bright-pass: extract luminance > threshold into half-res
    // =========================================================
    fragment float4 bloomBrightFrag(FSVOut in [[stage_in]],
                                    texture2d<float> hdrTex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = hdrTex.sample(s, in.uv);
        // Raised threshold: daytime sky sits around 0.7-1.1 HDR (broad region).
        // We must NOT let the sky into bloom — only the sun disc and emissive blocks
        // (fireflies, glow blocks) are legitimately overbright at 1.6+.
        // Old threshold (1.15) caught the entire daytime sky, smearing it across the
        // frame when the camera rotated upward. New lower bound = 1.6, full at 2.8
        // so only the sun disc (~1.1 * sunVis boost) and HDR emissives (1.6x mult)
        // actually bloom.  This eliminates the sky-rotation washout.
        float lum = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
        float bright = smoothstep(1.60, 2.80, lum);   // only true HDR highlights bloom
        return float4(c.rgb * bright, 1.0);
    }

    // =========================================================
    // BLOOM — separable 9-tap Gaussian (σ≈2)
    //   H pass: blur horizontally; V pass: blur vertically.
    //   Weights: [0.0625, 0.125, 0.25, 0.25, 0.25, ...] → use a 9-tap kernel.
    // =========================================================
    constant float kGaussWeights[5] = { 0.2270270270, 0.1945945946, 0.1216216216,
                                         0.0540540541, 0.0162162162 };

    fragment float4 bloomBlurHFrag(FSVOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 texelSize = 1.0 / float2(src.get_width(), src.get_height());
        float3 result = src.sample(s, in.uv).rgb * kGaussWeights[0];
        for (int i = 1; i < 5; ++i) {
            float off = float(i) * texelSize.x;
            result += src.sample(s, in.uv + float2( off, 0.0)).rgb * kGaussWeights[i];
            result += src.sample(s, in.uv + float2(-off, 0.0)).rgb * kGaussWeights[i];
        }
        return float4(result, 1.0);
    }

    fragment float4 bloomBlurVFrag(FSVOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 texelSize = 1.0 / float2(src.get_width(), src.get_height());
        float3 result = src.sample(s, in.uv).rgb * kGaussWeights[0];
        for (int i = 1; i < 5; ++i) {
            float off = float(i) * texelSize.y;
            result += src.sample(s, in.uv + float2(0.0,  off)).rgb * kGaussWeights[i];
            result += src.sample(s, in.uv + float2(0.0, -off)).rgb * kGaussWeights[i];
        }
        return float4(result, 1.0);
    }

    // =========================================================
    // COMPOSITE — ACES filmic tone-mapping + colour grade + vignette
    //             + animated precipitation overlay (rain streaks / snow flakes)
    //   Reads HDR scene (rgba16Float) + bloom texture, writes LDR bgra8.
    //   hdrTex is at the capped internal resolution; the bilinear sampler
    //   upscales it to the full drawable naturally.
    // =========================================================

    // (PostUniforms defined once at the top of the shader — see TERRAIN STRUCTS section)

    // ACES fitted curve (Narkowicz 2015, single-pass approximation)
    static float3 ACESFilmic(float3 x) {
        const float a = 2.51f;
        const float b = 0.03f;
        const float c = 2.43f;
        const float d = 0.59f;
        const float e = 0.14f;
        return clamp((x*(a*x+b)) / (x*(c*x+d)+e), 0.0, 1.0);
    }

    // (Old screen-space rainStreak / snowFlake helpers removed in #32 — precipitation
    //  is now environmental world-space particles; see the precip* shaders below.)

    fragment float4 compositeFrag(FSVOut in [[stage_in]],
                                  texture2d<float> hdrTex   [[texture(0)]],
                                  texture2d<float> bloomTex [[texture(1)]],
                                  constant PostUniforms& pu [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        // hdrTex is at the capped internal resolution; bilinear upscale is free here.
        float3 hdr   = hdrTex.sample(s, in.uv).rgb;
        float3 bloom = bloomTex.sample(s, in.uv).rgb;

        // Clamp the bloom contribution per-channel so a large bright region (sun disc,
        // emissive blocks) can never flood the frame and wash out directional shading.
        // Max bloom additive per channel is 0.25 — enough for a visible glow around
        // the sun and emissives but far below the point where it lifts everything to
        // flat-bright. (bloomStrength=0.08 * clamp(bloom, 0, ~3) ≤ 0.25 per channel.)
        float3 bloomClamped = clamp(bloom * pu.bloomStrength, 0.0, 0.20);
        // Exposure < 1 keeps bright scenes (open desert, low sun, bright sky in
        // view) off the ACES white point, so facing the sun no longer washes out.
        float3 combined = (hdr + bloomClamped) * 0.80;

        // ACES filmic tone-map
        float3 tonemapped = ACESFilmic(combined);

        // Gentle warm highlight tint.
        float lumG = dot(tonemapped, float3(0.2126, 0.7152, 0.0722));
        tonemapped = mix(tonemapped, tonemapped * float3(1.03, 1.00, 0.97), lumG * lumG * 0.18);

        // Moderate saturation (no midtone lift / heavy contrast — those pumped
        // brightness and caused the view-dependent wash-out).
        float lumSat = dot(tonemapped, float3(0.2126, 0.7152, 0.0722));
        tonemapped   = mix(float3(lumSat), tonemapped, pu.satBoost);
        // Light contrast only.
        tonemapped   = clamp((tonemapped - 0.5) * 1.06 + 0.5, 0.0, 1.0);

        // Vignette: smooth falloff toward screen edges
        float2 centred = in.uv - 0.5;
        float vigRad = dot(centred, centred);
        float vignette = 1.0 - smoothstep(0.20, 0.70, vigRad * 4.0) * pu.vignetteStr;
        tonemapped *= vignette;

        // ---- Precipitation is now ENVIRONMENTAL (world-space particles) ------
        // FIX (#32): The old screen-space rain-streak / snow-flake overlay was
        // removed. It read as a static full-frame HUD overlay with no parallax.
        // Precipitation is now drawn as instanced world-space quads (see the
        // precip* shaders + ParticleSystem-style pass in the HDR scene), so it
        // falls through the 3D world around the camera with real parallax.
        // pu.rainStrength is still passed (kept for struct-layout stability and
        // the rain wet-darkening of terrain) but no longer composited here.

        // Gamma: drawable is bgra8Unorm (no hardware sRGB), apply manual gamma 2.2.
        tonemapped = pow(clamp(tonemapped, 0.0, 1.0), float3(1.0 / 2.2));

        return float4(tonemapped, 1.0);
    }

    // =========================================================
    // WORLD-SPACE PRECIPITATION — rain streaks + snow flakes (#32)
    //
    // Replaces the old screen-space overlay. A fixed pool of instanced quads
    // (6 verts each) lives in a cube of edge `boxSize` centred on the camera.
    // Each particle has a STABLE world position derived from its seed offset +
    // the camera position, so as the camera moves/turns the particles show real
    // parallax (they are anchored in world space, not the screen). Falling and
    // recycling are done entirely on the GPU: the y coordinate sweeps downward
    // with wall-clock time and WRAPS within the box (modulo), and x/z wrap into
    // the box around the camera — so particles that leave the volume reappear on
    // the opposite side. No per-frame CPU update; just a few thousand quads.
    //
    // mode: 1 = rain (thin vertical streaks, fast), 2 = snow (small flakes, slow
    //       drift). Driven from frame.camera.weather.
    // =========================================================
    struct PrecipVOut {
        float4 position [[position]];
        float2 uv;        // quad-local UV in [-1,1]
        float  fade;      // edge-of-box fade (0 at box boundary, 1 in centre)
        uint   isSnow [[flat]];
    };

    // Wrap v into [0, range) (handles negatives), branchless.
    static float wrapf(float v, float range) {
        return v - floor(v / range) * range;
    }

    vertex PrecipVOut precipVert(uint vid [[vertex_id]],
                                 device const PrecipParticle* parts [[buffer(0)]],
                                 constant PrecipUniforms& pu [[buffer(1)]]) {
        uint pi = vid / 6u;
        uint ci = vid % 6u;
        PrecipParticle sp = parts[pi];

        bool isSnow = (pu.mode > 1.5);
        float box     = pu.boxSize;
        float halfBox = box * 0.5;     // NB: `half` is a reserved MSL type name — do not use it
        float3 cam    = pu.camPosW.xyz;

        // Fall speed (world units / sec): rain fast, snow slow.
        float speed = isSnow ? 1.6 : 18.0;
        // Phase staggers each particle's start so they don't all fall in lockstep.
        float phase = sp.seed.w;

        // World position. x/z: stable seed offset around the camera, wrapped into
        // the box so the field always surrounds the player (recycling sideways as
        // the camera moves). y: sweeps downward over time and wraps within the box.
        float baseX = cam.x + sp.seed.x * box;
        float baseZ = cam.z + sp.seed.z * box;
        // Snow drifts sideways gently; rain falls near-straight (tiny slant).
        float drift = isSnow ? (sin(pu.wallClock * 0.5 + phase * 6.2831) * 0.6) : 0.0;
        baseX += drift;

        // Wrap x/z into [cam-halfBox, cam+halfBox]: keeps the volume centred on the camera.
        float wx = wrapf(baseX - (cam.x - halfBox), box) + (cam.x - halfBox);
        float wz = wrapf(baseZ - (cam.z - halfBox), box) + (cam.z - halfBox);

        // y: start from top of box, fall, wrap. Using wall-clock * speed + phase.
        float fallY = (sp.seed.y * box) - (pu.wallClock * speed + phase * box);
        float wy = wrapf(fallY - (cam.y - halfBox), box) + (cam.y - halfBox);

        float3 worldPos = float3(wx, wy, wz);

        // Edge fade: dim particles near the box boundary so the volume edge isn't a
        // hard wall (also hides the wrap discontinuity). Based on horizontal distance.
        float2 dxz = float2(wx - cam.x, wz - cam.z);
        float horiz = max(abs(dxz.x), abs(dxz.y));
        float fade = 1.0 - smoothstep(halfBox * 0.6, halfBox, horiz);

        // Billboard the quad toward the camera in clip space (like ambientLifeVert),
        // but stretch rain vertically into a streak. Snow is a small square.
        const float2 corners[6] = {
            float2(-1,-1), float2(1,-1), float2(1, 1),
            float2(-1,-1), float2(1, 1), float2(-1, 1)
        };
        float2 corner = corners[ci];

        float4 clipC = pu.viewProj * float4(worldPos, 1.0);
        // Half-size in clip units, scaled by 1/w so it's a consistent on-screen size.
        float wsafe = max(clipC.w, 0.001);
        float halfW = (isSnow ? 0.045 : 0.012) / wsafe;   // rain: thin in X
        float halfH = (isSnow ? 0.045 : 0.130) / wsafe;   // rain: long streak in Y
        float4 pos = clipC + float4(corner.x * halfW, corner.y * halfH, 0.0, 0.0);

        PrecipVOut o;
        o.position = pos;
        o.uv       = corner;
        o.fade     = fade;
        o.isSnow   = isSnow ? 1u : 0u;
        return o;
    }

    fragment float4 precipFrag(PrecipVOut in [[stage_in]]) {
        float alpha;
        float3 col;
        if (in.isSnow == 1u) {
            // Soft round flake.
            float d = dot(in.uv, in.uv);
            if (d > 1.0) discard_fragment();
            alpha = (1.0 - smoothstep(0.3, 1.0, d)) * 0.85;
            col = float3(0.95, 0.97, 1.00);
        } else {
            // Rain streak: soft vertical bar, fade toward the ends for a motion look.
            float xs = 1.0 - smoothstep(0.4, 1.0, abs(in.uv.x));   // across the streak
            float ys = 1.0 - smoothstep(0.6, 1.0, abs(in.uv.y));   // along the streak
            alpha = xs * ys * 0.55;
            col = float3(0.72, 0.80, 0.92);
        }
        alpha *= in.fade;
        if (alpha < 0.01) discard_fragment();
        return float4(col, alpha);
    }

    // =========================================================
    // AMBIENT LIFE — birds (day) + fireflies (night)
    //
    // Each sprite occupies 6 vertices (two triangles = billboard quad).
    // The vertex shader reconstructs which sprite and which corner from
    // vertex_id: sprite = vid / 6, corner = vid % 6.
    //
    // Birds: large (~1 world unit), dark silhouette, drawn at fixed sky
    //        height — we skip depth testing effect by always writing to
    //        a far position, so they sit in the sky.
    // Fireflies: tiny emissive warm-green, HDR > 1, depth-tested so they
    //            hide behind terrain. They bloom via the existing bloom pass.
    // =========================================================

    struct ALVOut {
        float4 position [[position]];
        float4 color;    // rgba (HDR allowed)
        float2 uv;       // normalised quad UV (−1..1)
        uint   isBird [[flat]];  // 1=bird (screen-facing, no depth), 0=firefly
    };

    vertex ALVOut ambientLifeVert(uint vid [[vertex_id]],
                                   device const AmbientSprite* sprites [[buffer(0)]],
                                   constant AmbientLifeUniforms& au [[buffer(1)]]) {
        // Reconstruct sprite index and corner.
        uint si = vid / 6u;
        uint ci = vid % 6u;
        AmbientSprite sp = sprites[si];

        // Corner offsets for a quad via two triangles.
        // ci: 0=BL,1=BR,2=TR, 3=BL,4=TR,5=TL
        const float2 corners[6] = {
            float2(-1,-1), float2(1,-1), float2(1, 1),
            float2(-1,-1), float2(1, 1), float2(-1, 1)
        };
        float2 corner = corners[ci];

        float size   = sp.posW.w;   // screen-space half-size in clip units
        float4 clipCenter = au.viewProj * float4(sp.posW.xyz, 1.0);

        // Billboard: offset in clip space so the quad always faces the camera.
        // We scale the offset by size / clipCenter.w to keep it view-independent.
        float screenSize = size / max(clipCenter.w, 0.001);
        float4 pos = clipCenter + float4(corner.x * screenSize,
                                          corner.y * screenSize * 1.5, // slight vertical stretch for birds
                                          0.0, 0.0);

        ALVOut o;
        o.position = pos;
        o.color    = sp.color;
        o.uv       = corner;
        // Determine bird vs firefly by size: birds have size > 0.5, fireflies < 0.5
        o.isBird   = (size > 0.5) ? 1u : 0u;
        return o;
    }

    fragment float4 ambientLifeFrag(ALVOut in [[stage_in]]) {
        // Soft circular mask (both birds and fireflies are round/dot)
        float d = dot(in.uv, in.uv);
        if (d > 1.0) discard_fragment();

        float alpha = in.color.a;

        if (in.isBird == 1u) {
            // Bird silhouette: simple V-wing shape using the UV.
            // Wing tips: |x| > |y|*1.5 → draw, else discard for the body gap.
            float wingMask = step(abs(in.uv.y) * 1.6, abs(in.uv.x));
            // Also mask off the inner part to make a V (not a full disc)
            float innerGap = 1.0 - step(abs(in.uv.y) * 0.6, d);
            float mask = wingMask * (1.0 - innerGap * 0.5);
            if (mask < 0.1) discard_fragment();
            // Soft edge
            float edge = 1.0 - smoothstep(0.60, 1.0, d);
            return float4(in.color.rgb * edge * mask, alpha * edge * mask);
        } else {
            // Firefly: gaussian glow dot.  Multiply out to HDR levels for bloom.
            float glow = exp(-d * 3.5);
            // Outer halo (broader, dimmer)
            float halo = exp(-d * 1.2) * 0.35;
            float total = glow + halo;
            return float4(in.color.rgb * total, alpha * total);
        }
    }
    """
}

// MARK: - Shadow vert uniform (Swift side, matches MSL ShadowVertUniforms)

/// 80 bytes: lightViewProj (64) + chunkOrigin (16)
struct ShadowVertUniforms {
    var lightViewProj: simd_float4x4
    var chunkOrigin:   SIMD4<Float>
}

// MARK: - Ambient sprite POD (matches MSL AmbientSprite, 32 bytes)
/// 32 bytes per sprite, written by Swift, read by MSL ambientLifeVert.
struct AmbientSpritePod {
    var posW:    SIMD4<Float>   // xyz = world pos, w = size (screen-space radius)
    var color:   SIMD4<Float>   // rgb = HDR colour (>1 allowed for bloom), a = alpha
}

// MARK: - Precipitation particle POD (matches MSL PrecipParticle, 16 bytes)
/// One per particle. seed = a stable per-particle offset within the spawn box +
/// a phase, written ONCE at init; the vertex shader derives the animated world
/// position from it each frame (no per-frame CPU update — cheap & recycling-free).
struct PrecipParticlePod {
    var seed: SIMD4<Float>   // xyz = offset within box [-0.5..0.5]^3, w = per-particle phase 0..1
}

// MARK: - Offscreen render self-test (CI: proves terrain pixels actually draw)

func runRenderSelfTest(savePath: String? = nil, width: Int = 320, height: Int = 240) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return false }
    let queue = device.makeCommandQueue()!
    let registry = BufferRegistry(device: device)

    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else {
        print("shader compile failed"); return false
    }

    // ---- Build terrain pipeline (renders into rgba16Float then composited) ---
    let pdesc = MTLRenderPipelineDescriptor()
    pdesc.vertexFunction   = lib.makeFunction(name: "vmain")
    pdesc.fragmentFunction = lib.makeFunction(name: "fmain")
    pdesc.colorAttachments[0].pixelFormat = .rgba16Float
    pdesc.depthAttachmentPixelFormat = .depth32Float
    guard let terrainPipeline = try? device.makeRenderPipelineState(descriptor: pdesc) else {
        print("terrain pipeline failed"); return false
    }
    let dsd = MTLDepthStencilDescriptor()
    dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)

    // Sky pipeline
    let spdesc = MTLRenderPipelineDescriptor()
    spdesc.vertexFunction   = lib.makeFunction(name: "skyVmain")
    spdesc.fragmentFunction = lib.makeFunction(name: "skyFmain")
    spdesc.colorAttachments[0].pixelFormat = .rgba16Float
    spdesc.depthAttachmentPixelFormat = .depth32Float
    let skyPipeline = try? device.makeRenderPipelineState(descriptor: spdesc)
    let sdsd = MTLDepthStencilDescriptor()
    sdsd.depthCompareFunction = .always; sdsd.isDepthWriteEnabled = false
    let skyDepthState = device.makeDepthStencilState(descriptor: sdsd)

    // Shadow pipeline
    let shadowDesc = MTLRenderPipelineDescriptor()
    shadowDesc.vertexFunction   = lib.makeFunction(name: "shadowVmain")
    shadowDesc.fragmentFunction = nil
    shadowDesc.depthAttachmentPixelFormat = .depth32Float
    let shadowPipeline = try? device.makeRenderPipelineState(descriptor: shadowDesc)
    let shdd = MTLDepthStencilDescriptor()
    shdd.depthCompareFunction = .lessEqual; shdd.isDepthWriteEnabled = true
    let shadowDepthState = device.makeDepthStencilState(descriptor: shdd)

    // Composite pipeline
    let cpdesc = MTLRenderPipelineDescriptor()
    cpdesc.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
    cpdesc.fragmentFunction = lib.makeFunction(name: "compositeFrag")
    cpdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
    let compositePipeline = try? device.makeRenderPipelineState(descriptor: cpdesc)

    let nodd = MTLDepthStencilDescriptor()
    nodd.depthCompareFunction = .always; nodd.isDepthWriteEnabled = false
    let noDepthState = device.makeDepthStencilState(descriptor: nodd)

    let entR = EntityRenderer(device: device, colorFormat: .rgba16Float)

    // Shadow sampler
    let ssd = MTLSamplerDescriptor()
    ssd.minFilter = .linear; ssd.magFilter = .linear
    ssd.sAddressMode = .clampToEdge; ssd.tAddressMode = .clampToEdge
    ssd.compareFunction = .lessEqual
    let shadowSampler = device.makeSamplerState(descriptor: ssd)!

    // Engine
    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION; cfg.role = BF_ROLE_SINGLEPLAYER; cfg.start_mode = BF_MODE_CREATIVE
    cfg.content_dir = persistentCString("."); cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_rt")
    cfg.player_name = persistentCString("ci")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { print("engine create"); return false }
    defer { bf_engine_destroy(e) }
    var alloc = bf_gpu_allocator()
    alloc.user = Unmanaged.passUnretained(registry).toOpaque()
    alloc.alloc = allocTrampoline; alloc.free_ = freeTrampoline
    _ = bf_set_gpu_allocator(e, &alloc)
    _ = bf_world_new(e, 1)

    let W = width, H = height
    let HW = max(1, W/2), HH = max(1, H/2)
    let kShadowRes = 512  // smaller for CI speed

    func makeTex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage, priv: Bool = true) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage
        td.storageMode = priv ? .private : .shared
        return device.makeTexture(descriptor: td)!
    }

    let shadowTex  = makeTex(.depth32Float, kShadowRes, kShadowRes, usage: [.renderTarget, .shaderRead])
    let hdrColor   = makeTex(.rgba16Float,  W, H, usage: [.renderTarget, .shaderRead])
    let hdrDepth   = makeTex(.depth32Float, W, H, usage: [.renderTarget])
    let bloomBrt   = makeTex(.rgba16Float,  HW, HH, usage: [.renderTarget, .shaderRead])
    let bloomBlurA = makeTex(.rgba16Float,  HW, HH, usage: [.renderTarget, .shaderRead])
    // Final readable output
    let output = makeTex(.bgra8Unorm, W, H, usage: [.renderTarget], priv: false)

    var rendered = false

    for f in 0..<64 {
        registry.currentFrame = f
        var input = bf_frame_input()
        // Stream chunks in normally for the first frames, then fast-forward the
        // day clock to golden hour so the screenshot shows long cast shadows and
        // warm low-angle light (a representative, flattering scene).
        let dt = f < 24 ? 1.0/60.0 : 6.0
        _ = bf_frame_begin(e, &input, dt)
        var frame = bf_render_frame()
        _ = bf_frame_acquire_render(e, &frame)

        let proj = Renderer.perspective(fovy: 1.20, aspect: Float(W)/Float(H), near: 0.05, far: 512)
        let viewM = Renderer.mat(frame.camera.view)
        let viewProj = proj * viewM
        let sun = frame.camera.sun_dir

        // Real angled sun + camera for the shadow matrix, so the screenshot is
        // representative of gameplay (not a flat overhead-sun scene).
        let vt = viewM.columns.3
        let camPosW = SIMD3<Float>(
            -(viewM.columns.0.x*vt.x + viewM.columns.1.x*vt.y + viewM.columns.2.x*vt.z),
            -(viewM.columns.0.y*vt.x + viewM.columns.1.y*vt.y + viewM.columns.2.y*vt.z),
            -(viewM.columns.0.z*vt.x + viewM.columns.1.z*vt.y + viewM.columns.2.z*vt.z))
        let camFwdST = SIMD3<Float>(-viewM.columns.0.z, -viewM.columns.1.z, -viewM.columns.2.z)
        let testLightVP = Renderer.buildLightMatrix(
            sunDir: SIMD3<Float>(sun.x, sun.y, sun.z), camPos: camPosW, camFwd: camFwdST)

        guard let cmd = queue.makeCommandBuffer() else { bf_frame_end(e); continue }

        // --- Shadow pass ---
        if let sp = shadowPipeline {
            let srp = MTLRenderPassDescriptor()
            srp.depthAttachment.texture = shadowTex
            srp.depthAttachment.loadAction = .clear
            srp.depthAttachment.storeAction = .store
            srp.depthAttachment.clearDepth = 1.0
            if let enc = cmd.makeRenderCommandEncoder(descriptor: srp) {
                enc.setRenderPipelineState(sp)
                enc.setDepthStencilState(shadowDepthState)
                enc.setCullMode(.front)
                enc.setDepthBias(2.0, slopeScale: 2.0, clamp: 0.0)
                var windST = WindUniforms(wallClockSecs: Float(f)/60.0, rainStrength: 0)
                enc.setVertexBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 2)
                for i in 0..<Int(frame.draw_count) {
                    let d = frame.draws[i]
                    guard d.index_count > 0,
                          let vb = registry.lookup(d.vertex_buffer),
                          let ib = registry.lookup(d.index_buffer) else { continue }
                    var su = ShadowVertUniforms(
                        lightViewProj: testLightVP,
                        chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), 0))
                    enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                    enc.setVertexBytes(&su, length: MemoryLayout<ShadowVertUniforms>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                              indexType: .uint32, indexBuffer: ib,
                                              indexBufferOffset: Int(d.index_offset))
                }
                enc.endEncoding()
            }
        }

        // --- HDR scene pass ---
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdrColor
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.3, green: 0.12, blue: 0.22, alpha: 1)
        rp.depthAttachment.texture = hdrDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.storeAction = .dontCare

        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            // Sky
            if let sp = skyPipeline {
                enc.setRenderPipelineState(sp)
                enc.setDepthStencilState(skyDepthState)
                enc.setCullMode(.none)
                let cr = SIMD3<Float>(viewM.columns.0.x, viewM.columns.1.x, viewM.columns.2.x)
                let cu = SIMD3<Float>(viewM.columns.0.y, viewM.columns.1.y, viewM.columns.2.y)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    camRight: SIMD4<Float>(cr.x, cr.y, cr.z, 0.6841),
                    camUp:    SIMD4<Float>(cu.x, cu.y, cu.z, Float(W)/Float(H)),
                    camFwd:   SIMD4<Float>(camFwdST.x, camFwdST.y, camFwdST.z, 0))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: Float(f)/60.0, underwater: 0.0)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            // Terrain
            enc.setRenderPipelineState(terrainPipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
            var wu = WaterUniforms(wallClockSecs: Float(f)/60.0, underwater: 0.0,
                                   cameraPosW: SIMD4<Float>(0, 20, 0, 0))
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            enc.setFragmentTexture(shadowTex, index: 0)
            enc.setFragmentSamplerState(shadowSampler, index: 0)
            var windST = WindUniforms(wallClockSecs: Float(f)/60.0, rainStrength: 0)
            enc.setVertexBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setFragmentBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vb = registry.lookup(d.vertex_buffer),
                      let ib = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(
                    viewProj: viewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: testLightVP,
                    dimSatN: SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ib,
                                          indexBufferOffset: Int(d.index_offset))
                rendered = true
            }
            enc.setDepthStencilState(depthState)
            entR.encode(enc, viewProj: viewProj, entities: frame.entities, count: Int(frame.entity_count))
            enc.endEncoding()
        }

        // --- Bloom bright-pass (HDR → half-res) ---
        if let bpPipeline = try? { () throws -> MTLRenderPipelineState in
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
            d.fragmentFunction = lib.makeFunction(name: "bloomBrightFrag")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: d)
        }() {
            let brp = MTLRenderPassDescriptor()
            brp.colorAttachments[0].texture = bloomBrt
            brp.colorAttachments[0].loadAction = .dontCare
            brp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: brp) {
                enc.setRenderPipelineState(bpPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // --- Blur H ---
        if let bhPipeline = try? { () throws -> MTLRenderPipelineState in
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
            d.fragmentFunction = lib.makeFunction(name: "bloomBlurHFrag")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: d)
        }() {
            let brp = MTLRenderPassDescriptor()
            brp.colorAttachments[0].texture = bloomBlurA
            brp.colorAttachments[0].loadAction = .dontCare
            brp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: brp) {
                enc.setRenderPipelineState(bhPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(bloomBrt, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // --- Blur V → back into bloomBrt ---
        if let bvPipeline = try? { () throws -> MTLRenderPipelineState in
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
            d.fragmentFunction = lib.makeFunction(name: "bloomBlurVFrag")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: d)
        }() {
            let brp = MTLRenderPassDescriptor()
            brp.colorAttachments[0].texture = bloomBrt
            brp.colorAttachments[0].loadAction = .dontCare
            brp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: brp) {
                enc.setRenderPipelineState(bvPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(bloomBlurA, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // --- Composite → bgra8 output ---
        if let cp = compositePipeline {
            let crp = MTLRenderPassDescriptor()
            crp.colorAttachments[0].texture = output
            crp.colorAttachments[0].loadAction = .dontCare
            crp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: crp) {
                enc.setRenderPipelineState(cp)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor,  index: 0)
                enc.setFragmentTexture(bloomBrt,  index: 1)
                var pu = PostUniforms(bloomStrength: 0.12, vignetteStr: 0.22, satBoost: 1.18,
                                      rainStrength: 0, wallClockSecs: Float(f)/60.0)
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        cmd.commit(); cmd.waitUntilCompleted()
        bf_frame_end(e); registry.collect()
    }
    guard rendered else { print("no draws encoded"); return false }

    // Read back from composite output (bgra8)
    var px = [UInt8](repeating: 0, count: W*H*4)
    output.getBytes(&px, bytesPerRow: W*4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    let clear = (0.30, 0.12, 0.22)
    var terrain = 0
    for p in stride(from: 0, to: px.count, by: 4) {
        let b = Double(px[p])/255, g = Double(px[p+1])/255, r = Double(px[p+2])/255
        let dist = abs(r-clear.0) + abs(g-clear.1) + abs(b-clear.2)
        if dist > 0.15 { terrain += 1 }
    }
    let frac = Double(terrain) / Double(W*H)
    print(String(format: "OK: render self-test — %.1f%% of pixels are terrain (drew chunk meshes)", frac*100))

    if let path = savePath {
        var rgba = [UInt8](repeating: 0, count: W*H*4)
        for i in stride(from: 0, to: px.count, by: 4) {
            rgba[i] = px[i+2]; rgba[i+1] = px[i+1]; rgba[i+2] = px[i]; rgba[i+3] = 255
        }
        rgba.withUnsafeMutableBytes { raw in
            var planes: [UnsafeMutablePointer<UInt8>?] = [raw.bindMemory(to: UInt8.self).baseAddress]
            if let rep = NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: W, pixelsHigh: H,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: W*4, bitsPerPixel: 32),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote screenshot: \(path)")
            }
        }
    }
    return frac > 0.05
}

// MARK: - Washout regression test (#33)
// Negative test for the recurring "turn toward the sun and the whole frame washes
// out" bug. Renders the FULL gameplay pipeline (sky + terrain → bloom → ACES
// composite, with the gameplay PostUniforms) over real streamed terrain, sweeping
// the camera through a full 360° yaw at several sun elevations / times of day. At
// each step it measures the fraction of "washed" pixels — bright AND desaturated
// (near-white) — in the final image. Facing away from the sun this is tiny; a
// washout spikes it. The test FAILS if any direction/time exceeds the threshold,
// so a future change that re-breaks the sun shading is caught automatically.
func runWashoutTest() -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { print("SKIP: washout test (no Metal device)"); return true }
    let queue = device.makeCommandQueue()!
    let registry = BufferRegistry(device: device)
    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else {
        print("shader compile failed"); return false
    }
    func pipe(_ vfn: String, _ ffn: String, _ fmt: MTLPixelFormat, depth: Bool) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: vfn); d.fragmentFunction = lib.makeFunction(name: ffn)
        d.colorAttachments[0].pixelFormat = fmt
        if depth { d.depthAttachmentPixelFormat = .depth32Float }
        return try? device.makeRenderPipelineState(descriptor: d)
    }
    guard let skyPipe = pipe("skyVmain", "skyFmain", .rgba16Float, depth: true),
          let terrPipe = pipe("vmain", "fmain", .rgba16Float, depth: true),
          let brightPipe = pipe("fullscreenVert", "bloomBrightFrag", .rgba16Float, depth: false),
          let blurHPipe = pipe("fullscreenVert", "bloomBlurHFrag", .rgba16Float, depth: false),
          let blurVPipe = pipe("fullscreenVert", "bloomBlurVFrag", .rgba16Float, depth: false),
          let compPipe = pipe("fullscreenVert", "compositeFrag", .bgra8Unorm, depth: false)
    else { print("pipeline build failed"); return false }

    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)
    let sdsd = MTLDepthStencilDescriptor(); sdsd.depthCompareFunction = .always; sdsd.isDepthWriteEnabled = false
    let skyDepthState = device.makeDepthStencilState(descriptor: sdsd)
    let nodd = MTLDepthStencilDescriptor(); nodd.depthCompareFunction = .always; nodd.isDepthWriteEnabled = false
    let noDepthState = device.makeDepthStencilState(descriptor: nodd)

    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION; cfg.role = BF_ROLE_SINGLEPLAYER; cfg.start_mode = BF_MODE_CREATIVE
    cfg.content_dir = persistentCString("."); cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_wt")
    cfg.player_name = persistentCString("ci")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { print("engine create"); return false }
    defer { bf_engine_destroy(e) }
    var alloc = bf_gpu_allocator()
    alloc.user = Unmanaged.passUnretained(registry).toOpaque()
    alloc.alloc = allocTrampoline; alloc.free_ = freeTrampoline
    _ = bf_set_gpu_allocator(e, &alloc)
    _ = bf_world_new(e, 1)

    let W = 320, H = 240, HW = W/2, HH = H/2
    func makeTex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ shared: Bool) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: td)!
    }
    let hdrColor = makeTex(.rgba16Float, W, H, [.renderTarget, .shaderRead], false)
    let hdrDepth = makeTex(.depth32Float, W, H, [.renderTarget], false)
    let bloomBrt = makeTex(.rgba16Float, HW, HH, [.renderTarget, .shaderRead], false)
    let bloomBlurA = makeTex(.rgba16Float, HW, HH, [.renderTarget, .shaderRead], false)
    let output = makeTex(.bgra8Unorm, W, H, [.renderTarget], true)

    // Stream terrain in so the sweep renders a real scene (not empty sky).
    var camEye = SIMD3<Float>(0, 48, 0)
    for f in 0..<64 {
        registry.currentFrame = f
        var input = bf_frame_input()
        _ = bf_frame_begin(e, &input, f < 48 ? 1.0/60.0 : 2.0)
        var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
        let vm = Renderer.mat(fr.camera.view); let vt = vm.columns.3
        camEye = SIMD3<Float>(
            -(vm.columns.0.x*vt.x + vm.columns.1.x*vt.y + vm.columns.2.x*vt.z),
            -(vm.columns.0.y*vt.x + vm.columns.1.y*vt.y + vm.columns.2.y*vt.z),
            -(vm.columns.0.z*vt.x + vm.columns.1.z*vt.y + vm.columns.2.z*vt.z))
        bf_frame_end(e); registry.collect()
    }

    let proj = Renderer.perspective(fovy: 1.20, aspect: Float(W)/Float(H), near: 0.05, far: 512)
    let tanHalf = tan(0.60) as Float
    func lookView(_ eye: SIMD3<Float>, _ fwd: SIMD3<Float>, _ up: SIMD3<Float>) -> simd_float4x4 {
        let s = normalize(cross(fwd, up)); let u = cross(s, fwd)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -fwd.x, 0),
            SIMD4<Float>(s.y, u.y, -fwd.y, 0),
            SIMD4<Float>(s.z, u.z, -fwd.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(fwd, eye), 1)))
    }

    // Scenarios: (label, sun elevation°, time_of_day). The sun sits toward +X
    // (azimuth 0); the yaw sweep therefore faces it at yaw≈0.
    let scenarios: [(String, Float, Float)] = [
        ("noon",      70, 0.50),
        ("afternoon", 35, 0.30),
        ("golden",    12, 0.10),
        ("lowsun",     6, 0.06),
    ]
    let yawSteps = 24
    var worstWash: Double = 0, worstAt = ""
    var awayWash: Double = 0   // reference: wash when facing AWAY from the sun

    for (label, elevDeg, tod) in scenarios {
        let E = elevDeg * Float.pi / 180
        let toward = SIMD3<Float>(cos(E), sin(E), 0)     // direction toward the sun
        let sd = -toward                                  // sun_dir: from sun into scene
        let lookP = min(E, 18 * Float.pi / 180)           // pitch up toward the sun a bit
        for yi in 0..<yawSteps {
            let phi = 2 * Float.pi * Float(yi) / Float(yawSteps)
            let fwd = normalize(SIMD3<Float>(cos(phi) * cos(lookP), sin(lookP), sin(phi) * cos(lookP)))
            let view = lookView(camEye, fwd, SIMD3<Float>(0, 1, 0))
            let viewProj = proj * view
            let cr = SIMD3<Float>(view.columns.0.x, view.columns.1.x, view.columns.2.x)
            let cu = SIMD3<Float>(view.columns.0.y, view.columns.1.y, view.columns.2.y)

            registry.currentFrame = 64 + yi
            var input = bf_frame_input()
            _ = bf_frame_begin(e, &input, 1.0/60.0)
            var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
            guard let cmd = queue.makeCommandBuffer() else { bf_frame_end(e); continue }

            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = hdrColor
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            rp.depthAttachment.texture = hdrDepth
            rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0
            rp.depthAttachment.storeAction = .dontCare
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(skyPipe); enc.setDepthStencilState(skyDepthState); enc.setCullMode(.none)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sd.x, sd.y, sd.z, tod),
                    camRight: SIMD4<Float>(cr.x, cr.y, cr.z, tanHalf),
                    camUp:    SIMD4<Float>(cu.x, cu.y, cu.z, Float(W)/Float(H)),
                    camFwd:   SIMD4<Float>(fwd.x, fwd.y, fwd.z, 0))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: 0, underwater: 0)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                enc.setRenderPipelineState(terrPipe); enc.setDepthStencilState(depthState)
                enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
                var wu = WaterUniforms(wallClockSecs: 0, underwater: 0, cameraPosW: SIMD4<Float>(camEye.x, camEye.y, camEye.z, 0))
                enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
                var windST = WindUniforms(wallClockSecs: 0, rainStrength: 0)
                enc.setVertexBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
                enc.setFragmentBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
                for i in 0..<Int(fr.draw_count) {
                    let d = fr.draws[i]
                    guard d.index_count > 0, let vb = registry.lookup(d.vertex_buffer), let ib = registry.lookup(d.index_buffer) else { continue }
                    var u = Uniforms(
                        viewProj: viewProj,
                        chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                        sunDirTime: SIMD4<Float>(sd.x, sd.y, sd.z, tod),
                        lightViewProj: matrix_identity_float4x4,
                        dimSatN: SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                    enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                              indexType: .uint32, indexBuffer: ib, indexBufferOffset: Int(d.index_offset))
                }
                enc.endEncoding()
            }
            // Bloom bright → blurH → blurV (into bloomBrt), then ACES composite.
            func fsPass(_ p: MTLRenderPipelineState, _ inTex: MTLTexture, _ outTex: MTLTexture) {
                let d = MTLRenderPassDescriptor()
                d.colorAttachments[0].texture = outTex; d.colorAttachments[0].loadAction = .dontCare; d.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: d) {
                    enc.setRenderPipelineState(p); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                    enc.setFragmentTexture(inTex, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
                }
            }
            fsPass(brightPipe, hdrColor, bloomBrt)
            fsPass(blurHPipe, bloomBrt, bloomBlurA)
            fsPass(blurVPipe, bloomBlurA, bloomBrt)
            // Composite with the SAME PostUniforms gameplay uses (bloomStrength 0.08).
            let crp = MTLRenderPassDescriptor()
            crp.colorAttachments[0].texture = output; crp.colorAttachments[0].loadAction = .dontCare; crp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: crp) {
                enc.setRenderPipelineState(compPipe); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor, index: 0); enc.setFragmentTexture(bloomBrt, index: 1)
                var pu = PostUniforms(bloomStrength: 0.08, vignetteStr: 0.22, satBoost: 1.18, rainStrength: 0, wallClockSecs: 0)
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
            }
            cmd.commit(); cmd.waitUntilCompleted()
            bf_frame_end(e); registry.collect()

            // Measure washed pixels: bright (luma>0.82) AND desaturated (sat<0.18).
            var px = [UInt8](repeating: 0, count: W*H*4)
            output.getBytes(&px, bytesPerRow: W*4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            var washed = 0
            for p in stride(from: 0, to: px.count, by: 4) {
                let b = Double(px[p])/255, g = Double(px[p+1])/255, r = Double(px[p+2])/255
                let luma = 0.2126*r + 0.7152*g + 0.0722*b
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let sat = mx > 0.001 ? (mx - mn) / mx : 0
                if luma > 0.82 && sat < 0.18 { washed += 1 }
            }
            let frac = Double(washed) / Double(W*H)
            // yaw≈0 faces the sun; yaw≈π faces away (reference).
            if yi == 0 {
                print(String(format: "  %@: sun-facing washed %.1f%%", label, frac*100))
                if ProcessInfo.processInfo.environment["WASH_SAVE"] != nil {
                    var rgba = [UInt8](repeating: 255, count: W*H*4)
                    for i in stride(from: 0, to: px.count, by: 4) { rgba[i]=px[i+2]; rgba[i+1]=px[i+1]; rgba[i+2]=px[i] }
                    rgba.withUnsafeMutableBytes { raw in
                        var planes: [UnsafeMutablePointer<UInt8>?] = [raw.bindMemory(to: UInt8.self).baseAddress]
                        if let rep = NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: W, pixelsHigh: H,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                            colorSpaceName: .deviceRGB, bytesPerRow: W*4, bitsPerPixel: 32),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/wash_\(label).png"))
                        }
                    }
                }
            }
            if yi == yawSteps/2 { awayWash = max(awayWash, frac) }
            if frac > worstWash { worstWash = frac; worstAt = "\(label)@yaw\(Int(phi*180/Float.pi))°" }
        }
    }
    let thresh = 0.30
    let pass = worstWash < thresh
    print(String(format: "%@ washout test — worst washed %.1f%% (%@), facing-away ref %.1f%%, threshold %.0f%%",
                 pass ? "OK:" : "FAIL:", worstWash*100, worstAt, awayWash*100, thresh*100))
    return pass
}

// MARK: - Headless self-test (CI, no display) — unchanged boundary check

func runHeadlessSelfTest() -> Bool {
    guard bf_abi_version() == BF_ABI_VERSION else { return false }
    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION
    cfg.role = BF_ROLE_SINGLEPLAYER
    cfg.start_mode = BF_MODE_SURVIVAL
    cfg.content_dir = persistentCString(".")
    cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_selftest")
    cfg.player_name = persistentCString("ci")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { return false }
    defer { bf_engine_destroy(e) }
    guard bf_world_new(e, 7) == BF_OK else { return false }
    for _ in 0..<5 {
        var input = bf_frame_input()
        guard bf_frame_begin(e, &input, 1.0 / 60.0) == BF_OK else { return false }
        var frame = bf_render_frame()
        guard bf_frame_acquire_render(e, &frame) == BF_OK else { return false }
        if frame.hud.health != 20.0 { return false }
        bf_frame_end(e)
    }
    print("OK: swift<->c++ self-test (5 frames, hud populated)")
    return true
}
