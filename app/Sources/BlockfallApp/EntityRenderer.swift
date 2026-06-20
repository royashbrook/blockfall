// ============================================================================
// Blockfall — EntityRenderer (M5, five distinct creature species)
// Draws creatures as multi-part blocky animals (Minecraft-style).
//
// kind 0 — small round critter:  compact body, big head, stubby legs, round ears
//           animation: bouncy hop (abs-sin bob, legs stay close)
// kind 1 — tall lanky creature:  long thin legs, tall narrow body, long neck
//           animation: long striding gait, head sways side to side
// kind 2 — long low creature:    long body, very short legs, snout, thick tail
//           animation: side-to-side waddle, tail swings wide
// kind 3 — chunky wide creature: wide squat body, four sturdy legs, two horns
//           animation: heavy slow plod, slight head bob
// kind 4 — BOSS:                 bulky body, huge head, crown of 3 cubes, back spikes
//           animation: slow heavy stomp with dramatic foot-fall
//
// Public API (unchanged):
//   init(device:colorFormat:)
//   encode(_:viewProj:entities:count:)
// ============================================================================
import MetalKit
import simd
import QuartzCore   // CACurrentMediaTime()
import CBlockcore

// Passed to the vertex shader once per cube draw.
struct EUniforms {
    var mvp:   simd_float4x4
    var color: SIMD4<Float>   // rgb + sat (w)
}

final class EntityRenderer {
    private let pipeline:   MTLRenderPipelineState
    private let cubeVB:     MTLBuffer
    private let cubeIB:     MTLBuffer
    private let indexCount: Int

    // -----------------------------------------------------------------------
    init(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let lib = try? device.makeLibrary(source: EntityRenderer.shaderSource, options: nil) else {
            fatalError("entity shader compile failed")
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction   = lib.makeFunction(name: "evmain")
        pd.fragmentFunction = lib.makeFunction(name: "efmain")
        pd.colorAttachments[0].pixelFormat = colorFormat
        pd.depthAttachmentPixelFormat      = .depth32Float
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        // Unit cube centered at origin: 24 verts (pos.xyz + normal.xyz), 36 indices.
        var verts: [Float] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3( 0, 0, 1), SIMD3( 1, 0, 0), SIMD3(0, 1,  0)),  // +Z front
            (SIMD3( 0, 0,-1), SIMD3(-1, 0, 0), SIMD3(0, 1,  0)),  // -Z back
            (SIMD3( 1, 0, 0), SIMD3( 0, 0,-1), SIMD3(0, 1,  0)),  // +X right
            (SIMD3(-1, 0, 0), SIMD3( 0, 0, 1), SIMD3(0, 1,  0)),  // -X left
            (SIMD3( 0, 1, 0), SIMD3( 1, 0, 0), SIMD3(0, 0, -1)),  // +Y top
            (SIMD3( 0,-1, 0), SIMD3( 1, 0, 0), SIMD3(0, 0,  1)),  // -Y bottom
        ]
        var indices: [UInt16] = []
        var base: UInt16 = 0
        for (n, u, v) in faces {
            let c = n * 0.5
            let corners = [c - u*0.5 - v*0.5,
                           c + u*0.5 - v*0.5,
                           c + u*0.5 + v*0.5,
                           c - u*0.5 + v*0.5]
            for p in corners { verts += [p.x, p.y, p.z, n.x, n.y, n.z] }
            indices += [base, base+1, base+2, base, base+2, base+3]
            base += 4
        }
        cubeVB     = device.makeBuffer(bytes: verts,   length: verts.count   * 4, options: .storageModeShared)!
        cubeIB     = device.makeBuffer(bytes: indices,  length: indices.count * 2, options: .storageModeShared)!
        indexCount = indices.count
    }

    // -----------------------------------------------------------------------
    func encode(_ enc: MTLRenderCommandEncoder,
                viewProj: simd_float4x4,
                entities: UnsafePointer<bf_entity_draw>?,
                count:    Int) {
        guard let entities = entities, count > 0 else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(cubeVB, offset: 0, index: 0)

        let t = Float(CACurrentMediaTime())

        for i in 0..<count {
            let e = entities[i]
            let pos = SIMD3<Float>(e.position.x, e.position.y, e.position.z)
            // Per-entity phase so animals don't all step in sync.
            let phaseHash = sin(pos.x * 1.3 + pos.z * 2.7)
            let phase = t + phaseHash * 3.14159

            switch e.kind {
            case 0:  drawKind0(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase)
            case 1:  drawKind1(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase)
            case 2:  drawKind2(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase)
            case 3:  drawKind3(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase)
            default: drawKind4(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase)
            }
        }
    }

    // =========================================================================
    // KIND 0 — small round critter
    // Compact body, BIG round head (same width as body), very stubby legs,
    // two big round ear-nubs on top. Bouncy HOP animation: body lifts on abs-sin.
    // Parts: body(1) head(1) eyes(2) ears(2) tail(1) legs(4) = 11
    // =========================================================================
    private func drawKind0(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float) {
        let s   = e.scale
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol = baseCol * 0.68
        let eyeCol  = SIMD3<Float>(0.05, 0.05, 0.07)

        // Hop: body lifts on abs(sin), quick snap back down
        let hopSpeed: Float = 3.4
        let hopAmt = abs(sin(phase * hopSpeed * 0.5)) * s * 0.10
        let legSqueeze = sin(phase * hopSpeed) * 0.08  // tiny leg angle during hop

        // Dimensions — proportionally big head
        let bW = s * 0.70;  let bH = s * 0.50;  let bD = s * 0.75
        let hS = s * 0.62   // head almost as wide as body
        let legW = s * 0.18; let legH = s * 0.22; let legD = s * 0.18
        let earW = s * 0.20; let earH = s * 0.20; let earD = s * 0.20

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + hopAmt
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0,0,0), SIMD3(bW,bH,bD)), rgb: baseCol, sat: sat)
        // Head — sits right on top of body, slightly forward
        let headY = bH*0.5 + hS*0.5
        let headZ = bD*0.15
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS,hS,hS)), rgb: baseCol, sat: sat)
        // Eyes
        let eyeS = SIMD3<Float>(s*0.10, s*0.10, s*0.04)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.22, headY+hS*0.08, headZ+hS*0.50), eyeS),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.22, headY+hS*0.08, headZ+hS*0.50), eyeS),
                 rgb: eyeCol, sat: sat)
        // Big round ears — two short wide nubs
        let earY = headY + hS*0.50 + earH*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.30, earY, headZ), SIMD3(earW,earH,earD)),
                 rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.30, earY, headZ), SIMD3(earW,earH,earD)),
                 rgb: darkCol, sat: sat)
        // Tiny puff tail
        let tw = s*0.18
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH*0.20, -bD*0.50), SIMD3(tw,tw,tw*0.8)),
                 rgb: baseCol * 1.1, sat: sat)
        // 4 stubby legs
        let hipY = -bH*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.30, hipY, bD*0.28),  legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.30, hipY, bD*0.28), -legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.30, hipY, -bD*0.28), -legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.30, hipY, -bD*0.28),  legSqueeze), rgb: darkCol, sat: sat)
    }

    // =========================================================================
    // KIND 1 — tall lanky creature
    // Very long thin legs, tall narrow body, long neck, small head up high.
    // Striding gait with wide leg swing; head sways side-to-side.
    // Parts: legs(4) body(1) neck(1) head(1) eyes(2) ear-nubs(2) = 11
    // =========================================================================
    private func drawKind1(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float) {
        let s   = e.scale
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol = baseCol * 0.65
        let eyeCol  = SIMD3<Float>(0.05, 0.05, 0.07)

        let walkSpeed: Float = 2.2
        let legSwing  = sin(phase * walkSpeed) * 0.42  // big stride
        let sway      = sin(phase * walkSpeed) * s * 0.04  // head sway X

        // Tall narrow proportions
        let bW = s * 0.45;  let bH = s * 0.80;  let bD = s * 0.65
        let neckW = s * 0.20; let neckH = s * 0.55; let neckD = s * 0.20
        let hS = s * 0.32   // small head on long neck
        let legW = s * 0.14; let legH = s * 0.70; let legD = s * 0.14

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        let hipY = -bH*0.5
        // Legs — wide stance, long stride
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.38, hipY, bD*0.32),  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.38, hipY, bD*0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.38, hipY, -bD*0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.38, hipY, -bD*0.32),  legSwing), rgb: darkCol, sat: sat)
        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0,0,0), SIMD3(bW,bH,bD)), rgb: baseCol, sat: sat)
        // Neck — extends up from front of body
        let neckLocalY = bH*0.5 + neckH*0.5
        let neckLocalZ = bD*0.20
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway, neckLocalY, neckLocalZ), SIMD3(neckW,neckH,neckD)),
                 rgb: baseCol, sat: sat)
        // Head
        let headY = neckLocalY + neckH*0.5 + hS*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway, headY, neckLocalZ), SIMD3(hS,hS,hS)),
                 rgb: baseCol, sat: sat)
        // Eyes
        let eyeS = SIMD3<Float>(s*0.08, s*0.08, s*0.04)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway-hS*0.22, headY+hS*0.06, neckLocalZ+hS*0.50), eyeS),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway+hS*0.22, headY+hS*0.06, neckLocalZ+hS*0.50), eyeS),
                 rgb: eyeCol, sat: sat)
        // Two small upward ear-nubs
        let earW = s*0.10; let earH = s*0.18; let earD = s*0.10
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway-hS*0.28, headY+hS*0.50+earH*0.5, neckLocalZ), SIMD3(earW,earH,earD)),
                 rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway+hS*0.28, headY+hS*0.50+earH*0.5, neckLocalZ), SIMD3(earW,earH,earD)),
                 rgb: darkCol, sat: sat)
    }

    // =========================================================================
    // KIND 2 — long low creature
    // Long body, very short legs, snout that juts forward, thick tail behind.
    // Waddle: body rocks side-to-side (rotZ), tail swings opposite.
    // Parts: body(1) snout(1) head(1) eyes(2) tail(1) legs(4) back-fin(1) = 11
    // =========================================================================
    private func drawKind2(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float) {
        let s   = e.scale
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol = baseCol * 0.62
        let eyeCol  = SIMD3<Float>(0.05, 0.05, 0.07)
        let bellyCol = baseCol * 0.85

        let waddleSpeed: Float = 2.6
        let rockAngle = sin(phase * waddleSpeed) * 0.14  // side-to-side rock
        let legSwing  = sin(phase * waddleSpeed) * 0.22
        let tailSwing = -sin(phase * waddleSpeed * 1.3) * 0.28

        // Long flat proportions
        let bW = s * 0.65;  let bH = s * 0.38;  let bD = s * 1.30
        let snoutW = s * 0.38; let snoutH = s * 0.28; let snoutD = s * 0.30
        let hS = s * 0.40
        let legW = s * 0.16; let legH = s * 0.24; let legD = s * 0.20
        let tailW = s * 0.28; let tailH = s * 0.22; let tailD = s * 0.38

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        // Body rocks side-to-side — apply rock to entire entity after yaw
        let rock = EntityRenderer.rotZ(rockAngle)
        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * rock * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * rock * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0,0,0), SIMD3(bW,bH,bD)), rgb: baseCol, sat: sat)
        // Low belly stripe (slightly taller cube overlapping front of body)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH*0.20, bD*0.15), SIMD3(bW*0.90, bH*0.55, bD*0.55)),
                 rgb: bellyCol, sat: sat)
        // Head — low, at front
        let headY = bH*0.30
        let headZ = bD*0.50 + hS*0.40
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS*0.80, hS)),
                 rgb: baseCol, sat: sat)
        // Snout — juts forward from head
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY-hS*0.10, headZ+hS*0.45+snoutD*0.5), SIMD3(snoutW,snoutH,snoutD)),
                 rgb: darkCol, sat: sat)
        // Eyes — on sides of head, wide-set
        let eyeS = SIMD3<Float>(s*0.04, s*0.09, s*0.09)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.50, headY+hS*0.10, headZ), eyeS),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.50, headY+hS*0.10, headZ), eyeS),
                 rgb: eyeCol, sat: sat)
        // Thick tail — behind body, swings
        let tailHip = SIMD3<Float>(0, bH*0.25, -bD*0.50)
        do {
            let tailCenter = SIMD3<Float>(0, -tailH*0.4, -tailD*0.5)
            let tailModel = EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(tailHip)
                * EntityRenderer.rotX(tailSwing)
                * EntityRenderer.trans(tailCenter)
                * EntityRenderer.scaleM(SIMD3(tailW, tailH, tailD))
            drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: darkCol, sat: sat)
        }
        // Back ridge fin — a flat slab along the top of the body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH*0.50+s*0.06, -bD*0.10), SIMD3(s*0.10, s*0.12, bD*0.65)),
                 rgb: darkCol, sat: sat)
        // 4 short legs
        let hipY = -bH*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.38, hipY, bD*0.35),  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.38, hipY, bD*0.35), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.38, hipY, -bD*0.35), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.38, hipY, -bD*0.35),  legSwing), rgb: darkCol, sat: sat)
    }

    // =========================================================================
    // KIND 3 — chunky wide creature
    // Wide squat body, four thick sturdy legs, two forward-pointing horns,
    // and a tuft of fur on the back. Heavy slow plod.
    // Parts: body(1) head(1) eyes(2) horns(2) tuft(1) legs(4) = 11
    // =========================================================================
    private func drawKind3(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float) {
        let s   = e.scale
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol = baseCol * 0.65
        let hornCol = baseCol * 1.18
        let eyeCol  = SIMD3<Float>(0.05, 0.05, 0.07)

        let plodSpeed: Float = 1.8   // slow heavy plod
        let legSwing  = sin(phase * plodSpeed) * 0.26
        let bodyBob   = abs(sin(phase * plodSpeed)) * s * 0.009  // very subtle bob

        // Wide squat proportions
        let bW = s * 1.10;  let bH = s * 0.55;  let bD = s * 0.85
        let hS = s * 0.58   // wide head
        let legW = s * 0.28; let legH = s * 0.38; let legD = s * 0.28
        let hornW = s * 0.12; let hornH = s * 0.26; let hornD = s * 0.10

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + bodyBob
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0,0,0), SIMD3(bW,bH,bD)), rgb: baseCol, sat: sat)
        // Head — low, at front
        let headY: Float = bH*0.20
        let headZ: Float = bD*0.50 + hS*0.42
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS*0.80, hS*0.75)),
                 rgb: baseCol, sat: sat)
        // Eyes — low on face
        let eyeS = SIMD3<Float>(s*0.10, s*0.10, s*0.04)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.24, headY+hS*0.04, headZ+hS*0.37), eyeS),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.24, headY+hS*0.04, headZ+hS*0.37), eyeS),
                 rgb: eyeCol, sat: sat)
        // Two horns on top of head, angled forward
        let hornBaseY = headY + hS*0.40 + hornH*0.5
        let hornTiltFwd = EntityRenderer.rotX(-0.30)  // lean forward
        do {
            let wc2 = wc
            let hornModel1 = EntityRenderer.trans(wc2) * R
                * EntityRenderer.trans(SIMD3(-hS*0.28, hornBaseY, headZ))
                * hornTiltFwd
                * EntityRenderer.scaleM(SIMD3(hornW,hornH,hornD))
            drawCube(enc: enc, viewProj: viewProj, model: hornModel1, rgb: hornCol, sat: sat)
            let hornModel2 = EntityRenderer.trans(wc2) * R
                * EntityRenderer.trans(SIMD3( hS*0.28, hornBaseY, headZ))
                * hornTiltFwd
                * EntityRenderer.scaleM(SIMD3(hornW,hornH,hornD))
            drawCube(enc: enc, viewProj: viewProj, model: hornModel2, rgb: hornCol, sat: sat)
        }
        // Tuft — a slightly brighter wide slab on top of body near back
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH*0.50+s*0.08, -bD*0.22), SIMD3(bW*0.60, s*0.16, bD*0.30)),
                 rgb: baseCol * 1.12, sat: sat)
        // 4 thick legs
        let hipY = -bH*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.38, hipY, bD*0.32),  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.38, hipY, bD*0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.38, hipY, -bD*0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.38, hipY, -bD*0.32),  legSwing), rgb: darkCol, sat: sat)
    }

    // =========================================================================
    // KIND 4 — BOSS
    // Much bigger (scale * 1.5 applied internally). Bulky wide body, massive head,
    // crown of 3 tall cubes on head, two wide shoulder spikes, heavy stomp animation.
    // Parts: body(1) head(1) eyes(2) crown(3) shoulder-spikes(2) legs(4) = 13
    // =========================================================================
    private func drawKind4(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float) {
        let s   = e.scale * 1.50   // boss is noticeably bigger
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol  = baseCol * 0.60
        let crownCol = baseCol * 1.25
        let eyeCol   = SIMD3<Float>(0.05, 0.05, 0.07)

        let stompSpeed: Float = 1.4   // very slow heavy stomp
        let legSwing  = sin(phase * stompSpeed) * 0.30
        // Heavy stomp: sudden downward slam on negative-phase half
        let stompRaw  = sin(phase * stompSpeed)
        let stomp     = (stompRaw < 0 ? abs(stompRaw) * abs(stompRaw) : 0) * s * 0.025

        // Massive proportions
        let bW = s * 1.00;  let bH = s * 0.75;  let bD = s * 0.90
        let hS = s * 0.72   // huge head
        let legW = s * 0.30; let legH = s * 0.50; let legD = s * 0.30
        let crownW = s * 0.16; let crownH = s * 0.38; let crownD = s * 0.16
        let spikeW = s * 0.14; let spikeH = s * 0.30; let spikeD = s * 0.10

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + stomp
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0,0,0), SIMD3(bW,bH,bD)), rgb: baseCol, sat: sat)
        // Massive head — forward
        let headY: Float = bH*0.35
        let headZ: Float = bD*0.50 + hS*0.38
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS,hS,hS*0.85)),
                 rgb: baseCol, sat: sat)
        // Eyes — large, slightly menacing but round
        let eyeS = SIMD3<Float>(s*0.14, s*0.14, s*0.05)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.24, headY+hS*0.08, headZ+hS*0.43), eyeS),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.24, headY+hS*0.08, headZ+hS*0.43), eyeS),
                 rgb: eyeCol, sat: sat)
        // Crown — 3 tall spires on top of head (center taller, outer shorter)
        let crownBaseY = headY + hS*0.50
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, crownBaseY + crownH*0.60, headZ), SIMD3(crownW, crownH*1.20, crownD)),
                 rgb: crownCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.30, crownBaseY + crownH*0.50, headZ), SIMD3(crownW, crownH, crownD)),
                 rgb: crownCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.30, crownBaseY + crownH*0.50, headZ), SIMD3(crownW, crownH, crownD)),
                 rgb: crownCol, sat: sat)
        // Shoulder spikes — angled outward on top sides of body
        let spikeY = bH*0.42
        let spikeOutX = bW*0.50 + spikeH*0.30
        let spikeTiltL = EntityRenderer.rotZ( 0.45)  // lean outward
        let spikeTiltR = EntityRenderer.rotZ(-0.45)
        do {
            let wc2 = wc
            let spikeM1 = EntityRenderer.trans(wc2) * R
                * EntityRenderer.trans(SIMD3(-spikeOutX, spikeY, 0))
                * spikeTiltL
                * EntityRenderer.scaleM(SIMD3(spikeW, spikeH, spikeD))
            drawCube(enc: enc, viewProj: viewProj, model: spikeM1, rgb: crownCol, sat: sat)
            let spikeM2 = EntityRenderer.trans(wc2) * R
                * EntityRenderer.trans(SIMD3( spikeOutX, spikeY, 0))
                * spikeTiltR
                * EntityRenderer.scaleM(SIMD3(spikeW, spikeH, spikeD))
            drawCube(enc: enc, viewProj: viewProj, model: spikeM2, rgb: crownCol, sat: sat)
        }
        // 4 massive legs
        let hipY = -bH*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.38, hipY, bD*0.32),  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.38, hipY, bD*0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.38, hipY, -bD*0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.38, hipY, -bD*0.32),  legSwing), rgb: darkCol, sat: sat)
    }

    // -----------------------------------------------------------------------
    // Draw one unit cube with given model matrix and color.
    @inline(__always)
    private func drawCube(enc: MTLRenderCommandEncoder,
                          viewProj: simd_float4x4,
                          model: simd_float4x4,
                          rgb: SIMD3<Float>,
                          sat: Float) {
        var u = EUniforms(mvp: viewProj * model,
                          color: SIMD4<Float>(rgb.x, rgb.y, rgb.z, sat))
        enc.setVertexBytes(&u, length: MemoryLayout<EUniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                  indexType: .uint16, indexBuffer: cubeIB, indexBufferOffset: 0)
    }

    // -----------------------------------------------------------------------
    // Matrix helpers
    static func trans(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }
    static func scaleM(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = s.x
        m.columns.1.y = s.y
        m.columns.2.z = s.z
        return m
    }
    static func rotY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4( c, 0, -s, 0)
        m.columns.2 = SIMD4( s, 0,  c, 0)
        return m
    }
    static func rotX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.1 = SIMD4(0,  c, s, 0)
        m.columns.2 = SIMD4(0, -s, c, 0)
        return m
    }
    static func rotZ(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4( c, s, 0, 0)
        m.columns.1 = SIMD4(-s, c, 0, 0)
        return m
    }

    // -----------------------------------------------------------------------
    // MSL shader — unchanged; EUniforms matches struct above.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CVert    { packed_float3 pos; packed_float3 normal; };
    struct EUniforms { float4x4 mvp; float4 color; };
    struct EOut     { float4 position [[position]]; float3 color; float shade; float sat; };

    vertex EOut evmain(uint vid [[vertex_id]],
                       device const CVert* v [[buffer(0)]],
                       constant EUniforms& u [[buffer(1)]]) {
        CVert cv = v[vid];
        float3 n = float3(cv.normal);
        // Simple directional shading: top face bright, side faces medium, bottom dim
        float shade = clamp(0.55 + 0.30 * n.y + 0.15 * n.x, 0.0, 1.0);
        EOut o;
        o.position = u.mvp * float4(float3(cv.pos), 1.0);
        o.color    = u.color.rgb;
        o.shade    = shade;
        o.sat      = u.color.w;
        return o;
    }

    fragment float4 efmain(EOut in [[stage_in]]) {
        float3 c = in.color * in.shade;
        // Dim desaturation: mix toward luminance by (1 - sat)
        float l = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(l), c, clamp(in.sat, 0.0, 1.0));
        return float4(c, 1.0);
    }
    """
}
