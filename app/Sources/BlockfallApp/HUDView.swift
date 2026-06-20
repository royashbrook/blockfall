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
    // Current mouse position in view coords (for tooltip + held-stack ghost).
    private var mousePos: NSPoint = .zero
    private var mouseInside = false
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    // Click-through during play; capture clicks only when the inventory is open.
    override func hitTest(_ point: NSPoint) -> NSView? {
        hud.inventory_open != 0 ? self : nil
    }
    override var acceptsFirstResponder: Bool { hud.inventory_open != 0 }

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

        // When the inventory is open it replaces the in-world HUD.
        if hud.inventory_open != 0 { drawInventory(in: b); return }

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
            let s = slots[Int(hud.selected_slot)]
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

        drawText("Inventory", at: NSPoint(x: originX, y: b.midY + 175), size: 20, color: .white, bold: true)
        drawText("Crafting", at: NSPoint(x: originX + gridW - 220, y: b.midY + 175), size: 14, color: .white, bold: false)

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

        // --- Craftable recipes (press the number to craft) ---
        let cy = b.midY - 70
        drawText("Craft  (press the number)", at: NSPoint(x: originX, y: cy + slot + 8), size: 14, color: .systemYellow, bold: true)
        let n = Int(hud.craftable_count)
        if n == 0 {
            drawText("Gather wood and stone, then come back!", at: NSPoint(x: originX, y: cy + slot - 14),
                     size: 12, color: NSColor.white.withAlphaComponent(0.7), bold: false)
        }
        withUnsafeBytes(of: hud.craftable) { raw in
            let cr = raw.bindMemory(to: bf_hud_slot.self)
            var cx = originX
            for i in 0..<min(n, 8) {
                let rect = NSRect(x: cx, y: cy, width: slot, height: slot)
                NSColor.black.withAlphaComponent(0.5).setFill()
                let rr = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5); rr.fill()
                NSColor.systemYellow.withAlphaComponent(0.7).setStroke(); rr.lineWidth = 1.5; rr.stroke()
                if cr[i].item != 0 {
                    drawCenteredItem(id: cr[i].item, count: cr[i].count, in: rect, selected: false)
                    drawText(itemName(cr[i].item), at: NSPoint(x: cx - 6, y: cy - 16), size: 10, color: .white, bold: false)
                }
                drawText("\(i+1)", at: NSPoint(x: cx + 3, y: cy + slot - 16), size: 12, color: .systemYellow, bold: true)
                cx += slot + gap
            }
        }

        drawText("Esc / E to close   •   click a stack to pick it up, click a slot to place it",
                 at: NSPoint(x: originX, y: b.midY - 130), size: 12, color: .white, bold: false)

        // --- Hover tooltip: item name + count under the cursor (only when not
        //     carrying a stack, so the tooltip doesn't fight the ghost). ---
        if mouseInside && heldSlot == nil {
            if let i = slotIndex(at: mousePos) {
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

    private func drawTooltip(name: String, count: UInt16, near p: NSPoint) {
        let label = count > 1 ? "\(name)  ×\(count)" : name
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

    private func drawCenteredItem(id: bf_item_id, count: UInt16, in rect: NSRect, selected: Bool) {
        // No icon art yet — a colour-coded chip (matching the block's colour) +
        // count. The held-item name is shown above the hotbar.
        itemChipColor(id).setFill()
        let chip = rect.insetBy(dx: 9, dy: 9)
        let rr = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
        rr.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke(); rr.lineWidth = 1; rr.stroke()
        if count > 1 {
            drawText("\(count)", at: NSPoint(x: rect.maxX - 18, y: rect.minY + 3),
                     size: 12, color: .white, bold: true)
        }
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
