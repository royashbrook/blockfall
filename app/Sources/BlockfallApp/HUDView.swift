// ============================================================================
// Blockfall — HUDView (Phase 0 / M0)
// A lightweight AppKit overlay that renders the engine's HUD snapshot: hotbar,
// health, and the active quest. Deliberately simple (Core Graphics, no Metal
// text) so M0 proves the HUD-state handoff end to end. Track E may later move
// this into the Metal layer; the data contract (bf_hud_state) stays the same.
// ============================================================================
import AppKit
import CBlockcore

// Item id -> (display name, chip colour). Mirrors content/items so the HUD can
// label and colour items without an ABI change. Keep in sync with content.
private struct ItemInfo { let name: String; let color: NSColor }
private func itemColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
private let kItemTable: [UInt16: ItemInfo] = [
    1:  .init(name: "Dirt",          color: itemColor(0.55, 0.40, 0.26)),
    2:  .init(name: "Grass Block",   color: itemColor(0.40, 0.68, 0.32)),
    3:  .init(name: "Stone",         color: itemColor(0.55, 0.55, 0.57)),
    4:  .init(name: "Cobblestone",   color: itemColor(0.48, 0.48, 0.50)),
    5:  .init(name: "Sand",          color: itemColor(0.85, 0.78, 0.55)),
    6:  .init(name: "Gravel",        color: itemColor(0.52, 0.50, 0.48)),
    7:  .init(name: "Snow",          color: itemColor(0.92, 0.95, 0.98)),
    8:  .init(name: "Ice",           color: itemColor(0.68, 0.82, 0.95)),
    9:  .init(name: "Clay",          color: itemColor(0.62, 0.64, 0.68)),
    10: .init(name: "Dim Stone",     color: itemColor(0.30, 0.30, 0.36)),
    11: .init(name: "Dim Dirt",      color: itemColor(0.30, 0.26, 0.24)),
    12: .init(name: "Oak Log",       color: itemColor(0.52, 0.37, 0.20)),
    13: .init(name: "Oak Planks",    color: itemColor(0.74, 0.57, 0.34)),
    14: .init(name: "Birch Log",     color: itemColor(0.80, 0.74, 0.58)),
    15: .init(name: "Birch Planks",  color: itemColor(0.85, 0.78, 0.62)),
    16: .init(name: "Stone Brick",   color: itemColor(0.55, 0.55, 0.57)),
    17: .init(name: "Clay Brick",    color: itemColor(0.78, 0.45, 0.34)),
    18: .init(name: "Glass Pane",    color: itemColor(0.74, 0.86, 0.92)),
    19: .init(name: "Colored Glass", color: itemColor(0.40, 0.72, 0.85)),
    20: .init(name: "Wool",          color: itemColor(0.92, 0.92, 0.92)),
    21: .init(name: "Mossy Stone",   color: itemColor(0.42, 0.52, 0.36)),
    22: .init(name: "Crafting Table",color: itemColor(0.60, 0.42, 0.24)),
    23: .init(name: "Chest",         color: itemColor(0.62, 0.45, 0.24)),
    24: .init(name: "Torch",         color: itemColor(0.95, 0.72, 0.30)),
    25: .init(name: "Oak Door",      color: itemColor(0.56, 0.40, 0.22)),
    26: .init(name: "Beacon",        color: itemColor(0.40, 0.85, 0.90)),
    27: .init(name: "Glow Block",    color: itemColor(1.00, 0.90, 0.45)),
    28: .init(name: "Crystal Lamp",  color: itemColor(0.85, 0.55, 0.95)),
    29: .init(name: "Red Flower",    color: itemColor(0.88, 0.25, 0.25)),
    30: .init(name: "Yellow Flower", color: itemColor(0.95, 0.85, 0.25)),
    31: .init(name: "Color Crystal", color: itemColor(0.80, 0.45, 0.95)),
    50: .init(name: "Stick",         color: itemColor(0.60, 0.44, 0.26)),
    51: .init(name: "Coal",          color: itemColor(0.18, 0.18, 0.20)),
    52: .init(name: "Raw Copper",    color: itemColor(0.80, 0.50, 0.32)),
    53: .init(name: "Raw Iron",      color: itemColor(0.78, 0.70, 0.62)),
    54: .init(name: "Raw Crystal",   color: itemColor(0.55, 0.80, 0.90)),
    55: .init(name: "Copper Ingot",  color: itemColor(0.85, 0.55, 0.38)),
    56: .init(name: "Iron Ingot",    color: itemColor(0.82, 0.82, 0.85)),
    57: .init(name: "Crystal Shard", color: itemColor(0.60, 0.85, 0.95)),
    58: .init(name: "Clay Lump",     color: itemColor(0.62, 0.64, 0.68)),
    59: .init(name: "String",        color: itemColor(0.92, 0.92, 0.88)),
    60: .init(name: "Feather",       color: itemColor(0.95, 0.95, 0.95)),
    61: .init(name: "Color Dust",    color: itemColor(0.80, 0.45, 0.95)),
    62: .init(name: "Glow Dust",     color: itemColor(1.00, 0.92, 0.50)),
    63: .init(name: "Blank Book",    color: itemColor(0.80, 0.72, 0.55)),
    70: .init(name: "Wood Pickaxe",  color: itemColor(0.60, 0.44, 0.26)),
    71: .init(name: "Wood Axe",      color: itemColor(0.60, 0.44, 0.26)),
    72: .init(name: "Wood Shovel",   color: itemColor(0.60, 0.44, 0.26)),
    73: .init(name: "Stone Pickaxe", color: itemColor(0.55, 0.55, 0.57)),
    74: .init(name: "Stone Axe",     color: itemColor(0.55, 0.55, 0.57)),
    75: .init(name: "Stone Shovel",  color: itemColor(0.55, 0.55, 0.57)),
    76: .init(name: "Iron Pickaxe",  color: itemColor(0.82, 0.82, 0.85)),
    77: .init(name: "Iron Axe",      color: itemColor(0.82, 0.82, 0.85)),
    78: .init(name: "Iron Shovel",   color: itemColor(0.82, 0.82, 0.85)),
    90: .init(name: "Berries",       color: itemColor(0.80, 0.20, 0.35)),
    91: .init(name: "Mushroom Stew", color: itemColor(0.70, 0.50, 0.34)),
    92: .init(name: "Honey Cake",    color: itemColor(0.92, 0.70, 0.28)),
    93: .init(name: "Mushroom",      color: itemColor(0.78, 0.36, 0.32)),
]
private func itemName(_ id: UInt16) -> String { kItemTable[id]?.name ?? "Item \(id)" }
private func itemChipColor(_ id: UInt16) -> NSColor { kItemTable[id]?.color ?? NSColor(hue: CGFloat(id % 12)/12, saturation: 0.6, brightness: 0.9, alpha: 1) }

final class HUDView: NSView {
    private var hud = bf_hud_state()
    private var crosshair = true

    // --- Interactive inventory state ---
    // Closure the lead wires to BF_ACT_INV_MOVE (arg_i=from, arg_j=to, arg_k=count).
    var onMove: ((_ from: Int, _ to: Int, _ count: Int) -> Void)?
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

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    // Click-through during play; capture clicks only when the inventory is open.
    override func hitTest(_ point: NSPoint) -> NSView? {
        hud.inventory_open != 0 ? self : nil
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
        // Repaint only when the inventory is open (tooltip / held-stack ghost);
        // during play the in-world HUD doesn't track the mouse.
        if hud.inventory_open != 0 { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard hud.inventory_open != 0 else { return }   // gameplay: ignore
        let p = convert(event.locationInWindow, from: nil)
        mousePos = p
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

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        // Detect death+respawn (health was a small positive, then jumps back to
        // full). prevHealth must be > 0.5 so a startup/zero-frame health (0) can
        // NEVER look like a death — that was firing a false "you died" on spawn.
        if hud.mode == BF_MODE_SURVIVAL {
            if prevHealth > 0.5 && prevHealth < 6 && hud.health >= prevHealth + 8 {
                deathFlashUntil = Date().timeIntervalSinceReferenceDate + 2.0
            }
            prevHealth = hud.health
        }

        // When the inventory is open it replaces the in-world HUD.
        if hud.inventory_open != 0 { drawInventory(in: b); return }

        // --- Death banner (fades over 2s) ---
        let now = Date().timeIntervalSinceReferenceDate
        if now < deathFlashUntil {
            let a = CGFloat((deathFlashUntil - now) / 2.0)   // 1 -> 0
            NSColor.systemRed.withAlphaComponent(0.35 * a).setFill()
            b.fill()
            let msg = "Oh no! You ran out of hearts!"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 34),
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
                .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let sz = (lookName as NSString).size(withAttributes: attrs)
            (lookName as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY - 28),
                                        withAttributes: attrs)
        }

        // --- Hotbar (9 slots, centered along the bottom) ---
        let slot: CGFloat = 48, gap: CGFloat = 6
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
                .font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black, .strokeWidth: -3.0,
            ]
            let sz = (heldName as NSString).size(withAttributes: attrs)
            (heldName as NSString).draw(at: NSPoint(x: b.midX - sz.width / 2, y: y + slot + 8), withAttributes: attrs)
        }

        // --- Health hearts (survival) ---
        if hud.mode == BF_MODE_SURVIVAL {
            let heartsY = y + slot + 34
            drawHearts(value: hud.health, max: 20, at: NSPoint(x: b.midX - total / 2, y: heartsY))
            // Oxygen bubbles above the hearts, only while underwater (not full).
            if hud.oxygen < 0.999 {
                drawBubbles(value: hud.oxygen, at: NSPoint(x: b.midX - total / 2, y: heartsY + 18))
            }
        }

        // --- Active quest (top-left) ---
        if hud.active_quest_id != 0 {
            let title = withUnsafeBytes(of: hud.quest_title) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let obj = withUnsafeBytes(of: hud.quest_objective) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            drawText("★ " + title, at: NSPoint(x: 20, y: b.maxY - 36), size: 16, color: .systemYellow, bold: true)
            drawText(obj, at: NSPoint(x: 20, y: b.maxY - 58), size: 13, color: .white, bold: false)
            // progress bar
            let barRect = NSRect(x: 20, y: b.maxY - 70, width: 200, height: 6)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()
            let p = CGFloat(max(0, min(1, hud.quest_progress)))
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: NSRect(x: barRect.minX, y: barRect.minY,
                                             width: barRect.width * p, height: barRect.height),
                         xRadius: 3, yRadius: 3).fill()
        }

        // Mode badge (top-right)
        let modeStr = (hud.mode == BF_MODE_CREATIVE) ? "CREATIVE" : "SURVIVAL"
        drawText(modeStr, at: NSPoint(x: b.maxX - 110, y: b.maxY - 32), size: 13,
                 color: (hud.mode == BF_MODE_CREATIVE) ? .systemTeal : .systemOrange, bold: true)

        // Always-visible Guide hint (bottom-right) so kids discover the helper.
        let guideHint = "❓ Stuck? Press G for the Guide"
        let ghAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .strokeColor: NSColor.black.withAlphaComponent(0.8), .strokeWidth: -3.0,
        ]
        let ghSz = (guideHint as NSString).size(withAttributes: ghAttrs)
        (guideHint as NSString).draw(at: NSPoint(x: b.maxX - ghSz.width - 14, y: 14), withAttributes: ghAttrs)

        // Weather line (under the mode badge). Tells the player what the
        // on-screen precipitation overlay represents. 0=clear, 1=rain, 2=snow.
        switch hud.weather {
        case 1:
            drawText("Rain", at: NSPoint(x: b.maxX - 110, y: b.maxY - 50), size: 12,
                     color: NSColor(srgbRed: 0.62, green: 0.78, blue: 0.95, alpha: 1), bold: false)
        case 2:
            drawText("Snow", at: NSPoint(x: b.maxX - 110, y: b.maxY - 50), size: 12,
                     color: NSColor(srgbRed: 0.92, green: 0.95, blue: 0.98, alpha: 1), bold: false)
        default:
            break   // clear: no label (unobtrusive)
        }

        // Biome name under the mode/weather badges.
        let biome = withUnsafeBytes(of: hud.biome_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !biome.isEmpty {
            drawText(biome, at: NSPoint(x: b.maxX - 110, y: b.maxY - 68), size: 12,
                     color: NSColor.white.withAlphaComponent(0.85), bold: false)
        }

        // Achievement toast (top-center banner) when one was just unlocked.
        let toast = withUnsafeBytes(of: hud.achievement_toast) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !toast.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 20),
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
        drawText("Inventory", at: NSPoint(x: originX, y: invTop + 14), size: 20, color: .white, bold: true)

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

        // --- Craftable recipes: a clearly separated band BELOW the hotbar row.
        // The hotbar row is the lowest inventory rect (rects[0..8]); start the
        // craft band a generous gap under it so the two never overlap, and draw
        // a backing panel so the band reads as its own region (not floating over
        // the hotbar). Layout is derived from the grid geometry, so it stays
        // non-overlapping at any window size. ---
        let n = Int(hud.craftable_count)
        let hotbarBottom = rects[0].minY
        let bandGap: CGFloat = 26          // clear space between hotbar and band
        let titleH: CGFloat = 22           // room for the band title above slots
        let cy = hotbarBottom - bandGap - slot          // craft slot row origin-y
        let craftTitleY = cy + slot + 4                 // title baseline above row

        // Backing panel for the whole craft band (title + slots), inset to the
        // grid width so it doesn't run off-screen.
        let panel = NSRect(x: originX - 10,
                           y: cy - 8,
                           width: gridW + 20,
                           height: slot + titleH + 12)
        NSColor.black.withAlphaComponent(0.35).setFill()
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8)
        panelPath.fill()
        NSColor.systemYellow.withAlphaComponent(0.35).setStroke()
        panelPath.lineWidth = 1; panelPath.stroke()

        drawText("Craft  (press the number key shown)",
                 at: NSPoint(x: originX, y: craftTitleY), size: 14, color: .systemYellow, bold: true)
        if n == 0 {
            drawText("Gather wood and stone, then come back!",
                     at: NSPoint(x: originX, y: cy + (slot - 16) / 2),
                     size: 12, color: NSColor.white.withAlphaComponent(0.7), bold: false)
        }

        // Rebuild the parallel craftable rect array each frame (mirrors the
        // slotRects pattern) so hover hit-testing matches exactly what we draw.
        var crafts = [NSRect]()
        withUnsafeBytes(of: hud.craftable) { raw in
            let cr = raw.bindMemory(to: bf_hud_slot.self)
            var cx = originX
            for i in 0..<min(n, 8) {
                let rect = NSRect(x: cx, y: cy, width: slot, height: slot)
                crafts.append(rect)
                let hovered = mouseInside && heldSlot == nil && rect.contains(mousePos)
                NSColor.black.withAlphaComponent(0.5).setFill()
                let rr = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5); rr.fill()
                NSColor.systemYellow.withAlphaComponent(hovered ? 1.0 : 0.7).setStroke()
                rr.lineWidth = hovered ? 2.5 : 1.5; rr.stroke()
                if cr[i].item != 0 {
                    drawCenteredItem(id: cr[i].item, count: cr[i].count, in: rect, selected: false)
                    // (name shown via hover tooltip — inline labels overlapped)
                }
                // Number-key hint, top-left corner, away from the count badge
                // (which sits bottom-right). Small dark chip keeps it readable
                // over any item icon.
                let badge = NSRect(x: cx + 2, y: cy + slot - 16, width: 14, height: 14)
                NSColor.black.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
                drawText("\(i+1)", at: NSPoint(x: cx + 4, y: cy + slot - 16), size: 12, color: .systemYellow, bold: true)
                cx += slot + gap
            }
        }
        craftRects = crafts

        drawText("Esc / E to close   •   click a stack to pick it up, click a slot to place it",
                 at: NSPoint(x: originX, y: panel.minY - 22), size: 12, color: .white, bold: false)

        // --- Hover tooltips (only when not carrying a stack, so the tooltip
        //     doesn't fight the ghost). A craftable slot under the cursor takes
        //     priority and shows what the recipe makes + its number key. ---
        if mouseInside && heldSlot == nil {
            if let c = craftIndex(at: mousePos) {
                let s = craftableSlot(c)
                if s.item != 0 {
                    drawTooltip(name: itemName(s.item), count: s.count,
                                hint: "press \(c + 1)", near: mousePos)
                }
            } else if let i = slotIndex(at: mousePos) {
                let s = inventorySlot(i)
                if s.item != 0 { drawTooltip(name: itemName(s.item), count: s.count, near: mousePos) }
            }
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
    // valid recipes.
    private func craftableSlot(_ i: Int) -> bf_hud_slot {
        guard i >= 0 && i < Int(hud.craftable_count) && i < 8 else { return bf_hud_slot() }
        return withUnsafeBytes(of: hud.craftable) { raw in
            raw.bindMemory(to: bf_hud_slot.self)[i]
        }
    }

    // Craftable recipe index under a point, hit-tested against craftRects (which
    // is rebuilt every draw to mirror exactly what we painted).
    private func craftIndex(at p: NSPoint) -> Int? {
        for (i, r) in craftRects.enumerated() where r.contains(p) { return i }
        return nil
    }

    private func drawTooltip(name: String, count: UInt16, hint: String? = nil, near p: NSPoint) {
        // e.g. "Wooden Pickaxe ×1  (press 3)". Count is always shown for
        // craftable recipes (via hint) but only when >1 for inventory items.
        var label = count > 1 ? "\(name)  ×\(count)" : name
        if let h = hint {
            // Recipes: always surface the result count + the number key.
            label = "\(name) ×\(count)  (\(h))"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white,
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        var box = NSRect(x: p.x + 14, y: p.y + 14, width: sz.width + pad * 2, height: sz.height + pad)
        // Keep the tooltip on-screen (view isn't flipped: +x right, +y up).
        if box.maxX > bounds.maxX { box.origin.x = p.x - box.width - 6 }
        if box.maxY > bounds.maxY { box.origin.y = p.y - box.height - 6 }
        NSColor.black.withAlphaComponent(0.85).setFill()
        let rr = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4); rr.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke(); rr.lineWidth = 1; rr.stroke()
        (label as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }

    private func shade(_ c: NSColor, _ f: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return NSColor(srgbRed: min(1, s.redComponent * f), green: min(1, s.greenComponent * f),
                       blue: min(1, s.blueComponent * f), alpha: 1)
    }
    private func fillPoly(_ pts: [NSPoint], _ color: NSColor) {
        let p = NSBezierPath(); p.move(to: pts[0])
        for q in pts.dropFirst() { p.line(to: q) }
        p.close(); color.setFill(); p.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke(); p.lineWidth = 0.5; p.stroke()
    }
    private func drawCenteredItem(id: bf_item_id, count: UInt16, in rect: NSRect, selected: Bool) {
        let base = itemChipColor(id)
        let chip = rect.insetBy(dx: 8, dy: 8)
        if id <= 40 {
            // Block item → little isometric cube icon with a procedural texture
            // pattern on each visible face, so the material reads at a glance
            // (grass, stone, wood …) instead of three flat shaded diamonds.
            drawTexturedCube(id: id, in: chip, base: base)
        } else {
            // Tool / material / food → distinct procedural icon per item, so
            // each is recognizable at a glance (no more uniform chips).
            drawItemIcon(id: id, in: chip, base: base)
        }
        if count > 1 {
            drawText("\(count)", at: NSPoint(x: rect.maxX - 18, y: rect.minY + 3),
                     size: 12, color: .white, bold: true)
        }
    }

    // ===== Textured block cube icons =======================================
    // A small isometric cube (top diamond + left + right faces) with a cheap
    // procedural texture drawn ON each face so the material is recognizable —
    // no block icon is ever a plain flat-coloured diamond. Texture ops are
    // clipped to the exact face polygon via NSBezierPath.addClip inside a
    // save/restore pair, so nothing bleeds outside the cube. Non-flipped: +y UP.

    // Which texture "family" a block id belongs to. Keeps the dispatcher tidy.
    private enum BlockTex {
        case grass, grain, stone, sand, log, planks, leaves, snow, ice
        case bricks, table, chest, glow, plain
    }
    private func blockTexFamily(_ id: bf_item_id) -> BlockTex {
        switch id {
        case 2:              return .grass
        case 1, 6, 9, 11:    return .grain          // dirt / gravel / clay / dim dirt
        case 3, 4, 16, 10, 21: return .stone        // stone / cobble / brick / dim / mossy
        case 5:              return .sand
        case 12, 14:         return .log            // oak / birch log
        case 13, 15:         return .planks         // oak / birch planks
        case 7:              return .snow
        case 8:              return .ice
        case 17:             return .bricks         // clay brick
        case 22:             return .table          // crafting table
        case 23:             return .chest
        case 26, 27, 28, 31: return .glow           // beacon / glow / crystal lamp / crystal
        default:             return .grain          // everything else gets some grain
        }
    }

    // Run `body` with the drawing context clipped to the given polygon. Uses an
    // explicit save/restore so the clip is always balanced (no force-unwrap;
    // NSGraphicsContext.current is optional and we no-op if absent).
    private func clipped(to pts: [NSPoint], _ body: () -> Void) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        let clip = NSBezierPath()
        clip.move(to: pts[0])
        for q in pts.dropFirst() { clip.line(to: q) }
        clip.close()
        clip.addClip()
        body()
        ctx.restoreGraphicsState()
    }

    // A short line segment helper used by several textures.
    private func tick(_ a: NSPoint, _ b: NSPoint, _ color: NSColor, width: CGFloat) {
        let p = NSBezierPath(); p.lineCapStyle = .round
        p.move(to: a); p.line(to: b)
        color.setStroke(); p.lineWidth = width; p.stroke()
    }

    private func drawTexturedCube(id: bf_item_id, in chip: NSRect, base: NSColor) {
        let cx = chip.midX, cy = chip.midY
        let hw = chip.width * 0.46, qh = chip.height * 0.24, bd = chip.height * 0.34
        let topApex   = NSPoint(x: cx,      y: cy + bd*0.5 + qh)
        let rightApex = NSPoint(x: cx + hw, y: cy + bd*0.5)
        let leftApex  = NSPoint(x: cx - hw, y: cy + bd*0.5)
        let ctrTop    = NSPoint(x: cx,      y: cy + bd*0.5 - qh)
        let botLeft   = NSPoint(x: cx - hw, y: cy - bd*0.5)
        let botRight  = NSPoint(x: cx + hw, y: cy - bd*0.5)
        let botCtr    = NSPoint(x: cx,      y: cy - bd*0.5 - qh)

        let leftFace  = [leftApex, ctrTop, botCtr, botLeft]
        let rightFace = [ctrTop, rightApex, botRight, botCtr]
        let topFace   = [topApex, rightApex, ctrTop, leftApex]

        // Base shaded faces (same shading as before; texture draws on top).
        let fam = blockTexFamily(id)
        // Grass uses a dirt-brown body for the sides and a green top.
        let sideBase = (fam == .grass) ? itemColor(0.50, 0.36, 0.23) : base
        fillPoly(leftFace,  shade(sideBase, 0.74))
        fillPoly(rightFace, shade(sideBase, 0.56))
        fillPoly(topFace,   shade(base, 1.15))

        // Texture each face, clipped to its polygon, with the face's own shade so
        // the pattern reads as lit consistently with the underlying fill.
        clipped(to: topFace)   { texture(fam, face: topFace,   shaded: shade(base, 1.15), kind: .top) }
        clipped(to: leftFace)  { texture(fam, face: leftFace,  shaded: shade(sideBase, 0.74), kind: .left) }
        clipped(to: rightFace) { texture(fam, face: rightFace, shaded: shade(sideBase, 0.56), kind: .right) }
    }

    private enum FaceKind { case top, left, right }

    // Bounding box of a face polygon (used to size/iterate texture features).
    private func bbox(_ pts: [NSPoint]) -> NSRect {
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts.dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // Per-family texture painter. `shaded` is the face's base colour; derive
    // lighter/darker speckle colours from it so every face stays self-consistent.
    private func texture(_ fam: BlockTex, face: [NSPoint],
                         shaded: NSColor, kind: FaceKind) {
        let r = bbox(face)
        let dark = shade(shaded, 0.78)
        let light = lighten(shaded, 0.30)
        switch fam {
        case .grass:
            if kind == .top {
                // Green top speckled with short upright blade ticks.
                for o in [CGPoint(x: 0.30, y: 0.45), CGPoint(x: 0.50, y: 0.62),
                          CGPoint(x: 0.62, y: 0.40), CGPoint(x: 0.42, y: 0.30),
                          CGPoint(x: 0.55, y: 0.50), CGPoint(x: 0.38, y: 0.58)] {
                    let p = NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y)
                    tick(p, NSPoint(x: p.x, y: p.y + r.height * 0.10),
                         lighten(shaded, 0.45), width: 1)
                }
            } else {
                // Brown dirt side with a green fringe band along the top edge.
                // The outer per-face clip already constrains this to the face.
                let fringeH = r.height * 0.22
                itemColor(0.40, 0.62, 0.30).setFill()
                NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - fringeH,
                                          width: r.width, height: fringeH)).fill()
                speckle(in: r, count: 5, color: dark, size: r.width * 0.05)
            }
        case .grain:
            speckle(in: r, count: 7, color: dark, size: r.width * 0.05)
            speckle(in: r, count: 4, color: light, size: r.width * 0.04)
        case .stone:
            // Grey mottling + a few darker crack/cell lines (underground look).
            speckle(in: r, count: 6, color: dark, size: r.width * 0.06)
            speckle(in: r, count: 3, color: light, size: r.width * 0.04)
            let cracks: [(CGPoint, CGPoint)] = [
                (CGPoint(x: 0.20, y: 0.30), CGPoint(x: 0.45, y: 0.55)),
                (CGPoint(x: 0.55, y: 0.65), CGPoint(x: 0.78, y: 0.45)),
                (CGPoint(x: 0.40, y: 0.70), CGPoint(x: 0.50, y: 0.40)),
            ]
            for (a, bpt) in cracks {
                tick(NSPoint(x: r.minX + r.width * a.x, y: r.minY + r.height * a.y),
                     NSPoint(x: r.minX + r.width * bpt.x, y: r.minY + r.height * bpt.y),
                     shade(shaded, 0.62), width: 1)
            }
        case .sand:
            // Fine horizontal ripple lines.
            let n = 4
            for i in 1...n {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(n + 1)
                tick(NSPoint(x: r.minX + r.width * 0.10, y: y),
                     NSPoint(x: r.maxX - r.width * 0.10, y: y),
                     dark.withAlphaComponent(0.7), width: 0.8)
            }
        case .log:
            if kind == .top {
                // Concentric rings on the cut end.
                let c = NSPoint(x: r.midX, y: r.midY)
                for f in [0.62, 0.40, 0.20] {
                    let rad = r.width * 0.5 * CGFloat(f)
                    let rect = NSRect(x: c.x - rad, y: c.y - rad * 0.6,
                                      width: rad * 2, height: rad * 1.2)
                    let p = NSBezierPath(ovalIn: rect)
                    dark.setStroke(); p.lineWidth = 1; p.stroke()
                }
            } else {
                // Vertical grain lines along the bark side.
                for fx in [0.30, 0.50, 0.70] {
                    let x = r.minX + r.width * CGFloat(fx)
                    tick(NSPoint(x: x, y: r.minY + r.height * 0.08),
                         NSPoint(x: x, y: r.maxY - r.height * 0.08),
                         dark, width: 1)
                }
            }
        case .planks:
            // Plank seam lines: horizontal boards on the top, with end nicks.
            let n = 3
            for i in 1...n {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(n + 1)
                tick(NSPoint(x: r.minX + r.width * 0.08, y: y),
                     NSPoint(x: r.maxX - r.width * 0.08, y: y),
                     dark, width: 1)
            }
        case .leaves:
            for o in [CGPoint(x: 0.30, y: 0.40), CGPoint(x: 0.55, y: 0.55),
                      CGPoint(x: 0.45, y: 0.30), CGPoint(x: 0.65, y: 0.42)] {
                fillCircle(NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y),
                           r.width * 0.08, light, outline: nil)
            }
            speckle(in: r, count: 4, color: dark, size: r.width * 0.05)
        case .snow:
            // White with a few sparkle dots.
            speckle(in: r, count: 4, color: .white, size: r.width * 0.05)
            for o in [CGPoint(x: 0.35, y: 0.55), CGPoint(x: 0.60, y: 0.40)] {
                drawSparkle(at: NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y),
                            s: r.width * 0.07, color: .white)
            }
        case .ice:
            // Pale blue with thin crack-like facet lines.
            let cracks: [(CGPoint, CGPoint)] = [
                (CGPoint(x: 0.25, y: 0.30), CGPoint(x: 0.55, y: 0.65)),
                (CGPoint(x: 0.50, y: 0.35), CGPoint(x: 0.75, y: 0.55)),
            ]
            for (a, bpt) in cracks {
                tick(NSPoint(x: r.minX + r.width * a.x, y: r.minY + r.height * a.y),
                     NSPoint(x: r.minX + r.width * bpt.x, y: r.minY + r.height * bpt.y),
                     lighten(shaded, 0.55), width: 0.8)
            }
        case .bricks:
            // Offset brick courses: horizontal mortar lines + staggered verticals.
            let rows = 3
            for i in 1...rows {
                let y = r.minY + r.height * CGFloat(i) / CGFloat(rows + 1)
                tick(NSPoint(x: r.minX, y: y), NSPoint(x: r.maxX, y: y), dark, width: 0.9)
            }
            for i in 0..<rows {
                let y0 = r.minY + r.height * CGFloat(i) / CGFloat(rows + 1)
                let y1 = r.minY + r.height * CGFloat(i + 1) / CGFloat(rows + 1)
                let xoff: CGFloat = (i % 2 == 0) ? 0.34 : 0.66
                let x = r.minX + r.width * xoff
                tick(NSPoint(x: x, y: y0), NSPoint(x: x, y: y1), dark, width: 0.9)
            }
        case .table:
            if kind == .top {
                // Grid lines on the top (a 2x2 work surface).
                tick(NSPoint(x: r.midX, y: r.minY + r.height * 0.10),
                     NSPoint(x: r.midX, y: r.maxY - r.height * 0.10), dark, width: 1)
                tick(NSPoint(x: r.minX + r.width * 0.12, y: r.midY),
                     NSPoint(x: r.maxX - r.width * 0.12, y: r.midY), dark, width: 1)
            } else {
                for fx in [0.40, 0.60] {
                    let x = r.minX + r.width * CGFloat(fx)
                    tick(NSPoint(x: x, y: r.minY + r.height * 0.10),
                         NSPoint(x: x, y: r.maxY - r.height * 0.10), dark, width: 1)
                }
            }
        case .chest:
            if kind == .top {
                speckle(in: r, count: 3, color: dark, size: r.width * 0.05)
            } else {
                // Lid seam across the upper third + a small latch in the centre.
                let seamY = r.minY + r.height * 0.62
                tick(NSPoint(x: r.minX, y: seamY), NSPoint(x: r.maxX, y: seamY), dark, width: 1.2)
                let latch = NSRect(x: r.midX - r.width * 0.07, y: seamY - r.height * 0.10,
                                   width: r.width * 0.14, height: r.height * 0.18)
                shade(shaded, 0.55).setFill(); NSBezierPath(rect: latch).fill()
            }
        case .glow:
            // Bright with a sparkle/facet motif (lamp / crystal / beacon / glow).
            fillCircle(NSPoint(x: r.midX, y: r.midY), r.width * 0.16,
                       lighten(shaded, 0.6).withAlphaComponent(0.7), outline: nil)
            drawSparkle(at: NSPoint(x: r.midX, y: r.midY), s: r.width * 0.16, color: .white)
            for o in [CGPoint(x: 0.30, y: 0.40), CGPoint(x: 0.65, y: 0.55)] {
                drawSparkle(at: NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y),
                            s: r.width * 0.07, color: .white)
            }
        case .plain:
            speckle(in: r, count: 5, color: dark, size: r.width * 0.05)
        }
    }

    // Deterministic speckle: a fixed scatter of small dots inside a rect. Cheap
    // and stable frame-to-frame (no RNG), readable at ~40px.
    private func speckle(in r: NSRect, count: Int, color: NSColor, size: CGFloat) {
        // A fixed low-discrepancy-ish set of offsets in [0,1]^2.
        let pts: [CGPoint] = [
            CGPoint(x: 0.22, y: 0.34), CGPoint(x: 0.58, y: 0.24), CGPoint(x: 0.40, y: 0.52),
            CGPoint(x: 0.70, y: 0.46), CGPoint(x: 0.30, y: 0.66), CGPoint(x: 0.62, y: 0.64),
            CGPoint(x: 0.48, y: 0.38), CGPoint(x: 0.35, y: 0.45), CGPoint(x: 0.55, y: 0.58),
        ]
        for i in 0..<Swift.min(count, pts.count) {
            let o = pts[i]
            fillCircle(NSPoint(x: r.minX + r.width * o.x, y: r.minY + r.height * o.y),
                       size, color, outline: nil)
        }
    }

    // ===== Procedural item icons ============================================
    // Each item id (50..93) maps to a small recognizable silhouette drawn with
    // Core Graphics / NSBezierPath — no art assets. Helpers stay cheap (a few
    // bezier ops) because these draw several times per frame. The view is
    // non-flipped, so +y is UP throughout.

    // Tier tints for the 9 tools (head colour by material; handle is wood).
    private static let kWoodTint  = NSColor(srgbRed: 0.62, green: 0.45, blue: 0.26, alpha: 1)
    private static let kStoneTint = NSColor(srgbRed: 0.58, green: 0.58, blue: 0.60, alpha: 1)
    private static let kIronTint  = NSColor(srgbRed: 0.86, green: 0.87, blue: 0.90, alpha: 1)
    private static let kHandleCol = NSColor(srgbRed: 0.50, green: 0.34, blue: 0.18, alpha: 1)

    private func toolTint(_ id: bf_item_id) -> NSColor {
        switch id {
        case 70, 71, 72: return HUDView.kWoodTint
        case 73, 74, 75: return HUDView.kStoneTint
        case 76, 77, 78: return HUDView.kIronTint
        default:         return HUDView.kStoneTint
        }
    }

    // Lighten toward white by fraction f (0 = unchanged, 1 = white).
    private func lighten(_ c: NSColor, _ f: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let g = max(0, min(1, f))
        return NSColor(srgbRed: s.redComponent + (1 - s.redComponent) * g,
                       green: s.greenComponent + (1 - s.greenComponent) * g,
                       blue:  s.blueComponent + (1 - s.blueComponent) * g, alpha: 1)
    }

    private func strokePoly(_ pts: [NSPoint], _ fill: NSColor,
                            outline: NSColor = NSColor.black.withAlphaComponent(0.45),
                            width: CGFloat = 1) {
        guard pts.count >= 2 else { return }
        let p = NSBezierPath(); p.move(to: pts[0])
        for q in pts.dropFirst() { p.line(to: q) }
        p.close()
        fill.setFill(); p.fill()
        outline.setStroke(); p.lineWidth = width; p.stroke()
    }

    private func fillCircle(_ center: NSPoint, _ r: CGFloat, _ fill: NSColor,
                            outline: NSColor? = NSColor.black.withAlphaComponent(0.4),
                            width: CGFloat = 1) {
        let rect = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let p = NSBezierPath(ovalIn: rect)
        fill.setFill(); p.fill()
        if let o = outline { o.setStroke(); p.lineWidth = width; p.stroke() }
    }

    // Dispatch an id (50..93) to its dedicated icon helper.
    private func drawItemIcon(id: bf_item_id, in r: NSRect, base: NSColor) {
        switch id {
        // --- Tools: shape by type, head colour by tier ---
        case 70, 73, 76: drawPickaxe(in: r, tint: toolTint(id))
        case 71, 74, 77: drawAxe(in: r, tint: toolTint(id))
        case 72, 75, 78: drawShovel(in: r, tint: toolTint(id))
        // --- Materials ---
        case 50: drawStick(in: r)
        case 51: drawLumpCluster(in: r, color: base)            // coal
        case 52, 53, 54: drawOreNugget(in: r, color: base)      // raw ores
        case 55, 56: drawIngot(in: r, color: base)              // ingots
        case 57: drawGem(in: r, color: base)                    // crystal shard
        case 58: drawBlob(in: r, color: base)                   // clay lump
        case 59: drawCoil(in: r, color: base)                   // string fiber
        case 60: drawFeather(in: r, color: base)                // feather
        case 61, 62: drawDustPile(in: r, color: base)           // dusts
        case 63: drawBook(in: r, color: base)                   // blank book
        // --- Food ---
        case 90: drawBerryCluster(in: r, color: base)
        case 91: drawStewBowl(in: r, color: base)
        case 92: drawCakeSlice(in: r, color: base)
        case 93: drawMushroom(in: r, color: base)
        default: drawBlob(in: r, color: base)                   // graceful fallback
        }
    }

    // ----- Tools -----------------------------------------------------------
    // Shared: a diagonal wooden handle running lower-left → upper-right.
    private func drawHandle(in r: NSRect, from a: NSPoint, to b: NSPoint, thickness: CGFloat) {
        let p = NSBezierPath()
        p.lineCapStyle = .round
        p.move(to: a); p.line(to: b)
        HUDView.kHandleCol.setStroke(); p.lineWidth = thickness; p.stroke()
        // subtle highlight along the handle
        lighten(HUDView.kHandleCol, 0.25).setStroke(); p.lineWidth = max(1, thickness * 0.4); p.stroke()
    }

    private func drawPickaxe(in r: NSRect, tint: NSColor) {
        let handleA = NSPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.18)
        let handleB = NSPoint(x: r.maxX - r.width * 0.18, y: r.maxY - r.height * 0.22)
        drawHandle(in: r, from: handleA, to: handleB, thickness: max(2, r.width * 0.13))
        // Curved double-pointed head across the top, centred over the handle top.
        let hx = handleB.x, hy = handleB.y
        let span = r.width * 0.42
        let p = NSBezierPath()
        p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: NSPoint(x: hx - span, y: hy + r.height * 0.02))
        p.curve(to: NSPoint(x: hx + span, y: hy + r.height * 0.02),
                controlPoint1: NSPoint(x: hx - span * 0.3, y: hy + r.height * 0.30),
                controlPoint2: NSPoint(x: hx + span * 0.3, y: hy + r.height * 0.30))
        tint.setStroke(); p.lineWidth = max(2.5, r.width * 0.16); p.stroke()
        // tip accents
        fillCircle(NSPoint(x: hx - span, y: hy + r.height * 0.02), max(1, r.width * 0.05), lighten(tint, 0.2))
        fillCircle(NSPoint(x: hx + span, y: hy + r.height * 0.02), max(1, r.width * 0.05), lighten(tint, 0.2))
    }

    private func drawAxe(in r: NSRect, tint: NSColor) {
        let handleA = NSPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.16)
        let handleB = NSPoint(x: r.maxX - r.width * 0.26, y: r.maxY - r.height * 0.18)
        drawHandle(in: r, from: handleA, to: handleB, thickness: max(2, r.width * 0.13))
        // Wedge blade on the upper-right side of the handle head.
        let hx = handleB.x, hy = handleB.y
        let blade = [
            NSPoint(x: hx - r.width * 0.04, y: hy + r.height * 0.06),
            NSPoint(x: hx + r.width * 0.30, y: hy + r.height * 0.18),
            NSPoint(x: hx + r.width * 0.34, y: hy - r.height * 0.04),
            NSPoint(x: hx + r.width * 0.16, y: hy - r.height * 0.20),
            NSPoint(x: hx - r.width * 0.02, y: hy - r.height * 0.12),
        ]
        strokePoly(blade, tint, width: 1)
        // cutting-edge highlight
        let edge = NSBezierPath()
        edge.move(to: blade[1]); edge.line(to: blade[2])
        lighten(tint, 0.45).setStroke(); edge.lineWidth = max(1, r.width * 0.06); edge.stroke()
    }

    private func drawShovel(in r: NSRect, tint: NSColor) {
        let handleA = NSPoint(x: r.minX + r.width * 0.24, y: r.minY + r.height * 0.30)
        let handleB = NSPoint(x: r.maxX - r.width * 0.22, y: r.maxY - r.height * 0.16)
        drawHandle(in: r, from: handleA, to: handleB, thickness: max(2, r.width * 0.13))
        // Spade/scoop at the bottom (lower-left) end of the handle.
        let sx = handleA.x, sy = handleA.y
        let w = r.width * 0.20, h = r.height * 0.22
        let scoop = NSBezierPath()
        scoop.lineJoinStyle = .round
        scoop.move(to: NSPoint(x: sx - w, y: sy + h * 0.2))
        scoop.line(to: NSPoint(x: sx + w, y: sy + h * 0.2))
        scoop.line(to: NSPoint(x: sx + w * 0.7, y: sy - h))
        // rounded tip
        scoop.curve(to: NSPoint(x: sx - w * 0.7, y: sy - h),
                    controlPoint1: NSPoint(x: sx + w * 0.2, y: sy - h * 1.5),
                    controlPoint2: NSPoint(x: sx - w * 0.2, y: sy - h * 1.5))
        scoop.close()
        tint.setFill(); scoop.fill()
        NSColor.black.withAlphaComponent(0.45).setStroke(); scoop.lineWidth = 1; scoop.stroke()
    }

    // ----- Materials -------------------------------------------------------
    private func drawStick(in r: NSRect) {
        let p = NSBezierPath()
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.20))
        p.line(to: NSPoint(x: r.maxX - r.width * 0.30, y: r.maxY - r.height * 0.20))
        HUDView.kHandleCol.setStroke(); p.lineWidth = max(2, r.width * 0.16); p.stroke()
        lighten(HUDView.kHandleCol, 0.3).setStroke(); p.lineWidth = max(1, r.width * 0.06); p.stroke()
    }

    private func drawLumpCluster(in r: NSRect, color: NSColor) {
        // A few overlapping dark lumps (coal). Deterministic placement.
        let cx = r.midX, cy = r.midY
        let rr = r.width * 0.22
        let offs = [CGSize(width: -0.18, height: -0.10), CGSize(width: 0.16, height: -0.14),
                    CGSize(width: 0.02, height: 0.16), CGSize(width: -0.05, height: -0.02)]
        for (i, o) in offs.enumerated() {
            let c = NSPoint(x: cx + r.width * o.width, y: cy + r.height * o.height)
            fillCircle(c, rr, shade(color, i == 3 ? 1.25 : (0.85 + CGFloat(i) * 0.1)))
        }
    }

    private func drawOreNugget(in r: NSRect, color: NSColor) {
        // Rough faceted nugget: an irregular polygon in the ore colour.
        let cx = r.midX, cy = r.midY
        let w = r.width * 0.34, h = r.height * 0.32
        let pts = [
            NSPoint(x: cx - w,        y: cy - h * 0.2),
            NSPoint(x: cx - w * 0.4,  y: cy + h),
            NSPoint(x: cx + w * 0.6,  y: cy + h * 0.7),
            NSPoint(x: cx + w,        y: cy - h * 0.3),
            NSPoint(x: cx + w * 0.2,  y: cy - h),
            NSPoint(x: cx - w * 0.6,  y: cy - h * 0.8),
        ]
        strokePoly(pts, color, width: 1)
        // a couple of bright facet flecks
        fillCircle(NSPoint(x: cx - w * 0.2, y: cy + h * 0.1), max(1, r.width * 0.06), lighten(color, 0.45), outline: nil)
        fillCircle(NSPoint(x: cx + w * 0.4, y: cy - h * 0.2), max(1, r.width * 0.045), lighten(color, 0.55), outline: nil)
    }

    private func drawIngot(in r: NSRect, color: NSColor) {
        // Trapezoid bar (wider at the bottom), with a lighter top face.
        let cx = r.midX, cy = r.midY
        let bw = r.width * 0.40, tw = r.width * 0.28
        let h = r.height * 0.20
        let body = [
            NSPoint(x: cx - bw, y: cy - h),
            NSPoint(x: cx + bw, y: cy - h),
            NSPoint(x: cx + tw, y: cy + h),
            NSPoint(x: cx - tw, y: cy + h),
        ]
        strokePoly(body, color, width: 1)
        // top face highlight (thin parallelogram on top edge)
        let top = [
            NSPoint(x: cx - tw,         y: cy + h),
            NSPoint(x: cx + tw,         y: cy + h),
            NSPoint(x: cx + tw * 0.7,   y: cy + h * 1.7),
            NSPoint(x: cx - tw * 0.7,   y: cy + h * 1.7),
        ]
        strokePoly(top, lighten(color, 0.35), outline: NSColor.black.withAlphaComponent(0.25))
    }

    private func drawGem(in r: NSRect, color: NSColor) {
        // Faceted gem: top crown + pointed pavilion, with a centre facet line.
        let cx = r.midX, cy = r.midY
        let w = r.width * 0.30, top = r.height * 0.26, bot = r.height * 0.32
        let outline = [
            NSPoint(x: cx - w,        y: cy + top * 0.4),
            NSPoint(x: cx - w * 0.45, y: cy + top),
            NSPoint(x: cx + w * 0.45, y: cy + top),
            NSPoint(x: cx + w,        y: cy + top * 0.4),
            NSPoint(x: cx,            y: cy - bot),
        ]
        strokePoly(outline, color, width: 1)
        // facets
        let f = NSBezierPath()
        f.move(to: NSPoint(x: cx - w * 0.45, y: cy + top)); f.line(to: NSPoint(x: cx, y: cy - bot))
        f.move(to: NSPoint(x: cx + w * 0.45, y: cy + top)); f.line(to: NSPoint(x: cx, y: cy - bot))
        f.move(to: NSPoint(x: cx - w, y: cy + top * 0.4)); f.line(to: NSPoint(x: cx + w, y: cy + top * 0.4))
        lighten(color, 0.5).setStroke(); f.lineWidth = 1; f.stroke()
    }

    private func drawBlob(in r: NSRect, color: NSColor) {
        // Rounded clay blob: a fat oval with a soft highlight.
        let rect = r.insetBy(dx: r.width * 0.16, dy: r.height * 0.24)
        let p = NSBezierPath(ovalIn: rect)
        color.setFill(); p.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke(); p.lineWidth = 1; p.stroke()
        fillCircle(NSPoint(x: rect.midX - rect.width * 0.18, y: rect.midY + rect.height * 0.18),
                   max(1, rect.width * 0.14), lighten(color, 0.4), outline: nil)
    }

    private func drawCoil(in r: NSRect, color: NSColor) {
        // String fibre: a few stacked loops/threads.
        let cx = r.midX
        let w = r.width * 0.30
        let stroke = shade(color, 0.85)
        for i in 0..<3 {
            let y = r.midY + (CGFloat(i) - 1) * r.height * 0.18
            let rect = NSRect(x: cx - w, y: y - r.height * 0.07, width: w * 2, height: r.height * 0.14)
            let p = NSBezierPath(ovalIn: rect)
            stroke.setStroke(); p.lineWidth = max(1.5, r.width * 0.07); p.stroke()
        }
    }

    private func drawFeather(in r: NSRect, color: NSColor) {
        // Feather: a leaf-like vane with a central quill.
        let tip = NSPoint(x: r.maxX - r.width * 0.22, y: r.maxY - r.height * 0.18)
        let base = NSPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.20)
        let vane = NSBezierPath()
        vane.move(to: base)
        vane.curve(to: tip,
                   controlPoint1: NSPoint(x: r.minX + r.width * 0.15, y: r.maxY - r.height * 0.30),
                   controlPoint2: NSPoint(x: r.midX, y: r.maxY - r.height * 0.10))
        vane.curve(to: base,
                   controlPoint1: NSPoint(x: r.maxX - r.width * 0.10, y: r.midY),
                   controlPoint2: NSPoint(x: r.midX + r.width * 0.10, y: r.minY + r.height * 0.18))
        vane.close()
        color.setFill(); vane.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke(); vane.lineWidth = 1; vane.stroke()
        // quill / rachis
        let quill = NSBezierPath()
        quill.move(to: base); quill.line(to: tip)
        shade(color, 0.7).setStroke(); quill.lineWidth = max(1, r.width * 0.05); quill.stroke()
    }

    private func drawDustPile(in r: NSRect, color: NSColor) {
        // Small heap with sparkle specks.
        let cx = r.midX, baseY = r.minY + r.height * 0.30
        let heap = NSBezierPath()
        heap.move(to: NSPoint(x: cx - r.width * 0.30, y: baseY))
        heap.curve(to: NSPoint(x: cx + r.width * 0.30, y: baseY),
                   controlPoint1: NSPoint(x: cx - r.width * 0.10, y: baseY + r.height * 0.34),
                   controlPoint2: NSPoint(x: cx + r.width * 0.10, y: baseY + r.height * 0.34))
        heap.close()
        color.setFill(); heap.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke(); heap.lineWidth = 1; heap.stroke()
        // sparkles
        let spark = lighten(color, 0.6)
        for o in [CGPoint(x: -0.10, y: 0.42), CGPoint(x: 0.16, y: 0.30), CGPoint(x: 0.02, y: 0.55)] {
            drawSparkle(at: NSPoint(x: cx + r.width * o.x, y: baseY + r.height * o.y),
                        s: r.width * 0.07, color: spark)
        }
    }

    private func drawSparkle(at c: NSPoint, s: CGFloat, color: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x - s, y: c.y)); p.line(to: NSPoint(x: c.x + s, y: c.y))
        p.move(to: NSPoint(x: c.x, y: c.y - s)); p.line(to: NSPoint(x: c.x, y: c.y + s))
        color.setStroke(); p.lineWidth = max(1, s * 0.5); p.stroke()
    }

    private func drawBook(in r: NSRect, color: NSColor) {
        // Small closed book: cover + spine + page edge.
        let rect = r.insetBy(dx: r.width * 0.20, dy: r.height * 0.22)
        let cover = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        color.setFill(); cover.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke(); cover.lineWidth = 1; cover.stroke()
        // page edge on the right
        let pages = NSRect(x: rect.maxX - rect.width * 0.16, y: rect.minY + 1,
                           width: rect.width * 0.14, height: rect.height - 2)
        lighten(color, 0.7).setFill(); NSBezierPath(rect: pages).fill()
        // spine on the left
        let spine = NSRect(x: rect.minX, y: rect.minY, width: rect.width * 0.16, height: rect.height)
        shade(color, 0.7).setFill(); NSBezierPath(rect: spine).fill()
    }

    // ----- Food ------------------------------------------------------------
    private func drawBerryCluster(in r: NSRect, color: NSColor) {
        let rr = r.width * 0.16
        let offs = [CGPoint(x: -0.16, y: 0.10), CGPoint(x: 0.16, y: 0.10),
                    CGPoint(x: 0.0, y: -0.14), CGPoint(x: -0.02, y: 0.26)]
        for o in offs {
            let c = NSPoint(x: r.midX + r.width * o.x, y: r.midY + r.height * o.y)
            fillCircle(c, rr, color)
            fillCircle(NSPoint(x: c.x - rr * 0.3, y: c.y + rr * 0.3), rr * 0.3, lighten(color, 0.5), outline: nil)
        }
    }

    private func drawStewBowl(in r: NSRect, color: NSColor) {
        // Bowl (half-disc) with stew inside.
        let cx = r.midX, cy = r.midY - r.height * 0.04
        let bw = r.width * 0.34
        // stew surface (ellipse)
        let surf = NSRect(x: cx - bw, y: cy, width: bw * 2, height: r.height * 0.16)
        color.setFill(); NSBezierPath(ovalIn: surf).fill()
        // bowl body
        let bowl = NSBezierPath()
        bowl.move(to: NSPoint(x: cx - bw, y: cy + r.height * 0.08))
        bowl.curve(to: NSPoint(x: cx + bw, y: cy + r.height * 0.08),
                   controlPoint1: NSPoint(x: cx - bw * 0.6, y: cy - r.height * 0.28),
                   controlPoint2: NSPoint(x: cx + bw * 0.6, y: cy - r.height * 0.28))
        NSColor(srgbRed: 0.85, green: 0.85, blue: 0.88, alpha: 1).setFill(); bowl.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke(); bowl.lineWidth = 1; bowl.stroke()
    }

    private func drawCakeSlice(in r: NSRect, color: NSColor) {
        // Layered triangular slice (side view): two cake layers + a top.
        let left = r.minX + r.width * 0.22
        let right = r.maxX - r.width * 0.20
        let baseY = r.minY + r.height * 0.26
        let topY = r.maxY - r.height * 0.26
        let slice = [
            NSPoint(x: left, y: baseY),
            NSPoint(x: right, y: baseY),
            NSPoint(x: right, y: topY),
        ]
        strokePoly(slice, shade(color, 0.85), width: 1)
        // filling stripe
        let midY = (baseY + topY) / 2
        let stripe = NSBezierPath()
        stripe.move(to: NSPoint(x: left + (right - left) * 0.0, y: midY))
        stripe.line(to: NSPoint(x: right, y: midY))
        lighten(color, 0.55).setStroke(); stripe.lineWidth = max(1.5, r.height * 0.07); stripe.stroke()
        // a cherry on the top corner
        fillCircle(NSPoint(x: right - r.width * 0.06, y: topY - r.height * 0.02),
                   max(1, r.width * 0.07), NSColor.systemRed)
    }

    private func drawMushroom(in r: NSRect, color: NSColor) {
        // Stem + domed cap.
        let cx = r.midX
        // stem
        let stem = NSRect(x: cx - r.width * 0.10, y: r.minY + r.height * 0.22,
                          width: r.width * 0.20, height: r.height * 0.28)
        lighten(color, 0.6).setFill()
        let sp = NSBezierPath(roundedRect: stem, xRadius: 2, yRadius: 2); sp.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke(); sp.lineWidth = 1; sp.stroke()
        // cap (half dome)
        let capY = r.minY + r.height * 0.48
        let cw = r.width * 0.32
        let cap = NSBezierPath()
        cap.move(to: NSPoint(x: cx - cw, y: capY))
        cap.curve(to: NSPoint(x: cx + cw, y: capY),
                  controlPoint1: NSPoint(x: cx - cw, y: capY + r.height * 0.34),
                  controlPoint2: NSPoint(x: cx + cw, y: capY + r.height * 0.34))
        cap.close()
        color.setFill(); cap.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke(); cap.lineWidth = 1; cap.stroke()
        // spots
        fillCircle(NSPoint(x: cx - cw * 0.4, y: capY + r.height * 0.10), max(1, r.width * 0.05),
                   NSColor.white.withAlphaComponent(0.8), outline: nil)
        fillCircle(NSPoint(x: cx + cw * 0.35, y: capY + r.height * 0.14), max(1, r.width * 0.04),
                   NSColor.white.withAlphaComponent(0.8), outline: nil)
    }

    private func drawHearts(value: Float, max: Int, at origin: NSPoint) {
        let full = Int(value.rounded())
        for i in 0..<max / 2 {
            let filled = (i * 2) < full
            (filled ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.4)).setFill()
            let r = NSRect(x: origin.x + CGFloat(i) * 16, y: origin.y, width: 12, height: 12)
            NSBezierPath(ovalIn: r).fill()
        }
    }

    private func drawBubbles(value: Float, at origin: NSPoint) {
        // 10 air bubbles; fill count tracks remaining oxygen (1 = full).
        let count = 10
        let filled = Int((max(0, min(1, value)) * Float(count)).rounded())
        for i in 0..<count {
            let r = NSRect(x: origin.x + CGFloat(i) * 16, y: origin.y, width: 12, height: 12)
            if i < filled {
                NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: r).fill()
                NSColor.white.withAlphaComponent(0.6).setStroke()
                let p = NSBezierPath(ovalIn: r); p.lineWidth = 1; p.stroke()
            } else {
                NSColor.black.withAlphaComponent(0.4).setFill()
                NSBezierPath(ovalIn: r).fill()
            }
        }
    }

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, bold: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .strokeColor: NSColor.black, .strokeWidth: -2.0,
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
}
