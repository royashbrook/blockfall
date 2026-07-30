import Foundation
import MetalKit
import CBlockcore

/// Touch and game-controller input source for the shared Renderer.
final class GameView: MTKView {
    private let inputLock = NSLock()
    private var touchMove = SIMD2<Float>.zero
    private var controllerMove = SIMD2<Float>.zero
    private var lookDelta = SIMD2<Float>.zero
    private var controllerLook = SIMD2<Float>.zero
    private var jumpHeld = false
    private var descendHeld = false
    private var mineHeld = false
    private var actions: [bf_action] = []
    private var gamePaused = false
    private var interfaceBlocked = false

    var onPause: (() -> Void)?
    private(set) var chestOpen = false

    var worldIsPaused: Bool {
        inputLock.performLocked { gamePaused }
    }

    func makeFrameInput() -> bf_frame_input {
        inputLock.performLocked {
            guard !gamePaused && !interfaceBlocked && !chestOpen else {
                lookDelta = .zero
                return bf_frame_input()
            }
            let move = controllerMove.lengthSquared > touchMove.lengthSquared
                ? controllerMove : touchMove
            var input = bf_frame_input()
            input.move_strafe = max(-1, min(1, move.x))
            input.move_forward = max(-1, min(1, move.y))
            input.look_yaw_delta = lookDelta.x - controllerLook.x * 0.052
            input.look_pitch_delta = lookDelta.y + controllerLook.y * 0.040
            input.jump = jumpHeld ? 1 : 0
            input.fly_ascend = jumpHeld ? 1 : 0
            input.sneak = descendHeld ? 1 : 0
            input.fly_descend = descendHeld ? 1 : 0
            input.sprint = move.lengthSquared > 0.72 ? 1 : 0
            lookDelta = .zero
            return input
        }
    }

    func drainActions() -> [bf_action] {
        inputLock.performLocked {
            let queued = actions
            actions.removeAll(keepingCapacity: true)
            return queued
        }
    }

    func setTouchMovement(strafe: Float, forward: Float) {
        inputLock.performLocked { touchMove = SIMD2(strafe, forward) }
    }

    func setControllerMovement(strafe: Float, forward: Float) {
        inputLock.performLocked { controllerMove = SIMD2(strafe, forward) }
    }

    func addTouchLook(dx: Float, dy: Float) {
        inputLock.performLocked {
            // The engine's positive yaw turns left and positive pitch looks up.
            lookDelta.x += -dx * 0.0042
            lookDelta.y += -dy * 0.0042
        }
    }

    func setControllerLook(x: Float, y: Float) {
        inputLock.performLocked { controllerLook = SIMD2(x, y) }
    }

    func setJumping(_ held: Bool) {
        inputLock.performLocked { jumpHeld = held }
    }

    func setDescending(_ held: Bool) {
        inputLock.performLocked { descendHeld = held }
    }

    func beginMine() {
        inputLock.performLocked {
            guard !mineHeld, !gamePaused, !interfaceBlocked, !chestOpen else { return }
            mineHeld = true
            appendAction(BF_ACT_MINE_START)
        }
    }

    func endMine() {
        inputLock.performLocked {
            guard mineHeld else { return }
            mineHeld = false
            appendAction(BF_ACT_MINE_STOP)
        }
    }

    func interact() { enqueue(BF_ACT_INTERACT) }
    func selectHotbar(_ slot: Int) { enqueue(BF_ACT_HOTBAR_SELECT, Int32(slot)) }
    func scrollHotbar(_ direction: Int) { enqueue(BF_ACT_HOTBAR_SCROLL, Int32(direction)) }
    func toggleMode() { enqueue(BF_ACT_MODE_TOGGLE) }
    func craft(_ index: Int) { enqueue(BF_ACT_CRAFT, Int32(index)) }
    func equip(_ slot: Int) { enqueue(BF_ACT_EQUIP, Int32(slot)) }
    func requestDonate() { enqueue(BF_ACT_INTERACT, 1) }
    func requestDialogueEnd() { enqueue(BF_ACT_INTERACT, 2) }

    func toggleInventory(open: Bool) {
        enqueue(open ? BF_ACT_INV_OPEN : BF_ACT_INV_CLOSE)
        setInterfaceBlocked(open)
    }

    func setPaused(_ value: Bool) {
        inputLock.performLocked {
            gamePaused = value
            if value { cancelContinuousInput() }
        }
    }

    func setInterfaceBlocked(_ value: Bool) {
        inputLock.performLocked {
            interfaceBlocked = value
            if value { cancelContinuousInput() }
        }
    }

    func clearInput() {
        inputLock.performLocked { cancelContinuousInput() }
    }

    func setChestPanel(open: Bool) {
        inputLock.performLocked {
            chestOpen = open
            if open { cancelContinuousInput() }
        }
    }

    func consumeScreenshotRequest() -> Bool { false }

    private func enqueue(
        _ kind: bf_action_kind,
        _ i: Int32 = 0,
        _ j: Int32 = 0,
        _ k: Int32 = 0
    ) {
        inputLock.performLocked { appendAction(kind, i, j, k) }
    }

    private func appendAction(
        _ kind: bf_action_kind,
        _ i: Int32 = 0,
        _ j: Int32 = 0,
        _ k: Int32 = 0
    ) {
        var action = bf_action()
        action.kind = kind
        action.arg_i = i
        action.arg_j = j
        action.arg_k = k
        actions.append(action)
    }

    private func cancelContinuousInput() {
        touchMove = .zero
        controllerMove = .zero
        controllerLook = .zero
        lookDelta = .zero
        jumpHeld = false
        descendHeld = false
        if mineHeld {
            mineHeld = false
            appendAction(BF_ACT_MINE_STOP)
        }
    }
}

private extension NSLock {
    func performLocked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension SIMD2 where Scalar == Float {
    var lengthSquared: Float { x * x + y * y }
}
