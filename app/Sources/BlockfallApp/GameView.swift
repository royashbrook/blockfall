// ============================================================================
// Blockfall — GameView (M1 input)
// An MTKView subclass that captures keyboard + mouse and exposes a per-frame
// input snapshot the Renderer reads. Minecraft-faithful controls: WASD move,
// mouse look, space up / shift down (M1 free-fly), left-hold mine, right-click
// place, 1-6 select hotbar. Click to capture the pointer; Esc releases it.
// ============================================================================
import MetalKit
import CBlockcore

final class GameView: MTKView {
    private var pressed = Set<UInt16>()
    private var shiftDown = false
    private var captured = false

    // Accumulated mouse look since the last frame (consumed by Renderer).
    private(set) var lookDX: Float = 0
    private(set) var lookDY: Float = 0
    // Discrete actions queued for the engine (drained by Renderer).
    private var actionQueue: [bf_action] = []

    override var acceptsFirstResponder: Bool { true }

    // Key codes (US layout).
    private enum K {
        static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
        static let space: UInt16 = 49, esc: UInt16 = 53
        static let one: UInt16 = 18  // 1..6 are 18,19,20,21,23,22
    }

    // ---- per-frame snapshot ------------------------------------------------
    func makeFrameInput() -> bf_frame_input {
        var inp = bf_frame_input()
        inp.move_forward = (pressed.contains(K.w) ? 1 : 0) - (pressed.contains(K.s) ? 1 : 0)
        inp.move_strafe  = (pressed.contains(K.d) ? 1 : 0) - (pressed.contains(K.a) ? 1 : 0)
        inp.jump  = pressed.contains(K.space) ? 1 : 0
        inp.sneak = shiftDown ? 1 : 0
        inp.look_yaw_delta   = lookDX * 0.0035
        inp.look_pitch_delta = -lookDY * 0.0035
        lookDX = 0; lookDY = 0
        return inp
    }

    func drainActions() -> [bf_action] {
        let a = actionQueue; actionQueue.removeAll(keepingCapacity: true); return a
    }

    private func queue(_ kind: bf_action_kind, _ i: Int32 = 0) {
        var a = bf_action(); a.kind = kind; a.arg_i = i
        actionQueue.append(a)
    }

    // ---- keyboard ----------------------------------------------------------
    override func keyDown(with e: NSEvent) {
        if e.keyCode == K.esc { if invOpen { toggleInventory() } else { releasePointer() }; return }
        if e.keyCode == 14 { toggleInventory(); return }   // 'E' — inventory
        if e.keyCode == 8 { queue(BF_ACT_MODE_TOGGLE); return } // 'C' — creative/survival
        // Hotbar 1..9
        let nums: [UInt16: Int32] = [18:0, 19:1, 20:2, 21:3, 23:4, 22:5, 26:6, 28:7, 25:8]
        if let slot = nums[e.keyCode] { queue(BF_ACT_HOTBAR_SELECT, slot) }
        pressed.insert(e.keyCode)
    }

    private var invOpen = false
    private func toggleInventory() {
        invOpen.toggle()
        queue(invOpen ? BF_ACT_INV_OPEN : BF_ACT_INV_CLOSE)
        if invOpen { releasePointer() } else { capturePointer() }
    }
    override func keyUp(with e: NSEvent) { pressed.remove(e.keyCode) }
    override func flagsChanged(with e: NSEvent) { shiftDown = e.modifierFlags.contains(.shift) }

    // ---- mouse -------------------------------------------------------------
    override func mouseDown(with e: NSEvent) {
        if !captured { capturePointer() } else { queue(BF_ACT_MINE_START) }
    }
    override func mouseUp(with e: NSEvent) { if captured { queue(BF_ACT_MINE_STOP) } }
    override func rightMouseDown(with e: NSEvent) { if captured { queue(BF_ACT_PLACE) } }
    override func mouseMoved(with e: NSEvent)   { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }
    override func mouseDragged(with e: NSEvent) { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }
    override func rightMouseDragged(with e: NSEvent) { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }

    private func capturePointer() {
        captured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }
    private func releasePointer() {
        captured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }
    var isCaptured: Bool { captured }
}
