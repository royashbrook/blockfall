import MetalKit

extension EntityRenderer {
    // -----------------------------------------------------------------------
    // MSL shader.
    // EUniforms.color.w == -1.0 is the emissive sentinel.
    // Emissive cubes bypass the shading multiply and output HDR color directly,
    // which blooms in the existing rgba16Float → bloom pass.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CVert     { packed_float3 pos; packed_float3 normal; };
    struct EUniforms { float4x4 mvp; float4 color; float4x4 model; };
    struct EOut      { float4 position [[position]]; float3 color; float shade; float sat;
                       float3 worldPos; float3 worldNrm; };

    // #116 shared character-shadow uniforms (mirror EntityShadowUniforms in Swift).
    struct EShadowU  { float4 sunDirTime; float4 voxOrigin; float4 voxDims; float4 params; };

    // ---- World-space voxel sun occlusion (CAST-by-world, RECEIVED-by-entity). This is the SAME
    // DDA march the terrain fragment uses (Renderer.marchSunOcclusion), duplicated here so an
    // entity gets the identical shade as the ground it stands on. 1.0 = lit, 0.0 = shadowed.
    constant int BFE_COARSE = 4;
    static float entMarchSun(texture3d<uint, access::read> occ,
                             texture3d<uint, access::read> coarse,
                             float3 gridOrigin, float3 gridDims,
                             float3 worldP, float3 toSun, float maxDist) {
        int3 dims = int3(gridDims);
        int3 iorigin = int3(round(gridOrigin));
        float3 p0 = worldP - gridOrigin + toSun * 0.05;
        float3 inv = float3(abs(toSun.x) < 1e-6 ? 0.0 : 1.0/toSun.x,
                            abs(toSun.y) < 1e-6 ? 0.0 : 1.0/toSun.y,
                            abs(toSun.z) < 1e-6 ? 0.0 : 1.0/toSun.z);
        float3 sgnPos = float3(toSun.x >= 0.0 ? 1.0 : 0.0, toSun.y >= 0.0 ? 1.0 : 0.0, toSun.z >= 0.0 ? 1.0 : 0.0);
        float t = 0.0;
        const int MAX_STEPS = 48;
        for (int i = 0; i < MAX_STEPS; ++i) {
            float3 p = p0 + toSun * t;
            int3 v = int3(floor(p));
            if (v.x < 0 || v.y < 0 || v.z < 0 || v.x >= dims.x || v.y >= dims.y || v.z >= dims.z) return 1.0;
            int wfx = (v.x + iorigin.x) & (dims.x - 1);
            int wfz = (v.z + iorigin.z) & (dims.z - 1);
            uint3 cvox = uint3(uint(wfx >> 2), uint(v.y >> 2), uint(wfz >> 2));
            if (coarse.read(cvox).r == 0u) {
                float3 cbase = float3(v - (v & 3));
                float3 nb = cbase + sgnPos * float(BFE_COARSE);
                float dx = (inv.x == 0.0) ? 1e30 : (nb.x - p.x) * inv.x;
                float dy = (inv.y == 0.0) ? 1e30 : (nb.y - p.y) * inv.y;
                float dz = (inv.z == 0.0) ? 1e30 : (nb.z - p.z) * inv.z;
                t += max(min(dx, min(dy, dz)), 0.0) + 0.0008;
            } else {
                if (occ.read(uint3(uint(wfx), uint(v.y), uint(wfz))).r != 0u) return 0.0;
                float3 nb = float3(v) + sgnPos;
                float dx = (inv.x == 0.0) ? 1e30 : (nb.x - p.x) * inv.x;
                float dy = (inv.y == 0.0) ? 1e30 : (nb.y - p.y) * inv.y;
                float dz = (inv.z == 0.0) ? 1e30 : (nb.z - p.z) * inv.z;
                t += max(min(dx, min(dy, dz)), 0.0) + 0.0008;
            }
            if (t > maxDist) return 1.0;
        }
        return 1.0;
    }

    // dayLight gate matching Renderer.dayLight: brightest at noon, ~0 at night. The terrain uses
    // clamp(shade*1.5) per-vertex; entities have no baked shade so we derive the gate from the sun
    // height (sunDirTime.y is the sun direction's downward y; sun high => y very negative).
    static float entDayFactor(float3 sunDir) {
        // sunDir points FROM the sun (downward when the sun is up). -sunDir.y > 0 means sun above.
        return clamp((-sunDir.y) * 2.2, 0.0, 1.0);
    }

    vertex EOut evmain(uint vid [[vertex_id]],
                       device const CVert* v [[buffer(0)]],
                       constant EUniforms& u  [[buffer(1)]]) {
        CVert cv = v[vid];
        float3 n = float3(cv.normal);
        // Directional shading: top bright, sides medium, bottom dim.
        float shade = clamp(0.55 + 0.30 * n.y + 0.15 * n.x, 0.0, 1.0);
        EOut o;
        float4 wp = u.model * float4(float3(cv.pos), 1.0);
        o.position = u.mvp * float4(float3(cv.pos), 1.0);
        o.color    = u.color.rgb;
        o.shade    = shade;
        o.sat      = u.color.w;   // -1.0 = emissive
        o.worldPos = wp.xyz;
        // World-space face normal (model has no non-uniform shear that would need the inverse
        // transpose for our purposes (rotation + uniform-ish squash), good enough for a back-face
        // sun gate). Used only to early-out faces that point away from the sun.
        o.worldNrm = normalize((u.model * float4(n, 0.0)).xyz);
        return o;
    }

    fragment float4 efmain(EOut in [[stage_in]],
                           constant EShadowU& es [[buffer(2)]],
                           texture3d<uint, access::read> occ      [[texture(0)]],
                           texture3d<uint, access::read> occCoarse [[texture(1)]]) {
        // Emissive path: sat < 0 → output HDR color unmodified (glows in bloom). Glowing eyes
        // never receive shadow (they emit), exactly like the terrain's emissive-block skip.
        if (in.sat < 0.0) {
            return float4(in.color, 1.0);
        }
        float3 c = in.color * in.shade;
        // Dim desaturation: mix toward luminance by (1 - sat).
        float l = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(l), c, clamp(in.sat, 0.0, 1.0));

        // ---- #116 RECEIVE the world voxel sun shadow (Part 1). Same march, gate, and 0.55 darken
        // the terrain uses, so a creature in a tree's shade goes dark consistently with the ground.
        if (es.params.x > 0.5) {
            float3 sunDir = es.sunDirTime.xyz;
            float dayFactor = entDayFactor(sunDir);
            if (dayFactor > 0.001) {
                float3 toSun = normalize(-sunDir);
                // BACK-FACE SKIP (the big perf win, exact): a face pointing away from the sun is
                // self-shadowed; mark it shadowed and skip the march. ~half the faces never march.
                float ndl = dot(in.worldNrm, toSun);
                float raw;
                if (ndl <= 0.0) {
                    raw = 0.0;
                } else {
                    raw = entMarchSun(occ, occCoarse, es.voxOrigin.xyz, es.voxDims.xyz,
                                      in.worldPos + in.worldNrm * 0.25, toSun, es.voxOrigin.w);
                }
                float shadowFactor = 1.0 - (0.55 * dayFactor) * (1.0 - raw);
                c *= shadowFactor;
            }
        }
        return float4(c, 1.0);
    }

    // =====================================================================================
    // #116 GROUND CONTACT-SHADOW PASS (CAST, Part 2)
    // One horizontal quad per entity, GPU-expanded from vid (6 verts). The quad is centred on the
    // entity's foot world position and sized to cover the footprint plus the sun-stretch. In the
    // fragment we:
    //   1. snap the fragment's Y to the actual ground surface by marching the occupancy grid DOWN
    //      (so the blob lands on slopes, not floating);
    //   2. compute a soft SDF ellipse in the ground plane, OFFSET and STRETCHED along the sun's
    //      ground-projected direction (low sun = long offset blob; high sun = tight under feet);
    //   3. fade with daylight and clamp, so nothing shows at night (no wash).
    // Cheap: a couple of triangles + a short downward occupancy march per covered pixel.
    // =====================================================================================
    struct GShadowInst { float4 footRadius; float4 meta; };
    struct GShadowU    { float4x4 viewProj; float4 sunDirTime; float4 voxOrigin; float4 voxDims; };
    struct GSOut       { float4 position [[position]]; float3 worldPos; float3 center; float radius;
                         float2 sunGround; float dayFactor; };

    // Downward occupancy march to find the ground surface Y under a world XZ (shared by the vertex
    // snap and the fragment slope fade). Returns the world Y of the top face of the first solid
    // voxel found at or below startY, or a large-negative sentinel if none in range.
    static float gsGroundY(texture3d<uint, access::read> occ,
                           float3 gridOrigin, float3 gridDims,
                           float wx, float startY, float wz, int span) {
        int3 dims = int3(gridDims);
        int3 iorigin = int3(round(gridOrigin));
        int gx = int(floor(wx)) & (dims.x - 1);
        int gz = int(floor(wz)) & (dims.z - 1);
        int wy0 = int(floor(startY)) - iorigin.y;
        for (int dyi = 0; dyi <= span; ++dyi) {
            int vy = wy0 - dyi;
            if (vy < 0 || vy >= dims.y) continue;
            if (occ.read(uint3(uint(gx), uint(vy), uint(gz))).r != 0u) {
                return float(vy + 1 + iorigin.y);
            }
        }
        return -1e9;
    }

    // #139 Bug B: is there a solid (occupied) voxel ABOVE this world point within `span` cells?
    // Used to detect a creature swimming UNDER a ceiling (fish under ice): if so we suppress the
    // cast contact shadow so it never gets stamped on top of the ice. Mirrors gsGroundY's toroidal
    // XZ wrap and y-origin handling, scanning UP instead of down. Starts one cell above startY so
    // the creature's own foot cell (or the surface it rests on) is not counted as a ceiling.
    static bool gsSolidAbove(texture3d<uint, access::read> occ,
                             float3 gridOrigin, float3 gridDims,
                             float wx, float startY, float wz, int span) {
        int3 dims = int3(gridDims);
        int3 iorigin = int3(round(gridOrigin));
        int gx = int(floor(wx)) & (dims.x - 1);
        int gz = int(floor(wz)) & (dims.z - 1);
        int wy0 = int(floor(startY)) - iorigin.y;
        for (int dyi = 1; dyi <= span; ++dyi) {
            int vy = wy0 + dyi;
            if (vy < 0 || vy >= dims.y) continue;
            if (occ.read(uint3(uint(gx), uint(vy), uint(gz))).r != 0u) {
                return true;
            }
        }
        return false;
    }

    vertex GSOut groundShadowV(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               constant GShadowU& u [[buffer(0)]],
                               device const GShadowInst* insts [[buffer(1)]],
                               texture3d<uint, access::read> occ [[texture(0)]]) {
        GShadowInst e = insts[iid];
        float3 foot = e.footRadius.xyz;
        float r = e.footRadius.w;
        // #139 Bug B: a creature swimming UNDER a solid ceiling (fish under ice) must not stamp a
        // contact blob on top of that ceiling. If any solid voxel sits within a few cells ABOVE the
        // feet, the creature is submerged/under cover; collapse the quad to a degenerate point so it
        // is clipped with zero fragment work. Cheapest correct rule, no entity ABI change needed.
        if (gsSolidAbove(occ, u.voxOrigin.xyz, u.voxDims.xyz, foot.x, foot.y, foot.z, 4)) {
            GSOut o;
            o.position  = float4(0.0, 0.0, 0.0, 0.0);   // degenerate: clipped, never rasterized
            o.worldPos  = foot;
            o.center    = foot;
            o.radius    = r;
            o.sunGround = float2(0.0, 1.0);
            o.dayFactor = 0.0;                          // also gates the fragment off if it slips through
            return o;
        }
        // Snap the blob's plane to the real surface directly under the feet (search a couple blocks
        // up and down so it lands on the ground even if foot.y is slightly embedded or floating).
        float snapped = gsGroundY(occ, u.voxOrigin.xyz, u.voxDims.xyz, foot.x, foot.y + 2.0, foot.z, 6);

        // #150 snow-walk case (follow-up to #139). Fresh snow (#118) is a thin walk-through overlay:
        // the snow cell sits ON TOP of a surface block and casts in occupancy, but the engine seats
        // the creature on the block UNDER the snow, so foot.y = top of that block = BOTTOM of the
        // snow blanket. The blanket renders as a slab SNOW_LAYER tall (6/16, mirroring
        // emit_snow_layer's top=6 in mesher.rs) from foot.y up to foot.y + SNOW_LAYER. Because snow
        // casts in occupancy, the downward snap finds the snow cell TOP and overshoots a full block
        // above the feet (snapped is about foot.y + 1). That full-block overshoot ONLY happens for
        // walk-through snow, so it is our in-shader detector: when snapped lands ~1 block above the
        // feet, the creature stands on snow and the blob must sit on the VISIBLE snow SURFACE
        // (foot.y + SNOW_LAYER), not buried at foot.y (the #139 over-clamp, hidden under the opaque
        // slab) and not floating at the snap (foot.y + 1, the original #139 bug).
        const float SNOW_LAYER = 6.0 / 16.0;   // 0.375, mirrors emit_snow_layer top=6 (mesher.rs)
        float planeY;
        if (snapped > -1e8) {
            // Snow overshoot: snap sits roughly a full block (~1.0) above the feet. Use a tolerant
            // window (0.5 .. 1.5) so only the walk-through-snow full-cell overshoot qualifies; real
            // surfaces (slopes, flat ground) snap at or below foot.y and fall through to the clamp.
            float rise = snapped - foot.y;
            if (rise > 0.5 && rise < 1.5) {
                // Stand the blob just above the snow surface (tiny epsilon so it is not buried in or
                // z-fighting the opaque snow slab).
                planeY = foot.y + SNOW_LAYER + 0.01;
            } else {
                // #139 Bug A bare/sloped ground: clamp so the plane never rises above the feet (the
                // surface a creature rests on cannot be above it). Unchanged from #139.
                planeY = min(snapped, foot.y + 0.05);
            }
        } else {
            planeY = foot.y;
        }

        // Sun direction projected onto the ground (XZ). The shadow stretches AWAY from the sun
        // azimuth and the lower the sun the longer/more offset it gets.
        float3 sunDir = u.sunDirTime.xyz;           // points FROM sun (downward when sun up)
        float2 toLight = -sunDir.xz;                 // horizontal direction toward the sun
        float  tl = length(toLight);
        float2 sunGround = (tl > 1e-4) ? (toLight / tl) : float2(0.0, 1.0);
        // sunHeight: 1 = straight overhead, ~0 = on the horizon.
        float sunHeight = clamp(-sunDir.y, 0.0, 1.0);
        // Stretch factor: tight (1x) high sun, up to ~3.2x near the horizon. Offset distance grows
        // as the sun drops so the blob slides out from under the feet.
        float lowness = 1.0 - sunHeight;
        float stretch = 1.0 + lowness * lowness * 1.7;   // up to ~2.7x at the horizon
        float offset  = lowness * r * 1.7;               // world-units the blob slides away from the sun

        // Build a generous quad in the ground plane large enough to contain the stretched, offset
        // blob. Local axes: X = perpendicular to sun azimuth, Y(in-plane) = along the sun azimuth.
        float2 ax = float2(-sunGround.y, sunGround.x); // perpendicular
        float2 ay = sunGround;                          // along sun-to-ground
        float halfPerp = r * 1.6;
        float halfLong = r * 1.6 * stretch + offset + r;
        // Quad corners (two triangles). vid 0..5.
        float2 quad[6] = { float2(-1,-1), float2( 1,-1), float2( 1, 1),
                           float2(-1,-1), float2( 1, 1), float2(-1, 1) };
        float2 q = quad[vid];
        // Map unit quad to (perp * half, along * halfLong) and recenter so the blob (offset along
        // -sunGround) stays inside. We push the quad center away from the sun by `offset`.
        float2 centerXZ = foot.xz - sunGround * offset;
        float2 worldXZ = centerXZ + ax * (q.x * halfPerp) + ay * (q.y * halfLong);

        GSOut o;
        // Sit just above the snapped surface so it never z-fights the ground or gets buried.
        float3 wpos = float3(worldXZ.x, planeY + 0.04, worldXZ.y);
        o.position  = u.viewProj * float4(wpos, 1.0);
        o.worldPos  = wpos;
        o.center    = float3(foot.x, planeY, foot.z);
        o.radius    = r;
        o.sunGround = sunGround;
        // Pass the stretch/offset packed via radius-relative values the fragment recomputes; simpler
        // to recompute in-frag from sunGround + sun height which we encode in dayFactor's sign-free
        // companion. Recompute here once and stash stretch in center is messy; instead recompute in
        // frag from u (it has sunDirTime). dayFactor (daylight gate) computed here:
        o.dayFactor = clamp(sunHeight * 2.2, 0.0, 1.0);
        return o;
    }

    fragment float4 groundShadowF(GSOut in [[stage_in]],
                                  constant GShadowU& u [[buffer(0)]],
                                  texture3d<uint, access::read> occ      [[texture(0)]],
                                  texture3d<uint, access::read> occCoarse [[texture(1)]]) {
        if (in.dayFactor <= 0.001) discard_fragment();   // night: no contact shadow, no wash

        float3 sunDir = u.sunDirTime.xyz;
        float sunHeight = clamp(-sunDir.y, 0.0, 1.0);
        float lowness = 1.0 - sunHeight;
        float stretch = 1.0 + lowness * lowness * 1.7;   // MUST match groundShadowV
        float offset  = lowness * in.radius * 1.7;       // MUST match groundShadowV

        // Position relative to the entity's foot, in the ground plane (XZ).
        float2 rel = in.worldPos.xz - in.center.xz;
        // Decompose along/perp to the sun azimuth.
        float2 sg = in.sunGround;
        float2 perpAxis = float2(-sg.y, sg.x);
        float along = dot(rel, -sg);     // positive = away from the sun (where the shadow lies)
        float perp  = dot(rel, perpAxis);

        // Shift the ellipse center out from the feet along -sun by `offset`, then test an ellipse
        // whose long axis (along) is `stretch`-times the footprint radius.
        float a = (along - offset) / (in.radius * stretch);
        float b = perp / in.radius;
        float d = sqrt(a * a + b * b);   // 0 at blob center, 1 at the soft edge

        // Soft-edged blob: opaque core, smooth falloff to 0 at the rim. Slightly darker core.
        float blob = 1.0 - smoothstep(0.45, 1.0, d);
        if (blob <= 0.001) discard_fragment();

        // Cliff fade: if the real ground under THIS pixel is far BELOW the blob's plane (the blob
        // overhangs a ledge/edge into open air), fade it so it never floats. When no casting voxel
        // is found at all (e.g. surfaces the occupancy grid does not flag, or thin terrain) we keep
        // the blob: the vertex already snapped the plane to the surface, so it is grounded.
        float surfY = gsGroundY(occ, u.voxOrigin.xyz, u.voxDims.xyz,
                                in.worldPos.x, in.center.y + 1.5, in.worldPos.z, 5);
        if (surfY > -1e8) {
            float gap = abs(in.center.y - surfY);
            blob *= 1.0 - smoothstep(1.5, 3.0, gap);
        }

        // Darkness: a soft contact shadow. Fades with daylight; clamped so it never blows to black.
        float strength = 0.6 * in.dayFactor;
        float alpha = blob * strength;
        if (alpha <= 0.002) discard_fragment();
        // Source color black; alpha-over blend multiplies the ground toward dark.
        return float4(0.0, 0.0, 0.0, alpha);
    }
    """
}
