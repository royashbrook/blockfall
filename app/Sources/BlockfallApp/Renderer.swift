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

private func allocTrampoline(_ user: UnsafeMutableRawPointer?, _ bytes: UInt32) -> bf_gpu_buffer {
    guard let user = user else { return bf_gpu_buffer() }
    let reg = Unmanaged<BufferRegistry>.fromOpaque(user).takeUnretainedValue()
    guard let made = reg.make(Int(bytes)) else { return bf_gpu_buffer() }
    var out = bf_gpu_buffer(); out.handle = made.handle; out.contents = made.ptr; out.bytes = bytes
    return out
}
private func freeTrampoline(_ user: UnsafeMutableRawPointer?, _ handle: UInt64) {
    guard let user = user else { return }
    Unmanaged<BufferRegistry>.fromOpaque(user).takeUnretainedValue().free(handle)
}

// MARK: - Uniforms (must match the MSL struct byte layout)

struct Uniforms {
    var viewProj: simd_float4x4
    var chunkOrigin: SIMD4<Float>   // xyz origin, w unused
    var sunDirTime: SIMD4<Float>    // xyz sun dir, w time-of-day
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let registry: BufferRegistry
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var engine: OpaquePointer?
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var frameCounter = 0
    private weak var gameView: GameView?
    weak var hud: HUDView?

    init(view: MTKView, device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.registry = BufferRegistry(device: device)
        self.gameView = view as? GameView
        super.init()
        view.depthStencilPixelFormat = .depth32Float
        buildPipeline(colorFormat: view.colorPixelFormat)
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
    }

    private func createEngine() {
        var cfg = bf_engine_config()
        cfg.abi_version = BF_ABI_VERSION
        cfg.role = BF_ROLE_SINGLEPLAYER
        cfg.start_mode = BF_MODE_CREATIVE
        cfg.render_distance_chunks = 10
        cfg.memory_budget_bytes = 10 * 1024 * 1024 * 1024
        cfg.content_dir = persistentCString(Bundle.main.resourcePath ?? ".")
        cfg.save_dir = persistentCString(NSTemporaryDirectory() + "blockfall_save")
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
        _ = bf_world_new(e, 1234)
    }

    func shutdown() { if let e = engine { bf_engine_destroy(e); engine = nil } }
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
        let proj = Renderer.perspective(fovy: 1.20, aspect: aspect, near: 0.05, far: 512)
        let viewM = Renderer.mat(frame.camera.view)
        let viewProj = proj * viewM
        let sun = frame.camera.sun_dir

        // 4) sky + depth clear
        let sky = skyColor(frame.camera.time_of_day)
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: sky.0, green: sky.1, blue: sky.2, alpha: 1)
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.depthAttachment.clearDepth = 1.0
        passDesc.depthAttachment.loadAction = .clear

        if let cmd = queue.makeCommandBuffer(),
           let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)

            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = registry.lookup(d.vertex_buffer),
                      let ibuf = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(
                    viewProj: viewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), 0),
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day))
                enc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ibuf,
                                          indexBufferOffset: Int(d.index_offset))
            }
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }

        hud?.update(from: frame.hud)
        bf_frame_end(e)
        registry.collect()
    }

    private func skyColor(_ t: Float) -> (Double, Double, Double) {
        let day = max(0.0, sin(Double(t) * .pi))
        return (min(0.10 + 0.45 * day + 0.20 * (1 - day), 1),
                min(0.12 + 0.55 * day, 1),
                min(0.22 + 0.70 * day, 1))
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

    struct PackedVertex { uint pos; uint normuv; ushort material; uchar sky; uchar block; uint reserved; };
    struct Uniforms { float4x4 viewProj; float4 chunkOrigin; float4 sunDirTime; };
    struct VOut { float4 position [[position]]; float3 color; float shade; float sat; };

    static float3 normalFor(uint n) {
        switch (n) {
            case 0: return float3( 1, 0, 0); case 1: return float3(-1, 0, 0);
            case 2: return float3( 0, 1, 0); case 3: return float3( 0,-1, 0);
            case 4: return float3( 0, 0, 1); default: return float3( 0, 0,-1);
        }
    }
    static float faceShade(uint n) {
        if (n == 2) return 1.0;      // top
        if (n == 3) return 0.45;     // bottom
        return 0.72;                 // sides
    }
    static float3 materialColor(uint m) {
        switch (m) {
            case 1: return float3(0.40, 0.74, 0.34);  // grass
            case 2: return float3(0.52, 0.38, 0.26);  // dirt
            case 3: return float3(0.56, 0.56, 0.60);  // stone
            case 4: return float3(0.55, 0.40, 0.22);  // wood
            case 5: return float3(0.30, 0.62, 0.30);  // leaf
            case 6: return float3(0.86, 0.80, 0.55);  // sand
            case 7: return float3(1.00, 0.92, 0.55);  // glow
            case 8: return float3(0.74, 0.36, 0.30);  // brick
            case 9: return float3(0.30, 0.50, 0.85);  // water
            default: return float3(0.80, 0.40, 0.80);
        }
    }

    vertex VOut vmain(uint vid [[vertex_id]],
                      device const PackedVertex* verts [[buffer(0)]],
                      constant Uniforms& u [[buffer(1)]]) {
        PackedVertex p = verts[vid];
        float x = float(p.pos & 0x3f);
        float y = float((p.pos >> 6) & 0x3f);
        float z = float((p.pos >> 12) & 0x3f);
        float3 world = u.chunkOrigin.xyz + float3(x, y, z);
        uint n = p.normuv & 7u;
        float3 N = normalFor(n);
        float ndl = max(0.0, dot(N, normalize(-u.sunDirTime.xyz)));
        float shade = clamp(0.30 + 0.55 * faceShade(n) + 0.25 * ndl, 0.0, 1.0);
        VOut o;
        o.position = u.viewProj * float4(world, 1.0);
        o.color = materialColor(uint(p.material));
        o.shade = shade;
        o.sat = u.chunkOrigin.w;   // per-region Dim saturation (0=grey..1=full color)
        return o;
    }
    fragment float4 fmain(VOut in [[stage_in]]) {
        float3 col = in.color * in.shade;
        // Dim regions drain toward grey; restoring (e.g. a glow block) brings
        // the color back. Luminance-preserving desaturation.
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(float3(lum), col, clamp(in.sat, 0.0, 1.0));
        return float4(col, 1.0);
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
        enc.setRenderPipelineState(pipeline); enc.setDepthStencilState(depthState)
        enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
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
