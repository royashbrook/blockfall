// #71 — basic character appearance customization (skin, shirt, hair colour + style,
// nose, mouth). Kept deliberately simple and kid-friendly: each trait is an index into a
// small preset list, so the whole look is six small numbers that persist in UserDefaults
// and (later, Phase 2) replicate to co-op peers. The same presets drive both the 2D editor
// portrait and the in-world character, so what you pick is what you get.
import AppKit
import simd

struct CharacterAppearance: Equatable {
    var skin: Int      = 1   // index into skinPalette
    var shirt: Int     = 4   // index into shirtPalette
    var hairColor: Int = 1   // index into hairPalette
    var hairStyle: Int = 0   // index into hairStyleNames
    var nose: Int      = 0   // index into noseNames
    var mouth: Int     = 0   // index into mouthNames

    // ---- preset tables (common-sense, nothing crazy) -----------------------
    static let skinPalette: [SIMD3<Float>] = [
        SIMD3(0.99, 0.87, 0.76), SIMD3(0.94, 0.78, 0.64), SIMD3(0.86, 0.66, 0.49),
        SIMD3(0.69, 0.49, 0.34), SIMD3(0.49, 0.33, 0.22), SIMD3(0.32, 0.21, 0.15),
    ]
    static let shirtPalette: [SIMD3<Float>] = [
        SIMD3(0.86, 0.24, 0.24), SIMD3(0.95, 0.55, 0.18), SIMD3(0.96, 0.84, 0.25),
        SIMD3(0.35, 0.74, 0.36), SIMD3(0.27, 0.52, 0.88), SIMD3(0.55, 0.35, 0.80),
        SIMD3(0.93, 0.55, 0.72), SIMD3(0.93, 0.93, 0.95), SIMD3(0.22, 0.24, 0.28),
    ]
    static let hairPalette: [SIMD3<Float>] = [
        SIMD3(0.12, 0.09, 0.07), SIMD3(0.35, 0.22, 0.11), SIMD3(0.62, 0.43, 0.22),
        SIMD3(0.92, 0.80, 0.45), SIMD3(0.72, 0.28, 0.14), SIMD3(0.78, 0.78, 0.80),
        SIMD3(0.30, 0.55, 0.90), SIMD3(0.90, 0.45, 0.70), SIMD3(0.35, 0.70, 0.45),
    ]
    static let hairStyleNames = ["Short", "Long", "Spiky", "Bald"]
    static let noseNames      = ["Button", "Round", "Pointy"]
    static let mouthNames     = ["Smile", "Grin", "Neutral", "Whoa"]

    // ---- colour accessors (clamped) ----------------------------------------
    private static func pick(_ table: [SIMD3<Float>], _ i: Int) -> SIMD3<Float> {
        table[((i % table.count) + table.count) % table.count]
    }
    var skinRGB:  SIMD3<Float> { CharacterAppearance.pick(CharacterAppearance.skinPalette,  skin) }
    var shirtRGB: SIMD3<Float> { CharacterAppearance.pick(CharacterAppearance.shirtPalette, shirt) }
    var hairRGB:  SIMD3<Float> { CharacterAppearance.pick(CharacterAppearance.hairPalette,  hairColor) }

    // ---- cycling helper for the +/- editor controls ------------------------
    enum Trait { case skin, shirt, hairColor, hairStyle, nose, mouth }
    static func count(_ t: Trait) -> Int {
        switch t {
        case .skin:      return skinPalette.count
        case .shirt:     return shirtPalette.count
        case .hairColor: return hairPalette.count
        case .hairStyle: return hairStyleNames.count
        case .nose:      return noseNames.count
        case .mouth:     return mouthNames.count
        }
    }
    mutating func cycle(_ t: Trait, by d: Int) {
        let n = CharacterAppearance.count(t)
        func step(_ v: Int) -> Int { ((v + d) % n + n) % n }
        switch t {
        case .skin:      skin      = step(skin)
        case .shirt:     shirt     = step(shirt)
        case .hairColor: hairColor = step(hairColor)
        case .hairStyle: hairStyle = step(hairStyle)
        case .nose:      nose      = step(nose)
        case .mouth:     mouth     = step(mouth)
        }
    }
    func valueName(_ t: Trait) -> String {
        switch t {
        case .skin:      return "Tone \(skin + 1)"
        case .shirt:     return "Colour \(shirt + 1)"
        case .hairColor: return "Colour \(hairColor + 1)"
        case .hairStyle: return CharacterAppearance.hairStyleNames[hairStyle]
        case .nose:      return CharacterAppearance.noseNames[nose]
        case .mouth:     return CharacterAppearance.mouthNames[mouth]
        }
    }

    // ---- persistence -------------------------------------------------------
    static func load() -> CharacterAppearance {
        let d = UserDefaults.standard
        var a = CharacterAppearance()
        if d.object(forKey: "charSkin")      != nil { a.skin      = d.integer(forKey: "charSkin") }
        if d.object(forKey: "charShirt")     != nil { a.shirt     = d.integer(forKey: "charShirt") }
        if d.object(forKey: "charHairColor") != nil { a.hairColor = d.integer(forKey: "charHairColor") }
        if d.object(forKey: "charHairStyle") != nil { a.hairStyle = d.integer(forKey: "charHairStyle") }
        if d.object(forKey: "charNose")      != nil { a.nose      = d.integer(forKey: "charNose") }
        if d.object(forKey: "charMouth")     != nil { a.mouth     = d.integer(forKey: "charMouth") }
        return a
    }
    func save() {
        let d = UserDefaults.standard
        d.set(skin, forKey: "charSkin");           d.set(shirt, forKey: "charShirt")
        d.set(hairColor, forKey: "charHairColor"); d.set(hairStyle, forKey: "charHairStyle")
        d.set(nose, forKey: "charNose");           d.set(mouth, forKey: "charMouth")
    }

    // ---- 2D portrait (the editor preview + a headless verification image) --
    // Draws a friendly front-facing avatar into ctx within rect (origin bottom-left).
    func drawPortrait(in ctx: CGContext, rect: CGRect) {
        func col(_ c: SIMD3<Float>, _ a: CGFloat = 1) -> CGColor {
            CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: a)
        }
        let skinC = skinRGB, hairC = hairRGB, shirtC = shirtRGB
        let cx = rect.midX
        let w  = min(rect.width, rect.height)
        let headR = w * 0.26
        let headCY = rect.minY + rect.height * 0.62
        let headRect = CGRect(x: cx - headR, y: headCY - headR, width: headR * 2, height: headR * 2)

        // Soft background panel.
        ctx.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1))
        ctx.fill(rect)

        // Shirt / shoulders (rounded rect rising from the bottom).
        let shW = headR * 2.4, shH = rect.height * 0.34
        let shRect = CGRect(x: cx - shW/2, y: rect.minY + rect.height * 0.06, width: shW, height: shH)
        ctx.setFillColor(col(shirtC))
        ctx.addPath(CGPath(roundedRect: shRect, cornerWidth: shW * 0.22, cornerHeight: shW * 0.22, transform: nil))
        ctx.fillPath()

        // Head.
        ctx.setFillColor(col(skinC))
        ctx.fillEllipse(in: headRect)

        // Hair (style-dependent), unless bald.
        if hairStyle != 3 {
            ctx.setFillColor(col(hairC))
            switch hairStyle {
            case 1: // long: cap + sides framing the face
                ctx.fillEllipse(in: CGRect(x: cx - headR * 1.06, y: headCY - headR * 1.0,
                                           width: headR * 2.12, height: headR * 1.7))
                ctx.setFillColor(col(skinC))
                ctx.fillEllipse(in: CGRect(x: cx - headR * 0.78, y: headCY - headR * 0.95,
                                           width: headR * 1.56, height: headR * 1.7))
            case 2: // spiky: a row of triangles across the top
                let spikes = 5
                for i in 0..<spikes {
                    let t = CGFloat(i) / CGFloat(spikes - 1)
                    let bx = cx - headR * 0.9 + t * headR * 1.8
                    ctx.move(to: CGPoint(x: bx - headR * 0.22, y: headCY + headR * 0.55))
                    ctx.addLine(to: CGPoint(x: bx, y: headCY + headR * 1.15))
                    ctx.addLine(to: CGPoint(x: bx + headR * 0.22, y: headCY + headR * 0.55))
                    ctx.closePath()
                }
                ctx.fillPath()
                ctx.fillEllipse(in: CGRect(x: cx - headR, y: headCY + headR * 0.2,
                                           width: headR * 2, height: headR * 0.7))
            default: // short: a neat cap over the top
                ctx.fillEllipse(in: CGRect(x: cx - headR * 1.02, y: headCY - headR * 0.1,
                                           width: headR * 2.04, height: headR * 1.25))
                ctx.setFillColor(col(skinC))
                ctx.fillEllipse(in: CGRect(x: cx - headR * 0.92, y: headCY - headR * 0.55,
                                           width: headR * 1.84, height: headR * 1.25))
            }
        }

        // Eyes (whites + dark pupils).
        let eyeY = headCY + headR * 0.12, eyeDX = headR * 0.40, eyeR = headR * 0.20
        for sx in [-eyeDX, eyeDX] {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: cx + sx - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2))
            ctx.setFillColor(CGColor(red: 0.10, green: 0.08, blue: 0.10, alpha: 1))
            let pr = eyeR * 0.5
            ctx.fillEllipse(in: CGRect(x: cx + sx - pr, y: eyeY - pr, width: pr * 2, height: pr * 2))
        }

        // Nose (style-dependent), a touch darker than skin.
        let noseSkin = skinC * 0.82
        ctx.setFillColor(col(noseSkin))
        let noseY = headCY - headR * 0.18
        switch nose {
        case 1: // round
            let r = headR * 0.16
            ctx.fillEllipse(in: CGRect(x: cx - r, y: noseY - r, width: r * 2, height: r * 2))
        case 2: // pointy (little triangle)
            ctx.move(to: CGPoint(x: cx, y: noseY + headR * 0.22))
            ctx.addLine(to: CGPoint(x: cx - headR * 0.12, y: noseY - headR * 0.14))
            ctx.addLine(to: CGPoint(x: cx + headR * 0.12, y: noseY - headR * 0.14))
            ctx.closePath(); ctx.fillPath()
        default: // button
            let r = headR * 0.10
            ctx.fillEllipse(in: CGRect(x: cx - r, y: noseY - r, width: r * 2, height: r * 2))
        }

        // Mouth (style-dependent).
        ctx.setStrokeColor(CGColor(red: 0.60, green: 0.28, blue: 0.26, alpha: 1))
        ctx.setFillColor(CGColor(red: 0.60, green: 0.28, blue: 0.26, alpha: 1))
        ctx.setLineWidth(max(2, headR * 0.10)); ctx.setLineCap(.round)
        let mouthY = headCY - headR * 0.52, mw = headR * 0.5
        switch mouth {
        case 1: // grin (smile + a teeth line)
            ctx.move(to: CGPoint(x: cx - mw, y: mouthY + headR * 0.1))
            ctx.addQuadCurve(to: CGPoint(x: cx + mw, y: mouthY + headR * 0.1),
                             control: CGPoint(x: cx, y: mouthY - headR * 0.35))
            ctx.strokePath()
        case 2: // neutral line
            ctx.move(to: CGPoint(x: cx - mw, y: mouthY)); ctx.addLine(to: CGPoint(x: cx + mw, y: mouthY))
            ctx.strokePath()
        case 3: // whoa (open O)
            let r = headR * 0.18
            ctx.fillEllipse(in: CGRect(x: cx - r, y: mouthY - r, width: r * 2, height: r * 2))
        default: // smile
            ctx.move(to: CGPoint(x: cx - mw, y: mouthY + headR * 0.08))
            ctx.addQuadCurve(to: CGPoint(x: cx + mw, y: mouthY + headR * 0.08),
                             control: CGPoint(x: cx, y: mouthY - headR * 0.30))
            ctx.strokePath()
        }
    }

    // Render a portrait straight to a PNG file (headless verification + thumbnails).
    @discardableResult
    func writePortraitPNG(to path: String, size: Int = 256) -> Bool {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        drawPortrait(in: ctx, rect: CGRect(x: 0, y: 0, width: size, height: size))
        guard let img = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

// A small live-updating preview view for the editor.
final class CharacterPreviewView: NSView {
    var character = CharacterAppearance() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        character.drawPortrait(in: ctx, rect: bounds)
    }
}
