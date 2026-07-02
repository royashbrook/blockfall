import MetalKit
import simd

// MARK: - Uniforms (must match the MSL struct byte layout)

/// Terrain pass uniforms (64 bytes).
/// Swift layout: viewProj(64) + chunkOrigin(16) + sunDirTime(16) + lightViewProj(64) + dimSatN(16) = 176 bytes.
struct Uniforms {
    var viewProj:      simd_float4x4           // 64 bytes
    var chunkOrigin:   SIMD4<Float>            // 16 bytes  xyz=origin, w=dim_saturation (min corner)
    var sunDirTime:    SIMD4<Float>            // 16 bytes  xyz=sun_dir, w=time_of_day
    var lightViewProj: simd_float4x4           // 64 bytes  sun light-space VP (near cascade)
    var dimSatN:       SIMD4<Float>            // 16 bytes  x=+X corner, y=+Z, z=+XZ (for grey bilerp)
    var lightViewProjF: simd_float4x4 = matrix_identity_float4x4  // 64 bytes  far cascade (#46)
}

/// Matches the MSL SkyUniforms struct.
struct SkyUniforms {
    var sunDirTime: SIMD4<Float>    // xyz sun dir (pointing FROM sun, i.e. downward), w time-of-day
    var camRight:   SIMD4<Float>    // xyz world-space camera right, w = tanHalfFov
    var camUp:      SIMD4<Float>    // xyz world-space camera up,    w = aspect ratio
    var camFwd:     SIMD4<Float>    // xyz world-space camera forward (into scene), w unused
}

/// Extra per-frame uniforms passed as fragment bytes at index 2 for terrain pass,
/// and as both vertex+fragment bytes for the underwater post pass.
/// 32 bytes — not seen by the engine, set in draw(in:).
struct WaterUniforms {
    var wallClockSecs: Float
    var underwater:    Float
    var reflectScale:  Float = 1   // #: water-reflection toggle (0=off)
    var shadowScale:   Float = 1   // #: cast-shadow toggle (0=off, 2=harness shadow-factor debug)
    var cameraPosW:    SIMD4<Float> = .zero   // xyz = world-space camera pos, w unused
    var sunDirTime:    SIMD4<Float> = .zero   // xyz = sun dir, w = time_of_day (#43 water sky reflection)
    var celShade:      Float = 0   // #130 toon-band the diffuse term in fmain (0=off, 1=on)
    // #47 repurposed the former padding slots (the struct keeps the same 16-byte layout):
    //   cloudsOn -> volumetric cloud toggle for the sky pass (1=on, 0=off)
    //   pbrStr   -> stylized-PBR specular strength for the terrain pass (0..1)
    // Defaults are env-driven STATICS so the headless --shot harness (which default-builds
    // WaterUniforms) picks up the same look the live renderer ships, and BF_CLOUDS / BF_PBR
    // can drive a clouds-off or pbr-off comparison shot without touching the harness file.
    var cloudsOn:      Float = Renderer.cloudsDefault   // #47 cloud toggle (sky pass reads this)
    var pbrStr:        Float = Renderer.pbrDefault      // #47 stylized PBR specular strength
    // #162 packed weather for the sky/water shaders: precip mode (0/1/2) * 2 +
    // cloud coverage (0..1) * 0.98. Coverage drives how much sky the #146 cloud
    // layer fills (0 = clear blue, mid = scattered puffs, high = overcast sheet).
    // The default is env-driven (BF_WEATHER / BF_CLOUDCOVER) so the headless
    // --shot harness, which default-builds WaterUniforms, can force any weather;
    // the live renderer overwrites it per frame from the engine weather state.
    var weatherPack:   Float = Renderer.weatherPackDefault
    // ---- World-space voxel sun shadows (replaces the cascaded shadow map) ----
    // The renderer marches each fragment toward the sun through a 3D occupancy
    // texture (the engine's bf_world_shadow_volume). The shadow is a property of
    // the WORLD, identical for every camera position and view direction.
    var voxOrigin:  SIMD4<Float> = .zero  // xyz = grid origin (world block coords), w = march distance (world units)
    var voxDims:    SIMD4<Float> = .zero  // xyz = grid dims (voxels), w = soft-shadow flag (0=hard, 1=soft penumbra)
}

/// Uniforms for the HDR composite / tonemap pass (52 bytes).
struct PostUniforms {
    var bloomStrength:  Float   // fraction of bloom added
    var vignetteStr:    Float   // vignette strength
    var satBoost:       Float   // colour grade saturation multiplier
    var rainStrength:   Float   // 0..1 — drives precipitation overlay
    var wallClockSecs:  Float   // animation time for precipitation
    var godrayStrength: Float = 0   // #44 — 0 = god rays off (sun not visible)
    var sunScreenX:     Float = 0   // #44 — sun screen-space uv (matches fullscreenVert)
    var sunScreenY:     Float = 0
    var sunColorR:      Float = 1
    var sunColorG:      Float = 0.9
    var sunColorB:      Float = 0.7
    var greyHaze:       Float = 0   // #: 0..1 The-Grey screen wash (0 in test paths)
    var celShade:       Float = 0   // #130 1 = draw ink outlines + punchier cel grade
    var lensFlareStr:   Float = 0   // #132 lens-flare master strength (0 = off; folds toggle + daylight + look-at-sun)
    var celOutlineStr:  Float = 1   // #136 cel ink-outline intensity (0..1) scaling CEL_OUTLINE_DARK
}

/// #119 Volumetric god-ray uniforms — composite pass, buffer(1).
/// Everything the shadow-map raymarch needs: clip->world reconstruction, the two sun
/// shadow cascades (same maps fmain uses), camera pos + cascade radii, sun dir + colour,
/// and the single strength knob (0 = fully off). 240 bytes; layout matches the MSL struct.
struct VolUniforms {
    var invViewProj:    simd_float4x4 = matrix_identity_float4x4  // clip -> world
    var voxOrigin:      SIMD4<Float> = .zero   // xyz = shadow grid origin (world block coords), w = march distance
    var voxDims:        SIMD4<Float> = .zero   // xyz = grid dims (voxels), w = soft-shadow flag
    var camPosW:        SIMD4<Float> = .zero   // xyz = camera world pos, w = far coverage radius
    var sunDir:         SIMD4<Float> = .zero   // xyz = sun dir (points downward), w = 1 when the
                                               // half-res god-ray texture is bound (#167); 0 = inline march
    var sunColor:       SIMD4<Float> = .zero   // rgb = sun colour, w = volumetric strength (0 = off)
}

/// Wind + weather uniforms passed to terrain vertex shaders (both vmain and shadowVmain).
/// 16 bytes. Keeps foliage sway + rain factor in a dedicated buffer (index 3) so
/// Uniforms / WaterUniforms signatures stay unchanged (runPerfTest safe).
struct WindUniforms {
    var wallClockSecs: Float    //  4 — wall-clock seconds for sway animation
    var rainStrength:  Float    //  4 — 0..1 how hard it's raining (scales sway amp)
    var swayScale:     Float = 0  // #: foliage-sway toggle (0=off, default OFF)
    var pad1:          Float = 0
}

/// One part of a prop model for the GPU model table (#52/#62). 40 bytes; matches MSL
/// `struct PropCuboid { packed_float3 center, half_, color; float shape; }`. Plain
/// Floats (NOT SIMD3, which pads to 16) so the layout matches packed_float3 exactly.
struct PropCuboidGPU {
    var cx: Float, cy: Float, cz: Float   // center
    var hx: Float, hy: Float, hz: Float   // half-extent
    var r: Float,  g: Float,  b: Float    // colour
    var shape: Float = 0                   // 0=box, 1=sphere, 2=cone, 3=cylinder (#62)
}
/// Uniforms for the prop pass. 80 bytes; matches MSL PropUniforms.
struct PropUniforms {
    var viewProj: simd_float4x4
    var params:   SIMD4<Float>   // x = day brightness
}

/// Uniforms for the first-person viewmodel pass (#70). Matches MSL ViewModelUniforms.
struct ViewModelUniforms {
    var proj:   simd_float4x4
    var params: SIMD4<Float>   // x,y = bob offset, z = day brightness
}

/// The first-person arm + held item, as cuboids in VIEW space (camera at origin,
/// looking down -z). Lower-right of the view, forearm angling forward, fist at the
/// front. Ordered back-to-front so the always-on-top draw layers correctly. (#70)
func makeViewModelArm(skin: SIMD3<Float> = SIMD3<Float>(0.85, 0.66, 0.52),
                      sleeve: SIMD3<Float> = SIMD3<Float>(0.30, 0.50, 0.82)) -> [PropCuboidGPU] {
    func part(_ c: SIMD3<Float>, _ h: SIMD3<Float>, _ col: SIMD3<Float>) -> PropCuboidGPU {
        PropCuboidGPU(cx: c.x, cy: c.y, cz: c.z, hx: h.x, hy: h.y, hz: h.z, r: col.x, g: col.y, b: col.z, shape: 0)
    }
    // Sits low, just peeking up from the bottom of the view when idle (#70 feedback:
    // it was too high/centred). A swing/raise on action comes with the held-item pass.
    return [
        part(SIMD3( 0.46, -1.06, -0.95), SIMD3(0.12, 0.12, 0.16), sleeve), // cuff (back)
        part(SIMD3( 0.43, -0.96, -1.20), SIMD3(0.10, 0.10, 0.30), skin),   // forearm
        part(SIMD3( 0.41, -0.86, -1.58), SIMD3(0.13, 0.12, 0.13), skin),   // fist (front)
    ]
}

/// The held item shown in the viewmodel fist (#70 v2): tools (item ids 70-81) get a
/// handle + head silhouette coloured by tier (wood/stone/iron); blocks and other items
/// get a small held cube. Returns view-space cuboids, or [] for an empty hand.
// #70 a recognizable colour for a held BLOCK (item id == block id for placeables), so a
// block in hand reads as itself (grass green, stone grey, wood brown) instead of a generic
// tinted cube. Returns nil for non-block items (they fall back to the per-id tint).
func heldBlockColor(_ id: Int) -> SIMD3<Float>? {
    switch id {
    // #51: kept in step with the cohesive world palette (materialColor) so a held block
    // reads as the same colour it places.
    case 1:  return SIMD3(0.34, 0.72, 0.26)   // grass
    case 2:  return SIMD3(0.52, 0.35, 0.20)   // dirt
    case 3:  return SIMD3(0.50, 0.51, 0.56)   // stone
    case 4:  return SIMD3(0.74, 0.53, 0.28)   // oak planks
    case 5, 27: return SIMD3(0.34, 0.66, 0.28)// oak/birch leaves
    case 6:  return SIMD3(0.88, 0.76, 0.44)   // sand
    case 7:  return SIMD3(1.00, 0.92, 0.42)   // glow
    case 8:  return SIMD3(0.56, 0.57, 0.62)   // stone brick
    case 9:  return SIMD3(0.10, 0.40, 0.85)   // water
    case 10: return SIMD3(0.42, 0.43, 0.46)   // cobblestone
    case 12: return SIMD3(0.95, 0.97, 1.00)   // snow
    case 13: return SIMD3(0.66, 0.84, 1.00)   // ice
    case 21, 51: return SIMD3(0.47, 0.31, 0.16) // oak log / wood beam
    case 22: return SIMD3(0.83, 0.80, 0.68)   // birch log
    case 23: return SIMD3(0.84, 0.74, 0.52)   // birch planks
    case 24: return SIMD3(0.78, 0.36, 0.26)   // clay brick
    case 25: return SIMD3(0.74, 0.92, 1.00)   // glass
    case 26: return SIMD3(0.24, 0.82, 0.74)   // coloured glass
    case 28: return SIMD3(0.95, 0.93, 0.88)   // wool
    case 29: return SIMD3(0.40, 0.54, 0.34)   // mossy stone
    case 31: return SIMD3(0.78, 0.58, 0.26)   // chest
    case 48: return SIMD3(0.18, 0.42, 0.24)   // pine needles
    case 49: return SIMD3(0.40, 0.25, 0.15)   // pine log
    case 53: return SIMD3(0.30, 0.32, 0.36)   // iron gate (#95)
    default: return nil
    }
}

func makeHeldItem(_ itemId: Int) -> [PropCuboidGPU] {
    func part(_ c: SIMD3<Float>, _ h: SIMD3<Float>, _ col: SIMD3<Float>) -> PropCuboidGPU {
        PropCuboidGPU(cx: c.x, cy: c.y, cz: c.z, hx: h.x, hy: h.y, hz: h.z, r: col.x, g: col.y, b: col.z, shape: 0)
    }
    if itemId == 0 { return [] }
    let fx: Float = 0.40, fy: Float = -0.82, fz: Float = -1.62      // fist anchor
    let wood = SIMD3<Float>(0.52, 0.38, 0.22)
    if itemId >= 70 && itemId <= 81 {                               // a tool
        let isSword = itemId >= 79
        let tier = isSword ? (itemId - 79) : ((itemId - 70) / 3)    // 0 wood, 1 stone, 2 iron
        let mat: SIMD3<Float> = tier == 0 ? SIMD3(0.55, 0.40, 0.22)
                              : tier == 1 ? SIMD3(0.56, 0.56, 0.59)
                              :             SIMD3(0.82, 0.84, 0.88)
        let handle = part(SIMD3(fx, fy, fz), SIMD3(0.026, 0.27, 0.026), wood)   // shared shaft
        if isSword {                                                 // grip + pommel + guard + tapered blade
            return [
                part(SIMD3(fx, fy,        fz), SIMD3(0.028, 0.12, 0.028), wood),  // grip
                part(SIMD3(fx, fy - 0.13, fz), SIMD3(0.045, 0.03, 0.045), mat),   // pommel
                part(SIMD3(fx, fy + 0.13, fz), SIMD3(0.12, 0.025, 0.035), mat),   // wide crossguard
                part(SIMD3(fx, fy + 0.40, fz), SIMD3(0.035, 0.27, 0.05),  mat),   // blade
                part(SIMD3(fx, fy + 0.69, fz), SIMD3(0.018, 0.06, 0.04),  mat),   // blade tip (taper)
            ]
        }
        let kind = (itemId - 70) % 3   // 0 pickaxe, 1 axe, 2 shovel
        if kind == 0 {                                              // PICKAXE: bar + two angled points
            return [ handle,
                part(SIMD3(fx,        fy + 0.31, fz), SIMD3(0.06, 0.035, 0.045), mat),  // centre socket
                part(SIMD3(fx - 0.13, fy + 0.28, fz), SIMD3(0.07, 0.028, 0.04),  mat),  // left point (lower)
                part(SIMD3(fx + 0.13, fy + 0.28, fz), SIMD3(0.07, 0.028, 0.04),  mat),  // right point (lower)
            ]
        } else if kind == 1 {                                       // AXE: socket + wedge blade to one side
            return [ handle,
                part(SIMD3(fx + 0.05, fy + 0.30, fz), SIMD3(0.04, 0.06, 0.04),  mat),   // socket
                part(SIMD3(fx + 0.13, fy + 0.30, fz), SIMD3(0.035, 0.11, 0.055), mat),  // blade
            ]
        } else {                                                    // SHOVEL: socket + flat wide scoop
            return [ handle,
                part(SIMD3(fx, fy + 0.28, fz), SIMD3(0.035, 0.05, 0.03), mat),          // socket
                part(SIMD3(fx, fy + 0.37, fz), SIMD3(0.095, 0.06, 0.018), mat),         // scoop blade
            ]
        }
    }
    // Non-tool items must show too (#70): held UP above the fist so the hand does not
    // hide them (a cube at fist level was why blocks/berries did not display).
    if itemId == 90 {                                              // berry_cluster: red berries
        let r1 = SIMD3<Float>(0.82, 0.16, 0.22), r2 = SIMD3<Float>(0.62, 0.12, 0.24)
        return [
            part(SIMD3(fx,        fy + 0.15, fz),        SIMD3(0.05, 0.05, 0.05), r1),
            part(SIMD3(fx - 0.055, fy + 0.21, fz - 0.02), SIMD3(0.045, 0.045, 0.045), r2),
            part(SIMD3(fx + 0.055, fy + 0.20, fz + 0.02), SIMD3(0.045, 0.045, 0.045), r1),
            part(SIMD3(fx,        fy + 0.26, fz),        SIMD3(0.04, 0.04, 0.04), r2),
        ]
    }
    if itemId == 93 {                                              // mushroom: stem + red cap
        return [
            part(SIMD3(fx, fy + 0.14, fz), SIMD3(0.04, 0.07, 0.04), SIMD3(0.92, 0.90, 0.82)),
            part(SIMD3(fx, fy + 0.22, fz), SIMD3(0.09, 0.05, 0.09), SIMD3(0.80, 0.20, 0.18)),
        ]
    }
    // A held BLOCK shows as a small cube in its own colour, so it reads as that block.
    if let bc = heldBlockColor(itemId) {
        return [ part(SIMD3(fx, fy + 0.18, fz), SIMD3(0.13, 0.13, 0.13), bc) ]
    }
    // Any other item (materials, other food): a small cube held up, tinted by item id so
    // different things still look different.
    let h = Float((itemId &* 2654435761) & 0xFF) / 255.0
    let tint = SIMD3<Float>(0.42 + 0.40 * h, 0.44 + 0.28 * (1 - h), 0.40 + 0.34 * h)
    return [ part(SIMD3(fx, fy + 0.18, fz), SIMD3(0.11, 0.11, 0.11), tint) ]
}

/// Uniforms for the world-space precipitation pass (rain streaks / snow flakes).
/// Swift layout: viewProj(64) + camPosW(16) + params(16) = 96 bytes. Must match MSL PrecipUniforms.
struct PrecipUniforms {
    var viewProj:  simd_float4x4 = .init(diagonal: .one)   // 64 bytes — camera VP
    var camPosW:   SIMD4<Float>  = .zero                   // 16 bytes — xyz world cam pos, w unused
    var wallClock: Float         = 0                       // 4 — animation time (seconds)
    var mode:      Float         = 0                       // 4 — 0=clear, 1=rain, 2=snow
    var boxSize:   Float         = 0                       // 4 — full edge length of spawn volume (world units)
    var pad0:      Float         = 0                       // 4
}

/// Uniforms for the ambient-life sprite pass (birds / fireflies). 32 bytes.
struct AmbientLifeUniforms {
    var viewProj:      simd_float4x4 = .init(diagonal: .one)   // 64 bytes — camera VP
    var camPosW:       SIMD4<Float>  = .zero                   // 16 bytes — world cam pos
    var timeOfDay:     Float         = 0                       // 4 — 0..1 day cycle
    var wallClock:     Float         = 0                       // 4 — animation time
    var pad0:          Float         = 0
    var pad1:          Float         = 0
}
