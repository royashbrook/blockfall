import MetalKit
import CBlockcore

// MARK: - GPU buffer registry (Swift owns MTLBuffers; engine refs by handle)

final class BufferRegistry {
    struct Stats {
        var liveBuffers: Int
        var retiredBuffers: Int
        var reusableBuffers: Int
        var reusableBytes: Int
        var newBuffers: UInt64
        var reusedBuffers: UInt64
    }

    private var buffers: [UInt64: MTLBuffer] = [:]
    private var retired: [(buf: MTLBuffer, frame: Int)] = []
    private var reusable: [Int: [MTLBuffer]] = [:]
    private var reusableBytes = 0
    private var newBuffers: UInt64 = 0
    private var reusedBuffers: UInt64 = 0
    private var next: UInt64 = 1
    private let lock = NSLock()
    let device: MTLDevice
    var currentFrame = 0
    private var completedFrame = -1
    private let maxReusableBytes = 96 * 1024 * 1024
    init(device: MTLDevice) { self.device = device }

    func make(_ bytes: Int) -> (handle: UInt64, ptr: UnsafeMutableRawPointer)? {
        lock.lock(); defer { lock.unlock() }
        let wanted = BufferRegistry.bucketSize(max(bytes, 16))
        let buf: MTLBuffer
        if var bucket = reusable[wanted], let reused = bucket.popLast() {
            reusable[wanted] = bucket.isEmpty ? nil : bucket
            reusableBytes -= reused.length
            reusedBuffers += 1
            buf = reused
        } else {
            guard let made = device.makeBuffer(length: wanted, options: .storageModeShared) else { return nil }
            newBuffers += 1
            buf = made
        }
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
    func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        let reusableCount = reusable.values.reduce(0) { $0 + $1.count }
        return Stats(liveBuffers: buffers.count,
                     retiredBuffers: retired.count,
                     reusableBuffers: reusableCount,
                     reusableBytes: reusableBytes,
                     newBuffers: newBuffers,
                     reusedBuffers: reusedBuffers)
    }
    func markFrameCompleted(_ frame: Int) {
        lock.lock(); defer { lock.unlock() }
        completedFrame = max(completedFrame, frame)
    }
    // Release buffers only after Metal tells us the command buffer that could
    // have referenced them has completed. A frame-count heuristic is not a fence
    // when the GPU is under backpressure.
    func collect() {
        lock.lock(); defer { lock.unlock() }
        var keep: [(buf: MTLBuffer, frame: Int)] = []
        keep.reserveCapacity(retired.count)
        for item in retired {
            if item.frame <= completedFrame {
                recycle(item.buf)
            } else {
                keep.append(item)
            }
        }
        retired = keep
    }

    private static func bucketSize(_ bytes: Int) -> Int {
        var n = 16 * 1024
        while n < bytes { n <<= 1 }
        return n
    }

    private func recycle(_ buf: MTLBuffer) {
        if reusableBytes + buf.length > maxReusableBytes {
            return
        }
        let bucket = BufferRegistry.bucketSize(buf.length)
        reusable[bucket, default: []].append(buf)
        reusableBytes += buf.length
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
