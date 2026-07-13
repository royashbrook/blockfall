import MetalKit

extension Renderer {
    // MARK: - Shaders (MSL, runtime compiled)
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // =========================================================
    // TERRAIN STRUCTS & HELPERS
    // =========================================================

    // PackedVertex: same layout as the C++ BFVertex.
    //   pos    : low 6 bits of voxel coord (x/y/z), plus 4-bit sub-cell fractions.
    //   reserved bits 0/1/2 carry coordinate bit 6 for wide chunk edge vertices.
    //   normuv : bits [0..2]=face normal (0-5),  bits [3..5]=AO (0..3), bits [6+]=UV hints
    //   material, sky, block, reserved as before.
    struct PackedVertex {
        uint     pos;
        uint     normuv;
        ushort   material;
        uchar    sky;
        uchar    block;
        uint     reserved;
    };

    // Terrain uniforms: must EXACTLY match Swift Uniforms struct (176 bytes).
    //   viewProj (64), chunkOrigin (16), sunDirTime (16), lightViewProj (64), dimSatN (16)
    struct Uniforms {
        float4x4 viewProj;
        float4   chunkOrigin;   // xyz=origin, w=dim_saturation (min corner)
        float4   sunDirTime;    // xyz=sun_dir, w=time_of_day
        float4x4 lightViewProj; // sun shadow matrix (near cascade)
        float4   dimSatN;       // x=+X corner, y=+Z, z=+XZ saturation (grey bilerp)
        float4x4 lightViewProjF; // far cascade (#46)
    };

    // WaterUniforms (96 bytes) — not engine-filled. Must EXACTLY match Swift.
    struct WaterUniforms {
        float wallClockSecs;
        float underwater;
        float reflectScale;  // #: water-reflection toggle (0=off)
        float shadowScale;   // #: cast-shadow toggle (0=off, 2=harness shadow-factor debug)
        float4 cameraPosW;   // xyz = world pos, w = pad
        float4 sunDirTime;   // xyz = sun dir, w = time_of_day (#43)
        float celShade;      // #130 toon-band the diffuse term (0=off, 1=on)
        float cloudsOn;      // #47 volumetric cloud toggle (sky pass)
        float pbrStr;        // #47 stylized PBR specular strength (terrain pass)
        float weatherPack;   // #162 precip mode (0/1/2) * 2 + cloud coverage * 0.98
        // World-space voxel sun shadows (replaces the cascaded shadow map).
        float4 voxOrigin;    // xyz = grid origin (world block coords), w = march distance
        float4 voxDims;      // xyz = grid dims (voxels), w = soft-shadow flag (0=hard,1=soft)
    };
    #define UW_CAM_POS(wu) (wu).cameraPosW.xyz

    // ---- Shared water palette (keeps every water-related path consistent) ----
    // One source of truth so the translucent surface, the submerged-solid depth
    // tint and the full-screen underwater overlay all read as the SAME body of
    // water. Kept bright/aqua (no near-black murk) per the kid-friendly look.
    //   WATER_SURFACE_COL : base albedo of the water surface (top + sides)
    //   WATER_FOG_COL      : colour distant submerged solids fade toward, and the
    //                        colour of the full-screen underwater overlay. Same
    //                        value in both places so entering/looking around is smooth.
    constant float3 WATER_SURFACE_COL = float3(0.11, 0.38, 0.78);
    constant float3 WATER_FOG_COL     = float3(0.10, 0.34, 0.62);

    // PostUniforms (52 bytes) — composite pass.
    // >0 rainStrength = rain, <0 = snow, 0 = clear.
    struct PostUniforms {
        float bloomStrength;
        float vignetteStr;
        float satBoost;
        float rainStrength;
        float wallClockSecs;
        float godrayStrength;   // #44
        float sunScreenX;
        float sunScreenY;
        float sunColorR;
        float sunColorG;
        float sunColorB;
        float greyHaze;   // #: The-Grey screen wash
        float celShade;   // #130 1 = draw ink outlines + cel grade
        float lensFlareStr; // #132 lens-flare master strength (0 = off)
        float celOutlineStr; // #136 cel ink-outline intensity (0..1) scaling CEL_OUTLINE_DARK
    };

    // VolUniforms (240 bytes) — #119 radial screen-depth god rays, composite buffer(1).
    // Must EXACTLY match the Swift VolUniforms struct.
    struct VolUniforms {
        float4x4 invViewProj;    // clip -> world
        float4   voxOrigin;      // reserved legacy fields
        float4   voxDims;        // xyz reserved, w = projected sun UV.y
        float4   camPosW;        // xyz = camera world pos, w = projected sun UV.x
        float4   sunDir;         // xyz = sun dir (downward), w unused
        float4   sunColor;       // rgb = sun colour, w = volumetric strength (0 = off)
    };

    // (ShadowVertUniforms retired with the shadow-map render pass.)

    // WindUniforms (32 bytes): foliage sway + weather.  buffer(3) on vertex AND frag.
    struct WindUniforms {
        float wallClockSecs;
        float rainStrength;   // 0..1
        float swayScale;      // #: foliage-sway toggle (0=off)
        float pad1;
        float4 camPosH;       // #180 horizon curvature: xyz = cam world pos, w = enable (0 = flat)
    };

    // =========================================================
    // #180 HORIZON CURVATURE (render-only, phase 2 of the looping-world epic #173)
    // ---------------------------------------------------------
    // The world is a 32768-block torus (#179). To make it READ as a round little
    // planet, every world-space vertex is dropped by k * d^2 (d = horizontal
    // distance to the camera, k = 1 / (2 * R), R baked from Renderer.kHorizonRadius
    // / BF_HORIZON at library compile). PURELY VISUAL displacement at rasterization:
    // fog distances, the world-space voxel sun-shadow march and every out.worldPos
    // stay on the FLAT world, so world-fixed shadows remain camera-invariant.
    // camH.w gates per pass (0 = flat); default-built uniforms render flat.
    // =========================================================
    constant float BF_HORIZON_K = \(Renderer.horizonKLiteral);

    // World wrap period (engine WORLD_PERIOD, #179): geometry can be emitted at a far
    // toroidal image (x or z offset by 32768), so the camera delta must be wrapped to
    // the NEAREST image before the d^2 drop, or a far-image chunk gets an astronomic
    // drop and its triangles smear across the whole frame.
    constant float BF_HORIZON_PERIOD = 32768.0;
    // Cap d^2 at 600 blocks (beyond the 384-block render edge and the 512 far plane).
    // Resident-but-out-of-range chunks (eviction lag, flyover residue) are invisible
    // when flat (beyond the far plane); an unbounded d^2 drop would plunge them
    // thousands of blocks and stretch their triangles THROUGH the view volume as a
    // full-screen smear. Capping keeps their drop bounded so they stay clipped, while
    // everything inside the render distance is untouched (384^2 < the cap).
    constant float BF_HORIZON_D2CAP = 600.0 * 600.0;

    static float3 horizonBend(float3 world, float4 camH) {
        float2 d = world.xz - camH.xz;
        d -= BF_HORIZON_PERIOD * rint(d / BF_HORIZON_PERIOD);   // nearest toroidal image
        world.y -= BF_HORIZON_K * camH.w * min(dot(d, d), BF_HORIZON_D2CAP);
        return world;
    }

    // #230 T-junction weld: the raw k*d^2 drop above is QUADRATIC in xz, but the
    // rasterizer interpolates a long greedy quad's edge LINEARLY between its two
    // endpoints. A smaller neighbour quad places a real vertex partway along that
    // shared edge and samples the true curve there, so the surfaces disagree by
    // the parabola's sagitta (k*L^2/4, ~0.005 blocks on a 16-run) — a pixel-wide
    // crack that the cel ink pass reads as a huge depth discontinuity (#219's
    // dots/dashes). Terrain therefore samples the drop from a per-chunk BILINEAR
    // patch instead: evaluate the paraboloid only at the chunk's 4 xz corners and
    // lerp. A bilinear field restricted to any axis-aligned edge IS linear, so
    // every t-vertex lands exactly on the long edge's interpolated position, and
    // adjacent chunks agree on shared corners (same world corner, same drop).
    // Terrain quads are all axis-aligned, so this welds every seam with zero
    // extra vertices and greedy merging untouched.
    static float horizonDropAt(float2 cornerXZ, float2 camXZ) {
        float2 d = cornerXZ - camXZ;
        d -= BF_HORIZON_PERIOD * rint(d / BF_HORIZON_PERIOD);
        return BF_HORIZON_K * min(dot(d, d), BF_HORIZON_D2CAP);
    }

    // Vertex output for terrain pass.
    struct VOut {
        float4 position  [[position]];
        float3 color;
        float  shade;
        float  sat;
        float3 worldPos;
        uint   faceNorm  [[flat]];
        uint   material  [[flat]];
        float  lod       [[flat]];
        float  ao;               // 0=fully occluded, 1=fully open (from bits [3:5])
    };

    // AmbientSprite: 32 bytes, matches Swift AmbientSpritePod.
    struct AmbientSprite {
        float4 posW;    // xyz=world pos; w=bird world radius or tiny-mote size
        float4 color;   // rgb=HDR colour (>1 ok), a=alpha
    };

    // AmbientLifeUniforms: matches Swift AmbientLifeUniforms.
    struct AmbientLifeUniforms {
        float4x4 viewProj;   // 64 bytes
        float4   camPosW;    // 16 bytes
        float    timeOfDay;
        float    wallClock;
        float    horizonOn;  // #180 horizon curvature enable (0 = flat)
        float    aspect;
    };

    // PrecipParticle: 16 bytes, matches Swift PrecipParticlePod.
    struct PrecipParticle {
        float4 seed;   // xyz = offset within box [-0.5..0.5]^3, w = phase 0..1
    };

    // PrecipUniforms: 96 bytes, matches Swift PrecipUniforms.
    struct PrecipUniforms {
        float4x4 viewProj;   // 64 bytes
        float4   camPosW;    // 16 bytes — xyz world cam pos
        float    wallClock;  // animation time (seconds)
        float    mode;       // 1=rain, 2=snow
        float    boxSize;    // full edge length of spawn volume (world units)
        float    pad0;
    };

    // =========================================================
    // LIGHT / SHADE HELPERS
    // =========================================================

    static float faceShade(uint n) {
        if (n == 2u) return 1.0;    // top
        if (n == 3u) return 0.40;   // bottom
        return 0.62;                // sides (wider top/side spread = more depth)
    }

    // Day/night light level (0 = full night, 1 = full day) from the sun's actual
    // elevation. Mirrors Renderer.dayLight on the Swift side — see the long comment
    // there for the night-washout fix this replaces. The old sin(t*pi) term kept the
    // world bright through the whole night (a quarter-cycle out of phase with the sun
    // arc), so night read as a flat washed-out scene; this tracks the real sun.
    static float dayLight(float t) {
        float ang = t * 6.2831853f;
        float dx = cos(ang) * 0.6f, dy = -sin(ang) - 0.25f, dz = 0.90f;
        float elev = -dy * rsqrt(dx*dx + dy*dy + dz*dz);
        return smoothstep(-0.12f, 0.25f, elev);
    }

    static float3 hashColor(uint m) {
        float h = fract(float(m) * 0.6180339887f);
        float3 k = float3(1.0, 2.0/3.0, 1.0/3.0);
        float3 p = abs(fract(float3(h,h,h) + k) * 6.0 - 3.0);
        return clamp(p - 1.0, 0.0, 1.0) * 0.5 + 0.4;
    }

    // Full per-block colour table (ids 1-40).
    //
    // #51 milestone 4: a deliberate, COHESIVE bold-toy palette tuned as one family
    // rather than ad-hoc per-block hues. The look it has to sit under is the cel grade
    // (#130: 4-band toon lighting + ink outlines), which crushes mids and bands the
    // shading, so washy pastel bases drained to a flat sameness (water read like snow,
    // stone like sand). The retune gives the family a consistent saturation/value
    // language so it reads as Blockfall's own art style:
    //   * naturals (grass, sand, stone, water, leaves) get a clear saturation lift and
    //     are pulled apart in VALUE so each material owns a band under the toon ramp;
    //   * each block still reads instantly as itself and stays cheerful/kid-friendly;
    //   * whites (snow, glass, wool) keep a faint cool/warm tint so they never read as
    //     the same flat white and so snow separates from the pale water reflection.
    // Bases are kept a touch below full so the cel highlight band has room to pop and
    // the bright sun-facing faces do not clip.
    static float3 materialColor(uint m) {
        switch (m) {
            // ---- GROUND naturals: the screen-filling family, value-separated --------
            case  1u: return float3(0.34, 0.72, 0.26);   // grass: punchy spring green, high sat
            case  2u: return float3(0.52, 0.35, 0.20);   // dirt: warm chocolate, sits darker than sand
            case  3u: return float3(0.50, 0.51, 0.56);   // stone: cool neutral grey, slight blue lean
            case  6u: return float3(0.88, 0.76, 0.44);   // sand: warm golden tan, clearly warmer/brighter than stone
            case 11u: return float3(0.52, 0.50, 0.47);   // gravel: warm grey, between stone and dirt
            case 14u: return float3(0.58, 0.66, 0.74);   // clay: cool blue-grey, distinct from stone
            // ---- WATER ----------------------------------------------------------------
            case  9u: return float3(0.10, 0.40, 0.85);   // water: deep saturated cerulean (submerged base)
            // ---- SNOW / ICE: cool whites, not flat white ------------------------------
            case 12u: return float3(0.95, 0.97, 1.00);   // snow: bright with a whisper of blue
            case 54u: return float3(0.64, 0.70, 0.82);   // trodden snow (#117): compressed print, clearly dimmer cool grey-blue so the trail reads against fresh snow
            case 55u: return float3(0.72, 0.48, 0.94);   // warp totem (#182): lavender crystal pillar, matches its light and map icon
            case 13u: return float3(0.66, 0.84, 1.00);   // ice: clean glacial blue, more saturated than snow
            // ---- DARK / DIM terrain ---------------------------------------------------
            case 15u: return float3(0.26, 0.23, 0.34);   // dim stone: deep cool violet-grey
            case 16u: return float3(0.30, 0.21, 0.16);   // dim dirt: deep umber
            // ---- WOOD family: a coherent warm-brown ladder ----------------------------
            case  4u: return float3(0.74, 0.53, 0.28);   // oak planks: warm honey
            case 21u: return float3(0.47, 0.31, 0.16);   // oak log: rich dark bark
            case 22u: return float3(0.83, 0.80, 0.68);   // birch log: pale cream bark
            case 23u: return float3(0.84, 0.74, 0.52);   // birch planks: light sandy wood
            case 49u: return float3(0.40, 0.25, 0.15);   // pine log: dark reddish bark
            // ---- LEAVES: greens pushed apart from grass so canopy reads distinct -------
            case  5u: return float3(0.26, 0.58, 0.22);   // oak leaves: deep forest green
            case 27u: return float3(0.52, 0.78, 0.30);   // birch leaves: bright lime
            case 48u: return float3(0.18, 0.42, 0.24);   // pine needles: dark blue-green
            // ---- WORKED STONE / BRICK -------------------------------------------------
            case  8u: return float3(0.56, 0.57, 0.62);   // stone brick: slightly lighter/cooler than raw stone
            case 10u: return float3(0.42, 0.43, 0.46);   // cobblestone: darker grey so it separates from stone
            case 24u: return float3(0.78, 0.36, 0.26);   // clay brick: warm terracotta red
            case 29u: return float3(0.40, 0.54, 0.34);   // mossy stone: grey-green
            // ---- ORES: each owns a vivid hue against the grey stone matrix -------------
            case 17u: return float3(0.32, 0.33, 0.37);   // coal ore: dark charcoal grey
            case 18u: return float3(0.78, 0.46, 0.26);   // copper ore: warm orange-bronze
            case 19u: return float3(0.62, 0.60, 0.55);   // iron ore: pale tan-grey
            case 20u: return float3(0.55, 0.40, 0.82);   // crystal ore: vivid amethyst purple
            // ---- GLASS / WOOL / GLOW --------------------------------------------------
            case 25u: return float3(0.74, 0.92, 1.00);   // glass: cool pale tint
            case 26u: return float3(0.24, 0.82, 0.74);   // coloured glass: bold teal
            case 28u: return float3(0.95, 0.93, 0.88);   // wool: warm soft white
            case  7u: return float3(1.00, 0.92, 0.42);   // glow block: warm lamp yellow
            // ---- FUNCTIONAL props -----------------------------------------------------
            case 30u: return float3(0.62, 0.42, 0.20);   // crafting table: warm worked wood
            case 31u: return float3(0.78, 0.58, 0.26);   // chest: golden oak
            case 32u: return float3(1.00, 0.68, 0.16);   // torch: hot ember orange
            case 33u: return float3(0.66, 0.46, 0.24);   // oak door: medium wood
            case 34u: return float3(0.52, 0.95, 0.98);   // beacon: glowing cyan
            case 35u: return float3(0.80, 0.66, 1.00);   // crystal lamp: soft lilac
            case 52u: return float3(0.78, 0.20, 0.25);   // bed quilt: warm storybook red
            case 53u: return float3(0.30, 0.32, 0.36);   // iron gate (#95): dark cool iron
            // ---- DECOR accents: kept vivid and saturated ------------------------------
            case 36u: return float3(0.96, 0.20, 0.20);   // red flower
            case 37u: return float3(1.00, 0.88, 0.12);   // yellow flower
            case 38u: return float3(0.42, 0.76, 0.24);   // tall grass: matches grass family
            case 39u: return float3(0.60, 0.38, 0.22);   // mushroom block
            case 40u: return float3(0.98, 0.46, 0.90);   // colour crystal: candy pink
            default:  return hashColor(m);
        }
    }

    // =========================================================
    // PROCEDURAL TEXTURE HELPERS
    // =========================================================

    static float uhash(uint v) {
        v ^= v >> 17u; v *= 0xbf324c81u;
        v ^= v >> 11u; v *= 0x9f34a21du;
        v ^= v >> 16u;
        return float(v) * (1.0 / 4294967296.0);
    }
    static float voxelHash(int3 vi) {
        uint h = (uint(vi.x) * 73856093u) ^ (uint(vi.y) * 19349663u) ^ (uint(vi.z) * 83492791u);
        return uhash(h);
    }
    static float noise2(float2 p) {
        int2 i = int2(floor(p));
        float2 f = fract(p);
        float2 u = f*f*(3.0 - 2.0*f);
        float a = uhash(uint(i.x) + uint(i.y)*57u);
        float b = uhash(uint(i.x+1) + uint(i.y)*57u);
        float c = uhash(uint(i.x) + uint(i.y+1)*57u);
        float d = uhash(uint(i.x+1) + uint(i.y+1)*57u);
        return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
    }
    static float fbm2(float2 p) {
        return noise2(p)*0.60 + noise2(p*2.1+float2(3.7,1.1))*0.30 + noise2(p*4.3+float2(1.3,5.7))*0.10;
    }
    // #133/#134 stylized surface detail. A single low-frequency value-noise sample,
    // gently contrast-shaped so the variation reads as broad painterly patches rather
    // than fine speckle. ONE noise2 (four hashes) per call, no extra octaves and no
    // Voronoi loop, so it is far cheaper than the old fbm + 9-tap cellular pattern and
    // sits cleanly under the bold cel outlines and toon banding. Caller scales p to set
    // the patch size (lower scale = larger, calmer patches).
    static float smoothDetail(float2 p) {
        float n = noise2(p);
        // Soft S-curve: pushes the mid values apart a touch so patches have shape, while
        // keeping the extremes gentle (no harsh light/dark speckle).
        return n * n * (3.0 - 2.0 * n);
    }
    // Project world pos to 2D UV by dominant face axis (face 0/1=YZ, 2/3=XZ, 4/5=XY)
    static float2 faceUV(float3 wp, uint face) {
        if (face == 0u || face == 1u) return wp.yz;
        if (face == 2u || face == 3u) return wp.xz;
        return wp.xy;
    }

    // Cheap 2D Voronoi: returns distance to nearest cell centre (3x3 neighborhood).
    // p is already in "cell" coordinates (scale before calling).
    // Returns float2(distToNearest, distToSecondNearest) so caller can compute edge dist.
    static float2 voronoi2(float2 p) {
        int2 ip = int2(floor(p));
        float2 fp = fract(p);
        float d0 = 1e9, d1 = 1e9;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int2 nb = ip + int2(dx, dy);
                // jitter cell centre
                uint hx = uint(nb.x) * 1664525u + uint(nb.y) * 1013904223u;
                float jx = uhash(hx)         * 0.8 + 0.1;
                float jy = uhash(hx ^ 987u)  * 0.8 + 0.1;
                float2 diff = float2(float(dx) + jx, float(dy) + jy) - fp;
                float dist = dot(diff, diff);   // squared dist, fine for comparison
                if (dist < d0) { d1 = d0; d0 = dist; }
                else if (dist < d1) { d1 = dist; }
            }
        }
        return float2(sqrt(d0), sqrt(d1));
    }

    // Returns 0 near cell edges, 1 at cell centres.  edgeWidth in [0,1] (pre-sqrt scale).
    static float voronoiCell(float2 p, float scale) {
        float2 d = voronoi2(p * scale);
        float edge = d.y - d.x;         // wide in open areas, narrow at edges
        return smoothstep(0.0, 0.15, edge);
    }

    // ---- Per-material surface texture: returns float3 colour multiplier -------
    // Range roughly 0.78 .. 1.22.  Modulates base colour via multiply in fmain.
    // face: 2=top, 3=bottom, 0/1/4/5=sides.  worldPos is continuous across quads.
    static float3 blockDetail(float3 worldPos, uint face, uint matID) {
        float2 uv   = faceUV(worldPos, face);
        bool isTop  = (face == 2u);
        bool isBot  = (face == 3u);
        bool isSide = !isTop && !isBot;

        // Per-voxel random seed (adds block-level variation so adjacent blocks differ)
        int3  vi    = int3(floor(worldPos));
        float vH    = voxelHash(vi);                        // 0..1

        // ---- STONE / COBBLESTONE / ORES  (3,10,8,29,17-20) --------------------
        // #133 stylized rework: the natural terrain materials (the blocks that fill
        // most of the screen) used 2-3 octaves of value noise plus a 9-tap Voronoi
        // loop each, which read grainy/busy under the flat cel palette and cost a lot
        // of fragment instructions (#134). They now use one low-frequency smooth term
        // (calmer, painterly mottling) plus, where a block needs structure, ONE more
        // cheap term. No Voronoi loop, no high-frequency speckle. The per-voxel hash
        // (vH) still shifts each block so adjacent blocks differ.
        //
        // Stone (3): low-frequency grey mottling, soft, no crack net.
        if (matID == 3u) {
            float mot = smoothDetail(uv * 2.6 + float2(vH * 3.0, vH * 2.1));
            float bri = mix(0.86, 1.14, mot);
            return float3(clamp(bri, 0.80, 1.16));
        }

        // Cobblestone (10): broad rounded patches (low-freq) read as cobbles without
        // the per-pixel Voronoi pebble loop.
        if (matID == 10u) {
            float patch = smoothDetail(uv * 3.2 + float2(vH * 2.0, vH * 1.5));
            float bri   = mix(0.80, 1.12, patch) + (isTop ? 0.04 : 0.0);
            return float3(clamp(bri, 0.74, 1.16));
        }

        // Ores (17-20, 29): smooth stone base + a soft mineral vein in the ore hue
        // (low-freq band instead of high-freq speckle dots).
        if (matID==17u||matID==18u||matID==19u||matID==20u||matID==29u) {
            float mot   = smoothDetail(uv * 2.8 + float2(vH * 2.5, vH * 1.9));
            float stBase = mix(0.84, 1.14, mot);
            // Soft vein: a second low-freq term, thresholded gently into a vein region.
            float vein  = smoothstep(0.62, 0.80, smoothDetail(uv * 4.0 + float2(vH * 5.0, 1.3)));
            // Each ore gets a distinct hue push on the vein. Hues match the actual
            // content ores (#51 palette pass): coal/copper/iron/crystal, not the old
            // mislabeled silver/gold/emerald set.
            float3 oreHue;
            if      (matID == 17u) oreHue = float3(0.32, 0.32, 0.36);  // coal: dark charcoal flecks
            else if (matID == 18u) oreHue = float3(0.95, 0.55, 0.28);  // copper: warm orange-bronze
            else if (matID == 19u) oreHue = float3(0.80, 0.74, 0.62);  // iron: pale warm metal
            else if (matID == 20u) oreHue = float3(0.70, 0.45, 1.05);  // crystal: vivid amethyst
            else                   oreHue = float3(0.45, 0.85, 0.45);  // mossy stone (29)
            float3 col = float3(clamp(stBase, 0.80, 1.16));
            col = mix(col, col * oreHue * 1.30, vein * 0.55);
            return clamp(col, 0.76, 1.26);
        }

        // Mossy / decorated stone (15,16): soft organic overgrowth blotches.
        if (matID==15u||matID==16u) {
            float blotch = smoothDetail(uv * 2.8 + float2(vH * 2.0, vH * 1.5));
            float bri    = mix(0.82, 1.18, blotch);
            float mossy  = clamp(1.0 - blotch, 0.0, 0.6) * 0.28;
            float3 col   = float3(clamp(bri, 0.80, 1.16));
            col.g       += mossy;
            return clamp(col, 0.78, 1.22);
        }

        // ---- DIRT / GRAVEL / CLAY  (2, 11, 14) --------------------------------
        if (matID==2u||matID==11u||matID==14u) {
            // Soft coarse clumping, no fine grit / pebble speckle.
            float coarse = smoothDetail(uv * 2.4 + float2(vH * 1.5, 0.7));
            float bri    = mix(0.84, 1.12, coarse);
            // Clay (14) gets a slight blue-grey desaturation
            if (matID == 14u) {
                return clamp(float3(bri, bri, bri * 1.04), 0.80, 1.16);
            }
            return float3(clamp(bri, 0.80, 1.16));
        }

        // ---- GRASS  (1) -------------------------------------------------------
        if (matID == 1u) {
            if (isTop) {
                // Soft clumpy grass patches with a gentle green/yellow hue drift.
                // One low-freq term for brightness, the same term reused for hue
                // (no separate high-freq blade noise).
                // #51: calmer brightness range so the bold green base carries the look,
                // with the patch term steered into a clean green/yellow hue drift instead
                // of a grey light/dark wash (keeps the toy palette saturated, not muddy).
                float patch = smoothDetail(uv * 2.6 + float2(vH * 3.0, 0.9));
                float bri   = mix(0.90, 1.12, patch);
                float hue   = (patch - 0.5) * 0.16;   // lighter patches warm toward lime
                float3 col  = float3(bri + hue * 0.06, bri + hue * 0.02, bri - hue * 0.06);
                return clamp(col, 0.82, 1.18);
            } else {
                // Side: smooth dirt base with a grassy fringe at the top edge.
                float dirt = smoothDetail(uv * 2.6 + float2(vH * 1.5, 0.7));
                float bri  = mix(0.84, 1.12, dirt);
                float localY = fract(worldPos.y);   // 0=bottom of block, 1=top
                float fringe = smoothstep(0.70, 0.95, localY);
                float3 col   = float3(bri);
                col.g += fringe * 0.18;
                col.r -= fringe * 0.08;
                col.b -= fringe * 0.04;
                return clamp(col, 0.80, 1.20);
            }
        }

        // ---- SAND  (6) --------------------------------------------------------
        if (matID == 6u) {
            // Calm dune ripples (one sine band) over a soft low-freq tone. Cheaper
            // than the prior two-sine + two-noise grain and reads cleaner.
            // #51: tighter brightness range so the bold golden tan stays bold and clean;
            // ripples weighted lower than tone so dunes read as a calm hint, not stripes.
            float ripple = sin((uv.x * 0.95 + uv.y * 0.30) * 9.0) * 0.5 + 0.5;
            float tone   = smoothDetail(uv * 2.2 + float2(vH * 4.0, 1.7));
            float bri    = mix(0.90, 1.10, ripple * 0.4 + tone * 0.6);
            return float3(clamp(bri, 0.86, 1.12));
        }

        // ---- WOOD LOGS  (21, 22) ----------------------------------------------
        if (matID==21u||matID==22u) {
            if (isTop || isBot) {
                // End grain: concentric rings centred on block centre
                float2 ctr  = fract(worldPos.xz) - 0.5;   // -0.5..0.5 relative to block
                float  r    = length(ctr);
                // Ring spacing ~0.18 world units; noise wobbles the rings
                float wobble = (noise2(ctr * 5.0 + float2(vH * 2.0, 1.1)) - 0.5) * 0.06;
                float rings  = sin((r + wobble) * 28.0) * 0.5 + 0.5;
                float grain  = noise2(uv * 14.0 + float2(vH * 3.0, 2.1)) * 0.25;
                float bri    = mix(0.82, 1.18, rings * 0.65 + grain * 0.35);
                return float3(clamp(bri, 0.80, 1.18));
            } else {
                // Side faces: vertical grain lines
                float2 grainUV = float2(uv.x, worldPos.y);   // isolate X-axis for grain
                float stripe = sin(grainUV.x * 22.0) * 0.5 + 0.5;
                float vein   = noise2(float2(grainUV.x * 5.5, grainUV.y * 2.5 + vH * 3.0));
                float knot   = (1.0 - smoothstep(0.05, 0.25, abs(noise2(grainUV * float2(2.0, 0.5) + vH) - 0.5)))
                               * 0.15;
                float bri    = mix(0.84, 1.16, stripe * 0.40 + vein * 0.60) + knot;
                return float3(clamp(bri, 0.80, 1.18));
            }
        }

        // ---- PLANKS  (4, 23) --------------------------------------------------
        if (matID==4u||matID==23u) {
            // Plank seams: vertical lines every 0.33 units on sides, horizontal on top
            float plankU   = (isSide) ? uv.x : uv.x;
            float seam     = 1.0 - step(0.93, fract(plankU * 3.0));       // dark gap at seam
            float grain    = noise2(float2(uv.x * 4.0, worldPos.y * 0.8 + vH * 2.0)) * 0.55
                           + noise2(float2(uv.x * 9.0, worldPos.y * 2.0 + vH * 1.3)) * 0.45;
            float bri      = mix(0.85, 1.15, grain) * mix(0.82, 1.0, seam);
            return float3(clamp(bri, 0.79, 1.16));
        }

        // ---- LEAVES  (5, 27) --------------------------------------------------
        if (matID==5u||matID==27u) {
            // #51: lean on the big blotches and drop the fine speck so canopies read as
            // bold solid green masses (toy look) instead of busy per-pixel grain. The
            // brightness range is calmed too, with the leftover variation steered into a
            // clean green/yellow hue drift rather than light/dark noise.
            float blotch1 = noise2(uv * 3.5 + float2(vH * 2.5, 1.1));
            float blotch2 = noise2(uv * 7.0 + float2(1.7, vH * 1.8));
            float speck   = noise2(uv * 16.0 + float2(vH * 4.0, 2.3));
            float leaf    = blotch1 * 0.62 + blotch2 * 0.32 + speck * 0.06;
            float bri     = mix(0.84, 1.16, leaf);
            float3 col    = float3(bri);
            // Lighter clumps warm toward lime, darker clumps deepen, hue stays green.
            float yellowing = (leaf - 0.5) * 0.16;
            col.r += yellowing * 0.7;
            col.g += yellowing * 0.2;
            col.b -= yellowing * 0.5;
            return clamp(col, 0.80, 1.20);
        }

        // ---- SNOW  (12) -------------------------------------------------------
        if (matID == 12u) {
            // Soft drift tone, no sparkle speckle (the high-freq specks read as noise
            // under the flat cel palette). Gentle blue-white shading.
            float base = smoothDetail(uv * 2.2 + float2(vH * 2.5, 1.3));
            float bri  = mix(0.94, 1.10, base);
            return clamp(float3(bri, bri, bri + 0.01), 0.90, 1.18);
        }

        // ---- ICE  (13) --------------------------------------------------------
        if (matID == 13u) {
            // Mostly smooth with a faint blue-tinted low-freq sheen (no Voronoi cracks).
            float sheen = smoothDetail(uv * 1.8 + float2(vH * 1.5, 0.8));
            float bri   = 1.0 + (sheen - 0.5) * 0.10;
            float3 col  = float3(bri);
            col.b      += (1.0 - sheen) * 0.05;
            col.r      -= (1.0 - sheen) * 0.03;
            return clamp(col, 0.86, 1.12);
        }

        // ---- BRICKS  (8, 24) --------------------------------------------------
        if (matID==8u||matID==24u) {
            // Offset brick courses: stagger alternate rows by half a brick
            float2 brickScale = float2(2.2, 1.1);
            float2 brickUV    = uv * brickScale;
            // Row offset: even rows stagger half a brick
            float row     = floor(brickUV.y);
            float offset  = fmod(row, 2.0) * 0.5;
            float2 cell   = fract(float2(brickUV.x + offset, brickUV.y));
            // Mortar lines: thin gap at cell edges
            float mortarX = smoothstep(0.0, 0.07, cell.x) * smoothstep(0.0, 0.07, 1.0 - cell.x);
            float mortarY = smoothstep(0.0, 0.10, cell.y) * smoothstep(0.0, 0.10, 1.0 - cell.y);
            float mortar  = mortarX * mortarY;  // 1=brick, 0=mortar
            // Brick surface variation
            uint  cellID  = uint(floor(brickUV.x + offset)) * 7u + uint(floor(brickUV.y)) * 13u;
            float bGrain  = uhash(cellID + uint(matID) * 31u);
            float surf    = (noise2(uv * 8.0) - 0.5) * 0.09;
            float bri     = mix(0.68, 1.08, bGrain) * mix(0.72, 1.0, mortar) + surf;
            return float3(clamp(bri, 0.70, 1.15));
        }

        // ---- GLASS  (25, 26) --------------------------------------------------
        if (matID==25u||matID==26u) {
            // Almost featureless; faint highlight sheen band
            float sheen = noise2(uv * 3.5 + float2(vH * 2.0, 1.3));
            float bri   = 1.0 + (sheen - 0.5) * 0.06;
            return float3(clamp(bri, 0.94, 1.06));
        }

        // ---- BED QUILT (52) --------------------------------------------------
        // Broad stitched squares keep the blanket readable as soft fabric instead
        // of another noisy terrain block. Geometry supplies the mattress and folds.
        if (matID == 52u) {
            float2 q       = uv * 4.0;
            float2 cell    = fract(q);
            float edge     = min(min(cell.x, 1.0 - cell.x), min(cell.y, 1.0 - cell.y));
            float interior = smoothstep(0.02, 0.09, edge);
            float checker  = fmod(floor(q.x) + floor(q.y), 2.0);
            float bri      = mix(0.82, 1.0, interior) * mix(0.94, 1.06, checker);
            return float3(bri, bri * 0.98, bri * 1.02);
        }

        // ---- CRAFTING TABLE (30) -----------------------------------------------
        // Wood base everywhere.  TOP face: a 3×3 crafting grid overlay + saw-blade
        // centre motif.  SIDE faces: wood grain + a narrow tool-band across the
        // middle third (y ∈ [0.30, 0.70]) with a chisel/saw silhouette.
        if (matID == 30u) {
            // Shared wood grain base (same technique as planks/logs)
            float grain  = noise2(float2(uv.x * 4.0, worldPos.y * 0.8 + vH * 2.0)) * 0.55
                         + noise2(float2(uv.x * 9.0, worldPos.y * 2.0 + vH * 1.3)) * 0.45;
            float seam   = 1.0 - step(0.93, fract(uv.x * 3.0));
            float woodBri = mix(0.85, 1.15, grain) * mix(0.82, 1.0, seam);

            if (isTop) {
                // 3×3 grid: dark lines at 1/3 and 2/3 along each axis.
                // Use worldPos projected to [0,1] within the block.
                float2 cellUV = fract(worldPos.xz);   // 0..1 within block
                float2 gridLines;
                gridLines.x = 1.0 - smoothstep(0.0, 0.05, abs(fract(cellUV.x * 3.0) - 0.5) - 0.44);
                gridLines.y = 1.0 - smoothstep(0.0, 0.05, abs(fract(cellUV.y * 3.0) - 0.5) - 0.44);
                float grid   = max(gridLines.x, gridLines.y);   // 1 = on a line

                // Saw-blade: 8-tooth starburst centred on block top.
                float2 ctr  = cellUV - 0.5;   // -0.5..0.5
                float  r    = length(ctr);
                float  ang  = atan2(ctr.y, ctr.x);
                float  teeth = cos(ang * 8.0) * 0.5 + 0.5;   // 8 teeth
                float  blade = smoothstep(0.32, 0.26, r) * smoothstep(0.10, 0.18, r)
                             * mix(0.75, 1.0, teeth);

                // Combine: wood base, darken grid lines, brighten blade
                float bri = woodBri * (1.0 - grid * 0.35) * mix(1.0, 1.18, blade);
                return float3(clamp(bri, 0.70, 1.20));
            } else {
                // Side faces: wood grain + a horizontal dark band in middle third
                // with a simple chisel-slash pattern inside the band.
                float localY = fract(worldPos.y);
                float inBand = smoothstep(0.28, 0.32, localY) * smoothstep(0.72, 0.68, localY);
                // Diagonal chisel cuts inside the band
                float chisel = sin(uv.x * 18.0 + localY * 6.0) * 0.5 + 0.5;
                float bandBri = mix(woodBri, woodBri * (0.72 + chisel * 0.20), inBand);
                return float3(clamp(bandBri, 0.70, 1.18));
            }
        }

        // ---- LOOT BARREL (31) --------------------------------------------------
        // The mesher supplies the bowed octagonal body, real iron hoops and lock
        // crests. This branch only paints oak staves; the old box-lid seam/clasp
        // pattern made every curved facet look like a fragment of the former chest.
        if (matID == 31u) {
            float grain = noise2(float2(uv.x * 5.0, worldPos.y * 1.3 + vH * 2.0)) * 0.62
                        + noise2(float2(uv.x * 11.0, worldPos.y * 3.0 + vH * 1.4)) * 0.38;
            float staveEdge = smoothstep(0.40, 0.50, abs(fract(uv.x * 4.0) - 0.5));
            float woodBri = mix(0.82, 1.14, grain) * mix(1.0, 0.78, staveEdge);

            if (isTop) {
                float ring = smoothstep(0.34, 0.40, length(fract(worldPos.xz) - 0.5));
                woodBri *= mix(1.0, 0.82, ring);
            } else if (isBot) {
                woodBri *= 0.90;
            }
            return float3(clamp(woodBri, 0.68, 1.16));
        }

        // ---- TORCH (32) --------------------------------------------------------
        // Rendered as a full block face; fake a stick + glowing tip.
        // The stick occupies the bottom 70% (dark wood); the tip is the upper 30%
        // with a bright warm glow halo.  Emissive, so the tip feeds bloom.
        if (matID == 32u) {
            float localY = fract(worldPos.y);
            float2 cx    = fract(worldPos.xz) - 0.5;   // -0.5..0.5 within block
            float  dist2 = dot(cx, cx);                  // distance^2 from block centre

            // Stick: narrow dark column
            float stickR   = 0.10;
            float onStick  = smoothstep(stickR + 0.04, stickR, sqrt(dist2)) * step(localY, 0.70);
            float stickGrain = noise2(float2(sqrt(dist2) * 6.0, localY * 8.0 + vH * 3.0));
            float stickBri = mix(0.70, 0.95, stickGrain);

            // Flame tip: bright warm blob in upper 30%, glowing halo around centre
            float inTip   = smoothstep(0.75, 0.68, localY);
            float flamePulse = noise2(float2(worldPos.x * 4.0, worldPos.z * 4.0));
            float tipGlow = exp(-dist2 * 18.0) * (1.0 + flamePulse * 0.30);
            float halo    = exp(-dist2 *  5.0) * 0.55;

            // Combine: base is dark wood, glow tip overlaid
            float3 col = float3(stickBri * onStick + 0.15);
            col = mix(col, float3(1.6, 1.1, 0.4) * (tipGlow + halo), inTip * clamp(tipGlow + halo, 0.0, 1.0));
            return clamp(col, 0.0, 2.5);   // allow HDR for the tip (emissive branch multiplies again)
        }

        // ---- OAK DOOR (33) -----------------------------------------------------
        // Planked door look: two tall panels separated by a centre rail, a top rail
        // and a bottom rail.  A round door handle on the right side near mid height.
        // All faces share the same plank grain; door geometry is on the XY or ZY face.
        if (matID == 33u) {
            float grain = noise2(float2(uv.x * 4.0, uv.y * 1.2 + vH * 2.0)) * 0.55
                        + noise2(float2(uv.x * 9.0,  uv.y * 2.8 + vH * 1.3)) * 0.45;
            float woodBri = mix(0.84, 1.14, grain);

            if (isSide) {
                // The main visible face.  uv.x = horizontal across door, uv.y = vertical.
                float lx = fract(uv.x);   // 0..1 across block width
                float ly = fract(uv.y);   // 0..1 up the block

                // Panel grooves: vertical centre rail + top/bottom rails
                float centreRail = smoothstep(0.04, 0.0, abs(lx - 0.50));    // vertical seam
                float topRail    = smoothstep(0.04, 0.0, abs(ly - 0.82));    // near top
                float bottomRail = smoothstep(0.04, 0.0, abs(ly - 0.18));    // near bottom
                float midRail    = smoothstep(0.04, 0.0, abs(ly - 0.50));    // horizontal mid
                float rails      = max(max(centreRail, topRail), max(bottomRail, midRail));

                // Panel recesses: slight darkening of the panel interior
                float inPanel = (1.0 - centreRail) * (1.0 - topRail) * (1.0 - bottomRail) * (1.0 - midRail);
                float panelShade = mix(1.0, 0.88, inPanel * 0.4);

                // Round handle: small circle on right side at 55% height
                float2 hctr = float2(lx - 0.75, ly - 0.55);
                float hDist = length(hctr);
                float handle = smoothstep(0.07, 0.04, hDist);
                float handleRing = smoothstep(0.09, 0.07, hDist) * (1.0 - smoothstep(0.04, 0.03, hDist));

                float bri = woodBri * panelShade * (1.0 - rails * 0.30);
                float3 col = float3(clamp(bri, 0.72, 1.14));
                // Handle is iron: grey-bright disc with a slightly darker ring
                col = mix(col, float3(0.90, 0.88, 0.82), handle * 0.85);
                col = mix(col, float3(0.55, 0.54, 0.52), handleRing * 0.70);
                return clamp(col, 0.70, 1.15);
            } else {
                // Top/bottom of door: just wood grain, narrow (door is thin)
                return float3(clamp(woodBri, 0.78, 1.12));
            }
        }

        // ---- BEACON BLOCK (34) -------------------------------------------------
        // A glowing energy core with concentric animated rings and crystalline
        // facet lines.  Emissive (goes HDR); patterns modulate the brightness
        // so the beacon pulses visually but still reads as a distinct shape.
        if (matID == 34u) {
            float2 ctr  = fract(worldPos.xz) - 0.5;   // -0.5..0.5 within block top/side
            if (isTop || isBot) {
                float r     = length(ctr);
                // Concentric rings that animate (pretend T via vH for static version)
                float rings  = sin(r * 22.0 - vH * 6.28) * 0.5 + 0.5;
                // Radial spokes
                float ang    = atan2(ctr.y, ctr.x);
                float spokes = pow(abs(sin(ang * 6.0)) * 0.5 + 0.5, 2.0);
                // Core glow
                float core   = exp(-r * r * 28.0);
                float bri    = mix(0.80, 1.30, rings * 0.60 + spokes * 0.40) + core * 0.50;
                // Tint: aqua-white
                return clamp(float3(bri * 0.92, bri, bri * 1.05), 0.0, 2.0);
            } else {
                // Side faces: horizontal energy bands + diagonal facets
                float ly    = fract(worldPos.y);
                float bands = sin(ly * 14.0) * 0.5 + 0.5;
                float2 side2 = fract(uv) - 0.5;
                float facets = voronoiCell(side2 + float2(vH * 2.0, 0.5), 3.0);
                float bri   = mix(0.80, 1.30, bands * 0.50 + facets * 0.50);
                return clamp(float3(bri * 0.90, bri, bri * 1.06), 0.0, 2.0);
            }
        }

        // ---- CRYSTAL LAMP (35) -------------------------------------------------
        // Glowing crystalline facets with a bright inner core. Each face shows
        // Voronoi crystal cells with bright cell-centre highlights.
        if (matID == 35u) {
            float2 crystUV = uv + float2(vH * 1.3, vH * 0.7);
            float  cell   = voronoiCell(crystUV, 4.5);
            // Fine inner sparkle
            float  sparkle = step(0.88, noise2(uv * 18.0 + float2(vH * 5.0, 2.3)));
            // Gradient from edge (dim) to centre (bright) within each cell
            float  bri    = mix(0.75, 1.45, cell) + sparkle * 0.20;
            // Purple-white crystal tint
            float3 col    = float3(bri * 0.95, bri * 0.88, bri * 1.10);
            return clamp(col, 0.0, 2.0);
        }

        // ---- GLOW BLOCK (7) ----------------------------------------------------
        // Warm amber luminous block: smooth but with subtle hexagonal cell pattern
        // so it reads as a lamp tile rather than a flat coloured block.
        if (matID == 7u) {
            float  cell   = voronoiCell(uv + float2(vH * 1.1, vH * 0.8), 3.0);
            float  grain  = noise2(uv * 8.0 + float2(vH * 2.0, 1.3)) * 0.25;
            float  bri    = mix(0.85, 1.30, cell * 0.70 + grain * 0.30);
            // Warm amber tint (yellow-orange)
            float3 col    = float3(bri * 1.05, bri * 0.92, bri * 0.55);
            return clamp(col, 0.0, 2.0);
        }

        // ---- COLOR CRYSTAL (40) ------------------------------------------------
        // Bright magenta-violet faceted crystal with high-contrast Voronoi cells
        // and angular shards. Emissive, so overbright values feed bloom.
        if (matID == 40u) {
            float2 shardUV = uv * float2(1.3, 0.9) + float2(vH * 0.9, vH * 1.4);
            float2 vd      = voronoi2(shardUV * 4.2);
            float  edge    = smoothstep(0.0, 0.18, vd.y - vd.x);   // 0=edge, 1=centre
            float  sparkle = step(0.90, noise2(uv * 22.0 + float2(vH * 4.5, 1.7)));
            float  bri     = mix(0.72, 1.50, edge) + sparkle * 0.30;
            // Magenta-violet: high R and B, modest G
            float3 col     = float3(bri * 1.05, bri * 0.60, bri * 1.10);
            return clamp(col, 0.0, 2.2);
        }

        // ---- DEFAULT: gentle value noise for anything else --------------------
        float n = noise2(uv * 5.0 + float2(vH * 2.0, 1.1));
        return float3(mix(0.88, 1.12, n));
    }

    // =========================================================
    // WIND SWAY — foliage block classification + displacement
    // =========================================================

    // Returns sway amplitude factor for a given block material id (p.material).
    //   0   = not foliage, no sway
    //   1.0 = grass/flower/tall-grass  (full sway)
    //   0.4 = leaves                   (subtle rustle)
    //   0.3 = mushroom                 (minimal, stiff cap)
    static float foliageFactor(uint matID) {
        // Only ISOLATED decorative plants sway — these are single cubes, so a
        // gentle drift reads as a plant in the breeze. Leaves (5,27) and
        // mushrooms (39) are full/connected cubes that slide apart and look like
        // they're "rotating", so they do NOT sway.
        if (matID == 36u || matID == 37u || matID == 38u) return 1.0;  // flowers, tall grass
        return 0.0;
    }

    // Shared wind-sway displacement used by BOTH vmain and shadowVmain (#45).
    // Sways ONLY thin transparent decorations — 36/37 flowers, 38 tall grass,
    // 39 mushroom — which are cross/billboard quads, so they read as grass blowing.
    // Solid blocks (ground, leaves) are deliberately excluded: the earlier attempt
    // was disabled because swaying full cubes slid visibly / opened seams.
    static float2 windSway(float3 worldPos, uint matID, float T, float rainStr) {
        if (matID != 36u && matID != 37u && matID != 38u && matID != 39u) return float2(0.0);
        float amp = 0.07 * (1.0 + rainStr * 1.1);         // windier when it's raining
        // Low spatial frequency so neighbours move together; multi-frequency in time
        // so it reads as a breeze, not a metronome.
        float phase = worldPos.x * 0.30 + worldPos.z * 0.25;
        float sx = sin(T * 1.6 + phase)       + 0.35 * sin(T * 3.1 + phase * 1.7);
        float sz = cos(T * 1.3 + phase * 0.8) + 0.30 * sin(T * 2.5 + phase);
        return float2(sx, sz) * amp;
    }

    // The depth-only shadow-map vertex shader (shadowVmain) is retired: world-space
    // voxel shadows are marched per fragment against the occupancy 3D texture, so no
    // geometry is rasterised into a shadow map.

    // =========================================================
    // TERRAIN VERTEX SHADER (applies foliage wind sway)
    // =========================================================
    vertex VOut vmain(uint vid [[vertex_id]],
                      device const PackedVertex* verts [[buffer(0)]],
                      constant Uniforms& u [[buffer(1)]],
                      constant WindUniforms& wu [[buffer(3)]]) {
        PackedVertex p = verts[vid];
        uint xBits = (p.pos & 0x3f) | ((p.reserved & 1u) << 6);
        uint yBits = ((p.pos >> 6) & 0x3f) | (((p.reserved >> 1) & 1u) << 6);
        uint zBits = ((p.pos >> 12) & 0x3f) | (((p.reserved >> 2) & 1u) << 6);
        float x = float(xBits) + float((p.pos >> 18) & 0xf) / 16.0;
        float y = float(yBits) + float((p.pos >> 22) & 0xf) / 16.0;
        float z = float(zBits) + float((p.pos >> 26) & 0xf) / 16.0;
        float3 world = u.chunkOrigin.xyz + float3(x, y, z);
        uint n = p.normuv & 7u;

        // --- Foliage wind sway ---
        // p.material = block type id, p.block = per-vertex block light (0..15).
        float2 sway = windSway(world, uint(p.material), wu.wallClockSecs, wu.rainStrength) * wu.swayScale;
        float3 swayedWorld = world + float3(sway.x, 0.0, sway.y);

        // --- AO from bits [3:5] (0=fully occluded, 3=open) ---
        float ao = float((p.normuv >> 3u) & 3u) / 3.0;
        // Smooth the AO value slightly (gamma lift to soften corners)
        ao = pow(ao, 0.85);

        // --- Lighting: sky + block + day/night (same as before) ---
        float dayB   = 0.15 + 0.85 * dayLight(u.sunDirTime.w);
        float skyC   = (float(p.sky)   / 15.0) * dayB;
        float blockC = float(p.block)  / 15.0;
        float lightLevel = max(max(skyC, blockC), 0.08);
        float facing = 0.52 + 0.48 * faceShade(n);   // stronger directional contrast (depth w/o cast shadows)
        float shade  = clamp(lightLevel * facing, 0.0, 1.0);

        VOut o;
        // #180 horizon curvature: rasterize the DROPPED position, but keep worldPos
        // (fog, voxel shadow march, water waves) on the flat world.
        // #230: terrain samples the drop from the chunk's bilinear corner patch
        // (see horizonDropAt) so long greedy edges and their t-vertices agree
        // exactly — no more hairline cracks for the cel ink to ink (#219).
        float3 bent = swayedWorld;
        {
            float2 c0  = u.chunkOrigin.xz;
            float2 cam = wu.camPosH.xz;
            float d00 = horizonDropAt(c0,                      cam);
            float d10 = horizonDropAt(c0 + float2(16.0,  0.0), cam);
            float d01 = horizonDropAt(c0 + float2( 0.0, 16.0), cam);
            float d11 = horizonDropAt(c0 + float2(16.0, 16.0), cam);
            // Local UNSWAYED fractions: border vertices hit 0/1 exactly, so both
            // chunks compute the identical corner value and the seam welds shut.
            float tx = x * (1.0 / 16.0);
            float tz = z * (1.0 / 16.0);
            bent.y -= wu.camPosH.w * mix(mix(d00, d10, tx), mix(d01, d11, tx), tz);
        }
        o.position = u.viewProj * float4(bent, 1.0);

        float3 base = materialColor(uint(p.material));
        o.color    = mix(base, base * float3(1.15, 1.02, 0.8), clamp(blockC - skyC, 0.0, 1.0));
        o.shade    = shade;
        // Bilinearly blend saturation across the chunk's 4 corner regions so the
        // grey->colour edge feathers instead of snapping on the region grid.
        {
            float fx = clamp(x / float(16), 0.0, 1.0);
            float fz = clamp(z / float(16), 0.0, 1.0);
            float s00 = u.chunkOrigin.w, s10 = u.dimSatN.x, s01 = u.dimSatN.y, s11 = u.dimSatN.z;
            o.sat = mix(mix(s00, s10, fx), mix(s01, s11, fx), fz);
        }
        o.worldPos = swayedWorld;
        o.faceNorm = n;
        o.material = uint(p.material);
        o.lod      = u.dimSatN.w;
        o.ao       = ao;
        // Sun shadows are now computed in the fragment shader by marching the world
        // occupancy grid from o.worldPos toward the sun; no per-vertex light-space
        // projection is needed (no shadow map).

        return o;
    }

    // =========================================================
    // PCF SHADOW LOOKUP helper
    //   shadowTex: depth32Float texture bound with a comparison sampler.
    //   shadowPos: light-clip-space float4 (w=1 for ortho, but do divide anyway).
    //   Returns 1.0 = fully lit, 0.0 = fully in shadow.
    // =========================================================
    // =========================================================
    // WORLD-SPACE VOXEL SUN-SHADOW MARCH
    // ---------------------------------------------------------
    // A point is in shadow iff a solid (casting) voxel sits between it and the
    // sun. We DDA-march the 3D occupancy texture (the engine's resident-world
    // occupancy grid) from the fragment's WORLD position toward the sun. The
    // result depends ONLY on world geometry + sun direction, never the camera,
    // so a fixed world point's shadow is identical from every angle/position.
    //
    //   occ      : r8uint 3D texture, 1 = casting voxel, 0 = empty
    //   gridOrigin: world block coords of voxel (0,0,0)
    //   gridDims  : voxel dimensions (x,y,z)
    //   worldP    : the fragment's world position
    //   toSun     : unit vector pointing TOWARD the sun
    //   maxDist   : max world distance to march before giving up (lit)
    // Returns 1.0 = lit, 0.0 = fully shadowed.
    // Coarse cell size (must match Renderer.kShadowCoarse). Empty-space skipping: when the
    // ray is in an empty coarse cell, advance to that cell's exit in ONE step; only inside an
    // occupied coarse cell do we test fine voxels one at a time. Most of a sun ray's length is
    // open air, so the coarse skips collapse the step count. Position-sampling form (recompute
    // the voxel from p each iteration) keeps it simple and stall-free with a hard step cap.
    constant int BF_COARSE = 4;

    static float marchSunOcclusion(texture3d<uint, access::read> occ,
                                   texture3d<uint, access::read> coarse,
                                   float3 gridOrigin, float3 gridDims,
                                   float3 worldP, float3 toSun, float maxDist) {
        int3 dims = int3(gridDims);
        int3 iorigin = int3(round(gridOrigin));
        // Grid-relative start (window is [origin, origin+dim)), lifted a hair toward the sun
        // (the caller also lifts along the surface normal, handling self-shadow acne).
        float3 p0 = worldP - gridOrigin + toSun * 0.05;
        // Per-axis reciprocal (axes with ~0 component never cross a boundary -> huge t).
        float3 inv = float3(abs(toSun.x) < 1e-6 ? 0.0 : 1.0/toSun.x,
                            abs(toSun.y) < 1e-6 ? 0.0 : 1.0/toSun.y,
                            abs(toSun.z) < 1e-6 ? 0.0 : 1.0/toSun.z);
        float3 sgnPos = float3(toSun.x >= 0.0 ? 1.0 : 0.0, toSun.y >= 0.0 ? 1.0 : 0.0, toSun.z >= 0.0 ? 1.0 : 0.0);

        // Hierarchical empty-space skip: march the COARSE grid (CO-block cells) in big steps and
        // only refine to single voxels inside an occupied coarse cell. The wrapped buffer cell
        // (gx,_,gz) is tracked INCREMENTALLY (one add + a conditional wrap-correct, no per-step
        // floor/modulo) which is the hot-path optimization. One texture read per step, exit the
        // instant a solid voxel is hit.
        float t = 0.0;
        // Worst case is all-fine steps for the full march distance; cap generously but the loop
        // almost always exits early via the t>maxDist / hit / out-of-grid checks.
        const int MAX_STEPS = 48;
        for (int i = 0; i < MAX_STEPS; ++i) {
            float3 p = p0 + toSun * t;
            int3 v = int3(floor(p));   // grid-relative voxel
            if (v.x < 0 || v.y < 0 || v.z < 0 || v.x >= dims.x || v.y >= dims.y || v.z >= dims.z) {
                return 1.0;   // left the loaded window -> open sky / not loaded -> lit
            }
            // Wrapped fine cell + its coarse cell. dims.x/z are powers of two (256), so the
            // toroidal wrap is a cheap bitmask (& (dim-1)) instead of an integer modulo. y is direct.
            // BF_COARSE is a power of two (4) so /BF_COARSE -> >>2 and %BF_COARSE -> &3.
            int wfx = (v.x + iorigin.x) & (dims.x - 1);
            int wfz = (v.z + iorigin.z) & (dims.z - 1);
            uint3 cvox = uint3(uint(wfx >> 2), uint(v.y >> 2), uint(wfz >> 2));
            if (coarse.read(cvox).r == 0u) {
                // Empty coarse cell: jump to its far boundary in ONE step (CO blocks of air).
                float3 cbase = float3(v - (v & 3));
                float3 nb = cbase + sgnPos * float(BF_COARSE);
                float dx = (inv.x == 0.0) ? 1e30 : (nb.x - p.x) * inv.x;
                float dy = (inv.y == 0.0) ? 1e30 : (nb.y - p.y) * inv.y;
                float dz = (inv.z == 0.0) ? 1e30 : (nb.z - p.z) * inv.z;
                t += max(min(dx, min(dy, dz)), 0.0) + 0.0008;
            } else {
                // Occupied coarse cell: test this fine voxel, then step one voxel.
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

    // Sun shadow at a world point. Hard single ray, or a small jittered penumbra
    // when soft shadows are enabled. 1.0 = lit, 0.0 = shadowed.
    static float voxelSunShadow(texture3d<uint, access::read> occ,
                                texture3d<uint, access::read> coarse,
                                float3 gridOrigin, float3 gridDims,
                                float3 worldP, float3 toSun, float maxDist, float soft) {
        if (soft < 0.5) {
            return marchSunOcclusion(occ, coarse, gridOrigin, gridDims, worldP, toSun, maxDist);
        }
        // Soft penumbra: average a few rays jittered around the sun direction.
        float3 up = abs(toSun.y) < 0.95 ? float3(0,1,0) : float3(1,0,0);
        float3 t1 = normalize(cross(up, toSun));
        float3 t2 = cross(toSun, t1);
        const float R = 0.06;   // angular jitter radius
        float lit = marchSunOcclusion(occ, coarse, gridOrigin, gridDims, worldP, toSun, maxDist);
        const float2 offs[4] = { float2( 1, 0), float2(-1, 0), float2(0, 1), float2(0,-1) };
        for (int k = 0; k < 4; ++k) {
            float3 dir = normalize(toSun + (t1 * offs[k].x + t2 * offs[k].y) * R);
            lit += marchSunOcclusion(occ, coarse, gridOrigin, gridDims, worldP, dir, maxDist);
        }
        return lit / 5.0;
    }

    // =========================================================
    // TERRAIN FRAGMENT SHADER
    // =========================================================
    fragment float4 fmain(VOut in [[stage_in]],
                          constant WaterUniforms& wu [[buffer(2)]],
                          constant WindUniforms& wind [[buffer(3)]],
                          texture3d<uint, access::read> occ    [[texture(0)]],
                          texture3d<uint, access::read> occCoarse [[texture(1)]]) {
        uint mat = in.material;
        bool farLod = in.lod > 0.5;

        // ---- Glowing blocks skip shadowing (they emit light) ----
        bool isEmissive = (mat==7u||mat==32u||mat==34u||mat==35u||mat==40u);

        // ---- World-space voxel sun shadows ----
        // A fragment is sun-shadowed iff a casting voxel sits between it and the
        // sun. We DDA-march the resident-world occupancy grid (3D texture) from the
        // fragment's WORLD position toward the sun. The result depends only on world
        // geometry + sun direction, so a fixed world point's shadow is identical
        // regardless of camera position or yaw (no map, no cascade, no coverage ring,
        // no crawl). Daylight-gated via in.shade so there are no sun shadows at night.
        float shadowFactor = 1.0;
        if (!farLod && !isEmissive && wu.shadowScale > 0.5) {
            float dayFactor = clamp(in.shade * 1.5, 0.0, 1.0);
            if (dayFactor > 0.001) {
                float3 toSun = normalize(-wu.sunDirTime.xyz);
                float3 fnrm;
                switch (in.faceNorm) {
                    case 0u: fnrm = float3( 1, 0, 0); break;
                    case 1u: fnrm = float3(-1, 0, 0); break;
                    case 2u: fnrm = float3( 0, 1, 0); break;
                    case 3u: fnrm = float3( 0,-1, 0); break;
                    case 4u: fnrm = float3( 0, 0, 1); break;
                    default: fnrm = float3( 0, 0,-1); break;
                }
                // BACK-FACE SKIP (exact, the big win): a surface whose normal faces away from
                // the sun is self-shadowed by definition. Set fully shadowed and SKIP the march
                // entirely. ~half of visible faces never march. This is exact geometry, not an
                // approximation, so it does not affect world-fixedness.
                float ndl = dot(fnrm, toSun);
                float raw;
                if (ndl <= 0.0) {
                    raw = 0.0;   // back face -> shadowed, no march
                } else {
                    // March the world occupancy directly toward the sun, lifting the start along
                    // the face normal to avoid self-shadow acne. The bounded march distance
                    // (voxOrigin.w, THE perf knob) caps the per-fragment cost; the result is a
                    // pure function of the WORLD point, so a fixed point's shadow is camera-free.
                    raw = voxelSunShadow(occ, occCoarse, wu.voxOrigin.xyz, wu.voxDims.xyz,
                                         in.worldPos + fnrm * 0.25, toSun, wu.voxOrigin.w, wu.voxDims.w);
                }
                // Harness sentinel (shadowScale == 2): output the raw shadow factor as
                // grayscale (white = lit, black = shadowed) so coverage reads headless.
                if (wu.shadowScale > 1.5) return float4(raw, raw, raw, 1.0);
                shadowFactor = 1.0 - (0.55 * dayFactor) * (1.0 - raw);
            } else if (wu.shadowScale > 1.5) {
                return float4(1.0, 1.0, 1.0, 1.0);   // night: fully lit in the debug view
            }
        } else if (wu.shadowScale > 1.5) {
            return float4(1.0, 1.0, 1.0, 1.0);
        }

        // ---- AO multiplier: fold into lit colour (multiplied with shade) ----
        // ao=0 → dark corner (multiply by 0.45), ao=1 → open (multiply by 1.0)
        float aoFactor = mix(0.45, 1.0, in.ao);

        // ---- Water block special path ----
        // Water is rendered ONLY by the dedicated translucent pass (waterFmain),
        // never here in the opaque pass. Previously this branch painted water as a
        // fully opaque surface AND wrote depth, then the translucency pass blended
        // 0.55 on top of it — a double-draw that (a) double-blended the surface,
        // (b) overwrote the lake bottom so the "see-through" alpha had nothing real
        // to reveal, and (c) used a slightly different base colour, so the surface
        // read inconsistently. Discarding here keeps the lake bottom in the colour
        // buffer (and the bottom's depth), so the single translucent pass blends
        // cleanly over real terrain with no z-fighting or double-blend.
        if (mat == 9u) {
            discard_fragment();
        }
        // #68 glass (25, 26): see-through, drawn ONLY by the translucent pass. Discard
        // here so the opaque pass leaves whatever is behind the glass in the buffer.
        if (mat == 25u || mat == 26u) {
            discard_fragment();
        }

        // =========================================================
        // PLANT ALPHA-TESTED PATH (material ids 36-39)
        // The mesher emits CROSS billboards for these; we render them
        // as procedural alpha-tested shapes on the quad UV.
        // UV derivation: V = fract(worldPos.y) gives 0(bottom)..1(top);
        // U = fract of the dominant horizontal axis for this face normal.
        // =========================================================
        bool isPlant = (mat==36u||mat==37u||mat==38u||mat==39u);
        if (isPlant) {
            // Derive plant UV from worldPos: V = vertical (0=bottom, 1=top of block)
            float plantV = fract(in.worldPos.y);
            // U: use whichever horizontal axis is more "across" this face.
            // For face normals 0/1 (±X), use Z; for 4/5 (±Z), use X; for top/bot use X.
            float plantU;
            uint fn = in.faceNorm;
            if (fn == 0u || fn == 1u)      plantU = fract(in.worldPos.z);
            else if (fn == 4u || fn == 5u) plantU = fract(in.worldPos.x);
            else                            plantU = fract(in.worldPos.x);

            float alpha = 0.0;
            float3 plantCol = float3(0.0);

            if (mat == 38u) {
                // ---- TALL GRASS: soft clumpy tuft of short, rounded blades ----
                // 5 blades, each short (only fills lower 55-70% of V so there are
                // no sharp spike tips), and with wide soft-rounded tops rather than
                // tapering to a point. Blades are slightly taller/shorter individually
                // for a natural clumped look, not uniform spikes.
                float3 grassBase = float3(0.28, 0.72, 0.18);
                float bladeMask = 0.0;
                float3 hue = float3(0.0);
                // cx=centre, topV=where the blade ends (0.55-0.70), roundR=top-round radius
                const float centres[5] = {0.12, 0.30, 0.50, 0.68, 0.85};
                const float topVs[5]   = {0.62, 0.68, 0.58, 0.65, 0.60};  // shorter than 1.0!
                const float hues[5]    = {0.04, -0.03, 0.05, -0.04, 0.02};
                for (int bi = 0; bi < 5; ++bi) {
                    float cx    = centres[bi];
                    float topV  = topVs[bi];
                    // Width: 0.07 at base, narrows slightly but stays wider than before
                    float bladeWidth = 0.065 * (0.6 + 0.4 * (1.0 - plantV / topV));
                    bladeWidth = max(bladeWidth, 0.012);
                    float dx = abs(plantU - cx);
                    // Only active in [0, topV] vertical range
                    float inRange = smoothstep(0.0, 0.05, plantV)        // fade in at base
                                  * smoothstep(topV + 0.04, topV - 0.01, plantV);  // fade out at top
                    // Round the tip: use a soft circle cap near topV
                    float2 tipDiff = float2(plantU - cx, plantV - (topV - 0.06));
                    float tipDist  = length(tipDiff * float2(1.0 / 0.08, 1.0 / 0.08));
                    float tipCap   = smoothstep(1.0, 0.5, tipDist);  // soft rounded top
                    // Body mask: within blade width OR within rounded cap
                    float bodyMask = smoothstep(bladeWidth + 0.015, bladeWidth, dx) * inRange;
                    float inBlade  = max(bodyMask, tipCap * inRange);
                    if (inBlade > bladeMask) {
                        bladeMask = inBlade;
                        hue = float3(-hues[bi]*0.5, hues[bi], -hues[bi]*0.3);
                    }
                }
                alpha = bladeMask;
                plantCol = clamp(grassBase + hue, 0.0, 1.0);
                // Apply gentle lighting: mostly ambient (bright) with a little shade
                float lightMix = mix(0.55, 1.0, in.shade);
                plantCol *= lightMix;

            } else if (mat == 36u || mat == 37u) {
                // ---- FLOWER (red 36 / yellow 37) ----
                float3 stemCol   = float3(0.22, 0.60, 0.14);
                float3 bloomCol  = (mat == 36u) ? float3(0.92, 0.12, 0.12)
                                                : float3(1.00, 0.90, 0.08);

                // Stem: thin vertical strip in the middle, lower 60% of V
                float stemMask = 0.0;
                {
                    float dx = abs(plantU - 0.50);
                    float inStem = smoothstep(0.035, 0.018, dx);
                    float stemRange = smoothstep(0.0, 0.04, plantV)
                                    * smoothstep(0.62, 0.56, plantV);
                    stemMask = inStem * stemRange;
                }

                // Bloom: cluster of petals at top (V > 0.55)
                // 5 petals around the centre at radius 0.14, plus a centre disc
                float bloomMask = 0.0;
                {
                    float bloomV = smoothstep(0.55, 0.60, plantV);
                    // Centre disc
                    float2 ctr = float2(plantU - 0.50, plantV - 0.78);
                    float centreD = length(ctr);
                    float centreMask = smoothstep(0.12, 0.06, centreD);
                    // 5 petals
                    float petalMask = 0.0;
                    for (int pi = 0; pi < 5; ++pi) {
                        float angle = float(pi) * (6.2831853 / 5.0);
                        float2 pCtr = float2(cos(angle) * 0.14, sin(angle) * 0.10) + float2(0.50, 0.78);
                        float pd = length(float2(plantU, plantV) - pCtr);
                        petalMask = max(petalMask, smoothstep(0.10, 0.04, pd));
                    }
                    bloomMask = max(centreMask, petalMask) * bloomV;
                }

                alpha = max(stemMask, bloomMask);
                plantCol = (bloomMask > stemMask) ? bloomCol : stemCol;
                float lightMix = mix(0.70, 1.0, in.shade);
                plantCol *= lightMix;

            } else if (mat == 39u) {
                // ---- MUSHROOM: short pale stem + domed red cap with speckles ----
                float3 stemCol = float3(0.88, 0.84, 0.76);
                float3 capCol  = float3(0.88, 0.14, 0.10);

                // Stem: narrow, lower 40% of height
                float stemMask = 0.0;
                {
                    float dx = abs(plantU - 0.50);
                    float inStem = smoothstep(0.045, 0.022, dx);
                    float stemRange = smoothstep(0.0, 0.04, plantV)
                                    * smoothstep(0.42, 0.36, plantV);
                    stemMask = inStem * stemRange;
                }

                // Cap: dome shape, upper 50% of height
                float capMask = 0.0;
                {
                    // Dome: circular cross-section, centred at (0.5, 0.70)
                    float2 ctr = float2(plantU - 0.50, plantV - 0.68);
                    // Scale Y so the dome is wider than tall
                    float2 scaled = float2(ctr.x * 1.0, ctr.y * 1.8);
                    float d = length(scaled);
                    capMask = smoothstep(0.34, 0.26, d)
                            * smoothstep(0.38, 0.42, plantV);  // only upper half
                    // White speckles on cap
                    float speckN = step(0.80, noise2(float2(plantU, plantV) * 14.0));
                    capMask = max(capMask, capMask * speckN * 0.0);   // mask stays same for alpha
                }

                alpha = max(stemMask, capMask);
                if (capMask > stemMask) {
                    // Speckle colouring on cap
                    float speckN = step(0.80, noise2(float2(plantU, plantV) * 14.0));
                    plantCol = mix(capCol, float3(0.95, 0.90, 0.85), speckN * 0.55);
                } else {
                    plantCol = stemCol;
                }
                float lightMix = mix(0.65, 0.95, in.shade);
                plantCol *= lightMix;
            }

            // Alpha test: discard background quads
            if (alpha < 0.5) discard_fragment();

            // Dim desaturation (match normal block path)
            float lumP = dot(plantCol, float3(0.299, 0.587, 0.114));
            float satP = clamp(in.sat, 0.0, 1.0);
            float3 drainedP = float3(0.22, 0.25, 0.32) * (0.45 + lumP * 0.85);
            plantCol = mix(drainedP, plantCol, satP);
            return float4(plantCol, 1.0);
        }

        // ---- Standard block path ----
        float3 detail = farLod ? float3(1.0) : blockDetail(in.worldPos, in.faceNorm, in.material);

        // ---- Fake bump / normal perturbation from procedural height -----------
        // Derive a small per-fragment normal offset from finite-differencing the
        // same noise used by blockDetail so bumps are correlated with visible texture.
        // Only applies the bump to the sun (directional) lighting term, not AO/shadow,
        // keeping the effect subtle and tasteful.
        // Skip on emissive and water (they have their own shading).
        // FIX (#7): bumpStrength clamped so shade*bump never exceeds 1.0 on a
        // normally-lit face. The old clamp(sunTilt, 0.78, 1.22) allowed the bump
        // to push HDR output above 1.0, causing view-dependent bloom wash-out.
        // New: sunTilt capped at 1.0 so the bump can only darken, never brighten.
        float bumpLight = 1.0;
        float3 specAdd = float3(0.0);   // #47 stylized PBR specular (float3 so metals can tint it)
        if (!farLod && !isEmissive) {
            // #134 cheaper relief: the visible #133 detail is now low-frequency and smooth,
            // so the bump height field is sampled at the matching low frequency and with TWO
            // taps instead of three (a centre sample plus one diagonal offset). The diagonal
            // delta drives both axes, which loses a little directionality but is invisible at
            // this amplitude and saves a per-fragment noise2 (four hashes) on every block.
            const float eps = 0.10;   // finite-difference step in world units
            float2 uv0 = faceUV(in.worldPos, in.faceNorm);
            float h00  = noise2(uv0 * 2.6);
            float hD   = noise2((uv0 + float2(eps, eps)) * 2.6);
            float dH   = (hD - h00) / eps;
            float dHdX = dH;
            float dHdY = dH;
            // bumpStrength reduced to 0.06 (was 0.09) so the perturbation stays subtle.
            // sunTilt clamped to [0.82, 1.00] — bump can darken corners but never
            // pushes lit surfaces above 1.0 HDR, preventing bloom wash-out.
            float bumpStrength = 0.06;
            float sunTilt = clamp(1.0 - (dHdX + dHdY) * bumpStrength, 0.82, 1.00);
            bumpLight = (in.faceNorm == 3u) ? 1.0 : sunTilt;

            // #47/#89 relief sheen: perturb the face normal by the same height field (a
            // procedural normal map) and add a sun highlight that shimmers over the surface
            // relief. ORIGINALLY this used a Blinn-Phong half-vector (view + sun), so the
            // highlight rode across the terrain as the camera yawed, which read as the cast
            // shadows "wiping" when you turned (the #49/#72 shadow-map fixes were chasing a
            // shadow bug that the pixel experiment, --shadowprobe, proved does not exist: the
            // shadow map is byte-identical across yaws; only this sheen moved). Make the sheen
            // VIEW-INDEPENDENT: drive it off the SUN against the perturbed normal only, so it
            // still shimmers per-texel with the relief but no longer sweeps with the camera.
            float3 wN, wT, wB;
            switch (in.faceNorm) {
                case 0u: wN = float3( 1,0,0); wT = float3(0,0,1); wB = float3(0,1,0); break;
                case 1u: wN = float3(-1,0,0); wT = float3(0,0,1); wB = float3(0,1,0); break;
                case 2u: wN = float3(0, 1,0); wT = float3(1,0,0); wB = float3(0,0,1); break;
                case 3u: wN = float3(0,-1,0); wT = float3(1,0,0); wB = float3(0,0,1); break;
                case 4u: wN = float3(0,0, 1); wT = float3(1,0,0); wB = float3(0,1,0); break;
                default: wN = float3(0,0,-1); wT = float3(1,0,0); wB = float3(0,1,0); break;
            }
            float3 pN = normalize(wN - (wT * dHdX + wB * dHdY) * 0.5);
            float3 Ld = normalize(-wu.sunDirTime.xyz);
            // Sun-only relief term: highlights where the perturbed normal faces the sun more
            // than the flat face does. No camera term, so turning never moves it.
            // NIGHT FIX: Ld = normalize(-sunDir) points DOWN once the sun is below the
            // horizon, so a face turned toward the sun's azimuth (e.g. a +X wall at midnight)
            // still scored a big dot(pN, Ld) and pow()'d into a bright glint AT NIGHT. Gate it
            // by sunAbove (sunDir.y < 0 == sun up; >0 == set), so the relief sheen only fires
            // while the sun is actually above the horizon and fades to zero through dusk.
            float sunAbove = smoothstep(0.0, -0.12, wu.sunDirTime.y);   // 1 sun up .. 0 sun set
            float baseLum  = dot(in.color, float3(0.299, 0.587, 0.114));

            // ===== #47 STYLIZED PBR SPECULAR =====================================
            // There are no texture assets, so roughness/metalness are derived PROCEDURALLY
            // per material id, and the highlight is a SUN-ONLY (view-independent) lobe so it
            // never sweeps with the camera (preserving the world-fixed look). It is kept
            // RESTRAINED and quantized into a couple of flat steps so it reads as a bold
            // toon catch-light that COMPLEMENTS the cel bands rather than a smooth photoreal
            // gradient that would flatten them.
            //   rough  : 1 = matte (broad/dim), 0 = glossy (tight/bright)
            //   metal  : 0 = dielectric (white-ish highlight), 1 = metal (albedo-tinted)
            // Material families (ids from the block colour table):
            //   water 9 / glass 25,26  -> handled elsewhere (discarded above)
            //   metals/ore 13,14,15,33 -> glossy + metallic (tight albedo-tinted highlight)
            //   stone/brick 3,4,5,28   -> medium-rough dielectric (soft sheen)
            //   ice/gem 27,31          -> very glossy dielectric (wet/shiny)
            //   wood/plank 6,11,12     -> rough-ish, faint sheen
            //   default (grass/dirt..) -> matte (almost no highlight)
            float rough = 0.85;   // matte by default — most of the toy world is matte
            float metal = 0.0;
            if (mat==13u || mat==14u || mat==15u || mat==33u) { rough = 0.30; metal = 0.85; } // metal/ore
            else if (mat==27u || mat==31u)                     { rough = 0.16; metal = 0.0;  } // ice / gem (wet, shiny)
            else if (mat==3u || mat==4u || mat==5u || mat==28u){ rough = 0.62; metal = 0.0;  } // stone / brick
            else if (mat==6u || mat==11u || mat==12u)          { rough = 0.72; metal = 0.0;  } // wood
            // Rain makes top faces wet -> temporarily glossier (lower roughness) for a slick sheen.
            if (in.faceNorm == 2u && wind.rainStrength > 0.01) {
                rough = mix(rough, min(rough, 0.22), wind.rainStrength);
            }
            // Specular exponent from roughness: glossy -> tight bright lobe, matte -> broad dim.
            float specPow  = mix(6.0, 90.0, 1.0 - rough);
            float ndl      = max(0.0, dot(pN, Ld));
            float specRaw  = pow(ndl, specPow);
            // Quantize to a few flat steps so the highlight reads as a crisp toon catch-light.
            float specBands = mix(2.0, 4.0, 1.0 - rough);     // glossier -> a touch more steps
            float specQ     = floor(specRaw * specBands + 0.5) / specBands;
            // Glossier materials get a brighter peak; metals tint the highlight by albedo,
            // dielectrics keep a near-white catch-light. Strength scales smoothly to zero on
            // matte surfaces so grass/dirt stay flat (no PBR clash with the cel banding).
            float gloss    = 1.0 - rough;
            float3 specTint = mix(float3(1.0), normalize(in.color + 1e-3), metal);
            float specAmt  = specQ * (0.10 + 0.30 * gloss);   // restrained peak (<= ~0.40)
            // Keep bright materials (snow/sand) from washing: dim the highlight on already-bright albedo.
            specAmt *= (1.0 - smoothstep(0.60, 0.88, baseLum) * (1.0 - metal));
            // Day/sun + shadow + toggle gating. sunAbove keeps it ZERO at night (washout guard).
            specAdd = specTint * specAmt
                    * clamp(in.shade * 1.4, 0.0, 1.0) * shadowFactor
                    * sunAbove * clamp(wu.pbrStr, 0.0, 1.0);
        }

        // Combined: shade * AO * shadow * bump * detail
        // FIX (#7): clamp pre-bloom output to 1.0 for non-emissive blocks so
        // ordinary sunlit terrain never crosses the bloom bright-pass threshold.
        // Emissive blocks are still allowed to go overbright (they SHOULD bloom).
        //
        // #130 BANDED TOON LIGHTING. The full diffuse multiplier is
        //   lightTerm = shade * bumpLight * AO * shadowFactor
        // which the default path applies as a smooth gradient. When cel-shade is on we
        // QUANTIZE that multiplier into a few flat steps so a lit surface reads as bold
        // flat colour regions with a crisp light/shadow step instead of a soft ramp.
        // Crucially we band the LIGHT multiplier, not the final colour, and we never
        // lift the floor: the darkest band is just the quantized low end of whatever the
        // smooth term already was, so night stays night and a shadowed area lands in a
        // darker band rather than vanishing (the shadowFactor is inside the term).
        float lightTerm = (in.shade * bumpLight) * aoFactor * shadowFactor;
        if (wu.celShade > 0.5 && !isEmissive) {
            // CEL_BANDS flat steps. quantize to band centres so the brightest lit face
            // does not get pushed to a flat 1.0 (keeps material colour, avoids washout),
            // and the lowest band keeps the true dark end (night / deep shadow stay dark).
            const float CEL_BANDS = 4.0;
            float q = floor(lightTerm * CEL_BANDS) / CEL_BANDS;   // band floor in [0,1)
            // Half-step lift puts each region at its band centre; clamp so we never
            // exceed the original term (cannot brighten a surface, only flatten it).
            float banded = min(q + 0.5 / CEL_BANDS, lightTerm > 0.0 ? 1.0 : 0.0);
            // Bias toward the band floor a touch so the steps read crisp and the lit
            // bands stay graphic rather than blown bright.
            lightTerm = mix(q, banded, 0.75);
            // Keep a navigable NIGHT floor. The quantizer crushes the deliberate ~15%
            // night-light floor down toward black (band 0), which is too dark for a kids
            // sandbox. Floor the celled term only at night (scaled by 1-dayLight) so days
            // keep dark crisp shadows but night stays dim-visible like the non-cel build.
            float celNightFloor = 0.14 * (1.0 - dayLight(wu.sunDirTime.w));
            lightTerm = max(lightTerm, celNightFloor);
        }
        float3 col = in.color * detail * lightTerm;
        col += specAdd;                       // #47 normal-mapped sun sheen (pre-clamp)
        if (!isEmissive) col = clamp(col, 0.0, 1.0);

        // Emissive blocks bloom in HDR: push them above 1.0
        if (isEmissive) {
            col *= 1.6;   // HDR overbright → bloom
        }

        // "The Grey": unrestored regions drain toward a DIM, cold grey — not a bright
        // greyscale. FIX (#33, the real "washout"): the old mix(lum, col, sat) kept full
        // brightness, so over bright sand/snow a drained region read as a near-white
        // glare ("washout when not facing N/S" = looking into the unrestored Grey). Now
        // drained = darker + slightly cold, so it reads as a lifeless zone, not a wash.
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        float sat = clamp(in.sat, 0.0, 1.0);
        // Drained = a dim COLD SLATE, brightness-capped by lum so form still reads but
        // it can NEVER wash to white over bright sand/snow (that bright-greyscale was
        // the "washout"). Restores smoothly to full colour as the region is healed.
        float3 drained = float3(0.22, 0.25, 0.32) * (0.45 + lum * 0.85);
        col = mix(drained, col, sat);

        // --- Rain wet-darkening: top faces darken + desaturate slightly in rain ---
        if (wind.rainStrength > 0.01 && !isEmissive) {
            float topFace = (in.faceNorm == 2u) ? 1.0 : 0.3;   // mostly top faces
            // Wet surfaces: darken by ~15% at full rain, slight blue push
            float wetDark = 1.0 - wind.rainStrength * 0.15 * topFace;
            float3 wetTint = float3(0.96, 0.98, 1.02);          // faint cool tone
            col *= wetDark;
            col = mix(col, col * wetTint, wind.rainStrength * 0.35 * topFace);
        }

        // Underwater distance fog
        // FIX (#10): Gentler in-water fog so nearby blocks are clearly visible.
        // k = 0.030 gives ~63% scene colour at 15 blocks and ~55% at 20 blocks.
        // Additionally, smoothstep ramp means blocks 0-4 blocks away have near-zero
        // fog tint; tint builds gradually beyond that. This ensures walls, floor,
        // and ledges directly around the player are clearly readable.
        if (wu.underwater > 0.5) {
            // Flatten directional lighting underwater. Above water, `col` carries the
            // full sun term (in.shade) + bump, which makes a submerged wall flip
            // between bright/dim depending on which way the face points relative to
            // the sun — reading as inconsistent tint/dimming as you look around.
            // Underwater, light is scattered and effectively ambient, so blend the
            // lit colour heavily toward an AO-only flat version: the depth tint then
            // varies only with DISTANCE, never with face direction or view angle.
            // (AO is kept so concave corners still read; sun direction is dropped.)
            float3 flatCol = in.color * detail * aoFactor;   // no in.shade / bump
            if (!isEmissive) flatCol = clamp(flatCol, 0.0, 1.0);
            float flatLum = dot(flatCol, float3(0.299, 0.587, 0.114));
            flatCol = mix(float3(flatLum), flatCol, clamp(in.sat, 0.0, 1.0));
            col = mix(col, flatCol, 0.80);

            float dist = length(in.worldPos - UW_CAM_POS(wu));
            // FIX (#1): The submerged-SOLID fog was over-tinting the lake bottom:
            // at a grazing view the far part of a sandy floor sits 30-50 blocks
            // away, where exp(-0.030*dist) drove fogFactor down to ~0.3, blending
            // the sand ~70% toward WATER_FOG_COL — it blued out completely and
            // vanished into the water while the kelp (lit separately) stayed
            // visible. Two changes keep the bottom readable as SAND, just tinted:
            //   - Gentler coefficient (0.030 -> 0.018) so tint builds far slower
            //     with distance (e.g. at 30 blocks ~58% scene, was ~41%).
            //   - Floor the fog so a submerged solid is NEVER blended more than
            //     45% toward the fog colour. The base albedo always shows through,
            //     so sand stays sandy (just blue-tinted), never a flat blue wall.
            float rawFog = exp(-0.018 * dist);
            // Ramp: no tint at all within 4 blocks; smoothly add fog beyond that.
            float ramp = smoothstep(4.0, 14.0, dist);
            float fogFactor = clamp(mix(1.0, rawFog, ramp), 0.0, 1.0);
            // Keep at least 55% of the surface's own albedo at any distance so the
            // material (sand/dirt/stone) always stays distinguishable from water.
            fogFactor = max(fogFactor, 0.55);
            // Same colour the full-screen overlay uses (WATER_FOG_COL) so the
            // submerged-solid tint and the water volume read as one body of water.
            col = mix(WATER_FOG_COL, col, fogFactor);
        } else {
            // Atmospheric distance fog — ONLY the far edge, to hide chunk pop-in.
            // FIX (#33, the real washout): this range was tuned for the old ~256-block
            // render distance (fog 150→270). Render distance is now 24 chunks = 384
            // blocks, so 150→270 fogged the far 2/3 of every open vista — looking E/W
            // across open beach/desert you saw far and the whole mid-field washed pale,
            // while N/S was blocked by hills so it stayed clear. THAT was the directional
            // "washout when not facing N/S." Pushed the start out to ~290 and capped at
            // 0.32 so only the last ~25% of the view hazes; the field stays clear.
            float3 camPos3 = UW_CAM_POS(wu);
            float dist = length(in.worldPos - camPos3);
            // #120 GENTLE natural haze only. The strong artificial EDGE-haze band (340..384,
            // up to ~0.78) that was added to MASK the old shadow-fade ring is GONE: it was
            // itself a discrete band that swept across the land as the camera turned (the
            // player still saw the wipe). With shadows now full across the whole vista and the
            // fade pushed to the very render edge, there is no ring left to mask, so the fog
            // returns to a single soft haze that only just tints the far quarter of the view to
            // hide chunk pop-in. Onset ~290, capped at 0.32 (the pre-edge-haze behaviour). The
            // near/mid field stays clear so the player SEES the land.
            float fog = smoothstep(290.0, 384.0, dist) * 0.32;
            // Gate the haze colour by day/night. Ungated, this muted-blue haze stayed bright
            // at night, so the far render edge washed PALE/WHITE over dark night terrain (the
            // long-hunted night "white ground": worst looking E/W across open distance, which
            // is just where the most far terrain is visible). Fade it to a dark night haze so
            // distant terrain blends into the night instead of glowing. (0.12 floor keeps a
            // faint dark haze rather than pure black.)
            float fogDay = 0.12 + 0.88 * dayLight(wu.sunDirTime.w);
            float3 horizFogColor = float3(0.46, 0.56, 0.70) * fogDay;
            col = mix(col, horizFogColor, fog);
        }

        return float4(col, 1.0);
    }

    // =========================================================
    // WATER TRANSLUCENCY FRAGMENT SHADER
    // Same vertex shader as terrain (vmain). Discards any fragment whose material
    // is not 9 (water) so only water surfaces are drawn. Outputs alpha 0.55 for
    // translucent blending over the lake bottom already in the colour buffer.
    // Depth write is OFF (set by waterDepthState), depth test is lessEqual.
    // =========================================================
    // Reflective water (#43) samples the sky along the reflected ray. evalSkyColor
    // is defined further down (after cloudFbm); declare it here so water can call it.
    float3 evalSkyColor(float3 ray, float3 sd, float t, float clk, float cloudsOn, float weatherPack, float2 pixelCoord);

    fragment float4 waterFmain(VOut in [[stage_in]],
                               constant WaterUniforms& wu [[buffer(2)]],
                               constant WindUniforms& wind [[buffer(3)]],
                               texture3d<uint, access::read> occ    [[texture(0)]],
                               texture3d<uint, access::read> occCoarse [[texture(1)]]) {
        // #68 glass (25 clear, 26 colored): a light see-through pane, rendered in this
        // translucent pass. The mesher culls glass-to-glass faces, so a wall of panes
        // reads as one continuous sheet (connected glass), not a per-block grid.
        if (in.material == 25u || in.material == 26u) {
            bool colored = (in.material == 26u);
            float3 tint  = colored ? float3(0.40, 0.70, 0.95) : float3(0.82, 0.91, 0.98);
            float  alpha = colored ? 0.46 : 0.22;
            float  lit   = clamp(in.shade, 0.45, 1.0);
            return float4(tint * lit, alpha);
        }
        // Only render water (material id 9); discard all other blocks.
        if (in.material != 9u) discard_fragment();

        float t = wu.wallClockSecs;
        float2 uv = in.worldPos.xz;
        float wave1 = noise2(uv * 0.8  + float2( t * 0.22,  t * 0.14));
        float wave2 = noise2(uv * 1.40 + float2(-t * 0.17,  t * 0.28));
        float wave3 = noise2(uv * 2.80 + float2( t * 0.35, -t * 0.19));
        float ripple = wave1 * 0.50 + wave2 * 0.35 + wave3 * 0.15;
        float rippleN = ripple * 2.0 - 1.0;

        // Single shared base colour (WATER_SURFACE_COL) so the surface always
        // matches the submerged-solid tint and the underwater overlay.
        float3 waterBase = WATER_SURFACE_COL;

        // Normal perturbation for specular
        float2 nAB = float2(
            noise2(uv * 1.2 + float2(t * 0.22 + 0.1, t * 0.14)) - wave1,
            noise2(uv * 1.2 + float2(t * 0.22, t * 0.14 + 0.1)) - wave1
        ) * 4.0;
        float3 perturbedN = normalize(float3(nAB.x, 1.4, nAB.y));
        float3 sunDir3 = normalize(-wu.sunDirTime.xyz);   // real sun, so glint lands correctly (#43)
        // NIGHT FIX (mirror of fmain): gate the sun glint so it cannot glow once the sun
        // is below the horizon (sunDir.y > 0 means the sun has set).
        float sunAbove = smoothstep(0.0, -0.12, wu.sunDirTime.y);   // 1 sun up .. 0 sun set
        float spec = pow(max(0.0, dot(perturbedN, sunDir3)), 22.0) * sunAbove;

        // Shadow + AO (sample the precomputed half-res shadow, same as fmain)
        float aoFactor = mix(0.45, 1.0, in.ao);
        float dayFactor = clamp(in.shade * 1.5, 0.0, 1.0);
        float rawShadow = 1.0;
        if (wu.shadowScale > 0.5 && dayFactor > 0.001) {
            float3 toSun = normalize(-wu.sunDirTime.xyz);
            rawShadow = voxelSunShadow(occ, occCoarse, wu.voxOrigin.xyz, wu.voxDims.xyz,
                                       in.worldPos + float3(0, 0.25, 0), toSun, wu.voxOrigin.w, wu.voxDims.w);
        }
        float shadowStrength = 0.65 * dayFactor;
        float shadowFactor = 1.0 - shadowStrength * (1.0 - rawShadow);

        float3 col = waterBase * in.shade * aoFactor * shadowFactor;
        col *= 1.0 + rippleN * 0.18;

        // Surface highlights (sky reflection + sun specular) belong ONLY on the
        // top face. On side faces the old fresnelBias (0.06) still pushed a cool
        // brightening that, combined with cull-none double-sided side quads, made
        // edges flip/shimmer at grazing angles. Gate both highlight terms to the
        // up-facing surface so side faces stay a flat, stable water colour.
        bool topFace = (in.faceNorm == 2u);
        if (topFace) {
            // #43 cozy reflective water: mirror the ACTUAL sky (sun glint, sunset
            // hues, clouds) off the rippled surface, blended by Fresnel. Capped
            // below a full mirror so the lake bottom still reads and it stays
            // readable for kids; the final clamp keeps it out of the bloom range.
            float3 camP    = UW_CAM_POS(wu);
            float3 viewDir = normalize(in.worldPos - camP);
            float3 refl    = reflect(viewDir, perturbedN);
            refl.y = max(refl.y, 0.02);                       // keep the bounce skyward
            // cloudsOn=0 for the water reflection: the volumetric raymarch is skipped in the
            // bounce (it would double the cloud cost per water fragment for a subtle gain).
            float3 skyRefl = evalSkyColor(normalize(refl),
                                          wu.sunDirTime.xyz, wu.sunDirTime.w, t, 0.0,
                                          wu.weatherPack, float2(0.0));
            float ndv     = max(0.0, dot(-viewDir, perturbedN));
            float fres    = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);   // Schlick, F0≈0.02
            // NIGHT GROUND-WASH FIX (#117): the Fresnel sky reflection was NOT gated by
            // day/night. At night evalSkyColor returns a sky that is brighter toward the
            // sun's azimuth (the moon halo + horizon haze + low-elevation stars all sit on
            // the sun/moon E/W plane), so the reflected view ray hit that bright band only
            // when the camera faced E/W. The water then washed pale toward E/W and stayed
            // its dark night colour facing N/S -- the player's view-direction-dependent
            // night "ground" wash (water surfaces over the terrain). Daytime is unaffected
            // (dayLight==1), and a clear night sky has nothing bright to mirror anyway, so
            // fade the reflection out with day brightness. The moon/star sky is still drawn
            // by the sky pass; only the water MIRROR of it stops washing the surface.
            float dayRefl = dayLight(wu.sunDirTime.w);   // 1 day .. 0 night (same gate as terrain)
            // #138 DAYTIME WATER WASH FIX: the raw daytime sky is a bright near-white sheet,
            // and mirroring it straight onto the surface made water read as a pale white
            // panel that dominated daylight scenes. Tint the reflected sky toward a believable
            // deep water-blue and pull its brightness down BEFORE the Fresnel blend, so the
            // surface still mirrors the sky's HUE and the sun glint (sky reflection is kept,
            // just much less blown-out) but reads as blue water, not a white mirror. This is
            // gated by dayRefl (=daytime only): the night path is untouched (dayRefl~0 there
            // already fades the whole reflection out), so the night ground-whiteout cannot
            // return. tintAmt and the lower reflAmt ceiling are the two day-only knobs.
            // The reflected daytime sky is a bright, near-white sheet. We must keep it
            // CLEARLY reflecting (so water still mirrors the sky and the day reflection stays
            // visible) but stop it reading as a blown-out white panel. Two daytime-only steps:
            //  1) HUE: push the reflection toward water-blue so a clear sky mirrors as blue,
            //     not white, but keep most of its brightness so the reflection is still a
            //     distinct, visible highlight on the surface (not flattened into the base).
            //  2) BRIGHTNESS CAP: clamp the reflected luminance to a ceiling so the brightest
            //     part of the sky can't push the surface into the white/bloom range.
            // Both are gated by dayRefl, so the night path (and the night ground-whiteout
            // guard) is untouched: at night dayRefl~0 so skyRefl is unchanged and reflAmt~0.
            // NOTE: we fold these INTO skyRefl and keep the `col = mix(col, skyRefl, reflAmt)`
            // blend line verbatim below, because the --groundnighttest gate string-replaces
            // that exact line to neutralize the reflection for its A/B.
            float3 waterTint = float3(0.30, 0.52, 0.78);   // believable blue-water reflection hue
            float skyLuma    = dot(skyRefl, float3(0.299, 0.587, 0.114));
            // Re-tint toward blue while preserving the sky's relative brightness (so a clear
            // bright sky still reads as a bright blue reflection, a sunset still warm). Modest
            // mix so the reflection stays a real, visible highlight (keeps the day-reflection
            // gate happy) rather than collapsing onto the water base colour.
            float tintAmt    = 0.55 * dayRefl;
            float3 blueRefl  = waterTint * (0.45 + 0.85 * skyLuma);
            skyRefl = mix(skyRefl, blueRefl, tintAmt);
            // Cap the reflected luminance in daytime so the brightest sky cannot blow the
            // surface to white (the #138 wash), without dimming a normal blue reflection.
            float cap = mix(10.0, 0.62, dayRefl);          // day: ceiling 0.62 ; night: no cap
            float curLuma = dot(skyRefl, float3(0.299, 0.587, 0.114));
            if (curLuma > cap) skyRefl *= cap / max(curLuma, 1e-3);
            // Lower the daytime ceiling (0.60 -> 0.42) so a grazing Fresnel edge no longer
            // turns the surface into a near-full sky mirror. Night unaffected (dayRefl gate).
            float reflAmt = clamp(fres * 0.9 + 0.05, 0.0, 0.42) * wu.reflectScale * dayRefl;
            col = mix(col, skyRefl, reflAmt);
            col += float3(1.0, 0.98, 0.88) * spec * 0.45 * in.shade;
        }

        // Saturation — drained water matches terrain: a dim cold slate, not bright
        // greyscale (which read as washout). (#33)
        // #153 CHUNK-LINE PLANES FIX: in.sat is the per-REGION saturation the terrain uses
        // for the danger-site / regrowth "drain" (default DIM_SAT=0.18 until a region is
        // restored). It is uniform per region and bilinearly blended per chunk, so applying
        // it to the OCEAN surface painted whole regions of water grey while restored
        // neighbours stayed blue -- reading as large flat pale planes with hard seams on the
        // region/chunk grid (the reported "chunk-line grid in the water"). The ocean is a
        // single global body, not danger-site terrain that regrows, so it must read as one
        // continuous blue surface everywhere. Floor the water saturation high so a drained
        // region can still cool the tint very slightly (keeps a drained puddle from looking
        // out of place) but can never grey the sea into per-region planes. This removes the
        // seams without touching the mesh or the day/night-gated reflection above.
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        float sat = clamp(in.sat, 0.85, 1.0);
        float3 drained = float3(0.22, 0.25, 0.32) * (0.45 + lum * 0.85);
        col = mix(drained, col, sat);
        col = clamp(col, 0.0, 1.0);

        // Alpha is constant per face orientation only (never view-angle dependent),
        // so the surface never vanishes at grazing angles and never double-blends
        // unevenly. Top face slightly more opaque (you mostly look down through it);
        // side faces a touch more see-through so shorelines read cleanly.
        // FIX (#1): Lowered (top 0.58 -> 0.42, side 0.50 -> 0.38) so the sandy
        // lake bottom is clearly visible THROUGH the surface from above instead of
        // being hidden behind a near-opaque blue sheet. The surface still reads as
        // water (colour + specular + fresnel on the top face) but no longer stacks
        // a heavy blue layer on top of the (now-readable) submerged terrain.
        float alpha = topFace ? 0.42 : 0.38;
        return float4(col, alpha);
    }

    // =========================================================
    // SKY PASS — fullscreen triangle, no depth write
    // =========================================================
    struct SkyUniforms {
        float4 sunDirTime;
        float4 camRight;
        float4 camUp;
        float4 camFwd;
    };
    struct SkyVOut { float4 position [[position]]; float2 ndc; };

    vertex SkyVOut skyVmain(uint vid [[vertex_id]],
                            constant SkyUniforms& su [[buffer(0)]]) {
        float2 pos;
        if      (vid == 0u) pos = float2(-1.0, -1.0);
        else if (vid == 1u) pos = float2( 3.0, -1.0);
        else                pos = float2(-1.0,  3.0);
        SkyVOut o;
        o.position = float4(pos, 0.9999, 1.0);
        o.ndc      = pos;
        return o;
    }

    // Cloud-only FBM rotates each octave away from the value-noise lattice. Keeping
    // the same three noise reads preserves the old cost, while removing the large
    // axis-aligned interpolation cells that read as changing sky squares on a slow turn.
    static float cloudFbm(float2 p) {
        float2 p1 = float2(0.80 * p.x - 0.60 * p.y,
                           0.60 * p.x + 0.80 * p.y);
        float2 p2 = float2(0.36 * p.x + 0.93 * p.y,
                          -0.93 * p.x + 0.36 * p.y);
        return noise2(p1) * 0.46
             + noise2(p2 * 1.9 + float2(3.7, 1.1)) * 0.34
             + noise2(p * 3.8 + float2(1.3, 5.7)) * 0.20;
    }

    // ===================================================================
    // #47 VOLUMETRIC CLOUDS — bold/toy-styled raymarched cumulus.
    // ===================================================================
    // Cheap 3D value noise (trilinear hash lerp). Reuses the same integer hash the
    // 2D noise uses so the cost is 8 hashes per sample, no trig, no texture fetch.
    static float cloudHash3(float3 i) {
        int3 ii = int3(i);
        uint x = uint(ii.x + 32768);
        uint y = uint(ii.y + 32768);
        uint z = uint(ii.z + 32768);
        return uhash(x * 1597u ^ y * 2749u ^ z * 3433u);
    }
    static float cloudNoise3(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);                 // smootherstep weights
        float c000 = cloudHash3(i + float3(0,0,0));
        float c100 = cloudHash3(i + float3(1,0,0));
        float c010 = cloudHash3(i + float3(0,1,0));
        float c110 = cloudHash3(i + float3(1,1,0));
        float c001 = cloudHash3(i + float3(0,0,1));
        float c101 = cloudHash3(i + float3(1,0,1));
        float c011 = cloudHash3(i + float3(0,1,1));
        float c111 = cloudHash3(i + float3(1,1,1));
        float x00 = mix(c000, c100, f.x);
        float x10 = mix(c010, c110, f.x);
        float x01 = mix(c001, c101, f.x);
        float x11 = mix(c011, c111, f.x);
        return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
    }
    // Cloud density field at a world-ish sample point. The dominant octave is LOW
    // frequency so the forms are big chunky lobes (bold toy cumulus), with one small
    // higher octave for a fluffy edge. A tight smoothstep carves defined, hard-ish
    // edges (not wispy haze) and squashing Y keeps the slab reading as flat-bottomed
    // cumulus rather than vertical streaks. wind drifts the field over time. 0..1.
    static float cloudDensity(float3 p, float wind, float cover) {
        // Start away from the integer lattice origin and drift on non-matching
        // X/Z speeds. The old scalar `p.xz += wind` could sit on a diagonal hash
        // alignment for the first seconds after load, then visibly "heal" as wind
        // moved the cloud field off that unlucky lattice.
        p.x += wind * 0.73 + 37.0;
        p.z += wind * 1.11 - 19.0;
        // Scale DOWN hard so the noise cells are big (tens of units across): looking up
        // through the slab a screen region stays inside one lobe (big puffs, no speckle).
        // Y is squashed so the puffs are wide and flat-bottomed like real cumulus.
        // Roughly ISOTROPIC scale (only mild Y squash) so the puffs have real VERTICAL
        // structure: a near-vertical view ray then passes through varying density inside a
        // puff, which the sun light-march turns into internal 3D shading (bright crown,
        // shadowed base) instead of a flat overcast disc. Cells are ~30-40 units wide.
        float3 q = p * float3(0.026, 0.020, 0.026);
        // #140 DOMAIN WARP: nudge the sample by a low-frequency 3D noise so the lobes are not
        // axis-aligned to the integer-hash grid. This breaks the residual grid/streak look of
        // the trilinear value noise into rounded, separated, organic puffs while staying cheap
        // (one extra low-octave fetch per axis-shared warp). The warp also adds real vertical
        // variation so a near-vertical view ray crosses lobe boundaries (chunky, not layered).
        float3 w3 = float3(cloudNoise3(q * 0.7 + float3(11.3, 5.1, 19.7)),
                           cloudNoise3(q * 0.7 + float3(31.7, 17.9, 3.3)),
                           cloudNoise3(q * 0.7 + float3(7.2, 23.4, 41.1)));
        q += (w3 - 0.5) * 0.85;
        float base = cloudNoise3(q);                   // big puffy lobes (dominant)
        base += cloudNoise3(q * 2.1) * 0.24;           // medium billow
        base += cloudNoise3(q * 4.0) * 0.05;           // soft edge detail
        base /= 1.29;
        // Soft shaping: keep the chunky cumulus layout, but avoid hard, high-frequency
        // silhouettes that can read as detached shredding while the wind moves the field.
        float lo = 0.52 - cover * 0.16;
        float d  = smoothstep(lo, lo + 0.16, base);
        return d;
    }

    // Sky colour along a view ray (gradient, sun/moon, stars, clouds, weather).
    // Shared by the sky pass AND reflective water (#43) — forward-declared above
    // waterFmain. Does NOT apply the underground fade (that's sky-pass only).
    float3 evalSkyColor(float3 ray, float3 sd, float t, float clk, float cloudsOn, float weatherPack, float2 pixelCoord) {
        // dayT now tracks the real sun elevation (see dayLight) so the sky darkens
        // when the sun actually sets, instead of staying lit until t~1.0 (the old
        // sin(t*pi) was a quarter-cycle out of phase with the sun arc). The sun
        // crosses the horizon at t~0.54 (dusk) and t~0.96 (dawn), so the warm
        // sunset/sunrise tint is centred there now (it used to peak at t=0.25/0.75,
        // which with the corrected dayT would have painted midnight orange).
        float dayT    = dayLight(t);
        float dawnT   = max(0.0, 1.0 - abs(t - 0.96) * 8.0);
        float duskT   = max(0.0, 1.0 - abs(t - 0.54) * 8.0);
        float sunsetT = dawnT + duskT;

        float3 zenithDay    = float3(0.16, 0.42, 0.88);
        float3 horizDay     = float3(0.58, 0.76, 0.92);   // warmer horizon (less cold-grey)
        float3 zenithSunset = float3(0.22, 0.14, 0.45);
        float3 horizSunset  = float3(1.00, 0.52, 0.18);
        float3 zenithNight  = float3(0.03, 0.04, 0.12);
        float3 horizNight   = float3(0.08, 0.10, 0.22);

        float3 zenith = mix(mix(zenithNight, zenithDay, dayT), zenithSunset, sunsetT * 0.7);
        float3 horiz  = mix(mix(horizNight,  horizDay,  dayT), horizSunset,  sunsetT * 0.85);

        float gradT  = smoothstep(0.0, 0.45, ray.y);
        float3 skyCol = mix(horiz, zenith, gradT);

        float3 groundCol = mix(float3(0.20, 0.16, 0.12), float3(0.35, 0.30, 0.22), dayT);
        skyCol = mix(groundCol, skyCol, smoothstep(-0.05, 0.08, ray.y));

        float horizBand = exp(-abs(ray.y) * 12.0);
        float3 hazeCol = mix(float3(0.62, 0.74, 0.92), float3(1.00, 0.70, 0.40), sunsetT * 0.7);
        skyCol = mix(skyCol, hazeCol, horizBand * 0.18 * dayT + horizBand * 0.25 * sunsetT);

        float3 sunDir3 = normalize(-sd);
        float sunDot = dot(ray, sunDir3);
        // FIX (#33, 2nd pass): SHRINK the disc. sunDisc/sunInner are now both
        // tighter than before so the visible sun is a small dot, not a wide blob.
        //   sunDisc:  smoothstep(0.9988,1.0) → ~2.8° half-angle (was 0.9975 / ~4°)
        //   sunInner: smoothstep(0.9996,1.0) → ~1.6° half-angle (was 0.9992 / ~2.3°)
        float sunDisc  = smoothstep(0.9965, 0.9990, sunDot);   // BIGGER, distinct disc (#33: sun/moon size)
        float sunInner = smoothstep(0.9986, 0.9994, sunDot);   // bright warm core (feeds discHDR)
        // FIX (#33): The washout when turning was direction-dependent — it only
        // happened when the view looked toward the sun's azimuth (E/W/diagonal,
        // since the sun arcs East-West). Facing N/S kept the sun off-frame so the
        // glow terms were ~0 and the scene looked fine.
        //
        // The remaining culprit after the 1st pass (capping broad sky to 0.92) was
        // the SUN DISC HDR: `discHDR` was ADDED AFTER the 0.92 cap and reached ~1.5
        // HDR — sitting right at the bloom bright-pass foot (smoothstep 1.60..2.80),
        // so when the sun was in frame its disc fed the bloom blur and smeared a
        // bright halo across the screen = washout. Facing N/S the disc was off-frame
        // so nothing bloomed.
        //
        // This pass: (1) shrink the disc (above); (2) DIM the glow cones further so
        // even the near-disc region stays modest; (3) lower the disc HDR so its peak
        // stays comfortably BELOW the bloom threshold (target ≤ ~1.25 vs 1.60 floor)
        // — a small bright sun that does NOT bloom; (4) keep the hard 0.92 cap on the
        // entire broad sky. Net: no sunDot-gated term can flood the frame, and the
        // disc no longer crosses the bright-pass threshold.
        // The broad directional glow cones were removed (the 0.92 broad-sky cap below
        // clamped them anyway). The real dusk "light thing" toward E/W is the LOW SUN
        // reading as a bright glaring orb. Fix: fade the white-hot core + HDR boost out
        // as the sun nears the horizon, so a setting sun is a soft orange orb — still a
        // clear, distinct disc, but it no longer brightens the E/W view. (#33)
        float3 sunColor  = mix(float3(1.0, 0.50, 0.16), float3(1.0, 0.95, 0.80), dayT);  // orange low, warm-white high
        float sunVis  = max(dayT, sunsetT * 0.6);
        float sunHigh = smoothstep(-0.02, 0.28, sunDir3.y);   // 0 at/below horizon → 1 when well up
        skyCol = mix(skyCol, sunColor,             sunDisc  * sunVis);
        skyCol = mix(skyCol, float3(1.0, 0.99, 0.92), sunInner * sunVis * mix(0.25, 1.0, sunHigh));
        // (#66 sun corona removed: a warm ring around the sun brightened the whole E/W
        //  sky and washed out the view toward the sun's arc unless you faced N/S. The
        //  white moon already makes the two distinct; the sun does not need the ring.)

        // HDR: a SMALL boost on the tight inner disc so the sun reads as a crisp
        // bright dot — but kept BELOW the bloom bright-pass floor (1.60). Under
        // sunInner=1 the skyCol is already ~1.0 (mixed to near-white above); adding
        // 0.22 gives a disc peak of ~1.22 HDR < 1.60, so the disc no longer feeds
        // bloom. discHDR is gated on the TIGHT sunInner disc only, so this never
        // touches the broad sky.
        float3 discHDR = sunColor * 0.22 * sunInner * sunVis * mix(0.15, 1.0, sunHigh);   // no HDR glare when low
        skyCol += discHDR;

        // FIX (#33): Hard-cap EVERYTHING — including the disc HDR — to ≤1.25. This
        // guarantees no view direction (broad sky capped to 0.92 below; disc capped
        // to 1.25 here) can ever cross the 1.60 bloom threshold or reach the ACES
        // white point, so facing the sun reads the same exposure as facing N/S.
        // The broad sky (everything except the tight disc) is still pinned at ≤0.92.
        skyCol = clamp(skyCol - discHDR, 0.0, 0.92) + discHDR;
        skyCol = min(skyCol, float3(1.25));

        // Moon (#66): a bright WHITE moon, clearly distinct from the warm sun. Crisp
        // white body with subtle grey craters, a faint cool halo, and a gentle night
        // glow so it reads as luminous (vs the sun's warm cratered-free corona disc).
        float3 moonDir3 = -sunDir3;
        float moonDot  = dot(ray, moonDir3);
        float nightAmt = 1.0 - dayT;
        float moonHalo = smoothstep(0.9840, 0.9965, moonDot) * nightAmt;  // wide faint glow ring
        float moonBody = smoothstep(0.9965, 0.9992, moonDot) * nightAmt;  // the disc
        if (moonHalo > 0.001) {
            skyCol = mix(skyCol, float3(0.80, 0.85, 0.98), moonHalo * 0.16);
        }
        if (moonBody > 0.001) {
            float2 mlocal = float2(ray.x - moonDir3.x, ray.z - moonDir3.z) * 150.0;
            float mare  = smoothstep(0.42, 0.74, noise2(mlocal));          // big maria blotches
            float crater = smoothstep(0.62, 0.80, noise2(mlocal * 3.1));   // small crater speckle
            float3 moonCol = mix(float3(0.98, 0.99, 1.00), float3(0.78, 0.82, 0.90), mare * 0.45);
            moonCol = mix(moonCol, float3(0.72, 0.76, 0.84), crater * 0.30);
            skyCol = mix(skyCol, moonCol, moonBody);
            // gentle HDR glow (night sky is dark, so this stays well below bloom).
            skyCol += float3(0.10, 0.11, 0.14) * moonBody * nightAmt;
        }

        if (dayT < 0.5) {
            float starFade = 1.0 - smoothstep(0.05, 0.35, dayT);
            // Only render stars well above the horizon — the perspective division
            // ray.xz/ray.y blows up at low elevation and produces long streaks.
            float starElev = smoothstep(0.10, 0.22, ray.y);  // zero below 10° elevation
            starFade *= starElev;
            if (starFade > 0.001) {
                // Project onto a flat sky dome: UV is stable for ray.y > 0.10.
                float2 starUV = floor((ray.xz / max(ray.y, 0.10)) * 60.0 + float2(200.0));
                // Hash must not mix x*y (that produces visible diagonal streaks).
                float starH = uhash(uint(starUV.x + 5000.0) * 3141u
                                    ^ uint(starUV.y + 5000.0) * 1618u);
                float starBright = step(0.986, starH);
                skyCol += float3(starBright * starFade * 0.90);
            }
        }

        // #162 weather-driven sky. The old free-running sin(clk) weatherCycle is
        // gone: coverage + precip now come from the engine weather state via
        // weatherPack (precip mode * 2 + coverage * 0.98), deterministic per
        // world seed + world clock, frozen while paused.
        int   wPrecip = int(weatherPack * 0.5 + 0.25);   // 0 none, 1 rain, 2 snow
        float cover   = clamp((weatherPack - float(wPrecip) * 2.0) / 0.98, 0.0, 1.0);
        float overcast = smoothstep(0.55, 0.92, cover) * 0.65;
        float rainStrength = (wPrecip == 1) ? 1.0 : ((wPrecip == 2) ? 0.6 : 0.0);

        if (overcast > 0.01) {
            float cloudPlaneHit = (ray.y > 0.02) ? (1.0 / ray.y) : 0.0;
            float2 ocUV = ray.xz * cloudPlaneHit * 0.35 + float2(clk * 0.006, clk * 0.003);
            float ocCloud = cloudFbm(ocUV * 1.5);
            // Storm clouds: thicker, darker underbellies when raining
            float stormDark = mix(0.55, 0.35, rainStrength);
            float stormBright = mix(0.80, 0.62, rainStrength);
            ocCloud = smoothstep(0.38 - rainStrength * 0.08, 0.62, ocCloud);
            float3 ocColor = mix(float3(stormDark, stormDark + 0.02, stormDark + 0.09),
                                 float3(stormBright, stormBright + 0.02, stormBright + 0.06),
                                 dayT);
            // #162 night gate: an overcast sheet at night must be DARK (a 0.55 grey
            // over the 0.05 night sky read as a pale wash). Keep a whisper of
            // moonlit grey so the sheet still exists, but no night brightening.
            ocColor *= mix(0.16, 1.0, dayT);
            float ocFade = smoothstep(0.0, 0.12, ray.y);
            skyCol = mix(skyCol, ocColor, ocCloud * overcast * ocFade);
        }

        // Lightning: rare (appears ~every 45s during storm), brief full-sky flash.
        // Rain only (#162): snow's soft dimming must not flash.
        if (wPrecip == 1) {
            // Use a sawtooth phase in seconds, trigger a flash near the top.
            float ltPhase = fmod(clk * (1.0 / 45.0), 1.0);
            float ltFlash = smoothstep(0.97, 0.99, ltPhase) * smoothstep(1.00, 0.99, ltPhase);
            // Only light the sky-facing rays (not ground)
            ltFlash *= smoothstep(0.0, 0.15, ray.y);
            // FIX (night whiteout): the old amp was rainStrength*ltFlash*2.5 — a mix
            // factor up to 2.5, so mix(skyCol, white, amp) EXTRAPOLATED far past white
            // (skyCol + 2.5*(white-skyCol) ~= 2.4 HDR over the whole sky). At night the
            // dark sky got lifted to ~2.4, which sails past the bloom bright-pass floor
            // (1.60) so the entire sky bloomed and ACES mapped it to a full white-out
            // that washed the night scene. Cap the mix factor to <=1 (never overshoot
            // past the flash colour) and keep the flash colour below the bloom floor so
            // a flash is a brief visible brighten, not a screen-wide white bloom.
            float ltAmp = clamp(rainStrength * ltFlash, 0.0, 0.85);
            skyCol = mix(skyCol, float3(0.88, 0.92, 1.00), ltAmp);
        }

        // Rain/snow precipitation is now rendered as animated screen-space
        // streaks/flakes in the composite pass — not here in the sky.
        // (Kept the overcast / storm-cloud darkening above, which correctly
        //  dims the sky during rain; the actual falling precipitation is
        //  composited on top of the final LDR image for cheapness.)

        // #162 coverage gate: at near-zero coverage the cloud layer is fully OFF,
        // giving a genuinely clear blue sky (the old constant-coverage layer made
        // every day read as partly cloudy). Day/night gate (no wash at night) and
        // the hard cloudsOn toggle are unchanged. The ray must point above the
        // horizon to enter the cloud slab.
        float cloudVis  = smoothstep(0.12, 0.38, dayT)
                        * smoothstep(0.08, 0.20, ray.y)
                        * smoothstep(0.02, 0.10, cover)
                        * clamp(cloudsOn, 0.0, 1.0);
        if (cloudVis > 0.001) {
            // #146: smooth, bold sky-projected cumulus. This is a 2D layer painted on the
            // sky dome, NOT a raymarch: there is no per-step march to beat against, so it
            // cannot produce the scaly/fish-scale ripple the bounded 3D march did, and no
            // start-jitter to decorrelate.
            //
            // The ripple in the PREVIOUS 2D attempt came from the PROJECTION, not the noise:
            // it divided ray.xz by ray.y (a flat plane at infinity), so near the horizon the
            // UV scale blew up (1/0.10 = 10x) and packed many noise cells into a few pixels.
            // That undersampling aliased into concentric wave striations, and because the
            // scale is a pure function of elevation the pattern slid as a moving beat when
            // the camera turned. Divide by (ray.y + k) with a constant floor instead: at the
            // horizon the scale is ~1/0.42 rather than 1/0.10, so the on-screen noise
            // frequency stays bounded and smooth from ANY camera angle. No 1/ray.y blow-up
            // means no undersampling means no ripple.
            float cloudClk = clk + 18.0;
            float2 cuv = ray.xz / (ray.y + 0.42) * 1.10 + float2(cloudClk * 0.010, cloudClk * 0.006);
            // Two smooth octaves only: a dominant LOW-frequency octave lays out big chunky
            // lobes (bold puffs, not speckle) and one medium octave rounds their edges. A
            // tight smoothstep on a low threshold carves defined, opaque puff cores (bold
            // toy cumulus) instead of the thin translucent haze the old sheet showed.
            float broad = cloudFbm(cuv);
            float soft  = cloudFbm(cuv * 1.90 + float2(7.3, -3.9));
            float field = broad * 0.72 + soft * 0.28;
            // #162 COVERAGE CONTROL: the smoothstep threshold slides with the weather
            // coverage. Low cover carves only the densest lobes into small scattered
            // puffs; mid cover is the classic partly-cloudy layout; high cover drops
            // the threshold so the field closes into a near-continuous overcast sheet.
            // The band stays narrow (defined puff edges, no aliasing) at every cover.
            float lo    = mix(0.68, 0.16, cover);
            float mask  = smoothstep(lo, lo + 0.20, field);
            // Horizon fade (the slab edge does not hard-line) plus a soft fade toward zenith.
            // smoothstep requires ordered edges; the old reversed call was undefined.
            mask *= smoothstep(0.14, 0.34, ray.y)
                  * (1.0 - smoothstep(0.62, 1.02, ray.y));
            // Bold lit crown / cool shadow base, warmed at sunrise/sunset. Sun-facing puffs
            // read brighter via a gentle continuous gradient (no banding, no quantize).
            float3 cloudTop  = mix(float3(0.95, 0.97, 1.00), float3(1.00, 0.84, 0.62), sunsetT * 0.55);
            float3 cloudBase = mix(float3(0.62, 0.68, 0.80), float3(0.60, 0.46, 0.52), sunsetT * 0.45);
            // #162 as coverage closes toward a full sheet, flatten the palette toward
            // an even grey so heavy skies read overcast (dimmer, low-contrast) rather
            // than a wall of bright toy puffs. Rain darkens the sheet a step further.
            float sheet = smoothstep(0.65, 0.95, cover);
            cloudTop  = mix(cloudTop,  float3(0.78, 0.80, 0.85), sheet);
            cloudBase = mix(cloudBase, float3(0.50, 0.53, 0.61), sheet);
            cloudTop  *= 1.0 - rainStrength * 0.18;
            cloudBase *= 1.0 - rainStrength * 0.18;
            float lit = smoothstep(-0.20, 0.70, dot(ray, sunDir3));
            float3 cloudColor = mix(cloudBase, cloudTop, 0.45 + 0.55 * lit);
            // Bolder presence than the old faint sheet (0.58/cap 0.70 -> 0.90/cap 0.90) so the
            // puffs read clearly, while still letting a little sky breathe through the thin
            // edges (keeps the washout guard happy: cloud pixels stay tinted, never full white).
            skyCol = mix(skyCol, cloudColor, clamp(mask * cloudVis * 0.90, 0.0, 0.90));
        }
        if (false && cloudVis > 0.001) {
            // #47 REAL raymarched VOLUMETRIC clouds, styled BOLD/TOY (chunky, defined,
            // fluffy cumulus with a touch of cel banding and a bright sun rim), NOT wispy
            // photoreal haze. The clouds live in a slab between two heights; we intersect
            // the view ray with that slab and march a BOUNDED number of steps, accumulating
            // density front-to-back. A cheap 2-tap density step toward the sun gives real
            // self-shadowing so sun-facing billows are bright and undersides go shadowed.
            //
            // Perf: the slab + bounded step count caps the cost. Only sky-facing rays march
            // (cloudVis gates ray.y), the whole thing is skipped at night and when toggled
            // off, and the march short-circuits once the accumulated alpha is near opaque.
            const float CLOUD_BOTTOM = 55.0;
            const float CLOUD_TOP    = 145.0;  // thick slab -> vertical structure, 3D puffs
            const int   CLOUD_STEPS  = 44;     // THE perf knob (bounded march length)
            const float CLOUD_MID    = 100.0;  // slab centre (for the rounded vertical taper)
            const float CLOUD_HALF   = 45.0;   // half-thickness
            float ry   = max(ray.y, 0.04);
            // #140 ANTI-STREAK: march the ACTUAL 3D world position along the ray through the
            // slab, not a single fixed XZ column. The old scheme held cloudXZ constant across
            // the whole height march, so at grazing angles a column of pixels all sampled the
            // same lobe and the silhouette smeared into long horizontal streaks. Here the
            // sample point steps in X and Z as well as height (p = eye + ray*t), so each pixel
            // traverses different lobes and the forms read as separated chunky puffs. The eye
            // sits below the slab; we walk from the slab bottom-entry t to the top-exit t.
            // Both t's are finite because cloudVis already gates ray.y > ~0.02.
            float tEnter = CLOUD_BOTTOM / ry;
            float tExit  = CLOUD_TOP    / ry;
            float marchSpan = tExit - tEnter;
            float dt   = marchSpan / float(CLOUD_STEPS);     // along-ray step (XZ + height move)
            // #146 ANTI-RING, DECORRELATED: tEnter depends only on ray.y, so iso-elevation screen
            // circles sample the slab at the same depths and the value noise produced faint
            // CONCENTRIC rings. The #140 jitter fed the IGN magic frequencies a CONTINUOUS world
            // direction (ray.xz changes ~1e-3 per pixel), so fract(52.98*fract(tiny)) was nearly
            // constant over many pixels: a smooth low-frequency screen pattern that BEAT against
            // the march cadence into the scaly ripple bands the player saw. Scale ray.xz up so the
            // hash input changes by ~O(1) per pixel BEFORE the IGN, which makes the dither truly
            // blue-noise-like (well distributed over any small neighbourhood) so it breaks the ring
            // without a coherent beat pattern. Use real pixel coordinates in the sky pass;
            // water passes cloudsOn=0 and skips this block.
            float2 cpix  = pixelCoord;
            float cdith  = fract(52.9829189 * fract(dot(cpix, float2(0.06711056, 0.00583715))));
            tEnter += dt * (cdith - 0.5) * 0.10;
            // #146: Roy found the startup/reload shred resolves in exactly ~15s,
            // which means it is a deterministic bad cloud animation phase, not
            // engine loading. Start the cloud field after that bad phase while
            // leaving the rest of the sky/weather clock untouched.
            float cloudClk = clk + 18.0;
            float wind = cloudClk * 1.10;      // slow horizontal drift
            // `cover` modulates how much sky the clouds fill; a slow weather-ish breathe
            // keeps the sky from being uniformly packed. Kept modest so the sky still reads.
            // #140 bolder presence: raise the coverage floor so the puffs read as solid toy
            // cumulus (chunky, opaque cores) rather than thin translucent wisps, which also
            // masks the faint radial sampling ringing under solid cloud. Still breathes so the
            // sky is not uniformly packed.
            float cover = 0.62 + 0.14 * (sin(cloudClk * (3.14159265 / 90.0)) * 0.5 + 0.5);
            float3 sunL = normalize(-sd);                    // toward the sun

            float trans = 1.0;        // remaining transparency (front-to-back)
            float3 lum  = float3(0.0); // accumulated lit cloud colour
            // BOLD cloud palette: bright tops, defined cool-grey shadow, warm sunrise/sunset
            // tint. The lit top keeps a FAINT cool tint (not pure white) so cloud pixels hold
            // a little saturation instead of reading as a flat washed white field — that keeps
            // the washout guard happy AND still looks like a crisp toy cloud over blue sky.
            float3 litCol = mix(float3(0.96, 0.98, 1.00),
                                float3(1.00, 0.80, 0.58), sunsetT * 0.70);
            float3 shadowCol = mix(float3(0.42, 0.46, 0.58),
                                   float3(0.45, 0.34, 0.40), sunsetT * 0.55);
            for (int s = 0; s < CLOUD_STEPS; ++s) {
                if (trans < 0.02) break;                     // already ~opaque, stop
                // March the REAL 3D position along the ray: XZ advances with t too, so the
                // sample sweeps across distinct lobes instead of one fixed column (kills the
                // horizontal streak). The virtual eye is at the origin (sky is at infinity, so
                // only the ray direction matters for the silhouette).
                float tt = tEnter + (float(s) + 0.5) * dt;
                float3 p = ray * tt;                         // true 3D world-ish sample point
                float h  = p.y;                              // actual sample height in the slab
                float d  = cloudDensity(p, wind, cover);
                // Rounded vertical profile: density tapers to 0 at the slab top/bottom so the
                // puffs have domed crowns and soft bases (3D billows) rather than a hard
                // sliced slab. h is the sample's height (slab centred at CLOUD_MID).
                float hN = clamp(1.0 - abs(h - CLOUD_MID) / CLOUD_HALF, 0.0, 1.0);
                d *= smoothstep(0.0, 0.6, hN);
                if (d > 0.001) {
                    // 2-tap light march toward the sun for self-shadowing: sample density a
                    // short and a longer step sunward; more density above = darker billow.
                    float ls1 = cloudDensity(p + sunL * 8.0,  wind, cover);
                    float ls2 = cloudDensity(p + sunL * 20.0, wind, cover);
                    float shadowAcc = ls1 * 0.6 + ls2 * 0.4;
                    float lit = exp(-shadowAcc * 3.0);       // Beer toward the sun (deeper = bolder pop)
                    // #146 NO QUANTIZE: the old 4-band floor() of the lit term carved concentric
                    // iso-value contours into the self-shadow. As the camera moved those contour
                    // rings slid across the puffs and read as a scaly / fish-scale ripple. Use a
                    // SMOOTH contrast curve instead (a smoothstep keeps the bold lit/shadow break
                    // and crisp toy pop) so the shading varies continuously with no banded scales.
                    lit = smoothstep(0.10, 0.85, lit);
                    float3 cCol = mix(shadowCol, litCol, lit);
                    // Front-to-back compositing: each step occludes the steps behind it. A
                    // high per-step opacity makes the puff cores go solid quickly (chunky toy
                    // cumulus) rather than a thin translucent smear. #140: the along-ray step
                    // length grows toward the horizon (dt = (top-bottom)/ry/STEPS), so scale the
                    // opacity by the step length relative to the slab thickness. Without this the
                    // long grazing steps would over-accumulate and re-smear the horizon into a
                    // solid band; with it the same lobe reads the same density at every angle.
                    float stepRef = dt / ((CLOUD_TOP - CLOUD_BOTTOM) / float(CLOUD_STEPS));
                    float a = clamp(d * 1.10 * clamp(stepRef, 0.4, 1.35), 0.0, 1.0);
                    lum   += trans * a * cCol;
                    trans *= (1.0 - a);
                }
            }
            float cloudA = (1.0 - trans) * cloudVis;
            // Fade clouds out toward the horizon so the slab edge does not show as a hard
            // line (they sit naturally on the sky dome). Also never fully opaque so the
            // sky colour breathes through the thin edges (keeps the sky from washing).
            // Keep clouds in the upper sky where the slab reads as defined puffs. The low
            // grazing band (where a flat slab inevitably smears) fades to clean blue sky.
            // #140: with the along-ray 3D march the mid-sky no longer streaks, so bring the
            // fade window LOWER (0.18..0.55 -> 0.10..0.42) so bold chunky puffs now fill more
            // of the visible sky instead of only the zenith, while the true grazing horizon
            // (ray.y < ~0.10, where any flat slab smears) still fades to clean blue.
            float horizFade = smoothstep(0.18, 0.56, ray.y);
            cloudA *= horizFade * 0.82;
            float3 cloudColor = (cloudA > 1e-4) ? (lum / max(1.0 - trans, 1e-3)) : float3(0.0);
            skyCol = mix(skyCol, cloudColor, clamp(cloudA, 0.0, 0.92));
        }

        return skyCol;
    }

    fragment float4 skyFmain(SkyVOut in [[stage_in]],
                              constant SkyUniforms& su [[buffer(0)]],
                              constant WaterUniforms& wu [[buffer(1)]]) {
        float tanHalfFov = su.camRight.w;
        float aspect     = su.camUp.w;
        float3 ray = normalize(su.camFwd.xyz
                               + su.camRight.xyz * (in.ndc.x * aspect * tanHalfFov)
                               + su.camUp.xyz    * (in.ndc.y * tanHalfFov));
        float3 skyCol = evalSkyColor(ray, su.sunDirTime.xyz, su.sunDirTime.w, wu.wallClockSecs,
                                     wu.cloudsOn, wu.weatherPack, in.position.xy);

        // FIX (#33): when the eye is underground (su.camFwd.w = underground 0..1),
        // fade the whole sky to a near-black cave colour. Surface-priority streaming
        // doesn't load the far underground, so without this the bright, sun-directional
        // daytime sky shows through those gaps — reading as a bluish "wash".
        float underground = clamp(su.camFwd.w, 0.0, 1.0);
        skyCol = mix(skyCol, float3(0.015, 0.016, 0.020), underground);

        return float4(skyCol, 1.0);
    }

    // =========================================================
    // UNDERWATER POST PASS — unchanged
    // =========================================================
    struct UWVOut { float4 position [[position]]; float2 uv; };

    vertex UWVOut underwaterVmain(uint vid [[vertex_id]],
                                  constant WaterUniforms& wu [[buffer(0)]]) {
        float2 pos;
        if      (vid == 0u) pos = float2(-1.0, -1.0);
        else if (vid == 1u) pos = float2( 3.0, -1.0);
        else                pos = float2(-1.0,  3.0);
        UWVOut o;
        o.position = float4(pos, 0.0, 1.0);
        o.uv = pos * 0.5 + 0.5;
        return o;
    }

    // FIX (#4 / #5): Underwater overlay is a FULLY STEADY light blue tint.
    // Alpha is constant (no per-frame or per-view variation) so there is zero
    // fuzziness or inconsistency frame-to-frame. Caustic patterns only affect
    // the colour (a subtle brightness shimmer), NEVER the alpha — that prevents
    // the flickering/fuzziness while still giving life to the water.
    // Terrain distance fog in fmain (exp(-0.046*dist)) handles depth-based
    // visibility (~15-20 block range) independently of this overlay.
    fragment float4 underwaterFmain(UWVOut in [[stage_in]],
                                    constant WaterUniforms& wu [[buffer(0)]]) {
        float uw = wu.underwater;
        if (uw < 0.01) { discard_fragment(); }
        float t = wu.wallClockSecs;
        // Caustic shimmer: only modulates colour, not alpha.
        float2 cUV1 = in.uv * float2(3.0, 2.5) + float2(t * 0.08, t * 0.05);
        float2 cUV2 = in.uv * float2(2.2, 3.1) + float2(-t * 0.06, t * 0.09);
        float caustic = noise2(cUV1) * 0.6 + noise2(cUV2) * 0.4;
        caustic = smoothstep(0.55, 0.80, caustic) * 0.08;   // very subtle
        // Same colour the in-water distance fog fades toward (WATER_FOG_COL) so the
        // full-screen overlay and the submerged-solid tint are the SAME blue — no
        // strobing/mismatch between the water volume and the tinted surfaces.
        float3 uwColor = WATER_FOG_COL;
        float3 col = uwColor + float3(caustic * 0.4, caustic * 0.6, caustic * 0.3);
        // Constant alpha — no variation of any kind.
        // FIX (#10): Reduced from 0.16 to 0.08 so the post-pass overlay is a
        // light blue wash rather than a blue wall. Nearby terrain blocks remain
        // clearly readable through the tint; depth-based fade in fmain handles
        // far-distance blue-out independently.
        float totalAlpha = 0.08 * clamp(uw, 0.0, 1.0);
        return float4(col, totalAlpha);
    }

    // =========================================================
    // SHARED FULLSCREEN VERTEX SHADER (bloom + composite)
    // =========================================================
    struct FSVOut { float4 position [[position]]; float2 uv; };

    vertex FSVOut fullscreenVert(uint vid [[vertex_id]]) {
        float2 pos;
        if      (vid == 0u) pos = float2(-1.0, -1.0);
        else if (vid == 1u) pos = float2( 3.0, -1.0);
        else                pos = float2(-1.0,  3.0);
        FSVOut o;
        o.position = float4(pos, 0.0, 1.0);
        // UV: Metal (0,0) top-left, NDC (-1,-1) bottom-left
        o.uv = pos * float2(0.5, -0.5) + 0.5;
        return o;
    }

    // =========================================================
    // BLOOM — bright-pass: extract luminance > threshold into half-res
    // =========================================================
    fragment float4 bloomBrightFrag(FSVOut in [[stage_in]],
                                    texture2d<float> hdrTex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = hdrTex.sample(s, in.uv);
        // Raised threshold: daytime sky sits around 0.7-1.1 HDR (broad region).
        // We must NOT let the sky into bloom — only the sun disc and emissive blocks
        // (fireflies, glow blocks) are legitimately overbright at 1.6+.
        // Old threshold (1.15) caught the entire daytime sky, smearing it across the
        // frame when the camera rotated upward. New lower bound = 1.6, full at 2.8
        // so only the sun disc (~1.1 * sunVis boost) and HDR emissives (1.6x mult)
        // actually bloom.  This eliminates the sky-rotation washout.
        float lum = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
        float bright = smoothstep(1.60, 2.80, lum);   // only true HDR highlights bloom
        return float4(c.rgb * bright, 1.0);
    }

    // =========================================================
    // BLOOM — separable 9-tap Gaussian (σ≈2)
    //   H pass: blur horizontally; V pass: blur vertically.
    //   Weights: [0.0625, 0.125, 0.25, 0.25, 0.25, ...] → use a 9-tap kernel.
    // =========================================================
    constant float kGaussWeights[5] = { 0.2270270270, 0.1945945946, 0.1216216216,
                                         0.0540540541, 0.0162162162 };

    fragment float4 bloomBlurHFrag(FSVOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 texelSize = 1.0 / float2(src.get_width(), src.get_height());
        float3 result = src.sample(s, in.uv).rgb * kGaussWeights[0];
        for (int i = 1; i < 5; ++i) {
            float off = float(i) * texelSize.x;
            result += src.sample(s, in.uv + float2( off, 0.0)).rgb * kGaussWeights[i];
            result += src.sample(s, in.uv + float2(-off, 0.0)).rgb * kGaussWeights[i];
        }
        return float4(result, 1.0);
    }

    fragment float4 bloomBlurVFrag(FSVOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 texelSize = 1.0 / float2(src.get_width(), src.get_height());
        float3 result = src.sample(s, in.uv).rgb * kGaussWeights[0];
        for (int i = 1; i < 5; ++i) {
            float off = float(i) * texelSize.y;
            result += src.sample(s, in.uv + float2(0.0,  off)).rgb * kGaussWeights[i];
            result += src.sample(s, in.uv + float2(0.0, -off)).rgb * kGaussWeights[i];
        }
        return float4(result, 1.0);
    }

    // =========================================================
    // COMPOSITE — ACES filmic tone-mapping + colour grade + vignette
    //             + animated precipitation overlay (rain streaks / snow flakes)
    //   Reads HDR scene (rgba16Float) + bloom texture, writes LDR bgra8.
    //   hdrTex is at the capped internal resolution; the bilinear sampler
    //   upscales it to the full drawable naturally.
    // =========================================================

    // (PostUniforms defined once at the top of the shader — see TERRAIN STRUCTS section)

    // ACES fitted curve (Narkowicz 2015, single-pass approximation)
    static float3 ACESFilmic(float3 x) {
        const float a = 2.51f;
        const float b = 0.03f;
        const float c = 2.43f;
        const float d = 0.59f;
        const float e = 0.14f;
        return clamp((x*(a*x+b)) / (x*(c*x+d)+e), 0.0, 1.0);
    }

    // (Old screen-space rainStreak / snowFlake helpers removed in #32 — precipitation
    //  is now environmental world-space particles; see the precip* shaders below.)

    // =========================================================
    // #119 VOLUMETRIC GOD RAYS — screen-depth radial march helpers
    //
    //   GR_STEPS    : samples per ray. Higher = smoother shafts, more GPU. The dither
    //                 below lets a modest count look banding-free. PERF KNOB.
    //   GR_MAXDIST  : how far (world units) a ray marches before giving up. Kept inside
    //                 the far shadow cascade so every sample has shadow data.
    //   GR_DENSITY  : fog density per world unit; scales how fast in-scatter accumulates.
    //   GR_HG_G     : Henyey-Greenstein anisotropy (0..1). Higher = the glow concentrates
    //                 more tightly toward the sun direction (forward scattering).
    // =========================================================
    // #126 -> bold pass: pushed from a subtle in-scatter glow to dramatic, graphic
    // cel-shaded shafts. STEPS up a little (crisper beams at the higher density),
    // DENSITY ~2.3x (the in-scatter the eye reads as the shaft body), HG_G sharper
    // (a tighter forward lobe so the glow concentrates into distinct rays toward the
    // sun instead of a broad haze). See the floor / saturation / clamp tuning below.
    constant int   GR_STEPS   = 48;   // #167: was 80 at full res; at quarter res + IGN jitter + quad denoise, 48 holds the look at ~40% less march cost
    constant float GR_MAXDIST = 140.0;
    constant float GR_DENSITY = 0.024;
    constant float GR_HG_G    = 0.82;

    // Bold-shaft shaping knobs (all easy to tune):
    //   GR_FLOOR_LO/HI : the lit-fraction window the shaft is remapped from. The cores of
    //                    a shaft (air that is almost fully sunlit toward the sun) reach HI
    //                    and blaze; anything below LO is cut to zero. This is what makes the
    //                    shadow corridors carve crisp DARK gaps between beams.
    //   GR_SHAFT_GAMMA : > 1 CRUSHES the partly-lit midtones toward black, so the broad
    //                    low-level glow (the "sun glare" / fog wash) dies and only the
    //                    carved beams survive. Higher = more graphic, harder-edged shafts.
    //   GR_SATURATION  : pushes the shaft color away from its luma (>1 = more saturated).
    //   GR_WARM_TINT   : multiplies the (saturated) sun color to bias the beams warm-gold.
    //   GR_MAX_ADD     : HARD per-channel additive ceiling. The night/ground-wash guard:
    //                    even a runaway in-scatter can never lift a channel past this.
    constant float GR_FLOOR_LO    = 0.14;
    constant float GR_FLOOR_HI    = 0.88;
    constant float GR_SHAFT_GAMMA = 1.25;
    constant float GR_SATURATION  = 1.45;
    constant float3 GR_WARM_TINT  = float3(1.12, 1.02, 0.78);
    constant float GR_MAX_ADD     = 0.85;

    // #132 DISTINCT DESCENDING SHAFTS — knobs that sharpen the volumetric in-scatter into
    // clearly separated beams and boost it at low sun (dawn/dusk) so rays read as actually
    // streaming DOWN, subtler at high noon. Applied ON TOP of the base shaft shaping above.
    //   GR_SHAFT_SHARP : extra contrast applied around the shaft mid-value to segment the
    //                    smooth in-scatter into distinct bright cores / dark gaps (cel feel).
    //                    1 = no extra sharpening; higher = harder edges between beams.
    //   GR_LOWSUN_BOOST: multiplier added to the shaft at the lowest sun. At a low sun the
    //                    shafts get (1 + boost) stronger; at noon ~1x. This is what makes
    //                    dawn/dusk feel like god-rays streaming down.
    //   GR_LOWSUN_POW  : shapes the low-sun ramp (higher = the boost concentrates nearer the
    //                    horizon so noon stays subtle).
    constant float GR_SHAFT_SHARP  = 1.0;
    constant float GR_LOWSUN_BOOST = 1.6;
    constant float GR_LOWSUN_POW   = 2.0;

    // =========================================================
    // #132 STYLIZED SCREEN-SPACE LENS FLARE (composite pass)
    //
    // A classic ghost-chain flare drawn along the line from the sun's screen position
    // THROUGH the screen centre, plus a horizontal anamorphic streak through the sun and a
    // tight bright bloom at the sun itself. It is gated on the CPU (pu.lensFlareStr folds the
    // toggle + daylight + look-at-sun) and gated HERE by an occlusion depth test: if scene
    // geometry sits in front of the sun's screen position, the flare fades out (a flare from
    // a hidden sun looks wrong). All additive contributions are clamped so the flare can
    // never wash the scene to white. Tasteful for the cel look, not a lens-sim overload.
    //   FLARE_GHOSTS    : number of ghost elements along the sun->centre line.
    //   FLARE_GHOST_SP  : spacing between ghosts (fraction of the sun->centre vector).
    //   FLARE_GHOST_SZ  : base ghost radius (screen-space, aspect-corrected).
    //   FLARE_STREAK_LEN: half-length of the horizontal anamorphic streak (uv units).
    //   FLARE_STREAK_THK: thickness of the streak (uv units).
    //   FLARE_BLOOM_SZ  : radius of the tight bright core at the sun.
    //   FLARE_INTENSITY : overall flare brightness multiplier.
    //   FLARE_MAX_ADD   : HARD per-channel additive ceiling (the wash-out guard).
    constant int    FLARE_GHOSTS     = 5;
    constant float  FLARE_GHOST_SP   = 0.32;
    constant float  FLARE_GHOST_SZ   = 0.075;
    constant float  FLARE_STREAK_LEN = 0.40;
    constant float  FLARE_STREAK_THK = 0.0075;
    constant float  FLARE_BLOOM_SZ   = 0.055;
    constant float  FLARE_INTENSITY  = 0.95;
    constant float  FLARE_MAX_ADD    = 0.55;

    // =========================================================
    // #130 CEL-SHADE INK OUTLINES + PUNCHIER PALETTE (composite pass)
    //
    // A screen-space edge pass that draws a dark ink line on geometry edges, detected
    // from the SCENE DEPTH (already stored + sampleable here for the god-ray raymarch).
    // We linearize depth so the discontinuity test is in world-ish units (a raw [0,1]
    // depth buffer is hugely non-linear and would ink every distant seam). A Roberts
    // cross of linearized depth gives crisp SILHOUETTES (depth jumps at object borders)
    // cheaply; an extra check against the local neighbourhood mean catches strong
    // interior creases (ledges, block tops) without inking every tiny voxel seam.
    //
    // All tunables are single constants so the art direction can be dialed:
    //   CEL_OUTLINE_PX     : line thickness, in source pixels (tap offset radius).
    //   CEL_OUTLINE_DARK   : how dark the ink is (1 = near-black line, 0 = no line).
    //   CEL_DEPTH_SENS     : depth-discontinuity sensitivity. LOWER = more lines (more
    //                        sensitive to small depth steps); HIGHER = only bold edges.
    //   CEL_NEAR / CEL_FAR : the linearization range (matches the perspective depth split
    //                        the scene uses; only the ratio matters for edge detection).
    //   CEL_SAT / CEL_CON  : extra saturation / contrast applied ONLY when cel-shade is on,
    //                        so the palette reads graphic and bold (tasteful, not neon).
    constant float CEL_OUTLINE_PX   = 1.3;
    constant float CEL_OUTLINE_DARK = 0.82;
    // #186 follow-up: raised 0.022 -> 0.075. The #180 horizon bend makes the terrain a
    // piecewise-linear surface, so every greedy-quad boundary is a tiny slope CREASE the
    // curvature edge test would ink as a faint grid of dots/lines on otherwise flat
    // ground. A real silhouette is a depth STEP with a far larger curvature response, so
    // a higher threshold drops the bend creases while still inking blocks, grass, and
    // trees.
    constant float CEL_DEPTH_SENS   = 0.075;
    constant float CEL_NEAR         = 0.20;
    constant float CEL_FAR          = 420.0;
    constant float CEL_SAT          = 1.16;
    constant float CEL_CON          = 1.10;

    // Linearize a Metal [0,1] depth sample to a view-space-ish distance. The exact
    // projection constants do not matter for edge detection (we only compare relative
    // jumps), but matching the scene's near/far keeps CEL_DEPTH_SENS intuitive.
    static float celLinearizeDepth(float d) {
        // Standard reversed-z-free perspective: z_view = near*far / (far - d*(far-near)).
        return (CEL_NEAR * CEL_FAR) / max(CEL_FAR - d * (CEL_FAR - CEL_NEAR), 1e-4);
    }

    // Henyey-Greenstein phase: brightest when the view ray looks toward the sun.
    // cosT = dot(viewDir, toSun). Normalised so the forward lobe peaks but the term
    // stays bounded (no division blow-up at g->1).
    static float hgPhase(float cosT, float g) {
        float g2 = g * g;
        float denom = 1.0 + g2 - 2.0 * g * cosT;
        return (1.0 - g2) / (4.0 * 3.14159265 * pow(max(denom, 1e-4), 1.5));
    }

    // #167 GOD-RAY MARCH CORE. The screen-depth radial march + shaft shaping for one ray,
    // shared by the half-res pre-pass (godrayHalfFrag, the fast path the live renderer
    // uses) and the legacy inline path inside compositeFrag (kept for the headless
    // harness call sites, which signal it with vu.sunDir.w == 0). Returns:
    //   .x = inscatter (the whole shaft term except sun colour and the strength knob)
    //   .y = litFrac   (raw lit fraction, for the BF_GR_DEBUG output)
    //   .z = hitDist   (world-units distance to the depth surface; the depth key the
    //                   composite's bilateral upsample matches against)
    // dilateTexel is the uv offset for the 4-tap min-depth dilation: one scene texel
    // when marching at full res, one HALF-RES texel (two scene texels) at half res so
    // the conservative near depth covers the coarse pixel's whole 2x2 footprint.
    static float3 grInscatter(float2 uv, float2 pixPos, float2 dilateTexel,
                              depth2d<float, access::sample> sceneDepth,
                              constant VolUniforms& vu) {
        constexpr sampler sD(filter::nearest, address::clamp_to_edge);
        constexpr sampler sRay(filter::linear, address::clamp_to_edge);
        // Reconstruct this pixel's world position from depth (clip -> world).
        // FSVOut uv is Metal top-left; NDC y is flipped, z in [0,1] on Metal.
        float d = sceneDepth.sample(sD, uv);
        d = min(d, sceneDepth.sample(sD, uv + float2( dilateTexel.x, 0.0)));
        d = min(d, sceneDepth.sample(sD, uv + float2(-dilateTexel.x, 0.0)));
        d = min(d, sceneDepth.sample(sD, uv + float2(0.0,  dilateTexel.y)));
        d = min(d, sceneDepth.sample(sD, uv + float2(0.0, -dilateTexel.y)));
        float2 ndcXY = float2(uv.x * 2.0 - 1.0, (1.0 - uv.y) * 2.0 - 1.0);
        float4 clip  = float4(ndcXY, d, 1.0);
        float4 wp    = vu.invViewProj * clip;
        float3 worldHit = wp.xyz / wp.w;

        float3 camP    = vu.camPosW.xyz;
        float3 toHit   = worldHit - camP;
        float  hitDist = length(toHit);
        float3 viewDir = (hitDist > 1e-4) ? (toHit / hitDist) : float3(0, 0, 1);

        // March only up to the visible surface (so shafts respect occlusion) and
        // cap at GR_MAXDIST (keeps every sample inside the far cascade + bounds cost).
        float marchLen = min(hitDist, GR_MAXDIST);

        // toSun points from the scene toward the sun (sunDir points downward).
        float3 toSun = normalize(-vu.sunDir.xyz);
        float  cosT  = dot(viewDir, toSun);
        float  phase = hgPhase(cosT, GR_HG_G);

        // #188 STRATIFIED QUAD JITTER. The old scheme was one small (+/-7.5% step)
        // IGN offset per pixel; the 2x2 quad denoise below then averaged four
        // nearly-equal phases back to a constant, so the march re-quantized into
        // concentric rings around the sun (litFrac steps of 1/GR_STEPS) which the
        // steep shaft shaping amplified into the visible banded "cubing". Instead,
        // give each LANE of the 2x2 quad a different quarter of the step
        // ((lane + IGN)/4), with the IGN base computed per QUAD so the four lanes
        // stratify one full step exactly. The quad averages below then integrate a
        // 4x stratified estimate of the march (effectively 4*GR_STEPS phases), so
        // both the rings and the per-pixel grain are gone at the same march cost.
        float2 quadPos = floor(pixPos * 0.5);
        float ignQ = fract(52.9829189 * fract(dot(quadPos, float2(0.06711056, 0.00583715))));
        float lane = float((int(pixPos.x) & 1) | ((int(pixPos.y) & 1) << 1));
        float dither = (lane + ignQ) * 0.25;

        // #274: use a classic screen-space radial visibility march. The previous
        // world-volume version exposed both the finite occupancy box and individual
        // voxel cells as huge axis-aligned rectangles around a low sun. Scene depth
        // already contains the exact visible silhouettes needed to carve stylized
        // shafts; marching it toward the projected sun is cheaper, continuous, and
        // has no finite 3D box that can project onto the sky. The CPU packs sun UV in
        // camPosW.w / voxDims.w for this ray-only uniform.
        float2 sunUV = float2(vu.camPosW.w, vu.voxDims.w);
        float2 rayStep = (sunUV - uv) * (0.92 / float(GR_STEPS));
        float2 sampleUV = uv + rayStep * dither;
        float litLen = 0.0, totLen = 0.0;
        float weight = 1.0;
        for (int i = 0; i < GR_STEPS; ++i) {
            sampleUV += rayStep;
            float sd = sceneDepth.sample(sRay, sampleUV);
            // Linear depth filtering plus a narrow clear-depth ramp antialiases
            // tree/roof silhouettes before the radial integration.
            float openSky = smoothstep(0.995, 0.9999, sd);
            litLen += openSky * weight;
            totLen += weight;
            weight *= 0.965;
        }
        float litFrac = (totLen > 1e-4) ? (litLen / totLen) : 0.0;   // 0..1

        // #147 DENOISE THE LIT FRACTION (before the steep shaping). The jittered march
        // leaves a little high-frequency variance in litFrac; the floor/gamma/contrast curves
        // below are steep, so that small per-pixel noise gets AMPLIFIED into the visible grain
        // in the shafts near the sun. Box-average litFrac over the 2x2 fragment quad FIRST so
        // the shaping operates on a clean signal. quad_shuffle_xor reaches the three other
        // lanes of this pixel's quad (xor 1 = horizontal, 2 = vertical, 3 = diagonal), so the
        // mean of all four is the EXACT 2x2 box filter, parity-independent. This removes the
        // jitter grain while preserving the real beam structure (which varies far more slowly
        // than one pixel). Cost: three lane shuffles, no extra voxel marches (the dominant cost
        // stays at GR_STEPS); the grain that survived the march is averaged out for free.
        float lfq = (litFrac
                     + quad_shuffle_xor(litFrac, 1u)
                     + quad_shuffle_xor(litFrac, 2u)
                     + quad_shuffle_xor(litFrac, 3u)) * 0.25;
        litFrac = clamp(lfq, 0.0, 1.0);

        // A floor cut that keeps ONLY the shaft cores: it suppresses the broad,
        // uniform low-level glow (the "fog wash" failure mode and the ground-wash
        // guard) and remaps the surviving range so beams read as distinct, graphic
        // rays rather than a soft haze. The window is narrower and higher than #126
        // (0.28..1.0): air must be mostly sunlit toward the sun before it lights up.
        // GR_SHAFT_GAMMA > 1 then CRUSHES the partly-lit midtones toward black so the
        // broad smooth glare dies and the shadow corridors read as crisp dark gaps
        // between bright beams (graphic, cel-shaded shafts, not a soft halo).
        // Uniform open sky is sun glow, not a shaft (the sun disc / optional flare
        // already cover it). Keep only mixed open/occluded radial visibility, which
        // is where silhouettes actually carve crepuscular beams. Besides reading
        // more like rays, this removes the enormous shallow phase halo whose 8-bit
        // quantization exposed screen-sized tonal rectangles.
        float beamSignal = 4.0 * litFrac * (1.0 - litFrac);
        float shaftRaw = smoothstep(GR_FLOOR_LO, GR_FLOOR_HI, beamSignal);
        float shaft    = pow(shaftRaw, GR_SHAFT_GAMMA);
        // #132 DISTINCT BEAMS: sharpen the shaft around its mid-value with a contrast
        // curve so the smooth in-scatter SEGMENTS into separated bright cores and dark
        // gaps. A logistic-ish contrast about 0.5 keeps it in [0,1] (cannot raise the
        // mean past the carved beams, so it cannot reintroduce a wash).
        shaft = clamp((shaft - 0.5) * GR_SHAFT_SHARP + 0.5, 0.0, 1.0);
        float shaftQ = (shaft
                        + quad_shuffle_xor(shaft, 1u)
                        + quad_shuffle_xor(shaft, 2u)
                        + quad_shuffle_xor(shaft, 3u)) * 0.25;
        shaft = mix(shaft, clamp(shaftQ, 0.0, 1.0), 0.90);
        // #132 LOW-SUN BOOST: shafts read as god-rays streaming DOWN at dawn/dusk and stay
        // subtle at noon. sunDir points downward, so -sunDir.y is the sun elevation
        // (~1 noon, ~0 horizon). lowSun is ~1 near the horizon, ~0 high up.
        float sunElev = clamp(-vu.sunDir.y, 0.0, 1.0);
        float lowSun  = pow(1.0 - sunElev, GR_LOWSUN_POW);
        float shaftBoost = 1.0 + GR_LOWSUN_BOOST * lowSun;
        // marchLen factor: long rays (open sky toward the sun) scatter more than the
        // short rays that hit nearby ground, which keeps the ground from washing.
        float lenFactor = clamp(marchLen / GR_MAXDIST, 0.0, 1.0);
        float inscatter = shaft * shaftBoost * phase * lenFactor * GR_DENSITY * marchLen;
        return float3(inscatter, litFrac, hitDist);
    }

    // #167 LOW-RES GOD-RAY PRE-PASS. Runs the radial depth march at a fraction
    // of the scene resolution (kGodRayDownscale = 4, so 16x fewer marched pixels)
    // into a small rgba16Float target; compositeFrag then does a depth-aware
    // (bilateral) upsample so shaft edges stay crisp against foreground geometry.
    //   r = inscatter, g = litFrac (BF_GR_DEBUG), b = hit distance (the depth key).
    fragment float4 godrayHalfFrag(FSVOut in [[stage_in]],
                                   constant VolUniforms& vu [[buffer(1)]],
                                   depth2d<float, access::sample> sceneDepth [[texture(2)]]) {
        // Dilate the depth over one coarse texel. vu.sunDir.w carries the downscale
        // factor (2 = half res, 4 = quarter res), so the conservative near depth
        // covers this coarse pixel's whole NxN scene footprint (no shaft leak over
        // foreground silhouettes after the upsample).
        // #188: 2x the downscale, so the conservative near depth covers the whole
        // 2x2 QUAD footprint (the composite reconstructs from one texel per quad
        // now, and the quad denoise mixes all four lanes' marches, so every lane
        // must march against the quad's nearest depth or sky in-scatter leaks
        // over silhouettes as a bright halo).
        float2 dilate = 2.0 * max(vu.sunDir.w, 1.0)
                        / float2(sceneDepth.get_width(), sceneDepth.get_height());
        float3 r = grInscatter(in.uv, in.position.xy, dilate, sceneDepth, vu);
        // #188: store UNIT in-scatter (per marchLen^2), normalised by THIS lane's own
        // march length BEFORE the quad average. A quad straddling a silhouette mixes
        // short foreground marches with long sky marches; averaging raw in-scatter
        // and renormalising later by one shared quad length overshoots by up to
        // (maxLen/minLen)^2, which sparkled white along canopy edges. Unit in-scatter
        // is length-independent, so the quad mean stays consistent and the composite
        // just rescales by its own pixel's marchLen^2.
        float lenL = min(r.z, GR_MAXDIST);
        float u = r.x / max(lenL * lenL, 1.0);
        float uq = (u
                    + quad_shuffle_xor(u, 1u)
                    + quad_shuffle_xor(u, 2u)
                    + quad_shuffle_xor(u, 3u)) * 0.25;
        // #188: the composite now reconstructs from ONE texel per 2x2 quad, so the
        // depth key must be quad-uniform too: take the quad MIN so the key stays the
        // conservative near depth over the quad's whole scene footprint.
        float hd = min(min(r.z, quad_shuffle_xor(r.z, 1u)),
                       min(quad_shuffle_xor(r.z, 2u), quad_shuffle_xor(r.z, 3u)));
        // Clamp the stored distance into fp16 range (a sky pixel reconstructs far).
        return float4(uq, r.y, min(hd, 60000.0), 1.0);
    }

    fragment float4 compositeFrag(FSVOut in [[stage_in]],
                                  texture2d<float> hdrTex   [[texture(0)]],
                                  texture2d<float> bloomTex [[texture(1)]],
                                  constant PostUniforms& pu [[buffer(0)]],
                                  constant VolUniforms&  vu [[buffer(1)]],
                                  depth2d<float, access::sample> sceneDepth [[texture(2)]],
                                  texture2d<float> godrayTex                [[texture(5)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        constexpr sampler sDepth(filter::nearest, address::clamp_to_edge);

        // hdrTex is at the capped internal resolution; bilinear upscale is free here.
        float3 hdr   = hdrTex.sample(s, in.uv).rgb;
        float3 bloom = bloomTex.sample(s, in.uv).rgb;

        // =========================================================
        // #119 VOLUMETRIC GOD RAYS (replaces the old screen-space sun halo).
        // March a ray from the camera into the scene; at each step reconstruct the
        // world position, sample the SUN SHADOW MAP, and where the point is lit add
        // in-scatter weighted by a forward (Henyey-Greenstein) phase function. Lit
        // air glows; shadowed volumes (behind trees / hills / walls) stay dark, so
        // beams of sunlight read through the gaps. vu.sunColor.w folds the toggle
        // (gfxGodRays) AND daylight (dayLight) into one strength; 0 = fully off.
        // =========================================================
        float volStrength = vu.sunColor.w;
        // #119 DEBUG: a NEGATIVE strength (harness sentinel, BF_GR_DEBUG=1) outputs the raw
        // shaft in-scatter as grayscale so the beam structure is unmistakable headless.
        bool volDebug = (volStrength < -0.5);
        if (volDebug) volStrength = -volStrength;
        if (volStrength > 0.001) {
            float inscatter, litFrac;
            if (vu.sunDir.w > 0.5) {
                // #167 FAST PATH: the shafts were already marched at LOW RES into
                // godrayTex (godrayHalfFrag). Upsample with a depth-aware (bilateral)
                // 4-tap filter: each of the four nearest half-res samples is weighted
                // by its bilinear weight TIMES how well its stored hit distance (.b)
                // matches this full-res pixel's own hit distance, so shaft values from
                // the wrong side of a silhouette are rejected and edges stay crisp
                // (no halo bleeding over foreground geometry).
                float d = sceneDepth.sample(sDepth, in.uv);
                float2 ndcXY = float2(in.uv.x * 2.0 - 1.0, (1.0 - in.uv.y) * 2.0 - 1.0);
                float4 wp = vu.invViewProj * float4(ndcXY, d, 1.0);
                float hitD = min(length(wp.xyz / wp.w - vu.camPosW.xyz), 60000.0);
                // #188 QUAD-CENTRED RECONSTRUCTION. The pre-pass quad denoise makes
                // every 2x2 texel quad of godrayTex carry ONE value, so interpolating
                // between adjacent TEXELS produced flat 2-texel plateaus with kinks at
                // quad boundaries: on screen, a regular grid of blocks in the smooth
                // glow around the sun (the "cubing"). Interpolate between QUADS
                // instead (one representative texel per quad): the reconstruction is
                // then a single smooth bilinear ramp across the whole gradient.
                float2 grSize = float2(godrayTex.get_width(), godrayTex.get_height());
                float2 grQuads = grSize * 0.5;
                float2 posG = in.uv * grQuads - 0.5;
                float2 fw   = fract(posG);
                float2 q0   = floor(posG);
                // Lane (0,0) texel of each quad (all four lanes hold the same value).
                float2 base = (q0 * 2.0 + 0.5) / grSize;
                float2 gt   = 2.0 / grSize;
                float4 s00 = godrayTex.sample(sDepth, base);
                float4 s10 = godrayTex.sample(sDepth, base + float2(gt.x, 0.0));
                float4 s01 = godrayTex.sample(sDepth, base + float2(0.0, gt.y));
                float4 s11 = godrayTex.sample(sDepth, base + gt);
                float4 bw = float4((1.0 - fw.x) * (1.0 - fw.y), fw.x * (1.0 - fw.y),
                                   (1.0 - fw.x) * fw.y,         fw.x * fw.y);
                // RELATIVE distance mismatch, so the tolerance scales with distance
                // (a 2-block step matters up close, not at the horizon).
                float4 hz = float4(s00.b, s10.b, s01.b, s11.b);
                float4 dw = 1.0 / (0.05 + abs(hz - hitD) / max(hitD, 4.0));
                float4 w  = bw * dw;
                float ws  = w.x + w.y + w.z + w.w;
                if (ws < 1e-5) { w = bw; ws = 1.0; }   // no depth match: plain bilinear
                // #188: the pre-pass stores UNIT in-scatter (already normalised by each
                // lane's own marchLen^2 before the quad average), so thin foreground
                // geometry (grass blades, mushroom stems) narrower than a coarse texel
                // never inherits a long sky ray's raw in-scatter. Just rescale by THIS
                // pixel's own marchLen^2, the same physics the inline path applies.
                float4 tapIns = float4(s00.r, s10.r, s01.r, s11.r);
                float lenHere = min(hitD, GR_MAXDIST);
                inscatter = (dot(w, tapIns) / ws) * lenHere * lenHere;
                litFrac   = dot(w, float4(s00.g, s10.g, s01.g, s11.g)) / ws;
            } else {
                // Legacy inline full-res march. Only the headless harness composite
                // call sites take this path (they do not encode the pre-pass); the
                // live renderer always sets vu.sunDir.w to the downscale factor.
                float2 dilate = 1.0 / float2(sceneDepth.get_width(), sceneDepth.get_height());
                float3 r = grInscatter(in.uv, in.position.xy, dilate, sceneDepth, vu);
                inscatter = r.x; litFrac = r.y;
            }

            // Saturate the shaft color toward a warm gold so the beams read as obvious
            // sunlight, not a neutral lift. Push the base sun tint away from its luma so
            // brighter shaft cores get more saturated (cel-shaded, graphic), then warm it.
            float3 sunCol = vu.sunColor.rgb;
            float  sunLuma = dot(sunCol, float3(0.2126, 0.7152, 0.0722));
            float3 sunSat  = clamp(mix(float3(sunLuma), sunCol, GR_SATURATION) * GR_WARM_TINT,
                                   0.0, 1.5);
            // Clamp the additive HARD so god rays can never blow the scene to white
            // (mirrors the bloom clamp below). This is the night-whiteout / ground-wash
            // guard: even at max in-scatter the lift per channel stays bounded. The cap is
            // higher than #126 (0.40) so the bold shafts can actually punch through, but it
            // is still a hard per-channel ceiling, so a runaway value can never wash out.
            float3 add = clamp(sunSat * inscatter * volStrength, 0.0, GR_MAX_ADD);
            if (volDebug) {
                // Show the lit fraction (top) and the final shaft term (bottom half).
                float g = (in.uv.y < 0.5) ? litFrac : clamp(inscatter * volStrength * 4.0, 0.0, 1.0);
                return float4(g, g, g, 1.0);
            }
            hdr += add;
        }

        // =========================================================
        // #132 STYLIZED LENS FLARE.
        // pu.lensFlareStr (CPU) already folds the toggle + daylight + look-at-sun and is 0
        // when the sun is off-screen / behind the camera, so this whole block is skipped
        // unless the player is actually looking toward an on-screen daytime sun. We then do
        // the OCCLUSION test here: if scene geometry sits in front of the sun's screen
        // position the flare fades (a flare from a hidden sun looks wrong). Everything is
        // additive into hdr (so it shares the exposure + ACES + final clamp wash guards) and
        // hard-clamped to FLARE_MAX_ADD on top of that.
        if (pu.lensFlareStr > 0.001) {
            float2 sunUV = float2(pu.sunScreenX, pu.sunScreenY);
            // OCCLUSION: sample scene depth at the sun's screen position. The sky is at the
            // far plane (depth ~1); any geometry in front reads notably less than 1. Fade the
            // flare smoothly to zero as something occludes the sun (hill / tree / wall).
            float occD = sceneDepth.sample(s, clamp(sunUV, 0.0, 1.0));
            float visible = smoothstep(0.985, 0.9995, occD);   // 1 = clear sky behind sun, 0 = occluded
            float flareStr = pu.lensFlareStr * visible * FLARE_INTENSITY;
            if (flareStr > 0.001) {
                // Aspect correction so circles stay round and distances are isotropic.
                float w = float(sceneDepth.get_width());
                float h = float(sceneDepth.get_height());
                float aspect = w / max(h, 1.0);
                float2 px = in.uv;
                float2 aspV = float2(aspect, 1.0);
                // Warm flare tint from the sun colour, biased a touch warmer for the cel look.
                float3 fcol = clamp(pu.sunColorR > 0.0
                                    ? float3(pu.sunColorR, pu.sunColorG, pu.sunColorB) : float3(1.0),
                                    0.0, 1.5);
                fcol = mix(fcol, float3(1.0, 0.85, 0.55), 0.35);

                float3 flare = float3(0.0);

                // --- Tight bright bloom AT the sun ---
                float2 dSun = (px - sunUV) * aspV;
                float rSun  = length(dSun);
                float bloomC = exp(-rSun * rSun / (FLARE_BLOOM_SZ * FLARE_BLOOM_SZ));
                flare += fcol * bloomC * 1.2;

                // --- Horizontal anamorphic streak through the sun ---
                // Bright along x, tight in y: a soft horizontal bar centred on the sun.
                float2 dStr = px - sunUV;
                float streakX = 1.0 - smoothstep(0.0, FLARE_STREAK_LEN, abs(dStr.x));
                float streakY = exp(-(dStr.y * dStr.y) / (FLARE_STREAK_THK * FLARE_STREAK_THK));
                flare += fcol * streakX * streakX * streakY * 0.9;

                // --- Ghost chain along the sun -> screen-centre line ---
                // The vector from the sun toward the centre; ghosts march past centre to the
                // opposite side, the classic flare layout. Each ghost is a soft disc with a
                // size + tint that varies down the chain so it reads as a lens artefact, not
                // a row of identical dots.
                float2 toCentre = (float2(0.5) - sunUV);
                for (int gi = 0; gi < FLARE_GHOSTS; ++gi) {
                    float fi = float(gi + 1);
                    float2 gpos = sunUV + toCentre * (FLARE_GHOST_SP * fi);
                    // Vary size + brightness + a faint chromatic tint per ghost.
                    float gsz = FLARE_GHOST_SZ * (0.5 + 0.5 * fract(fi * 0.37 + 0.2));
                    float2 dG = (px - gpos) * aspV;
                    float rG  = length(dG);
                    float disc = exp(-rG * rG / (gsz * gsz));
                    // Soft hex-ish edge: a faint ring on the bigger ghosts adds the lens look
                    // without an expensive polygon test.
                    float ring = exp(-pow((rG - gsz) / (gsz * 0.5), 2.0)) * 0.25;
                    float gbright = (0.10 + 0.16 * fract(fi * 0.61));
                    float3 gtint = mix(fcol, float3(0.6, 0.8, 1.0), 0.3 * fract(fi * 0.5));
                    flare += gtint * (disc + ring) * gbright;
                }

                // Vignette the whole flare toward the screen edge so it never crowds the very
                // corners (keeps gameplay readable) and clamp HARD per channel: the flare can
                // brighten the sky toward the sun but can NEVER wash the frame to white.
                float2 cc = px - 0.5;
                float edgeFade = 1.0 - smoothstep(0.45, 0.75, dot(cc, cc) * 2.2);
                // (flare already carries the warm tint per element; one strength + clamp here.)
                float3 flareAdd = clamp(flare * flareStr * edgeFade, 0.0, FLARE_MAX_ADD);
                hdr += flareAdd;
            }
        }

        // Clamp the bloom contribution per-channel so a large bright region (sun disc,
        // emissive blocks) can never flood the frame and wash out directional shading.
        // Max bloom additive per channel is 0.25 — enough for a visible glow around
        // the sun and emissives but far below the point where it lifts everything to
        // flat-bright. (bloomStrength=0.08 * clamp(bloom, 0, ~3) ≤ 0.25 per channel.)
        float3 bloomClamped = clamp(bloom * pu.bloomStrength, 0.0, 0.20);
        // Exposure < 1 keeps bright scenes (open desert, low sun, bright sky in
        // view) off the ACES white point, so facing the sun no longer washes out.
        float3 combined = (hdr + bloomClamped) * 0.80;

        // ACES filmic tone-map
        float3 tonemapped = ACESFilmic(combined);

        // Gentle warm highlight tint.
        float lumG = dot(tonemapped, float3(0.2126, 0.7152, 0.0722));
        tonemapped = mix(tonemapped, tonemapped * float3(1.03, 1.00, 0.97), lumG * lumG * 0.18);

        // Moderate saturation (no midtone lift / heavy contrast — those pumped
        // brightness and caused the view-dependent wash-out).
        float lumSat = dot(tonemapped, float3(0.2126, 0.7152, 0.0722));
        tonemapped   = mix(float3(lumSat), tonemapped, pu.satBoost);
        // Light contrast only.
        tonemapped   = clamp((tonemapped - 0.5) * 1.06 + 0.5, 0.0, 1.0);

        // #130 PUNCHIER PALETTE. When cel-shade is on, add a modest extra saturation +
        // contrast lift on top of the base grade so colours read graphic and bold. Kept
        // tasteful (CEL_SAT 1.16, CEL_CON 1.10) so it pops without going neon, and applied
        // BEFORE the vignette / Grey wash so those still behave. Multiplicative contrast
        // about 0.5 cannot brighten the mean, so it cannot reintroduce a washout.
        if (pu.celShade > 0.5) {
            float lumC = dot(tonemapped, float3(0.2126, 0.7152, 0.0722));
            tonemapped = mix(float3(lumC), tonemapped, CEL_SAT);
            tonemapped = clamp((tonemapped - 0.5) * CEL_CON + 0.5, 0.0, 1.0);
        }

        // Vignette: smooth falloff toward screen edges
        float2 centred = in.uv - 0.5;
        float vigRad = dot(centred, centred);
        float vignette = 1.0 - smoothstep(0.20, 0.70, vigRad * 4.0) * pu.vignetteStr;
        tonemapped *= vignette;

        // ---- Precipitation is now ENVIRONMENTAL (world-space particles) ------
        // FIX (#32): The old screen-space rain-streak / snow-flake overlay was
        // removed. It read as a static full-frame HUD overlay with no parallax.
        // Precipitation is now drawn as instanced world-space quads (see the
        // precip* shaders + ParticleSystem-style pass in the HDR scene), so it
        // falls through the 3D world around the camera with real parallax.
        // pu.rainStrength is still passed (kept for struct-layout stability and
        // the rain wet-darkening of terrain) but no longer composited here.

        // The Grey (#: drained-region wash). When the player is in a drained region,
        // pull the WHOLE frame toward a cold desaturated grey + darken slightly, so
        // being in The Grey is unmistakable (not just guessable) instead of blending
        // with other dull areas. Only darkens/desaturates, so it can't wash out.
        if (pu.greyHaze > 0.001) {
            float gl = dot(tonemapped, float3(0.2126, 0.7152, 0.0722));
            float3 cold = float3(gl) * float3(0.84, 0.88, 0.97);   // cool slate grey
            tonemapped = mix(tonemapped, cold, clamp(pu.greyHaze, 0.0, 1.0) * 0.55);
            tonemapped *= (1.0 - clamp(pu.greyHaze, 0.0, 1.0) * 0.12);
        }

        // #130 BOLD INK OUTLINES. Screen-space edge pass from the scene depth. Sample a
        // cross of linearized-depth neighbours and look for a discontinuity (a silhouette
        // where geometry steps toward/away from the camera). Where one is found, darken the
        // pixel toward black so a crisp dark line traces the edge. The line is depth-aware:
        // it is normalised by the centre depth so a fixed world step inks the same whether
        // it is near or far (distant edges do not vanish, near edges do not over-thicken).
        // This catches terrain, structures, trees, AND creatures uniformly because they all
        // share this depth buffer. The sky (depth ~1) is skipped so the horizon stays clean.
        if (pu.celShade > 0.5) {
            float w = float(sceneDepth.get_width());
            float h = float(sceneDepth.get_height());
            float2 texel = float2(CEL_OUTLINE_PX / max(w, 1.0), CEL_OUTLINE_PX / max(h, 1.0));

            float dC = sceneDepth.sample(s, in.uv);
            // Skip the far plane (sky / nothing): no geometry edge to ink, and it keeps the
            // bright horizon from getting a dark fringe.
            if (dC < 0.9995) {
                float lc = celLinearizeDepth(dC);
                // #186 CURVATURE (second-difference) edge test. A silhouette is where the
                // depth GRADIENT jumps, not merely where depth is steep. |lL + lR - 2*lc| is
                // ~0 on ANY linearly-varying surface (flat ground, the same ground viewed
                // edge-on, and the gently curved horizon-bent terrain #180) and spikes only at
                // a true depth crease or step. The old first-difference (|lc - lR|) fired on
                // grazing ground, inking whole far regions black, AND drew a hard line at every
                // chunk boundary, where the greedy quads approximate the planet curve with a
                // per-chunk slope kink. Five taps (centre + L/R/U/D); normalise by centre depth
                // so a one-block ledge inks the same near and far.
                float lL = celLinearizeDepth(sceneDepth.sample(s, in.uv - float2(texel.x, 0.0)));
                float lR = celLinearizeDepth(sceneDepth.sample(s, in.uv + float2(texel.x, 0.0)));
                float lU = celLinearizeDepth(sceneDepth.sample(s, in.uv - float2(0.0, texel.y)));
                float lD = celLinearizeDepth(sceneDepth.sample(s, in.uv + float2(0.0, texel.y)));
                float curv = (abs(lL + lR - 2.0 * lc) + abs(lU + lD - 2.0 * lc)) / max(lc, 1.0);
                // #219: DISTANCE-scaled threshold. On flat ground at grazing angles the
                // horizon-bend quad diagonals leave rows of tiny depth creases whose
                // normalised curvature GROWS with distance, printing dashed lines across
                // open sand. A real silhouette at that range is a huge depth step, orders
                // above the crease, so raising the gate with distance kills the dashes
                // and costs nothing visible. Near range keeps the original sensitivity.
                float sens = CEL_DEPTH_SENS * (1.0 + lc * 0.030);
                // Smoothstep gate so the line antialiases instead of a hard 1-px jaggy.
                float edge = smoothstep(sens, sens * 2.2, curv);
                // #219 (root cause via colour probe): the dotted rows are PIXEL-WIDE
                // CRACKS, T-junction slits the smoothed terrain mesh leaves along its
                // contour lines. A slit shows the surface behind through a 1px gap;
                // the ink pass then outlines the slit (its centre and each arm look
                // like tiny edges), printing plus-shaped dots in rows in every biome.
                // Two crack-aware rules kill them without touching real silhouettes:
                // 1. A neighbour only counts as a silhouette if it is STILL far at
                //    ring-2 in the same direction (a real background is; a 1px slit
                //    is not), so the slit's arms stop inking.
                // 2. The centre must be the NEAR side (an outline belongs to the near
                //    surface), so the through-the-slit centre pixel stops inking.
                float lL2 = celLinearizeDepth(sceneDepth.sample(s, in.uv - float2(texel.x * 2.5, 0.0)));
                float lR2 = celLinearizeDepth(sceneDepth.sample(s, in.uv + float2(texel.x * 2.5, 0.0)));
                float lU2 = celLinearizeDepth(sceneDepth.sample(s, in.uv - float2(0.0, texel.y * 2.5)));
                float lD2 = celLinearizeDepth(sceneDepth.sample(s, in.uv + float2(0.0, texel.y * 2.5)));
                float gL = min(abs(lc - lL), abs(lc - lL2));
                float gR = min(abs(lc - lR), abs(lc - lR2));
                float gU = min(abs(lc - lU), abs(lc - lU2));
                float gD = min(abs(lc - lD), abs(lc - lD2));
                float effGap = max(max(gL, gR), max(gU, gD));
                edge *= smoothstep(0.28, 0.55, effGap);
                float minN = min(min(lL, lR), min(lU, lD));
                edge *= 1.0 - smoothstep(0.35, 0.80, lc - minN);
                // Fade ink after the 192-block far-detail transition and finish before
                // atmospheric fog begins at 290. Beams, leaves, and roof trim become
                // sub-pixel in this band at the capped internal resolution; keeping a
                // full-strength depth outline made their coverage blink on slow turns.
                // celLinearizeDepth uses its historical .20/420 detector range;
                // 313..363 maps to roughly 192..290 in the scene's .05/512 projection.
                float farFade = 1.0 - smoothstep(313.0, 363.0, lc);
                // #136 scale the ink darkness by the cel-outline intensity slider (0..1).
                tonemapped *= (1.0 - edge * CEL_OUTLINE_DARK * pu.celOutlineStr * farFade);
            }
        }

        // Gamma: drawable is bgra8Unorm (no hardware sRGB), apply manual gamma 2.2.
        tonemapped = pow(clamp(tonemapped, 0.0, 1.0), float3(1.0 / 2.2));

        // #274: the broad, shallow god-ray gradient spans many pixels per 8-bit
        // output level. Without quantization dither those levels become the large
        // screen-aligned squares/steps seen around the dawn sun even when the ray
        // visibility itself is smooth. Stable interleaved-gradient noise breaks only
        // the final LSB; it is too small to read as grain and is free when rays are off.
        if (volStrength > 0.001) {
            float q = fract(52.9829189 * fract(dot(in.position.xy,
                                                  float2(0.06711056, 0.00583715))));
            tonemapped = clamp(tonemapped + (q - 0.5) * (1.25 / 255.0), 0.0, 1.0);
        }

        return float4(tonemapped, 1.0);
    }

    // =========================================================
    // WORLD-SPACE PRECIPITATION — rain streaks + snow flakes (#32)
    //
    // Replaces the old screen-space overlay. A fixed pool of instanced quads
    // (6 verts each) lives in a cube of edge `boxSize` centred on the camera.
    // Each particle has a STABLE world position derived from its seed offset +
    // the camera position, so as the camera moves/turns the particles show real
    // parallax (they are anchored in world space, not the screen). Falling and
    // recycling are done entirely on the GPU: the y coordinate sweeps downward
    // with wall-clock time and WRAPS within the box (modulo), and x/z wrap into
    // the box around the camera — so particles that leave the volume reappear on
    // the opposite side. No per-frame CPU update; just a few thousand quads.
    //
    // mode: 1 = rain (thin vertical streaks, fast), 2 = snow (small flakes, slow
    //       drift). Driven from frame.camera.weather.
    // =========================================================
    struct PrecipVOut {
        float4 position [[position]];
        float2 uv;        // quad-local UV in [-1,1]
        float  fade;      // edge-of-box fade (0 at box boundary, 1 in centre)
        uint   isSnow [[flat]];
    };

    // Wrap v into [0, range) (handles negatives), branchless.
    static float wrapf(float v, float range) {
        return v - floor(v / range) * range;
    }

    vertex PrecipVOut precipVert(uint vid [[vertex_id]],
                                 device const PrecipParticle* parts [[buffer(0)]],
                                 constant PrecipUniforms& pu [[buffer(1)]]) {
        uint pi = vid / 6u;
        uint ci = vid % 6u;
        PrecipParticle sp = parts[pi];

        bool isSnow = (pu.mode > 1.5);
        float box     = pu.boxSize;
        float halfBox = box * 0.5;     // NB: `half` is a reserved MSL type name — do not use it
        float3 cam    = pu.camPosW.xyz;

        // Fall speed (world units / sec): rain fast, snow slow.
        float speed = isSnow ? 1.6 : 18.0;
        // Phase staggers each particle's start so they don't all fall in lockstep.
        float phase = sp.seed.w;

        // World position. x/z: stable seed offset around the camera, wrapped into
        // the box so the field always surrounds the player (recycling sideways as
        // the camera moves). y: sweeps downward over time and wraps within the box.
        float baseX = cam.x + sp.seed.x * box;
        float baseZ = cam.z + sp.seed.z * box;
        // Snow drifts sideways gently; rain falls near-straight (tiny slant).
        float drift = isSnow ? (sin(pu.wallClock * 0.5 + phase * 6.2831) * 0.6) : 0.0;
        baseX += drift;

        // Wrap x/z into [cam-halfBox, cam+halfBox]: keeps the volume centred on the camera.
        float wx = wrapf(baseX - (cam.x - halfBox), box) + (cam.x - halfBox);
        float wz = wrapf(baseZ - (cam.z - halfBox), box) + (cam.z - halfBox);

        // y: start from top of box, fall, wrap. Using wall-clock * speed + phase.
        float fallY = (sp.seed.y * box) - (pu.wallClock * speed + phase * box);
        float wy = wrapf(fallY - (cam.y - halfBox), box) + (cam.y - halfBox);

        float3 worldPos = float3(wx, wy, wz);

        // Edge fade: dim particles near the box boundary so the volume edge isn't a
        // hard wall (also hides the wrap discontinuity). Based on horizontal distance.
        float2 dxz = float2(wx - cam.x, wz - cam.z);
        float horiz = max(abs(dxz.x), abs(dxz.y));
        float fade = 1.0 - smoothstep(halfBox * 0.6, halfBox, horiz);

        // Billboard the quad toward the camera in clip space (like ambientLifeVert),
        // but stretch rain vertically into a streak. Snow is a small square.
        const float2 corners[6] = {
            float2(-1,-1), float2(1,-1), float2(1, 1),
            float2(-1,-1), float2(1, 1), float2(-1, 1)
        };
        float2 corner = corners[ci];

        float4 clipC = pu.viewProj * float4(worldPos, 1.0);
        // Half-size in clip units, scaled by 1/w so it's a consistent on-screen size.
        float wsafe = max(clipC.w, 0.001);
        float halfW = (isSnow ? 0.045 : 0.012) / wsafe;   // rain: thin in X
        float halfH = (isSnow ? 0.045 : 0.130) / wsafe;   // rain: long streak in Y
        float4 pos = clipC + float4(corner.x * halfW, corner.y * halfH, 0.0, 0.0);

        PrecipVOut o;
        o.position = pos;
        o.uv       = corner;
        o.fade     = fade;
        o.isSnow   = isSnow ? 1u : 0u;
        return o;
    }

    fragment float4 precipFrag(PrecipVOut in [[stage_in]]) {
        float alpha;
        float3 col;
        if (in.isSnow == 1u) {
            // Soft round flake.
            float d = dot(in.uv, in.uv);
            if (d > 1.0) discard_fragment();
            alpha = (1.0 - smoothstep(0.3, 1.0, d)) * 0.85;
            col = float3(0.95, 0.97, 1.00);
        } else {
            // Rain streak: soft vertical bar, fade toward the ends for a motion look.
            float xs = 1.0 - smoothstep(0.4, 1.0, abs(in.uv.x));   // across the streak
            float ys = 1.0 - smoothstep(0.6, 1.0, abs(in.uv.y));   // along the streak
            alpha = xs * ys * 0.55;
            col = float3(0.72, 0.80, 0.92);
        }
        alpha *= in.fade;
        if (alpha < 0.01) discard_fragment();
        return float4(col, alpha);
    }

    // =========================================================
    // AMBIENT LIFE — birds (day) + fireflies (night)
    //
    // Each sprite occupies 6 vertices (two triangles = billboard quad).
    // The vertex shader reconstructs which sprite and which corner from
    // vertex_id: sprite = vid / 6, corner = vid % 6.
    //
    // Birds: rounded procedural cartoon billboards, depth-tested against the
    //        world and turned along their camera-relative sky loops.
    // Fireflies: tiny emissive warm-green, HDR > 1, depth-tested so they
    //            hide behind terrain. They bloom via the existing bloom pass.
    // =========================================================

    struct ALVOut {
        float4 position [[position]];
        float4 color;    // rgba (HDR allowed)
        float2 uv;       // normalised quad UV (−1..1)
        float  flap [[flat]];
        uint   isBird [[flat]];
    };

    float alEllipse(float2 p, float2 center, float2 radius, float angle) {
        float2 q = p - center;
        float cs = cos(angle), sn = sin(angle);
        q = float2(cs * q.x + sn * q.y, -sn * q.x + cs * q.y);
        return length(q / radius);
    }

    float alMask(float d, float feather) {
        return 1.0 - smoothstep(1.0 - feather, 1.0 + feather, d);
    }

    vertex ALVOut ambientLifeVert(uint vid [[vertex_id]],
                                   device const AmbientSprite* sprites [[buffer(0)]],
                                   constant AmbientLifeUniforms& au [[buffer(1)]]) {
        // Reconstruct sprite index and corner.
        uint si = vid / 6u;
        uint ci = vid % 6u;
        AmbientSprite sp = sprites[si];

        // Corner offsets for a quad via two triangles.
        // ci: 0=BL,1=BR,2=TR, 3=BL,4=TR,5=TL
        const float2 corners[6] = {
            float2(-1,-1), float2(1,-1), float2(1, 1),
            float2(-1,-1), float2(1, 1), float2(-1, 1)
        };
        float2 corner = corners[ci];

        float size = sp.posW.w;
        bool isBird = size > 0.5;
        // #180 horizon curvature: fireflies hug the ground and birds share the same
        // sky, so both bend with the terrain (a distant firefly must not float).
        float4 camH = float4(au.camPosW.xyz, au.horizonOn);
        float3 centerW = horizonBend(sp.posW.xyz, camH);
        float4 clipCenter = au.viewProj * float4(centerW, 1.0);

        // A bird's loop tangent projected into screen space gives it a stable head-
        // first travel direction. Other motes preserve their old upright tiny quad.
        float aspect = max(au.aspect, 0.001);
        float2 forward = float2(1.0, 0.0);
        if (isBird) {
            float3 radial = sp.posW.xyz - au.camPosW.xyz;
            radial.y = 0.0;
            float invRadius = rsqrt(max(dot(radial.xz, radial.xz), 0.0001));
            float3 tangent = float3(-radial.z * invRadius, 0.0, radial.x * invRadius);
            float3 aheadW = horizonBend(sp.posW.xyz + tangent, camH);
            float4 clipAhead = au.viewProj * float4(aheadW, 1.0);
            float2 centerNdc = clipCenter.xy / max(abs(clipCenter.w), 0.001);
            float2 aheadNdc = clipAhead.xy / max(abs(clipAhead.w), 0.001);
            float2 deltaPixels = (aheadNdc - centerNdc) * float2(aspect, 1.0);
            if (dot(deltaPixels, deltaPixels) > 0.000001) forward = normalize(deltaPixels);
        }
        float2 up = float2(-forward.y, forward.x);
        float2 orientedPixels = forward * corner.x + up * corner.y;
        float2 orientedCorner = isBird
            ? float2(orientedPixels.x / aspect, orientedPixels.y)
            : float2(corner.x, corner.y * 1.5);
        // Birds use a world-sized billboard so they remain readable at their 28-60
        // block loops. Tiny motes keep the old falloff and therefore their old size.
        float screenSize = isBird ? size : size / max(abs(clipCenter.w), 0.001);
        float4 pos = clipCenter + float4(orientedCorner * screenSize, 0.0, 0.0);

        ALVOut o;
        o.position = pos;
        o.color    = sp.color;
        o.uv       = corner;
        o.flap = sin(au.wallClock * (5.1 + fmod(float(si), 3.0) * 0.35)
                     + float(si) * 1.91);
        o.isBird = isBird ? 1u : 0u;
        return o;
    }

    fragment float4 ambientLifeFrag(ALVOut in [[stage_in]]) {
        float alpha = in.color.a;

        if (in.isBird == 1u) {
            float2 uv = in.uv;
            float flap = in.flap;

            // Rounded tail feathers and floppy wings keep the silhouette cohesive;
            // everything overlaps the plump body instead of floating beside it.
            float tailTopD = alEllipse(uv, float2(-0.54,  0.13), float2(0.37, 0.12),  0.34);
            float tailBotD = alEllipse(uv, float2(-0.54, -0.13), float2(0.37, 0.12), -0.34);
            float bodyD = alEllipse(uv, float2(-0.05, -0.03), float2(0.57, 0.31), 0.0);
            float headD = alEllipse(uv, float2(0.47, 0.03), float2(0.27, 0.26), 0.0);
            float backWingD = alEllipse(uv, float2(-0.10, -flap * 0.18),
                                        float2(0.38, 0.15), -flap * 0.58);
            float frontWingD = alEllipse(uv, float2(-0.02, flap * 0.27),
                                         float2(0.45, 0.17 + abs(flap) * 0.04), flap * 0.72);

            float tail = max(alMask(tailTopD, 0.06), alMask(tailBotD, 0.06));
            float body = alMask(bodyD, 0.045);
            float head = alMask(headD, 0.05);
            float backWing = alMask(backWingD, 0.055);
            float frontWing = alMask(frontWingD, 0.055);

            // Pointed yellow beak with a slightly larger dark surround.
            float2 bp = uv - float2(0.64, 0.035);
            float beakReach = 1.0 - clamp(bp.x / 0.33, 0.0, 1.0);
            float beakX = smoothstep(-0.02, 0.02, bp.x)
                        * (1.0 - smoothstep(0.29, 0.33, bp.x));
            float beak = beakX
                       * (1.0 - smoothstep(0.125 * beakReach, 0.16 * beakReach + 0.012, abs(bp.y)));
            float beakOutline = smoothstep(-0.035, 0.005, bp.x)
                              * (1.0 - smoothstep(0.32, 0.36, bp.x))
                              * (1.0 - smoothstep(0.16 * beakReach, 0.20 * beakReach + 0.016, abs(bp.y)));

            float outline = max(max(alMask(tailTopD / 1.16, 0.035), alMask(tailBotD / 1.16, 0.035)),
                                max(alMask(bodyD / 1.13, 0.035), alMask(headD / 1.14, 0.035)));
            outline = max(outline, max(alMask(backWingD / 1.15, 0.035),
                                       alMask(frontWingD / 1.14, 0.035)));
            outline = max(outline, beakOutline);
            if (outline < 0.01) discard_fragment();

            float3 base = in.color.rgb;
            float3 ink = float3(0.055, 0.035, 0.055);
            float3 col = ink;
            col = mix(col, base * 0.52, backWing);
            col = mix(col, base * 0.68, tail);
            col = mix(col, base, body);
            float bellyD = alEllipse(uv, float2(0.10, -0.15), float2(0.34, 0.14), -0.08);
            float belly = alMask(bellyD, 0.06) * body;
            col = mix(col, mix(base, float3(1.0, 0.91, 0.72), 0.72), belly);
            col = mix(col, base * 0.92, head);
            col = mix(col, mix(base, float3(1.0), 0.23), frontWing);
            col = mix(col, float3(1.0, 0.67, 0.08), beak);

            // One oversized eye supplies the intentionally funny cartoon read.
            float eye = alMask(alEllipse(uv, float2(0.52, 0.085), float2(0.095, 0.105), 0.0), 0.08) * head;
            float pupil = alMask(alEllipse(uv, float2(0.555, 0.082), float2(0.041, 0.055), 0.0), 0.10) * eye;
            col = mix(col, float3(1.0, 0.97, 0.84), eye);
            col = mix(col, ink, pupil);

            return float4(col, alpha * outline);
        } else {
            float d = dot(in.uv, in.uv);
            if (d > 1.0) discard_fragment();
            // Firefly: gaussian glow dot.  Multiply out to HDR levels for bloom.
            float glow = exp(-d * 3.5);
            // Outer halo (broader, dimmer)
            float halo = exp(-d * 1.2) * 0.35;
            float total = glow + halo;
            // Standard alpha makes the CPU-authored fade meaningful. At a firefly's
            // centre, even its dim phase remains HDR green (>1 after blending), while
            // the clamp keeps peak blink alpha from exceeding one.
            return float4(in.color.rgb * total, clamp(alpha * total, 0.0, 1.0));
        }
    }

    // =========================================================
    // SUB-VOXEL PROPS (#51/#52) — detailed toy models for flowers / mushrooms /
    // crystals, GPU-INSTANCED: the CPU uploads only the tiny instance list and the
    // vertex shader expands each instance's model from a model table. No per-frame
    // geometry rebuild, so prop count is nearly free (scales to dense grass).
    // =========================================================
    struct PropUniforms { float4x4 viewProj; float4 params; float4 camPosH; };  // params.x day, y time, z foliage, w verts/part; camPosH = #180 horizon curvature
    struct PropVOut { float4 position [[position]]; float3 nrm; float3 col; };
    // Matches bf_prop_instance (24 bytes): position(12) + type(4) + seed(4) + sat(4).
    struct PropInstanceGPU { packed_float3 position; uint type; uint seed; float sat; };
    // One part of a model: centre, half-extent, colour (all in 0..1 block space), and
    // a shape selector (0=box, 1=sphere, 2=cone, 3=cylinder). (#52/#62)
    struct PropCuboid { packed_float3 center; packed_float3 half_; packed_float3 color; float shape; };

    constant float3 kFaceNrm[6] = {
        float3(1,0,0), float3(-1,0,0), float3(0,1,0), float3(0,-1,0), float3(0,0,1), float3(0,0,-1)
    };
    constant float3 kFaceCorner[24] = {
        float3(0.5,-0.5,-0.5), float3(0.5,-0.5,0.5), float3(0.5,0.5,0.5), float3(0.5,0.5,-0.5),     // +X
        float3(-0.5,-0.5,0.5), float3(-0.5,-0.5,-0.5), float3(-0.5,0.5,-0.5), float3(-0.5,0.5,0.5),  // -X
        float3(-0.5,0.5,-0.5), float3(0.5,0.5,-0.5), float3(0.5,0.5,0.5), float3(-0.5,0.5,0.5),       // +Y
        float3(-0.5,-0.5,0.5), float3(0.5,-0.5,0.5), float3(0.5,-0.5,-0.5), float3(-0.5,-0.5,-0.5),  // -Y
        float3(0.5,-0.5,0.5), float3(-0.5,-0.5,0.5), float3(-0.5,0.5,0.5), float3(0.5,0.5,0.5),       // +Z
        float3(-0.5,-0.5,-0.5), float3(0.5,-0.5,-0.5), float3(0.5,0.5,-0.5), float3(-0.5,0.5,-0.5)    // -Z
    };
    constant uint kTriIdx[6] = { 0u,1u,2u, 0u,2u,3u };
    constant uint kPropMaxCuboids = 5u;   // model table stride per type; MUST equal makePropModelTable slots (5).
                                          // 6d4aeaf grew the CPU table to 5 slots without this constant, so every
                                          // prop row past 0 read shifted cuboids (pink grass, lily-pad trees).
    // #62: build a unit primitive (extent [-0.5,0.5]) from a local vertex id, as a
    // surface of revolution. Small props use 6 slices; canopy/bush spheres pass
    // 144 verts and get 8 slices x 3 stacks for view-stable silhouettes (#265).
    // shape: 1=sphere, 2=cone, 3=cylinder. Writes
    // the outward normal. Verts past the shape's own count are returned degenerate.
    static float3 propRevVert(uint lv, uint shape, uint vertsPerShape, thread float3& nrm) {
        uint S = (shape == 1u && vertsPerShape >= 144u) ? 8u : 6u;
        uint T = (shape == 1u) ? ((S == 8u) ? 3u : 2u) : 1u;
        uint sideV = S * T * 6u;                       // verts used by the side quads
        if (lv < sideV) {
            uint quad = lv / 6u;
            const float2 co[6] = { float2(0,0), float2(1,0), float2(1,1),
                                   float2(0,0), float2(1,1), float2(0,1) };
            float2 c = co[lv % 6u];
            float a = 6.2831853 * (float(quad % S) + c.x) / float(S);
            float t = (float(quad / S) + c.y) / float(T);  // 0..1 up the axis
            float r, y, slope;
            if (shape == 1u) {            // sphere
                float phi = 3.14159265 * t;
                r = sin(phi) * 0.5; y = -cos(phi) * 0.5; slope = 0.0;
            } else if (shape == 2u) {     // cone: wide base, apex up
                r = (1.0 - t) * 0.5; y = t - 0.5; slope = 0.5;
            } else {                      // cylinder: octagonal tube
                r = 0.5; y = t - 0.5; slope = 0.0;
            }
            float ca = cos(a), sa = sin(a);
            float3 p = float3(r * ca, y, r * sa);
            nrm = (shape == 1u) ? normalize(p + float3(1e-5)) : normalize(float3(ca, slope, sa));
            return p;
        }
        // END CAPS (#62): cylinders are open tubes and cones are open at the base, so the
        // ends showed hollow. Close them with a triangle fan. Sphere needs none (poles).
        if (shape == 1u) { nrm = float3(0,1,0); return float3(0); }
        uint capTri = (lv - sideV) / 3u, cv = (lv - sideV) % 3u;
        bool isTop = (capTri >= S);
        uint ti = isTop ? (capTri - S) : capTri;
        if (ti >= S || (shape == 2u && isTop)) { nrm = float3(0,1,0); return float3(0); } // cone: no top
        float yc = isTop ? 0.5 : -0.5;
        float a0 = 6.2831853 * float(ti) / float(S), a1 = 6.2831853 * float(ti + 1u) / float(S);
        float3 p = (cv == 0u) ? float3(0.0, yc, 0.0)
                 : (cv == 1u) ? float3(0.5 * cos(a0), yc, 0.5 * sin(a0))
                 :              float3(0.5 * cos(a1), yc, 0.5 * sin(a1));
        nrm = float3(0.0, isTop ? 1.0 : -1.0, 0.0);
        return p;
    }
    // Flower blooms pick a bold colour from this palette per-instance (by seed), so
    // a meadow is multicoloured without needing a block type per colour. (#51 m2)
    constant float3 kFlowerPalette[6] = {
        float3(0.90, 0.20, 0.22),   // red
        float3(0.97, 0.82, 0.16),   // yellow
        float3(0.94, 0.45, 0.78),   // pink
        float3(0.62, 0.40, 0.90),   // purple
        float3(0.97, 0.97, 0.98),   // white
        float3(0.35, 0.62, 0.95)    // sky blue
    };
    // Mushroom caps vary too (#51 m2): red, brown, tan, orange.
    constant float3 kMushroomPalette[4] = {
        float3(0.85, 0.16, 0.14),   // classic red
        float3(0.55, 0.36, 0.22),   // brown
        float3(0.80, 0.68, 0.46),   // tan
        float3(0.88, 0.50, 0.18)    // orange
    };

    vertex PropVOut propInstVmain(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device PropInstanceGPU* insts  [[buffer(0)]],
                                  constant PropUniforms& u             [[buffer(1)]],
                                  const device PropCuboid* models      [[buffer(2)]]) {
        PropVOut o;
        PropInstanceGPU inst = insts[iid];
        // type -> row (36 red,37 yellow,39 mushroom,40 crystal,38 grass,41 pebble,
        //              42 berry,43 reed,44 cactus,45 seashell)
        int row = (inst.type == 36u) ? 0 : (inst.type == 37u) ? 1 : (inst.type == 39u) ? 2 : (inst.type == 40u) ? 3 : (inst.type == 38u) ? 4 : (inst.type == 41u) ? 5 : (inst.type == 42u) ? 6 : (inst.type == 43u) ? 7 : (inst.type == 44u) ? 8 : (inst.type == 45u) ? 9 : (inst.type == 46u) ? 10 : (inst.type == 47u) ? 11
                : (inst.type == 5u) ? 12 : (inst.type == 27u) ? 13   // #62 foliage (oak, birch)
                : (inst.type == 21u) ? 14 : (inst.type == 22u) ? 15  // #62 trunk (oak, birch)
                : (inst.type == 48u) ? 16 : (inst.type == 49u) ? 17   // #62 pine needles(16), pine trunk(17)
                : -1;
        bool isLeaf = (row == 12 || row == 13);
        bool isTrunk = (row == 14 || row == 15 || row == 17);
        uint vertsPerShape = max(1u, uint(u.params.w + 0.5));
        uint cuboidIdx = vid / vertsPerShape;
        if (row < 0 || cuboidIdx >= kPropMaxCuboids) { o.position = float4(0); o.nrm = float3(0); o.col = float3(0); return o; }
        PropCuboid cu = models[uint(row) * kPropMaxCuboids + cuboidIdx];
        float3 half_ = float3(cu.half_);
        if (half_.x == 0.0 && half_.y == 0.0 && half_.z == 0.0) { o.position = float4(0); o.nrm = float3(0); o.col = float3(0); return o; } // unused slot

        // #62: choose the part's primitive. 0=box (cube face table), else a surface of
        // revolution (sphere/cone/cylinder).
        uint shape = uint(cu.shape + 0.5);
        float3 cpos, cnrm;
        uint lv = vid % vertsPerShape;
        if (shape == 0u) {
            if (lv >= 36u) { o.position = float4(0); o.nrm = float3(0); o.col = float3(0); return o; }
            uint face = lv / 6u, corner = kTriIdx[lv % 6u];
            cpos = kFaceCorner[face * 4u + corner];
            cnrm = kFaceNrm[face];
        } else {
            cpos = propRevVert(lv, shape, vertsPerShape, cnrm);
        }
        float3 lp = float3(cu.center) + cpos * (2.0 * half_);   // local pos in block space
        // per-instance yaw about block centre. Trunks must NOT spin per-block, or the
        // stacked log segments would misalign into a jagged trunk (#62).
        float yaw = isTrunk ? 0.0 : float(inst.seed & 1023u) / 1023.0 * 6.2831853;
        float cy = cos(yaw), sy = sin(yaw);
        float dx = lp.x - 0.5, dz = lp.z - 0.5;
        lp.x = 0.5 + dx * cy - dz * sy;
        lp.z = 0.5 + dx * sy + dz * cy;
        float3 nm = float3(cnrm.x * cy - cnrm.z * sy, cnrm.y, cnrm.x * sy + cnrm.z * cy);
        // Small flowers vary naturally without becoming waist-high toy blocks.
        if (row == 0 || row == 1) {
            float flowerScale = 0.62 + 0.18 * (float((inst.seed >> 12u) & 255u) / 255.0);
            lp.x = 0.5 + (lp.x - 0.5) * flowerScale;
            lp.z = 0.5 + (lp.z - 0.5) * flowerScale;
            lp.y *= flowerScale;
        }
        if (row == 2) {
            float mushroomScale = 0.70 + 0.18 * (float((inst.seed >> 14u) & 255u) / 255.0);
            lp.x = 0.5 + (lp.x - 0.5) * mushroomScale;
            lp.z = 0.5 + (lp.z - 0.5) * mushroomScale;
            lp.y *= mushroomScale;
        }
        // Most grass is short ground cover. A stable minority keeps the old tall
        // silhouette, and dense patches spread modestly instead of scaling to 2x.
        if (row == 4) {
            float dens = float((inst.seed >> 28u) & 0xFu);   // 0..8 same-kind neighbours
            bool tall = ((inst.seed >> 12u) & 7u) == 0u;
            float widthScale = 0.72 + min(dens, 8.0) * 0.035;
            float heightScale = tall ? 0.92 : 0.40 + 0.12 * (float((inst.seed >> 16u) & 255u) / 255.0);
            lp.x = 0.5 + (lp.x - 0.5) * widthScale;
            lp.z = 0.5 + (lp.z - 0.5) * widthScale;
            lp.y *= heightScale;
        }
        if (row == 6) {
            float dens = float((inst.seed >> 28u) & 0xFu);
            float bushScale = 1.0 + min(dens, 8.0) * 0.05;
            lp.x = 0.5 + (lp.x - 0.5) * bushScale;
            lp.z = 0.5 + (lp.z - 0.5) * bushScale;
            lp.y *= bushScale;
        }
        // Desert cactus (#152): one stored plant block renders as a varied tall cactus.
        // The smallest is about 2x the old prop height and the biggest is about 5x.
        // Arm pieces are selectively hidden per seed, then yawed like every prop, so
        // a desert reads as mixed silhouettes without adding multi-block collision.
        if (row == 8) {
            uint variant = inst.seed & 3u;
            float hscale = (variant == 0u) ? 2.0 : (variant == 1u) ? 2.8 : (variant == 2u) ? 3.7 : 5.0;
            float wscale = (variant == 3u) ? 1.10 : 1.0;
            bool rightArm = (variant != 0u);
            bool leftArm = (variant >= 2u);
            if ((cuboidIdx == 1u || cuboidIdx == 2u) && !rightArm) {
                o.position = float4(0); o.nrm = float3(0); o.col = float3(0); return o;
            }
            if ((cuboidIdx == 3u || cuboidIdx == 4u) && !leftArm) {
                o.position = float4(0); o.nrm = float3(0); o.col = float3(0); return o;
            }
            lp.x = 0.5 + (lp.x - 0.5) * wscale;
            lp.z = 0.5 + (lp.z - 0.5) * wscale;
            lp.y *= hscale;
        }
        // #62 trunk vs branch. Branches (bit 31) lie sideways; trunks taper with height.
        if (isTrunk) {
            uint isBranch = (inst.seed >> 31u) & 1u;
            if (isBranch == 1u) {
                // Horizontal branch: rotate the vertical cylinder so its long axis lies
                // along x or z (bit 30). Keep it fairly FAT so it fills the block on all
                // sides, and EXTEND it past the block so it bridges to the trunk and the
                // next branch step instead of floating as a detached stub. (#62)
                uint axis = (inst.seed >> 30u) & 1u;
                float ox = lp.x - 0.5, oy = lp.y - 0.5, oz = lp.z - 0.5;
                const float thin = 0.85;   // fatter (fill the block)
                const float ext  = 1.4;    // longer (reach to trunk / next step)
                if (axis == 0u) {            // long axis -> x
                    lp = float3(0.5 + oy * ext, 0.5 + ox * thin, 0.5 + oz * thin);
                    nm = float3(nm.y, nm.x, nm.z);
                } else {                     // long axis -> z
                    lp = float3(0.5 + oz * thin, 0.5 + ox * thin, 0.5 + oy * ext);
                    nm = float3(nm.x, nm.z, nm.y);
                }
                // #62 followup: branches lie SIDEWAYS (horizontal), no downward slant. The
                // earlier inner-end droop made them hang and point at the ground.
            } else {
                // Trunk taper: narrows with height above the base (bits 24-30 = level).
                uint level = (inst.seed >> 24u) & 0x7Fu;
                float ws = clamp(1.0 - float(level) * 0.045, 0.5, 1.0);
                lp.x = 0.5 + (lp.x - 0.5) * ws;
                lp.z = 0.5 + (lp.z - 0.5) * ws;
                // #62 slant: at a lean-bend (bit 23), bend the trunk's BASE down and over
                // toward the lower trunk (bits 21-22 dir) so the two segments connect into
                // an elbow instead of two floating cylinders.
                if (((inst.seed >> 23u) & 1u) == 1u) {
                    uint sdir = (inst.seed >> 21u) & 3u;
                    float2 dv = (sdir == 0u) ? float2(1.0, 0.0)
                              : (sdir == 1u) ? float2(-1.0, 0.0)
                              : (sdir == 2u) ? float2(0.0, 1.0) : float2(0.0, -1.0);
                    float t = clamp((0.5 - lp.y) * 2.0, 0.0, 1.0);   // 0 at centre, 1 at the base
                    lp.x += dv.x * t * 0.9;
                    lp.z += dv.y * t * 0.9;
                    lp.y -= t * 0.55;
                }
            }
        }
        // Wind sway (#45/#52): thin foliage (grass row 4, flowers rows 0/1) bends in
        // the breeze — top sways, base stays rooted. Gated by params.z (foliage toggle).
        if (u.params.z > 0.5 && (row == 0 || row == 1 || row == 4 || row == 7)) {
            float ph = float(inst.position.x) * 0.30 + float(inst.position.z) * 0.25;
            float t  = u.params.y;
            float sway = sin(t * 1.6 + ph) + 0.35 * sin(t * 3.1 + ph * 1.7);
            lp.x += sway * max(0.0, lp.y - 0.05) * 0.22;   // height-rooted bend
        }
        float3 world = float3(inst.position) + lp;
        // #180 horizon curvature: props/trees must bend with the terrain or distant
        // canopies float above the sunken ground.
        o.position = u.viewProj * float4(horizonBend(world, u.camPosH), 1.0);
        // Leaf spheres overlap to form one canopy. Keep their tone flat so the
        // winning shell at an overlap cannot flash between different facet shades
        // as a distant camera turns. Oak/birch still differ in the model palette.
        o.nrm = isLeaf ? float3(0.0) : nm;
        // flat colour, drained by region saturation, scaled by day brightness
        float3 base = float3(cu.color);
        // Per-instance variety: flower blooms (rows 0/1, cuboid 1) take a palette
        // colour by seed; every prop gets a small brightness jitter so clumps of
        // grass/flowers don't look stamped from one mould.
        if ((row == 0 || row == 1) && cuboidIdx == 1u) base = kFlowerPalette[inst.seed % 6u];
        if (row == 2 && cuboidIdx == 1u) base = kMushroomPalette[inst.seed % 4u];  // mushroom cap variety
        // Leaves use a broad world-space tint: enough texture to keep a canopy from
        // going flat, but adjacent voxels differ by <1%, so an overlap cannot flash.
        // Seed jitter stays on isolated props only.
        if (isLeaf) {
            float leafPhase = float(inst.position.x) * 0.18
                            + float(inst.position.y) * 0.10
                            + float(inst.position.z) * 0.14;
            base *= 1.0 + 0.04 * sin(leafPhase);
        } else {
            base *= 0.90 + 0.20 * (float((inst.seed >> 5u) & 255u) / 255.0);
        }
        float lum = dot(base, float3(0.30, 0.59, 0.11));
        float3 drained = float3(0.22, 0.25, 0.32) * (0.45 + lum * 0.85);
        o.col = (drained + (base - drained) * clamp(inst.sat, 0.0, 1.0)) * u.params.x;
        return o;
    }
    fragment float4 propFmain(PropVOut in [[stage_in]]) {
        // Flat toy shading: up-faces brighter, down-faces a touch darker.
        float up = clamp(in.nrm.y, -1.0, 1.0);
        float shade = 0.80 + 0.20 * max(0.0, up) - 0.12 * max(0.0, -up);
        return float4(clamp(in.col * shade, 0.0, 1.0), 1.0);
    }

    // #70 first-person viewmodel: a few cuboids (arm + held item) drawn in VIEW space
    // (camera at origin), so they stay fixed in front of the player. params: x,y = bob
    // offset, z = day brightness. Parts are pre-ordered back-to-front in the buffer.
    struct ViewModelUniforms { float4x4 proj; float4 params; };
    vertex PropVOut viewModelVmain(uint vid [[vertex_id]],
                                   const device PropCuboid* parts [[buffer(0)]],
                                   constant ViewModelUniforms& u  [[buffer(1)]]) {
        PropVOut o;
        uint part = vid / 36u;
        PropCuboid cu = parts[part];
        float3 half_ = float3(cu.half_);
        uint v = vid % 36u, face = v / 6u, corner = kTriIdx[v % 6u];
        float3 cpos = kFaceCorner[face * 4u + corner];
        float3 vp = float3(cu.center) + cpos * (2.0 * half_);
        vp.x += u.params.x; vp.y += u.params.y;          // idle bob
        // #: goofy tool swing. params.w < 0 = idle; 0..1 = swing phase. The whole arm +
        // held item pitch about the wrist in a quick chop (down-forward then back), with a
        // little overshoot wobble so it reads as a fun bonk, not a precise motion.
        if (u.params.w >= 0.0) {
            float ph  = u.params.w;
            float arc = sin(ph * 3.14159265) * 1.05            // main down-up chop
                      + sin(ph * 9.4248) * 0.10;               // little jiggle/overshoot
            float3 piv = float3(0.44, -1.04, -0.92);           // wrist/elbow pivot
            float3 d = vp - piv;
            float ca = cos(arc), sa = sin(arc);
            vp = piv + float3(d.x, d.y * ca - d.z * sa, d.y * sa + d.z * ca);  // pitch about X
            vp.z -= sin(ph * 3.14159265) * 0.18;               // thrust forward on the chop
        }
        o.position = u.proj * float4(vp, 1.0);
        o.nrm = kFaceNrm[face];
        o.col = float3(cu.color) * (0.62 + 0.38 * u.params.z);  // dim a touch at night
        return o;
    }
    fragment float4 viewModelFmain(PropVOut in [[stage_in]]) {
        float up = clamp(in.nrm.y, -1.0, 1.0);
        float shade = 0.74 + 0.26 * max(0.0, up) - 0.10 * max(0.0, -up);
        return float4(clamp(in.col * shade, 0.0, 1.0), 1.0);
    }
    """
}
