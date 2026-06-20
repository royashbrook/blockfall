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

    // Mouse-look inversion: left/right inverted, up/down normal by default.
    // Toggle X with 'I', Y with 'O'.
    private var invertX = true
    private var invertY = false

    // App-level hooks (wired by the app delegate).
    var onHost: (() -> Void)?
    var onJoin: (() -> Void)?
    var onPause: (() -> Void)?

    private var gamePaused = false
    func releaseMouse() { releasePointer() }
    func grabMouse() { capturePointer() }
    func setPaused(_ b: Bool) { gamePaused = b; if b { releasePointer() } }

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
        if gamePaused { return bf_frame_input() }      // no movement/look while paused
        var inp = bf_frame_input()
        inp.move_forward = (pressed.contains(K.w) ? 1 : 0) - (pressed.contains(K.s) ? 1 : 0)
        inp.move_strafe  = (pressed.contains(K.d) ? 1 : 0) - (pressed.contains(K.a) ? 1 : 0)
        inp.jump  = pressed.contains(K.space) ? 1 : 0
        inp.sneak = shiftDown ? 1 : 0
        // Default to inverted on both axes (toggle with 'I').
        inp.look_yaw_delta   = lookDX * 0.0035 * (invertX ? -1 : 1)
        inp.look_pitch_delta = lookDY * 0.0035 * (invertY ?  1 : -1)
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
        if e.keyCode == K.esc { if invOpen { toggleInventory() } else { onPause?() }; return }
        if e.keyCode == 14 { toggleInventory(); return }   // 'E' — inventory
        if e.keyCode == 8 { queue(BF_ACT_MODE_TOGGLE); return } // 'C' — creative/survival
        if e.keyCode == 12 { queue(BF_ACT_CRAFT); return }      // 'Q' — craft first available
        if e.keyCode == 34 { invertX.toggle()                    // 'I' — invert left/right
            NSLog("Blockfall: invert X (left/right) = \(invertX)"); return }
        if e.keyCode == 31 { invertY.toggle()                    // 'O' — invert up/down
            NSLog("Blockfall: invert Y (up/down) = \(invertY)"); return }
        if e.keyCode == 4  { onHost?(); return }                // 'H' — host LAN co-op
        if e.keyCode == 38 { onJoin?(); return }                // 'J' — join a LAN host
        // Number keys: craft the Nth craftable recipe when the inventory is
        // open, otherwise select the hotbar slot.
        let nums: [UInt16: Int32] = [18:0, 19:1, 20:2, 21:3, 23:4, 22:5, 26:6, 28:7, 25:8]
        if let slot = nums[e.keyCode] {
            if invOpen { if slot < 8 { queue(BF_ACT_CRAFT, slot) } }
            else { hotbarSel = slot; queue(BF_ACT_HOTBAR_SELECT, slot) }
        }
        pressed.insert(e.keyCode)
    }

    // Mouse wheel cycles the selected hotbar slot (Minecraft-style).
    private var hotbarSel: Int32 = 0
    override func scrollWheel(with e: NSEvent) {
        guard captured && !invOpen && !gamePaused else { return }
        let dir: Int32 = e.scrollingDeltaY > 0 ? -1 : 1
        hotbarSel = (hotbarSel + dir + 9) % 9
        queue(BF_ACT_HOTBAR_SELECT, hotbarSel)
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
        if gamePaused { return }               // let the pause overlay get clicks
        if !captured { capturePointer() } else { queue(BF_ACT_MINE_START) }
    }
    override func mouseUp(with e: NSEvent) { if captured { queue(BF_ACT_MINE_STOP) } }
    override func rightMouseDown(with e: NSEvent) { if captured { queue(BF_ACT_PLACE) } }
    override func mouseMoved(with e: NSEvent)   { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }
    override func mouseDragged(with e: NSEvent) { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }
    override func rightMouseDragged(with e: NSEvent) { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }

    private var cursorHidden = false   // keep hide/unhide balanced so the cursor never gets stuck
    private func capturePointer() {
        captured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }
    private func releasePointer() {
        captured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        // Warp the cursor to the window centre so it's visible and on the overlay.
        if let w = window, let scr = w.screen {
            let p = CGPoint(x: w.frame.midX, y: scr.frame.maxY - w.frame.midY)
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
    var isCaptured: Bool { captured }
}
