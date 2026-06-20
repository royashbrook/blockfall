// ============================================================================
// Blockfall — HUDView (Phase 0 / M0)
// A lightweight AppKit overlay that renders the engine's HUD snapshot: hotbar,
// health, and the active quest. Deliberately simple (Core Graphics, no Metal
// text) so M0 proves the HUD-state handoff end to end. Track E may later move
// this into the Metal layer; the data contract (bf_hud_state) stays the same.
// ============================================================================
import AppKit
import CBlockcore

final class HUDView: NSView {
    private var hud = bf_hud_state()
    private var crosshair = true

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // click-through

    func update(from h: bf_hud_state) {
        hud = h
        needsDisplay = true
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

        // --- Health hearts (survival) ---
        if hud.mode == BF_MODE_SURVIVAL {
            drawHearts(value: hud.health, max: 20, at: NSPoint(x: b.midX - total / 2, y: y + slot + 10))
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

        func cell(_ rect: NSRect, _ s: bf_hud_slot, sel: Bool) {
            (sel ? NSColor.white : NSColor.black.withAlphaComponent(0.5)).setFill()
            let rr = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            rr.fill()
            NSColor.white.withAlphaComponent(sel ? 1 : 0.4).setStroke()
            rr.lineWidth = sel ? 2.5 : 1
            rr.stroke()
            if s.item != 0 { drawCenteredItem(id: s.item, count: s.count, in: rect, selected: sel) }
        }

        drawText("Inventory", at: NSPoint(x: originX, y: b.midY + 175), size: 20, color: .white, bold: true)
        drawText("Crafting", at: NSPoint(x: originX + gridW - 220, y: b.midY + 175), size: 14, color: .white, bold: false)

        withUnsafeBytes(of: hud.inventory) { raw in
            let inv = raw.bindMemory(to: bf_hud_slot.self)
            // Main inventory: slots 9..35 in 3 rows of 9, above the hotbar row.
            var topY = b.midY + 120
            for row in 0..<3 {
                var x = originX
                for col in 0..<cols {
                    let i = 9 + row * 9 + col
                    cell(NSRect(x: x, y: topY, width: slot, height: slot), inv[i], sel: false)
                    x += slot + gap
                }
                topY -= slot + gap
            }
            // Hotbar row (slots 0..8) a little below, highlighting the selection.
            let hy = topY - 12
            var hx = originX
            for col in 0..<9 {
                cell(NSRect(x: hx, y: hy, width: slot, height: slot), inv[col],
                     sel: Int(hud.selected_slot) == col)
                hx += slot + gap
            }
        }

        drawText("Esc / E to close", at: NSPoint(x: originX, y: b.midY - 130), size: 12, color: .white, bold: false)
    }

    private func drawCenteredItem(id: bf_item_id, count: UInt16, in rect: NSRect, selected: Bool) {
        // No icons yet (Track E/assets) — show a colored chip + count as a stand-in.
        let hue = CGFloat(id % 12) / 12.0
        NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
        let chip = rect.insetBy(dx: 10, dy: 10)
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        if count > 1 {
            drawText("\(count)", at: NSPoint(x: rect.maxX - 18, y: rect.minY + 3),
                     size: 12, color: selected ? .black : .white, bold: true)
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

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, bold: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .strokeColor: NSColor.black, .strokeWidth: -2.0,
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
}
