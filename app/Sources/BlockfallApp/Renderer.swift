// ============================================================================
// Blockfall — Renderer (Phase 0 / M0)
// Owns the engine handle and the Metal queue. Per frame: injects input, asks
// the engine for render+HUD data over the C ABI, clears the frame to the sky
// color, (no chunk draws yet — stub), and refreshes the HUD overlay.
//
// It also registers the UMA GPU allocator the engine will use to receive mesh
// data zero-copy once Track D lands. For M0 there are 0 draws, so alloc is
// wired but unused — proving the handoff path exists.
// ============================================================================
import MetalKit
import CBlockcore

// MARK: - GPU buffer registry (Swift owns MTLBuffers; engine references by handle)

final class BufferRegistry {
    private var buffers: [UInt64: MTLBuffer] = [:]
    private var next: UInt64 = 1
    private let lock = NSLock()
    let device: MTLDevice
    init(device: MTLDevice) { self.device = device }

    func make(_ bytes: Int) -> (handle: UInt64, ptr: UnsafeMutableRawPointer)? {
        guard let buf = device.makeBuffer(length: max(bytes, 16),
                                          options: .storageModeShared) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let h = next; next += 1
        buffers[h] = buf
        return (h, buf.contents())
    }
    func free(_ handle: UInt64) {
        lock.lock(); defer { lock.unlock() }
        buffers[handle] = nil
    }
    func lookup(_ handle: UInt64) -> MTLBuffer? {
        lock.lock(); defer { lock.unlock() }
        return buffers[handle]
    }
}

// C trampolines for the bf_gpu_allocator (no captured context -> pass registry via user ptr).
private func allocTrampoline(_ user: UnsafeMutableRawPointer?, _ bytes: UInt32) -> bf_gpu_buffer {
    guard let user = user else { return bf_gpu_buffer() }
    let reg = Unmanaged<BufferRegistry>.fromOpaque(user).takeUnretainedValue()
    guard let made = reg.make(Int(bytes)) else { return bf_gpu_buffer() }
    var out = bf_gpu_buffer()
    out.handle = made.handle
    out.contents = made.ptr
    out.bytes = bytes
    return out
}
private func freeTrampoline(_ user: UnsafeMutableRawPointer?, _ handle: UInt64) {
    guard let user = user else { return }
    let reg = Unmanaged<BufferRegistry>.fromOpaque(user).takeUnretainedValue()
    reg.free(handle)
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let registry: BufferRegistry
    private var engine: OpaquePointer?   // bf_engine
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    weak var hud: HUDView?

    init(view: MTKView, device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.registry = BufferRegistry(device: device)
        super.init()
        createEngine()
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

        // Register the UMA allocator (handoff path proven even with 0 draws).
        var alloc = bf_gpu_allocator()
        alloc.user = Unmanaged.passUnretained(registry).toOpaque()
        alloc.alloc = allocTrampoline
        alloc.free_ = freeTrampoline
        _ = bf_set_gpu_allocator(e, &alloc)

        _ = bf_world_new(e, 1234)
    }

    func shutdown() {
        if let e = engine { bf_engine_destroy(e); engine = nil }
    }

    deinit { shutdown() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let e = engine,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor else { return }

        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now

        // 1) Inject continuous input (none wired to keys yet for M0).
        var input = bf_frame_input()
        _ = bf_frame_begin(e, &input, dt)

        // 2) Borrow this frame's render + HUD data.
        var frame = bf_render_frame()
        _ = bf_frame_acquire_render(e, &frame)

        // 3) Sky color from time_of_day: friendly day<->dusk gradient (M0 juice).
        let sky = skyColor(frame.camera.time_of_day)
        passDesc.colorAttachments[0].clearColor =
            MTLClearColor(red: sky.0, green: sky.1, blue: sky.2, alpha: 1.0)
        passDesc.colorAttachments[0].loadAction = .clear

        // 4) Encode. Stub has 0 chunk draws; the clear IS the frame for M0.
        if let cmd = queue.makeCommandBuffer(),
           let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
            // (Track E will bind the pipeline + iterate frame.draws here.)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }

        // 5) HUD overlay reflects the engine's HUD snapshot.
        hud?.update(from: frame.hud)

        bf_frame_end(e)
    }

    private func skyColor(_ t: Float) -> (Double, Double, Double) {
        // Noon bright blue -> dusk warm -> night deep indigo. Always friendly.
        let day = max(0.0, sin(Double(t) * .pi))          // 0 at midnight, 1 at noon
        let r = 0.10 + 0.45 * day + 0.20 * (1 - day)
        let g = 0.12 + 0.55 * day
        let b = 0.22 + 0.70 * day
        return (min(r, 1), min(g, 1), min(b, 1))
    }
}

// MARK: - Headless self-test (CI, no display)

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
