import AppKit
import CBlockcore

extension HUDView {
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
    func drawCenteredItem(id: bf_item_id, count: UInt16, in rect: NSRect, selected: Bool) {
        let base = itemChipColor(id)
        let chip = rect.insetBy(dx: 8, dy: 8)
        // #31: A handful of "block" ids are really props/decor, not building
        // cubes — drawing them as an iso cube reads as a meaningless coloured
        // box (the torch was the worst offender). Route those to dedicated
        // silhouettes so they're recognizable at hotbar size. Plain building
        // blocks keep the iso-cube look below. (Falls through to the count badge.)
        switch id {
        case 24: drawTorch(in: chip)                                     // torch — stick + flame
        case 25: drawDoor(in: chip, color: base)                        // wooden door
        case 29: drawFlower(in: chip, petal: itemColor(0.90, 0.28, 0.28)) // red flower
        case 30: drawFlower(in: chip, petal: itemColor(0.97, 0.86, 0.28)) // yellow flower
        case let bid where bid <= 40:
            // Block item → little isometric cube icon with a procedural texture
            // pattern on each visible face, so the material reads at a glance
            // (grass, stone, wood …) instead of three flat shaded diamonds.
            drawTexturedCube(id: id, in: chip, base: base)
        default:
            // Tool / material / food → distinct procedural icon per item, so
            // each is recognizable at a glance (no more uniform chips).
            drawItemIcon(id: id, in: chip, base: base)
        }
        if count > 1 {
            // Badge font tracks the cell size so it stays legible when the HUD
            // (and thus the hotbar/inventory cells) are scaled up.
            let badgeSize = max(10, min(16, rect.height * 0.26))
            drawText("\(count)", at: NSPoint(x: rect.maxX - badgeSize * 1.5, y: rect.minY + 3),
                     size: badgeSize, color: .white, bold: true)
        }
    }

    // ===== #31: prop / decor icons (non-cube blocks) =======================
    // A few placeable ids are props, not building cubes. These cheap silhouettes
    // make them readable at hotbar size instead of generic coloured boxes.

    // Torch (#31 priority): a short brown handle with a layered orange→yellow
    // flame and a soft warm glow, so it reads as a torch even at ~32px.
    private func drawTorch(in r: NSRect) {
        let cx = r.midX
        // Handle: a thick vertical wooden stick in the lower half.
        let handleTop = NSPoint(x: cx, y: r.minY + r.height * 0.56)
        let handleBot = NSPoint(x: cx, y: r.minY + r.height * 0.12)
        let stick = NSBezierPath()
        stick.lineCapStyle = .round
        stick.move(to: handleBot); stick.line(to: handleTop)
        HUDView.kHandleCol.setStroke(); stick.lineWidth = max(2.5, r.width * 0.16); stick.stroke()
        lighten(HUDView.kHandleCol, 0.28).setStroke()
        stick.lineWidth = max(1, r.width * 0.05); stick.stroke()

        // Warm glow halo behind the flame.
        fillCircle(NSPoint(x: cx, y: handleTop.y + r.height * 0.10),
                   r.width * 0.24,
                   NSColor(srgbRed: 1.0, green: 0.78, blue: 0.30, alpha: 0.28),
                   outline: nil)

        // Flame: an outer orange teardrop, an inner yellow core, and a white
        // hot spot — built bottom→tip→bottom so it points up like a real flame.
        func flame(halfW: CGFloat, height: CGFloat, color: NSColor) {
            let baseY = handleTop.y - r.height * 0.02
            let tipY = baseY + height
            let f = NSBezierPath()
            f.move(to: NSPoint(x: cx - halfW, y: baseY))
            f.curve(to: NSPoint(x: cx, y: tipY),
                    controlPoint1: NSPoint(x: cx - halfW, y: baseY + height * 0.55),
                    controlPoint2: NSPoint(x: cx - halfW * 0.35, y: tipY))
            f.curve(to: NSPoint(x: cx + halfW, y: baseY),
                    controlPoint1: NSPoint(x: cx + halfW * 0.35, y: tipY),
                    controlPoint2: NSPoint(x: cx + halfW, y: baseY + height * 0.55))
            f.close()
            color.setFill(); f.fill()
        }
        flame(halfW: r.width * 0.17, height: r.height * 0.42, color: itemColor(0.98, 0.45, 0.10))
        flame(halfW: r.width * 0.11, height: r.height * 0.32, color: itemColor(1.0, 0.80, 0.20))
        flame(halfW: r.width * 0.05, height: r.height * 0.20, color: itemColor(1.0, 0.97, 0.78))
    }

    // Wooden door: a tall panelled rectangle with a knob — clearly a door, not
    // a brown cube. Coloured from the door's chip colour.
    private func drawDoor(in r: NSRect, color: NSColor) {
        let dw = r.width * 0.46
        let panel = NSRect(x: r.midX - dw / 2, y: r.minY + r.height * 0.10,
                           width: dw, height: r.height * 0.80)
        let body = NSBezierPath(roundedRect: panel, xRadius: 2, yRadius: 2)
        color.setFill(); body.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke(); body.lineWidth = 1; body.stroke()
        // Two recessed panels (upper + lower) for a door silhouette.
        let inset = panel.insetBy(dx: panel.width * 0.18, dy: panel.height * 0.10)
        let split = inset.minY + inset.height * 0.5
        for sub in [
            NSRect(x: inset.minX, y: split + 2, width: inset.width, height: inset.height * 0.5 - 4),
            NSRect(x: inset.minX, y: inset.minY, width: inset.width, height: inset.height * 0.5 - 4),
        ] {
            shade(color, 0.78).setFill(); NSBezierPath(rect: sub).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            let sp = NSBezierPath(rect: sub); sp.lineWidth = 0.8; sp.stroke()
        }
        // Knob near the right edge, mid-height.
        fillCircle(NSPoint(x: panel.maxX - panel.width * 0.16, y: panel.midY),
                   max(1, r.width * 0.05),
                   lighten(NSColor(srgbRed: 0.85, green: 0.72, blue: 0.30, alpha: 1), 0.1))
    }

    // Flower: a green stem, a small leaf, and a ring of petals around a centre.
    // `petal` colours the bloom (red / yellow), so the two flowers read distinctly.
    private func drawFlower(in r: NSRect, petal: NSColor) {
        let cx = r.midX
        let centre = NSPoint(x: cx, y: r.minY + r.height * 0.66)
        // Stem.
        let stem = NSBezierPath(); stem.lineCapStyle = .round
        stem.move(to: NSPoint(x: cx, y: r.minY + r.height * 0.14))
        stem.line(to: NSPoint(x: cx, y: centre.y - r.height * 0.06))
        itemColor(0.30, 0.60, 0.26).setStroke()
        stem.lineWidth = max(1.5, r.width * 0.07); stem.stroke()
        // Leaf off the stem.
        fillCircle(NSPoint(x: cx + r.width * 0.12, y: r.minY + r.height * 0.34),
                   r.width * 0.08, itemColor(0.34, 0.66, 0.30), outline: nil)
        // Petals: 5 around the centre.
        let pr = r.width * 0.12
        for k in 0..<5 {
            let ang = CGFloat(k) / 5.0 * 2 * .pi + .pi / 2
            let p = NSPoint(x: centre.x + cos(ang) * pr * 1.4,
                            y: centre.y + sin(ang) * pr * 1.4)
            fillCircle(p, pr, petal, outline: NSColor.black.withAlphaComponent(0.2))
        }
        // Bright centre.
        fillCircle(centre, pr * 0.7, lighten(petal, 0.55), outline: nil)
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
    func clipped(to pts: [NSPoint], _ body: () -> Void) {
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
                // Cask lid: concentric iron rim plus the bright loot crest.
                let rim = NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.12, dy: r.height * 0.12))
                rim.lineWidth = 1.2; dark.setStroke(); rim.stroke()
                fillCircle(NSPoint(x: r.midX, y: r.midY), r.width * 0.08,
                           lighten(shaded, 0.85), outline: dark)
            } else {
                // Vertical staves, two dark hoops and a bright central lock crest.
                for fx in [0.34, 0.66] {
                    let x = r.minX + r.width * CGFloat(fx)
                    tick(NSPoint(x: x, y: r.minY), NSPoint(x: x, y: r.maxY), dark, width: 0.8)
                }
                for fy in [0.28, 0.74] {
                    let y = r.minY + r.height * CGFloat(fy)
                    tick(NSPoint(x: r.minX, y: y), NSPoint(x: r.maxX, y: y), dark, width: 1.5)
                }
                fillCircle(NSPoint(x: r.midX, y: r.midY), r.width * 0.08,
                           lighten(shaded, 0.85), outline: dark)
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
    // Each non-block item maps to a small recognizable silhouette drawn with
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
        case 70, 71, 72, 79: return HUDView.kWoodTint
        case 73, 74, 75, 80: return HUDView.kStoneTint
        case 76, 77, 78, 81: return HUDView.kIronTint
        default:              return HUDView.kStoneTint
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

    // Dispatch a non-block item id to its dedicated icon helper.
    private func drawItemIcon(id: bf_item_id, in r: NSRect, base: NSColor) {
        switch id {
        // --- Tools: shape by type, head colour by tier ---
        case 70, 73, 76: drawPickaxe(in: r, tint: toolTint(id))
        case 71, 74, 77: drawAxe(in: r, tint: toolTint(id))
        case 72, 75, 78: drawShovel(in: r, tint: toolTint(id))
        // --- Swords ---
        case 79, 80, 81: drawSword(in: r, tint: toolTint(id))
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
        // --- Workstations ---
        case 97: drawChoppingBlock(in: r)
        case 98, 99, 100, 101: drawArtisanStation(id: id, in: r)
        case 102: drawCommunalBench(in: r)
        case 103: drawBroomStand(in: r)
        case 104...109: drawArmor(id: id, in: r, color: base)
        default: drawBlob(in: r, color: base)                   // graceful fallback
        }
    }

    private func drawArmor(id: bf_item_id, in r: NSRect, color: NSColor) {
        let outline = shade(color, 0.48)
        switch id {
        case 104, 107:
            let crown = NSRect(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.32,
                               width: r.width * 0.64, height: r.height * 0.50)
            let path = NSBezierPath(roundedRect: crown, xRadius: r.width * 0.25,
                                    yRadius: r.height * 0.25)
            color.setFill(); path.fill(); outline.setStroke(); path.lineWidth = 2; path.stroke()
            tick(NSPoint(x: crown.minX, y: crown.minY), NSPoint(x: crown.maxX, y: crown.minY),
                 lighten(color, 0.22), width: max(2, r.width * 0.08))
        case 105, 108:
            let vest = [
                NSPoint(x: r.minX + r.width * 0.28, y: r.maxY - r.height * 0.16),
                NSPoint(x: r.minX + r.width * 0.12, y: r.maxY - r.height * 0.34),
                NSPoint(x: r.minX + r.width * 0.24, y: r.minY + r.height * 0.12),
                NSPoint(x: r.maxX - r.width * 0.24, y: r.minY + r.height * 0.12),
                NSPoint(x: r.maxX - r.width * 0.12, y: r.maxY - r.height * 0.34),
                NSPoint(x: r.maxX - r.width * 0.28, y: r.maxY - r.height * 0.16),
            ]
            strokePoly(vest, color, width: 2)
            tick(NSPoint(x: r.midX, y: r.minY + r.height * 0.16),
                 NSPoint(x: r.midX, y: r.maxY - r.height * 0.23), outline, width: 2)
        default:
            for x in [r.minX + r.width * 0.15, r.midX + r.width * 0.05] {
                let boot = NSRect(x: x, y: r.minY + r.height * 0.18,
                                  width: r.width * 0.30, height: r.height * 0.52)
                let path = NSBezierPath(roundedRect: boot, xRadius: r.width * 0.09,
                                        yRadius: r.width * 0.09)
                color.setFill(); path.fill(); outline.setStroke(); path.lineWidth = 2; path.stroke()
            }
        }
    }

    private func drawChoppingBlock(in r: NSRect) {
        let bark = itemColor(0.47, 0.31, 0.16)
        let cutWood = itemColor(0.74, 0.53, 0.28)
        let iron = itemColor(0.30, 0.32, 0.36)
        let stump = NSRect(x: r.minX + r.width * 0.19,
                           y: r.minY + r.height * 0.14,
                           width: r.width * 0.56,
                           height: r.height * 0.37)

        let body = NSBezierPath(roundedRect: stump, xRadius: r.width * 0.08,
                                yRadius: r.width * 0.08)
        bark.setFill(); body.fill()
        NSColor.black.withAlphaComponent(0.4).setStroke(); body.lineWidth = 1; body.stroke()
        for x in [0.32, 0.48, 0.64] as [CGFloat] {
            tick(NSPoint(x: r.minX + r.width * x, y: stump.minY + r.height * 0.04),
                 NSPoint(x: r.minX + r.width * (x + 0.02), y: stump.maxY - r.height * 0.05),
                 shade(bark, 0.72), width: max(1, r.width * 0.025))
        }

        let top = NSRect(x: stump.minX, y: stump.maxY - r.height * 0.09,
                         width: stump.width, height: r.height * 0.18)
        let topPath = NSBezierPath(ovalIn: top)
        cutWood.setFill(); topPath.fill()
        shade(bark, 0.7).setStroke(); topPath.lineWidth = 1; topPath.stroke()
        let ring = NSBezierPath(ovalIn: top.insetBy(dx: top.width * 0.19,
                                                    dy: top.height * 0.24))
        shade(cutWood, 0.75).setStroke(); ring.lineWidth = 1; ring.stroke()
        let crack = NSBezierPath(); crack.lineCapStyle = .round
        crack.move(to: NSPoint(x: top.midX, y: top.midY))
        crack.line(to: NSPoint(x: top.midX - r.width * 0.11, y: top.midY + r.height * 0.04))
        crack.move(to: NSPoint(x: top.midX, y: top.midY))
        crack.line(to: NSPoint(x: top.midX + r.width * 0.08, y: top.midY - r.height * 0.05))
        shade(bark, 0.55).setStroke(); crack.lineWidth = max(1, r.width * 0.035); crack.stroke()

        let bite = NSPoint(x: top.midX + r.width * 0.04, y: top.midY + r.height * 0.02)
        let handleEnd = NSPoint(x: r.maxX - r.width * 0.12, y: r.maxY - r.height * 0.10)
        drawHandle(in: r, from: bite, to: handleEnd, thickness: max(2, r.width * 0.10))
        let blade = [
            NSPoint(x: bite.x - r.width * 0.02, y: bite.y + r.height * 0.12),
            NSPoint(x: bite.x - r.width * 0.28, y: bite.y + r.height * 0.13),
            NSPoint(x: bite.x - r.width * 0.30, y: bite.y - r.height * 0.05),
            NSPoint(x: bite.x - r.width * 0.12, y: bite.y - r.height * 0.10),
            NSPoint(x: bite.x + r.width * 0.04, y: bite.y - r.height * 0.02),
        ]
        strokePoly(blade, iron, width: 1)
        tick(blade[1], blade[2], lighten(iron, 0.45), width: max(1, r.width * 0.025))
    }

    private func drawArtisanStation(id: bf_item_id, in r: NSRect) {
        let wood = itemColor(0.52, 0.34, 0.17)
        let stone = itemColor(0.52, 0.53, 0.56)
        let iron = itemColor(0.25, 0.27, 0.31)
        let topY = r.minY + r.height * 0.42
        switch id {
        case 98: // Mason: broad stone slab, block, mallet and chisel.
            let slab = NSRect(x: r.minX + r.width * 0.12, y: topY,
                              width: r.width * 0.76, height: r.height * 0.20)
            stone.setFill(); NSBezierPath(roundedRect: slab, xRadius: 3, yRadius: 3).fill()
            shade(stone, 0.62).setFill()
            NSBezierPath(rect: NSRect(x: slab.minX + 3, y: r.minY + r.height * 0.13,
                                      width: r.width * 0.15, height: r.height * 0.30)).fill()
            NSBezierPath(rect: NSRect(x: slab.maxX - r.width * 0.15 - 3,
                                      y: r.minY + r.height * 0.13,
                                      width: r.width * 0.15, height: r.height * 0.30)).fill()
            let block = NSRect(x: r.midX - r.width * 0.13, y: slab.maxY,
                               width: r.width * 0.26, height: r.height * 0.20)
            lighten(stone, 0.16).setFill(); NSBezierPath(rect: block).fill()
            drawHandle(in: r,
                       from: NSPoint(x: r.minX + r.width * 0.28, y: slab.maxY + r.height * 0.02),
                       to: NSPoint(x: r.minX + r.width * 0.55, y: r.maxY - r.height * 0.08),
                       thickness: max(2, r.width * 0.07))
            let mallet = NSRect(x: r.minX + r.width * 0.43, y: r.maxY - r.height * 0.18,
                                width: r.width * 0.28, height: r.height * 0.12)
            wood.setFill(); NSBezierPath(roundedRect: mallet, xRadius: 2, yRadius: 2).fill()
            tick(NSPoint(x: block.maxX + r.width * 0.04, y: block.minY),
                 NSPoint(x: block.maxX + r.width * 0.12, y: block.maxY + r.height * 0.13),
                 iron, width: max(1, r.width * 0.045))
        case 99: // Blacksmith: unmistakable anvil over an ember forge.
            let coals = NSRect(x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.12,
                               width: r.width * 0.30, height: r.height * 0.24)
            shade(stone, 0.52).setFill(); NSBezierPath(roundedRect: coals, xRadius: 3, yRadius: 3).fill()
            fillCircle(NSPoint(x: coals.midX, y: coals.midY), r.width * 0.10,
                       itemColor(1.0, 0.38, 0.08), outline: nil)
            let foot = NSRect(x: r.midX - r.width * 0.13, y: r.minY + r.height * 0.13,
                              width: r.width * 0.26, height: r.height * 0.22)
            let waist = NSRect(x: r.midX - r.width * 0.09, y: foot.maxY,
                               width: r.width * 0.18, height: r.height * 0.22)
            iron.setFill(); NSBezierPath(rect: foot).fill(); NSBezierPath(rect: waist).fill()
            let anvil = [NSPoint(x: r.minX + r.width * 0.20, y: waist.maxY),
                         NSPoint(x: r.maxX - r.width * 0.08, y: waist.maxY),
                         NSPoint(x: r.maxX - r.width * 0.22, y: waist.maxY + r.height * 0.19),
                         NSPoint(x: r.minX + r.width * 0.14, y: waist.maxY + r.height * 0.15)]
            strokePoly(anvil, iron, width: 1)
            tick(anvil[3], anvil[2], lighten(iron, 0.32), width: max(1, r.width * 0.035))
        case 100: // Herbalist: low table, mortar, bottle and leafy bundle.
            let top = NSRect(x: r.minX + r.width * 0.10, y: topY,
                             width: r.width * 0.80, height: r.height * 0.13)
            wood.setFill(); NSBezierPath(roundedRect: top, xRadius: 2, yRadius: 2).fill()
            for x in [top.minX + r.width * 0.10, top.maxX - r.width * 0.16] {
                NSBezierPath(rect: NSRect(x: x, y: r.minY + r.height * 0.12,
                                          width: r.width * 0.08, height: r.height * 0.32)).fill()
            }
            let bowl = NSBezierPath()
            bowl.move(to: NSPoint(x: r.midX - r.width * 0.17, y: top.maxY + r.height * 0.16))
            bowl.line(to: NSPoint(x: r.midX + r.width * 0.17, y: top.maxY + r.height * 0.16))
            bowl.curve(to: NSPoint(x: r.midX, y: top.maxY),
                       controlPoint1: NSPoint(x: r.midX + r.width * 0.14, y: top.maxY),
                       controlPoint2: NSPoint(x: r.midX + r.width * 0.06, y: top.maxY))
            bowl.close(); itemColor(0.66, 0.39, 0.25).setFill(); bowl.fill()
            tick(NSPoint(x: r.midX, y: top.maxY + r.height * 0.10),
                 NSPoint(x: r.midX + r.width * 0.15, y: r.maxY - r.height * 0.06),
                 wood, width: max(2, r.width * 0.07))
            for dx in [-0.28, 0.28] as [CGFloat] {
                fillCircle(NSPoint(x: r.midX + r.width * dx, y: top.maxY + r.height * 0.12),
                           r.width * 0.09, itemColor(0.32, 0.64, 0.28), outline: nil)
            }
        default: // Builder: trestles, long plank and toothed hand saw.
            let plank = NSRect(x: r.minX + r.width * 0.08, y: topY,
                               width: r.width * 0.84, height: r.height * 0.16)
            lighten(wood, 0.20).setFill(); NSBezierPath(roundedRect: plank, xRadius: 2, yRadius: 2).fill()
            for x in [plank.minX + r.width * 0.16, plank.maxX - r.width * 0.20] {
                tick(NSPoint(x: x - r.width * 0.09, y: r.minY + r.height * 0.12),
                     NSPoint(x: x + r.width * 0.09, y: plank.minY), wood,
                     width: max(2, r.width * 0.08))
                tick(NSPoint(x: x + r.width * 0.09, y: r.minY + r.height * 0.12),
                     NSPoint(x: x - r.width * 0.09, y: plank.minY), wood,
                     width: max(2, r.width * 0.08))
            }
            let saw = [NSPoint(x: r.minX + r.width * 0.20, y: plank.maxY + r.height * 0.04),
                       NSPoint(x: r.maxX - r.width * 0.14, y: r.maxY - r.height * 0.10),
                       NSPoint(x: r.maxX - r.width * 0.22, y: plank.maxY + r.height * 0.01)]
            strokePoly(saw, iron, width: 1)
            drawHandle(in: r, from: saw[1],
                       to: NSPoint(x: r.maxX - r.width * 0.05, y: r.maxY - r.height * 0.02),
                       thickness: max(2, r.width * 0.08))
        }
    }

    private func drawCommunalBench(in r: NSRect) {
        let wood = itemColor(0.60, 0.42, 0.22)
        let dark = shade(wood, 0.62)
        let seat = NSRect(x: r.minX + r.width * 0.10, y: r.minY + r.height * 0.38,
                          width: r.width * 0.80, height: r.height * 0.16)
        wood.setFill(); NSBezierPath(roundedRect: seat, xRadius: 3, yRadius: 3).fill()
        for x in [seat.minX + r.width * 0.10, seat.maxX - r.width * 0.16] {
            dark.setFill()
            NSBezierPath(rect: NSRect(x: x, y: r.minY + r.height * 0.10,
                                      width: r.width * 0.07, height: r.height * 0.30)).fill()
        }
        let back = NSRect(x: seat.minX + r.width * 0.04, y: seat.maxY + r.height * 0.08,
                          width: seat.width - r.width * 0.08, height: r.height * 0.20)
        lighten(wood, 0.12).setFill()
        NSBezierPath(roundedRect: back, xRadius: 3, yRadius: 3).fill()
        tick(NSPoint(x: back.minX, y: seat.maxY), NSPoint(x: back.minX, y: back.maxY), dark,
             width: max(2, r.width * 0.07))
        tick(NSPoint(x: back.maxX, y: seat.maxY), NSPoint(x: back.maxX, y: back.maxY), dark,
             width: max(2, r.width * 0.07))
    }

    private func drawBroomStand(in r: NSRect) {
        let wood = itemColor(0.50, 0.31, 0.15)
        let straw = itemColor(0.86, 0.67, 0.24)
        let iron = itemColor(0.30, 0.32, 0.35)
        wood.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + r.width * 0.54, y: r.minY + r.height * 0.10,
                                         width: r.width * 0.28, height: r.height * 0.10),
                     xRadius: 2, yRadius: 2).fill()
        tick(NSPoint(x: r.minX + r.width * 0.70, y: r.minY + r.height * 0.16),
             NSPoint(x: r.minX + r.width * 0.70, y: r.maxY - r.height * 0.10), wood,
             width: max(2, r.width * 0.08))
        tick(NSPoint(x: r.minX + r.width * 0.48, y: r.maxY - r.height * 0.15),
             NSPoint(x: r.minX + r.width * 0.82, y: r.maxY - r.height * 0.15), iron,
             width: max(1, r.width * 0.05))
        tick(NSPoint(x: r.minX + r.width * 0.27, y: r.minY + r.height * 0.30),
             NSPoint(x: r.minX + r.width * 0.53, y: r.maxY - r.height * 0.08), wood,
             width: max(2, r.width * 0.065))
        let bristles = NSBezierPath()
        bristles.move(to: NSPoint(x: r.minX + r.width * 0.10, y: r.minY + r.height * 0.10))
        bristles.line(to: NSPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.10))
        bristles.line(to: NSPoint(x: r.minX + r.width * 0.32, y: r.minY + r.height * 0.34))
        bristles.line(to: NSPoint(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.34))
        bristles.close(); straw.setFill(); bristles.fill()
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

    private func drawSword(in r: NSRect, tint: NSColor) {
        // A classic sword icon: diagonal handle lower-left → upper-right, blade
        // widens into a flat tip, with a crossguard at the grip/blade junction.
        let handleA = NSPoint(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.14)
        let handleB = NSPoint(x: r.midX - r.width * 0.04, y: r.midY - r.height * 0.06)
        drawHandle(in: r, from: handleA, to: handleB, thickness: max(2, r.width * 0.12))

        // Blade: runs from the crossguard area to the tip (upper-right).
        let bladeBase = NSPoint(x: r.midX + r.width * 0.00, y: r.midY + r.height * 0.01)
        let bladeTip  = NSPoint(x: r.maxX - r.width * 0.16, y: r.maxY - r.height * 0.18)
        let bw = r.width * 0.07     // half-width of the blade at the base
        let perp = NSPoint(x: -(bladeTip.y - bladeBase.y), y: bladeTip.x - bladeBase.x)
        let perpLen = sqrt(perp.x * perp.x + perp.y * perp.y)
        let pn = perpLen > 0 ? NSPoint(x: perp.x / perpLen, y: perp.y / perpLen) : NSPoint(x: 0, y: 1)
        let bladeShape = [
            NSPoint(x: bladeBase.x + pn.x * bw, y: bladeBase.y + pn.y * bw),
            NSPoint(x: bladeBase.x - pn.x * bw, y: bladeBase.y - pn.y * bw),
            bladeTip,
        ]
        strokePoly(bladeShape, tint, width: 1)
        // Edge highlight along the upper face of the blade.
        let edgePath = NSBezierPath()
        edgePath.move(to: NSPoint(x: bladeBase.x + pn.x * bw, y: bladeBase.y + pn.y * bw))
        edgePath.line(to: bladeTip)
        lighten(tint, 0.50).setStroke(); edgePath.lineWidth = max(1, r.width * 0.05); edgePath.stroke()

        // Crossguard: a short perpendicular bar at the blade/handle junction.
        let cgCenter = NSPoint(x: (bladeBase.x + handleB.x) / 2, y: (bladeBase.y + handleB.y) / 2)
        let cgLen = r.width * 0.24
        let cgPath = NSBezierPath(); cgPath.lineCapStyle = .round
        cgPath.move(to: NSPoint(x: cgCenter.x - pn.x * cgLen, y: cgCenter.y - pn.y * cgLen))
        cgPath.line(to: NSPoint(x: cgCenter.x + pn.x * cgLen, y: cgCenter.y + pn.y * cgLen))
        shade(tint, 0.75).setStroke(); cgPath.lineWidth = max(2, r.width * 0.10); cgPath.stroke()
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

    func drawHearts(value: Float, max: Int, at origin: NSPoint) {
        let full = Int(value.rounded())
        let step = 16 * hudScale, sz = 12 * hudScale
        for i in 0..<max / 2 {
            let filled = (i * 2) < full
            (filled ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.4)).setFill()
            let r = NSRect(x: origin.x + CGFloat(i) * step, y: origin.y, width: sz, height: sz)
            NSBezierPath(ovalIn: r).fill()
        }
    }

    func drawBubbles(value: Float, at origin: NSPoint) {
        // 10 air bubbles; fill count tracks remaining oxygen (1 = full).
        let count = 10
        let step = 16 * hudScale, sz = 12 * hudScale
        let filled = Int((max(0, min(1, value)) * Float(count)).rounded())
        for i in 0..<count {
            let r = NSRect(x: origin.x + CGFloat(i) * step, y: origin.y, width: sz, height: sz)
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

    func drawText(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, bold: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .strokeColor: NSColor.black, .strokeWidth: -2.0,
        ]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }
}
