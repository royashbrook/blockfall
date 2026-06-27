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
    private var ctrlDown = false
    private var captured = false

    // Mouse-look inversion: left/right inverted, up/down normal by default.
    // Toggle X with 'I', Y with 'O'.
    private var invertX = true
    private var invertY = false

    // App-level hooks (wired by the app delegate).
    var onHost: (() -> Void)?
    var onJoin: (() -> Void)?
    var onPause: (() -> Void)?
    // #42: quest-log overlay hook (wired to HUDView). Flips the log open/closed.
    // GameView tracks its own questLogOpen so Esc can close it before pausing.
    var onToggleQuestLog: (() -> Void)?
    // Debug overlay (#): the app shell flips the on-HUD gfx toggles via this hook.
    // onDebugClick is given the raw mouse-down event and returns true if it landed
    // on a debug toggle row (so GameView swallows the click rather than re-grabbing
    // the pointer or starting a mine).
    var onToggleDebugHud: (() -> Void)?
    var onDebugClick: ((NSEvent) -> Bool)?

    private var gamePaused = false
    // True while the debug overlay is showing: the pointer is freed so the player
    // can click the on-HUD toggles, and mouse-look is suspended (WASD still works).
    private var debugHudActive = false
    func releaseMouse() { releasePointer() }
    func grabMouse() { capturePointer() }
    // Clear all held input. Called when the app loses focus (Cmd-Tab / Cmd-H):
    // keyUp/mouseUp never arrive for the other app, so without this a held key
    // would walk you forever and a held mine would never stop.
    func clearInput() {
        pressed.removeAll(); shiftDown = false; ctrlDown = false; lookDX = 0; lookDY = 0
        queue(BF_ACT_MINE_STOP)
    }
    func setPaused(_ b: Bool) { gamePaused = b; if b { releasePointer() } }
    var worldIsPaused: Bool { gamePaused }   // #77: renderer freezes the sim while paused (single-player)

    // Enter / leave the debug overlay. The world keeps running; we only change
    // pointer state: ON frees + shows the cursor (so the HUD toggles are
    // clickable) and suspends mouse-look; OFF re-grabs the pointer for FPS look.
    // WASD movement is unaffected either way.
    func setDebugHudActive(_ active: Bool) {
        guard active != debugHudActive else { return }
        debugHudActive = active
        if active { releasePointer() }
        else if !gamePaused && !invOpen && !questLogOpen { capturePointer() }
    }

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
    }

    // ---- per-frame snapshot ------------------------------------------------
    func makeFrameInput() -> bf_frame_input {
        if gamePaused { return bf_frame_input() }      // no movement/look while paused
        var inp = bf_frame_input()
        inp.move_forward = (pressed.contains(K.w) ? 1 : 0) - (pressed.contains(K.s) ? 1 : 0)
        inp.move_strafe  = (pressed.contains(K.d) ? 1 : 0) - (pressed.contains(K.a) ? 1 : 0)
        inp.jump  = pressed.contains(K.space) ? 1 : 0
        inp.sneak = shiftDown ? 1 : 0
        inp.sprint = ctrlDown ? 1 : 0          // hold Ctrl to run (#14)
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

    // Craft a specific craftable index, clicked in the HUD's crafting list.
    func enqueueCraft(_ index: Int) { queue(BF_ACT_CRAFT, Int32(index)) }

    // Creative item picker: grant an item id to the player.
    func enqueueGive(_ itemId: UInt16) { queue(BF_ACT_GIVE_ITEM, Int32(itemId)) }

    // Trash an inventory slot.
    func enqueueDestroy(_ slot: Int) { queue(BF_ACT_DROP_ITEM, Int32(slot)) }

    // Day/night pin for testing lighting: 0 = auto, 1 = always-day, 2 = always-night.
    // Mutually exclusive by construction (a single mode value). Surfaced to the HUD
    // via onTimeModeChanged so an indicator / settings control can mirror the state.
    private(set) var timeMode: Int32 = 0
    var onTimeModeChanged: ((Int32) -> Void)?

    // Cycle auto -> always-day -> always-night -> auto. Bound to 'T'.
    private func cycleTimeMode() {
        setTimeMode((timeMode + 1) % 3)
    }

    // Set the day/night pin directly (used by 'T' and by any settings control that
    // wants to drive it). Sends BF_ACT_SET_TIME_MODE so the engine pins the clock.
    func setTimeMode(_ mode: Int32) {
        timeMode = mode
        queue(BF_ACT_SET_TIME_MODE, mode)
        let label = ["auto (normal day/night)", "always day", "always night"][Int(mode)]
        NSLog("Blockfall: time mode = \(label)")
        onTimeModeChanged?(mode)
    }

    // Inventory move from the HUD (BF_ACT_INV_MOVE: from, to, count).
    func enqueueMove(from: Int, to: Int, count: Int) {
        var a = bf_action(); a.kind = BF_ACT_INV_MOVE
        a.arg_i = Int32(from); a.arg_j = Int32(to); a.arg_k = Int32(count)
        actionQueue.append(a)
    }

    // ---- keyboard ----------------------------------------------------------
    override func keyDown(with e: NSEvent) {
        if e.keyCode == K.esc {
            // Esc priority: close the quest log, then the inventory, else pause.
            if questLogOpen { toggleQuestLog() }
            else if invOpen { toggleInventory() }
            else { onPause?() }
            return
        }
        // While paused, no game key should act — 'E' especially would re-capture the
        // mouse and make the pause overlay buttons unclickable.
        guard !gamePaused else { return }
        if e.keyCode == 37 { toggleQuestLog(); return }    // 'L' — quest log (#42)
        if e.keyCode == 14 { toggleInventory(); return }   // 'E' — inventory
        if e.keyCode == 8 { queue(BF_ACT_MODE_TOGGLE); return } // 'C' — creative/survival
        if e.keyCode == 12 { queue(BF_ACT_CRAFT); return }      // 'Q' — craft first available
        if e.keyCode == 34 { invertX.toggle()                    // 'I' — invert left/right
            NSLog("Blockfall: invert X (left/right) = \(invertX)"); return }
        if e.keyCode == 31 { invertY.toggle()                    // 'O' — invert up/down
            NSLog("Blockfall: invert Y (up/down) = \(invertY)"); return }
        if e.keyCode == 4  { onHost?(); return }                // 'H' — host LAN co-op
        if e.keyCode == 38 { onJoin?(); return }                // 'J' — join a LAN host
        if e.keyCode == 17 { cycleTimeMode(); return }          // 'T' — auto/day/night pin
        if e.keyCode == 42 { onToggleDebugHud?(); return }      // '\' — debug overlay (on-HUD gfx toggles)
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

    // #42: quest-log toggle. The overlay is purely cosmetic (the game keeps
    // running — no engine pause action), but we release the pointer while it's
    // open so the player can read/scroll, mirroring the inventory.
    private var questLogOpen = false
    private func toggleQuestLog() {
        questLogOpen.toggle()
        onToggleQuestLog?()
        if questLogOpen { releasePointer() } else if !invOpen { capturePointer() }
    }
    override func keyUp(with e: NSEvent) { pressed.remove(e.keyCode) }
    override func flagsChanged(with e: NSEvent) {
        shiftDown = e.modifierFlags.contains(.shift)
        ctrlDown  = e.modifierFlags.contains(.control)
    }

    // ---- mouse -------------------------------------------------------------
    override func mouseDown(with e: NSEvent) {
        if gamePaused { return }               // let the pause overlay get clicks
        // Debug overlay: the pointer is free so the player can click HUD toggles.
        // A hit flips the effect (handled by the app shell); a miss is ignored so
        // we don't re-grab the cursor mid-A/B-test. The world keeps running.
        if debugHudActive { _ = onDebugClick?(e); return }
        if !captured { capturePointer() } else { queue(BF_ACT_MINE_START) }
    }
    override func mouseUp(with e: NSEvent) { if captured { queue(BF_ACT_MINE_STOP) } }
    override func rightMouseDown(with e: NSEvent) { if captured { queue(BF_ACT_INTERACT) } }  // #69 interact (befriend) or place
    override func mouseMoved(with e: NSEvent)   { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }
    override func mouseDragged(with e: NSEvent) { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }
    override func rightMouseDragged(with e: NSEvent) { if captured { lookDX += Float(e.deltaX); lookDY += Float(e.deltaY) } }

    private var cursorHidden = false   // keep hide/unhide balanced so the cursor never gets stuck
    private func capturePointer() {
        // While the debug overlay is up the pointer must stay free so its toggles
        // are clickable; ignore capture requests from inventory/quest-log/resume
        // transitions until debug is turned off (which calls capture itself).
        if debugHudActive { return }
        captured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }
    private func releasePointer() {
        // Releasing the pointer mid-mine (inventory open / pause) would otherwise
        // never deliver mouseUp's MINE_STOP and the engine mines forever.
        queue(BF_ACT_MINE_STOP)
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
