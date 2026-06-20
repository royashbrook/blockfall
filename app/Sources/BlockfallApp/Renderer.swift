// ============================================================================
// Blockfall — Renderer (Track E, M1)
// Owns the engine + Metal queue. Per frame: read GameView input -> drive the
// engine -> acquire the render frame -> draw each chunk mesh (greedy-meshed
// BFVertex buffers, UMA storageModeShared, referenced by handle) with a
// runtime-compiled stylized shader. Buffers freed by the engine are retired
// for a few frames so the GPU never reads a released buffer (threading.md §2).
// ============================================================================
import MetalKit
import simd
import CBlockcore

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

struct Uniforms {
    var viewProj: simd_float4x4
    var chunkOrigin: SIMD4<Float>   // xyz origin, w unused
    var sunDirTime: SIMD4<Float>    // xyz sun dir, w time-of-day
}

/// Matches the MSL SkyUniforms struct.
/// Camera basis vectors let the fragment reconstruct a world-space view ray
/// so the sky dome (sun, clouds, stars) sit fixed in the world and parallax
/// correctly as you turn and look up/down.
struct SkyUniforms {
    var sunDirTime: SIMD4<Float>    // xyz sun dir (pointing FROM sun, i.e. downward), w time-of-day
    var camRight:   SIMD4<Float>    // xyz world-space camera right, w = tanHalfFov
    var camUp:      SIMD4<Float>    // xyz world-space camera up,    w = aspect ratio
    var camFwd:     SIMD4<Float>    // xyz world-space camera forward (into scene), w unused
}

/// Extra per-frame uniforms passed as fragment bytes at index 2 for terrain pass,
/// and as both vertex+fragment bytes for the underwater post pass.
/// 32 bytes — not seen by the engine, set in draw(in:).
/// Layout must match MSL WaterUniforms struct:
///   float4 row0: wallClockSecs, underwater, pad0, pad1
///   float4 row1: cameraPosW (xyz = world camera pos, w = unused)
struct WaterUniforms {
    var wallClockSecs: Float   // CACurrentMediaTime() mod 3600 — for water anim + weather
    var underwater: Float      // 1.0 if camera is submerged, else 0.0
    var pad0: Float = 0
    var pad1: Float = 0
    var cameraPosW: SIMD4<Float> = .zero  // xyz = world-space camera pos, w unused
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let registry: BufferRegistry
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var skyPipeline: MTLRenderPipelineState!
    private var skyDepthState: MTLDepthStencilState!
    private var underwaterPipeline: MTLRenderPipelineState!  // fullscreen post-pass
    private var entityRenderer: EntityRenderer!
    private var particles: ParticleSystem!
    private var engine: OpaquePointer?
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var frameCounter = 0
    private weak var gameView: GameView?
    weak var hud: HUDView?
    weak var audio: GameAudio?
    private var lastUnderwater = false
    private let saveDir: String

    init(view: MTKView, device: MTLDevice, saveDir: String, audio: GameAudio?) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.registry = BufferRegistry(device: device)
        self.gameView = view as? GameView
        self.saveDir = saveDir
        self.audio = audio
        super.init()
        view.depthStencilPixelFormat = .depth32Float
        buildPipeline(colorFormat: view.colorPixelFormat)
        entityRenderer = EntityRenderer(device: device, colorFormat: view.colorPixelFormat)
        particles = ParticleSystem(device: device, colorFormat: view.colorPixelFormat)
        createEngine()
    }

    // ---- pipeline (runtime-compiled MSL; no offline metallib needed for M1) -
    private func buildPipeline(colorFormat: MTLPixelFormat) {
        let src = Renderer.shaderSource
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: src, options: nil) }
        catch { fatalError("shader compile failed: \(error)") }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = colorFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { fatalError("pipeline failed: \(error)") }

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)

        // Build sky pipeline from the same already-compiled library.
        let sdesc = MTLRenderPipelineDescriptor()
        sdesc.vertexFunction   = lib.makeFunction(name: "skyVmain")
        sdesc.fragmentFunction = lib.makeFunction(name: "skyFmain")
        sdesc.colorAttachments[0].pixelFormat = colorFormat
        sdesc.depthAttachmentPixelFormat = .depth32Float
        do { skyPipeline = try device.makeRenderPipelineState(descriptor: sdesc) }
        catch { fatalError("sky pipeline failed: \(error)") }
        let sdd = MTLDepthStencilDescriptor()
        sdd.depthCompareFunction = .always
        sdd.isDepthWriteEnabled  = false
        skyDepthState = device.makeDepthStencilState(descriptor: sdd)

        // Build underwater fullscreen post-pass pipeline (alpha blending, no depth write).
        let udesc = MTLRenderPipelineDescriptor()
        udesc.vertexFunction   = lib.makeFunction(name: "underwaterVmain")
        udesc.fragmentFunction = lib.makeFunction(name: "underwaterFmain")
        udesc.colorAttachments[0].pixelFormat = colorFormat
        udesc.colorAttachments[0].isBlendingEnabled = true
        udesc.colorAttachments[0].sourceRGBBlendFactor      = .sourceAlpha
        udesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        udesc.colorAttachments[0].sourceAlphaBlendFactor    = .one
        udesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
        udesc.depthAttachmentPixelFormat = .depth32Float
        do { underwaterPipeline = try device.makeRenderPipelineState(descriptor: udesc) }
        catch { fatalError("underwater pipeline failed: \(error)") }
    }

    private func createEngine() {
        var cfg = bf_engine_config()
        cfg.abi_version = BF_ABI_VERSION
        cfg.role = BF_ROLE_SINGLEPLAYER
        cfg.start_mode = BF_MODE_SURVIVAL      // walk + gravity (press C to fly)
        cfg.render_distance_chunks = 10
        cfg.memory_budget_bytes = 10 * 1024 * 1024 * 1024
        cfg.content_dir = persistentCString(Bundle.main.resourcePath ?? ".")
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
        // Gameplay effects -> audio + particles.
        bf_set_event_callback(e, eventTrampoline, Unmanaged.passUnretained(self).toOpaque())
        _ = bf_world_load(e)              // restores a prior session, else generates
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

    // Map engine effect codes (0 break,1 place,2 step,3 jump,4 craft,5 befriend,
    // 6 quest) to sounds + break particles.
    func handleEvent(_ ev: bf_event) {
        guard ev.kind == BF_EVT_SFX else { return }
        switch ev.i {
        case 0: audio?.play(.breakBlock); spawnBreakParticles(ev.pos)
        case 1: audio?.play(.place)
        case 2: audio?.play(.step)
        case 3: audio?.play(.jump)
        case 4: audio?.play(.craft)
        case 5: audio?.play(.befriend)
        case 6: audio?.play(.questComplete)
        case 7: audio?.play(.pickup)
        default: break
        }
    }

    func spawnBreakParticles(_ pos: bf_ivec3) { particles.spawn(at: pos) }

    func shutdown() {
        if let e = engine { _ = bf_world_save(e); bf_engine_destroy(e); engine = nil }
    }
    deinit { shutdown() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let e = engine,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor else { return }

        let now = CACurrentMediaTime()
        let dt = now - lastTime; lastTime = now
        frameCounter += 1
        registry.currentFrame = frameCounter

        // 1) input -> engine
        var input = gameView?.makeFrameInput() ?? bf_frame_input()
        _ = bf_frame_begin(e, &input, dt)
        if let actions = gameView?.drainActions() {
            for var a in actions { bf_input_action(e, &a) }
        }

        // 2) acquire render + HUD (this also remeshes dirty chunks)
        var frame = bf_render_frame()
        _ = bf_frame_acquire_render(e, &frame)

        // 3) camera: engine view, proj recomputed for the live aspect
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let fovy: Float = 1.20
        let proj = Renderer.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 512)
        let viewM = Renderer.mat(frame.camera.view)
        let viewProj = proj * viewM
        let sun = frame.camera.sun_dir

        // Wall-clock seconds (mod 3600 to stay finite) for water + weather animation.
        let wallClock = Float(now.truncatingRemainder(dividingBy: 3600.0))
        let isUnderwater = frame.camera.underwater

        // --- Camera basis for sky dome view-ray reconstruction ---
        // The view matrix is column-major: columns are (right, up, -forward, translation)
        // in view space but the rows are the world-space basis axes.
        // Row 0 of view matrix = world right, row 1 = world up, row 2 = world -forward.
        // simd_float4x4 columns: c0=(r0,r1,r2,r3), so row0.x=c0[0], row0.y=c1[0], row0.z=c2[0]
        let camRight = SIMD3<Float>(viewM.columns.0.x, viewM.columns.1.x, viewM.columns.2.x)
        let camUp    = SIMD3<Float>(viewM.columns.0.y, viewM.columns.1.y, viewM.columns.2.y)
        // Forward = -row2 (view matrix row2 points TOWARD -Z in view, which is behind camera)
        let camFwd   = SIMD3<Float>(-viewM.columns.0.z, -viewM.columns.1.z, -viewM.columns.2.z)
        let tanHalfFov = tan(fovy * 0.5)

        // Extract camera world position from inverse view: position = -(R^T * t)
        // where t = view.columns.3. For an orthonormal view matrix R^T = R^-1.
        let vt = viewM.columns.3
        let camPosW = SIMD4<Float>(
            -(viewM.columns.0.x * vt.x + viewM.columns.1.x * vt.y + viewM.columns.2.x * vt.z),
            -(viewM.columns.0.y * vt.x + viewM.columns.1.y * vt.y + viewM.columns.2.y * vt.z),
            -(viewM.columns.0.z * vt.x + viewM.columns.1.z * vt.y + viewM.columns.2.z * vt.z),
            0
        )

        // 4) sky + depth clear
        let sky = skyColor(frame.camera.time_of_day)
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: sky.0, green: sky.1, blue: sky.2, alpha: 1)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.depthAttachment.clearDepth = 1.0
        passDesc.depthAttachment.loadAction = .clear

        if let cmd = queue.makeCommandBuffer(),
           let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {

            // --- Sky pass (fullscreen, no depth write, drawn first) ---
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

            // Water/extra uniforms bound once for entire terrain pass (fragment index 2).
            var wu = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                   cameraPosW: camPosW)
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)

            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = registry.lookup(d.vertex_buffer),
                      let ibuf = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(
                    viewProj: viewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day))
                enc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ibuf,
                                          indexBufferOffset: Int(d.index_offset))
            }
            // Creatures + break particles on top of the world.
            enc.setDepthStencilState(depthState)
            entityRenderer.encode(enc, viewProj: viewProj, entities: frame.entities, count: Int(frame.entity_count))
            particles.update(Float(dt))
            particles.encode(enc, viewProj: viewProj)

            // --- Underwater post-pass (fullscreen overlay, alpha blend, no depth write) ---
            if underwaterPipeline != nil && isUnderwater > 0.01 {
                enc.setRenderPipelineState(underwaterPipeline)
                enc.setDepthStencilState(skyDepthState)  // always-pass, no write
                enc.setCullMode(.none)
                var wuPost = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                           cameraPosW: camPosW)
                enc.setVertexBytes(&wuPost, length: MemoryLayout<WaterUniforms>.stride, index: 0)
                enc.setFragmentBytes(&wuPost, length: MemoryLayout<WaterUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            enc.endEncoding()
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

    /// Clear color used as a base horizon tint (the sky pass renders on top).
    private func skyColor(_ t: Float) -> (Double, Double, Double) {
        let dayT  = Double(max(0.0, sin(t * .pi)))
        let dawnT = Double(max(0.0, 1.0 - abs(t - 0.25) * 8.0))
        let duskT = Double(max(0.0, 1.0 - abs(t - 0.75) * 8.0))
        let sunsetT = min(dawnT + duskT, 1.0)
        // Night: dark indigo horizon
        let nr = 0.08; let ng = 0.10; let nb = 0.22
        // Day: pale horizon blue
        let dr = 0.68; let dg = 0.84; let db = 1.00
        // Sunset: warm orange
        let sr = 1.00; let sg = 0.52; let sb = 0.18
        var r = nr + (dr - nr) * dayT
        var g = ng + (dg - ng) * dayT
        var b = nb + (db - nb) * dayT
        r = r + (sr - r) * sunsetT * 0.85
        g = g + (sg - g) * sunsetT * 0.85
        b = b + (sb - b) * sunsetT * 0.85
        return (min(r, 1.0), min(g, 1.0), min(b, 1.0))
    }

    // bf_mat4 (column-major float[16]) -> simd_float4x4
    static func mat(_ m: bf_mat4) -> simd_float4x4 {
        let c = m.m
        return simd_float4x4(columns: (
            SIMD4<Float>(c.0, c.1, c.2, c.3),
            SIMD4<Float>(c.4, c.5, c.6, c.7),
            SIMD4<Float>(c.8, c.9, c.10, c.11),
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

    // ---- shader (MSL) ------------------------------------------------------
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // =========================================================
    // TERRAIN STRUCTS & HELPERS
    // =========================================================
    struct PackedVertex { uint pos; uint normuv; ushort material; uchar sky; uchar block; uint reserved; };
    struct Uniforms { float4x4 viewProj; float4 chunkOrigin; float4 sunDirTime; };
    // WaterUniforms: separate small uniform, not engine-filled.
    // layout: [0] wallClockSecs, [1] underwater, [2] pad0, [3] pad1,
    //         [4-6] cameraPos.xyz, [7] pad2  (float4x2 = 32 bytes total)
    // Using float4 for cameraPos slot to guarantee 16-byte alignment match with Swift SIMD3.
    struct WaterUniforms { float wallClockSecs; float underwater; float pad0; float pad1;
                           float4 cameraPosW; };  // xyz = world pos, w = pad
    // Convenience accessor inside shaders:
    #define UW_CAM_POS(wu) (wu).cameraPosW.xyz

    struct VOut {
        float4 position [[position]];
        float3 color;
        float  shade;
        float  sat;
        float3 worldPos;              // for per-face procedural texture
        uint   faceNorm [[flat]];     // 0-5 — must be flat (uint not interpolatable)
        uint   material [[flat]];     // block id — flat
    };

    static float faceShade(uint n) {
        if (n == 2u) return 1.0;   // top
        if (n == 3u) return 0.45;  // bottom
        return 0.72;               // sides
    }

    // Distinct hue fallback for unmapped ids
    static float3 hashColor(uint m) {
        float h = fract(float(m) * 0.6180339887f);
        float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
        float3 p = abs(fract(float3(h,h,h) + k) * 6.0 - 3.0);
        return clamp(p - 1.0, 0.0, 1.0) * 0.5 + 0.4;
    }

    // Full per-block color table (ids 1-40 from content/blocks/*.json)
    static float3 materialColor(uint m) {
        switch (m) {
            // --- terrain.json ---
            case  1u: return float3(0.35, 0.75, 0.28);  // grass — vivid green
            case  2u: return float3(0.54, 0.38, 0.24);  // dirt — earthy brown
            case  3u: return float3(0.55, 0.55, 0.58);  // stone — cool grey
            case  6u: return float3(0.90, 0.83, 0.58);  // sand — warm tan
            case  9u: return float3(0.14, 0.42, 0.82);  // water — deeper blue (animated separately)
            case 10u: return float3(0.44, 0.44, 0.46);  // cobblestone — dark grey
            case 11u: return float3(0.50, 0.47, 0.42);  // gravel — grey-beige
            case 12u: return float3(0.93, 0.96, 1.00);  // snow_layer — bright white
            case 13u: return float3(0.72, 0.86, 1.00);  // ice — pale icy blue
            case 14u: return float3(0.60, 0.66, 0.78);  // clay — blue-grey
            case 15u: return float3(0.28, 0.24, 0.36);  // dim_stone — dark purple-grey
            case 16u: return float3(0.32, 0.22, 0.18);  // dim_dirt — deep dark brown
            // --- building.json ---
            case  4u: return float3(0.72, 0.54, 0.30);  // oak_planks — warm honey wood
            case  5u: return float3(0.28, 0.60, 0.24);  // oak_leaves — lush green
            case  8u: return float3(0.58, 0.58, 0.64);  // stone_brick — grey
            case 21u: return float3(0.46, 0.32, 0.18);  // oak_log — dark bark
            case 22u: return float3(0.80, 0.78, 0.68);  // birch_log — pale cream bark
            case 23u: return float3(0.82, 0.76, 0.58);  // birch_planks — light cream
            case 24u: return float3(0.76, 0.38, 0.28);  // clay_brick — terracotta red
            case 25u: return float3(0.75, 0.93, 1.00);  // glass_pane — pale cyan
            case 26u: return float3(0.30, 0.85, 0.75);  // colored_glass — vibrant teal
            case 27u: return float3(0.55, 0.80, 0.35);  // birch_leaves — bright lime
            case 28u: return float3(0.94, 0.92, 0.88);  // wool_block — soft cream
            case 29u: return float3(0.42, 0.52, 0.38);  // mossy_stone — green-grey
            // --- ores.json ---
            case 17u: return float3(0.40, 0.40, 0.42);  // coal_ore — dark flecked stone
            case 18u: return float3(0.65, 0.44, 0.30);  // copper_ore — orange-brown
            case 19u: return float3(0.60, 0.58, 0.54);  // iron_ore — tan-grey
            case 20u: return float3(0.52, 0.44, 0.72);  // crystal_ore — purple stone
            // --- functional.json ---
            case  7u: return float3(1.00, 0.92, 0.45);  // glow_block — warm gold
            case 30u: return float3(0.60, 0.42, 0.22);  // crafting_table — dark wood
            case 31u: return float3(0.75, 0.58, 0.28);  // chest — golden oak
            case 32u: return float3(1.00, 0.70, 0.20);  // torch — orange flame
            case 33u: return float3(0.65, 0.48, 0.28);  // oak_door — medium wood
            case 34u: return float3(0.60, 0.96, 0.98);  // beacon — cyan glow
            case 35u: return float3(0.80, 0.70, 1.00);  // crystal_lamp — soft purple
            // --- decorative.json ---
            case 36u: return float3(0.95, 0.18, 0.18);  // flower_red — vivid red
            case 37u: return float3(1.00, 0.90, 0.10);  // flower_yellow — bright yellow
            case 38u: return float3(0.40, 0.78, 0.25);  // tall_grass — fresh green
            case 39u: return float3(0.58, 0.38, 0.22);  // mushroom — warm brown cap
            case 40u: return float3(0.95, 0.50, 0.90);  // color_crystal — magenta-pink
            default:  return hashColor(m);
        }
    }

    // =========================================================
    // PROCEDURAL TEXTURE HELPERS
    // =========================================================

    // Fast integer hash (Wang hash variant) — returns 0..1
    static float uhash(uint v) {
        v ^= v >> 17u; v *= 0xbf324c81u;
        v ^= v >> 11u; v *= 0x9f34a21du;
        v ^= v >> 16u;
        return float(v) * (1.0 / 4294967296.0);
    }
    // Hash of three ints — identifies the unique voxel
    static float voxelHash(int3 vi) {
        uint h = (uint(vi.x) * 73856093u) ^ (uint(vi.y) * 19349663u) ^ (uint(vi.z) * 83492791u);
        return uhash(h);
    }
    // 2-D value noise on integer lattice (fast, no trig)
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
    // Cheap 2-octave fBm (used for clouds too)
    static float fbm2(float2 p) {
        return noise2(p)*0.60 + noise2(p*2.1+float2(3.7,1.1))*0.30 + noise2(p*4.3+float2(1.3,5.7))*0.10;
    }

    // Per-face UV: project world pos onto the dominant plane for the face
    static float2 faceUV(float3 wp, uint face) {
        if (face == 0u || face == 1u) return wp.yz;  // +X/-X face
        if (face == 2u || face == 3u) return wp.xz;  // +Y/-Y face
        return wp.xy;                                  // +Z/-Z face
    }

    // Compute a procedural detail multiplier (0.80..1.22) for a block face.
    // Combines: (a) per-voxel brightness jitter, (b) grain noise.
    static float blockDetail(float3 worldPos, uint face, uint matID) {
        int3 vi = int3(floor(worldPos));          // which voxel
        float vHash = voxelHash(vi);              // stable per-voxel scalar

        // (a) per-voxel brightness jitter: adjacent blocks differ ±8%
        float jitter = (vHash - 0.5) * 0.16;

        // (b) sub-voxel grain: different scale per material family
        float2 uv = faceUV(worldPos, face);
        float grain;

        // Stone / ore family: medium-scale speckle + coarse crack overlay
        if (matID==3u||matID==8u||matID==10u||matID==11u||
            matID==15u||matID==17u||matID==18u||matID==19u||
            matID==20u||matID==29u) {
            float fine  = (noise2(uv * 8.0) - 0.5) * 0.22;
            float coarse= (noise2(uv * 2.5 + float2(5.1, 2.3)) - 0.5) * 0.10;
            grain = fine + coarse;
        }
        // Grass / leaves / foliage: finer organic noise with dual-scale
        else if (matID==1u||matID==5u||matID==27u||matID==38u) {
            float a = (fbm2(uv * 5.5) - 0.5) * 0.20;
            float b = (noise2(uv * 14.0 + float2(1.7, 3.3)) - 0.5) * 0.08;
            grain = a + b;
        }
        // Wood / planks: linear ring grain (rotated UV)
        else if (matID==4u||matID==21u||matID==22u||matID==23u||
                 matID==30u||matID==31u||matID==33u) {
            float2 ruv = float2(uv.x+uv.y, uv.x-uv.y) * 3.5;
            float ring  = (noise2(ruv) - 0.5) * 0.16;
            float stripe= sin((uv.x + uv.y) * 6.28318f * 1.2f) * 0.05;
            grain = ring + stripe;
        }
        // Sand / gravel: gritty high-frequency speckle
        else if (matID==6u||matID==11u||matID==14u) {
            float coarse = (noise2(uv * 5.0) - 0.5) * 0.14;
            float grit   = (noise2(uv * 18.0 + float2(2.2, 7.1)) - 0.5) * 0.10;
            grain = coarse + grit;
        }
        // Snow / ice: gentle subtle shimmer
        else if (matID==12u||matID==13u) {
            grain = (noise2(uv * 11.0) - 0.5) * 0.08;
        }
        // Glowing blocks: gentle pulsing brightness (no grain clash)
        else if (matID==7u||matID==32u||matID==34u||matID==35u||matID==40u) {
            grain = 0.0;
        }
        // Clay brick / terracotta: mortared look (dark recessed grid)
        else if (matID==24u) {
            float bx = fract(uv.x * 2.0);
            float by = fract(uv.y * 1.0);
            float mortar = smoothstep(0.0, 0.08, bx) * smoothstep(0.0, 0.08, 1.0-bx)
                         * smoothstep(0.0, 0.10, by) * smoothstep(0.0, 0.10, 1.0-by);
            grain = (mortar - 0.5) * 0.22 + (noise2(uv * 7.0) - 0.5) * 0.06;
        }
        // Dim blocks: heavy dark grain
        else if (matID==15u||matID==16u) {
            grain = (fbm2(uv * 4.0) - 0.5) * 0.24;
        }
        else {
            grain = (noise2(uv * 5.0) - 0.5) * 0.10;
        }

        return 1.0 + jitter + grain;
    }

    // =========================================================
    // TERRAIN VERTEX SHADER
    // =========================================================
    vertex VOut vmain(uint vid [[vertex_id]],
                      device const PackedVertex* verts [[buffer(0)]],
                      constant Uniforms& u [[buffer(1)]]) {
        PackedVertex p = verts[vid];
        float x = float(p.pos & 0x3f);
        float y = float((p.pos >> 6) & 0x3f);
        float z = float((p.pos >> 12) & 0x3f);
        float3 world = u.chunkOrigin.xyz + float3(x, y, z);
        uint n = p.normuv & 7u;
        // Light = max(sky*day, blocklight), floored by ambient; modulated by a
        // gentle per-face directional term. (Track F per-voxel light.)
        float dayB = 0.15 + 0.85 * max(0.0, sin(u.sunDirTime.w * 3.14159265f));
        float skyC  = (float(p.sky)   / 15.0) * dayB;
        float blockC = float(p.block) / 15.0;
        float lightLevel = max(max(skyC, blockC), 0.08);
        float facing = 0.62 + 0.38 * faceShade(n);
        float shade  = clamp(lightLevel * facing, 0.0, 1.0);
        VOut o;
        o.position = u.viewProj * float4(world, 1.0);
        // Warm tint where block light dominates (torches/glow feel cosy).
        float3 base = materialColor(uint(p.material));
        o.color    = mix(base, base * float3(1.15, 1.02, 0.8), clamp(blockC - skyC, 0.0, 1.0));
        o.shade    = shade;
        o.sat      = u.chunkOrigin.w;   // per-region Dim saturation (0=grey..1=full)
        o.worldPos = world;
        o.faceNorm = n;
        o.material = uint(p.material);
        return o;
    }

    // =========================================================
    // TERRAIN FRAGMENT SHADER
    // =========================================================
    fragment float4 fmain(VOut in [[stage_in]],
                          constant WaterUniforms& wu [[buffer(2)]]) {
        uint mat = in.material;

        // ---- Water (block id 9) special path ----
        if (mat == 9u) {
            float t = wu.wallClockSecs;
            float2 uv = in.worldPos.xz;   // horizontal UV for water surface

            // Two layers of scrolling normal noise — orthogonal drift directions
            float wave1 = noise2(uv * 0.8  + float2( t * 0.22,  t * 0.14));
            float wave2 = noise2(uv * 1.40 + float2(-t * 0.17,  t * 0.28));
            float wave3 = noise2(uv * 2.80 + float2( t * 0.35, -t * 0.19));
            float ripple = wave1 * 0.50 + wave2 * 0.35 + wave3 * 0.15;
            // Remap to -1..1 range, use as brightness variation
            float rippleN = ripple * 2.0 - 1.0;  // -1..1

            // Base water color — slightly deeper blue-cyan
            float3 waterBase = float3(0.12, 0.40, 0.80);

            // Fresnel-ish: top face is brighter, sides see edge darkening
            float fresnelBias = (in.faceNorm == 2u) ? 0.30 : 0.08;
            float fresnelAmt  = fresnelBias + rippleN * 0.12;

            // Sun specular: glint using ripple as a perturbed normal
            // We fake a normal from the two noise layers
            float2 nAB = float2(
                noise2(uv * 1.2 + float2(t * 0.22 + 0.1, t * 0.14)) - wave1,
                noise2(uv * 1.2 + float2(t * 0.22, t * 0.14 + 0.1)) - wave1
            ) * 4.0;
            float3 perturbedN = normalize(float3(nAB.x, 1.4, nAB.y));
            // Simple Phong-ish sun direction (approximate, no camera matrix)
            float3 sunDir = normalize(float3(0.5, 0.9, 0.3));  // constant approx upward sun
            float spec = pow(max(0.0, dot(perturbedN, sunDir)), 22.0);
            float specular = spec * 0.55 * in.shade;  // modulated by light level

            // Assemble final water color
            float3 col = waterBase * in.shade;
            // Ripple brightening — lighter crest, darker trough
            col *= 1.0 + rippleN * 0.20;
            // Fresnel highlight (whitish)
            col = mix(col, float3(0.85, 0.95, 1.00), clamp(fresnelAmt, 0.0, 0.45));
            // Sun specular glint (warm white)
            col += float3(1.0, 0.98, 0.88) * specular;

            // Dim saturation
            float lum = dot(col, float3(0.299, 0.587, 0.114));
            col = mix(float3(lum), col, clamp(in.sat, 0.0, 1.0));
            return float4(clamp(col, 0.0, 1.0), 1.0);
        }

        // ---- Standard block path ----
        float detail = blockDetail(in.worldPos, in.faceNorm, in.material);
        float3 col = in.color * in.shade * clamp(detail, 0.75, 1.28);
        // Dim regions drain toward grey; restoring (e.g. a glow block) brings
        // the color back. Luminance-preserving desaturation.
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(lum), col, clamp(in.sat, 0.0, 1.0));

        // ---- Underwater distance fog (hides caves beyond ~6-8 blocks) ----
        // When the camera is submerged, apply a dense exponential distance fog
        // so geometry farther than ~6 blocks fades to opaque blue-green.
        // This prevents seeing cave systems through the water column above them.
        if (wu.underwater > 0.5) {
            float dist = length(in.worldPos - UW_CAM_POS(wu));
            // Visibility ~6 blocks: fog density chosen so e^(-density*6) ~ 0.05
            // density = -ln(0.05)/6 ≈ 0.499
            float fogDensity = 0.50;
            float fogFactor = exp(-fogDensity * dist);   // 1=near(clear), 0=far(solid)
            fogFactor = clamp(fogFactor, 0.0, 1.0);
            // Fog target: deep water colour
            float3 waterFogColor = float3(0.04, 0.22, 0.38);
            col = mix(waterFogColor, col, fogFactor);
        }

        return float4(col, 1.0);
    }

    // =========================================================
    // SKY PASS — fullscreen triangle, no depth write
    //
    // Key fix: we reconstruct a world-space VIEW RAY per pixel using
    // the camera basis vectors passed in SkyUniforms (right, up, forward)
    // and the tangent of the half-FOV.  Every sky feature (gradient, sun,
    // moon, stars, clouds) is keyed on this ray direction so the dome
    // stays fixed in the world as you turn and look up/down.
    // =========================================================
    // SkyUniforms must match Swift SkyUniforms struct (64 bytes).
    struct SkyUniforms {
        float4 sunDirTime;   // xyz sun dir (pointing FROM sun downward), w time_of_day 0..1
        float4 camRight;     // xyz world right,   w = tanHalfFov
        float4 camUp;        // xyz world up,       w = aspect ratio (w/h)
        float4 camFwd;       // xyz world forward (into scene), w unused
    };
    struct SkyVOut { float4 position [[position]]; float2 ndc; };

    vertex SkyVOut skyVmain(uint vid [[vertex_id]],
                            constant SkyUniforms& su [[buffer(0)]]) {
        // Fullscreen triangle in clip space
        float2 pos;
        if      (vid == 0u) pos = float2(-1.0, -1.0);
        else if (vid == 1u) pos = float2( 3.0, -1.0);
        else                pos = float2(-1.0,  3.0);
        SkyVOut o;
        o.position = float4(pos, 0.9999, 1.0);  // depth almost=1 -> behind terrain
        o.ndc      = pos;                        // NDC coords passed to fragment
        return o;
    }

    // fBm 2-octave for clouds (reuse noise2 defined above)
    static float cloudFbm(float2 p) {
        return fbm2(p);
    }

    fragment float4 skyFmain(SkyVOut in [[stage_in]],
                              constant SkyUniforms& su [[buffer(0)]],
                              constant WaterUniforms& wu [[buffer(1)]]) {
        float t   = su.sunDirTime.w;        // 0..1 time of day
        float3 sd = su.sunDirTime.xyz;      // sun direction pointing FROM sun (downward)
        float clk = wu.wallClockSecs;       // wall-clock seconds for fast animation

        // --- Reconstruct world-space view ray for this pixel ---
        // NDC x is screen-right (+1 = right edge), NDC y is screen-up (+1 = top).
        // Metal NDC: y goes up (+1 top, -1 bottom), x goes right.
        float tanHalfFov = su.camRight.w;
        float aspect     = su.camUp.w;
        float3 right     = su.camRight.xyz;
        float3 up        = su.camUp.xyz;
        float3 fwd       = su.camFwd.xyz;
        // Build ray: forward + right*ndcX*(aspect*tanHalf) + up*ndcY*tanHalf
        float3 ray = normalize(fwd
                               + right * (in.ndc.x * aspect * tanHalfFov)
                               + up    * (in.ndc.y * tanHalfFov));

        // --- Time ---
        float dayT    = max(0.0, sin(t * 3.14159265f));       // 0=midnight, 1=noon
        float dawnT   = max(0.0, 1.0 - abs(t - 0.25) * 8.0); // peaks at dawn
        float duskT   = max(0.0, 1.0 - abs(t - 0.75) * 8.0); // peaks at dusk
        float sunsetT = dawnT + duskT;

        // --- Sky gradient keyed on world-space elevation (ray.y) ---
        // ray.y: -1=straight down, 0=horizon, +1=straight up
        float3 zenithDay    = float3(0.22, 0.50, 0.92);
        float3 horizDay     = float3(0.68, 0.84, 1.00);
        float3 zenithSunset = float3(0.22, 0.14, 0.45);
        float3 horizSunset  = float3(1.00, 0.52, 0.18);
        float3 zenithNight  = float3(0.03, 0.04, 0.12);
        float3 horizNight   = float3(0.08, 0.10, 0.22);

        float3 zenith = mix(mix(zenithNight, zenithDay, dayT), zenithSunset, sunsetT * 0.7);
        float3 horiz  = mix(mix(horizNight,  horizDay,  dayT), horizSunset,  sunsetT * 0.85);

        // Gradient: smoothly from horizon (ray.y~0) to zenith (ray.y~1)
        // Use a smooth band: horizon band near 0, zenith above 0.25.
        float gradT  = smoothstep(0.0, 0.45, ray.y);
        float3 skyCol = mix(horiz, zenith, gradT);

        // Below horizon: show a darker ground/underground colour so the sky
        // doesn't bleed through the terrain seam.
        float3 groundCol = mix(float3(0.20, 0.16, 0.12), float3(0.35, 0.30, 0.22), dayT);
        skyCol = mix(groundCol, skyCol, smoothstep(-0.05, 0.08, ray.y));

        // Atmospheric horizon haze: slightly lighter/warmer band near ray.y==0
        float horizBand = exp(-abs(ray.y) * 12.0);
        float3 hazeCol = mix(float3(0.80, 0.86, 1.00), float3(1.00, 0.70, 0.40), sunsetT * 0.7);
        skyCol = mix(skyCol, hazeCol, horizBand * 0.35 * dayT + horizBand * 0.25 * sunsetT);

        // --- Sun disc (keyed on ray direction vs. sun direction) ---
        // sd points FROM sun downward, so the sun is in the direction -sd.
        float3 sunDir3 = normalize(-sd);   // direction TOWARD the sun in world space
        float sunDot = dot(ray, sunDir3);
        float sunDisc  = smoothstep(0.9975, 1.0000, sunDot);   // hard disc edge
        float sunInner = smoothstep(0.9992, 1.0000, sunDot);   // bright core
        float sunGlow1 = smoothstep(0.940,  1.0000, sunDot) * 0.22 * max(dayT, sunsetT * 0.5);
        float sunGlow2 = smoothstep(0.984,  1.0000, sunDot) * 0.35 * max(dayT, sunsetT * 0.5);
        float3 sunColor  = mix(float3(1.0, 0.72, 0.35), float3(1.0, 0.98, 0.85), dayT);
        float3 sunCorona = sunColor * 1.15;
        // Visibility: sun visible during day + vivid at sunset, fades at night
        float sunVis = max(dayT, sunsetT * 0.6);
        skyCol += sunGlow1 * sunCorona;
        skyCol += sunGlow2 * sunCorona;
        skyCol = mix(skyCol, sunColor,          sunDisc  * sunVis);
        skyCol = mix(skyCol, float3(1.0, 1.0, 0.96), sunInner * sunVis);

        // --- Moon (opposite the sun, visible at night) ---
        float3 moonDir3 = -sunDir3;
        float moonDot  = dot(ray, moonDir3);
        float moonDisc = smoothstep(0.9990, 1.000, moonDot) * (1.0 - dayT) * 0.9;
        skyCol = mix(skyCol, float3(0.90, 0.92, 1.00), moonDisc);

        // --- Stars (keyed on ray direction, not screen UV) ---
        if (dayT < 0.5) {
            float starFade = 1.0 - smoothstep(0.05, 0.35, dayT);
            starFade *= smoothstep(0.0, 0.10, ray.y);  // only above horizon
            // Discretise the ray into a grid on the hemisphere for stable star positions
            float2 starUV = floor((ray.xz / max(ray.y + 0.01, 0.01)) * 60.0 + float2(200.0));
            float starH = uhash(uint(starUV.x) * 3141u + uint(starUV.y) * 1618u
                                 + uint(starUV.x * starUV.y) * 97u);
            float starBright = step(0.986, starH);
            skyCol += float3(starBright * starFade * 0.90);
        }

        // --- Weather cycle ---
        // Slow sinusoidal cycle (~300 s period). 0=fair, 1=stormy.
        float weatherCycle = sin(clk * (3.14159265f / 150.0f)) * 0.5f + 0.5f;
        float overcast = smoothstep(0.52, 0.80, weatherCycle) * 0.65;

        // --- Overcast cloud layer (ray-space, not screen-space) ---
        if (overcast > 0.01) {
            // Project ray onto a horizontal cloud plane at height 1 above camera.
            // Only sample when ray points upward (avoid divide-by-zero and below-horizon artefacts).
            float cloudPlaneHit = (ray.y > 0.02) ? (1.0 / ray.y) : 0.0;
            float2 ocUV = ray.xz * cloudPlaneHit * 0.35 + float2(clk * 0.006, clk * 0.003);
            float ocCloud = cloudFbm(ocUV * 1.5);
            ocCloud = smoothstep(0.38, 0.62, ocCloud);
            float3 ocColor = mix(float3(0.55, 0.57, 0.64), float3(0.72, 0.74, 0.80), dayT);
            float ocFade = smoothstep(0.0, 0.12, ray.y);   // fade at/below horizon
            skyCol = mix(skyCol, ocColor, ocCloud * overcast * ocFade);
        }

        // --- Rain streaks (screen-space is acceptable for rain — droplets fall straight) ---
        float rainStrength = smoothstep(0.60, 0.82, weatherCycle);
        if (rainStrength > 0.01) {
            // Use NDC directly — rain streaks ARE screen-aligned (they fall vertically).
            float2 rUV  = float2(in.ndc.x * 40.0, in.ndc.y * 3.5 + clk * 2.0);
            float2 rUV2 = rUV * float2(1.4, 1.0) + float2(9.1, 0.0);
            float streak = noise2(rUV) * noise2(rUV2);
            float rain = pow(max(0.0, streak - 0.36), 2.2) * 10.0;
            rain = clamp(rain, 0.0, 1.0);
            float3 rainColor = mix(float3(0.62, 0.70, 0.84), float3(0.50, 0.62, 0.78), dayT);
            // Keep rain only in the upper ~70% of screen (not on horizon)
            float rainFade = smoothstep(-0.6, 0.0, in.ndc.y);
            skyCol = mix(skyCol, rainColor, rain * rainStrength * 0.30 * rainFade);
        }

        // --- Fair-weather clouds (ray-space, drift horizontally) ---
        float fairCloud = clamp(1.0 - overcast * 1.6, 0.0, 1.0);
        float cloudVis  = smoothstep(0.12, 0.38, dayT)
                        * smoothstep(0.0, 0.10, ray.y)   // above horizon only
                        * fairCloud;
        if (cloudVis > 0.001) {
            // Project ray onto cloud plane at height 1 (sky dome projection).
            float ry = max(ray.y, 0.02);
            float2 cloudUV  = (ray.xz / ry) * 0.30 + float2(clk * 0.010,  clk * 0.004);
            float2 cloudUV2 = (ray.xz / ry) * 0.18 + float2(-clk * 0.007, clk * 0.003);
            float cloud  = cloudFbm(cloudUV);
            float cloud2 = cloudFbm(cloudUV2);
            float cloudD = smoothstep(0.48, 0.70, (cloud + cloud2 * 0.5) / 1.5);

            float3 cloudTop  = mix(float3(0.96, 0.96, 1.00),
                                   mix(float3(1.0, 0.82, 0.65), float3(0.96, 0.96, 1.0), dayT),
                                   sunsetT * 0.60);
            // Darker underside: more prominent when looking up at a low angle
            float underBelly = smoothstep(0.06, 0.35, ray.y);
            float3 cloudCol  = mix(cloudTop * float3(0.72, 0.73, 0.80), cloudTop, underBelly);
            skyCol = mix(skyCol, cloudCol, cloudD * cloudVis * 0.90);
        }

        return float4(skyCol, 1.0);
    }

    // =========================================================
    // UNDERWATER POST PASS — fullscreen overlay (alpha blended)
    // Drawn AFTER terrain + particles. Fades geometry to blue-green
    // with distance so cave systems below are hidden while submerged.
    // =========================================================
    struct UWVOut { float4 position [[position]]; float2 uv; };

    vertex UWVOut underwaterVmain(uint vid [[vertex_id]],
                                  constant WaterUniforms& wu [[buffer(0)]]) {
        float2 pos;
        if      (vid == 0u) pos = float2(-1.0, -1.0);
        else if (vid == 1u) pos = float2( 3.0, -1.0);
        else                pos = float2(-1.0,  3.0);
        UWVOut o;
        o.position = float4(pos, 0.0, 1.0);  // depth 0 — in front of everything
        o.uv = pos * 0.5 + 0.5;
        return o;
    }

    fragment float4 underwaterFmain(UWVOut in [[stage_in]],
                                    constant WaterUniforms& wu [[buffer(0)]]) {
        float uw = wu.underwater;
        if (uw < 0.01) { discard_fragment(); }

        float t = wu.wallClockSecs;

        // Caustic shimmer: slow moving bright patches on screen
        float2 cUV1 = in.uv * float2(3.0, 2.5) + float2(t * 0.08, t * 0.05);
        float2 cUV2 = in.uv * float2(2.2, 3.1) + float2(-t * 0.06, t * 0.09);
        float caustic = noise2(cUV1) * 0.6 + noise2(cUV2) * 0.4;
        caustic = smoothstep(0.52, 0.78, caustic) * 0.18;  // subtle bright patches

        // Screen-space fog: stronger toward screen edges and near the bottom
        float edgeFog = 1.0 - 4.0 * (in.uv.x - 0.5) * (in.uv.x - 0.5)
                             - 4.0 * (in.uv.y - 0.5) * (in.uv.y - 0.5);
        edgeFog = clamp(edgeFog, 0.0, 1.0);
        // Fog that fills the lower half more (cave below)
        float depthFog = 1.0 - smoothstep(0.0, 0.7, in.uv.y);

        // Base underwater tint: blue-green
        float3 uwColor = float3(0.06, 0.28, 0.45);

        // Composite: tint over the whole frame, denser at edges + below
        float baseFog = 0.40;                // constant minimum overlay
        float edgeMod = (1.0 - edgeFog) * 0.30;
        float depthMod = depthFog * 0.28;
        float totalAlpha = clamp((baseFog + edgeMod + depthMod) * uw, 0.0, 0.78);

        // Add caustics as a brightening offset in the color
        float3 col = uwColor + float3(caustic * 0.8, caustic * 1.0, caustic * 0.6);

        return float4(col, totalAlpha);
    }
    """

}

// MARK: - Offscreen render self-test (CI: proves terrain pixels actually draw)

func runRenderSelfTest(savePath: String? = nil, width: Int = 320, height: Int = 240) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return false }
    let queue = device.makeCommandQueue()!
    let registry = BufferRegistry(device: device)

    // pipeline (same shader as the live renderer)
    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else {
        print("shader compile failed"); return false
    }
    let pdesc = MTLRenderPipelineDescriptor()
    pdesc.vertexFunction = lib.makeFunction(name: "vmain")
    pdesc.fragmentFunction = lib.makeFunction(name: "fmain")
    pdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
    pdesc.depthAttachmentPixelFormat = .depth32Float
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: pdesc) else {
        print("pipeline failed"); return false
    }
    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)
    // Sky pipeline (no depth write)
    let spdesc = MTLRenderPipelineDescriptor()
    spdesc.vertexFunction   = lib.makeFunction(name: "skyVmain")
    spdesc.fragmentFunction = lib.makeFunction(name: "skyFmain")
    spdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
    spdesc.depthAttachmentPixelFormat = .depth32Float
    let skyPipeline = try? device.makeRenderPipelineState(descriptor: spdesc)
    let sdsd = MTLDepthStencilDescriptor(); sdsd.depthCompareFunction = .always; sdsd.isDepthWriteEnabled = false
    let skyDepthState = device.makeDepthStencilState(descriptor: sdsd)
    let entR = EntityRenderer(device: device, colorFormat: .bgra8Unorm)

    // engine
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

    // offscreen targets
    let W = width, H = height
    let ctd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    ctd.usage = [.renderTarget]; ctd.storageMode = .shared
    let color = device.makeTexture(descriptor: ctd)!
    let dtd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: W, height: H, mipmapped: false)
    dtd.usage = [.renderTarget]; dtd.storageMode = .private
    let depth = device.makeTexture(descriptor: dtd)!

    let clear = (0.30, 0.12, 0.22)
    var rendered = false
    for f in 0..<48 {   // let the procedural world stream in before the snapshot
        registry.currentFrame = f
        var input = bf_frame_input()
        _ = bf_frame_begin(e, &input, 1.0/60.0)
        var frame = bf_render_frame()
        _ = bf_frame_acquire_render(e, &frame)

        let proj = Renderer.perspective(fovy: 1.20, aspect: Float(W)/Float(H), near: 0.05, far: 512)
        let viewProj = proj * Renderer.mat(frame.camera.view)
        let sun = frame.camera.sun_dir

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = color
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: clear.0, green: clear.1, blue: clear.2, alpha: 1)
        rp.depthAttachment.texture = depth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.storeAction = .dontCare

        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: rp)!
        // Sky pass first (no depth write)
        if let sp = skyPipeline {
            enc.setRenderPipelineState(sp)
            enc.setDepthStencilState(skyDepthState)
            enc.setCullMode(.none)
            // Identity camera basis for the self-test (looking -Z, world-up Y)
            var su = SkyUniforms(
                sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                camRight:   SIMD4<Float>(1, 0, 0, 0.6841),   // tanHalfFov for fovy=1.20
                camUp:      SIMD4<Float>(0, 1, 0, Float(W)/Float(H)),
                camFwd:     SIMD4<Float>(0, 0, -1, 0))
            enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
            enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
            var wuSky = WaterUniforms(wallClockSecs: Float(f) / 60.0, underwater: 0.0)
            enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        // Terrain pass
        enc.setRenderPipelineState(pipeline); enc.setDepthStencilState(depthState)
        enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
        var wu = WaterUniforms(wallClockSecs: Float(f) / 60.0, underwater: 0.0,
                               cameraPosW: SIMD4<Float>(0, 20, 0, 0))
        enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
        for i in 0..<Int(frame.draw_count) {
            let d = frame.draws[i]
            guard d.index_count > 0, let vb = registry.lookup(d.vertex_buffer), let ib = registry.lookup(d.index_buffer) else { continue }
            var u = Uniforms(viewProj: viewProj,
                             chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                             sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day))
            enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                      indexType: .uint32, indexBuffer: ib, indexBufferOffset: Int(d.index_offset))
            rendered = true
        }
        enc.setDepthStencilState(depthState)
        entR.encode(enc, viewProj: viewProj, entities: frame.entities, count: Int(frame.entity_count))
        enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        bf_frame_end(e); registry.collect()
    }
    guard rendered else { print("no draws encoded"); return false }

    // read back, count pixels that differ from the sky clear color (= terrain)
    var px = [UInt8](repeating: 0, count: W*H*4)
    color.getBytes(&px, bytesPerRow: W*4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    var terrain = 0
    for p in stride(from: 0, to: px.count, by: 4) {
        let b = Double(px[p])/255, g = Double(px[p+1])/255, r = Double(px[p+2])/255
        let dist = abs(r-clear.0) + abs(g-clear.1) + abs(b-clear.2)
        if dist > 0.15 { terrain += 1 }
    }
    let frac = Double(terrain) / Double(W*H)
    print(String(format: "OK: render self-test — %.1f%% of pixels are terrain (drew chunk meshes)", frac*100))

    if let path = savePath {
        // BGRA -> RGBA for the bitmap rep.
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
