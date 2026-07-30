import MetalKit
import CBlockcore

/// iPad input source for the shared Renderer. Touch/controller behavior is
/// layered onto this queue in #347; keeping the engine-facing contract identical
/// to macOS lets both platforms run the same frame loop.
final class GameView: MTKView {
    private var frameInput = bf_frame_input()
    private var actions: [bf_action] = []
    private(set) var worldIsPaused = false

    func makeFrameInput() -> bf_frame_input {
        guard !worldIsPaused else { return bf_frame_input() }
        let value = frameInput
        frameInput.look_yaw_delta = 0
        frameInput.look_pitch_delta = 0
        return value
    }

    func drainActions() -> [bf_action] {
        let queued = actions
        actions.removeAll(keepingCapacity: true)
        return queued
    }

    func enqueue(_ kind: bf_action_kind, _ i: Int32 = 0, _ j: Int32 = 0) {
        var action = bf_action()
        action.kind = kind
        action.arg_i = i
        action.arg_j = j
        actions.append(action)
    }

    func setPaused(_ paused: Bool) {
        worldIsPaused = paused
        if paused { clearInput() }
    }

    func clearInput() {
        frameInput = bf_frame_input()
        enqueue(BF_ACT_MINE_STOP)
    }

    func setChestPanel(open: Bool) {}
    func consumeScreenshotRequest() -> Bool { false }
}
