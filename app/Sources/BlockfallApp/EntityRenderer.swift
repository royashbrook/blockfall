// ============================================================================
// Blockfall — EntityRenderer (M5+ enhanced: distinct animal silhouettes + night monster
//             + multicolor palettes + 4 new species + improved giraffe & boss)
// Draws creatures as multi-part blocky animals.
//
// kind 0 — BUNNY/critter:   round low body, TALL upright ears (3× body height),
//           big cottontail, tiny stubby legs, wide head, hops.
//           PALETTE: base fur / pink belly / pink inner ear / dark paws
//           silhouette: round blob with two tall spikes above it.
//
// kind 1 — GIRAFFE (redesigned): very long thin neck (>body height), long
//           stilt legs with distinct ankle-bands, tiny head with ossicones,
//           tufted tail, MULTI-SPOT patchwork on body & neck, belly contrast.
//           PALETTE: warm amber / dark brown patches / pale muzzle/belly
//           silhouette: tall tower with a distinct thin neck mast.
//
// kind 2 — LIZARD/gecko:    flat wide body close to ground, 4 wide-splayed legs,
//           long curling tail behind, wide flat head, nostril bumps, scuttle.
//           PALETTE: green back / pale yellow-green belly / dark dorsal ridge
//           silhouette: low wide smear with long tail streaking behind.
//
// kind 3 — RAM/boar:        chunky barrel body, BIG swept curved horns (2-segment arc),
//           low wide head, prominent snout block, stubby hooves.
//           PALETTE: tawny back / dark face/hooves / warm amber horns / fluffy lighter belly
//           silhouette: wide squat rectangle with horn-arcs sweeping out both sides.
//
// kind 4 — BOSS (redesigned): clearly biggest (scale * 1.5), layered torso
//           (core + chest plate + mane), defined limb sections (upper/lower leg),
//           brow crest/mane fringe, crown of 3 spires, dorsal spikes,
//           GLOWING HDR amber eyes, heavy stomp. More menacing-but-friendly detail.
//           PALETTE: deep base / dark shadowed flanks / bright crown/mane accent
//           silhouette: massive layered figure with spire crown.
//
// kind 5 — NIGHT MONSTER:   deep maroon-purple hunched body (tilted forward), 6 limbs
//           (4 legs + 2 clawed arms), bony-ivory back spikes, GLOWING HDR RED eyes
//           (luminance > 1 → bloom), gaping mouth slit, skittering lurching gait.
//           PALETTE: dark maroon-purple back / lighter bruise-purple belly+head /
//                    mid-purple limbs / bony ivory spike accent / sickly yellow-green claws
//           Faint emissive purple rim on flanks for night visibility.
//           silhouette: hunched pointed mass with splayed multi-tone limbs and glowing eyes.
//
// kind 6 — FALLING BLOCK:   single 0.9³ cube centered on entity position.
//           uses entity color directly (block colour from engine — no creature
//           palette). entity yaw drives a continuous Y-axis spin so the cube
//           tumbles visibly; a fixed 0.35-rad X tilt makes the spin read in 3D.
//           directional shading applied (top bright, sides mid, bottom dark)
//           so the block has visible form — no legs, eyes, or animation beyond
//           the tumble. sat from entity is passed through unchanged.
//
// kind 7 — FOX/CAT PROWLER: sleek low body, long bushy tail, pointed ears
//           (outer dark / inner pale), narrow snout, slender legs, alert posture.
//           PALETTE: russet back / cream belly & snout / dark ear tips & paws
//           silhouette: long body + big arched tail curving up behind.
//
// kind 8 — ROUND BIRD/CHICK: very round puffy body, tiny beak, small wing nubs
//           on sides, stubby pair of legs, tail feather fan behind, hops.
//           PALETTE: yellow body / orange beak & feet / white wing tips
//           silhouette: fat round ball with tiny legs and a beak.
//
// kind 9 — TURTLE/ARMADILLO: dome shell (layered plate markings), four short
//           stubby legs peeping below, small head with blunt snout, short tail.
//           PALETTE: olive/forest shell top / lighter underbelly / dark plate lines
//           silhouette: low dome with stubby corners sticking out.
//
// kind 10 — DEER/FAWN: slender body, long graceful legs, small antlers (2-segment Y),
//            white spot row along back, white belly, gentle doe face.
//            PALETTE: warm tan back / white spots & belly / dark legs & antlers
//            silhouette: tall slender figure with branched antlers.
//
// kind 11 — HUMANOID MONSTER (goblin/shadow-person, scary-but-cartoonish):
//            fully upright bipedal figure — torso, head on top, TWO arms that
//            swing OPPOSITE PHASE to legs, TWO legs with a walk cycle, like a
//            person. Silhouette is unmistakably humanoid: tall narrow column with
//            a round head and long dangling arms.
//            FACE: two GLOWING HDR yellow-green eyes (emissive, luminance > 1 →
//            bloom) like the beast but different color, a dark horizontal brow
//            bar angled inward (menacing scowl), a wide jagged grin with uneven
//            teeth — creepy but goofy, not gory.
//            PALETTE: dark bruise-blue body (limbs, head back) / noticeably lighter
//            dark-teal chest plate and forearms/lower-legs / sickly green hands+feet+
//            face-trim accent / faint emissive teal rim on torso sides for night
//            visibility. Entity tint provides variety so a crowd of kind-11s aren't
//            identical. Distinct from kind-5 (maroon-purple) — this is blue-teal.
//            ANIMATION: walk cycle (legs alternate, arms opposite), idle breathe
//            Y-bob, whole-body sway (lurking menace), blink, hit-reaction squash
//            all folded through the existing squashRig so every part recoils.
//            Distinct from kind-5 (which is hunched, 6-limbed, skittering) —
//            this one is erect, 4-limbed, walks with deliberate loping strides.
//
// Animation list (updated for M5+kind11):
//   BLINK       — per-creature cadence: eyes squish flat for ~0.08s every 3-6s
//   BREATHE     — gentle body Y-bob + slight XZ scale pulse, ~0.4 Hz
//   TAIL WAG    — continuous side-to-side sine, always-on, independent freq
//   EAR TWITCH  — brief rotX flick on ears, one ear at a time, ~2-4s intervals
//   WALK CYCLE  — front/back leg pairs swing opposite phases; gait per species
//   LOCOMOTION  — speed-scaled via phase rate (always at 1× since no speed field)
//   BOSS STOMP  — squared abs(sin) so foot slams hard then holds
//   BOSS HDR    — emissive eyes write luminance > 1.0 into rgba16Float; bloom pass picks them up
//   MONSTER SKITTER — fast erratic leg flicker, body rocks, arms claw forward/back
//   MONSTER HDR     — glowing RED eyes (3.5, 0.05, 0.05) → strong bloom
//   HUMANOID LOPE   — upright two-legged walk: legs alternate, arms swing opposite
//   HUMANOID SWAY   — slow whole-body side-to-side sway (predator stalk)
//   HUMANOID HDR    — glowing YELLOW-GREEN eyes (0.8, 3.0, 0.1) → bloom
//
// Per-entity phase derivation:
//   phaseHash = sin(pos.x * 1.3 + pos.z * 2.7)          — spatial scatter
//   phase     = CACurrentMediaTime() + phaseHash * π      — unique offset per creature
//   blinkPhase  = phase * 0.97  + phaseHash * 4.1         — different rate for blink
//   breathPhase = phase * 0.38  + phaseHash * 1.7         — slow breath
//   earPhase    = phase * 0.71  + phaseHash * 6.3         — ear twitch cadence
//   tailPhase   = phase * 1.60  + phaseHash * 2.2         — wag always running
//
// MULTICOLOR PALETTE convention (applies to all kinds except kind 6):
//   Each kind derives its own small palette from the entity's base rgb:
//   backCol   = base tinted darker (top/back of body)
//   bellyCol  = base brightened + mixed lighter (underside)
//   accentCol = species-specific hue shift (ears, snout, paws, spots, shell plates)
//   Parts are assigned a palette slot so no two adjacent cubes share the same flat color.
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
                       t - h.lastSeen < 0.5,   // only a fresh, continuous entity — not a (re)spawn
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
            case 7:  drawKind7(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 8:  drawKind8(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 9:  drawKind9(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 10: drawKind10(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 11: drawKind11(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 12: drawKind12(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 13: drawKind13(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 14: drawKind14(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 15: drawKind15(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 16: drawKind16(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 17: drawKind17(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 18: drawKind18(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 19: drawKind19(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 20: drawKind20(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            case 21: drawKind21(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
            // kind 100 — REMOTE PLAYER (#13 multiplayer): render the connected
            // peer as an upright PERSON, not an animal. Reuse the villager
            // humanoid (drawKind20); it already tints clothing from e.color so
            // each peer's per-peer color makes them distinguishable.
            case 100: drawKind20(enc: enc, viewProj: viewProj, e: e, pos: pos, phase: phase, hash: phaseHash, squash: squash)
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
        let base     = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        // ---- PALETTE: bunny ----
        // baseCol: the main fur color
        let baseCol  = base
        // bellyCol: lighter, slightly warmer underside
        let bellyCol = SIMD3<Float>(min(1, base.x*0.72+0.26),
                                    min(1, base.y*0.72+0.24),
                                    min(1, base.z*0.68+0.22))
        // innerEarCol: pink tint inside the ear
        let innerEarCol = SIMD3<Float>(
            min(1.0, base.x * 0.82 + 0.22),
            min(1.0, base.y * 0.48 + 0.10),
            min(1.0, base.z * 0.48 + 0.12))
        // darkCol: shadowed paws/legs, noticeably darker
        let darkCol  = base * 0.58
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
    // KIND 1 — GIRAFFE (redesigned for clear silhouette)
    //
    // Key silhouette cues:
    //   — Extremely long thin neck (neckH = s*1.50, only s*0.15 wide)
    //   — Four very long stilt legs (legH = s*1.00) with dark ankle bands
    //   — Tiny compact head atop the neck with two ossicones
    //   — Patchwork SPOT markings on body + neck (irregular giraffe blotches)
    //   — Pale belly underside, warm amber base, dark brown patches
    //   — Short tail with dark tufted tip, swings gently
    //   — Gentle gait with neck swaying side to side
    //
    // PALETTE:
    //   baseCol  = warm amber-tan from entity color
    //   patchCol = deep reddish-brown spots (~0.55× base, shifted warm)
    //   bellyCol = pale cream (lightened base + white blend)
    //   muzzleCol = even paler cream
    //   legCol   = base * 0.80 (slightly darker than body)
    //   ankleCol = same as patchCol (dark bands)
    //
    // Parts: legs(4) ankle-bands(4) body(1) belly-underside(1) body-spots(4)
    //        neck(1) neck-spots(2) head(1) muzzle(1) nostrils(2) eyes(2) lashes(2)
    //        ossicones(2) tail-shaft(1) tail-tuft(1) = 31 parts
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
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE ----
        // Warm-shift the base: giraffes are amber-tan
        let baseCol   = SIMD3<Float>(min(1, base.x*0.70 + 0.30),
                                     min(1, base.y*0.65 + 0.22),
                                     min(1, base.z*0.30 + 0.06))
        // Deep reddish-brown patches
        let patchCol  = SIMD3<Float>(min(1, base.x*0.38 + 0.18),
                                     min(1, base.y*0.22 + 0.06),
                                     min(1, base.z*0.08 + 0.02))
        // Pale cream belly and muzzle
        let bellyCol  = SIMD3<Float>(min(1, baseCol.x*0.60 + 0.38),
                                     min(1, baseCol.y*0.60 + 0.35),
                                     min(1, baseCol.z*0.50 + 0.26))
        let muzzleCol = SIMD3<Float>(min(1, bellyCol.x + 0.06),
                                     min(1, bellyCol.y + 0.05),
                                     min(1, bellyCol.z + 0.04))
        let legCol    = baseCol * 0.82
        let ankleCol  = patchCol
        let eyeCol    = SIMD3<Float>(0.05, 0.03, 0.02)   // warm dark brown
        let lashCol   = SIMD3<Float>(0.06, 0.04, 0.03)

        let blinkPhase  = phase + hash * 3.8
        let breathPhase = phase * 0.38 + hash * 2.1
        let tailPhase   = phase + hash * 1.8

        let walkSpeed: Float = 1.9
        let legSwing  = sin(phase * walkSpeed) * 0.34
        // Neck sways gently side to side — very visible at this length
        let neckSway  = sin(phase * walkSpeed * 0.80 + 0.5) * s * 0.08

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)
        let tailAng    = tailWagAngle(tailPhase) * 0.50

        // ---- PROPORTIONS ---- (tall tower silhouette)
        // Body: compact barrel
        let bW = s * 0.58;  let bH = s * 0.60;  let bD = s * 0.70
        // Legs: VERY long thin stilts — THE visual key
        let legW = s * 0.11; let legH = s * 1.00; let legD = s * 0.11
        let ankW = s * 0.17; let ankH = s * 0.10; let ankD = s * 0.17
        // Neck: VERY long and THIN — unmistakable
        let neckW = s * 0.15; let neckH = s * 1.50; let neckD = s * 0.15
        // Head: tiny at top of neck
        let hW = s * 0.28; let hH = s * 0.24; let hD = s * 0.32
        // Ossicones: stubby horn knobs
        let ossW = s * 0.06; let ossH = s * 0.18; let ossD = s * 0.06

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
        func aw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH + ankH * 0.55, 0))
                * EntityRenderer.scaleM(SIMD3(ankW, ankH, ankD))
        }

        let hipY = -bH * 0.5
        let hipFL = SIMD3<Float>(-bW * 0.34, hipY,  bD * 0.32)
        let hipFR = SIMD3<Float>( bW * 0.34, hipY,  bD * 0.32)
        let hipBL = SIMD3<Float>(-bW * 0.34, hipY, -bD * 0.32)
        let hipBR = SIMD3<Float>( bW * 0.34, hipY, -bD * 0.32)

        // 4 long stilt legs + dark ankle bands
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFL,  legSwing), rgb: legCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFR, -legSwing), rgb: legCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBL, -legSwing), rgb: legCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBR,  legSwing), rgb: legCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipFL,  legSwing), rgb: ankleCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipFR, -legSwing), rgb: ankleCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipBL, -legSwing), rgb: ankleCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: aw(hipBR,  legSwing), rgb: ankleCol, sat: sat)

        // Body — compact barrel, amber-tan
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Pale cream belly underside
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH*0.28, 0), SIMD3(bW*0.78, bH*0.44, bD*0.80)),
                 rgb: bellyCol, sat: sat)
        // Patchwork spots on body flanks — 4 irregular dark blotches
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( bW*0.40, bH*0.20,  bD*0.18), SIMD3(s*0.06, s*0.24, s*0.28)),
                 rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bW*0.40, bH*0.05, -bD*0.10), SIMD3(s*0.06, s*0.20, s*0.26)),
                 rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( bW*0.40, bH*0.08, -bD*0.26), SIMD3(s*0.06, s*0.18, s*0.22)),
                 rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bW*0.40, bH*0.22,  bD*0.34), SIMD3(s*0.06, s*0.16, s*0.18)),
                 rgb: patchCol, sat: sat)

        // ---- NECK — very long, very thin, key silhouette mast ----
        let neckBaseY = bH * 0.48
        let neckFwdZ  = bD * 0.22
        let neckTilt  = EntityRenderer.rotX(-0.16)   // slight forward lean
        let neckModel = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3(neckSway, neckBaseY, neckFwdZ))
            * neckTilt
            * EntityRenderer.trans(SIMD3(0, neckH * 0.5, 0))
            * EntityRenderer.scaleM(SIMD3(neckW, neckH, neckD))
        drawCube(enc: enc, viewProj: viewProj, model: neckModel, rgb: baseCol, sat: sat)

        // Neck spots — two dark patch blocks along the neck at ~1/3 and ~2/3 height
        let neckSpot1 = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3(neckSway + neckW*0.5, neckBaseY + neckH*0.30, neckFwdZ))
            * neckTilt
            * EntityRenderer.scaleM(SIMD3(s*0.04, s*0.20, neckD*1.10))
        let neckSpot2 = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3(neckSway - neckW*0.5, neckBaseY + neckH*0.62, neckFwdZ))
            * neckTilt
            * EntityRenderer.scaleM(SIMD3(s*0.04, s*0.16, neckD*1.10))
        drawCube(enc: enc, viewProj: viewProj, model: neckSpot1, rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: neckSpot2, rgb: patchCol, sat: sat)

        // ---- HEAD — tiny, at top of neck ----
        let neckTopLY  = neckBaseY + cos(-0.16) * neckH
        let neckTopLZ  = neckFwdZ  + sin( 0.16) * neckH
        let headY      = neckTopLY + hH * 0.42
        let headZ      = neckTopLZ + hD * 0.18
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: baseCol, sat: sat)

        // Long narrow muzzle — paler cream, extends forward
        let snoutZ    = headZ + hD * 0.50 + s * 0.14
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway, headY - hH*0.08, snoutZ),
                           SIMD3(hW*0.60, hH*0.62, s*0.30)),
                 rgb: muzzleCol, sat: sat)
        // Nostrils — two dark dots at muzzle tip
        let nostCol = patchCol
        let nostZ   = snoutZ + s * 0.16
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway - hW*0.14, headY - hH*0.12, nostZ), SIMD3(s*0.04, s*0.04, s*0.03)),
                 rgb: nostCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway + hW*0.14, headY - hH*0.12, nostZ), SIMD3(s*0.04, s*0.04, s*0.03)),
                 rgb: nostCol, sat: sat)

        // Gentle front-facing eyes — wide-set on the small head, cream sclera
        let gfFaceZ  = headZ + hD * 0.46
        let geW = s * 0.08; let geH = s * 0.10 * eyeBlinkSY; let geD = s * 0.05
        let geY = headY + hH * 0.16
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(neckSway - hW*0.30, geY, gfFaceZ), r: SIMD3(geW, geH, geD),
                sat: sat, scleraCol: SIMD3(0.95, 0.92, 0.86), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(neckSway + hW*0.30, geY, gfFaceZ), r: SIMD3(geW, geH, geD),
                sat: sat, scleraCol: SIMD3(0.95, 0.92, 0.86), pupilCol: eyeCol)
        // Long eyelashes (giraffe charm)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway - hW*0.30, geY + geH*1.25, gfFaceZ), SIMD3(geW*1.6, s*0.02, geD)),
                 rgb: lashCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway + hW*0.30, geY + geH*1.25, gfFaceZ), SIMD3(geW*1.6, s*0.02, geD)),
                 rgb: lashCol, sat: sat)

        // Ossicones — two stubby horn-knobs on top of head
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway - hW*0.24, headY + hH*0.50 + ossH*0.5, headZ - hD*0.08),
                           SIMD3(ossW, ossH, ossD)),
                 rgb: patchCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(neckSway + hW*0.24, headY + hH*0.50 + ossH*0.5, headZ - hD*0.08),
                           SIMD3(ossW, ossH, ossD)),
                 rgb: patchCol, sat: sat)

        // Short tail with tufted dark tip
        let tailShaftW = s * 0.07; let tailShaftH = s * 0.18; let tailShaftD = s * 0.07
        let tailTuftW  = s * 0.13; let tailTuftH  = s * 0.14; let tailTuftD  = s * 0.09
        do {
            let tailPivot = SIMD3<Float>(0, bH * 0.30, -bD * 0.48)
            let shaftModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailAng)
                * EntityRenderer.trans(SIMD3(0, -tailShaftH * 0.5, -tailShaftD * 0.5))
                * EntityRenderer.scaleM(SIMD3(tailShaftW, tailShaftH, tailShaftD))
            let tuftModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailAng)
                * EntityRenderer.trans(SIMD3(0, -tailShaftH - tailTuftH*0.5, -tailShaftD*0.5))
                * EntityRenderer.scaleM(SIMD3(tailTuftW, tailTuftH, tailTuftD))
            drawCube(enc: enc, viewProj: viewProj, model: shaftModel, rgb: legCol,    sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: tuftModel,  rgb: patchCol,  sat: sat)
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
        let base     = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        // ---- PALETTE: lizard ----
        // Push entity color toward green-reptile hue
        let baseCol  = SIMD3<Float>(min(1, base.x*0.55+0.04),
                                    min(1, base.y*0.70+0.10),
                                    min(1, base.z*0.40+0.02))
        let darkCol  = baseCol * 0.56   // dorsal back, snout, dark legs
        // Pale yellowish-green belly — very distinct from top
        let bellyCol = SIMD3<Float>(min(1.0, baseCol.x*0.58+0.32),
                                    min(1.0, baseCol.y*0.62+0.28),
                                    min(1.0, baseCol.z*0.40+0.20))
        let ridgeCol = baseCol * 0.78   // mid-dark for dorsal ridge
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
        let base    = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        // ---- PALETTE: ram ----
        // baseCol: tawny warm body
        let baseCol = SIMD3<Float>(min(1, base.x*0.74+0.16),
                                   min(1, base.y*0.62+0.10),
                                   min(1, base.z*0.42+0.04))
        // darkCol: face, lower legs, shoulder hump — clearly darker
        let darkCol = baseCol * 0.54
        // Warm amber horn color — shifted toward horn-ivory
        let hornCol = SIMD3<Float>(min(1.0, baseCol.x*0.62+0.30),
                                   min(1.0, baseCol.y*0.54+0.22),
                                   min(1.0, baseCol.z*0.28+0.04))
        // tufCol: fluffy lighter back mane — slightly brighter than base
        let tufCol  = SIMD3<Float>(min(1, baseCol.x*1.12+0.04),
                                   min(1, baseCol.y*1.10+0.04),
                                   min(1, baseCol.z*1.08+0.02))
        // Belly: pale underside
        let bellyCol = SIMD3<Float>(min(1, baseCol.x*0.68+0.28),
                                    min(1, baseCol.y*0.68+0.24),
                                    min(1, baseCol.z*0.62+0.18))
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
        // Pale belly underside — noticeably lighter than back
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH*0.26, 0), SIMD3(bW*0.80, bH*0.46, bD*0.82)),
                 rgb: bellyCol, sat: sat)
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
    // KIND 4 — BOSS (friendly giant, redesigned for detail + menace-but-friendly)
    //
    // Design goals:
    //   — Layered torso: core body + chest plate + belly + shoulder flanges
    //   — Defined limb sections: upper leg (thick) + lower leg (slightly narrower)
    //   — Mane/crest fringe: row of thick spiky blocks around the head base
    //   — Crown of 3 spires with a ring base (not just floating pillars)
    //   — 5 dorsal spikes (more ridge-like)
    //   — Friendly face: raised brows, big grin, square teeth, glowing HDR amber eyes
    //   — Heavy stomp gait, crown bobs, spikes quiver
    //
    // PALETTE:
    //   baseCol    = entity base color (the boss's main body color)
    //   darkCol    = 0.52× base — shadowed flanks, lower legs, chin
    //   midCol     = 0.78× base — chest plate, shoulder tops, upper legs
    //   crownCol   = 1.30× base (clamped to 1) — crown spires + dorsal spikes + mane
    //   bellyCol   = 1.10× base + warm tint — belly underside (lighter)
    //   eyeGlowCol = HDR amber (unchanged)
    //
    // Parts: legs-upper(4) legs-lower(4) body(1) belly(1) chest-plate(1)
    //        shoulder-armor(2) mane-fringe(5) head(1) head-brow-ridge(1)
    //        chin-plate(1) dorsal-spikes(5) crown-base(1) crown-spires(3)
    //        eyes(2-emissive) face-brows(2) grin(3) teeth(2) = 40 parts
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
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE ----
        let baseCol  = base
        let darkCol  = base * 0.52
        let midCol   = base * 0.78
        let crownCol = SIMD3<Float>(min(1, base.x*1.30), min(1, base.y*1.30), min(1, base.z*1.30))
        let bellyCol = SIMD3<Float>(min(1, base.x*1.08+0.06), min(1, base.y*1.06+0.04), min(1, base.z*1.04+0.02))
        // HDR eye glow — luminance > 1 → bloom (unchanged)
        let eyeGlowCol = SIMD3<Float>(2.8, 1.2, 0.1)

        let stompSpeed: Float = 1.4
        let legSwing  = sin(phase * stompSpeed) * 0.30
        let stompRaw  = sin(phase * stompSpeed)
        let stomp     = (stompRaw < 0 ? stompRaw * stompRaw : Float(0)) * s * 0.025

        let crownBob  = sin(phase * 0.90 + hash * 1.5) * s * 0.016
        let spikeQuiv = sin(phase * 2.40 + hash * 3.3) * 0.04
        let maneWave  = sin(phase * 1.20 + hash * 2.1) * 0.06   // mane fringe sway

        let blinkPhase = phase * 1.8 + hash * 3.5
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS ----
        let bW = s * 1.00;  let bH = s * 0.78;  let bD = s * 0.92
        let hS = s * 0.74                    // head size (cubic-ish)
        // Layered legs: upper (thicker) + lower (slightly narrower) for defined limb
        let lupW = s * 0.32; let lupH = s * 0.28; let lupD = s * 0.32
        let llwW = s * 0.26; let llwH = s * 0.28; let llwD = s * 0.26
        let legTotalH = lupH + llwH
        let crownW = s * 0.17; let crownH = s * 0.40; let crownD = s * 0.17
        let crownBaseW = s * 0.62; let crownBaseH = s * 0.10; let crownBaseD = s * 0.46
        let spkW = s * 0.13; let spkD = s * 0.10
        let spikeHeights: [Float] = [s*0.22, s*0.32, s*0.40, s*0.30, s*0.20]
        let spikeZOffsets: [Float] = [bD*0.38, bD*0.18, 0, -bD*0.20, -bD*0.38]
        let armorW = s * 0.26; let armorH = s * 0.32; let armorD = s * 0.74
        let chinW = s * 0.42; let chinH = s * 0.14; let chinD = s * 0.24

        let groundY = pos.y
        let bodyY   = groundY + legTotalH + bH * 0.5 + stomp
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        // Upper leg: pivots at hip
        func luw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -lupH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(lupW, lupH, lupD))
        }
        // Lower leg: hangs from bottom of upper leg, follows same swing
        func llw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -lupH - llwH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(llwW, llwH, llwD))
        }

        let hipY = -bH * 0.5
        let hipFL = SIMD3<Float>(-bW * 0.36, hipY,  bD * 0.32)
        let hipFR = SIMD3<Float>( bW * 0.36, hipY,  bD * 0.32)
        let hipBL = SIMD3<Float>(-bW * 0.36, hipY, -bD * 0.32)
        let hipBR = SIMD3<Float>( bW * 0.36, hipY, -bD * 0.32)

        // 4 layered legs (upper + lower each)
        drawCube(enc: enc, viewProj: viewProj, model: luw(hipFL,  legSwing), rgb: midCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: luw(hipFR, -legSwing), rgb: midCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: luw(hipBL, -legSwing), rgb: midCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: luw(hipBR,  legSwing), rgb: midCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llw(hipFL,  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llw(hipFR, -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llw(hipBL, -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llw(hipBR,  legSwing), rgb: darkCol, sat: sat)

        // Body core
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Belly — slightly lighter underside
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH*0.28, bD*0.08), SIMD3(bW*0.76, bH*0.44, bD*0.72)),
                 rgb: bellyCol, sat: sat)
        // Chest plate — a raised armored slab on the front-upper body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH*0.22, bD*0.46), SIMD3(bW*0.84, bH*0.48, s*0.08)),
                 rgb: midCol, sat: sat)
        // Shoulder armor flanges — jut out wide on both sides
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bW*0.50 - armorW*0.40, bH*0.28, 0),
                           SIMD3(armorW, armorH, armorD)),
                 rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( bW*0.50 + armorW*0.40, bH*0.28, 0),
                           SIMD3(armorW, armorH, armorD)),
                 rgb: darkCol, sat: sat)

        // Dorsal spikes — 5-spike ridge along spine top, quiver, varying heights
        let spikeBaseY = bH * 0.50
        let spkTilt = EntityRenderer.rotX(spikeQuiv)
        for idx in 0..<5 {
            let spkH = spikeHeights[idx]
            let spkZ = spikeZOffsets[idx]
            let spkModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3(0, spikeBaseY + spkH*0.5, spkZ))
                * spkTilt
                * EntityRenderer.scaleM(SIMD3(spkW, spkH, spkD))
            drawCube(enc: enc, viewProj: viewProj, model: spkModel, rgb: crownCol, sat: sat)
        }

        // ---- HEAD — massive, pushed forward ----
        let headY: Float = bH * 0.34
        let headZ: Float = bD * 0.50 + hS * 0.40
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS, hS*0.84)),
                 rgb: baseCol, sat: sat)
        // Brow ridge — a heavy dark ledge above the eye line
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY + hS*0.30, headZ + hS*0.42),
                           SIMD3(hS*0.96, s*0.12, s*0.10)),
                 rgb: darkCol, sat: sat)
        // Chin plate — heavy jaw slab
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hS*0.44, headZ + hS*0.10),
                           SIMD3(chinW, chinH, chinD)),
                 rgb: darkCol, sat: sat)

        // MANE/CREST FRINGE — 5 thick spike-blocks ringing the back/sides of head base
        // gives the boss a lion-mane silhouette
        let maneOffsets: [(Float, Float, Float)] = [
            (-hS*0.52, headY, headZ - hS*0.05),   // left side
            ( hS*0.52, headY, headZ - hS*0.05),   // right side
            (-hS*0.38, headY + hS*0.36, headZ - hS*0.20),   // upper-left
            ( hS*0.38, headY + hS*0.36, headZ - hS*0.20),   // upper-right
            (       0, headY + hS*0.44, headZ - hS*0.30),   // top-back
        ]
        let maneTilt = EntityRenderer.rotX(maneWave)
        for (mx, my, mz) in maneOffsets {
            let maneM = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3(mx, my, mz))
                * maneTilt
                * EntityRenderer.scaleM(SIMD3(s*0.14, s*0.26, s*0.14))
            drawCube(enc: enc, viewProj: viewProj, model: maneM, rgb: crownCol, sat: sat)
        }

        // ---- FACE ----
        let bsFaceZ = headZ + hS * 0.42
        // Glowing HDR amber eyes (unchanged — emissive, no shading)
        let eyeW = s * 0.15; let eyeH = s * 0.15 * eyeBlinkSY; let eyeD = s * 0.05
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.22, headY + hS*0.06, bsFaceZ), SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeGlowCol, sat: -1.0)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.22, headY + hS*0.06, bsFaceZ), SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeGlowCol, sat: -1.0)
        // Friendly raised brows — angled upward-outward
        let browL = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3(-hS*0.22, headY + hS*0.22, bsFaceZ))
            * EntityRenderer.rotZ(0.24)
            * EntityRenderer.scaleM(SIMD3(s*0.22, s*0.06, s*0.05))
        let browR = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3( hS*0.22, headY + hS*0.22, bsFaceZ))
            * EntityRenderer.rotZ(-0.24)
            * EntityRenderer.scaleM(SIMD3(s*0.22, s*0.06, s*0.05))
        drawCube(enc: enc, viewProj: viewProj, model: browL, rgb: crownCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: browR, rgb: crownCol, sat: sat)
        // Big friendly grin with upturned corners
        let grinCol = SIMD3<Float>(0.10, 0.05, 0.05)
        let grinY   = headY - hS * 0.20
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, grinY, bsFaceZ), SIMD3(hS*0.54, s*0.07, s*0.05)),
                 rgb: grinCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.28, grinY + s*0.07, bsFaceZ), SIMD3(s*0.09, s*0.07, s*0.05)),
                 rgb: grinCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.28, grinY + s*0.07, bsFaceZ), SIMD3(s*0.09, s*0.07, s*0.05)),
                 rgb: grinCol, sat: sat)
        // Friendly square teeth
        let bossTooth = SIMD3<Float>(0.95, 0.95, 0.90)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-s*0.07, grinY + s*0.02, bsFaceZ + s*0.01), SIMD3(s*0.08, s*0.07, s*0.03)),
                 rgb: bossTooth, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( s*0.07, grinY + s*0.02, bsFaceZ + s*0.01), SIMD3(s*0.08, s*0.07, s*0.03)),
                 rgb: bossTooth, sat: sat)

        // ---- CROWN — ring base + 3 spires ----
        let crownBaseY = headY + hS * 0.50
        // Ring base (a flat slab the spires grow from)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, crownBaseY + crownBaseH*0.5, headZ),
                           SIMD3(crownBaseW, crownBaseH, crownBaseD)),
                 rgb: midCol, sat: sat)
        // Center spire — tallest, bobs
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, crownBaseY + crownBaseH + crownH*0.60 + crownBob, headZ),
                           SIMD3(crownW, crownH*1.25, crownD)),
                 rgb: crownCol, sat: sat)
        // Flanking spires
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hS*0.30, crownBaseY + crownBaseH + crownH*0.50, headZ),
                           SIMD3(crownW, crownH, crownD)),
                 rgb: crownCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hS*0.30, crownBaseY + crownBaseH + crownH*0.50, headZ),
                           SIMD3(crownW, crownH, crownD)),
                 rgb: crownCol, sat: sat)
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

        // PALETTE: night beast (kind 5) — deep purple/maroon body, clearly colored
        // but dark enough to stay creepy.  Entity tint provides per-instance variation
        // so a pack is not identical.
        let tint = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        // phaseHash already computed above; use it as a small per-creature offset.
        let tvar = (hash + 1.0) * 0.5   // 0..1 range from phaseHash
        // Back/top of body: deep maroon-purple — dark but unmistakably colored.
        let bodyCol  = tint * 0.14 + SIMD3<Float>(
            0.22 + tvar * 0.06,   // r: maroon base, varies warm
            0.04 + tvar * 0.02,   // g: nearly absent
            0.18 + tvar * 0.04)   // b: purple cast
        // Belly/front of body: a shade lighter and slightly warmer (deep bruise-purple)
        let bellyCol5 = tint * 0.16 + SIMD3<Float>(
            0.34 + tvar * 0.05,
            0.07 + tvar * 0.02,
            0.26 + tvar * 0.03)
        // Limbs (legs, upper arms): mid dark — between body and claws so depth reads
        let limbCol  = tint * 0.18 + SIMD3<Float>(
            0.28 + tvar * 0.04,
            0.05 + tvar * 0.02,
            0.22 + tvar * 0.03)
        // Spikes on back: bony pale — clearly lighter, almost tinted bone-ivory
        let spikeCol = tint * 0.12 + SIMD3<Float>(0.58, 0.46, 0.28)
        // Claws/forearms: bright sickly yellow-green accent — pop against the dark
        let clawCol  = tint * 0.10 + SIMD3<Float>(0.52, 0.62, 0.18)
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

        // Body — hunched (via bodyHunch in pw), dark maroon-purple top
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: bodyCol, sat: sat)
        // Belly / chest wedge — lighter bruise-purple so the underside reads separately
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.10, bD * 0.32),
                           SIMD3(bW * 0.78, bH * 0.60, bD * 0.30)),
                 rgb: bellyCol5, sat: sat)
        // Faint emissive rim on body sides (very low HDR, just enough to read at night).
        // Two thin slabs on left/right flanks with sat = -1 so they bypass shading.
        let rimCol5 = bodyCol + SIMD3<Float>(0.28, 0.04, 0.22)  // adds a dim purple glow rim
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bW * 0.50, 0, 0), SIMD3(s * 0.03, bH * 0.85, bD * 0.80)),
                 rgb: rimCol5, sat: -1.0)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( bW * 0.50, 0, 0), SIMD3(s * 0.03, bH * 0.85, bD * 0.80)),
                 rgb: rimCol5, sat: -1.0)

        // Back spikes — bony pale ivory, jagged uneven row
        for idx in 0..<5 {
            let spkH = spikeHeights[idx]
            let spkZ = spikeZOffsets[idx]
            let spkModel = EntityRenderer.trans(wc) * R * bodyHunch
                * EntityRenderer.trans(SIMD3(0, bH * 0.50 + spkH * 0.5, spkZ))
                * EntityRenderer.scaleM(SIMD3(spikeW, spkH, spikeD))
            drawCube(enc: enc, viewProj: viewProj, model: spkModel, rgb: spikeCol, sat: sat)
        }

        // Head — wide flat, sits low on body (menacing forward thrust)
        // Use bellyCol5 (lighter) so the head reads distinct from the dark back body.
        let headY: Float = bH * 0.22
        let headZ: Float = bD * 0.46 + hD * 0.42
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: bellyCol5, sat: sat)

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
        // ANGRY BROWS — bone-ivory (match spike color) angled bars pressing inward-down
        // (inner ends low, outer ends high → classic angry "V" scowl).
        // Using spikeCol (bony pale) here so brows contrast against the purple head.
        let mnBrowCol = spikeCol
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

        // 4 angled legs — placed slightly splayed for menacing stance.
        // Use limbCol (mid-dark, between body and claw) for upper leg; clawCol at tip.
        // Legs use world-space (no bodyHunch) so they plant on the ground correctly
        let hipY = -(bH * 0.5 + lurchY)   // offset for body lurch to keep feet near ground
        let legSplayAngleL = EntityRenderer.rotZ(-0.18)   // splay left legs outward
        let legSplayAngleR = EntityRenderer.rotZ( 0.18)
        // Upper leg height (half of total leg, used to place the claw tip)
        let upperLegH = legH * 0.55
        do {
            // Front-left (upper limb segment)
            let hipFL = SIMD3<Float>(-bW * 0.44, bH * 0.5 + hipY, bD * 0.30)
            let flUpper = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipFL)
                * legSplayAngleL
                * EntityRenderer.rotX(legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -upperLegH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, upperLegH, legD))
            // Front-left (claw tip segment)
            let flClaw = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipFL)
                * legSplayAngleL
                * EntityRenderer.rotX(legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -upperLegH - (legH - upperLegH) * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW * 0.80, legH - upperLegH, legD * 0.80))
            drawCube(enc: enc, viewProj: viewProj, model: flUpper, rgb: limbCol,  sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: flClaw,  rgb: clawCol, sat: sat)
            // Front-right
            let hipFR = SIMD3<Float>( bW * 0.44, bH * 0.5 + hipY, bD * 0.30)
            let frUpper = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipFR)
                * legSplayAngleR
                * EntityRenderer.rotX(-legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -upperLegH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, upperLegH, legD))
            let frClaw = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipFR)
                * legSplayAngleR
                * EntityRenderer.rotX(-legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -upperLegH - (legH - upperLegH) * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW * 0.80, legH - upperLegH, legD * 0.80))
            drawCube(enc: enc, viewProj: viewProj, model: frUpper, rgb: limbCol,  sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: frClaw,  rgb: clawCol, sat: sat)
            // Back-left
            let hipBL = SIMD3<Float>(-bW * 0.44, bH * 0.5 + hipY, -bD * 0.28)
            let blUpper = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipBL)
                * legSplayAngleL
                * EntityRenderer.rotX(-legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -upperLegH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, upperLegH, legD))
            let blClaw = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipBL)
                * legSplayAngleL
                * EntityRenderer.rotX(-legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -upperLegH - (legH - upperLegH) * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW * 0.80, legH - upperLegH, legD * 0.80))
            drawCube(enc: enc, viewProj: viewProj, model: blUpper, rgb: limbCol,  sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: blClaw,  rgb: clawCol, sat: sat)
            // Back-right
            let hipBR = SIMD3<Float>( bW * 0.44, bH * 0.5 + hipY, -bD * 0.28)
            let brUpper = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipBR)
                * legSplayAngleR
                * EntityRenderer.rotX(legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -upperLegH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, upperLegH, legD))
            let brClaw = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(hipBR)
                * legSplayAngleR
                * EntityRenderer.rotX(legSwingFast)
                * EntityRenderer.trans(SIMD3(0, -upperLegH - (legH - upperLegH) * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW * 0.80, legH - upperLegH, legD * 0.80))
            drawCube(enc: enc, viewProj: viewProj, model: brUpper, rgb: limbCol,  sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: brClaw,  rgb: clawCol, sat: sat)
        }

        // 2 CLAWED ARMS — jut from upper sides of body, claw forward/back.
        // Upper arm segment uses limbCol; forearm claw tip uses clawCol (bright accent).
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
            drawCube(enc: enc, viewProj: viewProj, model: upperArmLModel, rgb: limbCol, sat: sat)
            // Forearm claw — hangs from upper arm tip, extra forward claw angle; bright accent
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
            drawCube(enc: enc, viewProj: viewProj, model: upperArmRModel, rgb: limbCol, sat: sat)
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
    // KIND 7 — FOX / CAT-LIKE PROWLER
    //
    // Silhouette: sleek low body, LONG bushy tail arching up from rear (key),
    // two sharp pointed ears on the head, narrow snout block, alert upright posture.
    //
    // PALETTE (from entity base color):
    //   backCol   = russet/red-orange back & top (warm, saturated)
    //   bellyCol  = cream/pale underside
    //   accentCol = dark ears tips, paws, tail tip
    //   snoutCol  = pale muzzle cream
    //
    // Parts: body(1) belly(1) tail-base(1) tail-mid(1) tail-tip(1)
    //        head(1) snout(1) ears-outer(2) ears-inner(2) eyes(2)
    //        legs(4) = 17 parts
    //
    // Animation: walk cycle, ear twitch, tail sways up in wide arc, blink, breathe
    // =========================================================================
    private func drawKind7(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: fox ----
        // Warm russet back
        let backCol   = SIMD3<Float>(min(1, base.x*0.70+0.26), min(1, base.y*0.36+0.06), min(1, base.z*0.14+0.02))
        // Pale cream belly and snout
        let bellyCol  = SIMD3<Float>(min(1, base.x*0.40+0.54), min(1, base.y*0.36+0.48), min(1, base.z*0.28+0.40))
        // Dark ear tips, paws, tail tip
        let accentCol = SIMD3<Float>(min(1, base.x*0.22+0.04), min(1, base.y*0.14+0.02), min(1, base.z*0.10+0.01))
        // Inner ear pink
        let innerEarCol = SIMD3<Float>(min(1, backCol.x*0.72+0.22), min(1, backCol.y*0.38+0.10), min(1, backCol.z*0.30+0.08))
        let eyeCol    = SIMD3<Float>(0.04, 0.06, 0.04)   // dark with amber hint

        let blinkPhase  = phase + hash * 4.3
        let breathPhase = phase * 0.38 + hash * 2.0
        let earPhase    = phase + hash * 5.8
        let tailPhase   = phase + hash * 2.5

        let walkSpeed: Float = 2.6
        let legSwing  = sin(phase * walkSpeed) * 0.32
        let breatheY  = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)
        let earTwitchL = earTwitchAngle(earPhase, side: -1)
        let earTwitchR = earTwitchAngle(earPhase, side:  1)

        // Bushy tail: 3 segments arching UP from rear — key silhouette
        // Tail sways side to side AND has a big upward arch
        let tailSwayY = tailWagAngle(tailPhase) * 0.60   // side sway
        let tailLiftBase: Float = 0.80   // arc angle for base (rotX backward = lifts up behind)
        let tailLiftMid:  Float = 0.55
        let tailLiftTip:  Float = 0.30

        // ---- PROPORTIONS ----
        let bW = s*0.52;  let bH = s*0.38;  let bD = s*0.70   // sleek body
        let hW = s*0.38;  let hH = s*0.36;  let hD = s*0.40   // refined head
        let earW = s*0.12; let earH = s*0.30; let earD = s*0.08  // tall pointy ears
        let innerW = s*0.07; let innerH = s*0.22; let innerD = s*0.02
        let snW = s*0.22; let snH = s*0.18; let snD = s*0.28  // narrow snout
        let legW = s*0.13; let legH = s*0.36; let legD = s*0.13
        // Tail segments diminishing, arching upward
        let t1W = s*0.18; let t1H = s*0.42; let t1D = s*0.18  // base (thick)
        let t2W = s*0.16; let t2H = s*0.36; let t2D = s*0.16  // mid
        let t3W = s*0.20; let t3H = s*0.28; let t3D = s*0.20  // tip (fluffy = wider)

        let groundY = pos.y
        let bodyY   = groundY + legH + bH*0.5 + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Body — sleek low
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: backCol, sat: sat)
        // Belly underside — cream
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH*0.26, bD*0.08), SIMD3(bW*0.76, bH*0.44, bD*0.76)),
                 rgb: bellyCol, sat: sat)

        // Bushy tail — 3 segments chained, arching up behind
        do {
            let tailPivot = SIMD3<Float>(0, bH*0.26, -bD*0.48)
            // Base segment: arc backward-up (rotX negative = tip goes up behind)
            let t1Model = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailSwayY)
                * EntityRenderer.rotX(-tailLiftBase)
                * EntityRenderer.trans(SIMD3(0, t1H*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(t1W, t1H, t1D))
            drawCube(enc: enc, viewProj: viewProj, model: t1Model, rgb: backCol, sat: sat)
            // Mid segment: curls further
            let t2Model = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailSwayY)
                * EntityRenderer.rotX(-tailLiftBase)
                * EntityRenderer.trans(SIMD3(0, t1H, 0))
                * EntityRenderer.rotX(-tailLiftMid + tailLiftBase)
                * EntityRenderer.trans(SIMD3(0, t2H*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(t2W, t2H, t2D))
            drawCube(enc: enc, viewProj: viewProj, model: t2Model, rgb: backCol, sat: sat)
            // White tip — fluffy and wider
            let t3Model = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailSwayY)
                * EntityRenderer.rotX(-tailLiftBase)
                * EntityRenderer.trans(SIMD3(0, t1H, 0))
                * EntityRenderer.rotX(-tailLiftMid + tailLiftBase)
                * EntityRenderer.trans(SIMD3(0, t2H, 0))
                * EntityRenderer.rotX(-tailLiftTip + tailLiftMid)
                * EntityRenderer.trans(SIMD3(0, t3H*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(t3W, t3H, t3D))
            drawCube(enc: enc, viewProj: viewProj, model: t3Model, rgb: bellyCol, sat: sat)
        }

        // Head — slightly narrower than body, elevated
        let headY: Float = bH*0.45 + hH*0.46
        let headZ: Float = bD*0.34
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: backCol, sat: sat)
        // Narrow snout — pale cream, juts forward
        let snoutZ = headZ + hD*0.48 + snD*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hH*0.10, snoutZ), SIMD3(snW, snH, snD)),
                 rgb: bellyCol, sat: sat)
        // Dark nose tip
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hH*0.10 + snH*0.08, snoutZ + snD*0.50), SIMD3(s*0.08, s*0.07, s*0.04)),
                 rgb: accentCol, sat: sat)

        // Eyes — bright, alert
        let faceZ   = headZ + hD*0.46
        let eyeW    = s*0.09; let eyeH = s*0.11 * eyeBlinkSY; let eyeD = s*0.05
        let eyeY    = headY + hH*0.10
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hW*0.28, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: SIMD3(0.92, 0.82, 0.50), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hW*0.28, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: SIMD3(0.92, 0.82, 0.50), pupilCol: eyeCol)

        // TALL POINTED EARS — fox's key feature
        let earBaseY = headY + hH*0.48
        let earLeanL = EntityRenderer.rotZ( 0.14)
        let earLeanR = EntityRenderer.rotZ(-0.14)
        do {
            let pivotL = SIMD3<Float>(-hW*0.26, earBaseY, headZ - hD*0.10)
            let pivotR = SIMD3<Float>( hW*0.26, earBaseY, headZ - hD*0.10)
            let earLM = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotL)
                * earLeanL * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, earH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            let earRM = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotR)
                * earLeanR * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, earH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            drawCube(enc: enc, viewProj: viewProj, model: earLM, rgb: backCol,  sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: earRM, rgb: backCol,  sat: sat)
            // Dark ear tip accent (top 1/4 of ear)
            let earTipL = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotL)
                * earLeanL * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, earH*0.80, 0))
                * EntityRenderer.scaleM(SIMD3(earW*0.70, earH*0.28, earD))
            let earTipR = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotR)
                * earLeanR * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, earH*0.80, 0))
                * EntityRenderer.scaleM(SIMD3(earW*0.70, earH*0.28, earD))
            drawCube(enc: enc, viewProj: viewProj, model: earTipL, rgb: accentCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: earTipR, rgb: accentCol, sat: sat)
            // Pink inner ear stripe
            let innerL = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotL)
                * earLeanL * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, innerH*0.5 + earH*0.04, innerD*0.5 + earD*0.5))
                * EntityRenderer.scaleM(SIMD3(innerW, innerH, innerD))
            let innerR = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotR)
                * earLeanR * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, innerH*0.5 + earH*0.04, innerD*0.5 + earD*0.5))
                * EntityRenderer.scaleM(SIMD3(innerW, innerH, innerD))
            drawCube(enc: enc, viewProj: viewProj, model: innerL, rgb: innerEarCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: innerR, rgb: innerEarCol, sat: sat)
        }

        // 4 slender legs with dark paw tips
        let hipY = -bH*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.30, hipY,  bD*0.30),  legSwing), rgb: backCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.30, hipY,  bD*0.30), -legSwing), rgb: backCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-bW*0.30, hipY, -bD*0.30), -legSwing), rgb: backCol,   sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( bW*0.30, hipY, -bD*0.30),  legSwing), rgb: backCol,   sat: sat)
        // Dark paw blocks at leg bottoms
        let pawH = s*0.08
        func pawBlock(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH - pawH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW*1.15, pawH, legD*1.15))
        }
        drawCube(enc: enc, viewProj: viewProj,
                 model: pawBlock(SIMD3(-bW*0.30, hipY,  bD*0.30),  legSwing), rgb: accentCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pawBlock(SIMD3( bW*0.30, hipY,  bD*0.30), -legSwing), rgb: accentCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pawBlock(SIMD3(-bW*0.30, hipY, -bD*0.30), -legSwing), rgb: accentCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pawBlock(SIMD3( bW*0.30, hipY, -bD*0.30),  legSwing), rgb: accentCol, sat: sat)
    }

    // =========================================================================
    // KIND 21 — PLATYPUS (Perry-style secret agent)
    // Teal, low flat streamlined body, wide flat duck BILL (orange), broad flat
    // beaver paddle TAIL, four short webbed legs, beady eyes, and a little fedora.
    // =========================================================================
    private func drawKind21(enc: MTLRenderCommandEncoder, viewProj: simd_float4x4,
                            e: bf_entity_draw, pos: SIMD3<Float>, phase: Float, hash: Float,
                            squash: SIMD3<Float>) {
        let s = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // PALETTE: mostly fixed teal (Perry), lightly tinted by the entity colour.
        let bodyCol  = SIMD3<Float>(min(1, base.x*0.18+0.24), min(1, base.y*0.30+0.52), min(1, base.z*0.30+0.50))
        let bellyCol = SIMD3<Float>(min(1, bodyCol.x*0.6+0.34), min(1, bodyCol.y*0.6+0.30), min(1, bodyCol.z*0.6+0.28))
        let billCol  = SIMD3<Float>(0.88, 0.58, 0.26)                       // orange bill + webbed feet
        let tailCol  = SIMD3<Float>(bodyCol.x*0.7, bodyCol.y*0.7, bodyCol.z*0.7)  // darker teal paddle
        let eyeCol   = SIMD3<Float>(0.05, 0.06, 0.06)
        let hatCol   = SIMD3<Float>(0.34, 0.24, 0.16)                       // fedora brown
        let bandCol  = SIMD3<Float>(0.20, 0.14, 0.10)

        let blinkPhase  = phase + hash*4.3
        let breathPhase = phase*0.4 + hash*2.0
        let walkSpeed: Float = 2.4
        let legSwing   = sin(phase*walkSpeed) * 0.30
        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)
        let tailWag    = sin(phase*1.8 + hash*2.5) * 0.18                   // gentle paddle wag

        // PROPORTIONS — low, flat, wide.
        let bW = s*0.50, bH = s*0.24, bD = s*0.60
        let hW = s*0.34, hH = s*0.26, hD = s*0.28
        let billW = s*0.40, billH = s*0.09, billD = s*0.32
        let tlW = s*0.44, tlH = s*0.08, tlD = s*0.40
        let legW = s*0.11, legH = s*0.15, legD = s*0.11
        let footW = s*0.17, footH = s*0.04, footD = s*0.20

        let groundY = pos.y
        let bodyY   = groundY + legH + bH*0.5 + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float, _ dims: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip) * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -dims.y*0.5, 0)) * EntityRenderer.scaleM(dims)
        }

        // Body + belly
        drawCube(enc: enc, viewProj: viewProj, model: pw(SIMD3(0,0,0), SIMD3(bW,bH,bD)), rgb: bodyCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: pw(SIMD3(0,-bH*0.30,0), SIMD3(bW*0.82,bH*0.5,bD*0.82)), rgb: bellyCol, sat: sat)

        // Flat paddle tail behind, angled up a touch, wagging
        do {
            let pivot = SIMD3<Float>(0, bH*0.05, -bD*0.5)
            let m = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivot)
                * EntityRenderer.rotY(tailWag) * EntityRenderer.rotX(-0.18)
                * EntityRenderer.trans(SIMD3(0,0,-tlD*0.5))
                * EntityRenderer.scaleM(SIMD3(tlW,tlH,tlD))
            drawCube(enc: enc, viewProj: viewProj, model: m, rgb: tailCol, sat: sat)
        }

        // Head (front, slightly raised)
        let headY = bH*0.30 + hH*0.30
        let headZ = bD*0.40
        drawCube(enc: enc, viewProj: viewProj, model: pw(SIMD3(0,headY,headZ), SIMD3(hW,hH,hD)), rgb: bodyCol, sat: sat)

        // Duck BILL — wide, flat, juts forward
        let billY = headY - hH*0.20
        let billZ = headZ + hD*0.5 + billD*0.45
        drawCube(enc: enc, viewProj: viewProj, model: pw(SIMD3(0,billY,billZ), SIMD3(billW,billH,billD)), rgb: billCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: pw(SIMD3(0,billY+billH*0.42,billZ+billD*0.42), SIMD3(billW*0.5,billH*0.3,s*0.03)), rgb: SIMD3(0.60,0.38,0.16), sat: sat)

        // Beady eyes, top-front of head
        let faceZ = headZ + hD*0.42
        let eyeW = s*0.07, eyeH = s*0.09*eyeBlinkSY, eyeD = s*0.05
        let eyeY = headY + hH*0.20
        drawEye(enc: enc, viewProj: viewProj, pw: pw, c: SIMD3(-hW*0.26, eyeY, faceZ), r: SIMD3(eyeW,eyeH,eyeD), sat: sat, scleraCol: SIMD3(0.95,0.95,0.95), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw, c: SIMD3( hW*0.26, eyeY, faceZ), r: SIMD3(eyeW,eyeH,eyeD), sat: sat, scleraCol: SIMD3(0.95,0.95,0.95), pupilCol: eyeCol)

        // Secret-agent FEDORA (Perry nod): brim + crown + band
        let hatY = headY + hH*0.5
        drawCube(enc: enc, viewProj: viewProj, model: pw(SIMD3(0, hatY+s*0.01, headZ), SIMD3(hW*1.15, s*0.03, hD*1.10)), rgb: hatCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: pw(SIMD3(0, hatY+s*0.05, headZ), SIMD3(hW*0.68, s*0.04, hD*0.72)), rgb: bandCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: pw(SIMD3(0, hatY+s*0.10, headZ), SIMD3(hW*0.66, s*0.14, hD*0.70)), rgb: hatCol, sat: sat)

        // 4 short legs + flat webbed feet
        let hipY = -bH*0.5
        let legDims = SIMD3<Float>(legW, legH, legD)
        let hips: [(SIMD3<Float>, Float)] = [
            (SIMD3(-bW*0.34, hipY,  bD*0.30),  legSwing),
            (SIMD3( bW*0.34, hipY,  bD*0.30), -legSwing),
            (SIMD3(-bW*0.34, hipY, -bD*0.30), -legSwing),
            (SIMD3( bW*0.34, hipY, -bD*0.30),  legSwing),
        ]
        for (hip, ang) in hips {
            drawCube(enc: enc, viewProj: viewProj, model: lw(hip, ang, legDims), rgb: bodyCol, sat: sat)
            let foot = EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip) * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH - footH*0.5, footD*0.18))
                * EntityRenderer.scaleM(SIMD3(footW, footH, footD))
            drawCube(enc: enc, viewProj: viewProj, model: foot, rgb: billCol, sat: sat)
        }
    }

    // =========================================================================
    // KIND 8 — ROUND BIRD / CHICK
    //
    // Silhouette: VERY round puffy body (almost spherical), tiny orange beak,
    // two small wing-nubs on sides, two stubby legs, fan of tail feathers behind.
    // Hops like the bunny. Extremely compact and cute.
    //
    // PALETTE:
    //   bodyCol   = bright yellow (or tinted from entity color)
    //   beakCol   = orange
    //   wingTipCol = white
    //   legCol    = orange (same as beak — bird legs)
    //
    // Parts: body(1) wing-L(1) wing-R(1) wing-tip-L(1) wing-tip-R(1)
    //        tail-fan(3 feather blocks) head(1) beak(1) eyes(2) feet(2) legs(2) = 16
    // =========================================================================
    private func drawKind8(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: chick ----
        // Bright sunny yellow body (always warm regardless of entity hue)
        let bodyCol   = SIMD3<Float>(min(1, base.x*0.50+0.50), min(1, base.y*0.55+0.38), min(1, base.z*0.18+0.04))
        let beakCol   = SIMD3<Float>(0.96, 0.52, 0.08)   // bright orange beak/feet
        let wingTipCol = SIMD3<Float>(min(1, bodyCol.x+0.16), min(1, bodyCol.y+0.14), min(1, bodyCol.z+0.12))  // pale wing tips
        let darkEyeCol = SIMD3<Float>(0.04, 0.04, 0.06)

        let blinkPhase  = phase + hash * 3.6
        let breathPhase = phase * 0.38 + hash * 1.9
        let tailPhase   = phase + hash * 2.8

        let hopSpeed: Float = 4.2
        let hopAmt    = pow(max(0, sin(phase * hopSpeed * 0.5)), 2.0) * s * 0.16
        // Wing flap — little nubs flap when hopping
        let wingFlap  = sin(phase * hopSpeed) * 0.28
        let tailBob   = sin(phase * hopSpeed * 0.7 + tailPhase * 0.3) * 0.20

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS (very round) ----
        let bR = s*0.46   // body: nearly spherical
        let bW = bR*2.0; let bH = bR*1.85; let bD = bR*1.90
        let hS = s*0.38   // round head
        let wingW = s*0.28; let wingH = s*0.18; let wingD = s*0.12
        let tipW  = s*0.16; let tipH  = s*0.12; let tipD  = s*0.06
        let legW  = s*0.10; let legH  = s*0.22; let legD  = s*0.10
        let footW = s*0.16; let footH = s*0.06; let footD = s*0.14
        // Tail feathers — 3 fan blocks
        let tFW = s*0.16; let tFH = s*0.08; let tFD = s*0.20

        let groundY = pos.y
        let bodyY   = groundY + legH + bH*0.5 + hopAmt + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // Round body — main mass
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: bodyCol, sat: sat)

        // Wing nubs on sides — flap with hop
        do {
            let wingPivotL = SIMD3<Float>(-bW*0.50, 0, 0)
            let wingPivotR = SIMD3<Float>( bW*0.50, 0, 0)
            let wLM = EntityRenderer.trans(wc) * R * EntityRenderer.trans(wingPivotL)
                * EntityRenderer.rotZ(-wingFlap)
                * EntityRenderer.trans(SIMD3(-wingW*0.5, 0, 0))
                * EntityRenderer.scaleM(SIMD3(wingW, wingH, wingD))
            let wRM = EntityRenderer.trans(wc) * R * EntityRenderer.trans(wingPivotR)
                * EntityRenderer.rotZ( wingFlap)
                * EntityRenderer.trans(SIMD3( wingW*0.5, 0, 0))
                * EntityRenderer.scaleM(SIMD3(wingW, wingH, wingD))
            drawCube(enc: enc, viewProj: viewProj, model: wLM, rgb: bodyCol,    sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: wRM, rgb: bodyCol,    sat: sat)
            // Pale wing tips
            let tLM = EntityRenderer.trans(wc) * R * EntityRenderer.trans(wingPivotL)
                * EntityRenderer.rotZ(-wingFlap)
                * EntityRenderer.trans(SIMD3(-wingW - tipW*0.5, 0, 0))
                * EntityRenderer.scaleM(SIMD3(tipW, tipH, tipD))
            let tRM = EntityRenderer.trans(wc) * R * EntityRenderer.trans(wingPivotR)
                * EntityRenderer.rotZ( wingFlap)
                * EntityRenderer.trans(SIMD3( wingW + tipW*0.5, 0, 0))
                * EntityRenderer.scaleM(SIMD3(tipW, tipH, tipD))
            drawCube(enc: enc, viewProj: viewProj, model: tLM, rgb: wingTipCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: tRM, rgb: wingTipCol, sat: sat)
        }

        // Tail fan — 3 feather blocks fanning out behind (center + two angled)
        do {
            let fanPivot = SIMD3<Float>(0, bH*0.14, -bD*0.48)
            let fanCenter = EntityRenderer.trans(wc) * R * EntityRenderer.trans(fanPivot)
                * EntityRenderer.rotX(tailBob)
                * EntityRenderer.trans(SIMD3(0, 0, -tFD*0.5))
                * EntityRenderer.scaleM(SIMD3(tFW, tFH, tFD))
            let fanLeft = EntityRenderer.trans(wc) * R * EntityRenderer.trans(fanPivot)
                * EntityRenderer.rotY(-0.36) * EntityRenderer.rotX(tailBob)
                * EntityRenderer.trans(SIMD3(0, 0, -tFD*0.5))
                * EntityRenderer.scaleM(SIMD3(tFW*0.80, tFH, tFD*0.80))
            let fanRight = EntityRenderer.trans(wc) * R * EntityRenderer.trans(fanPivot)
                * EntityRenderer.rotY( 0.36) * EntityRenderer.rotX(tailBob)
                * EntityRenderer.trans(SIMD3(0, 0, -tFD*0.5))
                * EntityRenderer.scaleM(SIMD3(tFW*0.80, tFH, tFD*0.80))
            drawCube(enc: enc, viewProj: viewProj, model: fanCenter, rgb: wingTipCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: fanLeft,   rgb: bodyCol,   sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: fanRight,  rgb: bodyCol,   sat: sat)
        }

        // Round head sitting on top of body
        let headY: Float = bH*0.48 + hS*0.46
        let headZ: Float = bD*0.14
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS, hS*0.92)),
                 rgb: bodyCol, sat: sat)

        // Orange beak — two wedge-like blocks (upper beak)
        let bkFaceZ = headZ + hS*0.46
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hS*0.04, bkFaceZ + s*0.07), SIMD3(s*0.12, s*0.07, s*0.14)),
                 rgb: beakCol, sat: sat)
        // Lower beak (slightly smaller, angled down)
        let lowerBeak = EntityRenderer.trans(wc) * R
            * EntityRenderer.trans(SIMD3(0, headY - hS*0.10, bkFaceZ + s*0.04))
            * EntityRenderer.rotX(0.20)
            * EntityRenderer.scaleM(SIMD3(s*0.10, s*0.05, s*0.12))
        drawCube(enc: enc, viewProj: viewProj, model: lowerBeak, rgb: beakCol * 0.85, sat: sat)

        // Big round eyes — bird eyes are circular and bright
        let birdEyeW = s*0.11; let birdEyeH = s*0.12 * eyeBlinkSY; let birdEyeD = s*0.05
        let birdEyeY = headY + hS*0.14
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hS*0.30, birdEyeY, bkFaceZ), r: SIMD3(birdEyeW, birdEyeH, birdEyeD),
                sat: sat, scleraCol: SIMD3(0.98, 0.98, 0.96), pupilCol: darkEyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hS*0.30, birdEyeY, bkFaceZ), r: SIMD3(birdEyeW, birdEyeH, birdEyeD),
                sat: sat, scleraCol: SIMD3(0.98, 0.98, 0.96), pupilCol: darkEyeCol)

        // Stubby orange legs + flat feet
        let hipY = -bH*0.5
        let legHipL = SIMD3<Float>(-bW*0.18, hipY, bD*0.10)
        let legHipR = SIMD3<Float>( bW*0.18, hipY, bD*0.10)
        let legSwing = sin(phase * hopSpeed) * 0.18
        let legLL = EntityRenderer.trans(wc) * R * EntityRenderer.trans(legHipL)
            * EntityRenderer.rotX( legSwing)
            * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
            * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        let legRL = EntityRenderer.trans(wc) * R * EntityRenderer.trans(legHipR)
            * EntityRenderer.rotX(-legSwing)
            * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
            * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        drawCube(enc: enc, viewProj: viewProj, model: legLL, rgb: beakCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: legRL, rgb: beakCol, sat: sat)
        // Flat feet
        let footLL = EntityRenderer.trans(wc) * R * EntityRenderer.trans(legHipL)
            * EntityRenderer.rotX( legSwing)
            * EntityRenderer.trans(SIMD3(0, -legH - footH*0.5, footW*0.14))
            * EntityRenderer.scaleM(SIMD3(footW, footH, footD))
        let footRL = EntityRenderer.trans(wc) * R * EntityRenderer.trans(legHipR)
            * EntityRenderer.rotX(-legSwing)
            * EntityRenderer.trans(SIMD3(0, -legH - footH*0.5, footW*0.14))
            * EntityRenderer.scaleM(SIMD3(footW, footH, footD))
        drawCube(enc: enc, viewProj: viewProj, model: footLL, rgb: beakCol * 0.88, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: footRL, rgb: beakCol * 0.88, sat: sat)
    }

    // =========================================================================
    // KIND 9 — TURTLE / ARMADILLO
    //
    // Silhouette: LOW dome shell dominating the shape, four short stubby legs
    // barely peeking below the shell rim, small rounded head on a short neck,
    // tiny tail behind. Shell has plate/segment markings.
    //
    // PALETTE:
    //   shellTopCol  = olive/forest green dome (or tinted)
    //   shellPlateCol = darker greenish plate dividers (pattern lines)
    //   underCol     = pale yellowish underside (plastron)
    //   headCol      = mid-tone head and legs
    //
    // Parts: undercarriage(1) shell-dome(1) shell-plates(4 line-blocks)
    //        head(1) snout(1) eyes(2) neck(1) tail(1) legs(4) = 15
    // =========================================================================
    private func drawKind9(enc: MTLRenderCommandEncoder,
                           viewProj: simd_float4x4,
                           e: bf_entity_draw,
                           pos: SIMD3<Float>,
                           phase: Float,
                           hash: Float,
                           squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: turtle ----
        // Olive-green dome
        let shellTopCol   = SIMD3<Float>(min(1, base.x*0.26+0.12), min(1, base.y*0.50+0.16), min(1, base.z*0.14+0.04))
        // Dark plate dividers — clearly darker than shell
        let shellPlateCol = shellTopCol * 0.48
        // Pale yellowish plastron (underside)
        let underCol      = SIMD3<Float>(min(1, base.x*0.40+0.46), min(1, base.y*0.50+0.38), min(1, base.z*0.24+0.20))
        // Head/legs: earthy mid-tone
        let headCol       = SIMD3<Float>(min(1, base.x*0.30+0.18), min(1, base.y*0.46+0.16), min(1, base.z*0.14+0.06))
        let eyeCol        = SIMD3<Float>(0.04, 0.10, 0.04)   // dark green eyes

        let blinkPhase  = phase + hash * 4.0
        let breathPhase = phase * 0.32 + hash * 1.6   // very slow breath
        let tailPhase   = phase + hash * 3.1

        // Turtle is slow — gentle plod
        let plodSpeed: Float = 1.2
        let legSwing  = sin(phase * plodSpeed) * 0.20
        // Head bobs slightly, slowly retreats-extends
        let headPoke  = sin(phase * 0.80 + hash * 2.0) * s * 0.04   // head pokes in and out
        let tailWag   = sin(phase * plodSpeed * 0.7 + tailPhase * 0.4) * 0.22

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS ----
        let shW = s*0.80;  let shH = s*0.46;  let shD = s*0.72  // wide dome shell
        let underW = shW*0.92; let underH = s*0.08; let underD = shD*0.92  // flat plastron
        let legW = s*0.16; let legH = s*0.20; let legD = s*0.18  // stubby legs
        let neckW = s*0.20; let neckH = s*0.18; let neckD = s*0.20
        let hW = s*0.28; let hH = s*0.22; let hD = s*0.30  // small round head
        let snW = s*0.18; let snH = s*0.14; let snD = s*0.20  // blunt snout
        let tailW = s*0.10; let tailH = s*0.08; let tailD = s*0.16

        let groundY = pos.y
        // Turtle sits very low — only leg height
        let bodyY   = groundY + legH + underH + shH*0.5 + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }

        // Flat plastron (undercarriage)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -shH*0.50 - underH*0.5, 0), SIMD3(underW, underH, underD)),
                 rgb: underCol, sat: sat)

        // Shell dome — the dominant shape
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(shW, shH, shD)), rgb: shellTopCol, sat: sat)

        // Shell plate dividers — 4 dark lines making a grid pattern on the shell
        // Horizontal (fore-aft) divider ridge along top-center
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, shH*0.46, 0), SIMD3(s*0.04, s*0.05, shD*0.88)),
                 rgb: shellPlateCol, sat: sat)
        // Transverse divider 1 (forward)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, shH*0.42, shD*0.24), SIMD3(shW*0.92, s*0.05, s*0.04)),
                 rgb: shellPlateCol, sat: sat)
        // Transverse divider 2 (mid)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, shH*0.44, -shD*0.04), SIMD3(shW*0.92, s*0.05, s*0.04)),
                 rgb: shellPlateCol, sat: sat)
        // Transverse divider 3 (rear)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, shH*0.40, -shD*0.28), SIMD3(shW*0.92, s*0.05, s*0.04)),
                 rgb: shellPlateCol, sat: sat)

        // Short neck peeking out from front of shell
        let neckZ = shD*0.46
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -shH*0.10 + headPoke*0.5, neckZ + neckD*0.4),
                           SIMD3(neckW, neckH, neckD)),
                 rgb: headCol, sat: sat)
        // Small round head at neck tip
        let headZ = neckZ + neckD*0.82 + hD*0.44 + headPoke
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -shH*0.08 + headPoke*0.5, headZ), SIMD3(hW, hH, hD)),
                 rgb: headCol, sat: sat)
        // Blunt snout
        let snoutZ = headZ + hD*0.48 + snD*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -shH*0.08 + headPoke*0.5 - hH*0.06, snoutZ),
                           SIMD3(snW, snH, snD)),
                 rgb: headCol * 0.88, sat: sat)

        // Eyes — small, alert
        let faceZ   = headZ + hD*0.46
        let tEyeW = s*0.08; let tEyeH = s*0.09 * eyeBlinkSY; let tEyeD = s*0.04
        let tEyeY   = -shH*0.08 + headPoke*0.5 + hH*0.14
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hW*0.28, tEyeY, faceZ), r: SIMD3(tEyeW, tEyeH, tEyeD),
                sat: sat, scleraCol: SIMD3(0.88, 0.85, 0.68), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hW*0.28, tEyeY, faceZ), r: SIMD3(tEyeW, tEyeH, tEyeD),
                sat: sat, scleraCol: SIMD3(0.88, 0.85, 0.68), pupilCol: eyeCol)

        // 4 stubby legs peeking below shell rim
        let hipY: Float = -shH*0.50
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-shW*0.38, hipY,  shD*0.32),  legSwing), rgb: headCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( shW*0.38, hipY,  shD*0.32), -legSwing), rgb: headCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3(-shW*0.38, hipY, -shD*0.30), -legSwing), rgb: headCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: lw(SIMD3( shW*0.38, hipY, -shD*0.30),  legSwing), rgb: headCol, sat: sat)

        // Short stubby tail at rear
        do {
            let tailPivot = SIMD3<Float>(0, -shH*0.30, -shD*0.46)
            let tailModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailWag)
                * EntityRenderer.trans(SIMD3(0, 0, -tailD*0.5))
                * EntityRenderer.scaleM(SIMD3(tailW, tailH, tailD))
            drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: headCol * 0.80, sat: sat)
        }
    }

    // =========================================================================
    // KIND 10 — DEER / FAWN
    //
    // Silhouette: slender body on LONG graceful legs, small head with branched
    // antlers (two-segment Y shape), white spot row across back, white belly,
    // short fluffy tail. Gentle alert posture, delicate walk.
    //
    // PALETTE:
    //   backCol    = warm tan/fawn from entity color
    //   bellyCol   = pure/near-white underside
    //   spotCol    = white spots along back (row of small blocks)
    //   legCol     = dark brown lower legs (below knee)
    //   antlerCol  = dark warm brown antlers
    //
    // Parts: body(1) belly(1) spots(5) head(1) snout(1) eyes(2) ears(2)
    //        antler-base(2) antler-branch(2) legs-upper(4) legs-lower(4)
    //        tail(1) = 25 parts
    // =========================================================================
    private func drawKind10(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: deer/fawn ----
        // Warm tan/reddish-brown back
        let backCol   = SIMD3<Float>(min(1, base.x*0.72+0.22), min(1, base.y*0.46+0.12), min(1, base.z*0.18+0.03))
        // Near-white belly
        let bellyCol  = SIMD3<Float>(min(1, backCol.x*0.28+0.70), min(1, backCol.y*0.26+0.70), min(1, backCol.z*0.22+0.68))
        // White spots
        let spotCol   = SIMD3<Float>(0.96, 0.95, 0.90)
        // Dark brown lower legs
        let legDarkCol = SIMD3<Float>(min(1, base.x*0.24+0.10), min(1, base.y*0.18+0.06), min(1, base.z*0.10+0.02))
        // Upper legs: match back color
        let legLightCol = backCol * 0.88
        // Dark antlers
        let antlerCol = SIMD3<Float>(min(1, base.x*0.30+0.14), min(1, base.y*0.20+0.08), min(1, base.z*0.08+0.02))
        let eyeCol    = SIMD3<Float>(0.04, 0.03, 0.02)   // warm dark doe eyes

        let blinkPhase  = phase + hash * 4.5
        let breathPhase = phase * 0.36 + hash * 1.8
        let earPhase    = phase + hash * 5.5
        let tailPhase   = phase + hash * 2.0

        let walkSpeed: Float = 2.2
        let legSwing  = sin(phase * walkSpeed) * 0.34
        let breatheY  = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)
        let earTwitchL = earTwitchAngle(earPhase, side: -1) * 0.80
        let earTwitchR = earTwitchAngle(earPhase, side:  1) * 0.80
        let tailWag   = tailWagAngle(tailPhase) * 0.55

        // ---- PROPORTIONS ---- (slender and graceful)
        let bW = s*0.46;  let bH = s*0.46;  let bD = s*0.72   // slender body
        let hW = s*0.30;  let hH = s*0.28;  let hD = s*0.34   // small gentle head
        let earW = s*0.10; let earH = s*0.22; let earD = s*0.07  // alert pointy ears
        let snW = s*0.18; let snH = s*0.16; let snD = s*0.22
        // Long graceful legs: upper + lower (knee break for elegance)
        let ulW = s*0.12; let ulH = s*0.40; let ulD = s*0.12  // upper leg
        let llW = s*0.09; let llH = s*0.50; let llD = s*0.09  // lower leg (thinner, longer)
        let legTotalH = ulH + llH
        // Antler: base shaft up + branch forking out
        let antShaftW = s*0.06; let antShaftH = s*0.22; let antShaftD = s*0.06
        let antBranchW = s*0.05; let antBranchH = s*0.14; let antBranchD = s*0.05
        // White spot blocks along spine
        let spotW = s*0.14; let spotH = s*0.06; let spotD = s*0.12
        let tailW = s*0.10; let tailH = s*0.12; let tailD = s*0.08

        let groundY = pos.y
        let bodyY   = groundY + legTotalH + bH*0.5 + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        // Upper leg
        func ulw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -ulH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(ulW, ulH, ulD))
        }
        // Lower leg (hangs from hip with same swing; thinner)
        func llw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -ulH - llH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(llW, llH, llD))
        }

        let hipY = -bH*0.5
        let hipFL = SIMD3<Float>(-bW*0.32, hipY,  bD*0.30)
        let hipFR = SIMD3<Float>( bW*0.32, hipY,  bD*0.30)
        let hipBL = SIMD3<Float>(-bW*0.32, hipY, -bD*0.30)
        let hipBR = SIMD3<Float>( bW*0.32, hipY, -bD*0.30)

        // 4 long graceful legs (upper light / lower dark)
        drawCube(enc: enc, viewProj: viewProj, model: ulw(hipFL,  legSwing), rgb: legLightCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: ulw(hipFR, -legSwing), rgb: legLightCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: ulw(hipBL, -legSwing), rgb: legLightCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: ulw(hipBR,  legSwing), rgb: legLightCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llw(hipFL,  legSwing), rgb: legDarkCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llw(hipFR, -legSwing), rgb: legDarkCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llw(hipBL, -legSwing), rgb: legDarkCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llw(hipBR,  legSwing), rgb: legDarkCol,  sat: sat)

        // Body — slender warm tan
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: backCol, sat: sat)
        // White belly underside
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH*0.26, bD*0.04), SIMD3(bW*0.76, bH*0.44, bD*0.76)),
                 rgb: bellyCol, sat: sat)
        // White spots along back — 5 small dabs in a row
        let spotZs: [Float] = [bD*0.32, bD*0.14, -bD*0.04, -bD*0.22, -bD*0.38]
        for sz in spotZs {
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(0, bH*0.48, sz), SIMD3(spotW, spotH, spotD)),
                     rgb: spotCol, sat: sat)
        }

        // Short fluffy tail — white, wags
        do {
            let tailPivot = SIMD3<Float>(0, bH*0.32, -bD*0.48)
            let tailModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailWag)
                * EntityRenderer.trans(SIMD3(0, tailH*0.3, -tailD*0.5))
                * EntityRenderer.scaleM(SIMD3(tailW, tailH, tailD))
            drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: spotCol, sat: sat)
        }

        // Head — small and gentle
        let headY: Float = bH*0.44 + hH*0.48
        let headZ: Float = bD*0.30
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: backCol, sat: sat)
        // Gentle snout — slightly paler
        let snoutZ = headZ + hD*0.48 + snD*0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hH*0.08, snoutZ), SIMD3(snW, snH, snD)),
                 rgb: SIMD3<Float>(min(1, backCol.x+0.08), min(1, backCol.y+0.06), min(1, backCol.z+0.04)),
                 sat: sat)
        // Dark nose
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hH*0.08 + snH*0.10, snoutZ + snD*0.50), SIMD3(s*0.07, s*0.06, s*0.03)),
                 rgb: legDarkCol, sat: sat)

        // Big doe eyes — warm brown, gentle
        let faceZ   = headZ + hD*0.46
        let doeEyeW = s*0.10; let doeEyeH = s*0.12 * eyeBlinkSY; let doeEyeD = s*0.05
        let doeEyeY = headY + hH*0.12
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hW*0.30, doeEyeY, faceZ), r: SIMD3(doeEyeW, doeEyeH, doeEyeD),
                sat: sat, scleraCol: SIMD3(0.88, 0.80, 0.60), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hW*0.30, doeEyeY, faceZ), r: SIMD3(doeEyeW, doeEyeH, doeEyeD),
                sat: sat, scleraCol: SIMD3(0.88, 0.80, 0.60), pupilCol: eyeCol)

        // Alert perky ears — lean outward, twitch
        let earBaseY = headY + hH*0.42
        let earLeanL = EntityRenderer.rotZ( 0.26)
        let earLeanR = EntityRenderer.rotZ(-0.26)
        do {
            let pivotL = SIMD3<Float>(-hW*0.30, earBaseY, headZ - hD*0.12)
            let pivotR = SIMD3<Float>( hW*0.30, earBaseY, headZ - hD*0.12)
            let earLM = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotL)
                * earLeanL * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, earH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            let earRM = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotR)
                * earLeanR * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, earH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            drawCube(enc: enc, viewProj: viewProj, model: earLM, rgb: backCol,  sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: earRM, rgb: backCol,  sat: sat)
            // Inner ear pale
            let ieL = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotL)
                * earLeanL * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, earH*0.50 + earH*0.04, s*0.01 + earD*0.5))
                * EntityRenderer.scaleM(SIMD3(earW*0.65, earH*0.75, s*0.02))
            let ieR = EntityRenderer.trans(wc) * R * EntityRenderer.trans(pivotR)
                * earLeanR * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, earH*0.50 + earH*0.04, s*0.01 + earD*0.5))
                * EntityRenderer.scaleM(SIMD3(earW*0.65, earH*0.75, s*0.02))
            drawCube(enc: enc, viewProj: viewProj, model: ieL, rgb: bellyCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: ieR, rgb: bellyCol, sat: sat)
        }

        // Small antlers — 2-segment Y branch each side
        let antBaseY = headY + hH*0.50 + antShaftH*0.5
        let antZOff  = headZ - hD*0.14
        do {
            // Left antler shaft (straight up)
            let antLShaft = pw(SIMD3(-hW*0.22, antBaseY, antZOff), SIMD3(antShaftW, antShaftH, antShaftD))
            drawCube(enc: enc, viewProj: viewProj, model: antLShaft, rgb: antlerCol, sat: sat)
            // Left forward branch (tilts forward-up from top of shaft)
            let antLBranch = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3(-hW*0.22, antBaseY + antShaftH*0.48, antZOff))
                * EntityRenderer.rotX(-0.52) * EntityRenderer.rotZ(-0.20)
                * EntityRenderer.trans(SIMD3(0, antBranchH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(antBranchW, antBranchH, antBranchD))
            drawCube(enc: enc, viewProj: viewProj, model: antLBranch, rgb: antlerCol, sat: sat)
            // Right antler shaft
            let antRShaft = pw(SIMD3( hW*0.22, antBaseY, antZOff), SIMD3(antShaftW, antShaftH, antShaftD))
            drawCube(enc: enc, viewProj: viewProj, model: antRShaft, rgb: antlerCol, sat: sat)
            // Right forward branch (mirror)
            let antRBranch = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3( hW*0.22, antBaseY + antShaftH*0.48, antZOff))
                * EntityRenderer.rotX(-0.52) * EntityRenderer.rotZ( 0.20)
                * EntityRenderer.trans(SIMD3(0, antBranchH*0.5, 0))
                * EntityRenderer.scaleM(SIMD3(antBranchW, antBranchH, antBranchD))
            drawCube(enc: enc, viewProj: viewProj, model: antRBranch, rgb: antlerCol, sat: sat)
        }
    }

    // =========================================================================
    // KIND 11 — HUMANOID MONSTER (goblin / shadow-person)
    //
    // Silhouette: erect two-legged figure. From any angle: a squarish HEAD on top
    // of a taller TORSO, two ARMS hanging low on the sides (with visible hands),
    // two LEGS beneath. At a glance reads instantly as "a person" — which is what
    // makes it uncanny/creepy for kids.
    //
    // Anatomy (bottom-up, in local Y):
    //   groundY → legH → hipY → torsoH → shoulderY → neckH → headY
    //
    // Walk: two legs alternate phases. Arms swing OPPOSITE phase to legs (when
    //       left leg swings forward, left arm swings back, like a real person).
    // Sway: slow side-to-side whole-body tilt (predator stalking motion).
    // Blink: erratic flicker like kind-5 (night creature cadence).
    // Breathe: subtle Y-bob on the whole body.
    // Eyes: HDR yellow-green (0.8, 3.0, 0.1) — distinct from beast's red.
    // Face: scowl brow (dark bars angled inward-down), jagged grin (dark slash
    //       with irregular white teeth notches).
    //
    // PALETTE (from entity base tint, forced dark but COLORED):
    //   bodyCol      = dark bruise-blue (upper legs, upper arms, head back, torso sides)
    //   torsoCol     = lighter dark-teal (chest plate, brow bars)
    //   faceShadeCol = mid blue-grey (lower legs, forearms, neck, face overlay slab)
    //   accentCol    = sickly vivid green (hands, feet, face-trim bars) — night-readable
    //   rimCol11     = faint emissive teal on torso flanks for night silhouette
    //   mouthCol     = dark cavity red
    //   eyeGlow      = (0.8, 3.0, 0.1) HDR yellow-green → bloom
    //
    // Parts: legs-upper(2) legs-lower(2) feet(2) arms-upper(2) arms-lower(2)
    //        hands(2) torso(1) torso-rim(2) torso-plate(1) neck(1) head(1)
    //        face-overlay(1) face-trim(2) brow(2) eye-glow(2) mouth(1) teeth(3) = 27 parts
    // =========================================================================
    private func drawKind11(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale * 1.05   // slightly taller than an animal, but not boss-sized
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)

        // PALETTE: humanoid lurker (kind 11) — dark teal/bruise-blue body, clearly
        // distinct from kind-5's maroon-purple. Multi-tone so adjacent parts read as
        // separate in low light. Entity tint provides per-instance variation.
        let tint     = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
        let tvar11   = (hash + 1.0) * 0.5   // 0..1 per-creature range
        // bodyCol: dark bruise-blue (limbs, head back, upper body) — clearly blue-teal
        let bodyCol  = tint * 0.14 + SIMD3<Float>(
            0.06 + tvar11 * 0.03,
            0.14 + tvar11 * 0.05,
            0.28 + tvar11 * 0.06)
        // torsoCol: noticeably lighter dark-teal chest plate — reads as separate layer
        let torsoCol = tint * 0.18 + SIMD3<Float>(
            0.10 + tvar11 * 0.04,
            0.26 + tvar11 * 0.06,
            0.40 + tvar11 * 0.04)
        // accentCol: vivid sickly green on hands, feet, face patch — the lurker's signature
        // darker/more muted than the eye glow, but clearly a different hue from the body
        let accentCol = tint * 0.12 + SIMD3<Float>(0.12, 0.44, 0.18)
        // Mouth: deep dark red cavity
        let mouthCol  = SIMD3<Float>(0.42, 0.02, 0.04)
        // Neck/lower face: slightly lighter warm-grey so head depth reads on the neck
        let faceShadeCol = tint * 0.16 + SIMD3<Float>(0.12, 0.22, 0.30)
        // HDR yellow-green glowing eyes — luminance >> 1, blooms into eerie glow.
        // Distinct from beast's (3.5, 0.05, 0.05) red: this is a sickly yellow-green.
        let eyeGlowCol = SIMD3<Float>(0.8, 3.0, 0.1)

        // ---- ANIMATION PHASES ----
        let blinkPhase  = phase * 1.8 + hash * 5.4    // erratic like beast blink
        let breathPhase = phase * 0.42 + hash * 1.9
        let walkSpeed: Float = 2.2                     // deliberate loping stride

        // Leg swing: legs alternate, left leads right by π
        let legSwingL  =  sin(phase * walkSpeed) * 0.38
        let legSwingR  = -sin(phase * walkSpeed) * 0.38   // opposite leg
        // Arm swing OPPOSITE to same-side leg:
        //   left arm swings back when left leg swings forward → negate legSwingL
        let armSwingL  = -legSwingL * 0.55    // arms swing less than legs
        let armSwingR  = -legSwingR * 0.55

        // Whole-body sway (predator stalk): slow sine on rotZ of the whole rig
        let swayAngle  = sin(phase * 0.70 + hash * 1.2) * 0.06
        let bodySway   = EntityRenderer.rotZ(swayAngle)

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS (upright humanoid) ----
        // Legs: two segments (upper + lower), narrow, humanoid length
        let ulW = s * 0.17;  let ulH = s * 0.38;  let ulD = s * 0.17   // upper leg
        let llW = s * 0.14;  let llH = s * 0.34;  let llD = s * 0.14   // lower leg
        let footW = s * 0.22; let footH = s * 0.08; let footD = s * 0.26 // flat foot
        let legTotalH = ulH + llH + footH

        // Torso: upright block, taller than wide
        let tW = s * 0.52;  let tH = s * 0.54;  let tD = s * 0.34
        // Torso plate (chest): thinner slab on front of torso
        let tpW = tW * 0.78; let tpH = tH * 0.60; let tpD = s * 0.05

        // Neck: short connector
        let nkW = s * 0.18; let nkH = s * 0.10; let nkD = s * 0.18

        // Head: squarish but taller than wide for that creepy elongated look
        let hW = s * 0.46;  let hH = s * 0.50;  let hD = s * 0.40

        // Arms: two segments (upper arm + forearm) — hang from shoulders
        let uaW = s * 0.14;  let uaH = s * 0.36;  let uaD = s * 0.14   // upper arm
        let faW = s * 0.12;  let faH = s * 0.30;  let faD = s * 0.12   // forearm
        let handW = s * 0.20; let handH = s * 0.10; let handD = s * 0.22 // blocky hands

        // ---- WORLD CENTRE (at body mid) ----
        let groundY = pos.y
        let bodyY   = groundY + legTotalH + tH * 0.5 + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)

        // Fold hit-squash + yaw into R; then bodySway is applied per-part via pw.
        let R = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        // Part-world closure: trans(wc) * R * bodySway * trans(local) * scale
        // bodySway rotates the whole creature in local space, so the humanoid
        // rocks side-to-side as a unit (head, torso, arms, all together).
        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodySway * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // ---- LEGS (in world space so feet plant correctly despite body sway) ----
        // Hip positions in body-local space (below torso centre, which is at 0,0,0)
        let hipY = -tH * 0.5   // bottom of torso

        // Upper leg: pivots at hip
        func ulwH(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodySway * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -ulH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(ulW, ulH, ulD))
        }
        // Lower leg: hangs from bottom of upper leg
        func llwH(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodySway * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -ulH - llH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(llW, llH, llD))
        }
        // Foot: flat block at bottom of lower leg
        func footW_(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodySway * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -ulH - llH - footH * 0.5, footD * 0.12))
                * EntityRenderer.scaleM(SIMD3(footW, footH, footD))
        }

        let hipL = SIMD3<Float>(-tW * 0.22, hipY, 0)
        let hipR = SIMD3<Float>( tW * 0.22, hipY, 0)

        // Draw legs: upper in bodyCol (dark teal), lower in slightly lighter faceShadeCol,
        // feet in accentCol (vivid sickly green) for strong ankle contrast.
        drawCube(enc: enc, viewProj: viewProj, model: ulwH(hipL, legSwingL), rgb: bodyCol,      sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: ulwH(hipR, legSwingR), rgb: bodyCol,      sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llwH(hipL, legSwingL), rgb: faceShadeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: llwH(hipR, legSwingR), rgb: faceShadeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: footW_(hipL, legSwingL), rgb: accentCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: footW_(hipR, legSwingR), rgb: accentCol,  sat: sat)

        // ---- TORSO ----
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(tW, tH, tD)), rgb: bodyCol, sat: sat)
        // Chest plate — noticeably lighter teal slab on front; reads as armored layer.
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, tH * 0.06, tD * 0.50), SIMD3(tpW, tpH, tpD)),
                 rgb: torsoCol, sat: sat)
        // Faint emissive rim on torso sides — dim teal sheen so the silhouette is
        // visible at night without a light source (sat = -1.0 bypasses shading).
        let rimCol11 = bodyCol + SIMD3<Float>(0.04, 0.20, 0.30)   // adds dim teal rim glow
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-tW * 0.50, 0, 0), SIMD3(s * 0.025, tH * 0.90, tD * 0.80)),
                 rgb: rimCol11, sat: -1.0)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( tW * 0.50, 0, 0), SIMD3(s * 0.025, tH * 0.90, tD * 0.80)),
                 rgb: rimCol11, sat: -1.0)

        // ---- ARMS ----
        // Shoulders sit at upper sides of torso
        let shoulderY = tH * 0.42
        let shoulderXL = -(tW * 0.50 + uaW * 0.42)
        let shoulderXR =  (tW * 0.50 + uaW * 0.42)

        // Upper arm: pivots at shoulder, swings on X (forward/back)
        func uaFunc(_ shoulderX: Float, _ swingAng: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodySway
                * EntityRenderer.trans(SIMD3(shoulderX, shoulderY, 0))
                * EntityRenderer.rotX(swingAng)
                * EntityRenderer.trans(SIMD3(0, -uaH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(uaW, uaH, uaD))
        }
        // Forearm: hangs from bottom of upper arm
        func faFunc(_ shoulderX: Float, _ swingAng: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodySway
                * EntityRenderer.trans(SIMD3(shoulderX, shoulderY, 0))
                * EntityRenderer.rotX(swingAng)
                * EntityRenderer.trans(SIMD3(0, -uaH - faH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(faW, faH, faD))
        }
        // Blocky hand: dangles below forearm
        func handFunc(_ shoulderX: Float, _ swingAng: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodySway
                * EntityRenderer.trans(SIMD3(shoulderX, shoulderY, 0))
                * EntityRenderer.rotX(swingAng)
                * EntityRenderer.trans(SIMD3(0, -uaH - faH - handH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(handW, handH, handD))
        }

        // Upper arm: bodyCol (dark teal); forearm: faceShadeCol (a touch lighter); hand: accentCol
        drawCube(enc: enc, viewProj: viewProj, model: uaFunc(shoulderXL, armSwingL), rgb: bodyCol,      sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: uaFunc(shoulderXR, armSwingR), rgb: bodyCol,      sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: faFunc(shoulderXL, armSwingL), rgb: faceShadeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: faFunc(shoulderXR, armSwingR), rgb: faceShadeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: handFunc(shoulderXL, armSwingL), rgb: accentCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: handFunc(shoulderXR, armSwingR), rgb: accentCol,  sat: sat)

        // ---- NECK + HEAD ----
        // Neck uses faceShadeCol (lighter) so it reads against the darker torso.
        let neckY = tH * 0.50 + nkH * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, neckY, 0), SIMD3(nkW, nkH, nkD)), rgb: faceShadeCol, sat: sat)

        let headY: Float = tH * 0.50 + nkH + hH * 0.50
        // Head local Z: face is on the +Z side (forward) so eyes/mouth always
        // face the creature's heading direction.
        let headZ: Float = 0
        // Head back uses bodyCol; face front uses faceShadeCol so the face reads as a
        // lighter plane (the "mask look"). We draw the head body then overlay the face.
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hW, hH, hD)),
                 rgb: bodyCol, sat: sat)

        // ---- FACE (all parts placed on the +Z front face of the head) ----
        // hFaceZ is the local Z of the front face of the head block.
        // headZ is 0 (head centre is 0 local-Z), so hFaceZ = hD*0.5 + thin offset.
        let hFaceZ: Float = headZ + hD * 0.50 + s * 0.01   // front face of head

        // Face overlay: faceShadeCol slab — lighter blue-grey "mask" that makes the
        // front of the head clearly lighter than the dark sides (self-edge).
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY + hH * 0.06, hFaceZ - s*0.01),
                           SIMD3(hW * 0.80, hH * 0.62, s * 0.04)),
                 rgb: faceShadeCol, sat: sat)
        // Accent trim: a thin sickly-green frame around the face patch (above/below eyes)
        // makes the face look like a glowing-framed mask at night.
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY + hH * 0.42, hFaceZ - s*0.01),
                           SIMD3(hW * 0.76, s * 0.04, s * 0.03)),
                 rgb: accentCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hH * 0.28, hFaceZ - s*0.01),
                           SIMD3(hW * 0.76, s * 0.04, s * 0.03)),
                 rgb: accentCol, sat: sat)

        // GLOWING HDR YELLOW-GREEN EYES — emissive, no shading multiply (sat: -1.0)
        // Wide-set, large, angled inward-down slightly so they read as a menacing
        // look without being friendly. The sickly yellow-green is the monster's
        // signature — distinct from the beast's red and the boss's amber.
        let eyeW = s * 0.12; let eyeH = s * 0.12 * eyeBlinkSY; let eyeD = s * 0.04
        let eyeY = headY + hH * 0.14
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hW * 0.24, eyeY, hFaceZ), SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeGlowCol, sat: -1.0)   // emissive → bloom
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hW * 0.24, eyeY, hFaceZ), SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeGlowCol, sat: -1.0)   // emissive → bloom

        // ANGRY BROWS — two dark bars angled inward-down (inner end lower, outer higher)
        // The classic angry-V scowl, in heavy goblin style.
        let browCol = torsoCol   // slightly lighter than body so they read as separate
        let browLM = EntityRenderer.trans(wc) * R * bodySway
            * EntityRenderer.trans(SIMD3(-hW * 0.24, eyeY + s * 0.16, hFaceZ))
            * EntityRenderer.rotZ(-0.42)
            * EntityRenderer.scaleM(SIMD3(s * 0.22, s * 0.06, s * 0.05))
        let browRM = EntityRenderer.trans(wc) * R * bodySway
            * EntityRenderer.trans(SIMD3( hW * 0.24, eyeY + s * 0.16, hFaceZ))
            * EntityRenderer.rotZ( 0.42)
            * EntityRenderer.scaleM(SIMD3(s * 0.22, s * 0.06, s * 0.05))
        drawCube(enc: enc, viewProj: viewProj, model: browLM, rgb: browCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: browRM, rgb: browCol, sat: sat)

        // WIDE JAGGED GRIN — a wide horizontal dark slash below the eyes.
        // The grin goes all the way to the cheeks (wider than the eye spacing)
        // which makes it look unsettling yet cartoonish.
        let grinY  = headY - hH * 0.18
        let grinW  = hW * 0.78
        let grinH  = s * 0.08
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, grinY, hFaceZ), SIMD3(grinW, grinH, s * 0.04)),
                 rgb: mouthCol, sat: sat)
        // Irregular jagged teeth — 4 teeth, alternating up/down, uneven widths
        // (some missing) for a gap-toothed goblin grin.
        let toothCol = SIMD3<Float>(0.92, 0.88, 0.78)   // slightly yellowed ivory
        // Tooth positions in X as fractions of grin half-width; gaps at ±0.5 (missing)
        let teethData: [(Float, Float, Bool)] = [
            (-0.34, s * 0.07, true),   // left big tooth, downward
            (-0.12, s * 0.055, false), // small tooth, upward
            ( 0.14, s * 0.07, true),   // right big tooth, downward
            ( 0.40, s * 0.045, false), // small outer tooth, upward
        ]
        for (tx, th, down) in teethData {
            let ty = grinY + (down ? grinH * 0.20 : -grinH * 0.20)
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(grinW * tx, ty, hFaceZ + s * 0.01), SIMD3(s * 0.04, th, s * 0.03)),
                     rgb: toothCol, sat: sat)
        }
    }

    // =========================================================================
    // KIND 12 — BEAR (big chunky quadruped)
    //
    // Silhouette: bulky. A wide, deep, rounded barrel body sitting low on four
    // short stubby legs. Broad round head pushed forward with a short blunt
    // snout and two small round ears on top. Reads as heavy and cuddly.
    // Slow lumbering plod; body sways gently; ears twitch; blinks.
    //
    // Parts: body(1) belly(1) rump(1) head(1) snout(1) nose(1) ears(2)
    //        eyes(2) legs(4) paws(4) = 18
    // =========================================================================
    private func drawKind12(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale * 1.15   // bear is chunky/bigger than a normal animal
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: bear ----
        let baseCol  = base
        let bellyCol = SIMD3<Float>(min(1, base.x*0.74+0.20),
                                    min(1, base.y*0.72+0.18),
                                    min(1, base.z*0.70+0.16))
        let darkCol  = base * 0.60                       // legs, paws, ear backs
        let snoutCol = SIMD3<Float>(min(1, base.x*0.66+0.22),
                                    min(1, base.y*0.62+0.18),
                                    min(1, base.z*0.58+0.14))
        let noseCol  = SIMD3<Float>(0.08, 0.06, 0.07)
        let eyeCol   = SIMD3<Float>(0.05, 0.04, 0.05)

        let blinkPhase  = phase + hash * 4.3
        let breathPhase = phase * 0.38 + hash * 2.0
        let earPhase    = phase + hash * 6.1

        let plodSpeed: Float = 1.5
        let legSwing  = sin(phase * plodSpeed) * 0.20
        let bodyBob   = abs(sin(phase * plodSpeed)) * s * 0.012
        let bodySway  = sin(phase * plodSpeed * 0.5) * 0.05   // gentle Z roll

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)
        let earTwitchL = earTwitchAngle(earPhase, side: -1)
        let earTwitchR = earTwitchAngle(earPhase, side:  1)

        // ---- PROPORTIONS (bulky) ----
        let bW = s * 0.92;  let bH = s * 0.74;  let bD = s * 1.16   // deep barrel
        let hS = s * 0.66                                            // big round head
        let snW = s * 0.38; let snH = s * 0.28; let snD = s * 0.26   // short blunt snout
        let earW = s * 0.20; let earH = s * 0.20; let earD = s * 0.12 // small round ears
        let legW = s * 0.28; let legH = s * 0.30; let legD = s * 0.30 // short stubby legs
        let pawW = s * 0.30; let pawH = s * 0.10; let pawD = s * 0.34

        let groundY = pos.y
        let bodyY   = groundY + legH + pawH + bH * 0.5 + bodyBob + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)
        let roll    = EntityRenderer.rotZ(bodySway)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * roll * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        func lw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * roll * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }
        func paw(_ hip: SIMD3<Float>, _ ang: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * roll * EntityRenderer.trans(hip)
                * EntityRenderer.rotX(ang)
                * EntityRenderer.trans(SIMD3(0, -legH - pawH * 0.5, pawD * 0.10))
                * EntityRenderer.scaleM(SIMD3(pawW, pawH, pawD))
        }

        // Body — big deep barrel
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Rounded rump bump at the rear (adds chunky read)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH * 0.16, -bD * 0.42), SIMD3(bW * 0.92, bH * 0.78, bD * 0.30)),
                 rgb: baseCol, sat: sat)
        // Pale belly underside
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.26, bD * 0.04), SIMD3(bW * 0.82, bH * 0.46, bD * 0.80)),
                 rgb: bellyCol, sat: sat)

        // Head — broad and round, pushed forward and slightly down
        let headY: Float = bH * 0.30
        let headZ: Float = bD * 0.50 + hS * 0.42
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS * 0.92, hS * 0.86)),
                 rgb: baseCol, sat: sat)
        // Short blunt snout
        let snoutY = headY - hS * 0.16
        let snoutZ = headZ + hS * 0.42 + snD * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, snoutY, snoutZ), SIMD3(snW, snH, snD)),
                 rgb: snoutCol, sat: sat)
        // Nose — dark block on the snout tip
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, snoutY + snH * 0.10, snoutZ + snD * 0.50), SIMD3(s * 0.14, s * 0.10, s * 0.06)),
                 rgb: noseCol, sat: sat)

        // FACE — small friendly dark eyes high on the head
        let faceZ = headZ + hS * 0.44
        let eyeW = s * 0.10; let eyeH = s * 0.11 * eyeBlinkSY; let eyeD = s * 0.05
        let eyeY = headY + hS * 0.14
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hS * 0.26, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: eyeCol, pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hS * 0.26, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: eyeCol, pupilCol: eyeCol)

        // Small round ears on top of head, each twitches
        let earBaseY = headY + hS * 0.48
        do {
            let earLModel = EntityRenderer.trans(wc) * R * roll
                * EntityRenderer.trans(SIMD3(-hS * 0.30, earBaseY, headZ - hS * 0.04))
                * EntityRenderer.rotX(earTwitchL)
                * EntityRenderer.trans(SIMD3(0, earH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            let earRModel = EntityRenderer.trans(wc) * R * roll
                * EntityRenderer.trans(SIMD3( hS * 0.30, earBaseY, headZ - hS * 0.04))
                * EntityRenderer.rotX(earTwitchR)
                * EntityRenderer.trans(SIMD3(0, earH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(earW, earH, earD))
            drawCube(enc: enc, viewProj: viewProj, model: earLModel, rgb: darkCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: earRModel, rgb: darkCol, sat: sat)
        }

        // 4 short stubby legs + paws
        let hipY = -bH * 0.5
        let hipFL = SIMD3<Float>(-bW * 0.34, hipY,  bD * 0.34)
        let hipFR = SIMD3<Float>( bW * 0.34, hipY,  bD * 0.34)
        let hipBL = SIMD3<Float>(-bW * 0.34, hipY, -bD * 0.34)
        let hipBR = SIMD3<Float>( bW * 0.34, hipY, -bD * 0.34)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFL,  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipFR, -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBL, -legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: lw(hipBR,  legSwing), rgb: darkCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: paw(hipFL,  legSwing), rgb: noseCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: paw(hipFR, -legSwing), rgb: noseCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: paw(hipBL, -legSwing), rgb: noseCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: paw(hipBR,  legSwing), rgb: noseCol, sat: sat)
    }

    // =========================================================================
    // KIND 13 — PENGUIN (small upright biped)
    //
    // Silhouette: rounded upright teardrop. Dark back/head, big white belly oval
    // on the front, two little flippers on the sides, orange beak and two orange
    // feet poking out the bottom. Waddles side to side; flippers flap a little.
    //
    // Parts: body(1) belly(1) head(1) beak(1) eyes(2) flippers(2) feet(2) = 10
    // =========================================================================
    private func drawKind13(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale * 0.92   // penguins are little
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: penguin ----
        // backCol: dark (entity color darkened toward classic tuxedo back)
        let backCol  = base * 0.42
        let bellyCol = SIMD3<Float>(0.96, 0.96, 0.97)   // white belly
        let orange   = SIMD3<Float>(0.95, 0.55, 0.12)   // beak + feet
        let eyeCol   = SIMD3<Float>(0.04, 0.04, 0.05)

        let blinkPhase  = phase + hash * 4.0
        let breathPhase = phase * 0.40 + hash * 1.6

        let waddleSpeed: Float = 3.4
        let waddle  = sin(phase * waddleSpeed) * 0.14    // whole-body Z rock
        let bob     = abs(sin(phase * waddleSpeed)) * s * 0.018
        let flap    = sin(phase * waddleSpeed * 1.2) * 0.32  // flipper flap

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS (upright teardrop) ----
        let bW = s * 0.50;  let bH = s * 0.72;  let bD = s * 0.42   // tall round body
        let hS = s * 0.40                                            // round head
        let flW = s * 0.10; let flH = s * 0.46; let flD = s * 0.20   // flippers
        let ftW = s * 0.18; let ftH = s * 0.08; let ftD = s * 0.26   // feet
        let legH: Float = s * 0.04                                   // body sits just above feet

        let groundY = pos.y
        let bodyY   = groundY + ftH + legH + bH * 0.5 + bob + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)
        let rock    = EntityRenderer.rotZ(waddle)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * rock * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }
        // Foot: parked at ground; rocks with the body so it reads as a waddle
        func footM(_ lo: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(SIMD3(lo.x, -bH * 0.5 - legH - ftH * 0.5, lo.z))
                * EntityRenderer.scaleM(SIMD3(ftW, ftH, ftD))
        }

        // Body — dark rounded back
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: backCol, sat: sat)
        // White belly oval on the front
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.06, bD * 0.40), SIMD3(bW * 0.70, bH * 0.78, bD * 0.30)),
                 rgb: bellyCol, sat: sat)

        // Head — round, dark, sits on top
        let headY = bH * 0.50 + hS * 0.40
        let headZ = bD * 0.04
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hS, hS * 0.92, hS * 0.88)),
                 rgb: backCol, sat: sat)
        // Beak — small orange wedge at front of head
        let faceZ = headZ + hS * 0.44
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hS * 0.10, faceZ + s * 0.04), SIMD3(s * 0.12, s * 0.09, s * 0.14)),
                 rgb: orange, sat: sat)
        // Eyes — small dark dots
        let eyeW = s * 0.08; let eyeH = s * 0.09 * eyeBlinkSY; let eyeD = s * 0.04
        let eyeY = headY + hS * 0.10
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hS * 0.26, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: eyeCol, pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hS * 0.26, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: eyeCol, pupilCol: eyeCol)

        // Flippers — thin dark paddles on the sides, flap from the shoulder
        do {
            let shY = bH * 0.22
            let flapL = EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(SIMD3(-bW * 0.50, shY, 0))
                * EntityRenderer.rotX(flap)
                * EntityRenderer.trans(SIMD3(0, -flH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(flW, flH, flD))
            let flapR = EntityRenderer.trans(wc) * R * rock
                * EntityRenderer.trans(SIMD3( bW * 0.50, shY, 0))
                * EntityRenderer.rotX(-flap)
                * EntityRenderer.trans(SIMD3(0, -flH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(flW, flH, flD))
            drawCube(enc: enc, viewProj: viewProj, model: flapL, rgb: backCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: flapR, rgb: backCol, sat: sat)
        }

        // Feet — two orange blocks poking out the bottom
        drawCube(enc: enc, viewProj: viewProj, model: footM(SIMD3(-bW * 0.24, 0, bD * 0.18)), rgb: orange, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: footM(SIMD3( bW * 0.24, 0, bD * 0.18)), rgb: orange, sat: sat)
    }

    // =========================================================================
    // KIND 14 — FROG (low wide squat amphibian)
    //
    // Silhouette: wide squat blob close to the ground. Two big bulging eyes on
    // TOP of the head. Long folded back legs splayed to the rear, small front
    // legs propping up the front. A wide grin slit. Animation: a little hop —
    // crouch then spring up and forward — plus a throat-pouch puff.
    //
    // Parts: body(1) belly(1) eyes(2 dome+pupil = 4) grin(1) back-legs(2)
    //        front-legs(2) throat(1) = ~12
    // =========================================================================
    private func drawKind14(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale * 0.95
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: frog ----
        // push toward green
        let baseCol  = SIMD3<Float>(min(1, base.x*0.50+0.04),
                                    min(1, base.y*0.72+0.16),
                                    min(1, base.z*0.42+0.04))
        let bellyCol = SIMD3<Float>(min(1, baseCol.x*0.60+0.34),
                                    min(1, baseCol.y*0.64+0.30),
                                    min(1, baseCol.z*0.46+0.22))
        let legCol   = baseCol * 0.80
        let throatCol = SIMD3<Float>(min(1, baseCol.x*0.70+0.22),
                                     min(1, baseCol.y*0.60+0.18),
                                     min(1, baseCol.z*0.50+0.14))
        let eyeWhite = SIMD3<Float>(0.95, 0.92, 0.45)   // yellowish frog eye
        let eyeCol   = SIMD3<Float>(0.03, 0.03, 0.03)

        // Hop cycle: crouch (squash low) then quick rise + forward, then land.
        let hopSpeed: Float = 2.6
        let hopRaw  = sin(phase * hopSpeed)
        let hopUp   = pow(max(0, hopRaw), 1.6) * s * 0.26     // vertical leap
        // crouch: when not airborne, squash the body flatter
        let crouch  = (hopRaw < 0 ? -hopRaw : Float(0)) * 0.18
        // throat puff: gentle pulse
        let throatPuff = (sin(phase * 1.4 + hash) * 0.5 + 0.5) * 0.5 + 0.6

        let blinkPhase  = phase + hash * 5.0
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS (wide squat) ----
        let bW = s * 0.78;  let bH = s * 0.40;  let bD = s * 0.70
        let eyeS = s * 0.18                                  // big bulging eyes
        let flW = s * 0.12; let flH = s * 0.22; let flD = s * 0.12   // front legs
        // folded back legs: a thigh block angled to the rear-side
        let blW = s * 0.16; let blH = s * 0.14; let blD = s * 0.40

        let groundY = pos.y
        // crouch squashes the standing height; hopUp lifts the whole frog
        let standH  = (bH * 0.5 + flH) * (1.0 - crouch)
        let bodyY   = groundY + standH + hopUp
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)
        // crouch squash applied to the whole body locally (flat & wide when crouched)
        let crouchSquash = EntityRenderer.scaleM(SIMD3<Float>(1 + crouch * 0.5, 1 - crouch, 1 + crouch * 0.3))

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * crouchSquash * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // Body — wide low dome
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Pale belly underside
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.30, bD * 0.10), SIMD3(bW * 0.80, bH * 0.40, bD * 0.74)),
                 rgb: bellyCol, sat: sat)
        // Throat pouch — small puffing bump at the front-bottom
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.22, bD * 0.46), SIMD3(bW * 0.40 * throatPuff, bH * 0.40 * throatPuff, s * 0.14)),
                 rgb: throatCol, sat: sat)

        // BIG bulging eyes on TOP of the head (frog signature)
        let eyeBaseY = bH * 0.46
        let eyeZ     = bD * 0.30
        for sx in [-1.0, 1.0] as [Float] {
            let cx = sx * bW * 0.28
            // eye dome (slightly squashed by blink)
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(cx, eyeBaseY, eyeZ), SIMD3(eyeS, eyeS * eyeBlinkSY, eyeS)),
                     rgb: eyeWhite, sat: sat)
            // pupil — dark dot facing up-forward
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(cx, eyeBaseY + eyeS * 0.20, eyeZ + eyeS * 0.30),
                               SIMD3(eyeS * 0.45, eyeS * 0.45 * eyeBlinkSY, eyeS * 0.4)),
                     rgb: eyeCol, sat: sat)
        }

        // Wide grin slit across the front
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.04, bD * 0.50), SIMD3(bW * 0.74, s * 0.05, s * 0.04)),
                 rgb: SIMD3<Float>(0.10, 0.18, 0.08), sat: sat)

        // Front legs — small props under the front
        for sx in [-1.0, 1.0] as [Float] {
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(sx * bW * 0.34, -bH * 0.5 - flH * 0.5 + 0.0, bD * 0.34), SIMD3(flW, flH, flD)),
                     rgb: legCol, sat: sat)
        }
        // Folded back legs — angled thighs splayed to the rear sides
        for sx in [-1.0, 1.0] as [Float] {
            let blModel = EntityRenderer.trans(wc) * R * crouchSquash
                * EntityRenderer.trans(SIMD3(sx * bW * 0.40, -bH * 0.28, -bD * 0.30))
                * EntityRenderer.rotY(sx * 0.5)
                * EntityRenderer.rotX(-0.35)
                * EntityRenderer.trans(SIMD3(0, 0, -blD * 0.4))
                * EntityRenderer.scaleM(SIMD3(blW, blH, blD))
            drawCube(enc: enc, viewProj: viewProj, model: blModel, rgb: legCol, sat: sat)
        }
    }

    // =========================================================================
    // KIND 15 — SLIME (monster: wobbling translucent-looking blob)
    //
    // Silhouette: a rounded cube/blob that SQUASHES & STRETCHES as it bounces —
    // flat & wide on the "ground" beat, tall & narrow on the "up" beat. Uses the
    // entity color directly so it reads as a colored gel. A lighter inner core
    // gives a translucent gooey feel, a glossy highlight on top, and two simple
    // dark eyes near the front. Hops in place with a gummy bounce.
    //
    // Parts: body(1) inner-core(1) highlight(1) eyes(2) mouth(1) = 6
    // =========================================================================
    private func drawKind15(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: slime (use entity color as the gel) ----
        let gelCol   = base
        // inner core: brighter, lighter version (gooey translucent feel)
        let coreCol  = SIMD3<Float>(min(1, base.x*0.6+0.40),
                                    min(1, base.y*0.6+0.40),
                                    min(1, base.z*0.6+0.40))
        let highCol  = SIMD3<Float>(min(1, base.x*0.4+0.55),
                                    min(1, base.y*0.4+0.55),
                                    min(1, base.z*0.4+0.55))
        let eyeCol   = SIMD3<Float>(0.05, 0.05, 0.06)

        // Bounce: hop up, and squash/stretch out of phase with height.
        let bounceSpeed: Float = 3.0
        let bRaw   = sin(phase * bounceSpeed)
        let hopUp  = pow(max(0, bRaw), 1.4) * s * 0.22
        // squash factor: at the bottom of the bounce (bRaw < 0) it splats wide;
        // mid-rise it stretches tall. Drive from the bounce derivative-ish term.
        let stretch = bRaw                         // +1 rising/up, -1 landing
        let sx = 1.0 - stretch * 0.22              // wide on land, narrow up
        let sy = 1.0 + stretch * 0.30              // tall up, flat on land
        let sz = 1.0 - stretch * 0.22

        let blinkPhase  = phase + hash * 4.6
        let eyeBlinkSY  = blinkScale(blinkPhase)

        // ---- PROPORTIONS ----
        let bS = s * 0.66                           // base blob size

        let groundY = pos.y
        // anchor the blob to the ground: its bottom stays near groundY (squash
        // pivots about the foot), then hopUp lifts it.
        let bodyY   = groundY + bS * 0.5 * sy + hopUp
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)
        // gooey squash/stretch applied to the whole blob, pivoting about its base
        let footLocal = groundY - wc.y
        let wobble = EntityRenderer.trans(SIMD3<Float>(0, footLocal, 0))
            * EntityRenderer.scaleM(SIMD3<Float>(sx, sy, sz))
            * EntityRenderer.trans(SIMD3<Float>(0, -footLocal, 0))

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * wobble * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // Outer gel body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bS, bS, bS)), rgb: gelCol, sat: sat)
        // Inner brighter core (translucent goo read)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bS * 0.10, 0), SIMD3(bS * 0.50, bS * 0.50, bS * 0.50)),
                 rgb: coreCol, sat: sat)
        // Glossy highlight on the upper-front
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bS * 0.18, bS * 0.26, bS * 0.30), SIMD3(bS * 0.20, bS * 0.16, bS * 0.06)),
                 rgb: highCol, sat: sat)

        // Two simple eyes near the front
        let faceZ = bS * 0.50
        let eyeW = s * 0.09; let eyeH = s * 0.11 * eyeBlinkSY; let eyeD = s * 0.04
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-bS * 0.20, bS * 0.06, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: SIMD3<Float>(0.96, 0.96, 0.98), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( bS * 0.20, bS * 0.06, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: SIMD3<Float>(0.96, 0.96, 0.98), pupilCol: eyeCol)
        // Little mouth slit
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bS * 0.12, faceZ), SIMD3(s * 0.14, s * 0.04, s * 0.03)),
                 rgb: SIMD3<Float>(0.12, 0.10, 0.12), sat: sat)
    }

    // =========================================================================
    // KIND 16 — SPIDER (monster: low round body + EIGHT legs)
    //
    // Silhouette: a low round abdomen with a smaller head in front, and EIGHT
    // legs splayed out wide — each leg is a two-segment angled spike (thigh out,
    // shin down). Four legs per side. A few tiny glinting eyes on the head.
    // Creepy-but-cartoonish. Legs scuttle: each side ripples opposite.
    //
    // Parts: abdomen(1) head(1) eyes(4) legs(8 × 2 segs = 16) = 22
    // =========================================================================
    private func drawKind16(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: spider (dark, with entity tint) ----
        let bodyCol  = base * 0.40 + SIMD3<Float>(0.06, 0.04, 0.07)
        let headCol  = base * 0.34 + SIMD3<Float>(0.05, 0.03, 0.06)
        let legCol   = base * 0.30 + SIMD3<Float>(0.04, 0.03, 0.05)
        // small red glinting eyes (slightly HDR so they catch a little glow)
        let eyeCol   = SIMD3<Float>(0.95, 0.10, 0.10)

        let scuttleSpeed: Float = 6.0
        let blinkPhase  = phase + hash * 4.2
        let eyeBlinkSY  = blinkScale(blinkPhase)
        let bodyBob     = abs(sin(phase * scuttleSpeed * 0.5)) * s * 0.02

        // ---- PROPORTIONS (low and wide) ----
        let abW = s * 0.62; let abH = s * 0.42; let abD = s * 0.66   // round abdomen
        let hdW = s * 0.34; let hdH = s * 0.28; let hdD = s * 0.32   // smaller head in front
        let thW = s * 0.09; let thH = s * 0.09; let thD = s * 0.34   // leg thigh (outward)
        let shW = s * 0.07; let shH = s * 0.30; let shD = s * 0.07   // leg shin (down)

        let groundY = pos.y
        let bodyY   = groundY + shH * 0.7 + abH * 0.5 + bodyBob
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // Abdomen — round low body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, -abD * 0.10), SIMD3(abW, abH, abD)), rgb: bodyCol, sat: sat)
        // Head — smaller, in front
        let headZ = abD * 0.50 + hdD * 0.40
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -abH * 0.04, headZ), SIMD3(hdW, hdH, hdD)), rgb: headCol, sat: sat)

        // EIGHT legs — 4 per side, each a thigh (out) + shin (down) two-segment.
        // Z positions stagger from front to back; each leg flexes on a phase so
        // the side ripples (alternating legs lead).
        let legZ: [Float] = [abD * 0.34, abD * 0.10, -abD * 0.12, -abD * 0.34]
        for side in [-1.0, 1.0] as [Float] {
            for i in 0..<4 {
                let lz = legZ[i]
                // per-leg scuttle phase: opposite legs (by index parity and side) lead
                let legPhase = phase * scuttleSpeed + Float(i) * 1.3 + (side > 0 ? 1.57 : 0)
                let flex = sin(legPhase) * 0.22
                // hip on the side of the abdomen
                let hip = SIMD3<Float>(side * abW * 0.46, abH * 0.06, lz)
                let splay = EntityRenderer.rotZ(side * (0.65 + flex))   // thigh angles outward
                // Thigh — points out to the side, fans front/back a bit by index
                let yaw = EntityRenderer.rotY(side * Float(i - 1) * 0.30)
                let thighBase = EntityRenderer.trans(wc) * R
                    * EntityRenderer.trans(hip) * yaw * splay
                let thighModel = thighBase
                    * EntityRenderer.trans(SIMD3(side * thD * 0.5, 0, 0))
                    * EntityRenderer.scaleM(SIMD3(thD, thH, thW))   // long along X (outward)
                drawCube(enc: enc, viewProj: viewProj, model: thighModel, rgb: legCol, sat: sat)
                // Shin — drops down from the end of the thigh
                let shinModel = thighBase
                    * EntityRenderer.trans(SIMD3(side * thD, 0, 0))
                    * EntityRenderer.rotZ(side * -1.1)              // bend downward
                    * EntityRenderer.trans(SIMD3(0, -shH * 0.5, 0))
                    * EntityRenderer.scaleM(SIMD3(shW, shH, shD))
                drawCube(enc: enc, viewProj: viewProj, model: shinModel, rgb: legCol, sat: sat)
            }
        }

        // A few tiny glinting eyes clustered on the head front
        let faceZ = headZ + hdD * 0.42
        let eyeY  = -abH * 0.02
        let er = s * 0.05
        let erH = er * eyeBlinkSY
        for (ex, ey) in [(-0.16, 0.10), (0.16, 0.10), (-0.08, 0.0), (0.08, 0.0)] as [(Float, Float)] {
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(hdW * ex, eyeY + hdH * ey, faceZ), SIMD3(er, erH, er * 0.8)),
                     rgb: eyeCol, sat: sat)
        }
    }

    // =========================================================================
    // KIND 17 — GHOST (monster: floating wispy body, no legs)
    //
    // Silhouette: a rounded head/body that tapers to a WAVY tattered bottom (a
    // row of little hanging tails of varying length) instead of legs. Hollow
    // dark eyes and a small "oooh" mouth. The whole thing bobs up and down and
    // drifts gently side to side. Body uses an HDR-ish bright tint so it glows
    // faintly in the bloom pass (like the other monsters' emissive accents).
    //
    // Parts: body(1) head-dome(1) tails(5) eyes(2) mouth(1) = 10
    // =========================================================================
    private func drawKind17(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: ghost (pale, faintly glowing) ----
        // bright wispy body: lighten the entity color a lot toward white
        let bodyCol  = SIMD3<Float>(min(1, base.x*0.35+0.62),
                                    min(1, base.y*0.35+0.62),
                                    min(1, base.z*0.35+0.66))
        // tails slightly more saturated/dim than the body for a tapering read
        let tailCol  = SIMD3<Float>(min(1, base.x*0.45+0.42),
                                    min(1, base.y*0.45+0.42),
                                    min(1, base.z*0.45+0.48))
        let eyeCol   = SIMD3<Float>(0.04, 0.04, 0.08)   // hollow dark eyes

        // Float bob + drift
        let bob     = sin(phase * 1.6 + hash) * s * 0.10
        let drift   = sin(phase * 0.9 + hash * 1.7) * s * 0.06    // side-to-side
        let waveT   = phase * 2.4                                 // tail wave
        let blinkPhase = phase + hash * 4.0
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS ----
        let bW = s * 0.58; let bH = s * 0.66; let bD = s * 0.50

        let groundY = pos.y
        // floats above the ground
        let bodyY   = groundY + s * 0.55 + bH * 0.5 + bob
        let wc      = SIMD3<Float>(pos.x + drift, bodyY, pos.z)
        // ghost has no feet; keep squash pivot at body center (footLocal 0 is fine,
        // but use ground for consistency with hit recoil)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: -(bH * 0.5))

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // Body — rounded column
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bW, bH, bD)), rgb: bodyCol, sat: sat)
        // Rounded top dome (head)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH * 0.46, 0), SIMD3(bW * 0.86, bH * 0.34, bD * 0.86)),
                 rgb: bodyCol, sat: sat)

        // Wavy tattered bottom — 5 hanging tails of varying length that sway,
        // standing in for legs (the floaty wisp signature)
        let tails = 5
        for i in 0..<tails {
            let fx = (Float(i) / Float(tails - 1)) - 0.5      // -0.5 .. +0.5
            let baseLen: Float = (i % 2 == 0) ? 0.30 : 0.20    // alternate long/short
            let wave = sin(waveT + Float(i) * 1.1) * s * 0.04
            let tH = s * baseLen
            let tailModel = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3(fx * bW * 0.88 + wave, -bH * 0.5 - tH * 0.4, 0))
                * EntityRenderer.scaleM(SIMD3(bW * 0.20, tH, bD * 0.70))
            drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: tailCol, sat: sat)
        }

        // Hollow dark eyes
        let faceZ = bD * 0.50
        let eyeW = s * 0.11; let eyeH = s * 0.15 * eyeBlinkSY; let eyeD = s * 0.04
        let eyeY = bH * 0.40
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-bW * 0.22, eyeY, faceZ), SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( bW * 0.22, eyeY, faceZ), SIMD3(eyeW, eyeH, eyeD)),
                 rgb: eyeCol, sat: sat)
        // Small round "oooh" mouth
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH * 0.14, faceZ), SIMD3(s * 0.10, s * 0.12, s * 0.04)),
                 rgb: eyeCol, sat: sat)
    }

    // =========================================================================
    // KIND 18 — FISH (small horizontal swimmer)
    //
    // Silhouette: a small horizontal oval body oriented along the creature's
    // facing (yaw), a triangular tail fin at the back that WIGGLES, a top dorsal
    // fin, and a small side fin. Eye near the front. Whole body undulates with a
    // gentle swim wiggle.
    //
    // Parts: body(1) tail-fin(2 taper) dorsal-fin(1) side-fins(2) eyes(2) = 8
    // =========================================================================
    private func drawKind18(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: fish ----
        let baseCol  = base
        let bellyCol = SIMD3<Float>(min(1, base.x*0.6+0.34),
                                    min(1, base.y*0.6+0.34),
                                    min(1, base.z*0.6+0.36))
        let finCol   = SIMD3<Float>(min(1, base.x*0.7+0.16),
                                    min(1, base.y*0.7+0.16),
                                    min(1, base.z*0.7+0.20))
        let eyeCol   = SIMD3<Float>(0.04, 0.04, 0.05)

        let swimSpeed: Float = 3.6
        let bodyWiggle = sin(phase * swimSpeed) * 0.10       // whole-body yaw waver
        let tailWag    = sin(phase * swimSpeed + 1.0) * 0.6  // tail swings more
        let bob        = sin(phase * 1.8 + hash) * s * 0.04
        let blinkPhase = phase + hash * 4.0
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS (long along +Z = facing) ----
        let bW = s * 0.34; let bH = s * 0.42; let bD = s * 0.70   // body (tall-ish, oval)
        let t1W = s * 0.06; let t1H = s * 0.36; let t1D = s * 0.18 // tail base
        let t2W = s * 0.04; let t2H = s * 0.50; let t2D = s * 0.20 // tail flare
        let dorW = s * 0.05; let dorH = s * 0.26; let dorD = s * 0.34

        let groundY = pos.y
        let bodyY   = groundY + s * 0.45 + bob          // swims a bit above ground
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: -(bH * 0.5))
        let wig     = EntityRenderer.rotY(bodyWiggle)

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * wig * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // Body — oval, tapering toward the tail (drawn slightly narrower at back)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, bD * 0.05), SIMD3(bW, bH, bD)), rgb: baseCol, sat: sat)
        // Pale belly
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bH * 0.28, bD * 0.05), SIMD3(bW * 0.84, bH * 0.42, bD * 0.84)),
                 rgb: bellyCol, sat: sat)

        // Tail fin — two stacked blocks at the back that wag together
        do {
            let tailPivot = SIMD3<Float>(0, 0, -bD * 0.48)
            let base1 = EntityRenderer.trans(wc) * R * wig
                * EntityRenderer.trans(tailPivot)
                * EntityRenderer.rotY(tailWag)
            let t1Model = base1
                * EntityRenderer.trans(SIMD3(0, 0, -t1D * 0.5))
                * EntityRenderer.scaleM(SIMD3(t1W, t1H, t1D))
            let t2Model = base1
                * EntityRenderer.trans(SIMD3(0, 0, -t1D - t2D * 0.5))
                * EntityRenderer.scaleM(SIMD3(t2W, t2H, t2D))
            drawCube(enc: enc, viewProj: viewProj, model: t1Model, rgb: finCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj, model: t2Model, rgb: finCol, sat: sat)
        }

        // Dorsal fin — thin sail on top
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, bH * 0.50 + dorH * 0.4, 0), SIMD3(dorW, dorH, dorD)),
                 rgb: finCol, sat: sat)
        // Side fins — little paddles low on each flank
        for sx in [-1.0, 1.0] as [Float] {
            let fin = EntityRenderer.trans(wc) * R * wig
                * EntityRenderer.trans(SIMD3(sx * bW * 0.50, -bH * 0.10, bD * 0.10))
                * EntityRenderer.rotZ(sx * 0.5)
                * EntityRenderer.scaleM(SIMD3(s * 0.18, s * 0.04, s * 0.14))
            drawCube(enc: enc, viewProj: viewProj, model: fin, rgb: finCol, sat: sat)
        }

        // Eyes — near the front, one per side
        let faceZ = bD * 0.45
        let eyeW = s * 0.07; let eyeH = s * 0.09 * eyeBlinkSY; let eyeD = s * 0.05
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-bW * 0.42, bH * 0.10, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: SIMD3<Float>(0.96, 0.96, 0.98), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( bW * 0.42, bH * 0.10, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: SIMD3<Float>(0.96, 0.96, 0.98), pupilCol: eyeCol)
    }

    // =========================================================================
    // KIND 19 — PUFFERFISH (round spiky ball fish)
    //
    // Silhouette: a round ball body covered in short SPIKES poking out in all
    // directions, with two small side fins, a tiny tail, and big cute eyes on
    // the front. Spikes gently "breathe" in and out. Bobs in place.
    //
    // Parts: body(1) spikes(~14) side-fins(2) tail(1) eyes(2) mouth(1) = ~21
    // =========================================================================
    private func drawKind19(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let base = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE: pufferfish ----
        let baseCol  = base
        let bellyCol = SIMD3<Float>(min(1, base.x*0.6+0.34),
                                    min(1, base.y*0.6+0.34),
                                    min(1, base.z*0.6+0.32))
        let spikeCol = base * 0.62
        let finCol   = SIMD3<Float>(min(1, base.x*0.7+0.18),
                                    min(1, base.y*0.7+0.18),
                                    min(1, base.z*0.7+0.20))
        let eyeCol   = SIMD3<Float>(0.04, 0.04, 0.05)

        let bob        = sin(phase * 1.7 + hash) * s * 0.05
        // spike puff: spikes ease out and in (the puffer "inflates")
        let puff       = (sin(phase * 1.2 + hash) * 0.5 + 0.5)   // 0..1
        let spikeLen   = s * (0.10 + puff * 0.10)
        let finFlap    = sin(phase * 3.0) * 0.4
        let blinkPhase = phase + hash * 4.0
        let eyeBlinkSY = blinkScale(blinkPhase)

        // ---- PROPORTIONS ----
        let bS = s * 0.56                          // round ball body

        let groundY = pos.y
        let bodyY   = groundY + s * 0.45 + bob
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: -(bS * 0.5))

        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // Round ball body
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(bS, bS * 0.94, bS)), rgb: baseCol, sat: sat)
        // Pale belly underside
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bS * 0.26, bS * 0.10), SIMD3(bS * 0.74, bS * 0.40, bS * 0.74)),
                 rgb: bellyCol, sat: sat)

        // SPIKES — short blocks poking out on top, sides, and back (not the front
        // face, so they don't cover the eyes). Each sits just outside the body.
        let r = bS * 0.5
        let spikeDirs: [SIMD3<Float>] = [
            SIMD3( 0,  1,  0), SIMD3( 0.6, 0.7, 0), SIMD3(-0.6, 0.7, 0),   // top
            SIMD3( 1,  0.2, 0), SIMD3(-1, 0.2, 0),                          // sides
            SIMD3( 0.7, 0.0, -0.7), SIMD3(-0.7, 0.0, -0.7),                 // back-sides
            SIMD3( 0,  0.2, -1),                                            // back
            SIMD3( 0.6, -0.6, 0), SIMD3(-0.6, -0.6, 0),                     // lower sides
            SIMD3( 0,  -0.8, -0.4),                                          // lower back
            SIMD3( 0.5, 0.3, 0.6), SIMD3(-0.5, 0.3, 0.6),                   // upper front-side
            SIMD3( 0,  0.9, -0.4),                                           // top-back
        ]
        for d in spikeDirs {
            let dir = simd_normalize(d)
            let cx = dir.x * (r + spikeLen * 0.4)
            let cy = dir.y * (r + spikeLen * 0.4)
            let cz = dir.z * (r + spikeLen * 0.4)
            drawCube(enc: enc, viewProj: viewProj,
                     model: pw(SIMD3(cx, cy, cz), SIMD3(s * 0.07, s * 0.07, s * 0.07 + spikeLen)),
                     rgb: spikeCol, sat: sat)
        }

        // Side fins — flap a little
        for sx in [-1.0, 1.0] as [Float] {
            let fin = EntityRenderer.trans(wc) * R
                * EntityRenderer.trans(SIMD3(sx * bS * 0.50, -bS * 0.04, bS * 0.10))
                * EntityRenderer.rotZ(sx * (0.4 + finFlap * 0.2))
                * EntityRenderer.scaleM(SIMD3(s * 0.16, s * 0.04, s * 0.14))
            drawCube(enc: enc, viewProj: viewProj, model: fin, rgb: finCol, sat: sat)
        }
        // Tiny tail at the back
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, -bS * 0.54), SIMD3(s * 0.06, s * 0.20, s * 0.14)),
                 rgb: finCol, sat: sat)

        // Big cute eyes on the front
        let faceZ = bS * 0.50
        let eyeW = s * 0.12; let eyeH = s * 0.14 * eyeBlinkSY; let eyeD = s * 0.05
        let eyeY = bS * 0.10
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-bS * 0.24, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: SIMD3<Float>(0.97, 0.97, 0.99), pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( bS * 0.24, eyeY, faceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: SIMD3<Float>(0.97, 0.97, 0.99), pupilCol: eyeCol)
        // Small pursed mouth
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -bS * 0.14, faceZ), SIMD3(s * 0.08, s * 0.06, s * 0.04)),
                 rgb: SIMD3<Float>(0.12, 0.08, 0.10), sat: sat)
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

    // =========================================================================
    // KIND 20 — VILLAGER / NPC PERSON (friendly, cute, kid-game humanoid)
    //
    // Issue #39 (people at structures). A clearly FRIENDLY upright blocky person,
    // unmistakably distinct from the animals (quadrupeds) and from the scary
    // humanoid monsters (kind 5 / kind 11): bright skin tone, a colored tunic
    // (clothing accent from the entity tint), soft round head with two big
    // friendly eyes + a happy smile, simple hair cap, and a gentle idle — a slow
    // breathing bob plus a soft side-to-side arm sway. No glowing eyes, no fangs,
    // no menace. Reads as a cheerful villager you'd walk up to and talk to.
    //
    // Silhouette: short, slightly stocky upright figure — round head, boxy tunic
    // torso, two short arms, two short legs. Friendlier proportions than the
    // lurker (bigger head, rounder, no scowl).
    //
    // PALETTE:
    //   skinCol     — warm friendly skin tone (fixed, not tinted, so faces always
    //                 read as a person regardless of clothing color)
    //   tunicCol    — clothing color, derived from the entity tint so variants
    //                 (villager / elder / trader) wear different colors
    //   tunicTrim   — lighter band/collar on the tunic
    //   pantsCol    — muted brown trousers
    //   hairCol     — brown hair cap
    //   eyeCol      — soft dark eyes (sclera + pupil via drawEye)
    //   mouthCol    — gentle warm smile
    //
    // Parts: legs(2) feet(2) torso(1) tunic-trim(1) belt(1) arms(2) hands(2)
    //        neck(1) head(1) hair(1) eyes(2) cheeks(2) smile(1) = 19
    // =========================================================================
    private func drawKind20(enc: MTLRenderCommandEncoder,
                            viewProj: simd_float4x4,
                            e: bf_entity_draw,
                            pos: SIMD3<Float>,
                            phase: Float,
                            hash: Float,
                            squash: SIMD3<Float>) {
        let s   = e.scale
        let sat = e.sat
        let Ryaw = EntityRenderer.rotY(e.yaw)
        let tint = SIMD3<Float>(e.color.x, e.color.y, e.color.z)

        // ---- PALETTE ----
        // Warm friendly skin — fixed so the villager always reads as a person.
        let skinCol  = SIMD3<Float>(0.93, 0.76, 0.62)
        // Clothing comes from the entity tint so villager/elder/trader differ.
        // Keep it bright and cheerful (lift toward a vivid mid-tone).
        let tunicCol = SIMD3<Float>(min(1, tint.x * 0.60 + 0.22),
                                    min(1, tint.y * 0.60 + 0.30),
                                    min(1, tint.z * 0.60 + 0.34))
        // Lighter collar/trim band.
        let tunicTrim = SIMD3<Float>(min(1, tunicCol.x + 0.20),
                                     min(1, tunicCol.y + 0.20),
                                     min(1, tunicCol.z + 0.20))
        let beltCol  = SIMD3<Float>(0.40, 0.28, 0.16)   // brown belt
        let pantsCol = SIMD3<Float>(0.34, 0.27, 0.20)   // muted brown trousers
        let shoeCol  = SIMD3<Float>(0.22, 0.16, 0.12)   // dark shoes
        let hairCol  = SIMD3<Float>(0.32, 0.20, 0.10)   // brown hair
        let eyeCol   = SIMD3<Float>(0.10, 0.08, 0.10)   // soft dark eyes
        let mouthCol = SIMD3<Float>(0.62, 0.30, 0.28)   // gentle warm smile
        let cheekCol = SIMD3<Float>(0.96, 0.62, 0.56)   // rosy cheeks

        // ---- ANIMATION PHASES ----
        let blinkPhase  = phase + hash * 4.7
        let breathPhase = phase * 0.40 + hash * 1.6
        // Gentle idle: slow arm sway + tiny weight shift. No walk cycle needed —
        // a friendly NPC that stands and chats.
        let swaySpeed: Float = 1.1
        let armSway   = sin(phase * swaySpeed + hash * 2.0) * 0.16   // soft arm swing
        let leanAngle = sin(phase * swaySpeed * 0.5 + hash) * 0.025  // tiny body lean

        let breatheY   = breatheYOffset(breathPhase, scale: s)
        let eyeBlinkSY = blinkScale(blinkPhase)
        let bodyLean   = EntityRenderer.rotZ(leanAngle)

        // ---- PROPORTIONS (cute, slightly stocky person) ----
        let legW = s * 0.18; let legH = s * 0.34; let legD = s * 0.18
        let footW = s * 0.20; let footH = s * 0.09; let footD = s * 0.26
        let legTotalH = legH + footH

        // Torso: boxy tunic, a touch wider than the lurker for a softer look.
        let tW = s * 0.50;  let tH = s * 0.46;  let tD = s * 0.30
        // Neck: short connector.
        let nkW = s * 0.16; let nkH = s * 0.08; let nkD = s * 0.16
        // Head: big and round (cute — bigger relative to body than the monster).
        let hW = s * 0.46;  let hH = s * 0.44;  let hD = s * 0.42
        // Arms: short single-segment limbs.
        let armW = s * 0.14; let armH = s * 0.40; let armD = s * 0.14
        let handW = s * 0.17; let handH = s * 0.12; let handD = s * 0.17

        // ---- WORLD CENTRE (at torso mid) ----
        let groundY = pos.y
        let bodyY   = groundY + legTotalH + tH * 0.5 + breatheY
        let wc      = SIMD3<Float>(pos.x, bodyY, pos.z)
        let R       = squashRig(Ryaw, squash: squash, footLocalY: groundY - wc.y)

        // Part-world closure: trans(wc) * R * bodyLean * trans(local) * scale.
        // bodyLean gives the whole figure a soft idle rock.
        func pw(_ lo: SIMD3<Float>, _ d: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodyLean * EntityRenderer.trans(lo) * EntityRenderer.scaleM(d)
        }

        // ---- LEGS + FEET ----
        let hipY = -tH * 0.5
        func legM(_ hip: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodyLean * EntityRenderer.trans(hip)
                * EntityRenderer.trans(SIMD3(0, -legH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
        }
        func footM(_ hip: SIMD3<Float>) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodyLean * EntityRenderer.trans(hip)
                * EntityRenderer.trans(SIMD3(0, -legH - footH * 0.5, footD * 0.12))
                * EntityRenderer.scaleM(SIMD3(footW, footH, footD))
        }
        let hipL = SIMD3<Float>(-tW * 0.24, hipY, 0)
        let hipR = SIMD3<Float>( tW * 0.24, hipY, 0)
        drawCube(enc: enc, viewProj: viewProj, model: legM(hipL),  rgb: pantsCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: legM(hipR),  rgb: pantsCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: footM(hipL), rgb: shoeCol,  sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: footM(hipR), rgb: shoeCol,  sat: sat)

        // ---- TORSO (tunic) ----
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, 0, 0), SIMD3(tW, tH, tD)), rgb: tunicCol, sat: sat)
        // Collar/trim — lighter band across the top of the tunic.
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, tH * 0.40, tD * 0.02), SIMD3(tW * 1.02, tH * 0.16, tD * 1.02)),
                 rgb: tunicTrim, sat: sat)
        // Belt — brown band across the bottom of the tunic.
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, -tH * 0.40, 0), SIMD3(tW * 1.04, tH * 0.14, tD * 1.04)),
                 rgb: beltCol, sat: sat)

        // ---- ARMS + HANDS ---- (gentle opposite sway, hands are bare skin)
        let shoulderY  = tH * 0.40
        let shoulderXL = -(tW * 0.50 + armW * 0.45)
        let shoulderXR =  (tW * 0.50 + armW * 0.45)
        func armM(_ shoulderX: Float, _ swingAng: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodyLean
                * EntityRenderer.trans(SIMD3(shoulderX, shoulderY, 0))
                * EntityRenderer.rotX(swingAng)
                * EntityRenderer.trans(SIMD3(0, -armH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(armW, armH, armD))
        }
        func handM(_ shoulderX: Float, _ swingAng: Float) -> simd_float4x4 {
            EntityRenderer.trans(wc) * R * bodyLean
                * EntityRenderer.trans(SIMD3(shoulderX, shoulderY, 0))
                * EntityRenderer.rotX(swingAng)
                * EntityRenderer.trans(SIMD3(0, -armH - handH * 0.5, 0))
                * EntityRenderer.scaleM(SIMD3(handW, handH, handD))
        }
        // Sleeves match the tunic, hands are skin.
        drawCube(enc: enc, viewProj: viewProj, model: armM(shoulderXL,  armSway), rgb: tunicCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: armM(shoulderXR, -armSway), rgb: tunicCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: handM(shoulderXL,  armSway), rgb: skinCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj, model: handM(shoulderXR, -armSway), rgb: skinCol, sat: sat)

        // ---- NECK + HEAD ----
        let neckY = tH * 0.50 + nkH * 0.5
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, neckY, 0), SIMD3(nkW, nkH, nkD)), rgb: skinCol, sat: sat)

        let headY: Float = tH * 0.50 + nkH + hH * 0.50
        let headZ: Float = 0
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY, headZ), SIMD3(hW, hH, hD)), rgb: skinCol, sat: sat)

        // Hair — brown cap over the top/back of the head.
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY + hH * 0.34, -hD * 0.06), SIMD3(hW * 1.04, hH * 0.36, hD * 1.04)),
                 rgb: hairCol, sat: sat)

        // ---- FACE (on the +Z front of the head, so it faces the heading dir) ----
        let hFaceZ: Float = headZ + hD * 0.50 + s * 0.01
        // Two big friendly eyes (white sclera + soft dark pupil + catchlight).
        let eyeW = s * 0.10; let eyeH = s * 0.12 * eyeBlinkSY; let eyeD = s * 0.04
        let eyeY = headY + hH * 0.08
        let scleraCol = SIMD3<Float>(0.98, 0.98, 0.98)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3(-hW * 0.22, eyeY, hFaceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: scleraCol, pupilCol: eyeCol)
        drawEye(enc: enc, viewProj: viewProj, pw: pw,
                c: SIMD3( hW * 0.22, eyeY, hFaceZ), r: SIMD3(eyeW, eyeH, eyeD),
                sat: sat, scleraCol: scleraCol, pupilCol: eyeCol)
        // Rosy cheeks — soft friendly blush dots below the eyes.
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(-hW * 0.32, headY - hH * 0.14, hFaceZ), SIMD3(s * 0.09, s * 0.06, s * 0.02)),
                 rgb: cheekCol, sat: sat)
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3( hW * 0.32, headY - hH * 0.14, hFaceZ), SIMD3(s * 0.09, s * 0.06, s * 0.02)),
                 rgb: cheekCol, sat: sat)
        // Gentle smile — a small warm horizontal mouth below the eyes.
        drawCube(enc: enc, viewProj: viewProj,
                 model: pw(SIMD3(0, headY - hH * 0.26, hFaceZ), SIMD3(hW * 0.34, s * 0.05, s * 0.03)),
                 rgb: mouthCol, sat: sat)
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
