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

final class EntityRenderer {
    private let pipeline:   MTLRenderPipelineState
    private let cubeVB:     MTLBuffer
    let cubeIB:     MTLBuffer
    let indexCount: Int

    // #116 ground contact-shadow pass (CAST). A single horizontal quad per entity, GPU-expanded,
    // alpha-blended onto the ground, depth-TESTED (so terrain in front occludes it) but it does NOT
    // write depth (so it never z-fights the creature drawn after it). The blob is computed
    // analytically in the fragment shader, no per-entity shadow map.
    private let groundShadowPipeline: MTLRenderPipelineState
    private let groundShadowDepth:    MTLDepthStencilState
    // Opaque depth for the creature body pass (less, writes depth) so parts occlude each other.
    // The ground-shadow pass above binds a no-write state, so we must restore this before bodies,
    // otherwise face parts (drawn after the head) render through the head from behind.
    private let bodyDepth:            MTLDepthStencilState
    private var shadowInstBuf:        MTLBuffer?
    private var shadowInsts:          [EntityShadowInstance] = []
    // Current shadow uniforms + occupancy textures for THIS encode (set at top of encode()).
    private var curShadow:    EntityShadowUniforms = EntityShadowUniforms()
    private var curOcc:       MTLTexture?
    private var curOccCoarse: MTLTexture?
    // #180 horizon curvature for THIS encode: xyz = camera world pos, w = enable (0 = flat).
    // Internal (not private) because drawCube lives in the EntityRendererSpecies extension.
    var curCamPosH: SIMD4<Float> = .zero

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
        // #131 movement-matched animation. We track the entity's last ground
        // position and an accumulated GAIT phase. The walk cycle (legs) is driven by
        // this gait phase, which advances in proportion to the distance the creature
        // actually moved this frame, so the feet do not slide and the creature goes
        // idle (legs hold) when it stops. We do NOT have a velocity field in the
        // entity ABI, so speed is derived from the per-frame position delta.
        var lastX:      Float
        var lastZ:      Float
        var gait:       Float   // accumulated gait phase (radians)
        var gaitSpeed:  Float   // smoothed ground speed (blocks/sec) for cadence
    }
    private var hist: [UInt64: EntityHist] = [:]
    private var lastPrune: Float = 0
    /// Wall-clock time of the previous encode, to turn position deltas into speed.
    private var lastEncodeT: Float = -1

    /// Duration of the hit reaction in seconds (flash + squash recoil).
    private let hitDuration: Float = 0.32

    // Per-entity reaction state for the CURRENTLY drawing creature. Set once at
    // the top of each entity's draw in `encode`, read by `drawCube`. Avoids
    // threading a new parameter through every drawKindN signature.
    var curFlash: SIMD3<Float> = .zero   // additive color toward white/red
    var curFlashAmt: Float = 0           // 0..1 strength (for emissive parts)

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
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: EntityRenderer.shaderSource, options: nil) }
        catch { fatalError("entity shader compile failed: \(error)") }
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

        // #116 ground contact-shadow pipeline (CAST). Alpha-blended (over) so the dark blob
        // multiplies the ground toward shadow. Depth-tested but NOT depth-writing.
        let gsd = MTLRenderPipelineDescriptor()
        gsd.vertexFunction   = lib.makeFunction(name: "groundShadowV")
        gsd.fragmentFunction = lib.makeFunction(name: "groundShadowF")
        gsd.colorAttachments[0].pixelFormat = colorFormat
        gsd.colorAttachments[0].isBlendingEnabled = true
        gsd.colorAttachments[0].rgbBlendOperation = .add
        gsd.colorAttachments[0].alphaBlendOperation = .add
        gsd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        gsd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        gsd.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        gsd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        gsd.depthAttachmentPixelFormat = .depth32Float
        groundShadowPipeline = try! device.makeRenderPipelineState(descriptor: gsd)

        let gds = MTLDepthStencilDescriptor()
        gds.depthCompareFunction = .lessEqual
        gds.isDepthWriteEnabled  = false   // blend onto the ground without writing depth
        groundShadowDepth = device.makeDepthStencilState(descriptor: gds)!

        let bds = MTLDepthStencilDescriptor()
        bds.depthCompareFunction = .less
        bds.isDepthWriteEnabled  = true    // bodies write depth so parts occlude each other
        bodyDepth = device.makeDepthStencilState(descriptor: bds)!
    }

    // -----------------------------------------------------------------------
    // #116 `shadow`/`occ`/`occCoarse` are optional so the perf-only harness paths can keep calling
    // with no shadow data (character shadows simply off there). When present and enabled
    // (shadow.params.x > 0.5) entities RECEIVE the world voxel sun shadow AND a ground blob is CAST.
    func encode(_ enc: MTLRenderCommandEncoder,
                viewProj: simd_float4x4,
                entities: UnsafePointer<bf_entity_draw>?,
                count:    Int,
                shadow:   EntityShadowUniforms = EntityShadowUniforms(),
                occ:      MTLTexture? = nil,
                occCoarse: MTLTexture? = nil,
                camPosH:  SIMD4<Float> = .zero) {   // #180 horizon curvature (default flat)
        guard let entities = entities, count > 0 else { return }
        curShadow    = shadow
        curOcc       = occ
        curOccCoarse = occCoarse
        curCamPosH   = camPosH
        let charShadowOn = (shadow.params.x > 0.5) && occ != nil && occCoarse != nil

        // ---- CAST PASS (#116, Part 2): one soft ground blob per entity, drawn FIRST so the
        // creature cubes (which write depth) sit on top of it. Falling blocks (kind 6) get no
        // contact shadow. Daylight gating + the offset/stretch happen in the shader; here we just
        // collect a tiny per-entity instance (foot pos + footprint radius). Cheap: a few floats per
        // entity + one instanced draw of two triangles each.
        if charShadowOn {
            encodeGroundShadows(enc, viewProj: viewProj, entities: entities, count: count)
        }

        enc.setRenderPipelineState(pipeline)
        // Restore opaque write-enabled depth: the ground-shadow pass above leaves a no-write state
        // bound, which would let face parts show through the head from behind (#116 regression).
        enc.setDepthStencilState(bodyDepth)
        enc.setVertexBuffer(cubeVB, offset: 0, index: 0)
        // Bind shadow uniforms + occupancy once for all cubes this encode (RECEIVE pass, Part 1).
        var su = curShadow
        enc.setFragmentBytes(&su, length: MemoryLayout<EntityShadowUniforms>.stride, index: 2)
        if let o = curOcc       { enc.setFragmentTexture(o, index: 0) }
        if let oc = curOccCoarse { enc.setFragmentTexture(oc, index: 1) }

        let t = Float(CACurrentMediaTime())

        // Periodically prune stale history so the dictionary can't grow without
        // bound as creatures spawn/despawn. Cheap: every ~2s.
        if t - lastPrune > 2.0 {
            lastPrune = t
            hist = hist.filter { t - $0.value.lastSeen < 1.5 }
        }

        // Real seconds since the previous encode, clamped so a long stall (tab away,
        // first frame) can't fling the gait phase forward. Used to convert each
        // entity's position delta into a ground speed.
        let frameDt: Float = (lastEncodeT < 0) ? (1.0 / 60.0) : min(max(t - lastEncodeT, 1.0 / 240.0), 1.0 / 15.0)
        lastEncodeT = t

        for i in 0..<count {
            let e = entities[i]
            let pos = SIMD3<Float>(e.position.x, e.position.y, e.position.z)
            // Per-entity spatial hash — scatters all animation phases so
            // dozens of creatures never step in sync.
            let phaseHash = sin(pos.x * 1.3 + pos.z * 2.7)
            // Ambient (wall-clock) phase: drives the always-on idle breath pulse so
            // a stopped creature still looks alive even though its legs hold.
            let ambient   = t + phaseHash * 3.14159

            // #131 MOVEMENT-MATCHED WALK CYCLE. `phase` (consumed by every drawKindN
            // for the leg/gait swing) is now driven by the creature's ACTUAL ground
            // speed instead of wall-clock, so feet do not slide and the gait idles
            // when the creature stops. We derive speed from the per-frame ground
            // position delta (no velocity field in the entity ABI) and accumulate a
            // gait phase at a cadence proportional to that speed. Default for kinds
            // with no history this frame: fall back to the ambient phase so a freshly
            // seen creature still animates.
            var phase = ambient

            // --- HIT REACTION: derive a hurt signal & build the per-entity
            // reaction (flash + squash). Falling blocks (kind 6) are exempt.
            var squash = SIMD3<Float>(1, 1, 1)
            curFlash    = .zero
            curFlashAmt = 0
            if e.kind != 6 && e.kind != 22 {
                // CONTINUOUS LIVELINESS: a tiny always-on breathing pulse on the
                // whole-creature squash so nothing ever looks frozen, even when
                // stationary and not mid-hit. Very subtle (<1.5%) and phase-
                // scattered so a crowd doesn't pulse in unison. This rides
                // *through* the same squash channel, so it's free. Stays on the
                // ambient (wall-clock) phase so it keeps breathing while idle.
                let idle = sin(ambient * 0.9) * 0.012
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

                    // --- gait: distance moved this frame -> ground speed -> cadence.
                    let dx = pos.x - h.lastX
                    let dz = pos.z - h.lastZ
                    let inst = sqrt(dx * dx + dz * dz) / max(frameDt, 1e-4)
                    // Smooth the speed a little so a single jittery frame doesn't make
                    // the legs stutter; this is a cheap exponential follow.
                    h.gaitSpeed += (inst - h.gaitSpeed) * min(1.0, frameDt * 12.0)
                    // Cadence: radians of gait per second at the measured speed. ~2
                    // strides/sec per block/sec reads right for these small creatures.
                    // Below a tiny threshold the gait holds (feet planted = idle).
                    let cadence: Float = (h.gaitSpeed > 0.05) ? (h.gaitSpeed * 2.2) : 0.0
                    h.gait += cadence * frameDt
                    h.lastX = pos.x
                    h.lastZ = pos.z
                    // Use the gait phase (plus the per-entity hash offset so a crowd
                    // doesn't step in sync) for the walk cycle this frame.
                    phase = h.gait + phaseHash * 3.14159

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
                    // New bucket. A moving creature crosses 0.5-unit cells every few
                    // frames, so to avoid a leg-phase pop on each crossing we inherit
                    // the gait from the most recent neighbouring cell (same kind) if
                    // one exists. The creature's own previous-frame entry is one of
                    // these neighbours, so the gait stays continuous as it walks.
                    var seed = EntityHist(
                        lastScale: e.scale, lastSeen: t, hitAt: -1,
                        lastX: pos.x, lastZ: pos.z, gait: 0, gaitSpeed: 0
                    )
                    var bestAge: Float = 0.4   // only inherit from a fresh neighbour
                    for ddx in -1...1 {
                        for ddz in -1...1 {
                            if ddx == 0 && ddz == 0 { continue }
                            let np = SIMD3<Float>(pos.x + Float(ddx) * 0.5, pos.y, pos.z + Float(ddz) * 0.5)
                            let nk = histKey(np, e.kind)
                            if let nh = hist[nk], t - nh.lastSeen < bestAge {
                                bestAge = t - nh.lastSeen
                                seed.gait = nh.gait
                                seed.gaitSpeed = nh.gaitSpeed
                                seed.lastX = nh.lastX
                                seed.lastZ = nh.lastZ
                            }
                        }
                    }
                    phase = seed.gait + phaseHash * 3.14159
                    hist[key] = seed
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
            // kind 22 — DEBRIS FRAGMENT (#170 blockfall): a small tumbling cube
            // chip in the broken block's colour. yaw carries the engine-driven
            // spin phase; scale seeds the size + a fixed per-fragment tilt.
            case 22: drawKind22(enc: enc, viewProj: viewProj, e: e, pos: pos)
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


    // -----------------------------------------------------------------------
    // #116 CAST PASS. Collect one ground contact-shadow instance per entity and draw them as a
    // single instanced quad batch. The blob's footprint radius scales with the entity's draw scale;
    // the shader stretches/offsets it along the sun azimuth and snaps it to the ground surface by
    // sampling the occupancy grid. Anchored at the entity's foot world position (entity.position is
    // the ground contact in every drawKind, so .y is already the surface under the feet).
    private func encodeGroundShadows(_ enc: MTLRenderCommandEncoder,
                                     viewProj: simd_float4x4,
                                     entities: UnsafePointer<bf_entity_draw>,
                                     count: Int) {
        shadowInsts.removeAll(keepingCapacity: true)
        for i in 0..<count {
            let e = entities[i]
            if e.kind == 6 || e.kind == 22 { continue }   // falling blocks + debris: no contact shadow
            let pos = SIMD3<Float>(e.position.x, e.position.y, e.position.z)
            // Footprint radius scales with the creature's draw scale. Most kinds occupy ~0.6 units
            // wide at scale 1; the blob is a touch larger so it reads as a soft contact pool.
            let r = max(0.18, e.scale * 0.55)
            shadowInsts.append(EntityShadowInstance(
                footRadius: SIMD4<Float>(pos.x, pos.y, pos.z, r),
                meta: .zero))
        }
        let n = shadowInsts.count
        if n == 0 { return }

        let need = n * MemoryLayout<EntityShadowInstance>.stride
        if shadowInstBuf == nil || shadowInstBuf!.length < need {
            shadowInstBuf = enc.device.makeBuffer(length: max(need, 64 * 1024), options: .storageModeShared)
        }
        guard let ib = shadowInstBuf else { return }
        _ = shadowInsts.withUnsafeBytes { memcpy(ib.contents(), $0.baseAddress!, need) }

        enc.setRenderPipelineState(groundShadowPipeline)
        enc.setDepthStencilState(groundShadowDepth)
        enc.setCullMode(.none)
        var gu = GroundShadowUniforms(viewProj: viewProj,
                                      sunDirTime: curShadow.sunDirTime,
                                      voxOrigin:  curShadow.voxOrigin,
                                      voxDims:    curShadow.voxDims,
                                      camPosH:    curCamPosH)   // #180 blob sinks with the terrain
        enc.setVertexBytes(&gu, length: MemoryLayout<GroundShadowUniforms>.stride, index: 0)
        enc.setVertexBuffer(ib, offset: 0, index: 1)
        if let o = curOcc { enc.setVertexTexture(o, index: 0) }   // vertex snaps the quad to the surface
        enc.setFragmentBytes(&gu, length: MemoryLayout<GroundShadowUniforms>.stride, index: 0)
        if let o = curOcc       { enc.setFragmentTexture(o, index: 0) }
        if let oc = curOccCoarse { enc.setFragmentTexture(oc, index: 1) }
        // 6 verts (two triangles) per instance, GPU-expanded from gl_VertexID.
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)
        // Restore for the cube pass (encode rebinds its own pipeline next, but reset cull anyway).
        enc.setCullMode(.back)
    }


}
