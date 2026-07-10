// ============================================================================
// Blockfall — MapView (#182 world map + warp totems)
// A full-screen overlay showing the WHOLE torus planet: explored cells drawn
// as light parchment, unexplored as dark, always centred on the player
// (nearest-image on both axes, so the map wraps seamlessly at the world seam).
// Markers: home (house), visited villages (roof), warp totems (crystal
// diamond) — all big, kid-friendly icons with generous tap targets and zero
// typing. Tapping a marker shows a confirmation chip; confirming runs a short
// magical charge-up ring, then teleports and closes.
//
// The view is fed once when opened (bf_map_query via the Renderer) and draws
// from that snapshot — no per-frame engine cost while the map is up. The
// world is paused underneath (same pause path as the Esc menu, #127).
// ============================================================================
import AppKit
import CBlockcore

final class MapView: NSView {
    // One marker row (unpacked from bf_map_marker by the Renderer).
    struct Marker {
        let x: Int32
        let z: Int32
        let kind: UInt32   // 0 home, 1 village, 2 totem
        let id: UInt32
        let name: String
    }

    // Snapshot pushed by the app when the map opens.
    var explored: [UInt8] = []          // BF_MAP_EXPLORED_BYTES bits
    var period: Int = 32768             // torus period in blocks
    var cellSize: Int = 64              // blocks per explored cell
    var cells: Int = 512                // cells per axis
    var markers: [Marker] = []
    var playerX: Float = 0
    var playerZ: Float = 0
    var playerFacing: Float = 0         // yaw radians (atan2(fwd.x, fwd.z))

    // Hooks wired by the app delegate.
    var onClose: (() -> Void)?
    var onTeleport: ((UInt32) -> Void)?
    var onChargeStart: (() -> Void)?    // audio flourish at charge begin

    // Zoom: how many world blocks the map square spans. Default shows the
    // player's local region (explored blobs read BIG); zooming out to `period`
    // shows the whole planet. Buttons + scroll wheel; clamped power-of-two.
    var viewSpan: Int = 4096
    private let kMinSpan = 1024
    private var zoomInRect: NSRect = .zero
    private var zoomOutRect: NSRect = .zero

    // Interaction state.
    private var markerPoints: [(pt: CGPoint, idx: Int)] = []
    private var labelRects: [NSRect] = []
    private var selectedMarker: Int? = nil      // index into markers (chip shown)
    private var goRect: NSRect = .zero          // the confirmation chip's Go button
    private var chargeStart: CFTimeInterval = 0 // 0 = not charging
    private var chargeTimer: Timer?
    private var chargeMarker: Int? = nil
    private let kChargeSecs: CFTimeInterval = 1.5

    // The map backdrop image, built once per open (player-centred sampling).
    private var mapImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    deinit { chargeTimer?.invalidate() }

    // Call after the snapshot fields are set (and once on open).
    func rebuild() {
        mapImage = buildMapImage()
        needsDisplay = true
    }

    // ---- geometry ----------------------------------------------------------

    private var mapRect: NSRect {
        // Leave room for the title above and the hint below the parchment frame.
        let side = min(bounds.width - 120, bounds.height - 190)
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2 - 14,
                      width: side, height: side)
    }

    private func wrapSigned(_ d: Int) -> Int {
        let p = period
        return ((d + p / 2) % p + p) % p - p / 2
    }

    // World block position -> view point (player centred, north (-z) up).
    private func mapPoint(x: Int32, z: Int32) -> CGPoint {
        let r = mapRect
        let scale = r.width / CGFloat(viewSpan)
        let dx = CGFloat(wrapSigned(Int(x) - Int(playerX.rounded())))
        let dz = CGFloat(wrapSigned(Int(z) - Int(playerZ.rounded())))
        return CGPoint(x: r.midX + dx * scale, y: r.midY - dz * scale)
    }

    // ---- map backdrop ------------------------------------------------------

    // An n x n RGBA image (n = cells visible at the current zoom) sampled so
    // the player's cell is the centre pixel: parchment for explored, deep
    // night-blue for unexplored. The torus wrap is handled by the modular
    // sampling, so the edges join seamlessly at full zoom-out.
    private func buildMapImage() -> CGImage? {
        let total = cells
        let n = max(2, min(total, viewSpan / cellSize))
        guard total > 0, explored.count >= total * total / 8 else { return nil }
        let pcx = ((Int(playerX.rounded()) % period + period) % period) / cellSize
        let pcz = ((Int(playerZ.rounded()) % period + period) % period) / cellSize
        var data = [UInt8](repeating: 0, count: n * n * 4)
        // Parchment + dark palettes, with a mild checker so big explored areas
        // still read as a grid of "map squares" (kid-legible scale cue).
        for j in 0..<n {           // j = image row, top row = north (smaller z)
            let cz = ((pcz - n / 2 + j) % total + total) % total
            for i in 0..<n {
                let cx = ((pcx - n / 2 + i) % total + total) % total
                let bit = cz * total + cx
                let on = (explored[bit >> 3] & (1 << (bit & 7))) != 0
                let checker = (cx ^ cz) & 1 == 0
                let o = (j * n + i) * 4
                if on {
                    data[o] = checker ? 226 : 218      // R parchment
                    data[o + 1] = checker ? 208 : 199  // G
                    data[o + 2] = checker ? 168 : 158  // B
                } else {
                    data[o] = checker ? 24 : 21
                    data[o + 1] = checker ? 27 : 24
                    data[o + 2] = checker ? 38 : 34
                }
                data[o + 3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: n * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // ---- drawing -----------------------------------------------------------

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds

        // Dim the world behind and frame the map like a big friendly chart.
        ctx.setFillColor(NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 0.92).cgColor)
        ctx.fill(b)

        let r = mapRect
        // Parchment frame.
        let frame = r.insetBy(dx: -14, dy: -14)
        NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 16, yRadius: 16).fill()

        // The planet: explored parchment / unexplored dark, player centred.
        if let img = mapImage {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            // CGImage row 0 (north) draws at the TOP of the rect in this
            // unflipped view when we flip the CTM around the rect's centre.
            ctx.translateBy(x: 0, y: r.midY * 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: r)
            ctx.restoreGState()
        } else {
            NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
            ctx.fill(r)
        }

        // Title + hint.
        drawCenteredText("World Map", at: NSPoint(x: b.midX, y: frame.maxY + 16),
                         size: 30, weight: .heavy)
        drawCenteredText("Click a marker to travel  •  + / \u{2212} to zoom  •  M or Esc to close",
                         at: NSPoint(x: b.midX, y: frame.minY - 34), size: 15, weight: .semibold)

        // Markers (big icons + names). Collect hit points as we draw.
        markerPoints = []
        labelRects = []
        for (idx, m) in markers.enumerated() {
            let p = mapPoint(x: m.x, z: m.z)
            guard r.insetBy(dx: -6, dy: -6).contains(p) else { continue }
            markerPoints.append((p, idx))
            drawMarkerIcon(m, at: p, ctx: ctx)
        }

        // Zoom buttons (bottom-right, inside the frame): big friendly + / −.
        drawZoomButtons(in: r)

        // The player: a bold arrow at the map centre, rotated to the facing.
        drawPlayerArrow(at: CGPoint(x: r.midX, y: r.midY), ctx: ctx)

        // Compass rose (top-left, inside the frame): fixed N/E/S/W with a red
        // needle showing which way the player is looking.
        drawCompass(in: r, ctx: ctx)

        // Confirmation chip / charge ring on top.
        if let ci = chargeMarker, chargeStart > 0 {
            drawChargeRing(for: markers[ci], ctx: ctx)
        } else if let si = selectedMarker {
            drawConfirmChip(for: markers[si])
        } else {
            goRect = .zero
        }
    }

    private func drawCenteredText(_ s: String, at p: NSPoint, size: CGFloat,
                                  weight: NSFont.Weight, color: NSColor = .white) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .strokeColor: NSColor.black.withAlphaComponent(0.8), .strokeWidth: -3.0,
        ]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y), withAttributes: attrs)
    }

    private func drawMarkerIcon(_ m: Marker, at p: CGPoint, ctx: CGContext) {
        let s: CGFloat = 13   // icon half-size — big and tappable
        switch m.kind {
        case 0: // HOME: a little house (warm red walls, dark roof).
            let wall = NSRect(x: p.x - s * 0.7, y: p.y - s * 0.8, width: s * 1.4, height: s * 0.95)
            NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.30, alpha: 1).setFill()
            NSBezierPath(rect: wall).fill()
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: p.x - s, y: wall.maxY))
            roof.line(to: NSPoint(x: p.x, y: p.y + s))
            roof.line(to: NSPoint(x: p.x + s, y: wall.maxY))
            roof.close()
            NSColor(calibratedRed: 0.45, green: 0.25, blue: 0.16, alpha: 1).setFill()
            roof.fill()
            outline(roof); outline(NSBezierPath(rect: wall))
        case 1: // VILLAGE: two little roofs side by side.
            for dx in [-s * 0.55, s * 0.55] {
                let roof = NSBezierPath()
                roof.move(to: NSPoint(x: p.x + dx - s * 0.62, y: p.y - s * 0.55))
                roof.line(to: NSPoint(x: p.x + dx, y: p.y + s * 0.75))
                roof.line(to: NSPoint(x: p.x + dx + s * 0.62, y: p.y - s * 0.55))
                roof.close()
                NSColor(calibratedRed: 0.62, green: 0.44, blue: 0.24, alpha: 1).setFill()
                roof.fill()
                outline(roof)
            }
        case 3: // CITY (#221): a walled keep, wall slab + two towers + centre roof.
            let wall = NSRect(x: p.x - s * 1.1, y: p.y - s * 0.7, width: s * 2.2, height: s * 0.7)
            NSColor(calibratedRed: 0.55, green: 0.56, blue: 0.62, alpha: 1).setFill()
            NSBezierPath(rect: wall).fill()
            for tx in [p.x - s * 0.95, p.x + s * 0.95] {
                let tower = NSRect(x: tx - s * 0.22, y: p.y - s * 0.7, width: s * 0.44, height: s * 1.3)
                NSColor(calibratedRed: 0.62, green: 0.63, blue: 0.70, alpha: 1).setFill()
                NSBezierPath(rect: tower).fill()
                outline(NSBezierPath(rect: tower))
            }
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: p.x - s * 0.55, y: p.y + s * 0.05))
            roof.line(to: NSPoint(x: p.x, y: p.y + s * 0.85))
            roof.line(to: NSPoint(x: p.x + s * 0.55, y: p.y + s * 0.05))
            roof.close()
            NSColor(calibratedRed: 0.72, green: 0.32, blue: 0.28, alpha: 1).setFill()
            roof.fill()
            outline(roof); outline(NSBezierPath(rect: wall))
        default: // TOTEM: a glowing crystal diamond.
            let d = NSBezierPath()
            d.move(to: NSPoint(x: p.x, y: p.y + s))
            d.line(to: NSPoint(x: p.x + s * 0.72, y: p.y))
            d.line(to: NSPoint(x: p.x, y: p.y - s))
            d.line(to: NSPoint(x: p.x - s * 0.72, y: p.y))
            d.close()
            // Soft glow behind the crystal so it reads as magic.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10,
                          color: NSColor(calibratedRed: 0.6, green: 0.45, blue: 1.0, alpha: 0.9).cgColor)
            NSColor(calibratedRed: 0.68, green: 0.52, blue: 1.0, alpha: 1).setFill()
            d.fill()
            ctx.restoreGState()
            outline(d)
        }
        // Name label under the icon — skipped when it would collide with an
        // already-placed label (declutter when markers crowd at zoom-out).
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12)]
        let sz = (m.name as NSString).size(withAttributes: attrs)
        let lr = NSRect(x: p.x - sz.width / 2 - 2, y: p.y - s - 20,
                        width: sz.width + 4, height: sz.height + 4)
        if !labelRects.contains(where: { $0.intersects(lr) }) {
            labelRects.append(lr)
            drawCenteredText(m.name, at: NSPoint(x: p.x, y: p.y - s - 18), size: 12, weight: .bold)
        }
    }

    private func drawZoomButtons(in r: NSRect) {
        let d: CGFloat = 46
        zoomInRect = NSRect(x: r.maxX - d - 12, y: r.minY + 12 + d + 10, width: d, height: d)
        zoomOutRect = NSRect(x: r.maxX - d - 12, y: r.minY + 12, width: d, height: d)
        for (rect, glyph, enabled) in [(zoomInRect, "+", viewSpan > kMinSpan),
                                       (zoomOutRect, "\u{2212}", viewSpan < period)] {
            NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18,
                    alpha: enabled ? 0.92 : 0.45).setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.withAlphaComponent(enabled ? 1 : 0.4).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2
            ring.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 28, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(enabled ? 1 : 0.4),
            ]
            let sz = (glyph as NSString).size(withAttributes: attrs)
            (glyph as NSString).draw(at: NSPoint(x: rect.midX - sz.width / 2,
                                                 y: rect.midY - sz.height / 2),
                                     withAttributes: attrs)
        }
    }

    private func setZoom(span: Int) {
        let clamped = max(kMinSpan, min(period, span))
        guard clamped != viewSpan else { return }
        viewSpan = clamped
        selectedMarker = nil
        rebuild()
    }

    private func outline(_ path: NSBezierPath) {
        NSColor.black.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawCompass(in r: NSRect, ctx: CGContext) {
        let rad: CGFloat = 34
        let c = CGPoint(x: r.minX + rad + 14, y: r.maxY - rad - 14)
        // Disc.
        NSColor(calibratedRed: 0.14, green: 0.11, blue: 0.07, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)).fill()
        NSColor(calibratedRed: 0.86, green: 0.74, blue: 0.5, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
        ring.lineWidth = 2.5
        ring.stroke()
        // N/E/S/W letters (north up).
        for (ang, s) in [(CGFloat.pi / 2, "N"), (0, "E"), (-CGFloat.pi / 2, "S"), (CGFloat.pi, "W")] {
            let lp = NSPoint(x: c.x + cos(ang) * (rad - 11), y: c.y + sin(ang) * (rad - 11) - 6)
            drawCenteredText(s, at: lp, size: 12, weight: .heavy,
                             color: s == "N" ? NSColor(calibratedRed: 0.98, green: 0.5, blue: 0.45, alpha: 1) : .white)
        }
        // Needle in the facing direction (map is north = -z up).
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(playerFacing) + .pi)
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: 0, y: rad - 12))
        needle.line(to: NSPoint(x: 5, y: 0))
        needle.line(to: NSPoint(x: -5, y: 0))
        needle.close()
        NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.32, alpha: 1).setFill()
        needle.fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 0, y: -(rad - 12)))
        tail.line(to: NSPoint(x: 5, y: 0))
        tail.line(to: NSPoint(x: -5, y: 0))
        tail.close()
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        tail.fill()
        ctx.restoreGState()
    }

    private func drawPlayerArrow(at p: CGPoint, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        // World yaw (atan2(fwd.x, fwd.z)): 0 faces +z (map DOWN, since north=-z
        // is up). Rotate so the arrow points where the player looks.
        ctx.rotate(by: CGFloat(playerFacing) + .pi)
        let a = NSBezierPath()
        a.move(to: NSPoint(x: 0, y: 12))
        a.line(to: NSPoint(x: 8, y: -9))
        a.line(to: NSPoint(x: 0, y: -4))
        a.line(to: NSPoint(x: -8, y: -9))
        a.close()
        NSColor.white.setFill()
        a.fill()
        NSColor.black.setStroke()
        a.lineWidth = 2
        a.stroke()
        ctx.restoreGState()
    }

    private func drawConfirmChip(for m: Marker) {
        let p = mapPoint(x: m.x, z: m.z)
        let msg = "Travel to \(m.name)?"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white,
        ]
        let sz = (msg as NSString).size(withAttributes: attrs)
        let goW: CGFloat = 64, chipH: CGFloat = 44, pad: CGFloat = 14
        let w = sz.width + goW + pad * 3
        var chip = NSRect(x: p.x - w / 2, y: p.y + 22, width: w, height: chipH)
        // Keep the chip on screen.
        chip.origin.x = max(10, min(bounds.maxX - w - 10, chip.origin.x))
        if chip.maxY > bounds.maxY - 10 { chip.origin.y = p.y - 22 - chipH }
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 12, yRadius: 12).fill()
        (msg as NSString).draw(at: NSPoint(x: chip.minX + pad, y: chip.midY - sz.height / 2),
                               withAttributes: attrs)
        goRect = NSRect(x: chip.maxX - goW - pad + 4, y: chip.minY + 7, width: goW, height: chipH - 14)
        NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.42, alpha: 1).setFill()
        NSBezierPath(roundedRect: goRect, xRadius: 9, yRadius: 9).fill()
        let goAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white,
        ]
        let goSz = ("Go!" as NSString).size(withAttributes: goAttrs)
        ("Go!" as NSString).draw(at: NSPoint(x: goRect.midX - goSz.width / 2,
                                             y: goRect.midY - goSz.height / 2),
                                 withAttributes: goAttrs)
    }

    private func drawChargeRing(for m: Marker, ctx: CGContext) {
        let p = mapPoint(x: m.x, z: m.z)
        let t = CGFloat(min(1, (CACurrentMediaTime() - chargeStart) / kChargeSecs))
        // A growing magic ring + progress arc around the destination.
        let radius: CGFloat = 26 + t * 10
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 14,
                      color: NSColor(calibratedRed: 0.62, green: 0.48, blue: 1.0, alpha: 0.9).cgColor)
        let ring = NSBezierPath()
        ring.appendArc(withCenter: p, radius: radius, startAngle: 90,
                       endAngle: 90 - 360 * t, clockwise: true)
        NSColor(calibratedRed: 0.72, green: 0.58, blue: 1.0, alpha: 1).setStroke()
        ring.lineWidth = 6
        ring.lineCapStyle = .round
        ring.stroke()
        ctx.restoreGState()
        drawCenteredText("Warping…", at: NSPoint(x: p.x, y: p.y + radius + 10),
                         size: 15, weight: .heavy)
        // Sparkle dots orbiting the ring for a bit of magic.
        for k in 0..<6 {
            let a = CGFloat(k) / 6 * 2 * .pi + t * 6
            let sp = CGPoint(x: p.x + cos(a) * (radius + 8), y: p.y + sin(a) * (radius + 8))
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: sp.x - 2, y: sp.y - 2, width: 4, height: 4)).fill()
        }
    }

    // ---- interaction --------------------------------------------------------

    override func mouseDown(with e: NSEvent) {
        guard chargeStart == 0 else { return }   // no clicks mid-charge
        let p = convert(e.locationInWindow, from: nil)
        // Zoom buttons.
        if zoomInRect.contains(p) { setZoom(span: viewSpan / 2); return }
        if zoomOutRect.contains(p) { setZoom(span: viewSpan * 2); return }
        // Confirm chip first.
        if selectedMarker != nil, goRect != .zero, goRect.insetBy(dx: -8, dy: -8).contains(p) {
            beginCharge()
            return
        }
        // Marker hit (generous radius).
        var best: (idx: Int, d: CGFloat)? = nil
        for (pt, idx) in markerPoints {
            let d = hypot(pt.x - p.x, pt.y - p.y)
            if d < 30 && (best == nil || d < best!.d) { best = (idx, d) }
        }
        if let hit = best {
            selectedMarker = hit.idx
        } else {
            selectedMarker = nil   // click elsewhere cancels the chip
        }
        needsDisplay = true
    }

    private func beginCharge() {
        guard let si = selectedMarker else { return }
        chargeMarker = si
        selectedMarker = nil
        chargeStart = CACurrentMediaTime()
        onChargeStart?()
        chargeTimer?.invalidate()
        chargeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            self.needsDisplay = true
            if CACurrentMediaTime() - self.chargeStart >= self.kChargeSecs {
                self.chargeTimer?.invalidate()
                self.chargeTimer = nil
                let id = self.chargeMarker.map { self.markers[$0].id }
                self.chargeMarker = nil
                self.chargeStart = 0
                if let id = id { self.onTeleport?(id) }
            }
        }
    }

    override func scrollWheel(with e: NSEvent) {
        guard chargeStart == 0 else { return }
        if e.scrollingDeltaY > 0.5 { setZoom(span: viewSpan / 2) }
        else if e.scrollingDeltaY < -0.5 { setZoom(span: viewSpan * 2) }
    }

    // Harness hook (--mapshot): show the confirmation chip for a marker index.
    func debugSelectMarker(_ idx: Int) {
        guard idx >= 0 && idx < markers.count else {
            selectedMarker = nil
            needsDisplay = true
            return
        }
        selectedMarker = idx
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        // M (46) or Esc (53) closes. Esc also cancels a selection chip first.
        if e.keyCode == 53 || e.keyCode == 46 {
            if chargeStart > 0 { return }   // committed; let the warp finish
            if selectedMarker != nil && e.keyCode == 53 {
                selectedMarker = nil
                needsDisplay = true
                return
            }
            onClose?()
        }
    }
}
