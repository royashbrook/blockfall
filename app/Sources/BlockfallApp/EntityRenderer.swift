// ============================================================================
// Blockfall — EntityRenderer (M5 enhanced: richer models + full animation suite)
// Draws creatures as multi-part blocky animals (Minecraft-style).
//
// kind 0 — small round critter:  compact body, big head, stubby legs, round ears,
//           cotton-ball tail, toe-pads.
//           animation: bouncy hop, ear twitch, tail wag, blink, breathe
// kind 1 — tall lanky creature:  long thin legs, tall narrow body, long neck,
//           small head, pointy ears, ankle-knobs.
//           animation: long striding gait, head sway, neck bob, blink, breathe
// kind 2 — long low creature:    long body, very short legs, wide snout,
//           back-ridge fin, thick swinging tail, belly stripe.
//           animation: side-to-side waddle, tail swing, fin bob, blink
// kind 3 — chunky wide creature: wide squat body, four sturdy legs, two horns,
//           back tuft, nose ridge, shoulder pads.
//           animation: heavy slow plod, horn jitter, tuft sway, blink, breathe
// kind 4 — BOSS: bulky body, massive head, crown of 3 spires, 3 back spikes,
//           shoulder pads, GLOWING HDR eyes (bloom-ready), dramatic stomp.
//           animation: stomp, crown bob, shoulder spike quiver, emissive blink
//
// Animation list:
//   BLINK       — per-creature cadence: eyes squish flat for ~0.08s every 3-6s
//   BREATHE     — gentle body Y-bob + slight XZ scale pulse, ~0.4 Hz
//   TAIL WAG    — continuous side-to-side sine, always-on, independent freq
//   EAR TWITCH  — brief rotX flick on ears, one ear at a time, ~2-4s intervals
//   WALK CYCLE  — front/back leg pairs swing opposite phases; gait per species
//   LOCOMOTION  — speed-scaled via phase rate (always at 1× since no speed field)
//   BOSS STOMP  — squared abs(sin) so foot slams hard then holds
//   BOSS HDR    — emissive eyes write luminance > 1.0 into rgba16Float; bloom pass picks them up
//
// Per-entity phase derivation:
//   phaseHash = sin(pos.x * 1.3 + pos.z * 2.7)          — spatial scatter
//   phase     = CACurrentMediaTime() + phaseHash * π      — unique offset per creature
//   blinkPhase  = phase * 0.97  + phaseHash * 4.1         — different rate for blink
//   breathPhase = phase * 0.38  + phaseHash * 1.7         — slow breath
//   earPhase    = phase * 0.71  + phaseHash * 6.3         — ear twitch cadence
//   tailPhase   = phase * 1.60  + phaseHash * 2.2         — wag always running
//
// Public API (unchanged):
//   init(device:colorFormat:)
//   encode(_:viewProj:entities:count:)
//
// Emissive sentinel: sat == -1.0 in EUniforms signals the fragment shader to
// output color directly (no shading multiply). Used only for boss HDR eyes.
// Engine sat is 0..1 so negative is safe as a sentinel.
// ============================================================================
import MetalKit
import simd
import QuartzCore   // CACurrentMediaTime()
import CBlockcore

// Passed to the vertex shader once per cube draw.
struct EUniforms {
    var mvp:   simd_float4x4
    var color: SIMD4<Float>   // rgb + sat (w); w = -1 means emissive (no shading)
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
            // Per-entity spatial hash — scatters all animation phases so
            // dozens of creatures never step in sync.
            let phaseHash = sin(pos.x * 1.3 + pos.z * 2.7)
            let phase     = t + phaseHash * 3.14159

            switch e.kind {
            case 0:  drawKind0(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash)
            case 1:  drawKind1(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash)
            case 2:  drawKind2(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash)
            case 3:  drawKind3(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash)
            default: drawKind4(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash)
            }
        }
    }

    // =========================================================================
    // Shared animation helpers
    // =========================================================================

    /// Blink factor: returns a Y scale multiplier for eyes.
    /// Result is ~1.0 most of the time and briefly near 0.0 during a blink.
    /// `blinkPhase` should be a slow-rate phase (around 0.25–0.4 Hz).
    @inline(__always)
    private func blinkScale(_ blinkPhase: Float) -> Float {
        // pow(|sin|, 40) produces a very narrow spike near 0 each half-period.
        // The eye Y dimension is multiplied by (1 - spike) so it flattens.
        let spike = pow(abs(sin(blinkPhase * 0.55)), 40.0)
        return max(0.04, 1.0 - spike)
    }

    /// Breathe Y offset: gentle sine, returns a world-Y delta.
    /// Callers pass a phase already scaled to ~0.4 Hz; just evaluate sin directly.
    @inline(__always)
    private func breatheYOffset(_ breathPhase: Float, scale s: Float) -> Float {
        return sin(breathPhase) * s * 0.012
    }

    /// Ear twitch angle: intermittent rotX flick on one ear.
    /// `earPhase` drives the cadence; `side` is ±1 to split left/right.
    @inline(__always)
    private func earTwitchAngle(_ earPhase: Float, side: Float) -> Float {
        // fract-like: concentrate the flick into a narrow window of the cycle
        let raw = sin(earPhase * 0.71 + side * 1.57) // side offsets by ~π/2
        let spike = pow(abs(raw), 18.0) * (raw < 0 ? Float(-1) : Float(1))
        return spike * 0.30
    }

    /// Tail wag angle (continuous slow sway).
    @inline(__always)
    private func tailWagAngle(_ tailPhase: Float) -> Float {
        return sin(tailPhase * 1.60) * 0.32
    }

    // =========================================================================
    // KIND 0 — small round critter
    // Compact body, BIG round head, very stubby legs, big round ear-nubs,
    // cotton-ball tail, small toe-pads under each foot.
    // Parts: body(1) head(1) eyes(2) ears(2) tail(1) legs(4) toe-pads(4) = 15
    // =========================================================================
    private func drawKind0(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float) {
        let s   = e.scale
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol = baseCol * 0.68
        let bellyCol = baseCol * 0.92
        let eyeCol  = SIMD3<Float>(0.05, 0.05, 0.07)

        // Animation phases (different rates, all offset by hash)
        let blinkPhase  = phase + hash * 4.1
        let breathPhase = phase * 0.38 + hash * 1.7
        let earPhase    = phase + hash * 6.3
        let tailPhase   = phase + hash * 2.2

        // Hop: body lifts on abs(sin), quick snap back down
        let hopSpeed: Float  = 3.4
        let hopAmt    = abs(sin(phase * hopSpeed * 0.5)) * s * 0.10
        let legSqueeze = sin(phase * hopSpeed) * 0.08

        // Breathe: gentle Y bob on top of hop
        let breatheY = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)

        // Dimensions
        let bW = s * 0.70;  let bH = s * 0.50;  let bD = s * 0.75
        let hS = s * 0.62
        let legW = s * 0.18; let legH = s * 0.22; let legD = s * 0.18
        let earW = s * 0.22; let earH = s * 0.22; let earD = s * 0.22
        let toeW = s * 0.12; let toeH = s * 0.04; let toeD = s * 0.12

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + hopAmt + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        // Ear twitch angles (each ear independent)
        let earTwitchL = earTwitchAngle(earPhase, side: -1)
        let earTwitchR = earTwitchAngle(earPhase, side:  1)

        // Tail wag
        let tailAng = tailWagAngle(tailPhase)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        // Leg with pivot at hip, swing angle
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }
        // Toe-pad: sits at ground level below each leg
        func tw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            // Place toe at bottom of leg in leg-local space, then world
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH - toeH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(toeW, toeH, toeD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Belly tint — slightly lighter front-lower panel
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.18, bD * 0.20), SIMD3(bW * 0.75, bH * 0.58, bD * 0.38)),
                 rgb: bellyCol, sat: sat)
        // Head — sits right on top of body, slightly forward
        let headY = bH * 0.5 + hS * 0.5
        let headZ = bD * 0.15
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS, hS)), rgb: baseCol, sat: sat)
        // Eyes — with blink Y squish
        let eyeW = s * 0.10; let eyeH = s * 0.10 * eyeBlinkSY; let eyeD = s * 0.04
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS * 0.22, headY + hS * 0.08, headZ + hS * 0.50),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS * 0.22, headY + hS * 0.08, headZ + hS * 0.50),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        // Big round ears — ear-twitch rotX pivot at base of ear
        let earBaseY = headY + hS * 0.50
        do {
            let earPivotL = SIMD3<Float>(-hS * 0.30, earBaseY, headZ)
            let earPivotR = SIMD3<Float>( hS * 0.30, earBaseY, headZ)
            let earLModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(earPivotL)
                * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, earH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            let earRModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(earPivotR)
                * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, earH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            drawCube(enc: enc, viewProj: viewProj, model: earLModel, rgb: darkCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: earRModel, rgb: darkCol, sat: sat)
        }
        // Cotton-ball tail — wags side to side
        let tw2 = s * 0.20
        do {
            let tailPivot = SIMD3<Float>(0, bH * 0.20, -bD * 0.50)
            let tailModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailAng)
                * EntityRenderer.trans(SIMD3(0, 0, -tw2 * 0.5))
                * EntityRenderer.scaleM(SIMD3(tw2, tw2 * 0.85, tw2 * 0.80))
            drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: baseCol * 1.1, sat: sat)
        }
        // 4 stubby legs + toe pads beneath
        let hipY = -bH * 0.5
        let hipFL = SIMD3<Float>(-bW * 0.30, hipY,  bD * 0.28)
        let hipFR = SIMD3<Float>( bW * 0.30, hipY,  bD * 0.28)
        let hipBL = SIMD3<Float>(-bW * 0.30, hipY, -bD * 0.28)
        let hipBR = SIMD3<Float>( bW * 0.30, hipY, -bD * 0.28)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFL,  legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFR, -legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBL, -legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBR,  legSqueeze), rgb: darkCol, sat: sat)
        // Toe pads
        drawCube(enc: enc, viewProj: viewProj, model: tw(hipFL,  legSqueeze), rgb: darkCol * 0.85, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: tw(hipFR, -legSqueeze), rgb: darkCol * 0.85, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: tw(hipBL, -legSqueeze), rgb: darkCol * 0.85, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: tw(hipBR,  legSqueeze), rgb: darkCol * 0.85, sat: sat)
    }

    // =========================================================================
    // KIND 1 — tall lanky creature
    // Very long thin legs, tall narrow body, long neck, small head, pointed ears,
    // ankle knob, small round tail-bob at rear.
    // Parts: legs(4) ankle-knobs(4) body(1) neck(1) head(1) eyes(2) ears(2) tail-nub(1) = 16
    // =========================================================================
    private func drawKind1(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float) {
        let s   = e.scale
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol = baseCol * 0.65
        let spotCol = baseCol * 1.10   // lighter accent patches
        let eyeCol  = SIMD3<Float>(0.05, 0.05, 0.07)

        let blinkPhase  = phase + hash * 3.8
        let breathPhase = phase * 0.38 + hash * 2.1
        let earPhase    = phase + hash * 5.9
        let tailPhase   = phase + hash * 1.8

        let walkSpeed: Float = 2.2
        let legSwing  = sin(phase * walkSpeed) * 0.42
        let sway      = sin(phase * walkSpeed) * s * 0.04

        // Breathing: subtle neck sway amplitude modulation
        let breatheY  = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)

        // Ear twitch
        let earTwitchL = earTwitchAngle(earPhase, side: -1)
        let earTwitchR = earTwitchAngle(earPhase, side:  1)

        // Tail nub wag
        let tailAng = tailWagAngle(tailPhase) * 0.55   // less dramatic than k0

        // Tall narrow proportions
        let bW = s * 0.45;  let bH = s * 0.80;  let bD = s * 0.65
        let neckW = s * 0.20; let neckH = s * 0.55; let neckD = s * 0.20
        let hS = s * 0.32
        let legW = s * 0.14; let legH = s * 0.70; let legD = s * 0.14
        let ankleW = s * 0.20; let ankleH = s * 0.10; let ankleD = s * 0.20
        let earW = s * 0.10; let earH = s * 0.22; let earD = s * 0.10

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }
        // Ankle knob: at bottom of leg
        func aw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH - ankleH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(ankleW, ankleH, ankleD))
        }

        let hipY = -bH * 0.5
        let hipFL = SIMD3<Float>(-bW * 0.38, hipY,  bD * 0.32)
        let hipFR = SIMD3<Float>( bW * 0.38, hipY,  bD * 0.32)
        let hipBL = SIMD3<Float>(-bW * 0.38, hipY, -bD * 0.32)
        let hipBR = SIMD3<Float>( bW * 0.38, hipY, -bD * 0.32)

        // Legs
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFL,  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFR, -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBL, -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBR,  legSwing), rgb: darkCol, sat: sat)
        // Ankle knobs
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipFL,  legSwing), rgb: spotCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipFR, -legSwing), rgb: spotCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipBL, -legSwing), rgb: spotCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipBR,  legSwing), rgb: spotCol, sat: sat)
        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Neck
        let neckLocalY = bH * 0.5 + neckH * 0.5
        let neckLocalZ = bD * 0.20
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway, neckLocalY, neckLocalZ), SIMD3(neckW, neckH, neckD)),
                 rgb: baseCol, sat: sat)
        // Head
        let headTopY = neckLocalY + neckH * 0.5 + hS * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway, headTopY, neckLocalZ), SIMD3(hS, hS, hS)),
                 rgb: baseCol, sat: sat)
        // Eyes with blink
        let eyeW = s * 0.08; let eyeH = s * 0.08 * eyeBlinkSY; let eyeD = s * 0.04
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway - hS * 0.22, headTopY + hS * 0.06, neckLocalZ + hS * 0.50),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(sway + hS * 0.22, headTopY + hS * 0.06, neckLocalZ + hS * 0.50),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        // Pointy ears with twitch — pivot at ear base
        let earBaseY = headTopY + hS * 0.50
        do {
            let earPivotL = SIMD3<Float>(sway - hS * 0.28, earBaseY, neckLocalZ)
            let earPivotR = SIMD3<Float>(sway + hS * 0.28, earBaseY, neckLocalZ)
            let earLModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(earPivotL)
                * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, earH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            let earRModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(earPivotR)
                * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, earH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            drawCube(enc: enc, viewProj: viewProj, model: earLModel, rgb: darkCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: earRModel, rgb: darkCol, sat: sat)
        }
        // Small tail-nub at rear, wags
        let tnW = s * 0.12
        do {
            let tailPivot = SIMD3<Float>(0, bH * 0.30, -bD * 0.50)
            let tailModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailAng)
                * EntityRenderer.trans(SIMD3(0, 0, -tnW * 0.5))
                * EntityRenderer.scaleM(SIMD3(tnW, tnW, tnW * 0.80))
            drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: spotCol, sat: sat)
        }
    }

    // =========================================================================
    // KIND 2 — long low creature
    // Long body, very short legs, wide snout, back-ridge fin, thick tail,
    // belly stripe, nostril bumps on snout.
    // Parts: body(1) belly(1) head(1) snout(1) nostril-bumps(2) eyes(2) tail(1) fin(1) legs(4) = 14
    // =========================================================================
    private func drawKind2(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float) {
        let s   = e.scale
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol  = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol  = baseCol * 0.62
        let bellyCol = baseCol * 0.85
        let finCol   = baseCol * 0.78
        let eyeCol   = SIMD3<Float>(0.05, 0.05, 0.07)

        let blinkPhase  = phase + hash * 5.2
        let tailPhase   = phase + hash * 3.0
        // Fin oscillates slightly — a vertical flap
        let finPhase    = phase * 1.20 + hash * 2.5

        let waddleSpeed: Float = 2.6
        let rockAngle = sin(phase * waddleSpeed) * 0.14
        let legSwing  = sin(phase * waddleSpeed) * 0.22
        let tailSwing = -sin(phase * waddleSpeed * 1.3) * 0.28 + tailWagAngle(tailPhase) * 0.40

        let eyeBlinkSY = blinkScale(blinkPhase)
        let finBob = sin(finPhase) * s * 0.015   // fin tip oscillation expressed as Y translation

        // Long flat proportions
        let bW = s * 0.65;  let bH = s * 0.38;  let bD = s * 1.30
        let snoutW = s * 0.38; let snoutH = s * 0.28; let snoutD = s * 0.30
        let hS = s * 0.40
        let legW = s * 0.16; let legH = s * 0.24; let legD = s * 0.20
        let tailW = s * 0.28; let tailH = s * 0.22; let tailD = s * 0.38
        let nostW = s * 0.08; let nostH = s * 0.06; let nostD = s * 0.06

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        let rock = EntityRenderer.rotZ(rockAngle)
        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * rock * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * rock * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Belly stripe
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.20, bD * 0.15), SIMD3(bW * 0.90, bH * 0.55, bD * 0.55)),
                 rgb: bellyCol, sat: sat)
        // Head
        let headY = bH * 0.30
        let headZ = bD * 0.50 + hS * 0.40
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS * 0.80, hS)),
                 rgb: baseCol, sat: sat)
        // Snout
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hS * 0.10, headZ + hS * 0.45 + snoutD * 0.5),
                           SIMD3(snoutW, snoutH, snoutD)),
                 rgb: darkCol, sat: sat)
        // Nostril bumps on top-front of snout
        let nostrilZ = headZ + hS * 0.45 + snoutD
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-snoutW * 0.22, headY - hS * 0.10 + snoutH * 0.50 + nostH * 0.5, nostrilZ - nostD * 0.5),
                           SIMD3(nostW, nostH, nostD)),
                 rgb: darkCol * 0.85, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( snoutW * 0.22, headY - hS * 0.10 + snoutH * 0.50 + nostH * 0.5, nostrilZ - nostD * 0.5),
                           SIMD3(nostW, nostH, nostD)),
                 rgb: darkCol * 0.85, sat: sat)
        // Eyes — wide-set, with blink
        let eyeW = s * 0.04; let eyeH = s * 0.09 * eyeBlinkSY; let eyeD = s * 0.09
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS * 0.50, headY + hS * 0.10, headZ),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS * 0.50, headY + hS * 0.10, headZ),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        // Thick tail — behind body, swings + wags
        do {
            let tailHip = SIMD3<Float>(0, bH * 0.25, -bD * 0.50)
            let tailCenter = SIMD3<Float>(0, -tailH * 0.4, -tailD * 0.5)
            let tailModel = EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(tailHip)
                * EntityRenderer.rotY(tailSwing)
                * EntityRenderer.trans(tailCenter)
                * EntityRenderer.scaleM(SIMD3(tailW, tailH, tailD))
            drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: darkCol, sat: sat)
        }
        // Back ridge fin — slightly oscillates (finBob applied as Y offset)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH * 0.50 + s * 0.06 + finBob, -bD * 0.10),
                           SIMD3(s * 0.10, s * 0.12, bD * 0.65)),
                 rgb: finCol, sat: sat)
        // 4 short legs
        let hipY = -bH * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW * 0.38, hipY,  bD * 0.35),  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW * 0.38, hipY,  bD * 0.35), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW * 0.38, hipY, -bD * 0.35), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW * 0.38, hipY, -bD * 0.35),  legSwing), rgb: darkCol, sat: sat)
    }

    // =========================================================================
    // KIND 3 — chunky wide creature
    // Wide squat body, thick legs, two horns, nose ridge, shoulder pads, back tuft.
    // Parts: body(1) head(1) eyes(2) horns(2) nose-ridge(1) shoulder-pads(2) tuft(1) legs(4) = 14
    // =========================================================================
    private func drawKind3(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float) {
        let s   = e.scale
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol = baseCol * 0.65
        let hornCol = baseCol * 1.18
        let tufCol  = baseCol * 1.12
        let eyeCol  = SIMD3<Float>(0.05, 0.05, 0.07)

        let blinkPhase  = phase + hash * 4.7
        let breathPhase = phase * 0.38 + hash * 3.1
        let tufPhase    = phase * 0.55 + hash * 1.4   // tuft sways slowly

        let plodSpeed: Float = 1.8
        let legSwing  = sin(phase * plodSpeed) * 0.26
        let bodyBob   = abs(sin(phase * plodSpeed)) * s * 0.009

        let breatheY  = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)
        // Tuft sway: gentle side-to-side rotY
        let tufSway = sin(tufPhase) * 0.12
        // Horn jitter: tiny rotX on each horn, half-period offset
        let hornJitterL = sin(phase * 3.5 + hash * 2.0) * 0.025
        let hornJitterR = sin(phase * 3.5 + hash * 2.0 + 1.57) * 0.025

        // Wide squat proportions
        let bW = s * 1.10;  let bH = s * 0.55;  let bD = s * 0.85
        let hS = s * 0.58
        let legW = s * 0.28; let legH = s * 0.38; let legD = s * 0.28
        let hornW = s * 0.12; let hornH = s * 0.26; let hornD = s * 0.10
        let noseW = s * 0.28; let noseH = s * 0.08; let noseD = s * 0.10
        let padW  = s * 0.22; let padH  = s * 0.12; let padD  = s * 0.65

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + bodyBob + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Shoulder pads — slightly raised slabs on either side of body top
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bW * 0.50 - padW * 0.30, bH * 0.40, 0),
                           SIMD3(padW, padH, padD)),
                 rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( bW * 0.50 + padW * 0.30, bH * 0.40, 0),
                           SIMD3(padW, padH, padD)),
                 rgb: darkCol, sat: sat)
        // Head
        let headY: Float = bH * 0.20
        let headZ: Float = bD * 0.50 + hS * 0.42
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS * 0.80, hS * 0.75)),
                 rgb: baseCol, sat: sat)
        // Nose ridge on front of head
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hS * 0.20, headZ + hS * 0.35),
                           SIMD3(noseW, noseH, noseD)),
                 rgb: darkCol, sat: sat)
        // Eyes with blink
        let eyeW = s * 0.10; let eyeH = s * 0.10 * eyeBlinkSY; let eyeD = s * 0.04
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS * 0.24, headY + hS * 0.04, headZ + hS * 0.37),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS * 0.24, headY + hS * 0.04, headZ + hS * 0.37),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        // Horns — angled forward + subtle jitter
        let hornBaseY = headY + hS * 0.40 + hornH * 0.5
        let hornTiltFwd = EntityRenderer.rotX(-0.30)
        do {
            let hornModel1 = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3(-hS * 0.28, hornBaseY, headZ))
                * hornTiltFwd
                * EntityRenderer.rotZ(hornJitterL)
                * EntityRenderer.scaleM(SIMD3(hornW, hornH, hornD))
            let hornModel2 = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3( hS * 0.28, hornBaseY, headZ))
                * hornTiltFwd
                * EntityRenderer.rotZ(hornJitterR)
                * EntityRenderer.scaleM(SIMD3(hornW, hornH, hornD))
            drawCube(enc: enc, viewProj: viewProj, model: hornModel1, rgb: hornCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: hornModel2, rgb: hornCol, sat: sat)
        }
        // Tuft — back-top, sways side to side
        do {
            let tufPivot = SIMD3<Float>(0, bH * 0.50, -bD * 0.22)
            let tufModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tufPivot)
                * EntityRenderer.rotY(tufSway)
                * EntityRenderer.trans(SIMD3(0, s * 0.08, 0))
                * EntityRenderer.scaleM(SIMD3(bW * 0.60, s * 0.16, bD * 0.30))
            drawCube(enc: enc, viewProj: viewProj, model: tufModel, rgb: tufCol, sat: sat)
        }
        // 4 thick legs
        let hipY = -bH * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW * 0.38, hipY,  bD * 0.32),  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW * 0.38, hipY,  bD * 0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW * 0.38, hipY, -bD * 0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW * 0.38, hipY, -bD * 0.32),  legSwing), rgb: darkCol, sat: sat)
    }

    // =========================================================================
    // KIND 4 — BOSS
    // Bigger (scale * 1.5). Bulky wide body, massive head, crown of 3 spires
    // (center taller), 3 dorsal back spikes, shoulder armor plates,
    // GLOWING HDR eyes (emissive, sat = -1 sentinel → no shade multiply),
    // heavy stomp with pause, crown bob, spike quiver.
    // Parts: body(1) shoulder-armor(2) head(1) eyes(2) crown(3) back-spikes(3)
    //        chin-plate(1) legs(4) = 17
    // =========================================================================
    private func drawKind4(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float) {
        let s   = e.scale * 1.50   // boss is noticeably bigger
        let sat = e.sat
        let R   = EntityRenderer.rotY(e.yaw)
        let baseCol  = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol  = baseCol * 0.60
        let crownCol = baseCol * 1.25
        // HDR eye glow — luminance > 1 so the bloom pass picks it up
        // We want a vivid warm orange-amber that reads as glowing:
        let eyeGlowCol = SIMD3<Float>(2.8, 1.2, 0.1)

        let stompSpeed: Float = 1.4
        let legSwing  = sin(phase * stompSpeed) * 0.30
        // Heavy stomp: squared negative-half of sin gives sharp slam + hold
        let stompRaw  = sin(phase * stompSpeed)
        let stomp     = (stompRaw < 0 ? stompRaw * stompRaw : Float(0)) * s * 0.025

        // Crown bob: center spire bobs slightly on a separate clock
        let crownBob = sin(phase * 0.90 + hash * 1.5) * s * 0.015
        // Spike quiver: tiny rotX on the dorsal spikes
        let spikeQuiv = sin(phase * 2.40 + hash * 3.3) * 0.04

        // Blink: boss eyes flicker — rapid burst blink (more unsettling)
        let blinkPhase = phase * 1.8 + hash * 3.5
        let eyeBlinkSY = blinkScale(blinkPhase)

        // Massive proportions
        let bW = s * 1.00;  let bH = s * 0.75;  let bD = s * 0.90
        let hS = s * 0.72
        let legW = s * 0.30; let legH = s * 0.50; let legD = s * 0.30
        let crownW = s * 0.16; let crownH = s * 0.38; let crownD = s * 0.16
        let spkW = s * 0.14; let spkH = s * 0.28; let spkD = s * 0.10
        let armorW = s * 0.28; let armorH = s * 0.30; let armorD = s * 0.72
        let chinW = s * 0.38; let chinH = s * 0.12; let chinD = s * 0.22

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + stomp
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Shoulder armor plates — wide slabs flanking body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bW * 0.50 - armorW * 0.40, bH * 0.30, 0),
                           SIMD3(armorW, armorH, armorD)),
                 rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( bW * 0.50 + armorW * 0.40, bH * 0.30, 0),
                           SIMD3(armorW, armorH, armorD)),
                 rgb: darkCol, sat: sat)
        // Dorsal back spikes along top of body (3 spikes, quiver)
        let spikeBaseY = bH * 0.50 + spkH * 0.5
        do {
            let spkTilt = EntityRenderer.rotX(spikeQuiv)
            let spikeOffsets: [(Float, Float)] = [(-bD * 0.25, 1.0), (0, 1.25), (bD * 0.25, 0.85)]
            for (zOff, sFactor) in spikeOffsets {
                let spkModel = EntityRenderer.trans(wc) * R
                    * EntityRenderer.trans(SIMD3(0, spikeBaseY, zOff))
                    * spkTilt
                    * EntityRenderer.scaleM(SIMD3(spkW, spkH * sFactor, spkD))
                drawCube(enc: enc, viewProj: viewProj, model: spkModel, rgb: crownCol, sat: sat)
            }
        }
        // Head — massive, forward
        let headY: Float = bH * 0.35
        let headZ: Float = bD * 0.50 + hS * 0.38
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS, hS * 0.85)),
                 rgb: baseCol, sat: sat)
        // Chin plate — heavy jaw
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hS * 0.42, headZ + hS * 0.10),
                           SIMD3(chinW, chinH, chinD)),
                 rgb: darkCol, sat: sat)
        // Glowing HDR eyes — emissive (sat = -1.0 sentinel, no shading multiply)
        let eyeW = s * 0.14; let eyeH = s * 0.14 * eyeBlinkSY; let eyeD = s * 0.05
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS * 0.24, headY + hS * 0.08, headZ + hS * 0.43),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeGlowCol, sat: -1.0)  // emissive — bypasses shade
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS * 0.24, headY + hS * 0.08, headZ + hS * 0.43),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeGlowCol, sat: -1.0)  // emissive
        // Crown — 3 spires, center taller, bob on separate phase
        let crownBaseY = headY + hS * 0.50
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, crownBaseY + crownH * 0.60 + crownBob, headZ),
                           SIMD3(crownW, crownH * 1.20, crownD)),
                 rgb: crownCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS * 0.30, crownBaseY + crownH * 0.50, headZ),
                           SIMD3(crownW, crownH, crownD)),
                 rgb: crownCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS * 0.30, crownBaseY + crownH * 0.50, headZ),
                           SIMD3(crownW, crownH, crownD)),
                 rgb: crownCol, sat: sat)
        // 4 massive legs
        let hipY = -bH * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW * 0.38, hipY,  bD * 0.32),  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW * 0.38, hipY,  bD * 0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW * 0.38, hipY, -bD * 0.32), -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW * 0.38, hipY, -bD * 0.32),  legSwing), rgb: darkCol, sat: sat)
    }

    // -----------------------------------------------------------------------
    // Draw one unit cube with given model matrix and color.
    // sat = -1.0 is the emissive sentinel: fragment shader skips shading multiply.
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
    // MSL shader.
    // EUniforms.color.w == -1.0 is the emissive sentinel.
    // Emissive cubes bypass the shading multiply and output HDR color directly,
    // which blooms in the existing rgba16Float → bloom pass.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CVert     { packed_float3 pos; packed_float3 normal; };
    struct EUniforms { float4x4 mvp; float4 color; };
    struct EOut      { float4 position [[position]]; float3 color; float shade; float sat; };

    vertex EOut evmain(uint vid [[vertex_id]],
                       device const CVert* v [[buffer(0)]],
                       constant EUniforms& u  [[buffer(1)]]) {
        CVert cv = v[vid];
        float3 n = float3(cv.normal);
        // Directional shading: top bright, sides medium, bottom dim.
        float shade = clamp(0.55 + 0.30 * n.y + 0.15 * n.x, 0.0, 1.0);
        EOut o;
        o.position = u.mvp * float4(float3(cv.pos), 1.0);
        o.color    = u.color.rgb;
        o.shade    = shade;
        o.sat      = u.color.w;   // -1.0 = emissive
        return o;
    }

    fragment float4 efmain(EOut in [[stage_in]]) {
        // Emissive path: sat < 0 → output HDR color unmodified (glows in bloom).
        if (in.sat < 0.0) {
            return float4(in.color, 1.0);
        }
        float3 c = in.color * in.shade;
        // Dim desaturation: mix toward luminance by (1 - sat).
        float l = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(l), c, clamp(in.sat, 0.0, 1.0));
        return float4(c, 1.0);
    }
    """
}
