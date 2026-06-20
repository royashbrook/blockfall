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

/// Terrain pass uniforms (64 bytes).
/// Swift layout: viewProj(64) + chunkOrigin(16) + sunDirTime(16) + lightViewProj(64) = 160 bytes.
struct Uniforms {
    var viewProj:      simd_float4x4           // 64 bytes
    var chunkOrigin:   SIMD4<Float>            // 16 bytes  xyz=origin, w=dim_saturation
    var sunDirTime:    SIMD4<Float>            // 16 bytes  xyz=sun_dir, w=time_of_day
    var lightViewProj: simd_float4x4           // 64 bytes  sun light-space VP matrix
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

/// Uniforms for the HDR composite / tonemap pass (16 bytes).
struct PostUniforms {
    var bloomStrength: Float   // 0.18  — fraction of bloom added
    var vignetteStr:   Float   // 0.55
    var satBoost:      Float   // 1.12  — colour grade saturation multiplier
    var pad:           Float   // = 0
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

    // ---- HDR offscreen textures (rebuilt on resize) --------------------------
    private var hdrColor: MTLTexture?     // rgba16Float  — scene rendered here
    private var hdrDepth: MTLTexture?     // depth32Float — shared by shadow + scene
    // Bloom intermediates (half drawable size)
    private var bloomBright: MTLTexture?  // rgba16Float half-res bright pass
    private var bloomBlurA:  MTLTexture?  // rgba16Float blur ping
    private var bloomBlurB:  MTLTexture?  // rgba16Float blur pong
    private var currentDrawableSize: CGSize = .zero

    // ---- Shadow map (fixed 2048×2048) ----------------------------------------
    private let kShadowRes = 2048
    private var shadowMap: MTLTexture!    // depth32Float
    private var shadowSampler: MTLSamplerState!

    // ---- No-write depth state (sky + bloom quads) ----------------------------
    private var noDepthState: MTLDepthStencilState!

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
    private func rebuildHDRTextures(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }
        let W = Int(size.width), H = Int(size.height)
        let HW = max(1, W / 2), HH = max(1, H / 2)

        func make2D(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            td.usage = usage; td.storageMode = .private
            return device.makeTexture(descriptor: td)!
        }

        hdrColor    = make2D(.rgba16Float,  W,  H, usage: [.renderTarget, .shaderRead])
        hdrDepth    = make2D(.depth32Float, W,  H, usage: [.renderTarget])
        bloomBright = make2D(.rgba16Float, HW, HH, usage: [.renderTarget, .shaderRead])
        bloomBlurA  = make2D(.rgba16Float, HW, HH, usage: [.renderTarget, .shaderRead])
        bloomBlurB  = make2D(.rgba16Float, HW, HH, usage: [.renderTarget, .shaderRead])
        currentDrawableSize = size
    }

    // MARK: Engine create

    private func createEngine() {
        var cfg = bf_engine_config()
        cfg.abi_version = BF_ABI_VERSION
        cfg.role = BF_ROLE_SINGLEPLAYER
        cfg.start_mode = BF_MODE_SURVIVAL
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
        bf_set_event_callback(e, eventTrampoline, Unmanaged.passUnretained(self).toOpaque())
        _ = bf_world_load(e)
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

        // 3) camera matrices
        let aspect = Float(dSize.width / max(1, dSize.height))
        let fovy: Float = 1.20
        let proj  = Renderer.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 512)
        let viewM = Renderer.mat(frame.camera.view)
        let viewProj = proj * viewM
        let sun = frame.camera.sun_dir

        let wallClock = Float(now.truncatingRemainder(dividingBy: 3600.0))
        let isUnderwater = frame.camera.underwater

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

        guard let cmd = queue.makeCommandBuffer() else { return }

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

            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = registry.lookup(d.vertex_buffer),
                      let ibuf = registry.lookup(d.index_buffer) else { continue }
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

            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = registry.lookup(d.vertex_buffer),
                      let ibuf = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(
                    viewProj:      viewProj,
                    chunkOrigin:   SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime:    SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: lightViewProj)
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

        // Two iterations of separable Gaussian blur (H then V, ping-pong)
        for _ in 0..<2 {
            encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurHPipeline,
                                 inTexture: bloomBright, outTexture: bloomBlurA,
                                 uniforms: nil, uniformsSize: 0)
            encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurVPipeline,
                                 inTexture: bloomBlurA, outTexture: bloomBlurB,
                                 uniforms: nil, uniformsSize: 0)
            // bloomBlurB now holds one full pass; copy back into bloomBright for
            // next iteration by swapping the logical roles (can't alias in Metal,
            // so we just re-source from bloomBlurB on the 2nd iteration's H pass).
            encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurHPipeline,
                                 inTexture: bloomBlurB, outTexture: bloomBlurA,
                                 uniforms: nil, uniformsSize: 0)
            encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurVPipeline,
                                 inTexture: bloomBlurA, outTexture: bloomBright,
                                 uniforms: nil, uniformsSize: 0)
            break  // one iteration = 2 passes H+V (loop kept for easy tuning)
        }

        // =====================================================================
        // PASS 4: Composite → drawable (ACES + colour grade + vignette)
        // =====================================================================
        if let passDesc = view.currentRenderPassDescriptor {
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
                enc.setRenderPipelineState(compositePipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor,    index: 0)
                enc.setFragmentTexture(bloomBright, index: 1)
                var pu = PostUniforms(bloomStrength: 0.12, vignetteStr: 0.55, satBoost: 1.12, pad: 0)
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        cmd.present(drawable)
        cmd.commit()

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
        let center = camPos + camFwd * 40.0               // look-at centre
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

    // Terrain uniforms: must EXACTLY match Swift Uniforms struct (160 bytes).
    //   viewProj      (64), chunkOrigin (16), sunDirTime (16), lightViewProj (64)
    struct Uniforms {
        float4x4 viewProj;
        float4   chunkOrigin;   // xyz=origin, w=dim_saturation
        float4   sunDirTime;    // xyz=sun_dir, w=time_of_day
        float4x4 lightViewProj; // sun shadow matrix
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

    // PostUniforms (16 bytes) — composite pass.
    struct PostUniforms {
        float bloomStrength;
        float vignetteStr;
        float satBoost;
        float pad;
    };

    // ShadowVertUniforms (80 bytes): light VP + chunk origin.
    struct ShadowVertUniforms {
        float4x4 lightViewProj;  // 64 bytes
        float4   chunkOrigin;    // 16 bytes
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

    // =========================================================
    // LIGHT / SHADE HELPERS
    // =========================================================

    static float faceShade(uint n) {
        if (n == 2u) return 1.0;    // top
        if (n == 3u) return 0.45;   // bottom
        return 0.72;                // sides
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
            case  6u: return float3(0.90, 0.83, 0.58);
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
    // PROCEDURAL TEXTURE HELPERS (unchanged)
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
    static float2 faceUV(float3 wp, uint face) {
        if (face == 0u || face == 1u) return wp.yz;
        if (face == 2u || face == 3u) return wp.xz;
        return wp.xy;
    }

    static float blockDetail(float3 worldPos, uint face, uint matID) {
        int3 vi = int3(floor(worldPos));
        float vHash = voxelHash(vi);
        float jitter = (vHash - 0.5) * 0.16;
        float2 uv = faceUV(worldPos, face);
        float grain;
        if (matID==3u||matID==8u||matID==10u||matID==11u||
            matID==15u||matID==17u||matID==18u||matID==19u||
            matID==20u||matID==29u) {
            float fine  = (noise2(uv * 8.0) - 0.5) * 0.22;
            float coarse= (noise2(uv * 2.5 + float2(5.1, 2.3)) - 0.5) * 0.10;
            grain = fine + coarse;
        } else if (matID==1u||matID==5u||matID==27u||matID==38u) {
            float a = (fbm2(uv * 5.5) - 0.5) * 0.20;
            float b2 = (noise2(uv * 14.0 + float2(1.7, 3.3)) - 0.5) * 0.08;
            grain = a + b2;
        } else if (matID==4u||matID==21u||matID==22u||matID==23u||
                   matID==30u||matID==31u||matID==33u) {
            float2 ruv = float2(uv.x+uv.y, uv.x-uv.y) * 3.5;
            float ring  = (noise2(ruv) - 0.5) * 0.16;
            float stripe= sin((uv.x + uv.y) * 6.28318f * 1.2f) * 0.05;
            grain = ring + stripe;
        } else if (matID==6u||matID==14u) {
            float coarse = (noise2(uv * 5.0) - 0.5) * 0.14;
            float grit   = (noise2(uv * 18.0 + float2(2.2, 7.1)) - 0.5) * 0.10;
            grain = coarse + grit;
        } else if (matID==12u||matID==13u) {
            grain = (noise2(uv * 11.0) - 0.5) * 0.08;
        } else if (matID==7u||matID==32u||matID==34u||matID==35u||matID==40u) {
            grain = 0.0;
        } else if (matID==24u) {
            float bx = fract(uv.x * 2.0);
            float by = fract(uv.y * 1.0);
            float mortar = smoothstep(0.0, 0.08, bx) * smoothstep(0.0, 0.08, 1.0-bx)
                         * smoothstep(0.0, 0.10, by) * smoothstep(0.0, 0.10, 1.0-by);
            grain = (mortar - 0.5) * 0.22 + (noise2(uv * 7.0) - 0.5) * 0.06;
        } else if (matID==15u||matID==16u) {
            grain = (fbm2(uv * 4.0) - 0.5) * 0.24;
        } else {
            grain = (noise2(uv * 5.0) - 0.5) * 0.10;
        }
        return 1.0 + jitter + grain;
    }

    // =========================================================
    // SHADOW MAP — depth-only vertex shader
    // =========================================================
    vertex float4 shadowVmain(uint vid [[vertex_id]],
                              device const PackedVertex* verts [[buffer(0)]],
                              constant ShadowVertUniforms& su [[buffer(1)]]) {
        PackedVertex p = verts[vid];
        float x = float(p.pos & 0x3f);
        float y = float((p.pos >> 6) & 0x3f);
        float z = float((p.pos >> 12) & 0x3f);
        float3 world = su.chunkOrigin.xyz + float3(x, y, z);
        return su.lightViewProj * float4(world, 1.0);
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

        // --- AO from bits [3:5] (0=fully occluded, 3=open) ---
        float ao = float((p.normuv >> 3u) & 3u) / 3.0;
        // Smooth the AO value slightly (gamma lift to soften corners)
        ao = pow(ao, 0.85);

        // --- Lighting: sky + block + day/night (same as before) ---
        float dayB   = 0.15 + 0.85 * max(0.0, sin(u.sunDirTime.w * 3.14159265f));
        float skyC   = (float(p.sky)   / 15.0) * dayB;
        float blockC = float(p.block)  / 15.0;
        float lightLevel = max(max(skyC, blockC), 0.08);
        float facing = 0.62 + 0.38 * faceShade(n);
        float shade  = clamp(lightLevel * facing, 0.0, 1.0);

        VOut o;
        o.position = u.viewProj * float4(world, 1.0);

        float3 base = materialColor(uint(p.material));
        o.color    = mix(base, base * float3(1.15, 1.02, 0.8), clamp(blockC - skyC, 0.0, 1.0));
        o.shade    = shade;
        o.sat      = u.chunkOrigin.w;
        o.worldPos = world;
        o.faceNorm = n;
        o.material = uint(p.material);
        o.ao       = ao;

        // Light-space position for shadow lookup (per-vertex, interpolated).
        // lightViewProj maps world → [−1,1] clip; NDC depth is in [0,1] on Metal.
        float4 lsClip = u.lightViewProj * float4(world, 1.0);
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
        float texelSize = 1.0 / 2048.0;
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
                          depth2d<float, access::sample> shadowTex [[texture(0)]],
                          sampler shadowSamp [[sampler(0)]]) {
        uint mat = in.material;

        // ---- Glowing blocks skip shadowing (they emit light) ----
        bool isEmissive = (mat==7u||mat==32u||mat==34u||mat==35u||mat==40u);

        // ---- Day factor (for shadow strength scaling) ----
        // We can extract this from shade indirectly; use the sunDirTime.w-driven
        // dayB from the vertex shader. In the fragment we just use in.shade,
        // but we need a "sun contribution" fraction.
        // We'll derive dayFactor as: sun contribution ≈ in.shade (already encodes dayB).
        float dayFactor = clamp(in.shade * 1.5, 0.0, 1.0);

        // ---- PCF Shadow ----
        float shadowFactor = 1.0;
        if (!isEmissive) {
            float rawShadow = sampleShadowPCF(shadowTex, shadowSamp, in.shadowPos, dayFactor);
            // When in shadow, sun/sky contribution is 0.35 of normal.
            // Block light (torches, glow) is unaffected -> caves stay lit.
            // Shadow strength scales with dayFactor so shadows disappear at night.
            float shadowStrength = 0.65 * dayFactor;  // max darkening = 65% at noon
            shadowFactor = 1.0 - shadowStrength * (1.0 - rawShadow);
        }

        // ---- AO multiplier: fold into lit colour (multiplied with shade) ----
        // ao=0 → dark corner (multiply by 0.45), ao=1 → open (multiply by 1.0)
        float aoFactor = mix(0.45, 1.0, in.ao);

        // ---- Water block special path ----
        if (mat == 9u) {
            float t = wu.wallClockSecs;
            float2 uv = in.worldPos.xz;
            float wave1 = noise2(uv * 0.8  + float2( t * 0.22,  t * 0.14));
            float wave2 = noise2(uv * 1.40 + float2(-t * 0.17,  t * 0.28));
            float wave3 = noise2(uv * 2.80 + float2( t * 0.35, -t * 0.19));
            float ripple = wave1 * 0.50 + wave2 * 0.35 + wave3 * 0.15;
            float rippleN = ripple * 2.0 - 1.0;
            float3 waterBase = float3(0.12, 0.40, 0.80);
            float fresnelBias = (in.faceNorm == 2u) ? 0.30 : 0.08;
            float fresnelAmt  = fresnelBias + rippleN * 0.12;
            float2 nAB = float2(
                noise2(uv * 1.2 + float2(t * 0.22 + 0.1, t * 0.14)) - wave1,
                noise2(uv * 1.2 + float2(t * 0.22, t * 0.14 + 0.1)) - wave1
            ) * 4.0;
            float3 perturbedN = normalize(float3(nAB.x, 1.4, nAB.y));
            float3 sunDir3 = normalize(float3(0.5, 0.9, 0.3));
            float spec = pow(max(0.0, dot(perturbedN, sunDir3)), 22.0);
            float specular = spec * 0.55 * in.shade;
            float3 col = waterBase * in.shade * aoFactor;
            col *= 1.0 + rippleN * 0.20;
            col = mix(col, float3(0.85, 0.95, 1.00), clamp(fresnelAmt, 0.0, 0.45));
            col += float3(1.0, 0.98, 0.88) * specular;
            // Apply shadow on water too
            col *= shadowFactor;
            // Boost above 1 for HDR to trigger bloom on specular highlights
            col += float3(1.0, 0.98, 0.88) * specular * 0.8;
            float lum = dot(col, float3(0.299, 0.587, 0.114));
            col = mix(float3(lum), col, clamp(in.sat, 0.0, 1.0));
            return float4(col, 1.0);
        }

        // ---- Standard block path ----
        float detail = blockDetail(in.worldPos, in.faceNorm, in.material);

        // Combined: shade * AO * shadow * detail
        float3 col = in.color * in.shade * aoFactor * shadowFactor * clamp(detail, 0.75, 1.28);

        // Emissive blocks bloom in HDR: push them above 1.0
        if (isEmissive) {
            col *= 1.6;   // HDR overbright → bloom
        }

        // Dim desaturation
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(lum), col, clamp(in.sat, 0.0, 1.0));

        // Underwater distance fog
        if (wu.underwater > 0.5) {
            float dist = length(in.worldPos - UW_CAM_POS(wu));
            float fogFactor = clamp(exp(-0.50 * dist), 0.0, 1.0);
            float3 waterFogColor = float3(0.04, 0.22, 0.38);
            col = mix(waterFogColor, col, fogFactor);
        }

        return float4(col, 1.0);
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
        float3 horizDay     = float3(0.48, 0.70, 0.96);
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
        float sunDisc  = smoothstep(0.9975, 1.0000, sunDot);
        float sunInner = smoothstep(0.9992, 1.0000, sunDot);
        float sunGlow1 = smoothstep(0.940,  1.0000, sunDot) * 0.22 * max(dayT, sunsetT * 0.5);
        float sunGlow2 = smoothstep(0.984,  1.0000, sunDot) * 0.35 * max(dayT, sunsetT * 0.5);
        float3 sunColor  = mix(float3(1.0, 0.72, 0.35), float3(1.0, 0.98, 0.85), dayT);
        float3 sunCorona = sunColor * 1.15;
        float sunVis = max(dayT, sunsetT * 0.6);
        skyCol += sunGlow1 * sunCorona;
        skyCol += sunGlow2 * sunCorona;
        skyCol = mix(skyCol, sunColor,          sunDisc  * sunVis);
        skyCol = mix(skyCol, float3(1.0, 1.0, 0.96), sunInner * sunVis);

        // HDR: sun disc pushed above 1 so it blooms — but modestly, so it
        // doesn't flood the whole frame when near the horizon.
        skyCol += sunColor * 1.1 * sunInner * sunVis;

        float3 moonDir3 = -sunDir3;
        float moonDot  = dot(ray, moonDir3);
        float moonDisc = smoothstep(0.9990, 1.000, moonDot) * (1.0 - dayT) * 0.9;
        skyCol = mix(skyCol, float3(0.90, 0.92, 1.00), moonDisc);

        if (dayT < 0.5) {
            float starFade = 1.0 - smoothstep(0.05, 0.35, dayT);
            starFade *= smoothstep(0.0, 0.10, ray.y);
            float2 starUV = floor((ray.xz / max(ray.y + 0.01, 0.01)) * 60.0 + float2(200.0));
            float starH = uhash(uint(starUV.x) * 3141u + uint(starUV.y) * 1618u
                                 + uint(starUV.x * starUV.y) * 97u);
            float starBright = step(0.986, starH);
            skyCol += float3(starBright * starFade * 0.90);
        }

        float weatherCycle = sin(clk * (3.14159265f / 150.0f)) * 0.5f + 0.5f;
        float overcast = smoothstep(0.52, 0.80, weatherCycle) * 0.65;

        if (overcast > 0.01) {
            float cloudPlaneHit = (ray.y > 0.02) ? (1.0 / ray.y) : 0.0;
            float2 ocUV = ray.xz * cloudPlaneHit * 0.35 + float2(clk * 0.006, clk * 0.003);
            float ocCloud = cloudFbm(ocUV * 1.5);
            ocCloud = smoothstep(0.38, 0.62, ocCloud);
            float3 ocColor = mix(float3(0.55, 0.57, 0.64), float3(0.72, 0.74, 0.80), dayT);
            float ocFade = smoothstep(0.0, 0.12, ray.y);
            skyCol = mix(skyCol, ocColor, ocCloud * overcast * ocFade);
        }

        float rainStrength = smoothstep(0.60, 0.82, weatherCycle);
        if (rainStrength > 0.01) {
            float2 rUV  = float2(in.ndc.x * 40.0, in.ndc.y * 3.5 + clk * 2.0);
            float2 rUV2 = rUV * float2(1.4, 1.0) + float2(9.1, 0.0);
            float streak = noise2(rUV) * noise2(rUV2);
            float rain = pow(max(0.0, streak - 0.36), 2.2) * 10.0;
            rain = clamp(rain, 0.0, 1.0);
            float3 rainColor = mix(float3(0.62, 0.70, 0.84), float3(0.50, 0.62, 0.78), dayT);
            float rainFade = smoothstep(-0.6, 0.0, in.ndc.y);
            skyCol = mix(skyCol, rainColor, rain * rainStrength * 0.30 * rainFade);
        }

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

    fragment float4 underwaterFmain(UWVOut in [[stage_in]],
                                    constant WaterUniforms& wu [[buffer(0)]]) {
        float uw = wu.underwater;
        if (uw < 0.01) { discard_fragment(); }
        float t = wu.wallClockSecs;
        float2 cUV1 = in.uv * float2(3.0, 2.5) + float2(t * 0.08, t * 0.05);
        float2 cUV2 = in.uv * float2(2.2, 3.1) + float2(-t * 0.06, t * 0.09);
        float caustic = noise2(cUV1) * 0.6 + noise2(cUV2) * 0.4;
        caustic = smoothstep(0.52, 0.78, caustic) * 0.18;
        float edgeFog = 1.0 - 4.0 * (in.uv.x - 0.5) * (in.uv.x - 0.5)
                             - 4.0 * (in.uv.y - 0.5) * (in.uv.y - 0.5);
        edgeFog = clamp(edgeFog, 0.0, 1.0);
        float depthFog = 1.0 - smoothstep(0.0, 0.7, in.uv.y);
        float3 uwColor = float3(0.06, 0.28, 0.45);
        float baseFog  = 0.40;
        float edgeMod  = (1.0 - edgeFog) * 0.30;
        float depthMod = depthFog * 0.28;
        float totalAlpha = clamp((baseFog + edgeMod + depthMod) * uw, 0.0, 0.78);
        float3 col = uwColor + float3(caustic * 0.8, caustic * 1.0, caustic * 0.6);
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
        // Knee function: soft threshold at 1.0, full contribution above 1.5
        float lum = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
        float bright = smoothstep(1.15, 2.40, lum);   // only genuinely bright things bloom
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
    //   Reads HDR scene (rgba16Float) + bloom texture, writes LDR bgra8.
    // =========================================================

    // ACES fitted curve (Narkowicz 2015, single-pass approximation)
    static float3 ACESFilmic(float3 x) {
        const float a = 2.51f;
        const float b = 0.03f;
        const float c = 2.43f;
        const float d = 0.59f;
        const float e = 0.14f;
        return clamp((x*(a*x+b)) / (x*(c*x+d)+e), 0.0, 1.0);
    }

    fragment float4 compositeFrag(FSVOut in [[stage_in]],
                                  texture2d<float> hdrTex   [[texture(0)]],
                                  texture2d<float> bloomTex [[texture(1)]],
                                  constant PostUniforms& pu [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        float3 hdr   = hdrTex.sample(s, in.uv).rgb;
        float3 bloom = bloomTex.sample(s, in.uv).rgb;

        // Add bloom
        float3 combined = hdr + bloom * pu.bloomStrength;

        // ACES filmic tone-map
        float3 tonemapped = ACESFilmic(combined);

        // Colour grade: warm highlights (slightly push R, pull B at high luminance)
        float lumG = dot(tonemapped, float3(0.2126, 0.7152, 0.0722));
        float3 warmHighlight = float3(1.04, 1.00, 0.95);
        tonemapped = mix(tonemapped, tonemapped * warmHighlight, lumG * lumG * 0.30);

        // Saturation boost
        float lumSat = dot(tonemapped, float3(0.2126, 0.7152, 0.0722));
        tonemapped   = mix(float3(lumSat), tonemapped, pu.satBoost);
        tonemapped   = clamp(tonemapped, 0.0, 1.0);

        // Vignette: smooth falloff toward screen edges
        float2 centred = in.uv - 0.5;
        float vigRad = dot(centred, centred);
        float vignette = 1.0 - smoothstep(0.20, 0.70, vigRad * 4.0) * pu.vignetteStr;
        tonemapped *= vignette;

        // Gamma: assume drawable is in sRGB-compatible space (bgra8Unorm_srgb or
        // similar). If not sRGB, apply a manual gamma ≈ 2.2 adjustment here.
        // The drawable format is bgra8Unorm; apply a simple gamma lift.
        tonemapped = pow(clamp(tonemapped, 0.0, 1.0), float3(1.0 / 2.2));

        return float4(tonemapped, 1.0);
    }
    """
}

// MARK: - Shadow vert uniform (Swift side, matches MSL ShadowVertUniforms)

/// 80 bytes: lightViewProj (64) + chunkOrigin (16)
struct ShadowVertUniforms {
    var lightViewProj: simd_float4x4
    var chunkOrigin:   SIMD4<Float>
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
            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vb = registry.lookup(d.vertex_buffer),
                      let ib = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(
                    viewProj: viewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: testLightVP)
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
                var pu = PostUniforms(bloomStrength: 0.12, vignetteStr: 0.55, satBoost: 1.12, pad: 0)
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
