// #71 — character appearance customization (skin, shirt, hair colour + style, nose, mouth).
// Kid-friendly: each trait is an index into a preset list, so the whole look is six small
// numbers that persist in UserDefaults and (later, Phase 2) replicate to co-op peers. The
// same presets drive both the 2D editor portrait and (eventually) the in-world character.
// At least 10 options per trait, and a Randomize/Save flow in the editor.
import AppKit
import simd

struct CharacterAppearance: Equatable {
    var skin: Int      = 1
    var shirt: Int     = 4
    var hairColor: Int = 1
    var hairStyle: Int = 2
    var nose: Int      = 0
    var mouth: Int     = 0

    // ---- preset tables (10+ each, all meant to look normal, not wacky) -----
    static let skinPalette: [SIMD3<Float>] = [
        SIMD3(0.99, 0.88, 0.78), SIMD3(0.96, 0.81, 0.68), SIMD3(0.92, 0.74, 0.58),
        SIMD3(0.85, 0.65, 0.48), SIMD3(0.74, 0.54, 0.38), SIMD3(0.62, 0.44, 0.30),
        SIMD3(0.50, 0.34, 0.23), SIMD3(0.40, 0.27, 0.18), SIMD3(0.31, 0.21, 0.14),
        SIMD3(0.93, 0.78, 0.70),
    ]
    static let shirtPalette: [SIMD3<Float>] = [
        SIMD3(0.86, 0.24, 0.24), SIMD3(0.95, 0.55, 0.18), SIMD3(0.96, 0.84, 0.25),
        SIMD3(0.35, 0.74, 0.36), SIMD3(0.27, 0.52, 0.88), SIMD3(0.55, 0.35, 0.80),
        SIMD3(0.93, 0.55, 0.72), SIMD3(0.20, 0.70, 0.66), SIMD3(0.55, 0.40, 0.26),
        SIMD3(0.93, 0.93, 0.95), SIMD3(0.22, 0.24, 0.28), SIMD3(0.50, 0.55, 0.60),
    ]
    static let hairPalette: [SIMD3<Float>] = [
        SIMD3(0.10, 0.08, 0.07), SIMD3(0.32, 0.20, 0.10), SIMD3(0.55, 0.36, 0.18),
        SIMD3(0.78, 0.60, 0.30), SIMD3(0.93, 0.82, 0.50), SIMD3(0.72, 0.28, 0.14),
        SIMD3(0.80, 0.80, 0.82), SIMD3(0.30, 0.55, 0.90), SIMD3(0.90, 0.45, 0.70),
        SIMD3(0.35, 0.70, 0.45), SIMD3(0.62, 0.40, 0.78), SIMD3(0.95, 0.55, 0.20),
    ]
    static let hairStyleNames = ["Bald", "Buzz", "Short", "Side Part", "Long",
                                 "Ponytail", "Spiky", "Mohawk", "Curly", "Bun"]
    static let noseNames  = ["Button", "Round", "Pointy", "Wide", "Small",
                             "Long", "Upturned", "Flat", "Broad", "Narrow"]
    static let mouthNames = ["Smile", "Grin", "Neutral", "Whoa", "Frown",
                             "Smirk", "Laugh", "Tiny", "Big Smile", "Content"]

    private static func pick(_ table: [SIMD3<Float>], _ i: Int) -> SIMD3<Float> {
        table[((i % table.count) + table.count) % table.count]
    }
    var skinRGB:  SIMD3<Float> { CharacterAppearance.pick(CharacterAppearance.skinPalette,  skin) }
    var shirtRGB: SIMD3<Float> { CharacterAppearance.pick(CharacterAppearance.shirtPalette, shirt) }
    var hairRGB:  SIMD3<Float> { CharacterAppearance.pick(CharacterAppearance.hairPalette,  hairColor) }

    // ---- cycling + randomize -----------------------------------------------
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
    static func randomized() -> CharacterAppearance {
        CharacterAppearance(
            skin: Int.random(in: 0..<count(.skin)), shirt: Int.random(in: 0..<count(.shirt)),
            hairColor: Int.random(in: 0..<count(.hairColor)), hairStyle: Int.random(in: 0..<count(.hairStyle)),
            nose: Int.random(in: 0..<count(.nose)), mouth: Int.random(in: 0..<count(.mouth)))
    }
    func valueName(_ t: Trait) -> String {
        switch t {
        case .skin:      return "Tone \(skin + 1)"
        case .shirt:     return "Colour \(shirt + 1)"
        case .hairColor: return "Colour \(hairColor + 1)"
        case .hairStyle: return CharacterAppearance.hairStyleNames[hairStyle % CharacterAppearance.hairStyleNames.count]
        case .nose:      return CharacterAppearance.noseNames[nose % CharacterAppearance.noseNames.count]
        case .mouth:     return CharacterAppearance.mouthNames[mouth % CharacterAppearance.mouthNames.count]
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

    // ---- 2D portrait (editor preview + headless verification) --------------
    func drawPortrait(in ctx: CGContext, rect: CGRect) {
        func cg(_ c: SIMD3<Float>, _ a: CGFloat = 1) -> CGColor {
            CGColor(red: CGFloat(max(0, c.x)), green: CGFloat(max(0, c.y)), blue: CGFloat(max(0, c.z)), alpha: a)
        }
        let skinC = skinRGB, hairC = hairRGB, shirtC = shirtRGB
        let cx = rect.midX
        let w  = min(rect.width, rect.height)
        let headR = w * 0.25
        let headCY = rect.minY + rect.height * 0.60
        let headRect = CGRect(x: cx - headR, y: headCY - headR, width: headR * 2, height: headR * 2)

        ctx.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1)); ctx.fill(rect)

        // Shirt / shoulders.
        let shW = headR * 2.5, shH = rect.height * 0.34
        let shRect = CGRect(x: cx - shW/2, y: rect.minY + rect.height * 0.05, width: shW, height: shH)
        ctx.setFillColor(cg(shirtC))
        ctx.addPath(CGPath(roundedRect: shRect, cornerWidth: shW * 0.22, cornerHeight: shW * 0.22, transform: nil))
        ctx.fillPath()

        // Head.
        ctx.setFillColor(cg(skinC)); ctx.fillEllipse(in: headRect)

        // ---- hair (10 styles) ----
        let hc = cg(hairC), sc = cg(skinC)
        func cap(_ widen: CGFloat, _ drop: CGFloat) {   // a rounded hair cap, then re-cut the face
            ctx.setFillColor(hc)
            ctx.fillEllipse(in: CGRect(x: cx - headR * widen, y: headCY - headR * 0.05 + drop,
                                       width: headR * 2 * widen, height: headR * 1.25))
            ctx.setFillColor(sc)
            ctx.fillEllipse(in: CGRect(x: cx - headR * 0.92, y: headCY - headR * 0.62,
                                       width: headR * 1.84, height: headR * 1.25))
        }
        switch hairStyle {
        case 0: break                                   // Bald
        case 1: // Buzz: thin cap hugging the very top
            ctx.setFillColor(hc)
            ctx.fillEllipse(in: CGRect(x: cx - headR * 0.96, y: headCY + headR * 0.18,
                                       width: headR * 1.92, height: headR * 0.78))
        case 3: // Side Part: cap, then sweep one side back
            cap(1.02, 0.0)
            ctx.setFillColor(hc)
            ctx.fillEllipse(in: CGRect(x: cx - headR * 0.95, y: headCY - headR * 0.1,
                                       width: headR * 0.9, height: headR * 0.9))
        case 4: // Long: frames the face down the sides
            ctx.setFillColor(hc)
            ctx.fillEllipse(in: CGRect(x: cx - headR * 1.08, y: headCY - headR * 1.05,
                                       width: headR * 2.16, height: headR * 1.95))
            ctx.setFillColor(sc)
            ctx.fillEllipse(in: CGRect(x: cx - headR * 0.78, y: headCY - headR * 0.95,
                                       width: headR * 1.56, height: headR * 1.75))
        case 5: // Ponytail: cap + a tail to the side
            ctx.setFillColor(hc)
            ctx.fillEllipse(in: CGRect(x: cx + headR * 0.55, y: headCY - headR * 0.5,
                                       width: headR * 0.7, height: headR * 1.1))
            cap(1.02, 0.0)
        case 6: // Spiky: triangles across the top
            ctx.setFillColor(hc)
            let n = 6
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n - 1)
                let bx = cx - headR * 0.85 + t * headR * 1.7
                ctx.move(to: CGPoint(x: bx - headR * 0.18, y: headCY + headR * 0.55))
                ctx.addLine(to: CGPoint(x: bx, y: headCY + headR * 1.2))
                ctx.addLine(to: CGPoint(x: bx + headR * 0.18, y: headCY + headR * 0.55))
                ctx.closePath()
            }
            ctx.fillPath()
            ctx.fillEllipse(in: CGRect(x: cx - headR, y: headCY + headR * 0.25, width: headR * 2, height: headR * 0.6))
        case 7: // Mohawk: central strip of spikes
            ctx.setFillColor(hc)
            for i in 0..<3 {
                let bx = cx - headR * 0.3 + CGFloat(i) * headR * 0.3
                ctx.move(to: CGPoint(x: bx - headR * 0.14, y: headCY + headR * 0.6))
                ctx.addLine(to: CGPoint(x: bx, y: headCY + headR * 1.35))
                ctx.addLine(to: CGPoint(x: bx + headR * 0.14, y: headCY + headR * 0.6))
                ctx.closePath()
            }
            ctx.fillPath()
        case 8: // Curly: a scalloped row of puffs
            ctx.setFillColor(hc)
            for i in 0..<5 {
                let t = CGFloat(i) / 4.0
                let bx = cx - headR * 0.8 + t * headR * 1.6
                ctx.fillEllipse(in: CGRect(x: bx - headR * 0.3, y: headCY + headR * 0.35,
                                           width: headR * 0.6, height: headR * 0.6))
            }
            cap(0.98, headR * 0.1)
        case 9: // Bun: cap + a round bun on top
            cap(1.02, 0.0)
            ctx.setFillColor(hc)
            ctx.fillEllipse(in: CGRect(x: cx - headR * 0.3, y: headCY + headR * 0.95,
                                       width: headR * 0.6, height: headR * 0.6))
        default: cap(1.02, 0.0)                          // Short (2)
        }

        // ---- eyes ----
        let eyeY = headCY + headR * 0.12, eyeDX = headR * 0.40, eyeR = headR * 0.19
        for sx in [-eyeDX, eyeDX] {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: cx + sx - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2))
            ctx.setFillColor(CGColor(red: 0.10, green: 0.08, blue: 0.10, alpha: 1))
            let pr = eyeR * 0.5
            ctx.fillEllipse(in: CGRect(x: cx + sx - pr, y: eyeY - pr, width: pr * 2, height: pr * 2))
        }

        // ---- nose (10) ----  width/height variations of a few shapes
        ctx.setFillColor(cg(skinC * 0.80))
        let nY = headCY - headR * 0.16
        func noseBlob(_ wf: CGFloat, _ hf: CGFloat) {
            ctx.fillEllipse(in: CGRect(x: cx - headR * wf, y: nY - headR * hf, width: headR * wf * 2, height: headR * hf * 2))
        }
        func noseTri(_ wf: CGFloat, _ up: Bool) {
            let h = headR * 0.22
            if up { ctx.move(to: CGPoint(x: cx, y: nY - h)); ctx.addLine(to: CGPoint(x: cx - headR*wf, y: nY + h*0.6)); ctx.addLine(to: CGPoint(x: cx + headR*wf, y: nY + h*0.6)) }
            else  { ctx.move(to: CGPoint(x: cx, y: nY + h)); ctx.addLine(to: CGPoint(x: cx - headR*wf, y: nY - h*0.6)); ctx.addLine(to: CGPoint(x: cx + headR*wf, y: nY - h*0.6)) }
            ctx.closePath(); ctx.fillPath()
        }
        switch nose {
        case 1: noseBlob(0.16, 0.16)                    // Round
        case 2: noseTri(0.12, false)                    // Pointy (down)
        case 3: noseBlob(0.22, 0.11)                    // Wide
        case 4: noseBlob(0.08, 0.08)                    // Small
        case 5: noseBlob(0.08, 0.20)                    // Long
        case 6: noseTri(0.12, true)                     // Upturned
        case 7: ctx.fill(CGRect(x: cx - headR*0.16, y: nY - headR*0.04, width: headR*0.32, height: headR*0.08)) // Flat bar
        case 8: noseBlob(0.20, 0.16)                    // Broad
        case 9: noseBlob(0.07, 0.14)                    // Narrow
        default: noseBlob(0.10, 0.10)                   // Button
        }

        // ---- mouth (10) ----
        let mC = CGColor(red: 0.60, green: 0.28, blue: 0.26, alpha: 1)
        ctx.setStrokeColor(mC); ctx.setFillColor(mC)
        ctx.setLineWidth(max(2, headR * 0.10)); ctx.setLineCap(.round)
        let mY = headCY - headR * 0.52
        func curve(_ wf: CGFloat, _ depth: CGFloat) {   // depth>0 smile, <0 frown
            let mw = headR * wf
            ctx.move(to: CGPoint(x: cx - mw, y: mY + headR * 0.06))
            ctx.addQuadCurve(to: CGPoint(x: cx + mw, y: mY + headR * 0.06), control: CGPoint(x: cx, y: mY - headR * depth))
            ctx.strokePath()
        }
        switch mouth {
        case 1: curve(0.55, 0.34)                       // Grin
        case 2: ctx.move(to: CGPoint(x: cx - headR*0.4, y: mY)); ctx.addLine(to: CGPoint(x: cx + headR*0.4, y: mY)); ctx.strokePath() // Neutral
        case 3: let r = headR*0.18; ctx.fillEllipse(in: CGRect(x: cx-r, y: mY-r, width: r*2, height: r*2)) // Whoa
        case 4: curve(0.45, -0.28)                      // Frown
        case 5: ctx.move(to: CGPoint(x: cx - headR*0.1, y: mY)); ctx.addQuadCurve(to: CGPoint(x: cx + headR*0.42, y: mY + headR*0.12), control: CGPoint(x: cx + headR*0.2, y: mY - headR*0.18)); ctx.strokePath() // Smirk
        case 6: // Laugh: open mouth (filled arc) with a tongue
            let mw = headR*0.42
            ctx.move(to: CGPoint(x: cx - mw, y: mY + headR*0.05))
            ctx.addQuadCurve(to: CGPoint(x: cx + mw, y: mY + headR*0.05), control: CGPoint(x: cx, y: mY - headR*0.45))
            ctx.closePath(); ctx.fillPath()
        case 7: let r = headR*0.07; ctx.fillEllipse(in: CGRect(x: cx-r, y: mY-r, width: r*2, height: r*2)) // Tiny
        case 8: curve(0.62, 0.30)                       // Big Smile
        case 9: curve(0.35, 0.18)                       // Content
        default: curve(0.50, 0.30)                      // Smile
        }
    }

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

final class CharacterPreviewView: NSView {
    var character = CharacterAppearance() { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        character.drawPortrait(in: ctx, rect: bounds)
    }
}
