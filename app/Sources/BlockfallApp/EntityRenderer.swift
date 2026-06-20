// ============================================================================
// Blockfall — EntityRenderer (M5 enhanced: distinct animal silhouettes + night monster)
// Draws creatures as multi-part blocky animals.
//
// kind 0 — BUNNY/critter:   round low body, TALL upright ears (3× body height),
//           big cottontail, tiny stubby legs, wide head, hops.
//           silhouette: round blob with two tall spikes above it.
//
// kind 1 — GIRAFFE-ish:     very long neck (>body height), long thin stilt legs,
//           tiny high head, short tail with tuft-tip block.
//           silhouette: tall vertical tower, thin top-heavy mast.
//
// kind 2 — LIZARD/gecko:    flat wide body close to ground, 4 wide-splayed legs,
//           long curling tail behind, wide flat head, nostril bumps, scuttle.
//           silhouette: low wide smear with long tail streaking behind.
//
// kind 3 — RAM/boar:        chunky barrel body, BIG swept curved horns (2-segment arc),
//           low wide head, prominent snout block, stubby hooves.
//           silhouette: wide squat rectangle with horn-arcs sweeping out both sides.
//
// kind 4 — BOSS (friendly): clearly biggest (scale * 1.5), crown of 3 spires,
//           shoulder armor, dorsal spikes, GLOWING HDR amber eyes, heavy stomp.
//           silhouette: massive block with spire crown and armor flanges.
//
// kind 5 — NIGHT MONSTER:   dark hunched body (tilted forward), 6 sharp limbs
//           (4 legs + 2 clawed arms), jagged back spikes, GLOWING HDR RED eyes
//           (luminance > 1 → bloom), gaping mouth slit, skittering lurching gait.
//           silhouette: hunched pointed mass with splayed limbs and glowing eyes.
//
// kind 6 — FALLING BLOCK:   single 0.9³ cube centered on entity position.
//           uses entity color directly (block colour from engine — no creature
//           palette). entity yaw drives a continuous Y-axis spin so the cube
//           tumbles visibly; a fixed 0.35-rad X tilt makes the spin read in 3D.
//           directional shading applied (top bright, sides mid, bottom dark)
//           so the block has visible form — no legs, eyes, or animation beyond
//           the tumble. sat from entity is passed through unchanged.
//
// Animation list (unchanged from M5):
//   BLINK       — per-creature cadence: eyes squish flat for ~0.08s every 3-6s
//   BREATHE     — gentle body Y-bob + slight XZ scale pulse, ~0.4 Hz
//   TAIL WAG    — continuous side-to-side sine, always-on, independent freq
//   EAR TWITCH  — brief rotX flick on ears, one ear at a time, ~2-4s intervals
//   WALK CYCLE  — front/back leg pairs swing opposite phases; gait per species
//   LOCOMOTION  — speed-scaled via phase rate (always at 1× since no speed field)
//   BOSS STOMP  — squared abs(sin) so foot slams hard then holds
//   BOSS HDR    — emissive eyes write luminance > 1.0 into rgba16Float; bloom pass picks them up
//   MONSTER SKITTER — fast erratic leg flicker, body rocks, arms claw forward/back
//   MONSTER HDR — glowing RED eyes (3.5, 0.05, 0.05) → strong bloom
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
// output color directly (no shading multiply). Used for boss HDR eyes and
// monster HDR eyes. Engine sat is 0..1 so negative is safe as a sentinel.
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

    // =========================================================================
    // HIT REACTION — combat feedback ("you just click and poof" → make it land)
    //
    // The engine's bf_entity_draw ABI (contract/engine_c_api.h) currently has NO
    // hit/hurt/flash field — only position, yaw, color, scale, kind, sat, _pad.
    // We must NOT change the ABI here, so the hit signal is derived locally:
    //
    //   SIGNAL USED: a sudden drop in an entity's `scale` between frames.
    //   When the engine damages a creature it almost always shrinks/knocks it
    //   (or it vanishes outright on death). We key a tiny per-entity history by
    //   a quantized (position, kind) hash, remember last frame's scale, and when
    //   scale drops sharply (>12%) we fire a short hit window for that entity.
    //
    //   The reaction itself (flash white→red + squash-recoil) lives in
    //   `hitReaction(progress:)` and is applied to every cube via `flashRGB`
    //   and the body-level `squash`. It is written so the lead can ALSO drive
    //   it directly: if/when an engine hit-flash field is added (the natural
    //   home is the reserved `_pad` slot — e.g. low byte = frames-since-hit, or
    //   a float 0..1 hurt value), set `externalHurt01` per entity in `encode`
    //   and it takes precedence over the derived signal. Until then it is a
    //   robust no-op when nothing is hit.
    //
    // Cost: one dictionary probe + a few float ops per entity per frame, and a
    // periodic prune. Cheap for dozens on screen.
    // =========================================================================
    private struct EntityHist {
        var lastScale:  Float
        var lastSeen:   Float   // wall-clock time last observed
        var hitAt:      Float   // wall-clock time the last hit fired (-1 = none)
    }
    private var hist: [UInt64: EntityHist] = [:]
    private var lastPrune: Float = 0

    /// Duration of the hit reaction in seconds (flash + squash recoil).
    private let hitDuration: Float = 0.32

    // Per-entity reaction state for the CURRENTLY drawing creature. Set once at
    // the top of each entity's draw in `encode`, read by `drawCube`. Avoids
    // threading a new parameter through every drawKindN signature.
    private var curFlash: SIMD3<Float> = .zero   // additive color toward white/red
    private var curFlashAmt: Float = 0           // 0..1 strength (for emissive parts)

    /// Quantize (pos, kind) into a stable-ish key so a creature maps to the same
    /// history bucket across frames despite small movement. 0.5-unit cells.
    @inline(__always)
    private func histKey(_ pos: SIMD3<Float>, _ kind: UInt32) -> UInt64 {
        let qx = UInt64(bitPattern: Int64((pos.x * 2.0).rounded()))
        let qy = UInt64(bitPattern: Int64((pos.y * 2.0).rounded()))
        let qz = UInt64(bitPattern: Int64((pos.z * 2.0).rounded()))
        // Mix; keep it cheap. kind in the low bits keeps distinct species apart.
        var h = qx &* 0x9E3779B1
        h = (h ^ (qz &* 0x85EBCA77)) &* 0xC2B2AE3D
        h = h ^ (qy &* 0x27D4EB2F) ^ UInt64(kind)
        return h
    }

    /// Hit reaction curve. `p` is 0 (just hit) → 1 (recovered).
    /// Returns: flash color (additive, fades fast), flash strength, and a
    /// per-axis squash scale (squash down + bulge wide, then settle).
    @inline(__always)
    private func hitReaction(_ p: Float) -> (flash: SIMD3<Float>, amt: Float, squash: SIMD3<Float>) {
        let q = max(0, min(1, p))
        // Flash: bright white the first ~third, decaying into red, then gone.
        // amt drops as a fast ease-out so the pop is snappy not laggy.
        let amt = (1.0 - q) * (1.0 - q)
        // hot white early, shifting toward red as it fades
        let white = SIMD3<Float>(1.0, 1.0, 1.0)
        let red   = SIMD3<Float>(1.0, 0.18, 0.12)
        let flash = simd_mix(red, white, SIMD3<Float>(repeating: max(0, 1.0 - q * 2.2))) * amt
        // Squash recoil: quick downward smash that springs back with a small
        // overshoot. abs/decay so it reads as a single recoil, not a wobble.
        let env   = (1.0 - q)
        let osc   = sin(q * 11.0) * env * env      // damped spring
        let sy    = 1.0 - osc * 0.22               // flatten vertically on impact
        let sxz   = 1.0 + osc * 0.14               // bulge horizontally
        return (flash, amt, SIMD3<Float>(sxz, sy, sxz))
    }

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

        // Periodically prune stale history so the dictionary can't grow without
        // bound as creatures spawn/despawn. Cheap: every ~2s.
        if t - lastPrune > 2.0 {
            lastPrune = t
            hist = hist.filter { t - $0.value.lastSeen < 1.5 }
        }

        for i in 0..<count {
            let e = entities[i]
            let pos = SIMD3<Float>(e.position.x, e.position.y, e.position.z)
            // Per-entity spatial hash — scatters all animation phases so
            // dozens of creatures never step in sync.
            let phaseHash = sin(pos.x * 1.3 + pos.z * 2.7)
            let phase     = t + phaseHash * 3.14159

            // --- HIT REACTION: derive a hurt signal & build the per-entity
            // reaction (flash + squash). Falling blocks (kind 6) are exempt.
            var squash = SIMD3<Float>(1, 1, 1)
            curFlash    = .zero
            curFlashAmt = 0
            if e.kind != 6 {
                // CONTINUOUS LIVELINESS: a tiny always-on breathing pulse on the
                // whole-creature squash so nothing ever looks frozen, even when
                // stationary and not mid-hit. Very subtle (<1.5%) and phase-
                // scattered so a crowd doesn't pulse in unison. This rides
                // *through* the same squash channel, so it's free.
                let idle = sin(phase * 0.9) * 0.012
                squash = SIMD3<Float>(1 - idle * 0.5, 1 + idle, 1 - idle * 0.5)

                let key = histKey(pos, e.kind)
                if var h = hist[key] {
                    // SIGNAL: a sharp drop in scale this frame ≈ damage/recoil.
                    // (See class-level note: swap for an engine field when one
                    // exists — set externalHurt01 and skip this derivation.)
                    if h.lastScale > 0.0001,
                       e.scale < h.lastScale * 0.88,
                       (h.hitAt < 0 || t - h.hitAt > hitDuration) {
                        h.hitAt = t
                    }
                    h.lastScale = e.scale
                    h.lastSeen  = t
                    if h.hitAt >= 0, t - h.hitAt < hitDuration {
                        let p = (t - h.hitAt) / hitDuration
                        let r = hitReaction(p)
                        // Hit squash dominates the idle pulse during the window.
                        squash      = r.squash
                        curFlash    = r.flash
                        curFlashAmt = r.amt
                    }
                    hist[key] = h
                } else {
                    hist[key] = EntityHist(lastScale: e.scale, lastSeen: t, hitAt: -1)
                }
            }

            switch e.kind {
            case 0:  drawKind0(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 1:  drawKind1(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 2:  drawKind2(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 3:  drawKind3(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 4:  drawKind4(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 5:  drawKind5(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 6:  drawKind6(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase)
            default: drawKind0(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            }
            // Clear so kind 6 (and the next iter before it sets) never inherit.
            curFlash    = .zero
            curFlashAmt = 0
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

    /// Build the per-creature hit-reaction SQUASH transform, expressed in the
    /// creature's post-yaw local frame so it can be folded straight into the
    /// rotation matrix (R = rotY * squash) and thus apply to EVERY part —
    /// body, head, legs, horns, ears, tail — with no per-part changes.
    ///
    /// The squash pivots about the creature's foot/ground contact so the recoil
    /// reads as "smashed down into the ground" and the feet stay planted.
    /// `footLocalY` is the ground height in local space = groundY - wc.y (<= 0).
    @inline(__always)
    private func squashRig(_ rotY: simd_float4x4,
                           squash: SIMD3<Float>,
                           footLocalY: Float) -> simd_float4x4 {
        // Identity fast-path: no allocation of trans/scale chains when at rest.
        if squash.x == 1 && squash.y == 1 && squash.z == 1 { return rotY }
        let toFoot   = EntityRenderer.trans(SIMD3<Float>(0, footLocalY, 0))
        let fromFoot = EntityRenderer.trans(SIMD3<Float>(0, -footLocalY, 0))
        return rotY * toFoot * EntityRenderer.scaleM(squash) * fromFoot
    }

    // -------------------------------------------------------------------------
    // FACE PARTS — small reusable face features placed on the FRONT (+Z, local)
    // of a head. Because every creature's parts are drawn as
    //   trans(wc) * R * trans(local) * scale,  and R already includes rotY(yaw),
    // anything we place at +Z local automatically sits on the front of the head
    // along the creature's facing direction. So faces always look where the
    // creature moves — no extra orientation math needed. (R also carries the
    // hit squash, so faces squash with the body too.)
    //
    // `pw` is the caller's part-world closure (lo, dims) -> matrix, identical to
    // the ones each drawKind defines. We just feed face-part positions through it.
    // -------------------------------------------------------------------------

    /// A single rounded eye: white sclera + dark pupil + tiny highlight.
    /// `c` = eye center (local), `r` = eye radius (x = width, y = height incl.
    /// blink already applied by caller, z = depth bulge). `look` shifts the pupil
    /// toward +Z/front-down for a friendly downward gaze (set 0 for forward).
    /// `scleraCol`/`pupilCol` let species tint the eye.
    @inline(__always)
    private func drawEye(enc: MTLRenderCommandEncoder, viewProj: simd_float4x4,
                         pw: (SIMD3<Float>, SIMD3<Float>) -> simd_float4x4,
                         c: SIMD3<Float>, r: SIMD3<Float>, sat: Float,
                         scleraCol: SIMD3<Float>, pupilCol: SIMD3<Float>) {
        // Sclera
        drawCube(enc: enc, viewProj: viewProj, model: pw(c, SIMD3(r.x, r.y, r.z)),
                 rgb: scleraCol, sat: sat)
        // Pupil — slightly smaller, pushed to the very front so it reads on top
        let pupil = SIMD3<Float>(r.x * 0.55, r.y * 0.62, r.z * 0.9)
        let pupilC = SIMD3<Float>(c.x, c.y - r.y * 0.05, c.z + r.z * 0.45)
        drawCube(enc: enc, viewProj: viewProj, model: pw(pupilC, pupil),
                 rgb: pupilCol, sat: sat)
        // Highlight — tiny bright fleck upper-outer of pupil (catchlight = life)
        let hl = SIMD3<Float>(r.x * 0.22, r.y * 0.24, r.z * 0.5)
        let hlC = SIMD3<Float>(c.x + r.x * 0.18, c.y + r.y * 0.22, c.z + r.z * 0.7)
        drawCube(enc: enc, viewProj: viewProj, model: pw(hlC, hl),
                 rgb: SIMD3<Float>(0.98, 0.98, 1.0), sat: sat)
    }

    // =========================================================================
    // KIND 0 — BUNNY / small critter
    //
    // Silhouette: very round compact body sitting low, TWO TALL UPRIGHT EARS
    // rising dramatically above it (~3× body height), big puffy cottontail at
    // rear, tiny stubby legs hidden under body. The ear-spikes make it
    // unmistakable at a glance.
    //
    // Hop: whole body rises quickly and slaps back down.
    // Ear twitch: each ear flicks independently.
    // Cottontail: wags horizontally.
    //
    // Parts: body(1) belly(1) head(1) eyes(2) nose(1)
    //        TALL ears(2) ear-inner(2) cottontail(1) legs(4) = 15
    // =========================================================================
    private func drawKind0(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let baseCol  = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let bellyCol = baseCol * 0.96
        let innerEarCol = SIMD3<Float>(
            min(1.0, baseCol.x * 0.90 + 0.22),
            min(1.0, baseCol.y * 0.55 + 0.10),
            min(1.0, baseCol.z * 0.55 + 0.10))   // pinkish inner ear
        let darkCol  = baseCol * 0.65
        let eyeCol   = SIMD3<Float>(0.04, 0.04, 0.06)
        let noseCol  = SIMD3<Float>(0.85, 0.30, 0.32)   // pink nose

        let blinkPhase  = phase + hash * 4.1
        let breathPhase = phase * 0.38 + hash * 1.7
        let earPhase    = phase + hash * 6.3
        let tailPhase   = phase + hash * 2.2

        // Hop: quick rise, slow fall (abs of sharpened sin)
        let hopSpeed: Float = 3.8
        let hopAmt    = pow(max(0, sin(phase * hopSpeed * 0.5)), 2.0) * s * 0.18
        // Leg: squeeze inward on landing
        let legSqueeze = sin(phase * hopSpeed) * 0.10

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)

        // Dimensions — round and compact, BIG head
        let bW = s * 0.62;  let bH = s * 0.44;  let bD = s * 0.60
        let hS = s * 0.50   // head nearly as wide as body, round
        // TALL ears — defining feature
        let earW = s * 0.15; let earH = s * 0.58; let earD = s * 0.12
        let innerW = s * 0.08; let innerH = s * 0.44; let innerD = s * 0.02
        // Short stubby legs
        let legW = s * 0.16; let legH = s * 0.18; let legD = s * 0.16
        // Cottontail
        let ctW  = s * 0.22; let ctH = s * 0.20; let ctD = s * 0.18

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + hopAmt + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        // Fold hit-squash into the rotation so every part recoils together,
        // pivoting about the ground contact (local Y = groundY - wc.y).
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        let earTwitchL = earTwitchAngle(earPhase, side: -1)
        let earTwitchR = earTwitchAngle(earPhase, side:  1)
        let tailAng    = tailWagAngle(tailPhase)

        // Body — round sphere-like block
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Belly — lighter, slightly forward and low
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.15, bD * 0.22), SIMD3(bW * 0.72, bH * 0.55, bD * 0.36)),
                 rgb: bellyCol, sat: sat)

        // Head — large and round, sits on top of body
        let headY = bH * 0.50 + hS * 0.46
        let headZ = bD * 0.08
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS * 0.95, hS * 0.90)),
                 rgb: baseCol, sat: sat)

        // FACE — BUNNY: BIG round dark eyes (sclera + pupil + catchlight), pink
        // nose, tiny buck teeth, soft cheek blush. Biggest eyes of any species
        // so the bunny reads as the cute/innocent one at a glance.
        let faceZ  = headZ + hS * 0.46
        let eyeW = s * 0.15; let eyeH = s * 0.17 * eyeBlinkSY; let eyeD = s * 0.05
        let eyeY = headY + hS * 0.10
        // Bunny eyes are nearly all dark pupil with a strong highlight (doe-eyed)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hS * 0.27, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: eyeCol, pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hS * 0.27, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: eyeCol, pupilCol: eyeCol)
        // Cheek blush — soft pink dots low on the cheeks
        let blush = SIMD3<Float>(min(1, baseCol.x * 0.6 + 0.4), baseCol.y * 0.5 + 0.2, baseCol.z * 0.5 + 0.25)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS * 0.40, headY - hS * 0.14, headZ + hS * 0.42), SIMD3(s*0.10, s*0.07, s*0.02)),
                 rgb: blush, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS * 0.40, headY - hS * 0.14, headZ + hS * 0.42), SIMD3(s*0.10, s*0.07, s*0.02)),
                 rgb: blush, sat: sat)
        // Nose — pink triangle-ish block at front-center
        let noseY = headY - hS * 0.06
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, noseY, faceZ + hS * 0.04), SIMD3(s * 0.09, s * 0.06, s * 0.04)),
                 rgb: noseCol, sat: sat)
        // Buck teeth — two little white blocks below the nose (bunny signature)
        let toothCol = SIMD3<Float>(0.97, 0.97, 0.93)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-s * 0.035, noseY - hS * 0.12, faceZ), SIMD3(s*0.05, s*0.09, s*0.03)),
                 rgb: toothCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( s * 0.035, noseY - hS * 0.12, faceZ), SIMD3(s*0.05, s*0.09, s*0.03)),
                 rgb: toothCol, sat: sat)

        // TALL UPRIGHT EARS — the key silhouette feature
        // Pivot at base of ear (on top of head), rotate upright with slight outward lean
        let earBaseY = headY + hS * 0.48
        let earLeanL = EntityRenderer.rotZ( 0.12)   // lean left ear slightly outward
        let earLeanR = EntityRenderer.rotZ(-0.12)   // lean right ear slightly outward
        do {
            let pivotL = SIMD3<Float>(-hS * 0.24, earBaseY, headZ)
            let pivotR = SIMD3<Float>( hS * 0.24, earBaseY, headZ)
            // Outer ear
            let earLModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(pivotL)
                * earLeanL
                * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, earH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            let earRModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(pivotR)
                * earLeanR
                * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, earH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            drawCube(enc: enc, viewProj: viewProj, model: earLModel, rgb: baseCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: earRModel, rgb: baseCol, sat: sat)
            // Inner ear — thin pink stripe slightly in front
            let innerLModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(pivotL)
                * earLeanL
                * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, innerH * 0.5 + earH * 0.04, innerD * 0.5 + earD * 0.5))
                * EntityRenderer.scaleM(SIMD3(innerW, innerH, innerD))
            let innerRModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(pivotR)
                * earLeanR
                * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, innerH * 0.5 + earH * 0.04, innerD * 0.5 + earD * 0.5))
                * EntityRenderer.scaleM(SIMD3(innerW, innerH, innerD))
            drawCube(enc: enc, viewProj: viewProj, model: innerLModel, rgb: innerEarCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: innerRModel, rgb: innerEarCol, sat: sat)
        }

        // Cottontail — big puffy white ball at back, wags
        do {
            let tailPivot = SIMD3<Float>(0, bH * 0.12, -bD * 0.50)
            let tailModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailAng)
                * EntityRenderer.trans(SIMD3(0, 0, -ctD * 0.5))
                * EntityRenderer.scaleM(SIMD3(ctW, ctH, ctD))
            drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: SIMD3<Float>(1.0, 1.0, 1.0), sat: sat)
        }

        // 4 tiny stubby legs
        let hipY = -bH * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW * 0.30, hipY,  bD * 0.28),  legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW * 0.30, hipY,  bD * 0.28), -legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW * 0.30, hipY, -bD * 0.28), -legSqueeze), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW * 0.30, hipY, -bD * 0.28),  legSqueeze), rgb: darkCol, sat: sat)
    }

    // =========================================================================
    // KIND 1 — GIRAFFE-ish browser
    //
    // Silhouette: extraordinarily tall. Very long thin neck rising from a
    // compact barrel body, tiny small head perched way up top, 4 long stilt
    // legs below. Short tail with a dark tuft-block at tip. Gentle stride with
    // neck swaying side to side.
    //
    // Height breakdown (in units of s):
    //   legs:  0.90   neck: 1.20   head: 0.28   total tower: ~2.4
    //   body:  0.65 (sits mid-leg height)
    //
    // Parts: legs(4) ankle-bands(4) body(1) neck(1) head(1) eyes(2) ossicones(2)
    //        tail-shaft(1) tail-tuft(1) = 17
    // =========================================================================
    private func drawKind1(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let baseCol  = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let patchCol = baseCol * 0.62        // darker irregular patch color
        let legCol   = baseCol * 0.75
        let eyeCol   = SIMD3<Float>(0.05, 0.03, 0.02)   // warm dark brown gentle eyes

        let blinkPhase  = phase + hash * 3.8
        let breathPhase = phase * 0.38 + hash * 2.1
        let tailPhase   = phase + hash * 1.8

        let walkSpeed: Float = 1.9
        let legSwing  = sin(phase * walkSpeed) * 0.36
        // Neck sways side to side with the walk
        let neckSway  = sin(phase * walkSpeed * 0.85 + 0.4) * s * 0.06

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)

        // Tail: short shaft + tuft wag
        let tailAng    = tailWagAngle(tailPhase) * 0.45

        // Giraffe proportions — the tall vertical stack is the key
        let bW = s * 0.58;  let bH = s * 0.65;  let bD = s * 0.72
        // Very long thin legs — THE defining visual
        let legW = s * 0.12; let legH = s * 0.92; let legD = s * 0.12
        // Ankle band (dark ring at bottom of leg)
        let ankW = s * 0.18; let ankH = s * 0.08; let ankD = s * 0.18
        // Very long neck
        let neckW = s * 0.18; let neckH = s * 1.20; let neckD = s * 0.18
        // Tiny head at top
        let hW = s * 0.30; let hH = s * 0.28; let hD = s * 0.36
        // Ossicones — short stubby horn-knobs on top of head
        let ossW = s * 0.07; let ossH = s * 0.16; let ossD = s * 0.07

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }
        // Ankle band — just below leg bottom
        func aw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH + ankH * 0.1, 0))
                * EntityRenderer.scaleM(SIMD3(ankW, ankH, ankD))
        }

        let hipY = -bH * 0.5
        let hipFL = SIMD3<Float>(-bW * 0.36, hipY,  bD * 0.34)
        let hipFR = SIMD3<Float>( bW * 0.36, hipY,  bD * 0.34)
        let hipBL = SIMD3<Float>(-bW * 0.36, hipY, -bD * 0.34)
        let hipBR = SIMD3<Float>( bW * 0.36, hipY, -bD * 0.34)

        // 4 long stilt legs
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFL,  legSwing), rgb: legCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFR, -legSwing), rgb: legCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBL, -legSwing), rgb: legCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBR,  legSwing), rgb: legCol,   sat: sat)
        // Ankle bands
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipFL,  legSwing), rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipFR, -legSwing), rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipBL, -legSwing), rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipBR,  legSwing), rgb: patchCol, sat: sat)

        // Body — compact barrel
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Patch marking on body flank
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( bW * 0.38, bH * 0.15, bD * 0.10), SIMD3(s * 0.04, s * 0.22, s * 0.26)),
                 rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bW * 0.38, bH * 0.10, -bD * 0.15), SIMD3(s * 0.04, s * 0.18, s * 0.20)),
                 rgb: patchCol, sat: sat)

        // Long neck — leans slightly forward, sways with walk
        let neckBaseY = bH * 0.50
        let neckFwdZ  = bD * 0.25
        let neckTilt  = EntityRenderer.rotX(-0.18)   // neck leans forward (browsing posture)
        let neckModel = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3(neckSway, neckBaseY, neckFwdZ))
            * neckTilt
            * EntityRenderer.trans(SIMD3(0, neckH * 0.5, 0))
            * EntityRenderer.scaleM(SIMD3(neckW, neckH, neckD))
        drawCube(enc: enc, viewProj: viewProj, model: neckModel, rgb: baseCol, sat: sat)

        // Head — tiny, at top of neck, leaning forward
        // Compute head position: top of neck after tilt
        let neckTopLY  = neckBaseY + cos(-0.18) * neckH      // approx local Y travel
        let neckTopLZ  = neckFwdZ  + sin( 0.18) * neckH      // approx local Z travel
        let headY      = neckTopLY + hH * 0.38
        let headZ      = neckTopLZ + hD * 0.15
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: baseCol, sat: sat)

        // FACE — GIRAFFE: long gentle snout jutting forward, soft front-facing
        // eyes with long lashes, two nostrils at the snout tip. Eyes are gentle
        // (calm, half-lidded look via a brow shade above) to read as docile.
        let snoutZ = headZ + hD * 0.50 + s * 0.16
        // Long snout — lighter muzzle extending forward off the small head
        let muzzleCol = SIMD3<Float>(min(1, baseCol.x*0.7+0.22), min(1, baseCol.y*0.7+0.18), min(1, baseCol.z*0.6+0.12))
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway, headY - hH * 0.10, snoutZ),
                           SIMD3(hW * 0.66, hH * 0.66, s * 0.34)),
                 rgb: muzzleCol, sat: sat)
        // Nostrils — two dark dots at the very tip of the snout
        let nostCol = baseCol * 0.45
        let nostZ = snoutZ + s * 0.18
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway - hW * 0.18, headY - hH * 0.14, nostZ), SIMD3(s*0.05, s*0.05, s*0.03)),
                 rgb: nostCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway + hW * 0.18, headY - hH * 0.14, nostZ), SIMD3(s*0.05, s*0.05, s*0.03)),
                 rgb: nostCol, sat: sat)
        // Gentle eyes — front-facing, with pupil + highlight, set wide on the
        // small head. Smaller and softer than the bunny's.
        let gfFaceZ = headZ + hD * 0.46
        let geW = s * 0.07; let geH = s * 0.09 * eyeBlinkSY; let geD = s * 0.05
        let geY = headY + hH * 0.18
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(neckSway - hW * 0.34, geY, gfFaceZ), r: SIMD3(geW, geH, geD),
                sat: sat, scleraCol: SIMD3(0.95, 0.92, 0.86), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(neckSway + hW * 0.34, geY, gfFaceZ), r: SIMD3(geW, geH, geD),
                sat: sat, scleraCol: SIMD3(0.95, 0.92, 0.86), pupilCol: eyeCol)
        // Long eyelashes — thin dark line above each eye (the giraffe's charm)
        let lashCol = SIMD3<Float>(0.06, 0.04, 0.03)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway - hW * 0.34, geY + geH * 1.3, gfFaceZ), SIMD3(geW * 1.5, s*0.02, geD)),
                 rgb: lashCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway + hW * 0.34, geY + geH * 1.3, gfFaceZ), SIMD3(geW * 1.5, s*0.02, geD)),
                 rgb: lashCol, sat: sat)

        // Ossicones — tiny nubby horn-knobs on top of head (giraffe's distinctive horns)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway - hW * 0.28, headY + hH * 0.50 + ossH * 0.5, headZ - hD * 0.10),
                           SIMD3(ossW, ossH, ossD)),
                 rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway + hW * 0.28, headY + hH * 0.50 + ossH * 0.5, headZ - hD * 0.10),
                           SIMD3(ossW, ossH, ossD)),
                 rgb: patchCol, sat: sat)

        // Short tail with tuft — shaft + darker tuft block at tip
        let tailShaftW = s * 0.08; let tailShaftH = s * 0.14; let tailShaftD = s * 0.08
        let tailTuftW  = s * 0.14; let tailTuftH  = s * 0.12; let tailTuftD  = s * 0.10
        do {
            let tailPivot = SIMD3<Float>(0, bH * 0.35, -bD * 0.50)
            let shaftModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailAng)
                * EntityRenderer.trans(SIMD3(0, -tailShaftH * 0.5, -tailShaftD * 0.5))
                * EntityRenderer.scaleM(SIMD3(tailShaftW, tailShaftH, tailShaftD))
            let tuftModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailAng)
                * EntityRenderer.trans(SIMD3(0, -tailShaftH - tailTuftH * 0.5, -tailShaftD * 0.5))
                * EntityRenderer.scaleM(SIMD3(tailTuftW, tailTuftH, tailTuftD))
            drawCube(enc: enc, viewProj: viewProj, model: shaftModel, rgb: legCol,   sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: tuftModel,  rgb: patchCol, sat: sat)
        }
    }

    // =========================================================================
    // KIND 2 — LIZARD / gecko
    //
    // Silhouette: extremely flat and long. Body almost at ground level.
    // 4 legs splay WIDE to the sides (not under body). Long whip-tail curling
    // behind and slightly sideways. Wide flat head, prominent wide snout.
    // Waddles/scuttles with a side-to-side body rock.
    //
    // Proportions:
    //   body:  very long bD = s*1.70, very flat bH = s*0.28, legH = s*0.20
    //   legs:  short but wide-offset (hipX = bW*0.70, hip angled outward)
    //   tail:  bD * 1.0 long, made of 3 segments diminishing in size
    //
    // Parts: body(1) belly(1) head(1) snout(1) nostrils(2) eyes(2)
    //        dorsal-ridge(1) tail segments(3) legs(4) = 16
    // =========================================================================
    private func drawKind2(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let baseCol  = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol  = baseCol * 0.60
        let bellyCol = SIMD3<Float>(
            min(1.0, baseCol.x * 0.70 + 0.18),
            min(1.0, baseCol.y * 0.70 + 0.18),
            min(1.0, baseCol.z * 0.55 + 0.14))  // lighter pale belly
        let ridgeCol = baseCol * 0.82
        let eyeCol   = SIMD3<Float>(0.04, 0.20, 0.04)   // reptile eyes: dark green

        let blinkPhase  = phase + hash * 5.2
        let tailPhase   = phase + hash * 3.0

        let waddleSpeed: Float = 2.8
        // Side-to-side body rock — the lizard waddle
        let rockAngle = sin(phase * waddleSpeed) * 0.18
        // Legs: front pair and back pair swing opposite
        let legSwingF = sin(phase * waddleSpeed) * 0.28
        let legSwingB = sin(phase * waddleSpeed + 3.14159) * 0.28
        // Tail curls left-right, compounding from tail swing
        let tailBase  = sin(phase * waddleSpeed * 0.8 + tailPhase * 0.4) * 0.35
        let tailMid   = tailBase * 1.4
        let tailTip   = tailBase * 1.9

        let eyeBlinkSY = blinkScale(blinkPhase)

        // Very long flat body — THE shape signature
        let bW = s * 0.60;  let bH = s * 0.28;  let bD = s * 1.70
        // Short legs but placed FAR out to sides (splay)
        let legW = s * 0.15; let legH = s * 0.20; let legD = s * 0.18
        // Wide flat head
        let hW = s * 0.50; let hH = s * 0.24; let hD = s * 0.40
        // Wide flat snout extending forward
        let snW = s * 0.40; let snH = s * 0.16; let snD = s * 0.26
        // Tail segments (3 blocks, diminishing)
        let t1W = s * 0.22; let t1H = s * 0.20; let t1D = s * 0.42
        let t2W = s * 0.14; let t2H = s * 0.14; let t2D = s * 0.36
        let t3W = s * 0.08; let t3H = s * 0.08; let t3D = s * 0.30

        let groundY = pos.y
        // Body sits very low — legs are short
        let bodyY   = groundY + legH + bH * 0.5
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        let rock = EntityRenderer.rotZ(rockAngle)
        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * rock * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        // Splay legs: the leg pivots out to the side, then angles down
        func lwSplay(_ hip: SIMD3<Float>, _ splayAngle: Float, _ swingAng: Float) -> simd_float4x4 {
            let splay = EntityRenderer.rotZ(splayAngle)   // rotate leg outward from body
            return EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(hip)
                * splay
                * EntityRenderer.rotX(swingAng)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body — long flat plank
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Belly — pale underside
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.28, bD * 0.10), SIMD3(bW * 0.88, bH * 0.44, bD * 0.78)),
                 rgb: bellyCol, sat: sat)

        // Dorsal ridge — narrow row of bumps along spine
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH * 0.50 + s * 0.05, -bD * 0.05),
                           SIMD3(s * 0.08, s * 0.10, bD * 0.70)),
                 rgb: ridgeCol, sat: sat)

        // Head — wide flat rectangle
        let headY: Float = bH * 0.18
        let headZ: Float = bD * 0.50 + hD * 0.44
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: baseCol, sat: sat)
        // Snout — even wider, lower, extends further forward
        let snoutZ: Float = headZ + hD * 0.44 + snD * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hH * 0.12, snoutZ),
                           SIMD3(snW, snH, snD)),
                 rgb: darkCol, sat: sat)
        // Nostrils — top of snout, two bumps
        let nostW = s * 0.07; let nostH = s * 0.05; let nostD = s * 0.05
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-snW * 0.25, headY - hH * 0.12 + snH * 0.50 + nostH * 0.5,
                                 snoutZ + snD * 0.30),
                           SIMD3(nostW, nostH, nostD)), rgb: darkCol * 0.82, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( snW * 0.25, headY - hH * 0.12 + snH * 0.50 + nostH * 0.5,
                                 snoutZ + snD * 0.30),
                           SIMD3(nostW, nostH, nostD)), rgb: darkCol * 0.82, sat: sat)

        // FACE — LIZARD: bulging dome eyes mounted high on the SIDES of the flat
        // head (true reptile placement → unmistakable side-eyed look), each a
        // pale dome with a slit-style dark pupil, plus a wide toothy grin slit
        // along the snout. Goofy/cheeky rather than cute.
        // Eyes: domed cubes high on each side, pupil facing outward (+/-X front).
        let lzEyeW = s * 0.12; let lzEyeH = s * 0.13 * eyeBlinkSY; let lzEyeD = s * 0.12
        let lzEyeY = headY + hH * 0.42
        let lzEyeZ = headZ - hD * 0.06
        let domeCol = SIMD3<Float>(min(1, baseCol.x*0.5+0.45), min(1, baseCol.y*0.5+0.42), min(1, baseCol.z*0.4+0.30))
        // Left dome + outward slit pupil
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hW * 0.50, lzEyeY, lzEyeZ), SIMD3(lzEyeW, lzEyeH, lzEyeD)),
                 rgb: domeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hW * 0.50 - lzEyeW * 0.45, lzEyeY, lzEyeZ),
                           SIMD3(s*0.03, lzEyeH * 0.8, lzEyeD * 0.55)),
                 rgb: eyeCol, sat: sat)
        // Right dome + outward slit pupil
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hW * 0.50, lzEyeY, lzEyeZ), SIMD3(lzEyeW, lzEyeH, lzEyeD)),
                 rgb: domeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hW * 0.50 + lzEyeW * 0.45, lzEyeY, lzEyeZ),
                           SIMD3(s*0.03, lzEyeH * 0.8, lzEyeD * 0.55)),
                 rgb: eyeCol, sat: sat)
        // WIDE GRIN — a dark mouth slit running across the front of the snout,
        // with a few tiny white teeth notches. The lizard's cheeky signature.
        let grinCol = SIMD3<Float>(0.10, 0.04, 0.04)
        let grinZ = snoutZ + snD * 0.50
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hH * 0.30, grinZ), SIMD3(snW * 0.92, s * 0.05, s * 0.04)),
                 rgb: grinCol, sat: sat)
        let lzToothCol = SIMD3<Float>(0.95, 0.95, 0.88)
        for tx in [-0.28, -0.10, 0.10, 0.28] as [Float] {
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(snW * tx, headY - hH * 0.24, grinZ), SIMD3(s*0.03, s*0.045, s*0.03)),
                     rgb: lzToothCol, sat: sat)
        }

        // 4 splayed legs — set wide out to sides
        let hipY: Float = -bH * 0.5
        let splayOut: Float = 0.45   // outward lean angle (radians)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lwSplay(SIMD3(-bW * 0.52, hipY,  bD * 0.30), -splayOut, legSwingF),
                 rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lwSplay(SIMD3( bW * 0.52, hipY,  bD * 0.30),  splayOut, legSwingF),
                 rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lwSplay(SIMD3(-bW * 0.52, hipY, -bD * 0.25), -splayOut, legSwingB),
                 rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lwSplay(SIMD3( bW * 0.52, hipY, -bD * 0.25),  splayOut, legSwingB),
                 rgb: darkCol, sat: sat)

        // Tail — 3 segments chained, each curls more
        // Segment 1 (attached to body)
        do {
            let tail1Pivot = SIMD3<Float>(0, bH * 0.20, -bD * 0.50)
            let t1Model = EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(tail1Pivot)
                * EntityRenderer.rotY(tailBase)
                * EntityRenderer.trans(SIMD3(0, -t1H * 0.08, -t1D * 0.5))
                * EntityRenderer.scaleM(SIMD3(t1W, t1H, t1D))
            drawCube(enc: enc, viewProj: viewProj, model: t1Model, rgb: darkCol, sat: sat)

            // Segment 2 — chained off end of segment 1, curls more
            let t2Model = EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(tail1Pivot)
                * EntityRenderer.rotY(tailBase)
                * EntityRenderer.trans(SIMD3(0, -t1H * 0.08, -t1D))
                * EntityRenderer.rotY(tailMid - tailBase)
                * EntityRenderer.trans(SIMD3(0, -t2H * 0.08, -t2D * 0.5))
                * EntityRenderer.scaleM(SIMD3(t2W, t2H, t2D))
            drawCube(enc: enc, viewProj: viewProj, model: t2Model, rgb: darkCol * 0.90, sat: sat)

            // Segment 3 — tip, curls most
            let t3Model = EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(tail1Pivot)
                * EntityRenderer.rotY(tailBase)
                * EntityRenderer.trans(SIMD3(0, -t1H * 0.08, -t1D))
                * EntityRenderer.rotY(tailMid - tailBase)
                * EntityRenderer.trans(SIMD3(0, -t2H * 0.08, -t2D))
                * EntityRenderer.rotY(tailTip - tailMid)
                * EntityRenderer.trans(SIMD3(0, -t3H * 0.08, -t3D * 0.5))
                * EntityRenderer.scaleM(SIMD3(t3W, t3H, t3D))
            drawCube(enc: enc, viewProj: viewProj, model: t3Model, rgb: darkCol * 0.78, sat: sat)
        }
    }

    // =========================================================================
    // KIND 3 — RAM / boar
    //
    // Silhouette: wide and squat. Barrel-shaped body, very low to the ground.
    // BIG swept curved horns — each horn is 2 blocks at angles making a curve
    // that sweeps OUT and then UP (like a ram). Low heavy head with prominent
    // square snout. Stubby thick hooves. Slow heavy plod.
    //
    // Proportions:
    //   body: wide bW = s*1.15, low bH = s*0.55
    //   legs: short legH = s*0.32, thick
    //   horns: two segments per side sweeping wide — gives huge width silhouette
    //
    // Parts: body(1) head(1) snout(1) eyes(2) horn-base(2) horn-tip(2)
    //        shoulder-hump(1) back-tuft(1) hooves(4) legs(4) = 18
    // =========================================================================
    private func drawKind3(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let baseCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol = baseCol * 0.62
        let hornCol = SIMD3<Float>(
            min(1.0, baseCol.x * 0.60 + 0.28),
            min(1.0, baseCol.y * 0.55 + 0.22),
            min(1.0, baseCol.z * 0.30 + 0.04))  // warm amber horn
        let tufCol  = baseCol * 1.10
        let eyeCol  = SIMD3<Float>(0.04, 0.04, 0.06)
        let hoofCol = SIMD3<Float>(0.15, 0.10, 0.08)

        let blinkPhase  = phase + hash * 4.7
        let breathPhase = phase * 0.38 + hash * 3.1
        let tufPhase    = phase * 0.50 + hash * 1.4

        let plodSpeed: Float = 1.6
        let legSwing  = sin(phase * plodSpeed) * 0.22
        let bodyBob   = abs(sin(phase * plodSpeed)) * s * 0.010

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)
        let tufSway    = sin(tufPhase) * 0.14
        // Horn jitter: slow snort-shimmy
        let hornJitter = sin(phase * 2.8 + hash * 2.0) * 0.018

        // Wide squat proportions
        let bW = s * 1.15;  let bH = s * 0.55;  let bD = s * 0.85
        let hW = s * 0.60;  let hH = s * 0.50;  let hD = s * 0.55  // big boxy head
        let snW = s * 0.38; let snH = s * 0.24; let snD = s * 0.26  // square snout
        let legW = s * 0.30; let legH = s * 0.32; let legD = s * 0.30  // stubby
        let hoofW = s * 0.32; let hoofH = s * 0.08; let hoofD = s * 0.32
        // Horn segments: base sweeps OUT, tip curves UP
        let hb_W = s * 0.12; let hb_H = s * 0.14; let hb_D = s * 0.12  // horn base
        let ht_W = s * 0.10; let ht_H = s * 0.20; let ht_D = s * 0.10  // horn tip

        let groundY = pos.y
        let bodyY   = groundY + legH + hoofH + bH * 0.5 + bodyBob + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }
        func hw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH - hoofH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(hoofW, hoofH, hoofD))
        }

        // Body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Shoulder hump — raised mass at front of body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH * 0.42, bD * 0.28),
                           SIMD3(bW * 0.82, bH * 0.32, bD * 0.30)),
                 rgb: darkCol, sat: sat)

        // Head — low, heavy, pushed forward
        let headY: Float = -bH * 0.05    // head sits LOW, level with mid-body
        let headZ: Float = bD * 0.50 + hD * 0.44
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: baseCol, sat: sat)
        // Square snout — juts forward and down
        let snoutY: Float = headY - hH * 0.18
        let snoutZ: Float = headZ + hD * 0.46 + snD * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, snoutY, snoutZ), SIMD3(snW, snH, snD)),
                 rgb: darkCol, sat: sat)

        // FACE — RAM: STERN heavy brow casting the eyes into a glare, narrow
        // squinting eyes with a hard pupil, dark nostril slits on the snout.
        // Reads as tough/grumpy — the bruiser of the herd.
        let rmFaceZ = headZ + hD * 0.46
        // Heavy brow ridge — a dark angled bar above the eyes (the stern look)
        let browCol = baseCol * 0.45
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY + hH * 0.24, rmFaceZ), SIMD3(hW * 0.86, s * 0.10, s * 0.06)),
                 rgb: browCol, sat: sat)
        // Eyes — narrow, set just under the brow, amber sclera + dark slit pupil
        let rmEyeW = s * 0.12; let rmEyeH = s * 0.08 * eyeBlinkSY; let rmEyeD = s * 0.05
        let rmEyeY = headY + hH * 0.07
        let amberSclera = SIMD3<Float>(0.85, 0.62, 0.18)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hW * 0.28, rmEyeY, rmFaceZ), r: SIMD3(rmEyeW, rmEyeH, rmEyeD),
                sat: sat, scleraCol: amberSclera, pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hW * 0.28, rmEyeY, rmFaceZ), r: SIMD3(rmEyeW, rmEyeH, rmEyeD),
                sat: sat, scleraCol: amberSclera, pupilCol: eyeCol)
        // Nostril slits — two dark dashes on the front of the snout
        let snFrontZ = snoutZ + snD * 0.50
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-snW * 0.22, snoutY + snH * 0.05, snFrontZ), SIMD3(s*0.05, s*0.08, s*0.03)),
                 rgb: baseCol * 0.30, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( snW * 0.22, snoutY + snH * 0.05, snFrontZ), SIMD3(s*0.05, s*0.08, s*0.03)),
                 rgb: baseCol * 0.30, sat: sat)

        // BIG SWEPT CURVED HORNS — each is 2 segments making an arc
        // Base segment sweeps wide-outward (rotZ outward)
        // Tip segment curls UP from end of base (rotZ further + rotX back)
        let hornAnchorY: Float = headY + hH * 0.44
        let hornAnchorZ: Float = headZ
        do {
            // Left horn
            let baseAngleL = EntityRenderer.rotZ( 0.78 + hornJitter)   // sweep left-outward
            let tipAngleL  = EntityRenderer.rotZ( 0.55) * EntityRenderer.rotX(-0.50)  // curl up+back
            let hbLModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3(-hW * 0.42, hornAnchorY, hornAnchorZ))
                * baseAngleL
                * EntityRenderer.trans(SIMD3(-hb_W * 0.5, hb_H * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(hb_W, hb_H, hb_D))
            let htLModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3(-hW * 0.42, hornAnchorY, hornAnchorZ))
                * baseAngleL
                * EntityRenderer.trans(SIMD3(-hb_W * 0.5 - cos(0.78) * hb_W,
                                             hb_H + sin(0.78) * hb_H * 0.5, 0))
                * tipAngleL
                * EntityRenderer.trans(SIMD3(-ht_W * 0.5, ht_H * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(ht_W, ht_H, ht_D))
            drawCube(enc: enc, viewProj: viewProj, model: hbLModel, rgb: hornCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: htLModel, rgb: hornCol, sat: sat)

            // Right horn (mirror)
            let baseAngleR = EntityRenderer.rotZ(-0.78 - hornJitter)
            let tipAngleR  = EntityRenderer.rotZ(-0.55) * EntityRenderer.rotX(-0.50)
            let hbRModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3( hW * 0.42, hornAnchorY, hornAnchorZ))
                * baseAngleR
                * EntityRenderer.trans(SIMD3( hb_W * 0.5, hb_H * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(hb_W, hb_H, hb_D))
            let htRModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3( hW * 0.42, hornAnchorY, hornAnchorZ))
                * baseAngleR
                * EntityRenderer.trans(SIMD3( hb_W * 0.5 + cos(0.78) * hb_W,
                                             hb_H + sin(0.78) * hb_H * 0.5, 0))
                * tipAngleR
                * EntityRenderer.trans(SIMD3( ht_W * 0.5, ht_H * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(ht_W, ht_H, ht_D))
            drawCube(enc: enc, viewProj: viewProj, model: hbRModel, rgb: hornCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: htRModel, rgb: hornCol, sat: sat)
        }

        // Back tuft — fluffy mane on rear of body
        do {
            let tufPivot = SIMD3<Float>(0, bH * 0.50, -bD * 0.18)
            let tufModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tufPivot)
                * EntityRenderer.rotY(tufSway)
                * EntityRenderer.trans(SIMD3(0, s * 0.10, 0))
                * EntityRenderer.scaleM(SIMD3(bW * 0.55, s * 0.20, bD * 0.28))
            drawCube(enc: enc, viewProj: viewProj, model: tufModel, rgb: tufCol, sat: sat)
        }

        // 4 thick legs + hooves
        let hipY = -bH * 0.5
        let hipFL = SIMD3<Float>(-bW * 0.38, hipY,  bD * 0.30)
        let hipFR = SIMD3<Float>( bW * 0.38, hipY,  bD * 0.30)
        let hipBL = SIMD3<Float>(-bW * 0.38, hipY, -bD * 0.30)
        let hipBR = SIMD3<Float>( bW * 0.38, hipY, -bD * 0.30)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFL,  legSwing), rgb: darkCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFR, -legSwing), rgb: darkCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBL, -legSwing), rgb: darkCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBR,  legSwing), rgb: darkCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: hw(hipFL,  legSwing), rgb: hoofCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: hw(hipFR, -legSwing), rgb: hoofCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: hw(hipBL, -legSwing), rgb: hoofCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: hw(hipBR,  legSwing), rgb: hoofCol,  sat: sat)
    }

    // =========================================================================
    // KIND 4 — BOSS (friendly giant)
    //
    // Clearly the biggest creature (scale * 1.5). Bulky wide body, massive head,
    // crown of 3 spires (center taller), 3 dorsal back spikes, wide shoulder
    // armor plates, GLOWING HDR amber eyes (bloom-ready), heavy stomp.
    // Friendly but imposing — kids should find it awesome, not scary.
    //
    // Parts: body(1) shoulder-armor(2) head(1) chin-plate(1) eyes(2) crown(3)
    //        back-spikes(3) legs(4) = 17
    // =========================================================================
    private func drawKind4(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale * 1.50   // boss is noticeably bigger
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let baseCol  = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let darkCol  = baseCol * 0.60
        let crownCol = baseCol * 1.25
        // HDR eye glow — luminance > 1 so the bloom pass picks it up
        // Vivid warm amber-orange: friendly glowing eyes
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

        // Blink: boss eyes flicker — rapid burst blink (more dramatic)
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
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

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

        // FACE — BOSS (friendly grand giant): kindly RAISED brows over the
        // glowing eyes (raised = warm, not angry), and a big broad GRIN with
        // upturned corners so the giant reads as awesome-friendly, not scary.
        let bsFaceZ = headZ + hS * 0.43
        // Friendly raised brows — short bars angled gently upward-outward.
        let bossBrowCol = crownCol
        let browL = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3(-hS * 0.24, headY + hS * 0.24, bsFaceZ))
            * EntityRenderer.rotZ(0.22)
            * EntityRenderer.scaleM(SIMD3(s * 0.20, s * 0.05, s * 0.05))
        let browR = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3( hS * 0.24, headY + hS * 0.24, bsFaceZ))
            * EntityRenderer.rotZ(-0.22)
            * EntityRenderer.scaleM(SIMD3(s * 0.20, s * 0.05, s * 0.05))
        drawCube(enc: enc, viewProj: viewProj, model: browL, rgb: bossBrowCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: browR, rgb: bossBrowCol, sat: sat)
        // Big grin — wide dark mouth bar with upturned corner blocks.
        let grinCol = SIMD3<Float>(0.10, 0.05, 0.05)
        let grinY   = headY - hS * 0.22
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, grinY, bsFaceZ), SIMD3(hS * 0.50, s * 0.06, s * 0.05)),
                 rgb: grinCol, sat: sat)
        // Upturned corners (smile)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS * 0.26, grinY + s * 0.06, bsFaceZ), SIMD3(s*0.08, s*0.06, s*0.05)),
                 rgb: grinCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS * 0.26, grinY + s * 0.06, bsFaceZ), SIMD3(s*0.08, s*0.06, s*0.05)),
                 rgb: grinCol, sat: sat)
        // A couple of friendly square teeth in the grin
        let bossTooth = SIMD3<Float>(0.95, 0.95, 0.9)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-s * 0.06, grinY + s * 0.02, bsFaceZ + s*0.01), SIMD3(s*0.07, s*0.06, s*0.03)),
                 rgb: bossTooth, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( s * 0.06, grinY + s * 0.02, bsFaceZ + s*0.01), SIMD3(s*0.07, s*0.06, s*0.03)),
                 rgb: bossTooth, sat: sat)

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

    // =========================================================================
    // KIND 5 — NIGHT MONSTER (new; scary for kids 7-10, cartoonish not gory)
    //
    // Silhouette: hunched menacing shape. Body is TILTED FORWARD so the chest
    // leans toward the viewer. 6 sharp limbs: 4 legs (widely placed, angular)
    // + 2 clawed arm-spikes jutting forward from "shoulders". Jagged back-ridge
    // with multiple sharp spikes. Wide flat head with a GAPING MOUTH slit.
    // GLOWING RED HDR eyes (3.5, 0.05, 0.05) bloom bright red.
    // Dark body: forced near-black regardless of entity color (we use entity
    // color mixed darkly so dozens of monsters aren't identical).
    //
    // Gait: skittering lurching — fast erratic leg movement, body bobs erratically,
    // arms claw forward and back.
    //
    // Parts: body(1) chest(1) head(1) mouth-slit(1) EYES(2) back-spikes(5)
    //        arm-claw-L(2 segs) arm-claw-R(2 segs) legs(4) = 19
    // =========================================================================
    private func drawKind5(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale * 1.10   // slightly bigger than normal animals
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)

        // Force entity color very dark — monsters are black/near-black with
        // a tiny tint from entity color so siblings differ slightly.
        let tint = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let bodyCol  = tint * 0.10 + SIMD3<Float>(0.04, 0.02, 0.06)   // near black, hint of purple
        let spikeCol = tint * 0.08 + SIMD3<Float>(0.08, 0.04, 0.10)   // slightly lighter spikes
        let clawCol  = tint * 0.06 + SIMD3<Float>(0.12, 0.06, 0.14)   // claws lightest dark part
        let mouthCol = SIMD3<Float>(0.55, 0.02, 0.02)                  // dark blood-red mouth slit
        // GLOWING RED HDR eyes — luminance > 1 → bloom red glow
        let eyeGlowCol = SIMD3<Float>(3.5, 0.05, 0.05)

        // Skitter gait: fast chaotic leg flicker
        let skitterSpeed: Float = 5.5
        let legSwingFast  = sin(phase * skitterSpeed) * 0.45
        // Erratic body lurch: compound two frequencies
        let lurchY = (sin(phase * 3.1) * 0.40 + sin(phase * 7.3 + hash) * 0.25) * s * 0.040
        let lurchX = sin(phase * 4.7 + hash * 2.0) * s * 0.012

        // Body HUNCHED FORWARD: rotate whole body forward on X
        let hunchAngle: Float = 0.52   // ~30 degrees lean forward
        let bodyHunch = EntityRenderer.rotX(hunchAngle)

        // Arm claw phases: clawing forward and back
        let clawPhase = phase * 3.8 + hash * 1.5
        let armSwingF = sin(clawPhase) * 0.60           // front arm claws
        let armSwingB = sin(clawPhase + 1.57) * 0.40   // slight offset

        // Blink: monster eyes flicker erratically
        let blinkPhase = phase * 2.2 + hash * 5.1
        let eyeBlinkSY = blinkScale(blinkPhase)

        // Proportions
        let bW = s * 0.72;  let bH = s * 0.52;  let bD = s * 0.82
        let hW = s * 0.66;  let hH = s * 0.38;  let hD = s * 0.50   // wide flat head
        let legW = s * 0.14; let legH = s * 0.42; let legD = s * 0.14
        // Spikes on back — 5 of them, different heights
        let spikeW = s * 0.10; let spikeD = s * 0.08
        let spikeHeights: [Float] = [s*0.28, s*0.38, s*0.44, s*0.32, s*0.22]
        let spikeZOffsets: [Float] = [bD*0.38, bD*0.18, -bD*0.02, -bD*0.22, -bD*0.40]
        // Arm segments
        let arm1W = s * 0.10; let arm1H = s * 0.30; let arm1D = s * 0.10
        let arm2W = s * 0.08; let arm2H = s * 0.24; let arm2D = s * 0.08

        let groundY = pos.y
        let bodyY   = groundY + legH + bH * 0.5 + lurchY
        // Body also lurches on X
        let wc      = SIMD3<Float>(pos.x + lurchX, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodyHunch * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body — hunched (via bodyHunch in pw)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: bodyCol, sat: sat)
        // Chest — a slightly lighter wedge pushed forward (gives hunched mass feel)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.10, bD * 0.32),
                           SIMD3(bW * 0.78, bH * 0.60, bD * 0.30)),
                 rgb: spikeCol, sat: sat)

        // Back spikes — jagged uneven row
        for idx in 0..<5 {
            let spkH = spikeHeights[idx]
            let spkZ = spikeZOffsets[idx]
            let spkModel = EntityRenderer.trans(wc) * R * bodyHunch
                * EntityRenderer.trans(SIMD3(0, bH * 0.50 + spkH * 0.5, spkZ))
                * EntityRenderer.scaleM(SIMD3(spikeW, spkH, spikeD))
            drawCube(enc: enc, viewProj: viewProj, model: spkModel, rgb: spikeCol, sat: sat)
        }

        // Head — wide flat, sits low on body (menacing forward thrust)
        let headY: Float = bH * 0.22
        let headZ: Float = bD * 0.46 + hD * 0.42
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: bodyCol, sat: sat)

        // FACE — NIGHT MONSTER: glowing red eyes (kept), plus ANGRY angled
        // brows pressing down over them and a JAGGED fanged mouth. The face is
        // the threat-read — menacing but cartoonish, not gory.
        let mnFaceZ = headZ + hD * 0.50
        // GAPING MOUTH — dark red gap with a row of jagged white fangs across
        // it (alternating up/down points → the jagged maw).
        let mouthW = hW * 0.82; let mouthH = s * 0.10; let mouthD = s * 0.04
        let mouthY = headY - hH * 0.22
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, mouthY, mnFaceZ), SIMD3(mouthW, mouthH, mouthD)),
                 rgb: mouthCol, sat: sat)
        // Jagged fangs — five thin teeth, alternating from top and bottom.
        let fangCol = SIMD3<Float>(0.92, 0.90, 0.84)
        let fangXs: [Float] = [-0.32, -0.16, 0.0, 0.16, 0.32]
        for (i, fx) in fangXs.enumerated() {
            let down = (i % 2 == 0)   // alternate up/down points
            let fy = mouthY + (down ? mouthH * 0.18 : -mouthH * 0.18)
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(mouthW * fx, fy, mnFaceZ + s*0.01), SIMD3(s*0.045, s*0.07, s*0.03)),
                     rgb: fangCol, sat: sat)
        }

        // GLOWING RED HDR EYES — emissive, bloom into red haze (unchanged)
        let eyeW = s * 0.13; let eyeH = s * 0.13 * eyeBlinkSY; let eyeD = s * 0.04
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hW * 0.26, headY + hH * 0.12, mnFaceZ),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeGlowCol, sat: -1.0)  // emissive red
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hW * 0.26, headY + hH * 0.12, mnFaceZ),
                           SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeGlowCol, sat: -1.0)  // emissive red
        // ANGRY BROWS — dark angled bars pressing inward-down over the eyes
        // (inner ends low, outer ends high → classic angry "V" scowl).
        let mnBrowCol = spikeCol * 1.4
        let mbL = EntityRenderer.trans(wc) * R * bodyHunch
            * EntityRenderer.trans(SIMD3(-hW * 0.26, headY + hH * 0.30, mnFaceZ))
            * EntityRenderer.rotZ(-0.40)
            * EntityRenderer.scaleM(SIMD3(s * 0.20, s * 0.05, s * 0.05))
        let mbR = EntityRenderer.trans(wc) * R * bodyHunch
            * EntityRenderer.trans(SIMD3( hW * 0.26, headY + hH * 0.30, mnFaceZ))
            * EntityRenderer.rotZ( 0.40)
            * EntityRenderer.scaleM(SIMD3(s * 0.20, s * 0.05, s * 0.05))
        drawCube(enc: enc, viewProj: viewProj, model: mbL, rgb: mnBrowCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: mbR, rgb: mnBrowCol, sat: sat)

        // 4 angled legs — placed slightly splayed for menacing stance
        // Legs use world-space (no bodyHunch) so they plant on the ground correctly
        let hipY = -(bH * 0.5 + lurchY)   // offset for body lurch to keep feet near ground
        let legSplayAngleL = EntityRenderer.rotZ(-0.18)   // splay left legs outward
        let legSplayAngleR = EntityRenderer.rotZ( 0.18)
        do {
            // Front-left
            let hipFL = SIMD3<Float>(-bW * 0.44, bH * 0.5 + hipY, bD * 0.30)
            let flModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipFL)
                * legSplayAngleL
                * EntityRenderer.rotX(legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
            drawCube(enc: enc, viewProj: viewProj, model: flModel, rgb: clawCol, sat: sat)
            // Front-right
            let hipFR = SIMD3<Float>( bW * 0.44, bH * 0.5 + hipY, bD * 0.30)
            let frModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipFR)
                * legSplayAngleR
                * EntityRenderer.rotX(-legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
            drawCube(enc: enc, viewProj: viewProj, model: frModel, rgb: clawCol, sat: sat)
            // Back-left
            let hipBL = SIMD3<Float>(-bW * 0.44, bH * 0.5 + hipY, -bD * 0.28)
            let blModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipBL)
                * legSplayAngleL
                * EntityRenderer.rotX(-legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
            drawCube(enc: enc, viewProj: viewProj, model: blModel, rgb: clawCol, sat: sat)
            // Back-right
            let hipBR = SIMD3<Float>( bW * 0.44, bH * 0.5 + hipY, -bD * 0.28)
            let brModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipBR)
                * legSplayAngleR
                * EntityRenderer.rotX(legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
            drawCube(enc: enc, viewProj: viewProj, model: brModel, rgb: clawCol, sat: sat)
        }

        // 2 CLAWED ARMS — jut from upper sides of body, claw forward/back
        // Each arm: 2 segments (upper arm + lower forearm/claw)
        do {
            // Left arm
            let armShoulderL = SIMD3<Float>(-bW * 0.48, bH * 0.28, bD * 0.20)
            // Upper arm rotates on X (claw forward/back), leans outward on Z
            let upperArmLModel = EntityRenderer.trans(wc) * R * bodyHunch
                * EntityRenderer.trans(armShoulderL)
                * EntityRenderer.rotZ(-0.55)    // angle outward-down
                * EntityRenderer.rotX(armSwingF)
                * EntityRenderer.trans(SIMD3(0, -arm1H * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(arm1W, arm1H, arm1D))
            drawCube(enc: enc, viewProj: viewProj, model: upperArmLModel, rgb: spikeCol, sat: sat)
            // Forearm claw — hangs from upper arm tip, extra forward claw angle
            let foreArmLModel = EntityRenderer.trans(wc) * R * bodyHunch
                * EntityRenderer.trans(armShoulderL)
                * EntityRenderer.rotZ(-0.55)
                * EntityRenderer.rotX(armSwingF)
                * EntityRenderer.trans(SIMD3(-arm2W * 0.3, -arm1H, 0))
                * EntityRenderer.rotX(armSwingB + 0.40)   // claw curls forward
                * EntityRenderer.trans(SIMD3(0, -arm2H * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(arm2W, arm2H, arm2D))
            drawCube(enc: enc, viewProj: viewProj, model: foreArmLModel, rgb: clawCol, sat: sat)

            // Right arm (mirror)
            let armShoulderR = SIMD3<Float>( bW * 0.48, bH * 0.28, bD * 0.20)
            let upperArmRModel = EntityRenderer.trans(wc) * R * bodyHunch
                * EntityRenderer.trans(armShoulderR)
                * EntityRenderer.rotZ( 0.55)
                * EntityRenderer.rotX(armSwingF)
                * EntityRenderer.trans(SIMD3(0, -arm1H * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(arm1W, arm1H, arm1D))
            drawCube(enc: enc, viewProj: viewProj, model: upperArmRModel, rgb: spikeCol, sat: sat)
            let foreArmRModel = EntityRenderer.trans(wc) * R * bodyHunch
                * EntityRenderer.trans(armShoulderR)
                * EntityRenderer.rotZ( 0.55)
                * EntityRenderer.rotX(armSwingF)
                * EntityRenderer.trans(SIMD3( arm2W * 0.3, -arm1H, 0))
                * EntityRenderer.rotX(armSwingB + 0.40)
                * EntityRenderer.trans(SIMD3(0, -arm2H * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(arm2W, arm2H, arm2D))
            drawCube(enc: enc, viewProj: viewProj, model: foreArmRModel, rgb: clawCol, sat: sat)
        }
    }

    // =========================================================================
    // KIND 6 — FALLING BLOCK (sand, gravel, or log from felled tree)
    //
    // A single cube, 0.9 units on each side, centered on the entity position.
    // Color comes directly from the engine via e.color (the actual block colour).
    // The entity's yaw is used as a continuously-supplied tumble angle: the
    // engine increments it each tick so the cube spins as it falls.  A fixed
    // 0.35-rad X tilt is composed in so the spin reads clearly in 3D (a
    // pure Y-spin on a unit cube looks flat from the side).
    // Directional shading is provided by the existing vertex shader via the
    // face normals in cubeVB — no extra setup needed here.
    // sat is passed through from the entity so the desaturation path works.
    // No legs, eyes, blink, breathe, or any creature animation.
    // =========================================================================
    private func drawKind6(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float) {
        let s   = e.scale
        let sat = e.sat
        let blockCol = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // The cube is 0.9 × scale on each axis, centered at pos.
        let side = s * 0.9

        // Tumble: yaw supplies a Y-spin; a fixed X tilt of 0.35 rad makes
        // the rotation visible in 3D even when viewed from a shallow angle.
        let spinY = EntityRenderer.rotY(e.yaw)
        let tiltX = EntityRenderer.rotX(0.35)

        let model = EntityRenderer.trans(pos)
            * spinY
            * tiltX
            * EntityRenderer.scaleM(SIMD3<Float>(side, side, side))

        drawCube(enc: enc, viewProj: viewProj, model: model, rgb: blockCol, sat: sat)
    }

    // -----------------------------------------------------------------------
    // Draw one unit cube with given model matrix and color.
    // sat = -1.0 is the emissive sentinel: fragment shader skips shading multiply.
    //
    // HIT FLASH: when the currently-drawing creature is mid-hit-reaction
    // (curFlashAmt > 0) every part is pushed toward the hot flash color. We do
    // this on the CPU side (per draw) so it composites correctly for both the
    // shaded path and the emissive (sat < 0) eye path:
    //   - shaded parts: lerp rgb toward flash, drive sat toward emissive so the
    //     flash reads at full brightness regardless of face-shading.
    //   - already-emissive parts (glowing eyes): add the flash on top so they
    //     pop brighter / whiter for the duration, then settle back.
    @inline(__always)
    private func drawCube(enc: MTLRenderCommandEncoder,
                          viewProj: simd_float4x4,
                          model: simd_float4x4,
                          rgb: SIMD3<Float>,
                          sat: Float) {
        var outRGB = rgb
        var outSat = sat
        if curFlashAmt > 0.001 {
            if sat < 0.0 {
                // Emissive part: add flash energy on top of existing HDR glow.
                outRGB = rgb + curFlash * 1.5
            } else {
                // Shaded part: blend toward the flash color and make it emissive
                // for the blended amount so the pop is full-strength.
                let k = min(1.0, curFlashAmt)
                outRGB = simd_mix(rgb, max(rgb, curFlash), SIMD3<Float>(repeating: k))
                // Drive toward emissive only once the flash is strong, so the
                // creature's own color still shows during the tail of the fade.
                outSat = k > 0.5 ? -1.0 : sat
            }
        }
        var u = EUniforms(mvp: viewProj * model,
                          color: SIMD4<Float>(outRGB.x, outRGB.y, outRGB.z, outSat))
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
