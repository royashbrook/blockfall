// ============================================================================
// Blockfall — MinimapView (#187)
// A always-on corner minimap, the navigation aid people love in Minecraft mods.
// North-up circular chart centred on the player: nearby home / village / totem
// markers as coloured dots, a heading arrow for the player, N/E/S/W ticks, and a
// live compass heading readout. Display-only (never eats clicks): it reads the
// renderer's cheap player state every tick and refreshes the marker list (via the
// same bf_map_query the big map uses) a couple of times a second. Toggle in the
// pause menu; hidden while the big map or a modal overlay is open.
// ============================================================================
import AppKit

final class MinimapView: NSView {
    weak var renderer: Renderer?

    private var markers: [MapView.Marker] = []
    private var period: Int = 32768
    private var px: Float = 0
    private var pz: Float = 0
    private var facing: Float = 0

    // World blocks from centre to the ring edge. ~1400 shows the neighbours you
    // just walked past without turning the dots into confetti.
    private let worldRadius: Float = 1400

    private var tick: Timer?
    private var frame30 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // #191: no raised zPosition — it must sit UNDER the loading overlay so it
        // does not peek through the load screen. The app reveals it (isHidden) once
        // loading lifts.
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // Display-only: let every click fall through to the game view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    func start() {
        refreshMarkers()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isHidden, let r = self.renderer else { return }
            self.px = r.playerWorldX
            self.pz = r.playerWorldZ
            self.facing = r.playerWorldFacing
            self.frame30 += 1
            if self.frame30 >= 30 { self.frame30 = 0; self.refreshMarkers() }  // ~2s
            self.needsDisplay = true
        }
    }

    func stop() { tick?.invalidate(); tick = nil }
    deinit { tick?.invalidate() }

    // Harness hook (--mapshot): draw from fixed sample data, no live renderer.
    func debugPreview(markers: [MapView.Marker], playerX: Float, playerZ: Float,
                      facing: Float, period: Int) {
        self.markers = markers; self.px = playerX; self.pz = playerZ
        self.facing = facing; self.period = period
        needsDisplay = true
    }

    private func refreshMarkers() {
        guard let snap = renderer?.mapQuery() else { return }
        markers = snap.markers
        period = snap.period
    }

    private func wrapSigned(_ d: Int) -> Int {
        let p = period
        return ((d + p / 2) % p + p) % p - p / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let c = CGPoint(x: b.midX, y: b.midY)
        let radius = min(b.width, b.height) / 2 - 6
        let scale = CGFloat(radius) / CGFloat(worldRadius)

        // Round chart: soft dark disc + parchment-tinted rim so it reads friendly.
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                               width: radius * 2, height: radius * 2))
        NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.16, alpha: 0.74).setFill()
        disc.fill()

        ctx.saveGState()
        disc.addClip()
        // Faint concentric range ring at half radius for a distance cue.
        let mid = NSBezierPath(ovalIn: NSRect(x: c.x - radius / 2, y: c.y - radius / 2,
                                              width: radius, height: radius))
        NSColor.white.withAlphaComponent(0.08).setStroke()
        mid.lineWidth = 1
        mid.stroke()

        // Marker dots (north = -z is up). Nearest-image so a town across the seam
        // still shows on the correct side.
        for m in markers {
            let dx = CGFloat(wrapSigned(Int(m.x) - Int(px.rounded()))) * scale
            let dz = CGFloat(wrapSigned(Int(m.z) - Int(pz.rounded()))) * scale
            let pt = CGPoint(x: c.x + dx, y: c.y - dz)
            if hypot(pt.x - c.x, pt.y - c.y) > radius - 2 { continue }  // off-chart
            dot(at: pt, kind: m.kind)
        }
        ctx.restoreGState()

        // Rim.
        NSColor(calibratedRed: 0.34, green: 0.26, blue: 0.16, alpha: 0.95).setStroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                              width: radius * 2, height: radius * 2))
        rim.lineWidth = 4
        rim.stroke()

        // N/E/S/W ticks + a bold N (map is north-up, so they are fixed).
        for (ang, label, big) in [(CGFloat.pi / 2, "N", true), (0, "E", false),
                                  (-CGFloat.pi / 2, "S", false), (CGFloat.pi, "W", false)] {
            let outer = CGPoint(x: c.x + cos(ang) * radius, y: c.y + sin(ang) * radius)
            let inner = CGPoint(x: c.x + cos(ang) * (radius - 7), y: c.y + sin(ang) * (radius - 7))
            let tickPath = NSBezierPath()
            tickPath.move(to: inner); tickPath.line(to: outer)
            (big ? NSColor(calibratedRed: 0.95, green: 0.4, blue: 0.35, alpha: 1)
                 : NSColor.white.withAlphaComponent(0.6)).setStroke()
            tickPath.lineWidth = big ? 3 : 2
            tickPath.stroke()
            let lp = CGPoint(x: c.x + cos(ang) * (radius + 11), y: c.y + sin(ang) * (radius + 11))
            drawLabel(label, at: lp, size: big ? 15 : 12,
                      color: big ? NSColor(calibratedRed: 0.98, green: 0.5, blue: 0.45, alpha: 1) : .white)
        }

        // Player heading arrow at centre.
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(facing) + .pi)
        let a = NSBezierPath()
        a.move(to: NSPoint(x: 0, y: 10)); a.line(to: NSPoint(x: 7, y: -8))
        a.line(to: NSPoint(x: 0, y: -3)); a.line(to: NSPoint(x: -7, y: -8)); a.close()
        NSColor.white.setFill(); a.fill()
        NSColor.black.setStroke(); a.lineWidth = 2; a.stroke()
        ctx.restoreGState()

        // Live heading pill at the top-right of the ring, clear of the N/E/S/W
        // letters, so kids can read the exact facing as a word.
        let pill = headingText()
        drawLabel(pill, at: CGPoint(x: c.x + radius * 0.52, y: c.y + radius * 0.52),
                  size: 13, color: NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.6, alpha: 1))
    }

    private func dot(at p: CGPoint, kind: UInt32) {
        let (col, r): (NSColor, CGFloat)
        switch kind {
        case 0: col = NSColor(calibratedRed: 0.90, green: 0.42, blue: 0.30, alpha: 1); r = 4.5 // home
        case 1: col = NSColor(calibratedRed: 0.70, green: 0.52, blue: 0.26, alpha: 1); r = 4    // village
        case 4: col = NSColor(calibratedRed: 0.88, green: 0.55, blue: 0.22, alpha: 1); r = 5    // town
        case 3: col = NSColor(calibratedRed: 0.62, green: 0.63, blue: 0.72, alpha: 1); r = 5.5 // city (#221): bigger grey keep dot
        case 5: col = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.24, alpha: 1); r = 6.5 // fortified City: gold sword-badge dot
        default: col = NSColor(calibratedRed: 0.70, green: 0.54, blue: 1.0, alpha: 1); r = 4    // totem
        }
        NSColor.black.withAlphaComponent(0.7).setStroke()
        col.setFill()
        let d = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        d.fill(); d.lineWidth = 1.5; d.stroke()
        if kind == 5 {
            drawLabel("⚔", at: p, size: 8, color: .black)
        }
    }

    // 8-point compass from the player's world facing (north = -z).
    private func headingText() -> String {
        let bearing = atan2(sin(facing), -cos(facing))   // 0 = N, +cw
        var deg = bearing * 180 / .pi
        if deg < 0 { deg += 360 }
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return dirs[Int((deg / 45).rounded()) % 8]
    }

    private func drawLabel(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: color,
            .strokeColor: NSColor.black.withAlphaComponent(0.85), .strokeWidth: -3.5,
        ]
        let sz = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2),
                             withAttributes: attrs)
    }
}
