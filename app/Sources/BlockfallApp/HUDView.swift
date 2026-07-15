// ============================================================================
// Blockfall — HUDView (Phase 0 / M0)
// A lightweight AppKit overlay that renders the engine's HUD snapshot: hotbar,
// health, and the active quest. Deliberately simple (Core Graphics, no Metal
// text) so M0 proves the HUD-state handoff end to end. Track E may later move
// this into the Metal layer; the data contract (bf_hud_state) stays the same.
// ============================================================================
import AppKit
import QuartzCore   // CACurrentMediaTime for the #29 FPS counter
import simd         // #202 villager chatter pair distances
import CBlockcore

final class HUDView: NSView {
    private var hud = bf_hud_state()
    private var crosshair = true

    // --- Interactive inventory state ---
    // Closure the lead wires to BF_ACT_INV_MOVE (arg_i=from, arg_j=to, arg_k=count).
    var onMove: ((_ from: Int, _ to: Int, _ count: Int) -> Void)?
    // Called when the player clicks a craftable row. index = 0-based craftable slot.
    var onCraft: ((Int) -> Void)?
    // #15: creative item picker — clicking an item in the picker gives it to the
    // player. Wired by the lead to BF_ACT_GIVE_ITEM (or equivalent). nil = no-op.
    var onGiveItem: ((UInt16) -> Void)?
    // Slot-index (0..35) of a "picked up" stack, or nil when nothing is held.
    private var heldSlot: Int? = nil
    private var heldItem: bf_item_id = 0
    private var heldCount: UInt16 = 0
    // Last 36 slot rects we drew (index == inventory index). Empty when closed.
    private var slotRects: [NSRect] = []
    // Craftable recipe slot rects we drew, parallel to hud.craftable (index ==
    // recipe index, 0-based; the on-screen number key is index+1). Empty when
    // closed or when there are no craftable recipes. Tracked exactly like
    // slotRects so hover hit-testing stays in sync with what we draw.
    private var craftRects: [NSRect] = []
    // Current mouse position in view coords (for tooltip + held-stack ghost).
    private var mousePos: NSPoint = .zero
    private var mouseInside = false
    private var trackingAreaRef: NSTrackingArea?
    // Death feedback: respawn happens same-frame, so we detect it as health
    // jumping back to full from a near-empty state and flash a kid-readable banner.
    private var prevHealth: Float = 20
    private var deathFlashUntil: TimeInterval = 0

    // --- #12: always-visible coordinates + facing readout ---
    // The renderer calls setPlayerInfo each frame. facing is a yaw in radians
    // from atan2(forward.x, forward.z); we round coords to ints for display.
    private var playerX: Float = 0
    private var playerY: Float = 0
    private var playerZ: Float = 0
    private var playerFacing: Float = 0   // yaw radians

    // --- #30: day/night indicator ---
    // Renderer pushes the world time-of-day each frame via setTimeOfDay.
    // 0 = midnight, 0.5 = noon (one full day = 0..1, wrapping). Stored and shown
    // in the top-right status box as a sun/moon glyph + Day/Night/Dawn/Dusk label
    // and a small progress bar marking position in the cycle.
    private var timeOfDay: Float = 0.5    // default to noon so a fresh HUD reads "Day"

    // --- #34: destroy/trash slot ---
    // The lead wires this to the engine; it fires with the inventory slot index
    // (0..35) that should be emptied. Triggered by dropping a picked-up stack on
    // the trash slot while the inventory is open.
    var onDestroy: ((Int) -> Void)?
    // Rect of the trash slot we last drew (inventory open only). .zero = not shown.
    private var trashRect: NSRect = .zero

    // --- #109 chest panel ---
    // The Renderer polls bf_chest_open_pos / bf_chest_query each frame and pushes the
    // open chest's contents here (or closes it). When chestOpen is true we draw a panel
    // with the chest's slots on top and the player inventory below, and clicking moves
    // items between them. Closing on ESC / use-again is driven by the engine (the poll
    // returns no open chest), so we just mirror that state. The lead wires:
    //   onChestTake(slot)        -> bf_chest_take(pos, slot)      (chest slot -> inventory)
    //   onChestDeposit(invSlot)  -> bf_chest_deposit(pos, invSlot)(inventory slot -> chest)
    // Items are never destroyed: a full inventory leaves the stack in the chest (engine).
    var onChestTake: ((Int) -> Void)?
    var onChestDeposit: ((Int) -> Void)?
    private var chestOpen = false
    private var chestSlots: [bf_hud_slot] = []          // BF_CHEST_SLOTS live contents
    private var chestSlotRects: [NSRect] = []           // hit-test rects for chest slots
    private var chestInvRects: [NSRect] = []            // hit-test rects for the inventory grid

    // Renderer: a chest was opened (right-click on a chest). Mirror its contents.
    func setChestOpen(pos: bf_ivec3, view: bf_chest_view) {
        var slots: [bf_hud_slot] = []
        withUnsafeBytes(of: view.slots) { raw in
            let p = raw.bindMemory(to: bf_hud_slot.self)
            for i in 0..<Int(BF_CHEST_SLOTS) { slots.append(p[i]) }
        }
        let changed = !chestOpen || slots.count != chestSlots.count
            || zip(slots, chestSlots).contains { $0.item != $1.item || $0.count != $1.count }
        chestOpen = true
        chestSlots = slots
        if changed { needsDisplay = true }
    }

    // Renderer: no chest open. Hide the panel and drop any held stack.
    func setChestClosed() {
        if chestOpen {
            chestOpen = false
            chestSlots = []
            chestSlotRects = []
            chestInvRects = []
            clearHeld()
            needsDisplay = true
        }
    }

    var isChestOpen: Bool { chestOpen }

    // --- #95 living villages: the tier/donation status of the nearest village, pushed
    // each frame by the Renderer (bf_village_query). nil when no village is near. Drives
    // a small donation panel so the player can see what each villager wants and the
    // town's current tier + progress.
    private var villageView: bf_village_view? = nil
    func setVillage(_ v: bf_village_view?) {
        let was = villageView
        villageView = v
        // Repaint when presence, tier, or progress changed (cheap field compare).
        let changed: Bool = {
            guard let a = was, let b = v else { return (was == nil) != (v == nil) }
            return a.present != b.present || a.tier != b.tier
                || a.wood_cells != b.wood_cells || a.progress != b.progress
                || a.lights != b.lights || a.ward_active != b.ward_active
        }()
        if changed { needsDisplay = true }
    }

    // --- #29: FPS counter ---
    // Derived purely from the time between draw(_:) calls (the renderer already
    // drives one redraw per frame), so no timer is added. We keep an exponential
    // moving average of the instantaneous FPS so the number reads steadily
    // instead of flickering every frame. lastDrawTime < 0 means "no prior frame".
    private var lastDrawTime: CFTimeInterval = -1
    private var smoothedFPS: Double = 0

    // --- #16: scrollable craft list ---
    // Vertical scroll offset (in points) into the craft band. 0 = top of list.
    // Clamped to [0, maxCraftScroll] each draw against the real content height.
    private var craftScroll: CGFloat = 0
    private var maxCraftScroll: CGFloat = 0
    // The clipping rect of the craft rows viewport (set each draw); used to
    // reject clicks/hover on rows scrolled out of view.
    private var craftViewport: NSRect = .zero
    // Index parallel to craftRects: the recipe index each drawn rect represents.
    // (Only visible rows get rects, so positions in craftRects no longer equal
    // recipe indices once scrolled — keep the mapping explicit.)
    private var craftRowIndex: [Int] = []

    // --- #15: creative item picker ---
    // Scroll offset into the picker grid and its clamp/viewport, mirroring the
    // craft-list approach. Rects parallel to pickerItemIds for hit-testing.
    private var pickerScroll: CGFloat = 0
    private var maxPickerScroll: CGFloat = 0
    private var pickerViewport: NSRect = .zero
    private var pickerRects: [NSRect] = []
    private var pickerItemIds: [UInt16] = []
    // Sorted list of every known item id.
    private static let kAllItemIds: [UInt16] = allItemIds()

    // --- HUD options (#: text size + visibility) ---
    // Global multiplier applied to EVERY HUD font size (and the paddings that
    // depend on text height). 1.0 = the original sizes (the smallest acceptable);
    // up to ~2.0 for kids who want big text. Set from the pause-menu options and
    // persisted via UserDefaults by the app shell.
    var hudScale: CGFloat = 1.0 {
        didSet { if hudScale != oldValue { needsDisplay = true } }
    }
    // When false, the in-world gameplay HUD overlays are hidden. The inventory
    // and quest-log screens (explicitly opened) still draw so they remain usable.
    var hudVisible: Bool = true {
        didSet { if hudVisible != oldValue { needsDisplay = true } }
    }
    // Scale a base font size by the current HUD scale. Single funnel so every
    // text element honours the option.
    private func fs(_ base: CGFloat) -> CGFloat { base * hudScale }

    // --- #42: Quest/progression log overlay ---
    // Full quest chain, fetched by the Renderer (which owns the engine handle)
    // and pushed in via setQuests while the log is open. Toggled by 'L' in
    // GameView; closable with Esc. Drawn as a translucent panel listing every
    // quest with done / active / upcoming styling.
    private var questLogOpen = false
    private var quests: [QuestRow] = []
    private var questLogScroll: CGFloat = 0
    private var maxQuestLogScroll: CGFloat = 0
    private var questLogViewport: NSRect = .zero
    struct QuestRow { let title: String; let objective: String; let state: UInt8; let progress: Float }

    // True when the renderer should fetch + forward the quest list this frame.
    var isQuestLogOpen: Bool { questLogOpen }
    // Toggle the quest log (bound to 'L' in GameView). Returns the new open
    // state. GameView mirrors this state so Esc can close the log before pausing.
    @discardableResult
    func toggleQuestLog() -> Bool { questLogOpen.toggle(); needsDisplay = true; return questLogOpen }
    // Renderer pushes the freshly-fetched quest list each frame while open.
    func setQuests(_ rows: [QuestRow]) { quests = rows; if questLogOpen { needsDisplay = true } }

    // Screenshot confirmation flash (backslash key). A brief, non-blocking toast in
    // the corner so the player gets visible feedback that a shot was captured. Never
    // pauses the game. Set by the Renderer after a successful save; auto-clears.
    private var screenshotFlashUntil: TimeInterval = 0
    func flashScreenshot() {
        screenshotFlashUntil = Date().timeIntervalSinceReferenceDate + 1.2
        needsDisplay = true
        // Schedule a redraw after the flash window so it disappears even if the HUD
        // would not otherwise repaint (e.g. the player is standing still).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.needsDisplay = true
        }
    }

    // Draw the fading "Screenshot saved" toast near the top-center. Fades out over
    // its lifetime; a no-op once expired.
    private func drawScreenshotFlash(in b: NSRect) {
        let now = Date().timeIntervalSinceReferenceDate
        guard now < screenshotFlashUntil else { return }
        let a = CGFloat(min(1, (screenshotFlashUntil - now) / 1.2))   // 1 -> 0
        let msg = "📸 Screenshot saved"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(15)),
            .foregroundColor: NSColor.white.withAlphaComponent(a),
            .strokeColor: NSColor.black.withAlphaComponent(a), .strokeWidth: -3.0,
        ]
        let sz = (msg as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 10
        let bx = b.midX - sz.width / 2 - pad
        let by = b.maxY - 64 - sz.height
        let bg = NSRect(x: bx, y: by - 6, width: sz.width + pad * 2, height: sz.height + 12)
        NSColor.black.withAlphaComponent(0.55 * a).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        (msg as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: by), withAttributes: attrs)
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    // Click-through during play; capture clicks only when an overlay (inventory
    // or quest log) is open so its scroll/close interactions work.
    override func hitTest(_ point: NSPoint) -> NSView? {
        (hud.inventory_open != 0 || questLogOpen || chestOpen) ? self : nil
    }
    // Never take key focus — the GameView must keep receiving Esc/E so the
    // inventory can always be closed (clicking a slot was stealing first
    // responder and killing the close keys). Mouse events still arrive via
    // hitTest regardless of first responder.
    override var acceptsFirstResponder: Bool { false }

    func update(from h: bf_hud_state) {
        let wasOpen = hud.inventory_open != 0
        hud = h
        // If the inventory just closed, drop any picked-up stack.
        if wasOpen && hud.inventory_open == 0 { clearHeld() }
        needsDisplay = true
    }

    private func clearHeld() {
        heldSlot = nil; heldItem = 0; heldCount = 0
    }

    // #12: Renderer pushes the player's world position + yaw each frame. We only
    // request a repaint when the displayed (rounded) value actually changes, so
    // the always-on readout doesn't force a redraw 60×/s while standing still.
    func setPlayerInfo(x: Float, y: Float, z: Float, facing: Float) {
        let changed = x.rounded() != playerX.rounded()
            || y.rounded() != playerY.rounded()
            || z.rounded() != playerZ.rounded()
            || cardinal(from: facing) != cardinal(from: playerFacing)
        playerX = x; playerY = y; playerZ = z; playerFacing = facing
        // Don't fight the inventory's own repaints; in-world readout only.
        if changed && hud.inventory_open == 0 { needsDisplay = true }
    }

    // Map a yaw (radians, from atan2(forward.x, forward.z)) to an 8-way compass
    // label. We bucket into 8 sectors of 45°. atan2(x,z): +z forward = 0,
    // +x (east) = +90°. Normalize to [0,360) then divide into octants.
    private func cardinal(from yaw: Float) -> String {
        let names = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
        // yaw=0 points toward +z. We label +z as South and +x as East so the
        // compass reads naturally on the standard right-handed world layout.
        var deg = Double(yaw) * 180.0 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        let idx = Int((deg / 45.0).rounded()) % 8
        return names[idx]
    }

    // #30: Renderer pushes the world time-of-day each frame, pre-converted by
    // Renderer.clockPhase to this view's midnight-at-zero convention (0=midnight,
    // 0.5=noon; see #237). We normalize into [0,1) and only request a repaint
    // when the displayed phase label or the integer clock hour changes, so the
    // always-on indicator doesn't force a redraw 60×/s while time creeps.
    func setTimeOfDay(_ t: Float) {
        var nt = t.truncatingRemainder(dividingBy: 1)
        if nt < 0 { nt += 1 }
        if !nt.isFinite { nt = 0.5 }
        let changed = timePhase(nt).0 != timePhase(timeOfDay).0
            || clockHour(nt) != clockHour(timeOfDay)
        timeOfDay = nt
        if changed && hud.inventory_open == 0 { needsDisplay = true }
    }

    // Day/night pin indicator: 0 auto, 1 always-day, 2 always-night. Set from
    // GameView's T key so the player gets visible confirmation the pin is active.
    var timeMode: Int32 = 0
    func setTimeMode(_ m: Int32) { if m != timeMode { timeMode = m; needsDisplay = true } }

    // Map time-of-day [0,1) to a (label, glyph). Day ≈ [0.25,0.75]; the ~0.05
    // bands at each transition read as Dawn (sunrise ~0.25) / Dusk (sunset ~0.75).
    private func timePhase(_ t: Float) -> (String, String) {
        switch t {
        case 0.23..<0.30: return ("Dawn", "🌅")
        case 0.30..<0.70: return ("Day",  "☀️")
        case 0.70..<0.77: return ("Dusk", "🌇")
        default:          return ("Night", "🌙")
        }
    }

    // Time-of-day as an integer 24h clock hour (0=midnight at t=0).
    private func clockHour(_ t: Float) -> Int {
        let h = Int((Double(t) * 24.0).rounded(.down)) % 24
        return h < 0 ? h + 24 : h
    }

    // --- #13: Multiplayer compass — other connected players (remote peers) ---
    // The Renderer scans the render frame for remote-player entities (kind 100),
    // works out for each whether it is on-screen/in-front (with a screen point)
    // or off-screen/behind (with an edge direction to point an arrow), plus the
    // distance + that peer's tint colour, and pushes the list here each frame.
    // We draw a floating marker for on-screen peers and a bright edge arrow for
    // off-screen ones so co-op kids can always find each other. Honours
    // hudVisible / hudScale like the rest of the HUD. Empty when no peers exist
    // (the compass draws nothing then).
    struct PeerMarker {
        let onScreen: Bool      // true = in front AND inside the viewport
        let screenPt: CGPoint   // view-pixel point (only meaningful when onScreen)
        let edgeDir:  CGVector  // unit-ish direction to point the arrow (off-screen)
        let distM:    Int       // distance to the peer, metres (rounded)
        let color:    NSColor   // the peer's per-peer tint
        let label:    String    // player, creature objective, or local artisan
    }
    private var peers: [PeerMarker] = []

    // Renderer pushes the per-frame peer list. We always request a repaint when
    // peers are present (or were present last frame) so markers/arrows track the
    // moving camera; an empty→empty transition is a no-op so an idle solo game
    // never forces extra redraws.
    func setPeers(_ list: [PeerMarker]) {
        let had = !peers.isEmpty
        peers = list
        if (had || !list.isEmpty) && hud.inventory_open == 0 && !questLogOpen {
            needsDisplay = true
        }
    }

    // --- #202: villager chatter, comic speech bubbles over talking pairs -------
    // The renderer pushes every on-screen villager (stable key + projected head
    // point) each frame. A tiny state machine picks a nearby PAIR, runs a short
    // scripted exchange (A speaks, B replies, sometimes one more round), then
    // cools down and picks a new pair. Bubbles are classic comic style: white
    // rounded rect, dark outline, a little tail pointing at the speaker's head.
    struct VillagerMarker {
        let key: UInt32          // stable per-villager id (from the #201 colour)
        let screenPt: CGPoint    // projected head point (view points)
        let worldPos: SIMD3<Float>
        let dist: Float          // metres from the camera
    }
    private var villagers: [VillagerMarker] = []
    private var chatPair: (a: UInt32, b: UInt32)? = nil
    private var chatScript: [(who: Int, line: String)] = []   // 0 = a, 1 = b
    private var chatStep = -1
    private var chatStepEnds: CFTimeInterval = 0
    private var chatCooldownUntil: CFTimeInterval = 0
    private var chatRng = SystemRandomNumberGenerator()

    // Kid-friendly exchanges. Short lines so bubbles stay small and readable.
    private static let chatScripts: [[(Int, String)]] = [
        [(0, "Nice day, huh?"), (1, "The best!")],
        [(0, "I saw a slime!"), (1, "Eek! Where?!"), (0, "It bounced away.")],
        [(0, "Berry pie later?"), (1, "Save me a slice!")],
        [(0, "My hut is cozy."), (1, "Mine has a plant!")],
        [(0, "Race you home!"), (1, "You always win!")],
        [(0, "The stars are out."), (1, "Make a wish!")],
        [(0, "I petted a fox."), (1, "So fluffy!")],
        [(0, "Need more wood."), (1, "Ask the woodcutter!")],
        [(0, "Heard a ghost..."), (1, "Just the wind!"), (0, "Phew!")],
        [(0, "New here?"), (1, "Been here forever!")],
    ]

    func setVillagers(_ list: [VillagerMarker], now: CFTimeInterval) {
        let had = !villagers.isEmpty
        villagers = list
        chatterTick(now: now)
        if (had || !list.isEmpty) && hud.inventory_open == 0 && !questLogOpen {
            needsDisplay = true
        }
    }

    private func chatterTick(now: CFTimeInterval) {
        // Advance or finish an active exchange.
        if let pair = chatPair {
            let aVisible = villagers.contains { $0.key == pair.a }
            let bVisible = villagers.contains { $0.key == pair.b }
            if !aVisible || !bVisible {
                chatPair = nil
                chatCooldownUntil = now + 4
            } else if now >= chatStepEnds {
                chatStep += 1
                if chatStep >= chatScript.count {
                    chatPair = nil
                    chatCooldownUntil = now + CFTimeInterval(Int.random(in: 7...14, using: &chatRng))
                } else {
                    chatStepEnds = now + 2.8
                }
            }
            return
        }
        guard now >= chatCooldownUntil, villagers.count >= 2 else { return }
        // Pick the closest-together on-screen pair within 7 blocks of each other.
        var best: (a: VillagerMarker, b: VillagerMarker, d: Float)? = nil
        for i in 0..<villagers.count {
            for j in (i + 1)..<villagers.count {
                let d = simd_length(villagers[i].worldPos - villagers[j].worldPos)
                if d < 7, best == nil || d < best!.d {
                    best = (villagers[i], villagers[j], d)
                }
            }
        }
        guard let pick = best else { return }
        chatPair = (pick.a.key, pick.b.key)
        chatScript = HUDView.chatScripts.randomElement(using: &chatRng) ?? HUDView.chatScripts[0]
        chatStep = 0
        chatStepEnds = now + 2.8
    }

    private func drawChatter(in b: NSRect) {
        guard let pair = chatPair, chatStep >= 0, chatStep < chatScript.count else { return }
        let (who, line) = chatScript[chatStep]
        let key = who == 0 ? pair.a : pair.b
        guard let m = villagers.first(where: { $0.key == key }) else { return }
        // Comic bubble above the head, clamped on screen.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(14)),
            .foregroundColor: NSColor.black,
        ]
        let sz = (line as NSString).size(withAttributes: attrs)
        let padX: CGFloat = fs(10), padY: CGFloat = fs(6)
        var bubble = NSRect(x: m.screenPt.x - sz.width / 2 - padX,
                            y: m.screenPt.y + fs(14),
                            width: sz.width + padX * 2,
                            height: sz.height + padY * 2)
        bubble.origin.x = max(6, min(b.maxX - bubble.width - 6, bubble.origin.x))
        bubble.origin.y = max(6, min(b.maxY - bubble.height - 6, bubble.origin.y))
        let path = NSBezierPath(roundedRect: bubble, xRadius: fs(9), yRadius: fs(9))
        // Tail: small triangle from the bubble toward the head point.
        let tail = NSBezierPath()
        let tx = max(bubble.minX + 12, min(bubble.maxX - 12, m.screenPt.x))
        tail.move(to: NSPoint(x: tx - fs(5), y: bubble.minY + 1))
        tail.line(to: NSPoint(x: m.screenPt.x, y: m.screenPt.y + fs(4)))
        tail.line(to: NSPoint(x: tx + fs(5), y: bubble.minY + 1))
        tail.close()
        NSColor.white.withAlphaComponent(0.96).setFill()
        path.fill(); tail.fill()
        NSColor.black.withAlphaComponent(0.85).setStroke()
        path.lineWidth = fs(1.6); path.stroke()
        tail.lineWidth = fs(1.4); tail.stroke()
        (line as NSString).draw(at: NSPoint(x: bubble.minX + padX, y: bubble.minY + padY),
                                withAttributes: attrs)
    }

    // ----- Mouse handling (active only while the inventory is open) -----

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        mousePos = convert(event.locationInWindow, from: nil)
        if hud.inventory_open != 0 { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        if hud.inventory_open != 0 { needsDisplay = true }
    }

    override func mouseMoved(with event: NSEvent) {
        mouseInside = true
        mousePos = convert(event.locationInWindow, from: nil)
        // Repaint only when an overlay is open (tooltip / held-stack ghost / chest hover);
        // during play the in-world HUD doesn't track the mouse.
        if hud.inventory_open != 0 || chestOpen { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        // #109 chest panel click-to-move: a click on a chest slot takes that stack into
        // the inventory; a click on an inventory slot deposits it into the chest. The
        // engine refreshes both sides next frame (it never destroys items: a full
        // inventory leaves the stack in the chest). No "held/ghost" stack here — kid
        // simple single-click moves, matching the panel's hint text.
        if chestOpen {
            let cp = convert(event.locationInWindow, from: nil)
            mousePos = cp
            for (i, r) in chestSlotRects.enumerated() where r.contains(cp) {
                onChestTake?(i)
                needsDisplay = true
                return
            }
            for (i, r) in chestInvRects.enumerated() where r.contains(cp) {
                onChestDeposit?(i)
                needsDisplay = true
                return
            }
            return
        }
        guard hud.inventory_open != 0 else { return }   // gameplay: ignore
        let p = convert(event.locationInWindow, from: nil)
        mousePos = p

        // #34: Trash slot — if carrying a stack and clicking the trash, destroy
        // the held stack's source slot. Checked first so the trash always wins
        // over slot/craft/picker hit-testing while a stack is held. Clicking the
        // trash with nothing held is a harmless no-op.
        if let src = heldSlot, trashRect.contains(p) {
            onDestroy?(src)
            clearHeld()                                  // engine refreshes next frame
            needsDisplay = true
            return
        }

        // #15: Creative item picker takes priority when shown — clicking an item
        // gives it to the player. Only active in creative mode (its rects are
        // empty otherwise, so this is a no-op in survival).
        if heldSlot == nil, let pid = pickerItemId(at: p) {
            onGiveItem?(pid)
            needsDisplay = true
            return
        }

        // Check craft rows next — clicking one crafts the recipe.
        if heldSlot == nil, let ci = craftIndex(at: p) {
            onCraft?(ci)
            needsDisplay = true
            return
        }

        guard let idx = slotIndex(at: p) else {
            // Click on empty space cancels a pending pickup.
            if heldSlot != nil { clearHeld(); needsDisplay = true }
            return
        }
        if let src = heldSlot {
            if idx == src {
                clearHeld()                              // same slot -> cancel
            } else {
                onMove?(src, idx, Int(heldCount))        // place onto target
                clearHeld()                              // engine refreshes next frame
            }
            needsDisplay = true
        } else {
            // First click: pick up the whole stack if the slot is non-empty.
            let s = inventorySlot(idx)
            if s.item != 0 {
                heldSlot = idx; heldItem = s.item; heldCount = s.count
                needsDisplay = true
            }
        }
    }

    // #16 / #15: mouse-wheel scrolling for the craft list and the creative
    // picker. Whichever panel the cursor is over receives the scroll; offsets
    // are clamped against the live content height (recomputed each draw). When
    // the inventory is closed we ignore the wheel entirely (pass it through is
    // unnecessary since hitTest already returns nil during play).
    override func scrollWheel(with event: NSEvent) {
        // Quest log scrolls independently of the inventory.
        if questLogOpen {
            let p = convert(event.locationInWindow, from: nil)
            if questLogViewport.contains(p) && maxQuestLogScroll > 0 {
                questLogScroll = min(max(0, questLogScroll + event.scrollingDeltaY), maxQuestLogScroll)
                needsDisplay = true
            }
            return
        }
        guard hud.inventory_open != 0 else { super.scrollWheel(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        // scrollingDeltaY: +up / -down in AppKit. Scrolling "down" should reveal
        // lower entries, i.e. increase the offset.
        let dy = event.scrollingDeltaY
        if pickerViewport.contains(p) && maxPickerScroll > 0 {
            pickerScroll = min(max(0, pickerScroll + dy), maxPickerScroll)
            needsDisplay = true
        } else if craftViewport.contains(p) && maxCraftScroll > 0 {
            craftScroll = min(max(0, craftScroll + dy), maxCraftScroll)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        // --- #29: FPS from draw-to-draw timing (no timer) ---
        // Measure the delta since the previous draw. Clamp the delta to a sane
        // range so a paused/backgrounded gap can't produce a wild value, then
        // fold the instantaneous FPS into an exponential moving average. We do
        // this every frame (even with the inventory open) so the number stays
        // current and the box shows a stable reading the instant it's drawn.
        let nowT = CACurrentMediaTime()
        if lastDrawTime > 0 {
            let dt = nowT - lastDrawTime
            if dt > 0.0001 && dt < 1.0 {            // ignore zero / huge gaps
                let inst = 1.0 / dt
                // EMA: weight new samples lightly so the readout doesn't jitter.
                smoothedFPS = smoothedFPS <= 0 ? inst : smoothedFPS * 0.9 + inst * 0.1
            }
        }
        lastDrawTime = nowT

        // Detect death+respawn (health was a small positive, then jumps back to
        // full). prevHealth must be > 0.5 so a startup/zero-frame health (0) can
        // NEVER look like a death — that was firing a false "you died" on spawn.
        if hud.mode == BF_MODE_SURVIVAL {
            if prevHealth > 0.5 && prevHealth < 6 && hud.health >= prevHealth + 8 {
                deathFlashUntil = Date().timeIntervalSinceReferenceDate + 2.0
            }
            prevHealth = hud.health
        }

        // Screenshot confirmation toast (drawn in every HUD state, including over the
        // inventory / quest log, so the backslash key always gives feedback). Set by
        // the Renderer AFTER the captured frame, so it never appears in the saved PNG.
        drawScreenshotFlash(in: b)

        // #109 the chest panel replaces the in-world HUD while a chest is open. It is
        // its own screen (chest slots + player inventory + click-to-move).
        if chestOpen { drawChestPanel(in: b); return }

        // When the inventory is open it replaces the in-world HUD.
        if hud.inventory_open != 0 { drawInventory(in: b); return }

        // #42: the quest log overlay draws over the world (game keeps running).
        // It's an explicit screen, so it shows even when the gameplay HUD is
        // hidden via the visibility option.
        if questLogOpen { drawQuestLog(in: b); return }

        // #: HUD visibility toggle — when off, hide all the in-world info
        // overlays (hotbar, hearts, quest, status box, hints, toasts, etc.).
        // The crosshair stays so the player can still aim.
        if !hudVisible {
            if crosshair {
                let cx = b.midX, cy = b.midY, s: CGFloat = 8
                NSColor.white.withAlphaComponent(0.85).setStroke()
                let path = NSBezierPath()
                path.lineWidth = 2
                path.move(to: NSPoint(x: cx - s, y: cy)); path.line(to: NSPoint(x: cx + s, y: cy))
                path.move(to: NSPoint(x: cx, y: cy - s)); path.line(to: NSPoint(x: cx, y: cy + s))
                path.stroke()
            }
            return
        }

        // --- Death banner (fades over 2s) ---
        let now = Date().timeIntervalSinceReferenceDate
        if now < deathFlashUntil {
            let a = CGFloat((deathFlashUntil - now) / 2.0)   // 1 -> 0
            NSColor.systemRed.withAlphaComponent(0.35 * a).setFill()
            b.fill()
            let msg = "Oh no! You ran out of hearts!"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(34)),
                .foregroundColor: NSColor.white.withAlphaComponent(a),
                .strokeColor: NSColor.black.withAlphaComponent(a), .strokeWidth: -3.0,
            ]
            let sz = (msg as NSString).size(withAttributes: attrs)
            (msg as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY + 60), withAttributes: attrs)
        }

        // --- Crosshair ---
        if crosshair {
            let cx = b.midX, cy = b.midY, s: CGFloat = 8
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: NSPoint(x: cx - s, y: cy)); path.line(to: NSPoint(x: cx + s, y: cy))
            path.move(to: NSPoint(x: cx, y: cy - s)); path.line(to: NSPoint(x: cx, y: cy + s))
            path.stroke()
        }

        // --- Look-at name (what the crosshair is pointing at), under crosshair ---
        let lookName = withUnsafeBytes(of: hud.look_name) { raw -> String in
            // Guaranteed NUL-terminated by the engine; bind as CChar and read.
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !lookName.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(14)), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let sz = (lookName as NSString).size(withAttributes: attrs)
            (lookName as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY - 28 * hudScale),
                                        withAttributes: attrs)
        }

        // --- Hotbar (9 slots, centered along the bottom) ---
        // Scale the slot size with the HUD scale so larger count badges / item
        // icons stay proportionate and the hearts/quest anchors above it follow.
        let slot: CGFloat = 48 * hudScale, gap: CGFloat = 6 * hudScale
        let total = CGFloat(BF_HOTBAR_SLOTS) * slot + CGFloat(BF_HOTBAR_SLOTS - 1) * gap
        var x = b.midX - total / 2
        let y: CGFloat = 24
        withUnsafeBytes(of: hud.hotbar) { raw in
            let slots = raw.bindMemory(to: bf_hud_slot.self)
            for i in 0..<Int(BF_HOTBAR_SLOTS) {
                let rect = NSRect(x: x, y: y, width: slot, height: slot)
                let selected = (Int(hud.selected_slot) == i)
                (selected ? NSColor.white : NSColor.black.withAlphaComponent(0.45)).setFill()
                let rr = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                rr.fill()
                NSColor.white.withAlphaComponent(selected ? 1.0 : 0.5).setStroke()
                rr.lineWidth = selected ? 3 : 1.5
                rr.stroke()

                let s = slots[i]
                if s.item != 0 {
                    drawCenteredItem(id: s.item, count: s.count, in: rect, selected: selected)
                }
                x += slot + gap
            }
        }

        // --- Held item name (above the hotbar, centered) ---
        let heldName: String = withUnsafeBytes(of: hud.hotbar) { raw in
            let slots = raw.bindMemory(to: bf_hud_slot.self)
            let sel = min(Int(hud.selected_slot), Int(BF_HOTBAR_SLOTS) - 1)  // never read past the hotbar
            let s = slots[sel]
            return s.item != 0 ? itemName(s.item) : ""
        }
        if !heldName.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(15)), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let sz = (heldName as NSString).size(withAttributes: attrs)
            (heldName as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: y + slot + 8 * hudScale), withAttributes: attrs)
        }

        // --- Health hearts (survival) ---
        if hud.mode == BF_MODE_SURVIVAL {
            let heartsY = y + slot + 34 * hudScale
            drawHearts(value: hud.health, max: 20, at: NSPoint(x: b.midX - total / 2, y: heartsY))
            // Oxygen bubbles above the hearts, only while underwater (not full).
            if hud.oxygen < 0.999 {
                drawBubbles(value: hud.oxygen, at: NSPoint(x: b.midX - total / 2, y: heartsY + 18 * hudScale))
            }
        }

        // --- #42/#: Active quest (top-left), now wrapped in a rounded
        // translucent dark panel matching the top-right status box so it reads
        // clearly on any terrain. Keeps the ★ title, objective, and the green
        // progress bar. Sized to its content + scaled with the HUD scale.
        // questPanelBottom carries the panel's bottom edge so the coords readout
        // below can anchor under it at any size.
        var questPanelBottom = b.maxY - 24    // default top-left when no quest
        if hud.active_quest_id != 0 {
            let title = withUnsafeBytes(of: hud.quest_title) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let obj = withUnsafeBytes(of: hud.quest_objective) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let titleStr = "★ " + title

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(16)), .foregroundColor: NSColor.systemYellow,
                .strokeColor: NSColor.black, .strokeWidth: -2.0,
            ]
            let objAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fs(13)), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -2.0,
            ]
            let tSz = (titleStr as NSString).size(withAttributes: titleAttrs)
            let oSz = (obj as NSString).size(withAttributes: objAttrs)

            let pad: CGFloat = 8 * hudScale
            let lineGap: CGFloat = 3 * hudScale
            let barH: CGFloat = 6 * hudScale
            let barGap: CGFloat = 5 * hudScale
            let contentW = max(max(tSz.width, oSz.width), 200 * hudScale)
            let boxW = contentW + pad * 2
            let boxH = tSz.height + oSz.height + barH + lineGap + barGap + pad * 2
            let margin: CGFloat = 16
            let box = NSRect(x: margin, y: b.maxY - margin - boxH, width: boxW, height: boxH)

            // Panel: same look as the status box (dark fill + subtle border).
            NSColor.black.withAlphaComponent(0.45).setFill()
            let rr = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            rr.fill()
            NSColor.white.withAlphaComponent(0.20).setStroke()
            rr.lineWidth = 1; rr.stroke()

            // Title, objective, then the progress bar — stacked top-to-bottom.
            var ly = box.maxY - pad - tSz.height
            (titleStr as NSString).draw(at: NSPoint(x: box.minX + pad, y: ly), withAttributes: titleAttrs)
            ly -= oSz.height + lineGap
            (obj as NSString).draw(at: NSPoint(x: box.minX + pad, y: ly), withAttributes: objAttrs)
            ly -= barGap + barH
            let barRect = NSRect(x: box.minX + pad, y: ly, width: contentW, height: barH)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2).fill()
            let p = CGFloat(max(0, min(1, hud.quest_progress)))
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY,
                                             width: barRect.width * p, height: barRect.height),
                         xRadius: barH / 2, yRadius: barH / 2).fill()
            questPanelBottom = box.minY
        }

        // --- #12: Coordinates + facing readout (top-left, always visible) ---
        // Sits under the quest panel when a quest is active so they don't
        // overlap; otherwise tucks into the top-left corner. Compact: a coord
        // line + a cardinal direction badge.
        do {
            let xi = Int(playerX.rounded())
            let yi = Int(playerY.rounded())
            let zi = Int(playerZ.rounded())
            let dir = cardinal(from: playerFacing)
            let coordStr = "X: \(xi)   Y: \(yi)   Z: \(zi)"
            let facingStr = "Facing: \(dir)"
            // Anchor just below the quest panel (its bottom edge), else top-left.
            let topY = (hud.active_quest_id != 0) ? (questPanelBottom - 8) : (b.maxY - 24)
            let coAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fs(13), weight: .semibold),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let cSz = (coordStr as NSString).size(withAttributes: coAttrs)
            let fSz = (facingStr as NSString).size(withAttributes: coAttrs)
            let pad: CGFloat = 6 * hudScale
            let boxW = max(cSz.width, fSz.width) + pad * 2
            let boxH = cSz.height + fSz.height + pad * 2 + 2
            let box = NSRect(x: 16, y: topY - boxH + cSz.height, width: boxW, height: boxH)
            NSColor.black.withAlphaComponent(0.40).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            (coordStr as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.maxY - cSz.height - pad),
                                        withAttributes: coAttrs)
            (facingStr as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad - 1),
                                         withAttributes: coAttrs)
        }

        // --- #28 / #29: Environment status box (top-right) ---
        // A single bordered panel replacing the old loose mode/weather/biome
        // labels. Lines: game mode (coloured), FPS, weather, the Grey indicator,
        // and the biome. The box is sized to the widest line and anchored to the
        // top-right with a margin so it never overlaps the top-left quest panel.
        drawStatusBox(in: b)

        // Always-visible hints (bottom-right) so kids discover the helpers:
        // the Guide companion (G) and the new quest log (#42, L). Stacked.
        let hintAttrsFor: (CGFloat) -> [NSAttributedString.Key: Any] = { size in [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .strokeColor: NSColor.black.withAlphaComponent(0.8), .strokeWidth: -3.0,
        ] }
        let ghAttrs = hintAttrsFor(fs(12))
        let guideHint = "❓ Stuck? Press G for the Guide"
        let questHint = "📜 Press L for the Quest Log"
        // #194: bottom-LEFT so they never sit under the corner minimap (#187).
        let qhSz = (questHint as NSString).size(withAttributes: ghAttrs)
        (questHint as NSString).draw(at: NSPoint(x: 14, y: 14), withAttributes: ghAttrs)
        (guideHint as NSString).draw(at: NSPoint(x: 14, y: 14 + qhSz.height + 4), withAttributes: ghAttrs)

        // --- #13: Multiplayer compass (only when other players are connected) ---
        drawPeerCompass(in: b)
        drawChatter(in: b)   // #202 villager speech bubbles

        // Achievement toast (top-center banner) when one was just unlocked.
        let toast = withUnsafeBytes(of: hud.achievement_toast) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !toast.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(20)),
                .foregroundColor: NSColor(red: 1.0, green: 0.86, blue: 0.30, alpha: 1),
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let sz = (toast as NSString).size(withAttributes: attrs)
            let pad: CGFloat = 16
            let bx = b.midX - sz.width/2 - pad, by = b.maxY - 96
            let bg = NSRect(x: bx, y: by - 6, width: sz.width + pad*2, height: sz.height + 12)
            NSColor(red: 0.10, green: 0.14, blue: 0.10, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 10, yRadius: 10).fill()
            NSColor(red: 1.0, green: 0.86, blue: 0.30, alpha: 0.8).setStroke()
            let bp = NSBezierPath(roundedRect: bg, xRadius: 10, yRadius: 10); bp.lineWidth = 2; bp.stroke()
            (toast as NSString).draw(at: NSPoint(x: b.midX - sz.width/2, y: by), withAttributes: attrs)
        }

        // #95 living-villages donation panel (only when standing near a village).
        drawVillagePanel(in: b)
    }

    // #95: a compact bottom-center panel showing the nearest village's tier, what the
    // next villager wants, and a progress bar. Hidden when no village is in range.
    private func drawVillagePanel(in b: NSRect) {
        guard let v = villageView, v.present != 0 else { return }
        // Read the requested item name (a C char[16]).
        let want = withUnsafeBytes(of: v.want) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let tierName: String
        switch v.tier {
        case 0: tierName = "Village"
        case 1: tierName = "Walled Village"
        case 2: tierName = "Town"
        default: tierName = "City"
        }
        // Headline + the build and light-ward hints.
        let title = "\(tierName)  ·  Tier \(v.tier)/3"
        let hint: String
        switch want {
        case "wood":  hint = "Bring the Woodcutter LOGS for the wall"
        case "stone": hint = "Bring the Stone Mason STONE to reinforce it"
        case "iron":  hint = "Bring the Blacksmith IRON for the gate + lamps"
        default:      hint = "City guards are ready — Grey assaults still come at night"
        }
        let ward = v.ward_active != 0
            ? "✦ Light ward shining — streets restored"
            : "Light ward: \(v.lights)/8 nearby torches"
        // Progress fraction: wood tier uses wall cells; later tiers use the resource count.
        let frac: CGFloat
        if v.tier <= 1 && v.wood_cells < v.wood_total {
            frac = v.wood_total > 0 ? CGFloat(v.wood_cells) / CGFloat(v.wood_total) : 0
        } else if v.progress_needed > 0 {
            frac = min(1, CGFloat(v.progress) / CGFloat(v.progress_needed))
        } else {
            frac = 1
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(15)),
            .foregroundColor: NSColor(red: 0.96, green: 0.90, blue: 0.66, alpha: 1),
            .strokeColor: NSColor.black, .strokeWidth: -2.5,
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fs(12)),
            .foregroundColor: NSColor(white: 0.92, alpha: 1),
            .strokeColor: NSColor.black, .strokeWidth: -2.0,
        ]
        let wardAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(12)),
            .foregroundColor: v.ward_active != 0
                ? NSColor(red: 1.0, green: 0.84, blue: 0.32, alpha: 1)
                : NSColor(red: 0.70, green: 0.76, blue: 0.88, alpha: 1),
            .strokeColor: NSColor.black, .strokeWidth: -2.0,
        ]
        let tSz = (title as NSString).size(withAttributes: titleAttrs)
        let hSz = (hint as NSString).size(withAttributes: hintAttrs)
        let wSz = (ward as NSString).size(withAttributes: wardAttrs)
        let pad: CGFloat = 14
        let barH: CGFloat = 8
        let w = max(max(tSz.width, hSz.width), wSz.width) + pad * 2
        let h = tSz.height + hSz.height + wSz.height + barH + 20
        let bx = b.midX - w / 2
        let by: CGFloat = 92   // sit just above the hotbar
        let box = NSRect(x: bx, y: by, width: w, height: h)
        NSColor(red: 0.08, green: 0.10, blue: 0.12, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        NSColor(red: 0.96, green: 0.86, blue: 0.40, alpha: 0.7).setStroke()
        let bp = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10); bp.lineWidth = 2; bp.stroke()
        var cy = box.maxY - tSz.height - 6
        (title as NSString).draw(at: NSPoint(x: box.midX - tSz.width/2, y: cy), withAttributes: titleAttrs)
        cy -= hSz.height + 2
        (hint as NSString).draw(at: NSPoint(x: box.midX - hSz.width/2, y: cy), withAttributes: hintAttrs)
        cy -= wSz.height + 1
        (ward as NSString).draw(at: NSPoint(x: box.midX - wSz.width/2, y: cy), withAttributes: wardAttrs)
        // Progress bar.
        let barRect = NSRect(x: box.minX + pad, y: box.minY + 8, width: box.width - pad*2, height: barH)
        NSColor(white: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4).fill()
        if frac > 0 {
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: max(2, barRect.width * frac), height: barH)
            NSColor(red: 0.42, green: 0.82, blue: 0.40, alpha: 1).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()
        }
    }

    // ===== #28 / #29: Environment status box ================================
    // A single tidy bordered panel in the top-right corner that gathers the
    // game mode, FPS, weather, the "In the Grey" indicator and the biome into
    // compact, aligned lines. Matches the other HUD panels (rounded rect,
    // semi-transparent dark fill, subtle border). Sized to the widest line and
    // anchored top-right with a margin, so it stays clear of the top-left quest
    // panel. The view is non-flipped: +x right, +y up.
    private func drawStatusBox(in b: NSRect) {
        // One status line = text + colour. Built top-to-bottom in reading order.
        struct StatusLine { let text: String; let color: NSColor; let bold: Bool }
        var lines: [StatusLine] = []

        // Game mode — keep the existing teal/orange colour cue.
        let creative = (hud.mode == BF_MODE_CREATIVE)
        lines.append(StatusLine(text: creative ? "CREATIVE" : "SURVIVAL",
                                color: creative ? .systemTeal : .systemOrange,
                                bold: true))

        // Day/Night indicator (#30) — sun/moon glyph + phase label + 24h clock.
        // Coloured warm for day, cool for night, so it reads at a glance.
        let (phaseLabel, phaseGlyph) = timePhase(timeOfDay)
        let hour = clockHour(timeOfDay)
        let clockStr = String(format: "%02d:00", hour)
        let isDay = (timeOfDay >= 0.25 && timeOfDay < 0.75)
        let timeColor = isDay ? NSColor(srgbRed: 1.0, green: 0.86, blue: 0.40, alpha: 1)
                              : NSColor(srgbRed: 0.66, green: 0.74, blue: 0.95, alpha: 1)
        lines.append(StatusLine(text: "\(phaseGlyph) \(phaseLabel)  \(clockStr)",
                                color: timeColor, bold: true))
        // Index of the time line within `lines`, so we can underlay a progress
        // bar at exactly its row after the box is laid out below.
        let timeLineIdx = lines.count - 1
        // Day/night pin (T key) indicator, so the player can see the pin is on.
        if timeMode != 0 {
            lines.append(StatusLine(text: timeMode == 1 ? "[ALWAYS DAY] (T)" : "[ALWAYS NIGHT] (T)",
                                    color: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.85, alpha: 1),
                                    bold: true))
        }

        // FPS (#29) — rounded smoothed value. Shows "—" until the first delta.
        let fpsText = smoothedFPS > 0 ? "\(Int(smoothedFPS.rounded())) FPS" : "— FPS"
        lines.append(StatusLine(text: fpsText,
                                color: NSColor.white.withAlphaComponent(0.9), bold: false))

        // Weather: 0=Clear, 1=Rain, 2=Snow, 3=Partly Cloudy, 4=Overcast (#162).
        let weather: (String, NSColor)
        switch hud.weather {
        case 1:  weather = ("Weather: Rain", NSColor(srgbRed: 0.62, green: 0.78, blue: 0.95, alpha: 1))
        case 2:  weather = ("Weather: Snow", NSColor(srgbRed: 0.92, green: 0.95, blue: 0.98, alpha: 1))
        case 3:  weather = ("Weather: Partly Cloudy", NSColor(srgbRed: 0.86, green: 0.89, blue: 0.94, alpha: 1))
        case 4:  weather = ("Weather: Overcast", NSColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 1))
        default: weather = ("Weather: Clear", NSColor.white.withAlphaComponent(0.85))
        }
        lines.append(StatusLine(text: weather.0, color: weather.1, bold: false))

        // "In the Grey" indicator (#28). Make the Grey state obvious (that's the
        // whole point); when restored, show a quiet rainbow line so the contrast
        // reads clearly for kids.
        if hud.in_dim != 0 {
            lines.append(StatusLine(text: "⬛ The Grey",
                                    color: NSColor(white: 0.62, alpha: 1.0), bold: true))
        } else {
            lines.append(StatusLine(text: "🌈 Restored",
                                    color: NSColor.white.withAlphaComponent(0.85), bold: false))
        }

        // Biome name (NUL-terminated char[] like the other char fields).
        let biome = withUnsafeBytes(of: hud.biome_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !biome.isEmpty {
            lines.append(StatusLine(text: biome,
                                    color: NSColor.white.withAlphaComponent(0.85), bold: false))
        }

        // Layout: measure every line, size the box to the widest, stack them
        // with consistent padding + line spacing.
        let fontSize: CGFloat = fs(13)
        let pad: CGFloat = 8 * hudScale    // inner padding
        let lineGap: CGFloat = 3 * hudScale // gap between lines
        let margin: CGFloat = 16           // distance from the top-right corner

        func attrs(_ l: StatusLine) -> [NSAttributedString.Key: Any] {
            [
                .font: l.bold ? NSFont.boldSystemFont(ofSize: fontSize)
                              : NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: l.color,
                .strokeColor: NSColor.black, .strokeWidth: -2.0,
            ]
        }

        var maxW: CGFloat = 0
        var lineH: CGFloat = 0
        for l in lines {
            let sz = (l.text as NSString).size(withAttributes: attrs(l))
            maxW = max(maxW, sz.width)
            lineH = max(lineH, sz.height)
        }
        let count = CGFloat(lines.count)
        let boxW = maxW + pad * 2
        let boxH = count * lineH + (count - 1) * lineGap + pad * 2

        let box = NSRect(x: b.maxX - boxW - margin, y: b.maxY - boxH - margin,
                         width: boxW, height: boxH)

        // Panel: semi-transparent dark fill + subtle border (matches HUD style).
        NSColor.black.withAlphaComponent(0.45).setFill()
        let rr = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        rr.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        rr.lineWidth = 1; rr.stroke()

        // Draw lines top-to-bottom inside the box.
        var ly = box.maxY - pad - lineH
        for (i, l) in lines.enumerated() {
            (l.text as NSString).draw(at: NSPoint(x: box.minX + pad, y: ly),
                                      withAttributes: attrs(l))
            // #30: draw a thin day/night progress bar tucked under the time line,
            // marking where we are in the 0..1 cycle (midnight → noon → midnight).
            if i == timeLineIdx {
                let barH: CGFloat = 3
                let barY = ly - 2                          // just under the text baseline
                let barRect = NSRect(x: box.minX + pad, y: barY,
                                     width: maxW, height: barH)
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
                let frac = CGFloat(max(0, min(1, timeOfDay)))
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY,
                                                 width: max(2, barRect.width * frac),
                                                 height: barH),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
            ly -= lineH + lineGap
        }
    }

    // ===== #13: Multiplayer compass =========================================
    // Draws an indicator for every other connected player (a "remote peer").
    // The Renderer has already done the camera/projection maths and handed us,
    // per peer: whether it is on-screen (with a screen point), an off-screen
    // arrow direction, the distance, and the peer's tint colour.
    //
    //   ON-SCREEN peer  : a small floating diamond marker + "Player" + "24m"
    //                     hovering just above the peer's projected screen point.
    //   OFF-SCREEN peer : a bright filled triangle ARROW pinned just inside the
    //                     screen edge, pointing toward the peer, with the
    //                     distance beside it — kid-obvious in the peer's colour.
    //
    // Cheap NSBezierPath / NSColor like the rest of the HUD. Nothing draws when
    // there are zero peers, when the HUD is hidden, or while an overlay is up.
    private func drawPeerCompass(in b: NSRect) {
        guard !peers.isEmpty else { return }

        for peer in peers {
            if peer.onScreen {
                drawOnScreenPeer(peer, in: b)
            } else {
                drawOffScreenPeerArrow(peer, in: b)
            }
        }
    }

    // A floating marker hovering at/above a peer that is visible on screen.
    private func drawOnScreenPeer(_ peer: PeerMarker, in b: NSRect) {
        // Clamp the projected point into the view so a marker right at the edge
        // is still fully drawn.
        let mPad: CGFloat = 22 * hudScale
        let px = min(max(b.minX + mPad, peer.screenPt.x), b.maxX - mPad)
        let py = min(max(b.minY + mPad, peer.screenPt.y), b.maxY - mPad)

        // Small diamond marker in the peer's colour, hovering above their head.
        let mR: CGFloat = 9 * hudScale
        let cy = py + 26 * hudScale            // float above the projected point
        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: px,      y: cy + mR))
        diamond.line(to: NSPoint(x: px + mR, y: cy))
        diamond.line(to: NSPoint(x: px,      y: cy - mR))
        diamond.line(to: NSPoint(x: px - mR, y: cy))
        diamond.close()
        peer.color.withAlphaComponent(0.95).setFill()
        diamond.fill()
        NSColor.black.withAlphaComponent(0.85).setStroke()
        diamond.lineWidth = 2 * hudScale
        diamond.stroke()
        // A little downward stem so it reads as a "pin" pointing at the player.
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: px, y: cy - mR))
        stem.line(to: NSPoint(x: px, y: cy - mR - 8 * hudScale))
        NSColor.black.withAlphaComponent(0.85).setStroke()
        stem.lineWidth = 2 * hudScale
        stem.stroke()

        // Label: "Player"/"Boss" + distance, centered above the marker.
        let label = "\(peer.label)  \(peer.distM)m"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(12)),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -3.0,
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: px - sz.width / 2, y: cy + mR + 4 * hudScale),
                                 withAttributes: attrs)
    }

    // A bright triangle arrow pinned near the screen edge, pointing toward a peer
    // who is off-screen or behind the camera.
    private func drawOffScreenPeerArrow(_ peer: PeerMarker, in b: NSRect) {
        // Normalize the supplied direction (Renderer keeps it stable for the
        // behind-camera case). Guard against a zero vector.
        var dx = peer.edgeDir.dx
        var dy = peer.edgeDir.dy
        let len = (dx * dx + dy * dy).squareRoot()
        if len < 1e-4 { dx = 0; dy = 1 } else { dx /= len; dy /= len }

        // Project a ray from the screen centre to the rectangle edge, then pull
        // the arrow inward by a margin so it sits fully on screen.
        let inset: CGFloat = 46 * hudScale
        let rect = b.insetBy(dx: inset, dy: inset)
        let cx = rect.midX, cy = rect.midY
        let hw = rect.width / 2, hh = rect.height / 2
        // Largest t such that (cx + dx*t, cy + dy*t) is still inside the rect.
        var t = CGFloat.greatestFiniteMagnitude
        if abs(dx) > 1e-4 { t = min(t, hw / abs(dx)) }
        if abs(dy) > 1e-4 { t = min(t, hh / abs(dy)) }
        if !t.isFinite { t = 0 }
        let ax = cx + dx * t
        let ay = cy + dy * t

        // Triangle arrow pointing along (dx, dy), centered at (ax, ay).
        let aLen: CGFloat = 20 * hudScale   // tip length
        let aWide: CGFloat = 13 * hudScale  // half-width of the base
        let tipX = ax + dx * aLen, tipY = ay + dy * aLen
        // Perpendicular for the base corners.
        let pxx = -dy, pyy = dx
        let baseX = ax - dx * (aLen * 0.4), baseY = ay - dy * (aLen * 0.4)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: tipX, y: tipY))
        arrow.line(to: NSPoint(x: baseX + pxx * aWide, y: baseY + pyy * aWide))
        arrow.line(to: NSPoint(x: baseX - pxx * aWide, y: baseY - pyy * aWide))
        arrow.close()
        peer.color.withAlphaComponent(0.95).setFill()
        arrow.fill()
        NSColor.black.withAlphaComponent(0.85).setStroke()
        arrow.lineWidth = 2 * hudScale
        arrow.stroke()

        // Label + distance, placed just inward of the arrow (toward the centre).
        let label = "\(peer.label)  \(peer.distM)m"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(12)),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black, .strokeWidth: -3.0,
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        let lx = ax - dx * (24 * hudScale) - sz.width / 2
        let ly = ay - dy * (24 * hudScale) - sz.height / 2
        (label as NSString).draw(at: NSPoint(x: lx, y: ly), withAttributes: attrs)
    }

    // ===== #42: Quest / progression log overlay =============================
    // A toggleable panel (L) listing the FULL quest chain so the player can see
    // their progress. Done quests show a green check and are dimmed; the active
    // quest is highlighted with its objective + a green progress bar (same look
    // as the top-left quest bar); upcoming quests look locked with their
    // objective shown as a faint hint. Scrollable for ~15 rows. Matches the
    // translucent-dark rounded-panel HUD aesthetic. Honours the HUD text scale.
    private func drawQuestLog(in b: NSRect) {
        // Dim the world behind the overlay so the list reads clearly.
        NSColor.black.withAlphaComponent(0.55).setFill()
        b.fill()

        // Outer panel, centered, sized as a comfortable fraction of the window.
        let panelW = min(b.width - 80, 560 * hudScale)
        let panelH = min(b.height - 100, 620 * hudScale)
        let panel = NSRect(x: b.midX - panelW / 2, y: b.midY - panelH / 2,
                           width: panelW, height: panelH)
        NSColor.black.withAlphaComponent(0.55).setFill()
        let pp = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12); pp.fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        pp.lineWidth = 1.5; pp.stroke()

        let pad: CGFloat = 16 * hudScale

        // Title strip.
        let titleH = fs(24)
        drawText("📜 Quest Log", at: NSPoint(x: panel.minX + pad, y: panel.maxY - pad - titleH),
                 size: fs(22), color: .systemYellow, bold: true)
        drawText("Press L or Esc to close", at: NSPoint(x: panel.minX + pad, y: panel.maxY - pad - titleH - fs(16)),
                 size: fs(12), color: NSColor.white.withAlphaComponent(0.7), bold: false)

        // Empty-state message if the engine hasn't reported any quests yet.
        if quests.isEmpty {
            drawText("No quests yet — start exploring!",
                     at: NSPoint(x: panel.minX + pad, y: panel.midY),
                     size: fs(14), color: NSColor.white.withAlphaComponent(0.8), bold: false)
            questLogViewport = .zero; maxQuestLogScroll = 0
            return
        }

        // Scrollable rows region below the header.
        let viewTop = panel.maxY - pad - titleH - fs(16) - 12 * hudScale
        let viewBottom = panel.minY + pad
        let viewport = NSRect(x: panel.minX + pad, y: viewBottom,
                              width: panelW - pad * 2, height: max(40, viewTop - viewBottom))
        questLogViewport = viewport

        let rowH: CGFloat = 64 * hudScale
        let rowGap: CGFloat = 8 * hudScale
        let n = quests.count
        let contentH = CGFloat(n) * (rowH + rowGap) - rowGap
        maxQuestLogScroll = max(0, contentH - viewport.height)
        questLogScroll = min(max(0, questLogScroll), maxQuestLogScroll)

        clipped(to: [NSPoint(x: viewport.minX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.maxY),
                     NSPoint(x: viewport.minX, y: viewport.maxY)]) {
            for (i, q) in quests.enumerated() {
                // Row 0 at the top of the viewport; scroll moves rows up.
                let ry = viewport.maxY - rowH - CGFloat(i) * (rowH + rowGap) + questLogScroll
                let rowRect = NSRect(x: viewport.minX, y: ry, width: viewport.width, height: rowH)
                if rowRect.maxY < viewport.minY || rowRect.minY > viewport.maxY { continue }
                drawQuestRow(rowRect, quest: q)
            }
        }

        if maxQuestLogScroll > 0 {
            drawScrollbar(in: viewport, contentH: contentH, scroll: questLogScroll)
        }
    }

    // One quest row: state-styled. DONE = green check + dimmed; ACTIVE =
    // highlighted with objective + progress bar; UPCOMING = locked/dimmed hint.
    private func drawQuestRow(_ rowRect: NSRect, quest q: QuestRow) {
        let active = (q.state == UInt8(BF_QUEST_ACTIVE.rawValue))
        let done   = (q.state == UInt8(BF_QUEST_DONE.rawValue))
        let pad: CGFloat = 10 * hudScale

        // Row background — the active quest is highlighted; others are subtle.
        (active ? NSColor.systemGreen.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.45)).setFill()
        let rr = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6); rr.fill()
        (active ? NSColor.systemGreen.withAlphaComponent(0.80)
                : NSColor.white.withAlphaComponent(0.18)).setStroke()
        rr.lineWidth = active ? 2 : 1; rr.stroke()

        // Leading status glyph.
        let glyph = done ? "✅" : (active ? "⭐️" : "🔒")
        let glyphAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fs(20))]
        let gSz = (glyph as NSString).size(withAttributes: glyphAttrs)
        (glyph as NSString).draw(at: NSPoint(x: rowRect.minX + pad, y: rowRect.maxY - pad - gSz.height),
                                 withAttributes: glyphAttrs)

        let textX = rowRect.minX + pad + gSz.width + 8 * hudScale
        let textW = rowRect.maxX - pad - textX

        // Title — dimmed for done/upcoming, bright for active.
        let titleColor: NSColor = active ? .systemYellow
            : (done ? NSColor.systemGreen.withAlphaComponent(0.85)
                    : NSColor.white.withAlphaComponent(0.45))
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(15)), .foregroundColor: titleColor,
        ]
        let title = truncated(q.title, to: textW, attrs: titleAttrs)
        let tSz = (title as NSString).size(withAttributes: titleAttrs)
        (title as NSString).draw(at: NSPoint(x: textX, y: rowRect.maxY - pad - tSz.height),
                                 withAttributes: titleAttrs)

        // Objective line — shown for active (its current goal) and upcoming (as a
        // faint hint). Done quests skip it to read as "completed".
        if !done {
            let objColor = active ? NSColor.white.withAlphaComponent(0.9)
                                  : NSColor.white.withAlphaComponent(0.40)
            let objAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fs(12)), .foregroundColor: objColor,
            ]
            let obj = truncated(q.objective, to: textW, attrs: objAttrs)
            (obj as NSString).draw(at: NSPoint(x: textX, y: rowRect.maxY - pad - tSz.height - fs(12) - 4 * hudScale),
                                   withAttributes: objAttrs)
        }

        // Progress bar for the active quest — same green-bar look as the
        // top-left quest panel.
        if active {
            let barH: CGFloat = 6 * hudScale
            let barRect = NSRect(x: textX, y: rowRect.minY + pad, width: textW, height: barH)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2).fill()
            let p = CGFloat(max(0, min(1, q.progress)))
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY,
                                             width: barRect.width * p, height: barRect.height),
                         xRadius: barH / 2, yRadius: barH / 2).fill()
        }
    }

    // Inventory grid geometry — single source of truth for both drawing and
    // hit-testing. Returns 36 rects indexed by inventory slot (0..8 hotbar row,
    // 9..35 main grid), matching the bf_hud_state.inventory layout we draw.
    private func inventorySlotRects(in b: NSRect) -> [NSRect] {
        let slot: CGFloat = 46, gap: CGFloat = 5
        let cols = 9
        let gridW = CGFloat(cols) * slot + CGFloat(cols - 1) * gap
        let originX = b.midX - gridW / 2

        // Pre-size so we can assign by index regardless of fill order.
        var rects = [NSRect](repeating: .zero, count: 36)
        // Main inventory: slots 9..35 in 3 rows of 9, above the hotbar row.
        var topY = b.midY + 120
        for row in 0..<3 {
            var x = originX
            for col in 0..<cols {
                let i = 9 + row * 9 + col
                rects[i] = NSRect(x: x, y: topY, width: slot, height: slot)
                x += slot + gap
            }
            topY -= slot + gap
        }
        // Hotbar row (slots 0..8) a little below the main grid.
        let hy = topY - 12
        var hx = originX
        for col in 0..<9 {
            rects[col] = NSRect(x: hx, y: hy, width: slot, height: slot)
            hx += slot + gap
        }
        return rects
    }

    // #109 chest screen: the chest's slots on top, the player inventory below, with
    // single-click to move (chest slot -> inventory, inventory slot -> chest). Reuses
    // the inventory's slot cell + item rendering so it matches the existing HUD style.
    // Kid-simple: one row of chest slots, a clear "Treasure Chest" header, and a hint.
    private func drawChestPanel(in b: NSRect) {
        NSColor.black.withAlphaComponent(0.60).setFill()
        b.fill()

        let slot: CGFloat = 46, gap: CGFloat = 5
        let cols = 9
        let gridW = CGFloat(cols) * slot + CGFloat(cols - 1) * gap
        let originX = b.midX - gridW / 2

        // Shared cell renderer (same look as the inventory). `hot` highlights the
        // selected hotbar slot so the player can still see their active slot.
        func cell(_ rect: NSRect, _ s: bf_hud_slot, sel: Bool) {
            (sel ? NSColor.white : NSColor.black.withAlphaComponent(0.5)).setFill()
            let rr = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            rr.fill()
            (sel ? NSColor.white : NSColor.systemYellow.withAlphaComponent(0.5)).setStroke()
            rr.lineWidth = sel ? 2.5 : 1
            rr.stroke()
            if s.item != 0 { drawCenteredItem(id: s.item, count: s.count, in: rect, selected: sel) }
        }

        // --- Chest row (the container) sits in the upper third. ---
        let chestN = Int(BF_CHEST_SLOTS)
        let chestRowW = CGFloat(chestN) * slot + CGFloat(chestN - 1) * gap
        let chestX = b.midX - chestRowW / 2
        let chestY = b.midY + 150

        // A framed panel behind the chest row so it reads as "the chest".
        let chestPanel = NSRect(x: chestX - 14, y: chestY - 16,
                                width: chestRowW + 28, height: slot + 56)
        NSColor(srgbRed: 0.30, green: 0.20, blue: 0.10, alpha: 0.55).setFill()
        let cpp = NSBezierPath(roundedRect: chestPanel, xRadius: 10, yRadius: 10); cpp.fill()
        NSColor.systemYellow.withAlphaComponent(0.6).setStroke()
        cpp.lineWidth = 2; cpp.stroke()

        drawText("Loot Barrel", at: NSPoint(x: chestX, y: chestY + slot + 16),
                 size: fs(20), color: .systemYellow, bold: true)

        var crects = [NSRect]()
        for i in 0..<chestN {
            let r = NSRect(x: chestX + CGFloat(i) * (slot + gap), y: chestY, width: slot, height: slot)
            crects.append(r)
            let s = i < chestSlots.count ? chestSlots[i] : bf_hud_slot()
            cell(r, s, sel: false)
        }
        chestSlotRects = crects

        // --- Player inventory below (hotbar + 3 main rows). ---
        let invTopY = b.midY + 40
        var irects = [NSRect](repeating: .zero, count: 36)
        // Main inventory 9..35 (3 rows of 9).
        var topY = invTopY
        for row in 0..<3 {
            for col in 0..<cols {
                let i = 9 + row * 9 + col
                irects[i] = NSRect(x: originX + CGFloat(col) * (slot + gap), y: topY, width: slot, height: slot)
            }
            topY -= slot + gap
        }
        // Hotbar row 0..8 a little below the main grid.
        let hy = topY - 12
        for col in 0..<9 {
            irects[col] = NSRect(x: originX + CGFloat(col) * (slot + gap), y: hy, width: slot, height: slot)
        }
        chestInvRects = irects

        drawText("Your Backpack", at: NSPoint(x: originX, y: invTopY + slot + 8),
                 size: fs(18), color: .white, bold: true)

        withUnsafeBytes(of: hud.inventory) { raw in
            let inv = raw.bindMemory(to: bf_hud_slot.self)
            for i in 9..<36 { cell(irects[i], inv[i], sel: false) }
            for col in 0..<9 { cell(irects[col], inv[col], sel: Int(hud.selected_slot) == col) }
        }

        // Hints at the bottom.
        drawText("Click a barrel item to take it   •   click a backpack item to store it",
                 at: NSPoint(x: originX, y: hy - 30), size: fs(13), color: .white, bold: true)
        drawText("Press Esc to close",
                 at: NSPoint(x: originX, y: 18), size: fs(12), color: .white, bold: false)

        // Hover tooltip (which item is under the cursor).
        if mouseInside {
            if let i = chestSlotRects.firstIndex(where: { $0.contains(mousePos) }),
               i < chestSlots.count, chestSlots[i].item != 0 {
                drawTooltip(name: itemName(chestSlots[i].item), count: chestSlots[i].count,
                            itemId: chestSlots[i].item, hint: "click to take", near: mousePos)
            } else if let i = chestInvRects.firstIndex(where: { $0.contains(mousePos) }) {
                let s = inventorySlot(i)
                if s.item != 0 {
                    drawTooltip(name: itemName(s.item), count: s.count, itemId: s.item,
                                hint: "click to store", near: mousePos)
                }
            }
        }
    }

    // Inventory screen: 27 main slots (3x9) + the 9-slot hotbar row, with a
    // 2x2 crafting grid + result preview at the top. Populated from
    // bf_hud_state.inventory (engine fills it when open).
    private func drawInventory(in b: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        b.fill()
        let slot: CGFloat = 46, gap: CGFloat = 5
        let cols = 9
        let gridW = CGFloat(cols) * slot + CGFloat(cols - 1) * gap
        let originX = b.midX - gridW / 2

        // Record geometry so mouseDown/mouseMoved can hit-test against it.
        let rects = inventorySlotRects(in: b)
        slotRects = rects

        func cell(_ rect: NSRect, _ s: bf_hud_slot, sel: Bool, picked: Bool) {
            (sel ? NSColor.white : NSColor.black.withAlphaComponent(0.5)).setFill()
            let rr = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            rr.fill()
            (picked ? NSColor.systemYellow : NSColor.white.withAlphaComponent(sel ? 1 : 0.4)).setStroke()
            rr.lineWidth = (picked || sel) ? 2.5 : 1
            rr.stroke()
            // The picked-up slot is drawn empty (its stack rides the cursor).
            if s.item != 0 && !picked {
                drawCenteredItem(id: s.item, count: s.count, in: rect, selected: sel)
            }
        }

        // Title sits just above the top inventory row (rects[9] is the top-left
        // main slot). Keeps the header anchored to the grid at any window size.
        let invTop = rects[9].maxY
        drawText("Inventory", at: NSPoint(x: originX, y: invTop + 14), size: fs(20), color: .white, bold: true)

        withUnsafeBytes(of: hud.inventory) { raw in
            let inv = raw.bindMemory(to: bf_hud_slot.self)
            // Main inventory: slots 9..35.
            for i in 9..<36 {
                cell(rects[i], inv[i], sel: false, picked: heldSlot == i)
            }
            // Hotbar row (slots 0..8), highlighting the selection.
            for col in 0..<9 {
                cell(rects[col], inv[col], sel: Int(hud.selected_slot) == col,
                     picked: heldSlot == col)
            }
        }

        // --- #34: Trash slot — drop a picked-up stack here to delete it. Sits
        // just to the right of the hotbar row so it reads as part of the
        // inventory area. Red box + 🗑 glyph; it lights up while a stack is held
        // so kids see exactly where to drop. Record its rect for hit-testing.
        let hotRow = rects[0]                            // hotbar's first slot
        let trash = NSRect(x: rects[8].maxX + 18, y: hotRow.minY,
                           width: hotRow.width, height: hotRow.height)
        trashRect = trash
        let holding = (heldSlot != nil)
        let trashHover = mouseInside && holding && trash.contains(mousePos)
        (trashHover ? NSColor.systemRed.withAlphaComponent(0.55)
                    : NSColor.systemRed.withAlphaComponent(holding ? 0.32 : 0.18)).setFill()
        let trr = NSBezierPath(roundedRect: trash, xRadius: 6, yRadius: 6); trr.fill()
        NSColor.systemRed.withAlphaComponent(holding ? 0.95 : 0.55).setStroke()
        trr.lineWidth = trashHover ? 3 : (holding ? 2 : 1.5); trr.stroke()
        let trashGlyph = "🗑"
        let tgAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
        ]
        let tgSz = (trashGlyph as NSString).size(withAttributes: tgAttrs)
        (trashGlyph as NSString).draw(at: NSPoint(x: trash.midX - tgSz.width / 2,
                                                  y: trash.midY - tgSz.height / 2),
                                      withAttributes: tgAttrs)
        drawText("Trash", at: NSPoint(x: trash.minX, y: trash.minY - 15),
                 size: fs(11), color: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.55, alpha: 1),
                 bold: true)

        // --- #16: Craftable recipes — a SINGLE-column scrollable list BELOW the
        // hotbar. Rows are clipped to a fixed viewport; the mouse wheel scrolls
        // when there are more rows than fit. Each row is a clickable strip:
        // icon + name + "×N", with a number-key badge on recipes 1–9. ---
        let n = Int(hud.craftable_count)
        let hotbarBottom = rects[0].minY
        let bandGap: CGFloat = 20           // gap between hotbar and craft band
        let craftTitleH: CGFloat = 20       // title strip height
        let rowH: CGFloat = 36              // height of each recipe row
        let rowGap: CGFloat = 3             // vertical gap between rows
        let panelPad: CGFloat = 6           // inner padding of the rows viewport

        // Width: leave room on the right for the creative picker panel when it
        // is shown so the two don't overlap. The picker lives on the right edge.
        let pickerActive = (hud.mode == BF_MODE_CREATIVE)
        let craftRightLimit = pickerActive ? (kPickerPanelX(in: b) - 16) : b.maxX
        let craftLeft = originX - 10
        let craftWidth = min(gridW + 20, craftRightLimit - craftLeft)
        let colW = craftWidth - panelPad * 2 - 12   // row width inside viewport (reserve scrollbar)

        // The band spans from just under the hotbar down to a bottom margin.
        let bandBottom: CGFloat = 44        // keep clear of the bottom hint line
        let bandTop = hotbarBottom - bandGap
        let titleY = bandTop - craftTitleH + 2

        // Viewport (the clipped scroll area) sits below the title.
        let viewTop = titleY - 6
        let viewBottom = bandBottom + 4
        let viewH = max(rowH, viewTop - viewBottom)
        let viewport = NSRect(x: craftLeft, y: viewBottom, width: craftWidth, height: viewH)
        craftViewport = viewport

        // Panel background (title + viewport).
        let panel = NSRect(x: craftLeft, y: viewBottom - 2,
                           width: craftWidth, height: (titleY + craftTitleH) - (viewBottom - 2))
        NSColor.black.withAlphaComponent(0.38).setFill()
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8)
        panelPath.fill()
        NSColor.systemYellow.withAlphaComponent(0.35).setStroke()
        panelPath.lineWidth = 1; panelPath.stroke()

        // Title strip.
        drawText(n == 0 ? "Nothing craftable yet — gather wood and stone!"
                        : "Crafting  (click a row to craft  •  1–9 = number key)",
                 at: NSPoint(x: originX, y: titleY), size: fs(12), color: .systemYellow, bold: true)

        // Total content height & scroll clamp. Top row sits at the top of the
        // viewport; subsequent rows below it. scroll moves the content UP.
        let contentH = CGFloat(n) * (rowH + rowGap) - (n > 0 ? rowGap : 0)
        maxCraftScroll = max(0, contentH - viewH)
        craftScroll = min(max(0, craftScroll), maxCraftScroll)

        // Draw visible rows clipped to the viewport. Rebuild craftRects +
        // craftRowIndex each frame so hit-testing matches exactly what we paint.
        var crafts = [NSRect]()
        var craftIdx = [Int]()
        clipped(to: [NSPoint(x: viewport.minX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.maxY),
                     NSPoint(x: viewport.minX, y: viewport.maxY)]) {
            withUnsafeBytes(of: hud.craftable) { raw in
                let cr = raw.bindMemory(to: bf_hud_slot.self)
                let rx = viewport.minX + panelPad
                for i in 0..<n {
                    // Row i's top within content; map to view coords (non-flipped:
                    // +y up). Row 0 top aligns with viewport top + craftScroll.
                    let ry = viewport.maxY - rowH - CGFloat(i) * (rowH + rowGap) + craftScroll
                    let rowRect = NSRect(x: rx, y: ry, width: colW, height: rowH)
                    // Skip rows fully outside the viewport (cheap cull).
                    if rowRect.maxY < viewport.minY || rowRect.minY > viewport.maxY { continue }
                    crafts.append(rowRect); craftIdx.append(i)
                    let s = cr[i]
                    let hovered = mouseInside && heldSlot == nil
                        && rowRect.contains(mousePos) && viewport.contains(mousePos)
                    drawCraftRow(rowRect, slot: s, recipeIndex: i, colW: colW, hovered: hovered)
                }
            }
        }
        craftRects = crafts
        craftRowIndex = craftIdx

        // Scrollbar indicator on the right edge of the viewport.
        if maxCraftScroll > 0 {
            drawScrollbar(in: viewport, contentH: contentH, scroll: craftScroll)
        }

        // #15: Creative item picker panel (right side), scrollable. Only built in
        // creative mode; sets pickerRects/pickerItemIds (empty otherwise).
        if pickerActive {
            drawCreativePicker(in: b)
        } else {
            pickerRects = []; pickerItemIds = []
            pickerViewport = .zero; maxPickerScroll = 0
        }

        // Bottom hint — sits at the very bottom of the screen.
        drawText("Esc / E to close   •   click a stack to pick it up, click a slot to place it",
                 at: NSPoint(x: originX, y: 18), size: fs(12), color: .white, bold: false)

        // --- Hover tooltips (only when not carrying a stack, so the tooltip
        //     doesn't fight the ghost). A craftable row under the cursor takes
        //     priority and shows what the recipe makes + its number key. ---
        if mouseInside && heldSlot == nil {
            if let pid = pickerItemId(at: mousePos) {
                drawTooltip(name: itemName(pid), count: 1, itemId: pid,
                            hint: "click to get", near: mousePos)
            } else if let c = craftIndex(at: mousePos) {
                let s = craftableSlot(c)
                if s.item != 0 {
                    let keyHint = c < 9 ? "press \(c + 1)" : nil
                    drawTooltip(name: itemName(s.item), count: s.count, itemId: s.item,
                                hint: keyHint, near: mousePos)
                }
            } else if let i = slotIndex(at: mousePos) {
                let s = inventorySlot(i)
                if s.item != 0 {
                    drawTooltip(name: itemName(s.item), count: s.count, itemId: s.item, near: mousePos)
                }
            }
        }

        // --- #34: Trash hint. Shown whenever the cursor is over the trash slot,
        //     even while carrying a stack (that's exactly when it's actionable).
        if mouseInside && trashRect.contains(mousePos) {
            let hint = (heldSlot != nil) ? "🗑 Drop here to delete"
                                         : "🗑 Pick up a stack, then drop it here to delete"
            drawTooltip(name: hint, count: 1, near: mousePos)
        }

        // --- Picked-up stack ghost following the cursor. ---
        if heldSlot != nil && heldItem != 0 {
            let g = NSRect(x: mousePos.x - 18, y: mousePos.y - 18, width: 36, height: 36)
            drawCenteredItem(id: heldItem, count: heldCount, in: g, selected: false)
        }
    }

    private func inventorySlot(_ i: Int) -> bf_hud_slot {
        guard i >= 0 && i < 36 else { return bf_hud_slot() }
        return withUnsafeBytes(of: hud.inventory) { raw in
            raw.bindMemory(to: bf_hud_slot.self)[i]
        }
    }

    private func slotIndex(at p: NSPoint) -> Int? {
        for (i, r) in slotRects.enumerated() where r.contains(p) { return i }
        return nil
    }

    // Read a craftable recipe's result slot (item + count). Bounds-checked
    // against the live craftable_count so a stale rect can never read past the
    // valid recipes. Array is now 24 entries (ABI v8).
    private func craftableSlot(_ i: Int) -> bf_hud_slot {
        guard i >= 0 && i < Int(hud.craftable_count) && i < 24 else { return bf_hud_slot() }
        return withUnsafeBytes(of: hud.craftable) { raw in
            raw.bindMemory(to: bf_hud_slot.self)[i]
        }
    }

    // Craftable recipe index under a point, hit-tested against craftRects (which
    // is rebuilt every draw to mirror exactly what we painted). craftRects holds
    // only the visible (scrolled) rows, so we map the matched rect position back
    // to its true recipe index via craftRowIndex. Clicks outside the scroll
    // viewport are rejected so a row peeking past the clip can't be clicked.
    private func craftIndex(at p: NSPoint) -> Int? {
        guard craftViewport.contains(p) else { return nil }
        for (k, r) in craftRects.enumerated() where r.contains(p) {
            return k < craftRowIndex.count ? craftRowIndex[k] : nil
        }
        return nil
    }

    // ===== #16 helpers: craft row + scrollbar ==============================

    // Draw a single craft recipe row strip. Pulled out of drawInventory so the
    // scrolled list and any future layout reuse the same visuals.
    private func drawCraftRow(_ rowRect: NSRect, slot s: bf_hud_slot,
                              recipeIndex i: Int, colW: CGFloat, hovered: Bool) {
        let rx = rowRect.minX, ry = rowRect.minY, rowH = rowRect.height
        (hovered ? NSColor.systemYellow.withAlphaComponent(0.22)
                 : NSColor.black.withAlphaComponent(0.45)).setFill()
        let rr = NSBezierPath(roundedRect: rowRect, xRadius: 5, yRadius: 5); rr.fill()
        NSColor.systemYellow.withAlphaComponent(hovered ? 0.90 : 0.40).setStroke()
        rr.lineWidth = hovered ? 2 : 1; rr.stroke()

        // Icon on the left.
        let iconSize: CGFloat = rowH - 6
        let iconRect = NSRect(x: rx + 4, y: ry + (rowH - iconSize) / 2,
                              width: iconSize, height: iconSize)
        if s.item != 0 {
            drawCenteredItem(id: s.item, count: s.count, in: iconRect, selected: false)
        }
        // Number-key badge (1–9) on first 9 rows.
        if i < 9 {
            let badge = NSRect(x: rx + 2, y: ry + rowH - 15, width: 14, height: 14)
            NSColor.black.withAlphaComponent(0.70).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            drawText("\(i + 1)", at: NSPoint(x: rx + 4, y: ry + rowH - 15),
                     size: 11, color: .systemYellow, bold: true)
        }
        // Name + count to the right of the icon.
        if s.item != 0 {
            let textX = rx + iconSize + 8
            let textW = colW - iconSize - 12
            let nameStr = itemName(s.item)
            let countStr = "×\(s.count)"
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fs(12)), .foregroundColor: NSColor.white,
            ]
            let cntAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fs(11)),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            ]
            let nameSz = (nameStr as NSString).size(withAttributes: nameAttrs)
            let cntSz  = (countStr as NSString).size(withAttributes: cntAttrs)
            let totalTextH = nameSz.height + cntSz.height + 1
            let textY = ry + (rowH - totalTextH) / 2
            let displayName = truncated(nameStr, to: textW, attrs: nameAttrs)
            (displayName as NSString).draw(at: NSPoint(x: textX, y: textY + cntSz.height + 1),
                                           withAttributes: nameAttrs)
            (countStr as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: cntAttrs)
        }
    }

    // Truncate a string with an ellipsis so it fits maxW at the given attrs.
    private func truncated(_ s: String, to maxW: CGFloat,
                           attrs: [NSAttributedString.Key: Any]) -> String {
        if (s as NSString).size(withAttributes: attrs).width <= maxW { return s }
        var t = s
        while !t.isEmpty &&
              ((t + "…") as NSString).size(withAttributes: attrs).width > maxW {
            t = String(t.dropLast())
        }
        return t + "…"
    }

    // Subtle scrollbar on the right edge of a viewport. contentH is the full
    // (unclipped) content height; scroll is the current offset in [0, max].
    private func drawScrollbar(in viewport: NSRect, contentH: CGFloat, scroll: CGFloat) {
        guard contentH > viewport.height else { return }
        let trackW: CGFloat = 4
        let track = NSRect(x: viewport.maxX - trackW - 2, y: viewport.minY + 2,
                           width: trackW, height: viewport.height - 4)
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let frac = viewport.height / contentH                 // visible fraction
        let thumbH = max(16, track.height * frac)
        let maxScroll = max(1, contentH - viewport.height)
        // scroll=0 → thumb at top (non-flipped: top = high y).
        let t = scroll / maxScroll
        let thumbY = track.maxY - thumbH - t * (track.height - thumbH)
        let thumb = NSRect(x: track.minX, y: thumbY, width: trackW, height: thumbH)
        NSColor.systemYellow.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
    }

    // ===== #15 helpers: creative item picker ==============================

    // Left edge X of the creative picker panel for a given view bounds. Used both
    // to draw it and to keep the craft list from overlapping it.
    private func kPickerPanelX(in b: NSRect) -> CGFloat {
        let panelW: CGFloat = 196
        return b.maxX - panelW - 14
    }

    // Draw the "Creative Items" panel: a scrollable grid of every known item.
    // Clicking an icon calls onGiveItem. Rebuilds pickerRects/pickerItemIds each
    // frame so hit-testing matches the scrolled layout exactly.
    private func drawCreativePicker(in b: NSRect) {
        let panelW: CGFloat = 196
        let panelX = b.maxX - panelW - 14
        let titleH: CGFloat = 22
        let panelTop = b.maxY - 100        // below the mode/weather/biome badges
        let panelBottom: CGFloat = 44
        let panel = NSRect(x: panelX, y: panelBottom, width: panelW,
                           height: panelTop - panelBottom)

        NSColor.black.withAlphaComponent(0.55).setFill()
        let pp = NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10); pp.fill()
        NSColor.systemTeal.withAlphaComponent(0.55).setStroke()
        pp.lineWidth = 1.5; pp.stroke()

        drawText("Creative Items", at: NSPoint(x: panel.minX + 12, y: panel.maxY - titleH),
                 size: fs(14), color: .systemTeal, bold: true)
        drawText("click to get one", at: NSPoint(x: panel.minX + 12, y: panel.maxY - titleH - 15),
                 size: fs(10), color: NSColor.white.withAlphaComponent(0.7), bold: false)

        // Grid geometry inside the panel.
        let pad: CGFloat = 10
        let cell: CGFloat = 40, cgap: CGFloat = 6
        let cols = Swift.max(1, Int((panelW - pad * 2 + cgap) / (cell + cgap)))
        let viewTop = panel.maxY - titleH - 24
        let viewBottom = panel.minY + 8
        let viewport = NSRect(x: panel.minX + pad, y: viewBottom,
                              width: panelW - pad * 2, height: Swift.max(cell, viewTop - viewBottom))
        pickerViewport = viewport

        let ids = HUDView.kAllItemIds
        let rows = Int(ceil(Double(ids.count) / Double(cols)))
        let contentH = CGFloat(rows) * (cell + cgap) - (rows > 0 ? cgap : 0)
        maxPickerScroll = Swift.max(0, contentH - viewport.height)
        pickerScroll = Swift.min(Swift.max(0, pickerScroll), maxPickerScroll)

        var rects = [NSRect](); var outIds = [UInt16]()
        clipped(to: [NSPoint(x: viewport.minX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.minY),
                     NSPoint(x: viewport.maxX, y: viewport.maxY),
                     NSPoint(x: viewport.minX, y: viewport.maxY)]) {
            for (k, id) in ids.enumerated() {
                let row = k / cols, col = k % cols
                let cx = viewport.minX + CGFloat(col) * (cell + cgap)
                // Row 0 at top of viewport (non-flipped: +y up), scroll moves up.
                let cy = viewport.maxY - cell - CGFloat(row) * (cell + cgap) + pickerScroll
                let cr = NSRect(x: cx, y: cy, width: cell, height: cell)
                if cr.maxY < viewport.minY || cr.minY > viewport.maxY { continue }
                rects.append(cr); outIds.append(id)
                let hovered = mouseInside && heldSlot == nil
                    && cr.contains(mousePos) && viewport.contains(mousePos)
                (hovered ? NSColor.systemTeal.withAlphaComponent(0.30)
                         : NSColor.black.withAlphaComponent(0.45)).setFill()
                let bp = NSBezierPath(roundedRect: cr, xRadius: 5, yRadius: 5); bp.fill()
                NSColor.systemTeal.withAlphaComponent(hovered ? 0.9 : 0.35).setStroke()
                bp.lineWidth = hovered ? 2 : 1; bp.stroke()
                drawCenteredItem(id: id, count: 1, in: cr, selected: false)
            }
        }
        pickerRects = rects
        pickerItemIds = outIds

        if maxPickerScroll > 0 {
            drawScrollbar(in: viewport, contentH: contentH, scroll: pickerScroll)
        }
    }

    // Item id of the picker cell under a point, or nil. Rejects points outside
    // the scroll viewport so a partially-clipped cell can't be clicked.
    private func pickerItemId(at p: NSPoint) -> UInt16? {
        guard pickerViewport.contains(p) else { return nil }
        for (k, r) in pickerRects.enumerated() where r.contains(p) {
            return k < pickerItemIds.count ? pickerItemIds[k] : nil
        }
        return nil
    }

    private func drawTooltip(name: String, count: UInt16, itemId: UInt16 = 0,
                             hint: String? = nil, near p: NSPoint) {
        // Title line: "Wooden Pickaxe ×1  (press 3)". Count always shown for
        // craftable recipes (via hint) but only when >1 for inventory items.
        var titleLine = count > 1 ? "\(name)  ×\(count)" : name
        if let h = hint {
            titleLine = "\(name) ×\(count)  (\(h))"
        }
        // Description line — always shown; looks up the item-specific blurb.
        let desc = itemId != 0 ? itemDescription(id: itemId) : ""

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fs(13)), .foregroundColor: NSColor.white,
        ]
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fs(11)),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]

        // Maximum tooltip width so long descriptions wrap neatly.
        let maxW: CGFloat = 260 * hudScale
        let pad: CGFloat = 7
        let titleSz = (titleLine as NSString).size(withAttributes: titleAttrs)

        // Wrap description: split into lines that fit maxW.
        var descLines: [String] = []
        if !desc.isEmpty {
            // Simple word-wrap: build lines word by word.
            var current = ""
            for word in desc.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let test = current.isEmpty ? word : current + " " + word
                let w = (test as NSString).size(withAttributes: descAttrs).width
                if w > maxW - pad * 2 && !current.isEmpty {
                    descLines.append(current)
                    current = word
                } else {
                    current = test
                }
            }
            if !current.isEmpty { descLines.append(current) }
        }

        let lineH: CGFloat = 14 * hudScale
        let totalH = titleSz.height + (descLines.isEmpty ? 0 : CGFloat(descLines.count) * lineH + 4) + pad
        let boxW = min(maxW, max(titleSz.width + pad * 2,
                                 descLines.map { ($0 as NSString).size(withAttributes: descAttrs).width }.max().map { $0 + pad * 2 } ?? 0))

        var box = NSRect(x: p.x + 14, y: p.y + 14, width: boxW, height: totalH)
        // Keep the tooltip on-screen (view isn't flipped: +x right, +y up).
        if box.maxX > bounds.maxX { box.origin.x = p.x - box.width - 6 }
        if box.maxY > bounds.maxY { box.origin.y = p.y - box.height - 6 }
        if box.minX < bounds.minX { box.origin.x = bounds.minX + 4 }
        if box.minY < bounds.minY { box.origin.y = bounds.minY + 4 }

        NSColor.black.withAlphaComponent(0.88).setFill()
        let rr = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5); rr.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke(); rr.lineWidth = 1; rr.stroke()

        // Title at the top of the box.
        let titleY = box.maxY - titleSz.height - pad * 0.5
        (titleLine as NSString).draw(at: NSPoint(x: box.minX + pad, y: titleY), withAttributes: titleAttrs)

        // Description lines below the title.
        if !descLines.isEmpty {
            var dy = titleY - 4
            for line in descLines {
                dy -= lineH
                (line as NSString).draw(at: NSPoint(x: box.minX + pad, y: dy), withAttributes: descAttrs)
            }
        }
    }

}
