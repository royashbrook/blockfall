// ============================================================================
// Blockfall — Renderer (Track E, M1 + M5 Cinematic Lighting)
// Owns the engine + Metal queue. Per frame: read GameView input -> drive the
// engine -> acquire the render frame -> draw each chunk mesh (greedy-meshed
// BFVertex buffers, UMA storageModeShared, referenced by handle) with a
// runtime-compiled stylized shader. Buffers freed by the engine are retired
// for a few frames so the GPU never reads a released buffer (threading.md §2).
//
// M5 lighting additions:
//   • Ambient occlusion from packed vertex bits [3:5]
//   • Sun shadow mapping  (2048²  depth32Float, PCF 3×3)
//   • HDR offscreen scene (rgba16Float + depth32Float)
//   • Bloom (bright-pass → half-res Gaussian blur H + V × 2 iterations)
//   • Composite / tonemap: ACES filmic + colour grade + vignette → drawable
// ============================================================================
import MetalKit
import simd
import CBlockcore
#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - GPU buffer registry (Swift owns MTLBuffers; engine refs by handle)

final class BufferRegistry {
    private var buffers: [UInt64: MTLBuffer] = [:]
    private var retired: [(buf: MTLBuffer, frame: Int)] = []
    private var next: UInt64 = 1
    private let lock = NSLock()
    let device: MTLDevice
    var currentFrame = 0
    init(device: MTLDevice) { self.device = device }

    func make(_ bytes: Int) -> (handle: UInt64, ptr: UnsafeMutableRawPointer)? {
        guard let buf = device.makeBuffer(length: max(bytes, 16), options: .storageModeShared) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let h = next; next += 1
        buffers[h] = buf
        return (h, buf.contents())
    }
    func free(_ handle: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if let b = buffers.removeValue(forKey: handle) { retired.append((b, currentFrame)) }
    }
    func lookup(_ handle: UInt64) -> MTLBuffer? {
        lock.lock(); defer { lock.unlock() }
        return buffers[handle]
    }
    // One-shot copy for the encode window: buffers are only added/freed between
    // frame_end and the next frame_begin, so a per-frame snapshot lets the three
    // render passes resolve handles lock-free (was ~1500 NSLock calls/frame).
    func snapshot() -> [UInt64: MTLBuffer] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }
    // Release buffers retired more than a few frames ago (GPU done with them).
    func collect() {
        lock.lock(); defer { lock.unlock() }
        retired.removeAll { currentFrame - $0.frame > 3 }
    }
}

func allocTrampoline(_ user: UnsafeMutableRawPointer?, _ bytes: UInt32) -> bf_gpu_buffer {
    guard let user = user else { return bf_gpu_buffer() }
    let reg = Unmanaged<BufferRegistry>.fromOpaque(user).takeUnretainedValue()
    guard let made = reg.make(Int(bytes)) else { return bf_gpu_buffer() }
    var out = bf_gpu_buffer(); out.handle = made.handle; out.contents = made.ptr; out.bytes = bytes
    return out
}
func freeTrampoline(_ user: UnsafeMutableRawPointer?, _ handle: UInt64) {
    guard let user = user else { return }
    Unmanaged<BufferRegistry>.fromOpaque(user).takeUnretainedValue().free(handle)
}

// Engine gameplay effects (BF_EVT_SFX, ev.i = effect code) -> Renderer.
func eventTrampoline(_ user: UnsafeMutableRawPointer?, _ ev: UnsafePointer<bf_event>?) {
    guard let user = user, let ev = ev else { return }
    Unmanaged<Renderer>.fromOpaque(user).takeUnretainedValue().handleEvent(ev.pointee)
}

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
    var pad2:          Float = 0
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
    var sunDir:         SIMD4<Float> = .zero   // xyz = sun dir (points downward), w unused
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

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let registry: BufferRegistry
    // Scene pipelines (chunk terrain + sky + underwater)
    private var pipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var skyPipeline: MTLRenderPipelineState!
    private var skyDepthState: MTLDepthStencilState!
    private var underwaterPipeline: MTLRenderPipelineState!
    // World-space voxel sun shadows: no shadow-map render pass (see uploadShadowVolume).
    // Post-processing pipelines
    private var bloomBrightPipeline: MTLRenderPipelineState!  // bright-pass (HDR → half-res)
    private var bloomBlurHPipeline: MTLRenderPipelineState!  // horizontal Gaussian
    private var bloomBlurVPipeline: MTLRenderPipelineState!  // vertical Gaussian
    private var compositePipeline: MTLRenderPipelineState!   // ACES + grade + vignette → drawable
    // Ambient life (birds + fireflies) — renderer-owned, no engine data needed
    private var ambientLifePipeline: MTLRenderPipelineState!
    private var ambientLifeDepthState: MTLDepthStencilState!
    private var ambientLifeBuffer: MTLBuffer!   // AmbientSprite array (CPU-updated each frame)
    private let kMaxAmbientSprites = 120   // birds + fireflies + pollen + grey ash motes

    // ---- Sub-voxel props (#51/#52: GPU-instanced) ---------------------------
    private var propPipeline: MTLRenderPipelineState!
    private var propModelTable: MTLBuffer!       // static: 4 types × 4 cuboids (PropCuboidGPU)
    private var viewModelPipeline: MTLRenderPipelineState!   // #70 first-person arm
    private var viewModelDepthState: MTLDepthStencilState!   // always-on-top
    private var viewModelArmBuf: MTLBuffer!
    private var viewModelArmCount = 0
    // #71 the player's own skin/shirt, applied to the first-person arm.
    private var charSkin  = SIMD3<Float>(0.85, 0.66, 0.52)
    private var charShirt = SIMD3<Float>(0.30, 0.50, 0.82)
    func setRenderDistance(_ chunks: Int) {   // #85 live render-distance slider
        if let e = engine { bf_set_render_distance(e, UInt32(max(8, min(40, chunks)))) }
    }
    func setCharacterAppearance(skin: SIMD3<Float>, shirt: SIMD3<Float>) {
        charSkin = skin; charShirt = shirt
        let arm = makeViewModelArm(skin: charSkin, sleeve: charShirt)
        viewModelArmCount = arm.count
        viewModelArmBuf = device.makeBuffer(bytes: arm, length: arm.count * MemoryLayout<PropCuboidGPU>.stride,
                                            options: .storageModeShared)
    }
    private var heldItemBuf: MTLBuffer?            // #70 v2: equipped item in hand
    private var heldItemCount = 0
    private var lastHeldItem = -1
    private var swingPulse: Double = -100          // #: time of last mine/place/attack (tool swing)
    private var propInstanceBuffer: MTLBuffer?   // per-frame: the bf_prop_instance list (tiny)
    private let kPropMaxCuboids = 5
    // #62: each part now draws up to 144 verts so it can be a box, sphere, cone, or
    // cylinder (the richest is an 8-slice x 3-stack sphere = 144). Unused verts are
    // emitted degenerate and culled.
    private let kPropVertsPerInstance = 5 * 144  // kPropMaxCuboids × kVertsPerShape

    // ---- Graphics effect toggles (pause-menu Options) ------------------------
    // Each effect can be switched on/off live. Persisted in UserDefaults; loaded
    // here so even the --playtest path picks them up. Waving foliage defaults OFF
    // (too busy with dense plants); the rest default ON.
    var gfxFoliage = UserDefaults.standard.object(forKey: "gfxFoliage") as? Bool ?? false
    var gfxWater   = UserDefaults.standard.object(forKey: "gfxWater")   as? Bool ?? true
    var gfxGodRays = UserDefaults.standard.object(forKey: "gfxGodRays") as? Bool ?? true
    // #132 lens flare: classic screen-space flare when the sun is on-screen and not
    // occluded. Separate toggle from God Rays (which drives the descending shafts).
    // Defaults ON; OFF removes the flare entirely (no cost, byte-identical to no-flare).
    var gfxLensFlare = UserDefaults.standard.object(forKey: "gfxLensFlare") as? Bool ?? true
    var gfxPollen  = UserDefaults.standard.object(forKey: "gfxPollen")  as? Bool ?? true
    // World-space voxel sun shadows. The old camera-following shadow map had a residual
    // sun-angle / camera-yaw wipe and shipped OFF. This is the from-scratch world-space
    // rebuild: a fixed world point's shadow is identical from every camera, so it defaults ON.
    var gfxShadows = UserDefaults.standard.object(forKey: "gfxShadows") as? Bool ?? true
    // Soft shadows: a few jittered sun rays for a penumbra instead of one hard ray. Costs
    // ~5x the march, so it is a quality knob gated behind its own toggle (default OFF, Air-safe).
    var gfxSoftShadows = UserDefaults.standard.object(forKey: "gfxSoftShadows") as? Bool ?? false
    // #116 character shadows: dynamic entities (mobs, villagers, animals, the player) are not in
    // the static voxel occupancy grid, so they cannot be ray-marched as casters. This toggle drives
    // (a) entities RECEIVING the world voxel sun shadow (they darken in shade, marched the same way
    // the terrain is) and (b) a cheap stylized CAST contact-shadow blob on the ground under each
    // entity, offset/stretched along the sun direction. Daylight-gated. Defaults ON.
    var gfxCharShadows = UserDefaults.standard.object(forKey: "gfxCharShadows") as? Bool ?? true
    // #130 cel-shade: bold outlines + banded toon lighting + punchier palette. This is the
    // new intended look so it defaults ON; OFF cleanly restores the prior smooth render for
    // A/B comparison. Drives both the terrain banding (fmain) and the composite ink/edge pass.
    var gfxCelShade = UserDefaults.standard.object(forKey: "gfxCelShade") as? Bool ?? true
    // #136 per-effect intensity (0..1) for the effects that have a meaningful strength
    // knob, each beside its on/off checkbox in the pause menu and persisted alongside its
    // toggle. The fraction multiplies that effect's shader strength:
    //   gfxGodRayStr  -> scales kGodRayStrength (the god-ray master). Default 0.5 so the
    //                    out-of-the-box look is HALF the old full strength (the old build
    //                    ran the equivalent of 1.0, which read too strong); 1.0 restores it.
    //   gfxBloomStr   -> scales the composite bloom add. Default 0.5 (the previous fixed
    //                    look maps to ~0.5 on this 0..2x range; 1.0 doubles the glow).
    //   gfxCelOutlineStr -> scales the cel ink-outline darkness. Default 1.0 (current look).
    // BF_GODRAY_STR (0..1) overrides the persisted/default god-ray slider, so the headless
    // --shot harness can render the rays at a fixed intensity for the 0/50/100 verification.
    var gfxGodRayStr: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_GODRAY_STR"], let v = Float(s) {
            return max(0, min(1, v))
        }
        return Float(UserDefaults.standard.object(forKey: "gfxGodRayStr") as? Double ?? 0.5)
    }()
    var gfxBloomStr      = Float(UserDefaults.standard.object(forKey: "gfxBloomStr")      as? Double ?? 0.5)
    var gfxCelOutlineStr = Float(UserDefaults.standard.object(forKey: "gfxCelOutlineStr") as? Double ?? 1.0)
    // #47 volumetric clouds: real raymarched, bold/toy-styled cumulus over the sky dome,
    // day/night gated. Defaults ON. The pause-menu checkbox is owned by the UI layer
    // (main.swift); this reads the same persisted "gfxClouds" key so wiring a checkbox there
    // is a one-liner, and BF_CLOUDS=0/1 overrides headless for the clouds-off comparison shot.
    // Wired: the pause menu has a "Volumetric Clouds" checkbox (tag 8) bound to "gfxClouds".
    var gfxClouds = Renderer.cloudsDefault > 0.5
    // #47 stylized PBR: procedural per-material roughness/metalness drives a restrained
    // specular that complements the cel bands (wet/shiny vs matte). Strength 0..1; default
    // 0.6 (a tasteful sheen that does not flatten the toon banding). BF_PBR overrides headless.
    var gfxPBRStr: Float = Renderer.pbrDefault
    // Env-driven look defaults, shared by the live renderer AND the WaterUniforms struct
    // defaults the headless --shot harness builds (so a shot ships the same look). BF_CLOUDS
    // and BF_PBR let the verification shots compare clouds-off / pbr-off without a harness edit.
    static let cloudsDefault: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_CLOUDS"], let v = Float(s) { return v > 0.5 ? 1 : 0 }
        return (UserDefaults.standard.object(forKey: "gfxClouds") as? Bool ?? true) ? 1 : 0
    }()
    static let pbrDefault: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_PBR"], let v = Float(s) { return max(0, min(1, v)) }
        return Float(UserDefaults.standard.object(forKey: "gfxPBRStr") as? Double ?? 0.6)
    }()
    // World-space precipitation (rain streaks / snow flakes) — renderer-owned,
    // instanced billboards in a volume around the camera. Drives off frame.camera.weather.
    private var precipPipeline: MTLRenderPipelineState!
    private var precipDepthState: MTLDepthStencilState!
    private var precipBuffer: MTLBuffer!           // PrecipParticlePod array (filled once at init)
    private let kPrecipCount = 6000                // #32: doubled (was 3000) — denser rain/snow; recycled in-shader
    private let kPrecipBox: Float = 48.0           // edge length of the spawn cube around the camera
    // Water translucency pass — re-draws chunks with alpha blend, water-only
    private var waterPipeline: MTLRenderPipelineState!
    private var waterDepthState: MTLDepthStencilState!
    // Sub-systems
    private var entityRenderer: EntityRenderer!
    private var particles: ParticleSystem!
    // Engine state
    private var engine: OpaquePointer?
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    // #127 cosmetic animation clock. Drives grass sway, creature/leaf wiggle, pollen,
    // ambient sprites, and precipitation. It accumulates frame dt ONLY when the world is
    // not paused, so on pause every cosmetic motion freezes in place and on unpause it
    // resumes from the exact same value (no jump). This replaces the old wall-clock read
    // (CACurrentMediaTime), which kept ticking through a pause and made the world look
    // alive while the player expected it stopped. The world_clock / sun is already held by
    // ticking the engine with dt = 0 while paused (see worldPaused below).
    private var animClock: CFTimeInterval = 0
    private var frameCounter = 0
    private weak var gameView: GameView?
    weak var hud: HUDView?
    weak var audio: GameAudio?
    private var lastUnderwater = false

    // #109 chest moves requested by HUD clicks this frame, applied at the top of the
    // next draw against the currently open chest. Each is (take: true => chest->inv from
    // chest slot N; false => inv->chest from inventory slot N). Drained per frame. The
    // engine resolves the position from its own open-chest state, so we only pass slots.
    private var pendingChestMoves: [(take: Bool, slot: Int)] = []
    private var openChestPos: bf_ivec3?
    func enqueueChestTake(_ slot: Int) { pendingChestMoves.append((true, slot)) }
    func enqueueChestDeposit(_ slot: Int) { pendingChestMoves.append((false, slot)) }
    // ESC from GameView closes the engine's open chest; the next poll clears the panel.
    func closeChest() { if let e = engine { bf_chest_close(e) } }

    // ---- #135 first-load readiness signal -----------------------------------
    // The app shows a loading overlay from launch and hides it once the spawn
    // neighbourhood has actually meshed + uploaded and the framerate has settled.
    // We detect that from state we already have per frame: the resident chunk
    // draw count (frame.draw_count, i.e. spawn-area meshes uploaded) crossing a
    // threshold AND a short run of consecutive healthy frame times. We prefer
    // the mesh-count signal over a pure timer because a timer alone is fragile.
    // isWorldReady latches true once and onReady fires exactly once.
    private(set) var isWorldReady = false
    var onReady: (() -> Void)?
    // Called each loading frame with the live progress fraction so the overlay can
    // animate a bar. Cleared by the app once the overlay is gone.
    var onLoadProgress: (() -> Void)?
    // The first-load stutter is the spawn chunks meshing/uploading; once this
    // many chunk draws are resident the spawn neighbourhood is on the GPU.
    private let kReadyChunkDraws = 24
    // ...and the frame loop must have settled: this many back-to-back frames
    // under the healthy-frame budget (the 1-2 fps load frames blow way past it).
    private let kReadyHealthyFrames = 6
    private let kHealthyFrameSecs: CFTimeInterval = 1.0 / 40.0   // <=25ms = settled
    private var healthyFrameRun = 0
    // Progress fraction (0..1) for a bar: resident chunk draws / threshold.
    private(set) var loadProgress: Float = 0

    private let saveDir: String
    private let freshWorld: Bool       // true = start a brand-new world (ignore any save)
    private let worldSeed: UInt64

    // ---- HDR offscreen textures (rebuilt on resize) --------------------------
    private var hdrColor: MTLTexture?     // rgba16Float  — scene rendered here
    private var hdrDepth: MTLTexture?     // depth32Float — shared by shadow + scene
    // Bloom intermediates (half scene size)
    private var bloomBright: MTLTexture?  // rgba16Float half-res bright pass
    private var bloomBlurA:  MTLTexture?  // rgba16Float blur ping
    private var bloomBlurB:  MTLTexture?  // rgba16Float blur pong
    private var currentDrawableSize: CGSize = .zero
    // Capped internal render size (the long edge is limited to kRenderLongEdge).
    // The final composite upscales to the full drawable; only the HDR/scene/bloom
    // textures are at this reduced size — saves ~4× fragment cost on Retina.
    // Lowered to 1280 now that MetalFX spatial upscaling recovers quality.
    private let kRenderLongEdge: CGFloat = 1280
    private var sceneSize: CGSize = .zero   // actual HDR texture size (≤ drawable)

    // ---- MetalFX spatial upscaler (optional — macOS 13+, Apple GPU) ---------
    // compositeLowRes: ACES composite writes here at sceneSize (LDR bgra8Unorm).
    // spatialScaler:   upscales compositeLowRes → full drawable texture.
    // If MetalFX is unavailable the composite writes straight to the drawable (bilinear fallback).
    private var compositeLowRes: MTLTexture?
#if canImport(MetalFX)
    @available(macOS 13.0, *)
    private var _spatialScaler: MTLFXSpatialScaler?
#endif
    // True when the scaler was successfully created and can be used this frame.
    private var metalFXEnabled: Bool = false

    // ---- World-space voxel sun shadows --------------------------------------
    // Shadows are a property of the WORLD: a point is in shadow iff a solid voxel
    // sits between it and the sun. The engine exports a compact occupancy grid
    // (bf_world_shadow_volume) for the resident region around the player; the
    // renderer uploads it to a 3D texture and DDA-marches each fragment toward the
    // sun. No shadow map, no cascades, no coverage ring, no crawl, no camera
    // dependence whatsoever.
    //
    // THE PRIMARY QUALITY/PERF KNOB: the march distance (world units). A fragment is sun-lit
    // if no casting voxel is hit within this distance toward the sun. The per-fragment march
    // is THE cost (the spec flagged this), and it scales with this distance: on the dev box
    // (RD24 stress) ~20 holds the median comfortably above 60 while still covering the contact
    // shadows players actually notice (under trees, beside structures, terraces). Larger gives
    // longer grazing shadows but costs more; smaller is cheaper. BF_MARCH_DIST overrides it.
    // M1 AIR NOTE: drop this to ~12-16 on the Air; raise toward 48+ only on a strong GPU.
    static let kShadowMarchDist: Float = {
        if let s = ProcessInfo.processInfo.environment["BF_MARCH_DIST"], let v = Float(s) {
            return max(8, min(256, v))
        }
        return 20.0
    }()
    // Coverage radius used only to fade the god-ray contribution near the grid edge.
    private let kShadowFarR:  Float = 384
    // #119 THE GOD-RAY TUNING KNOB. Overall strength of the volumetric light shafts at
    // full daylight; daylight + the toggle scale it down further (0 = off). Raise for
    // more dramatic beams, lower (or toggle God Rays off in graphics settings) on a weak
    // GPU like the M1 Air. The raymarch only runs when this resolves > 0.
    // #136 this is the 100%-slider CEILING. The pause-menu God Rays intensity slider scales
    // it by gfxGodRayStr (0..1), which DEFAULTS to 0.5 — so the shipped look is half this,
    // Halved again after playtest (the 1.5 ceiling still read too strong even at the 0.5 default).
    // Ceiling 1.5 with the 0.5 default gives ~0.75 effective; slider at 100% = 1.5 (the prior default).
    static let kGodRayStrength: Float = 1.5
    // #132 LENS-FLARE GATE KNOBS (CPU side; shader has its own element knobs FLARE_*).
    //   kFlareEdgeFade : how far (in centre-distance, 0=centre ~1.4=corner) the flare keeps
    //                    fading to zero. Larger = the flare reaches further toward the edges.
    static let kFlareEdgeFade: Float = 1.25

    // World occupancy 3D texture (r8uint, 1 = casting voxel) + the persistent CPU
    // buffer the engine fills, and the region metadata for the current upload.
    private var shadowVolTex: MTLTexture?
    // Coarse 1/CO occupancy mip (1 = ANY casting voxel in the CO^3 block) for empty-space
    // skipping: open-air rays step CO blocks at a time instead of one voxel, the big perf win.
    private var shadowVolCoarseTex: MTLTexture?
    private var shadowVolBuf: [UInt8] = []
    private var shadowVolCoarseBuf: [UInt8] = []
    private var shadowVolOrigin: SIMD3<Float> = .zero
    private var shadowVolDims: SIMD3<Float> = .zero
    private var shadowVolRevision: UInt32 = .max   // last uploaded revision (forces first upload)
    private var shadowVolTexDims: (Int, Int, Int) = (0, 0, 0)
    static let kShadowCoarse = 4   // coarse cell size (voxels per axis)

    // ---- No-write depth state (sky + bloom quads) ----------------------------
    private var noDepthState: MTLDepthStencilState!

    // ---- In-game screenshot (backslash key) ---------------------------------
    // A shared-storage bgra8 texture the screenshot path composites the final
    // scene into so the CPU can read it back (the swapchain drawable is
    // framebufferOnly and cannot be getBytes'd). Lazily sized to the drawable.
    // The HUD (a separate AppKit NSView) is composited on top on the CPU, so the
    // saved PNG matches exactly what the player sees, overlay included.
    private var screenshotReadback: MTLTexture?

    init(view: MTKView, device: MTLDevice, saveDir: String, audio: GameAudio?,
         fresh: Bool = false, seed: UInt64 = 0) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.registry = BufferRegistry(device: device)
        self.gameView = view as? GameView
        self.saveDir = saveDir
        self.freshWorld = fresh
        self.worldSeed = seed
        self.audio = audio
        super.init()
        view.depthStencilPixelFormat = .depth32Float
#if canImport(MetalFX)
        if #available(macOS 13.0, *) {
            // MTLFXSpatialScaler writes to the drawable via a compute kernel that
            // requires MTLTextureUsageShaderWrite. MTKView's default framebufferOnly=true
            // restricts drawable textures to renderTarget-only usage, blocking the
            // compute write. Clearing framebufferOnly allows both. On Apple Silicon
            // UMA there is no meaningful performance cost for doing this.
            if MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                view.framebufferOnly = false
            }
        }
#endif
        buildPipeline(colorFormat: view.colorPixelFormat)
        // World occupancy 3D texture is created lazily on the first uploadShadowVolume()
        // (its dims come from the engine), so there is no shadow-map allocation here.
        entityRenderer = EntityRenderer(device: device, colorFormat: .rgba16Float)
        particles = ParticleSystem(device: device, colorFormat: .rgba16Float)
        createEngine()
    }

    // MARK: Pipeline build

    private func buildPipeline(colorFormat: MTLPixelFormat) {
        let src = Renderer.shaderSource
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: src, options: nil) }
        catch { fatalError("shader compile failed: \(error)") }

        // ---- Terrain pipeline (renders into rgba16Float HDR target) ----------
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        desc.depthAttachmentPixelFormat = .depth32Float
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { fatalError("terrain pipeline failed: \(error)") }

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)

        // ---- Sky pipeline (HDR target, no depth write) -----------------------
        let sdesc = MTLRenderPipelineDescriptor()
        sdesc.vertexFunction   = lib.makeFunction(name: "skyVmain")
        sdesc.fragmentFunction = lib.makeFunction(name: "skyFmain")
        sdesc.colorAttachments[0].pixelFormat = .rgba16Float
        sdesc.depthAttachmentPixelFormat = .depth32Float
        do { skyPipeline = try device.makeRenderPipelineState(descriptor: sdesc) }
        catch { fatalError("sky pipeline failed: \(error)") }

        let sdd = MTLDepthStencilDescriptor()
        sdd.depthCompareFunction = .always
        sdd.isDepthWriteEnabled  = false
        skyDepthState = device.makeDepthStencilState(descriptor: sdd)

        // ---- No-depth state (used by bloom quads too) ------------------------
        let ndd = MTLDepthStencilDescriptor()
        ndd.depthCompareFunction = .always
        ndd.isDepthWriteEnabled  = false
        noDepthState = device.makeDepthStencilState(descriptor: ndd)

        // ---- Underwater post-pass pipeline (HDR target, alpha blend) ---------
        let udesc = MTLRenderPipelineDescriptor()
        udesc.vertexFunction   = lib.makeFunction(name: "underwaterVmain")
        udesc.fragmentFunction = lib.makeFunction(name: "underwaterFmain")
        udesc.colorAttachments[0].pixelFormat = .rgba16Float
        udesc.colorAttachments[0].isBlendingEnabled = true
        udesc.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        udesc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        udesc.colorAttachments[0].sourceAlphaBlendFactor      = .one
        udesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
        udesc.depthAttachmentPixelFormat = .depth32Float
        do { underwaterPipeline = try device.makeRenderPipelineState(descriptor: udesc) }
        catch { fatalError("underwater pipeline failed: \(error)") }

        // ---- Water translucency pipeline (alpha blend, depth test, NO depth write) ----
        // Re-draws chunk meshes; fragment discards any fragment whose material != 9 (water).
        // Depth test lessEqual so water surfaces at the right depth blend over the lake bottom.
        let wdesc = MTLRenderPipelineDescriptor()
        wdesc.vertexFunction   = lib.makeFunction(name: "vmain")
        wdesc.fragmentFunction = lib.makeFunction(name: "waterFmain")
        wdesc.colorAttachments[0].pixelFormat = .rgba16Float
        wdesc.colorAttachments[0].isBlendingEnabled = true
        wdesc.colorAttachments[0].sourceRGBBlendFactor        = .sourceAlpha
        wdesc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        wdesc.colorAttachments[0].sourceAlphaBlendFactor      = .one
        wdesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
        wdesc.depthAttachmentPixelFormat = .depth32Float
        do { waterPipeline = try device.makeRenderPipelineState(descriptor: wdesc) }
        catch { fatalError("water pipeline failed: \(error)") }

        let wdd = MTLDepthStencilDescriptor()
        wdd.depthCompareFunction = .lessEqual
        wdd.isDepthWriteEnabled  = false   // don't write depth — lake bottom must stay visible
        waterDepthState = device.makeDepthStencilState(descriptor: wdd)

        // World-space voxel sun shadows: no shadow-map render pass, so there is no
        // depth-only shadow pipeline. Shadows are marched per-fragment against the
        // engine occupancy 3D texture (see uploadShadowVolume / fmain).

        // ---- Bloom bright-pass (HDR → half-res rgba16Float) ------------------
        let bpd = MTLRenderPipelineDescriptor()
        bpd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bpd.fragmentFunction = lib.makeFunction(name: "bloomBrightFrag")
        bpd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBrightPipeline = try device.makeRenderPipelineState(descriptor: bpd) }
        catch { fatalError("bloom bright pipeline failed: \(error)") }

        // ---- Bloom blur H -------------------------------------------------------
        let bhd = MTLRenderPipelineDescriptor()
        bhd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bhd.fragmentFunction = lib.makeFunction(name: "bloomBlurHFrag")
        bhd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBlurHPipeline = try device.makeRenderPipelineState(descriptor: bhd) }
        catch { fatalError("bloom blurH pipeline failed: \(error)") }

        // ---- Bloom blur V -------------------------------------------------------
        let bvd = MTLRenderPipelineDescriptor()
        bvd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        bvd.fragmentFunction = lib.makeFunction(name: "bloomBlurVFrag")
        bvd.colorAttachments[0].pixelFormat = .rgba16Float
        do { bloomBlurVPipeline = try device.makeRenderPipelineState(descriptor: bvd) }
        catch { fatalError("bloom blurV pipeline failed: \(error)") }

        // ---- Composite / tonemap (rgba16Float HDR + bloom → drawable bgra8) ---
        let cpd = MTLRenderPipelineDescriptor()
        cpd.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
        cpd.fragmentFunction = lib.makeFunction(name: "compositeFrag")
        cpd.colorAttachments[0].pixelFormat = colorFormat   // drawable bgra8
        do { compositePipeline = try device.makeRenderPipelineState(descriptor: cpd) }
        catch { fatalError("composite pipeline failed: \(error)") }

        // ---- Ambient life (birds / fireflies): additive blended point sprites --
        let ald = MTLRenderPipelineDescriptor()
        ald.vertexFunction   = lib.makeFunction(name: "ambientLifeVert")
        ald.fragmentFunction = lib.makeFunction(name: "ambientLifeFrag")
        ald.colorAttachments[0].pixelFormat = .rgba16Float
        ald.colorAttachments[0].isBlendingEnabled             = true
        ald.colorAttachments[0].sourceRGBBlendFactor          = .one
        ald.colorAttachments[0].destinationRGBBlendFactor     = .one   // additive
        ald.colorAttachments[0].sourceAlphaBlendFactor        = .one
        ald.colorAttachments[0].destinationAlphaBlendFactor   = .zero
        ald.depthAttachmentPixelFormat = .depth32Float
        do { ambientLifePipeline = try device.makeRenderPipelineState(descriptor: ald) }
        catch { fatalError("ambient life pipeline failed: \(error)") }

        // ---- Sub-voxel props (#51/#52): GPU-instanced toy models ----------------
        let propd = MTLRenderPipelineDescriptor()
        propd.vertexFunction   = lib.makeFunction(name: "propInstVmain")
        propd.fragmentFunction = lib.makeFunction(name: "propFmain")
        propd.colorAttachments[0].pixelFormat = .rgba16Float
        propd.depthAttachmentPixelFormat = .depth32Float
        do { propPipeline = try device.makeRenderPipelineState(descriptor: propd) }
        catch { fatalError("prop pipeline failed: \(error)") }

        // Props no longer need a depth-only shadow pipeline: prop blocks live in the
        // engine occupancy grid (the engine stamps their casting voxels), so they cast
        // world-space shadows without any extra render pass here.

        propModelTable = Renderer.makePropModelTable(device: device)

        // ---- First-person viewmodel (#70): view-space arm, always on top ---------
        let vmd = MTLRenderPipelineDescriptor()
        vmd.vertexFunction   = lib.makeFunction(name: "viewModelVmain")
        vmd.fragmentFunction = lib.makeFunction(name: "viewModelFmain")
        vmd.colorAttachments[0].pixelFormat = .rgba16Float
        vmd.depthAttachmentPixelFormat = .depth32Float
        do { viewModelPipeline = try device.makeRenderPipelineState(descriptor: vmd) }
        catch { fatalError("viewmodel pipeline failed: \(error)") }
        let vmdd = MTLDepthStencilDescriptor()
        vmdd.depthCompareFunction = .always   // draw over the scene; parts ordered back-to-front
        vmdd.isDepthWriteEnabled  = false
        viewModelDepthState = device.makeDepthStencilState(descriptor: vmdd)
        let ap0 = CharacterAppearance.load()                 // #71 own arm reflects your skin/shirt
        charSkin = ap0.skinRGB; charShirt = ap0.shirtRGB
        let arm = makeViewModelArm(skin: charSkin, sleeve: charShirt)
        viewModelArmCount = arm.count
        viewModelArmBuf = device.makeBuffer(bytes: arm, length: arm.count * MemoryLayout<PropCuboidGPU>.stride,
                                            options: .storageModeShared)

        // Birds: no depth test (sky sprites). Fireflies: less-equal depth test.
        // We handle both in one pipeline; fireflies use depth, birds skip via discard logic.
        let aldd = MTLDepthStencilDescriptor()
        aldd.depthCompareFunction = .lessEqual
        aldd.isDepthWriteEnabled  = false   // additive sprites never write depth
        ambientLifeDepthState = device.makeDepthStencilState(descriptor: aldd)

        // Allocate the CPU-writable sprite buffer (updated every frame)
        ambientLifeBuffer = device.makeBuffer(
            length: kMaxAmbientSprites * MemoryLayout<AmbientSpritePod>.stride,
            options: .storageModeShared)!

        // ---- World-space precipitation pipeline (alpha-blended billboards) -----
        // Rain = thin vertical streaks; snow = small soft flakes. Standard
        // src-alpha / one-minus-src-alpha blend over the scene; depth-tested so
        // particles behind terrain are hidden, but no depth write.
        let ppd = MTLRenderPipelineDescriptor()
        ppd.vertexFunction   = lib.makeFunction(name: "precipVert")
        ppd.fragmentFunction = lib.makeFunction(name: "precipFrag")
        ppd.colorAttachments[0].pixelFormat = .rgba16Float
        ppd.colorAttachments[0].isBlendingEnabled             = true
        ppd.colorAttachments[0].sourceRGBBlendFactor          = .sourceAlpha
        ppd.colorAttachments[0].destinationRGBBlendFactor     = .oneMinusSourceAlpha
        ppd.colorAttachments[0].sourceAlphaBlendFactor        = .one
        ppd.colorAttachments[0].destinationAlphaBlendFactor   = .zero
        ppd.depthAttachmentPixelFormat = .depth32Float
        do { precipPipeline = try device.makeRenderPipelineState(descriptor: ppd) }
        catch { fatalError("precip pipeline failed: \(error)") }

        let ppdd = MTLDepthStencilDescriptor()
        ppdd.depthCompareFunction = .lessEqual
        ppdd.isDepthWriteEnabled  = false   // precipitation never writes depth
        precipDepthState = device.makeDepthStencilState(descriptor: ppdd)

        // Fill the precipitation particle buffer ONCE: each particle gets a stable
        // pseudo-random offset within the unit box [-0.5..0.5]^3 plus a fall phase.
        // The vertex shader animates the world position from these each frame, so no
        // per-frame CPU work and the particles recycle (wrap) entirely on the GPU.
        precipBuffer = device.makeBuffer(
            length: kPrecipCount * MemoryLayout<PrecipParticlePod>.stride,
            options: .storageModeShared)!
        let pptr = precipBuffer.contents().bindMemory(to: PrecipParticlePod.self, capacity: kPrecipCount)
        func h(_ n: UInt32) -> Float {   // cheap deterministic hash → [0,1)
            var v = n &* 0x9E3779B1
            v ^= v >> 16; v = v &* 0x85EBCA6B
            v ^= v >> 13; v = v &* 0xC2B2AE35
            v ^= v >> 16
            return Float(v) / Float(UInt32.max)
        }
        for i in 0..<kPrecipCount {
            let n = UInt32(i)
            pptr[i] = PrecipParticlePod(seed: SIMD4<Float>(
                h(n &* 3 &+ 1) - 0.5,         // x offset in [-0.5, 0.5]
                h(n &* 7 &+ 13) - 0.5,        // y offset in [-0.5, 0.5]
                h(n &* 11 &+ 101) - 0.5,      // z offset in [-0.5, 0.5]
                h(n &* 17 &+ 271)))           // phase 0..1
        }
    }

    // Upload the engine's world occupancy grid into the 3D shadow texture. Pulls
    // bf_world_shadow_volume into a persistent CPU buffer, (re)creates the r8uint
    // 3D texture if the grid dims changed, and re-uploads the bytes only when the
    // engine bumped the revision (so a stationary scene costs one cheap call). The
    // texture + region metadata are then bound by the terrain / water / composite
    // passes. Returns true if a usable occupancy texture is ready.
    @discardableResult
    private func uploadShadowVolume(_ e: bf_engine) -> Bool {
        // Probe call (nil buffer): cheap, returns dims + revision + dirty box, NO 4 MB copy.
        var vol = bf_shadow_volume()
        vol.voxels = nil
        vol.voxel_cap = 0
        _ = bf_world_shadow_volume(e, &vol)
        let dx = Int(vol.dim_x), dy = Int(vol.dim_y), dz = Int(vol.dim_z)
        let need = dx * dy * dz
        if need <= 0 { return false }
        let dimsKnownSame = (shadowVolTex != nil && shadowVolTexDims == (dx, dy, dz))
        // Standing still / nothing changed: textures are current, skip the fill + upload.
        if dimsKnownSame && vol.revision == shadowVolRevision { return true }

        if shadowVolBuf.count < need { shadowVolBuf = [UInt8](repeating: 0, count: need) }
        // Fill call: the engine copies the toroidal buffer into our persistent storage.
        let ok: Bool = shadowVolBuf.withUnsafeMutableBufferPointer { p -> Bool in
            vol.voxels = p.baseAddress
            vol.voxel_cap = UInt32(p.count)
            return bf_world_shadow_volume(e, &vol) == BF_OK
        }
        if !ok { return false }

        shadowVolOrigin = SIMD3<Float>(Float(vol.origin.x), Float(vol.origin.y), Float(vol.origin.z))
        shadowVolDims   = SIMD3<Float>(Float(dx), Float(dy), Float(dz))

        // (Re)create the toroidal 3D textures when the dims change (rare).
        let CO = Renderer.kShadowCoarse
        let cdx = (dx + CO - 1) / CO, cdy = (dy + CO - 1) / CO, cdz = (dz + CO - 1) / CO
        if shadowVolTex == nil || shadowVolTexDims != (dx, dy, dz) {
            func make3D(_ w: Int, _ h: Int, _ d: Int) -> MTLTexture? {
                let td = MTLTextureDescriptor()
                td.textureType = .type3D; td.pixelFormat = .r8Uint
                td.width = w; td.height = h; td.depth = d
                td.usage = [.shaderRead]; td.storageMode = .shared
                return device.makeTexture(descriptor: td)
            }
            shadowVolTex = make3D(dx, dy, dz)
            shadowVolCoarseTex = make3D(cdx, cdy, cdz)
            shadowVolTexDims = (dx, dy, dz)
            shadowVolRevision = .max   // force a full upload into the new textures
        }
        guard let tex = shadowVolTex, let ctex = shadowVolCoarseTex else { return false }
        if shadowVolCoarseBuf.count < cdx * cdy * cdz {
            shadowVolCoarseBuf = [UInt8](repeating: 0, count: cdx * cdy * cdz)
        }

        // Nothing changed since our last upload: keep the textures, skip the GPU work.
        if vol.revision == shadowVolRevision { return true }

        // Collect the dirty boxes the engine reported (a list, to avoid one giant L-shaped
        // bounding box on a diagonal scroll). On the first upload into fresh textures, force
        // the full window.
        let oy = Int(vol.origin.y)
        let boxes = Renderer.shadowDirtyBoxes(vol, dx: dx, dy: dy, dz: dz,
                                              forceFull: shadowVolRevision == .max)
        for (wlo, whi) in boxes {
            // Rebuild the coarse mip for ONLY this box, then upload only this box.
            buildCoarseRegion(fine: shadowVolBuf, coarse: &shadowVolCoarseBuf,
                              dx: dx, dy: dy, dz: dz, cdx: cdx, cdy: cdy, cdz: cdz, co: CO,
                              originY: oy, wlo: wlo, whi: whi)
            uploadToroidalRegion(tex, ctex, buf: shadowVolBuf, coarseBuf: shadowVolCoarseBuf,
                                 dx: dx, dy: dy, dz: dz, cdx: cdx, cdy: cdy, cdz: cdz, co: CO,
                                 wlo: wlo, whi: whi)
        }
        shadowVolRevision = vol.revision
        return true
    }

    // Decode the engine's dirty-box list (a C fixed array, imported as a Swift tuple) into
    // clamped world-voxel AABBs. forceFull (first upload into fresh textures) returns the
    // whole window regardless of what the engine reported.
    static func shadowDirtyBoxes(_ vol: bf_shadow_volume, dx: Int, dy: Int, dz: Int,
                                 forceFull: Bool) -> [(SIMD3<Int>, SIMD3<Int>)] {
        let ox = Int(vol.origin.x), oy = Int(vol.origin.y), oz = Int(vol.origin.z)
        if forceFull {
            return [(SIMD3<Int>(ox, oy, oz), SIMD3<Int>(ox + dx - 1, oy + dy - 1, oz + dz - 1))]
        }
        var los = vol.dirty_lo, his = vol.dirty_hi
        let nlo = withUnsafeBytes(of: &los) { $0.bindMemory(to: bf_ivec3.self) }
        let nhi = withUnsafeBytes(of: &his) { $0.bindMemory(to: bf_ivec3.self) }
        var out: [(SIMD3<Int>, SIMD3<Int>)] = []
        let n = min(Int(vol.dirty_count), nlo.count)
        for i in 0..<n {
            let lo = SIMD3<Int>(max(Int(nlo[i].x), ox), max(Int(nlo[i].y), oy), max(Int(nlo[i].z), oz))
            let hi = SIMD3<Int>(min(Int(nhi[i].x), ox + dx - 1),
                                min(Int(nhi[i].y), oy + dy - 1),
                                min(Int(nhi[i].z), oz + dz - 1))
            if hi.x >= lo.x && hi.y >= lo.y && hi.z >= lo.z { out.append((lo, hi)) }
        }
        return out
    }

    // Upload a world-voxel AABB [wlo, whi] into the toroidal fine + coarse textures, splitting
    // the box at the wrap seam on x and z (y does not wrap). The buffers are the full toroidal
    // arrays; we copy each wrapped sub-rect with MTLTexture.replace on just that region.
    private func uploadToroidalRegion(_ tex: MTLTexture, _ ctex: MTLTexture,
                                      buf: [UInt8], coarseBuf: [UInt8],
                                      dx: Int, dy: Int, dz: Int,
                                      cdx: Int, cdy: Int, cdz: Int, co: Int,
                                      wlo: SIMD3<Int>, whi: SIMD3<Int>) {
        func wrap(_ v: Int, _ d: Int) -> Int { let m = v % d; return m < 0 ? m + d : m }
        // Build the up-to-2 contiguous cell spans for an axis range [lo,hi] of length n<=dim.
        func spans(_ lo: Int, _ hi: Int, _ dim: Int) -> [(g0: Int, len: Int)] {
            let n = hi - lo + 1
            if n >= dim { return [(0, dim)] }
            let g0 = wrap(lo, dim)
            if g0 + n <= dim { return [(g0, n)] }
            return [(g0, dim - g0), (0, n - (dim - g0))]   // wraps: tail + head
        }
        let xs = spans(wlo.x, whi.x, dx)
        let zs = spans(wlo.z, whi.z, dz)
        let gy0 = wlo.y - Int(shadowVolOrigin.y)          // y does not wrap
        let yh  = whi.y - wlo.y + 1
        // Fine grid: for each (x-span, z-span) rect, replace that sub-volume from the buffer.
        buf.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for zsp in zs {
                for xsp in xs {
                    let region = MTLRegionMake3D(xsp.g0, gy0, zsp.g0, xsp.len, yh, zsp.len)
                    // Source pointer to the buffer cell (xsp.g0, gy0, zsp.g0); the buffer is
                    // contiguous with bytesPerRow=dx, bytesPerImage=dx*dy, so a sub-rect upload
                    // reads strided directly from it.
                    let off = (zsp.g0 * dy + gy0) * dx + xsp.g0
                    tex.replace(region: region, mipmapLevel: 0, slice: 0,
                                withBytes: base + off, bytesPerRow: dx, bytesPerImage: dx * dy)
                }
            }
        }
        // Coarse grid: the same AABB mapped to coarse cells (floor on lo, ceil on hi).
        let cxs = spans(Int(floor(Double(wlo.x) / Double(co))), Int(floor(Double(whi.x) / Double(co))), cdx)
        let czs = spans(Int(floor(Double(wlo.z) / Double(co))), Int(floor(Double(whi.z) / Double(co))), cdz)
        let cgy0 = (gy0) / co
        let cyh  = (gy0 + yh + co - 1) / co - cgy0
        coarseBuf.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for zsp in czs {
                for xsp in cxs {
                    let region = MTLRegionMake3D(xsp.g0, cgy0, zsp.g0, xsp.len, cyh, zsp.len)
                    let off = (zsp.g0 * cdy + cgy0) * cdx + xsp.g0
                    ctex.replace(region: region, mipmapLevel: 0, slice: 0,
                                 withBytes: base + off, bytesPerRow: cdx, bytesPerImage: cdx * cdy)
                }
            }
        }
    }

    // ---- Resize: rebuild HDR + bloom textures when drawable size changes -----
    // The HDR scene is rendered at a capped internal resolution so the long edge
    // never exceeds kRenderLongEdge pixels (e.g. 1280 on a 5K Retina display).
    // The ACES composite writes to compositeLowRes (bgra8Unorm at sceneSize), then
    // an MTLFXSpatialScaler upscales it to the full drawable with much higher quality
    // than bilinear. Falls back to bilinear if MetalFX is unavailable.
    private func rebuildHDRTextures(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }

        // Compute capped scene size: scale down if the long edge exceeds the cap.
        let longEdge = max(size.width, size.height)
        let scale = longEdge > kRenderLongEdge ? kRenderLongEdge / longEdge : 1.0
        let SW = max(1, Int((size.width  * scale).rounded()))
        let SH = max(1, Int((size.height * scale).rounded()))
        sceneSize = CGSize(width: SW, height: SH)

        let HW = max(1, SW / 2), HH = max(1, SH / 2)
        let DW = max(1, Int(size.width.rounded()))
        let DH = max(1, Int(size.height.rounded()))

        func make2D(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            td.usage = usage; td.storageMode = .private
            return device.makeTexture(descriptor: td)!
        }

        hdrColor    = make2D(.rgba16Float,  SW,  SH, usage: [.renderTarget, .shaderRead])
        // #119 god rays: the composite volumetric pass raymarches from the camera to the
        // scene depth, so the depth buffer must be readable (shaderRead) and survive the
        // scene pass (store, set on the depth attachment below). Was render-target-only.
        hdrDepth    = make2D(.depth32Float, SW,  SH, usage: [.renderTarget, .shaderRead])
        bloomBright = make2D(.rgba16Float, HW,  HH, usage: [.renderTarget, .shaderRead])
        bloomBlurA  = make2D(.rgba16Float, HW,  HH, usage: [.renderTarget, .shaderRead])
        bloomBlurB  = make2D(.rgba16Float, HW,  HH, usage: [.renderTarget, .shaderRead])
        currentDrawableSize = size

        // ---- MetalFX spatial upscaler setup ---------------------------------
        // compositeLowRes is the ACES composite output at sceneSize (LDR bgra8Unorm).
        // MetalFX requires its input texture to have .shaderRead + .renderTarget usage.
        // The scaler then writes to the full-resolution drawable texture.
        metalFXEnabled = false
        compositeLowRes = nil
#if canImport(MetalFX)
        if #available(macOS 13.0, *) {
            // Only build the scaler when the scene is actually smaller than the drawable
            // (if already 1:1 the spatial scaler would be a no-op but still costs memory).
            let needsUpscale = SW < DW || SH < DH
            if needsUpscale && MTLFXSpatialScalerDescriptor.supportsDevice(device) {
                let scalerDesc = MTLFXSpatialScalerDescriptor()
                scalerDesc.inputWidth           = SW
                scalerDesc.inputHeight          = SH
                scalerDesc.outputWidth          = DW
                scalerDesc.outputHeight         = DH
                // bgra8Unorm: the ACES composite already produces a tone-mapped LDR image,
                // so we use .perceptual colour processing (designed for LDR gamma-correct input).
                scalerDesc.colorTextureFormat   = .bgra8Unorm
                scalerDesc.outputTextureFormat  = .bgra8Unorm
                scalerDesc.colorProcessingMode  = .perceptual

                if let scaler = scalerDesc.makeSpatialScaler(device: device) {
                    _spatialScaler = scaler
                    // compositeLowRes: MetalFX input — needs .shaderRead for the scaler to read it.
                    let td = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: SW, height: SH, mipmapped: false)
                    td.usage        = [.renderTarget, .shaderRead]
                    td.storageMode  = .private
                    compositeLowRes = device.makeTexture(descriptor: td)
                    if compositeLowRes != nil {
                        metalFXEnabled = true
                    }
                }
            }
        }
#endif
    }

    // MARK: Engine create

    private func createEngine() {
        var cfg = bf_engine_config()
        cfg.abi_version = BF_ABI_VERSION
        cfg.role = BF_ROLE_SINGLEPLAYER
        cfg.start_mode = BF_MODE_SURVIVAL
        // #85 streaming radius (chunks), persisted + adjustable via the pause-menu slider.
        let rd = UserDefaults.standard.object(forKey: "gfxRenderDist") as? Int ?? 24
        cfg.render_distance_chunks = UInt32(max(8, min(40, rd)))
        cfg.memory_budget_bytes = 10 * 1024 * 1024 * 1024
        // Content is bundled at Resources/content (build.sh copies it there).
        // The registry loads <dir>/blocks, <dir>/items, … so point at that folder,
        // not Resources itself — otherwise NO blocks/items/recipes load and there
        // are no drops, starter items, or recipes.
        let resDir = Bundle.main.resourcePath ?? "."
        let contentDir = FileManager.default.fileExists(atPath: resDir + "/content/blocks")
            ? resDir + "/content" : resDir
        cfg.content_dir = persistentCString(contentDir)
        cfg.save_dir = persistentCString(saveDir)
        cfg.player_name = persistentCString("kid")
        var err = BF_OK
        engine = bf_engine_create(&cfg, &err)
        guard let e = engine, err == BF_OK else {
            fatalError("engine create failed: \(String(cString: bf_last_error_global()))")
        }
        var alloc = bf_gpu_allocator()
        alloc.user = Unmanaged.passUnretained(registry).toOpaque()
        alloc.alloc = allocTrampoline
        alloc.free_ = freeTrampoline
        _ = bf_set_gpu_allocator(e, &alloc)
        bf_set_event_callback(e, eventTrampoline, Unmanaged.passUnretained(self).toOpaque())
        // A brand-new world starts fresh (ignore any stale save in this folder);
        // an existing world loads its save.
        if freshWorld {
            _ = bf_world_new(e, worldSeed)
            _ = bf_world_save(e)          // write an initial save so the world persists immediately
        } else {
            _ = bf_world_load(e)
        }
    }

    private let discovery = NetDiscovery()
    private let coopPort: Int32 = 27355

    func startHost() {
        guard let e = engine else { return }
        _ = bf_net_host_start(e, UInt16(coopPort))
        discovery.publish(port: coopPort)
    }
    func joinLAN() {
        discovery.onHostFound = { [weak self] ip, port in
            DispatchQueue.main.async {
                guard let self = self, let e = self.engine else { return }
                ip.withCString { _ = bf_net_client_connect(e, $0, port) }
                NSLog("Blockfall: joining \(ip):\(port)")
            }
        }
        discovery.browse()
    }

    var onDialogue: ((Int) -> Void)?   // #82 villager dialogue hook (npc_id), wired by the app
    func handleEvent(_ ev: bf_event) {
        guard ev.kind == BF_EVT_SFX else { return }
        switch ev.i {
        case 0:                                    // packed: (blockId<<4 | soundClass)
            let packed = Int(ev.j)
            audio?.playBreak(materialClass: packed & 0xF)
            spawnBreakParticles(ev.pos, blockId: packed >> 4)
        case 1: audio?.play(.place)
        case 2: audio?.playStep(Int(ev.j))   // ev.j = terrain class (soft/hard/sand/snow/wood)
        case 3: audio?.play(.jump)
        case 4: audio?.play(.craft)
        case 5: audio?.play(.befriend)
        case 6: audio?.play(.questComplete)
        case 7: audio?.play(.pickup)
        case 8: audio?.play(.mine)         // melee hit on a creature
        case 9: audio?.play(.hurt)         // player took damage
        case 20: onDialogue?(Int(ev.j))    // #82 right-clicked a villager: open dialogue (npc_id = j)
        default: break
        }
    }

    func spawnBreakParticles(_ pos: bf_ivec3, blockId: Int = 0) { particles.spawn(at: pos, blockId: blockId) }

    func shutdown() {
        guard let e = engine else { return }
        engine = nil   // stop draw(in:) from touching the engine from here on
        // The frame loop only waitUntilScheduled()s before present, so the GPU may
        // still be reading chunk mesh buffers that bf_engine_destroy is about to
        // free. Fence on a fresh command buffer to ensure all submitted work has
        // completed before we free those buffers (prevents a GPU use-after-free
        // when quitting to the menu mid-frame).
        let fence = queue.makeCommandBuffer()
        fence?.commit(); fence?.waitUntilCompleted()
        _ = bf_world_save(e); bf_engine_destroy(e)
    }
    deinit { shutdown() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildHDRTextures(size: size)
    }

    // MARK: Draw

    func draw(in view: MTKView) {
        guard let e = engine,
              let drawable = view.currentDrawable else { return }

        let now = CACurrentMediaTime()
        let dt = now - lastTime; lastTime = now
        frameCounter += 1
        registry.currentFrame = frameCounter

        // Lazy texture init / resize check
        let dSize = view.drawableSize
        if currentDrawableSize != dSize { rebuildHDRTextures(size: dSize) }
        guard let hdrColor = hdrColor, let hdrDepth = hdrDepth,
              let bloomBright = bloomBright, let bloomBlurA = bloomBlurA,
              let bloomBlurB = bloomBlurB else { return }

        // 1) input -> engine
        var input = gameView?.makeFrameInput() ?? bf_frame_input()
        // #77 world pause: when you are alone and the pause menu is up, freeze the sim by
        // ticking with dt = 0 (creatures, day/night, physics all hold). In multiplayer
        // (any peer connected) never pause the shared world, so dt stays real.
        let worldPaused = (gameView?.worldIsPaused ?? false) && bf_net_peer_count(e) == 0
        _ = bf_frame_begin(e, &input, worldPaused ? 0.0 : dt)
        // #127 advance the cosmetic animation clock only while NOT paused, so grass sway,
        // creature/leaf wiggle, pollen, ambient sprites, and precipitation all freeze on
        // pause and resume from the same value on unpause (no jump). It tracks the same
        // dt = 0 hold the engine clock uses, so the render-side motion and the sun stop
        // together. Always advance when a peer is connected (multiplayer never pauses).
        if !worldPaused { animClock += dt }
        if let actions = gameView?.drainActions() {
            for var a in actions {
                // #: trigger a tool swing on mine/place/attack (continuous mining is
                // handled separately via mine_progress in the viewmodel draw).
                if a.kind == BF_ACT_MINE_START || a.kind == BF_ACT_PLACE
                   || a.kind == BF_ACT_ATTACK || a.kind == BF_ACT_INTERACT {
                    swingPulse = now
                }
                bf_input_action(e, &a)
            }
        }

        // #109 apply any chest moves requested by HUD clicks this frame. The engine
        // resolves the chest position from its own open-chest state (set by INTERACT);
        // we use the last polled position. Items are never destroyed: a full inventory
        // leaves the stack in the chest (engine-side). Done before acquire so the panel
        // reflects the change on the same frame.
        if !pendingChestMoves.isEmpty, let cpos = openChestPos {
            for mv in pendingChestMoves {
                if mv.take {
                    _ = bf_chest_take(e, cpos, UInt32(mv.slot))
                } else {
                    _ = bf_chest_deposit(e, cpos, UInt32(mv.slot))
                }
            }
        }
        pendingChestMoves.removeAll(keepingCapacity: true)

        // 2) acquire render
        var frame = bf_render_frame()
        _ = bf_frame_acquire_render(e, &frame)

        // Snapshot the buffer registry AFTER acquire: this frame's update/remesh
        // (inside frame_begin/acquire) may have allocated brand-new mesh buffers,
        // and the draw list references them. Snapshotting earlier missed those, so
        // a just-remeshed chunk wasn't drawn for a frame — flashing holes that let
        // you see the caves below, especially while chunks stream/light settles.
        let bufs = registry.snapshot()

        // #135 first-load readiness: while the spawn neighbourhood is meshing and
        // uploading the loop runs at 1-2 fps and few chunk draws are resident. Treat
        // the world as "ready to play" once enough chunk draws are on the GPU AND the
        // frame loop has held a healthy frame time for a short run. Latches once and
        // fires onReady so the app can lift the loading overlay. Costs a couple of
        // comparisons per frame and nothing after it latches.
        if !isWorldReady {
            let residentDraws = Int(frame.draw_count)
            loadProgress = min(1.0, Float(residentDraws) / Float(kReadyChunkDraws))
            if let cb = onLoadProgress { DispatchQueue.main.async { cb() } }
            // dt on the very first frame is ~0 (lastTime seeded at init); only count
            // real frames toward the healthy run.
            if dt > 0 && dt <= kHealthyFrameSecs && residentDraws >= kReadyChunkDraws {
                healthyFrameRun += 1
            } else {
                healthyFrameRun = 0
            }
            if healthyFrameRun >= kReadyHealthyFrames {
                isWorldReady = true
                loadProgress = 1.0
                NSLog("[Blockfall #135] world ready: %d chunk draws resident, %d healthy frames (frame %d) — hiding loading overlay",
                      residentDraws, healthyFrameRun, frameCounter)
                let cb = onReady
                DispatchQueue.main.async { cb?() }
            }
        }

        // 3) camera matrices
        let aspect = Float(dSize.width / max(1, dSize.height))
        let fovy: Float = 1.20
        let proj  = Renderer.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 512)
        let viewM = Renderer.mat(frame.camera.view)
        let viewProj = proj * viewM
        let sun = frame.camera.sun_dir

        // #127 cosmetic animation time. Was `now` (CACurrentMediaTime) which kept ticking
        // through a pause; now sourced from animClock, which only advances while unpaused, so
        // all wallClock-driven motion (sway / wiggle / pollen / sprites / precip) holds still
        // while paused and resumes without a jump. Wrapped to keep the float precise.
        let wallClock = Float(animClock.truncatingRemainder(dividingBy: 3600.0))
        let isUnderwater = frame.camera.underwater

        // Feed the HUD the player's world position + facing so it can show
        // coordinates. facing = heading angle (radians) from forward.x/forward.z.
        hud?.setPlayerInfo(x: frame.camera.position.x,
                           y: frame.camera.position.y,
                           z: frame.camera.position.z,
                           facing: atan2(frame.camera.forward.x, frame.camera.forward.z))

        // Feed the HUD the time of day for a day/night indicator (HUDView method
        // added by another agent; guarded so it's a no-op until then).
        hud?.setTimeOfDay(frame.camera.time_of_day)

        // #42: when the quest log overlay is open, fetch the FULL quest chain
        // from the engine and forward it to the HUD. Done only while open so the
        // closed-log path stays free of the extra ABI call. This is the only
        // Renderer touchpoint for the quest log — fetch + forward, nothing more.
        if let hud = hud, hud.isQuestLogOpen {
            let cap = 32
            var buf = [bf_quest_entry](repeating: bf_quest_entry(), count: cap)
            let total = Int(bf_quest_list(e, &buf, UInt32(cap)))
            let count = min(total, cap)
            var rows: [HUDView.QuestRow] = []
            rows.reserveCapacity(count)
            for i in 0..<count {
                let title = withUnsafeBytes(of: buf[i].title) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                let objective = withUnsafeBytes(of: buf[i].objective) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                rows.append(HUDView.QuestRow(title: title, objective: objective,
                                             state: buf[i].state, progress: buf[i].progress))
            }
            hud.setQuests(rows)
        }

        // Weather is now fully engine-owned: frame.camera.weather = 0=clear, 1=rain, 2=snow.
        // Map that to a rain strength for wind/wet-darkening (0 when clear or snow, 1 when rain).
        let engineWeather = Int(frame.camera.weather)   // 0, 1, or 2
        let rainStrength: Float = (engineWeather == 1) ? 1.0 : 0.0

        // Wind uniforms (index 3 on vertex shaders — new dedicated buffer)
        var windU = WindUniforms(wallClockSecs: wallClock, rainStrength: rainStrength,
                                 swayScale: gfxFoliage ? 1 : 0)   // #: foliage toggle

        // Camera basis for sky dome
        let camRight = SIMD3<Float>(viewM.columns.0.x, viewM.columns.1.x, viewM.columns.2.x)
        let camUp    = SIMD3<Float>(viewM.columns.0.y, viewM.columns.1.y, viewM.columns.2.y)
        let camFwd   = SIMD3<Float>(-viewM.columns.0.z, -viewM.columns.1.z, -viewM.columns.2.z)
        let tanHalfFov = tan(fovy * 0.5)

        let vt = viewM.columns.3
        let camPosW = SIMD4<Float>(
            -(viewM.columns.0.x * vt.x + viewM.columns.1.x * vt.y + viewM.columns.2.x * vt.z),
            -(viewM.columns.0.y * vt.x + viewM.columns.1.y * vt.y + viewM.columns.2.y * vt.z),
            -(viewM.columns.0.z * vt.x + viewM.columns.1.z * vt.y + viewM.columns.2.z * vt.z),
            0)

        // ---- #13: Multiplayer compass — find other connected players --------
        // Scan the render frame for remote-player entities (kind == 100) and,
        // for each, work out an on-screen marker point or an off-screen edge
        // arrow direction + distance + the peer's tint colour, then push the
        // list to the HUD which draws the compass. Pure read + forward; touches
        // no Metal pipeline / frame-lifecycle state. The HUD overlay is laid out
        // in the GameView's POINT space (it shares the MTKView frame), so we
        // project NDC into points using the view's bounds size, not the (Retina)
        // drawable pixel size.
        if let hud = hud {
            buildPeerCompass(hud: hud, frame: frame, viewProj: viewProj,
                             camPos: SIMD3<Float>(frame.camera.position.x,
                                                  frame.camera.position.y,
                                                  frame.camera.position.z),
                             camFwd: camFwd, camRight: camRight, camUp: camUp)
        }

        // 4) World-space voxel sun shadows: pull the engine occupancy grid into the
        //    3D shadow texture. Cheap when nothing changed (the engine only bumps the
        //    revision on a real change, and we re-upload only then). This REPLACES the
        //    old shadow-map cascade render pass entirely.
        let haveShadowVol = gfxShadows ? uploadShadowVolume(e) : false

        // Must release the acquired frame even on this early-out, or `borrowed`
        // sticks true and every later acquire returns the same frame forever.
        guard let cmd = queue.makeCommandBuffer() else { bf_frame_end(e); return }

        // PASS 1 (the camera-following shadow-map cascade render) is RETIRED. World-space
        // voxel shadows need no shadow geometry pass: the occupancy 3D texture was uploaded
        // above (uploadShadowVolume) and each fragment marches it toward the sun. Trees and
        // structures cast because their voxels live in the engine occupancy grid.

        // Per-fragment voxel-shadow uniform fields shared by terrain + water + composite.
        // voxOrigin.xyz = grid origin (world block coords), voxOrigin.w = march distance.
        // voxDims.xyz   = grid dims (voxels),               voxDims.w   = soft-shadow flag.
        // When the grid is not ready (haveShadowVol == false) the shadow toggle reads 0 so
        // fmain skips the march cleanly (fully lit).
        let voxOriginU = SIMD4<Float>(shadowVolOrigin.x, shadowVolOrigin.y, shadowVolOrigin.z,
                                      Renderer.kShadowMarchDist)
        let voxDimsU   = SIMD4<Float>(shadowVolDims.x, shadowVolDims.y, shadowVolDims.z,
                                      gfxSoftShadows ? 1 : 0)
        let shadowOn: Float = (gfxShadows && haveShadowVol) ? 1 : 0

        // Shadows are marched directly per fragment in the terrain pass (fmain) against the
        // occupancy 3D textures bound below. The march distance (voxOrigin.w) is THE perf knob.

        // =====================================================================
        // PASS 2: Main scene → HDR colour texture (rgba16Float)
        //   Sub-passes: sky, terrain, entities, particles, underwater
        // =====================================================================
        let sky = skyColor(frame.camera.time_of_day)
        let hdrRP = MTLRenderPassDescriptor()
        hdrRP.colorAttachments[0].texture     = hdrColor
        hdrRP.colorAttachments[0].loadAction  = .clear
        hdrRP.colorAttachments[0].storeAction = .store
        hdrRP.colorAttachments[0].clearColor  = MTLClearColor(red: sky.0, green: sky.1, blue: sky.2, alpha: 1)
        hdrRP.depthAttachment.texture         = hdrDepth
        hdrRP.depthAttachment.loadAction      = .clear
        // #119 god rays: keep the depth buffer so the composite volumetric pass can read it.
        hdrRP.depthAttachment.storeAction     = .store
        hdrRP.depthAttachment.clearDepth      = 1.0

        if let enc = cmd.makeRenderCommandEncoder(descriptor: hdrRP) {

            // --- Sky pass ---
            if skyPipeline != nil {
                enc.setRenderPipelineState(skyPipeline)
                enc.setDepthStencilState(skyDepthState)
                enc.setCullMode(.none)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    camRight:   SIMD4<Float>(camRight.x, camRight.y, camRight.z, tanHalfFov),
                    camUp:      SIMD4<Float>(camUp.x,    camUp.y,    camUp.z,    aspect),
                    camFwd:     SIMD4<Float>(camFwd.x,   camFwd.y,   camFwd.z,   frame.camera.underground))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                          cameraPosW: camPosW)
                let ug = max(0, min(1, (frame.camera.underground - 0.05) / 0.40))
                let undergroundCloudFade = 1 - ug * ug * (3 - 2 * ug)
                wuSky.cloudsOn = gfxClouds ? undergroundCloudFade : 0   // #47 volumetric cloud toggle (sky pass)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            // --- Terrain pass ---
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)

            var wu = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                   reflectScale: gfxWater ? 1 : 0,      // #: water-reflection toggle
                                   shadowScale:  shadowOn,              // #: world-shadow toggle (0 = off / grid not ready)
                                   cameraPosW: camPosW,
                                   sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day))
            wu.cameraPosW.w = kShadowFarR
            wu.celShade = gfxCelShade ? 1 : 0   // #130 toon-band the diffuse term in fmain
            wu.pbrStr   = gfxPBRStr             // #47 stylized PBR specular strength (terrain)
            wu.voxOrigin = voxOriginU           // world-space voxel sun-shadow grid
            wu.voxDims   = voxDimsU
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            if let occ = shadowVolTex { enc.setFragmentTexture(occ, index: 0) }  // world occupancy grid (fine)
            if let occc = shadowVolCoarseTex { enc.setFragmentTexture(occc, index: 1) }  // coarse mip (empty-space skip)
            // Wind/weather available to terrain frag at index 3 (rain wet-darkening)
            enc.setFragmentBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            // Wind uniforms to terrain vertex shader at index 3 (foliage sway)
            enc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)

            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = bufs[d.vertex_buffer],
                      let ibuf = bufs[d.index_buffer] else { continue }
                var u = Uniforms(
                    viewProj:      viewProj,
                    chunkOrigin:   SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime:    SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: matrix_identity_float4x4,
                    dimSatN:       SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ibuf,
                                          indexBufferOffset: Int(d.index_offset))
            }

            // --- Sub-voxel props (#52: GPU-instanced) — upload the tiny instance
            //     list and let the GPU expand the models. No per-frame CPU rebuild. ---
            let propN = Int(frame.prop_instance_count)
            if propN > 0, let insts = frame.prop_instances {
                let need = propN * MemoryLayout<bf_prop_instance>.stride
                if propInstanceBuffer == nil || propInstanceBuffer!.length < need {
                    propInstanceBuffer = device.makeBuffer(length: max(need, 64 * 1024), options: .storageModeShared)
                }
                if let ib = propInstanceBuffer {
                    memcpy(ib.contents(), insts, need)
                    let dayBright = 0.30 + 0.70 * Renderer.dayLight(frame.camera.time_of_day)
                    var pu2 = PropUniforms(viewProj: viewProj,
                                           params: SIMD4<Float>(dayBright, wallClock, gfxFoliage ? 1 : 0, 0))
                    enc.setRenderPipelineState(propPipeline)
                    enc.setDepthStencilState(depthState)
                    enc.setCullMode(.none)   // small opaque cuboids; skip winding concerns
                    enc.setVertexBuffer(ib, offset: 0, index: 0)
                    enc.setVertexBytes(&pu2, length: MemoryLayout<PropUniforms>.stride, index: 1)
                    enc.setVertexBuffer(propModelTable, offset: 0, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: kPropVertsPerInstance, instanceCount: propN)
                }
            }

            // Entities + particles
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            // #116 character shadows: entities both RECEIVE the world voxel sun shadow and CAST a
            // cheap stylized ground blob. Gate on gfxCharShadows AND the shared world-shadow toggle
            // (shadowOn already folds in gfxShadows + grid-ready); pass the same voxel grid uniforms
            // + occupancy textures the terrain marches, so a creature's shade matches the ground.
            let es = EntityShadowUniforms(
                sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                voxOrigin:  voxOriginU,
                voxDims:    voxDimsU,
                params:     SIMD4<Float>((gfxCharShadows && shadowOn > 0.5) ? 1 : 0, 0, 0, 0))
            entityRenderer.encode(enc, viewProj: viewProj, entities: frame.entities,
                                  count: Int(frame.entity_count), shadow: es,
                                  occ: shadowVolTex, occCoarse: shadowVolCoarseTex)
            particles.update(Float(dt))
            particles.encode(enc, viewProj: viewProj)

            // --- Ambient life: birds (day) + fireflies (night) ---
            let spriteCount = updateAmbientSprites(
                wallClock: wallClock,
                timeOfDay: frame.camera.time_of_day,
                camPos: SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z),
                greyAmt: max(0, 1 - frame.camera.local_sat))   // #: Grey ash density
            if spriteCount > 0 {
                enc.setRenderPipelineState(ambientLifePipeline)
                enc.setDepthStencilState(ambientLifeDepthState)
                enc.setCullMode(.none)
                var alU = AmbientLifeUniforms(
                    viewProj:   viewProj,
                    camPosW:    camPosW,
                    timeOfDay:  frame.camera.time_of_day,
                    wallClock:  wallClock,
                    pad0:       0,
                    pad1:       0)
                enc.setVertexBuffer(ambientLifeBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&alU, length: MemoryLayout<AmbientLifeUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: spriteCount * 6)
            }

            // --- Water translucency pass ---
            // Re-draw chunk meshes with the water pipeline: the fragment shader discards
            // all material IDs except 9 (water) and outputs alpha 0.55 so the lake
            // bottom (already in the colour buffer from the opaque terrain pass) shows
            // through. Depth write is OFF; depth test is lessEqual so only actual water
            // surface fragments are drawn (terrain below is already at lesser depth).
            enc.setRenderPipelineState(waterPipeline)
            enc.setDepthStencilState(waterDepthState)
            enc.setCullMode(.none)   // water seen from below should also be translucent
            enc.setFrontFacing(.counterClockwise)
            // Reuse the same WaterUniforms / occupancy / wind bindings already set above
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            if let occ = shadowVolTex { enc.setFragmentTexture(occ, index: 0) }  // world occupancy grid (fine)
            if let occc = shadowVolCoarseTex { enc.setFragmentTexture(occc, index: 1) }  // coarse mip (empty-space skip)
            enc.setFragmentBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vbuf = bufs[d.vertex_buffer],
                      let ibuf = bufs[d.index_buffer] else { continue }
                var u = Uniforms(
                    viewProj:      viewProj,
                    chunkOrigin:   SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime:    SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: matrix_identity_float4x4,
                    dimSatN:       SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vbuf, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ibuf,
                                          indexBufferOffset: Int(d.index_offset))
            }

            // --- First-person viewmodel (#70): the arm + equipped item, over the scene ---
            if viewModelArmCount > 0 {
                enc.setRenderPipelineState(viewModelPipeline)
                enc.setDepthStencilState(viewModelDepthState)
                enc.setCullMode(.none)
                let dayB = 0.30 + 0.70 * Renderer.dayLight(frame.camera.time_of_day)
                // #: tool swing — repeated goofy chops while mining (mine_progress > 0),
                // one chop per discrete mine/place/attack. -1 = idle (no swing).
                let swingPhase: Float
                if frame.hud.mine_progress > 0.0 {
                    swingPhase = Float(fmod(now * 2.4, 1.0))
                } else if (now - swingPulse) < 0.35 {
                    swingPhase = Float((now - swingPulse) / 0.35)
                } else {
                    swingPhase = -1.0
                }
                var vmU = ViewModelUniforms(proj: proj, params: SIMD4<Float>(
                    sin(wallClock * 1.6) * 0.006, sin(wallClock * 3.1) * 0.006, dayB, swingPhase))
                enc.setVertexBytes(&vmU, length: MemoryLayout<ViewModelUniforms>.stride, index: 1)
                enc.setVertexBuffer(viewModelArmBuf, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: viewModelArmCount * 36)

                // #70 v2: the equipped item in the fist (from the HUD in the frame).
                let sel = Int(frame.hud.selected_slot)
                var heldId = 0
                withUnsafePointer(to: frame.hud.hotbar) { p in
                    p.withMemoryRebound(to: bf_hud_slot.self, capacity: 9) { slots in
                        if sel >= 0 && sel < 9 { heldId = Int(slots[sel].item) }
                    }
                }
                if heldId != lastHeldItem {
                    lastHeldItem = heldId
                    let model = makeHeldItem(heldId)
                    heldItemCount = model.count
                    heldItemBuf = model.isEmpty ? nil : device.makeBuffer(
                        bytes: model, length: model.count * MemoryLayout<PropCuboidGPU>.stride, options: .storageModeShared)
                }
                if let hb = heldItemBuf, heldItemCount > 0 {
                    enc.setVertexBuffer(hb, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: heldItemCount * 36)
                }
            }

            // --- World-space precipitation (rain / snow) ---
            // Environmental falling particles in a volume around the camera. Driven
            // by engine weather (0=clear, 1=rain, 2=snow). Drawn after terrain+water
            // so it layers over the scene; depth-tested (lessEqual, no write) so
            // particles behind solid terrain are correctly hidden. Skipped entirely
            // when clear or when underwater (no rain underwater).
            if engineWeather != 0 && isUnderwater <= 0.5 {
                enc.setRenderPipelineState(precipPipeline)
                enc.setDepthStencilState(precipDepthState)
                enc.setCullMode(.none)
                var prU = PrecipUniforms(
                    viewProj:  viewProj,
                    camPosW:   camPosW,
                    wallClock: wallClock,
                    mode:      Float(engineWeather),   // 1=rain, 2=snow
                    boxSize:   kPrecipBox,
                    pad0:      0)
                enc.setVertexBuffer(precipBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&prU, length: MemoryLayout<PrecipUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: kPrecipCount * 6)
            }

            // --- Underwater post-pass ---
            if isUnderwater > 0.01 {
                enc.setRenderPipelineState(underwaterPipeline)
                enc.setDepthStencilState(skyDepthState)
                enc.setCullMode(.none)
                var wuPost = WaterUniforms(wallClockSecs: wallClock, underwater: isUnderwater,
                                           cameraPosW: camPosW)
                enc.setVertexBytes(&wuPost, length: MemoryLayout<WaterUniforms>.stride, index: 0)
                enc.setFragmentBytes(&wuPost, length: MemoryLayout<WaterUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }

            enc.endEncoding()
        }

        // =====================================================================
        // PASS 3: Bloom — bright-pass (HDR → half-res bloomBright)
        // =====================================================================
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBrightPipeline,
                             inTexture: hdrColor, outTexture: bloomBright,
                             uniforms: nil, uniformsSize: 0)

        // Separable Gaussian blur, two H+V sweeps (ping-pong; can't alias in Metal).
        // Final result lands back in bloomBright for the composite pass.
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurHPipeline,
                             inTexture: bloomBright, outTexture: bloomBlurA,
                             uniforms: nil, uniformsSize: 0)
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurVPipeline,
                             inTexture: bloomBlurA, outTexture: bloomBlurB,
                             uniforms: nil, uniformsSize: 0)
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurHPipeline,
                             inTexture: bloomBlurB, outTexture: bloomBlurA,
                             uniforms: nil, uniformsSize: 0)
        encodeFullscreenPass(cmd: cmd, pipeline: bloomBlurVPipeline,
                             inTexture: bloomBlurA, outTexture: bloomBright,
                             uniforms: nil, uniformsSize: 0)

        // Precipitation driven entirely by engine weather field (0=clear, 1=rain, 2=snow).
        // Pack: >0 = rain (strength), <0 = snow (abs = strength), 0 = clear.
        let precipPacked: Float
        switch engineWeather {
        case 1:  precipPacked =  1.0   // rain
        case 2:  precipPacked = -1.0   // snow
        default: precipPacked =  0.0   // clear
        }
        // God rays (#119): volumetric light shafts via a shadow-map raymarch in the
        // composite pass (replaces the old screen-space sun halo). The single strength
        // knob folds the toggle (gfxGodRays) AND daylight (dayLight) so it is zero at
        // night and zero when the player turns it off. THE TUNING KNOB is kGodRayStrength.
        let dayT  = Renderer.dayLight(frame.camera.time_of_day)
        var grStrength: Float = 0
        if gfxGodRays {                                   // #: god-ray toggle
            // #136 fold in the intensity slider (0..1) so the rays scale from off to the
            // kGodRayStrength ceiling; defaults to 0.5 = half the old full-strength look.
            grStrength = dayT * (1 - frame.camera.underground) * Renderer.kGodRayStrength * gfxGodRayStr
        }
        // #132 LENS FLARE gate. Project the sun to screen + derive the look-at-sun strength
        // on the CPU; fold in the toggle and underground (no flare in a cave). The shader does
        // the occlusion depth test + the per-element draw. Zero here => the flare block is
        // skipped entirely (free when toggled off, off-screen, or at night via dayT).
        var flareStr: Float = 0
        var sunUVx: Float = 0, sunUVy: Float = 0
        if gfxLensFlare {                                 // #132 lens-flare toggle
            let g = Renderer.sunFlareGate(viewProj: viewProj,
                                          camPos: SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z),
                                          sunDir: SIMD3<Float>(sun.x, sun.y, sun.z), dayT: dayT)
            sunUVx = g.uv.x; sunUVy = g.uv.y
            flareStr = g.strength * (1 - frame.camera.underground)
        }
        // #136 bloom intensity slider (0..1). Maps the default 0.5 to the prior fixed
        // look (0.08 add) and 1.0 to double it: bloomAdd = 0.16 * gfxBloomStr.
        var pu = PostUniforms(bloomStrength: 0.16 * gfxBloomStr, vignetteStr: 0.22, satBoost: 1.18,
                              rainStrength: precipPacked, wallClockSecs: wallClock,
                              godrayStrength: 0, sunScreenX: sunUVx, sunScreenY: sunUVy,
                              sunColorR: 1.0, sunColorG: 0.6 + 0.35 * dayT, sunColorB: 0.3 + 0.5 * dayT,
                              greyHaze: max(0, 1 - frame.camera.local_sat),   // #: The Grey wash
                              celShade: gfxCelShade ? 1 : 0)   // #130 ink outlines + cel grade
        pu.lensFlareStr = flareStr
        // #136 cel ink-outline intensity slider (0..1) scales CEL_OUTLINE_DARK in the
        // composite. Only meaningful when cel-shade is on; 0 = no outline, 1 = current look.
        pu.celOutlineStr = gfxCelShade ? gfxCelOutlineStr : 0
        // #119 volumetric uniforms shared by every composite call site this frame. The god-ray
        // occlusion now marches the SAME world occupancy grid the cast shadows use (no shadow map).
        var vu = VolUniforms(
            invViewProj:    viewProj.inverse,
            voxOrigin:      voxOriginU,
            voxDims:        voxDimsU,
            camPosW:        SIMD4<Float>(camPosW.x, camPosW.y, camPosW.z, kShadowFarR),
            sunDir:         SIMD4<Float>(sun.x, sun.y, sun.z, 0),
            sunColor:       SIMD4<Float>(1.0, 0.6 + 0.35 * dayT, 0.3 + 0.5 * dayT, grStrength))

        // =====================================================================
        // PASS 4a: Composite (ACES + colour grade + vignette)
        //   MetalFX path:  composite → compositeLowRes (bgra8Unorm at sceneSize)
        //   Fallback path: composite → drawable directly (bilinear upscale via sampler)
        // =====================================================================
#if canImport(MetalFX)
        let useMetalFX: Bool
        if #available(macOS 13.0, *) {
            useMetalFX = metalFXEnabled && _spatialScaler != nil && compositeLowRes != nil
        } else {
            useMetalFX = false
        }
#else
        let useMetalFX = false
#endif

        if useMetalFX, let lowResTarget = compositeLowRes {
            // --- Composite to the low-res intermediate ---
            let lowResRP = MTLRenderPassDescriptor()
            lowResRP.colorAttachments[0].texture    = lowResTarget
            lowResRP.colorAttachments[0].loadAction  = .dontCare
            lowResRP.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: lowResRP) {
                enc.setRenderPipelineState(compositePipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor,    index: 0)
                enc.setFragmentTexture(bloomBright, index: 1)
                enc.setFragmentTexture(hdrDepth,    index: 2)   // #119 scene depth for the raymarch
                if let occ = shadowVolTex { enc.setFragmentTexture(occ, index: 3) }  // world occupancy grid (fine)
                if let occc = shadowVolCoarseTex { enc.setFragmentTexture(occc, index: 4) }  // coarse mip
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
#if canImport(MetalFX)
            // --- PASS 4b: MetalFX spatial upscale → drawable ---
            if #available(macOS 13.0, *), let scaler = _spatialScaler {
                scaler.colorTexture  = lowResTarget
                scaler.outputTexture = drawable.texture
                scaler.encode(commandBuffer: cmd)
            }
#endif
        } else {
            // --- Fallback: composite straight to drawable (bilinear, original behaviour) ---
            if let passDesc = view.currentRenderPassDescriptor {
                passDesc.colorAttachments[0].loadAction  = .clear
                passDesc.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                if let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
                    enc.setRenderPipelineState(compositePipeline)
                    enc.setDepthStencilState(noDepthState)
                    enc.setCullMode(.none)
                    enc.setFragmentTexture(hdrColor,    index: 0)
                    enc.setFragmentTexture(bloomBright, index: 1)
                    enc.setFragmentTexture(hdrDepth,    index: 2)   // #119 scene depth for the raymarch
                    if let occ = shadowVolTex { enc.setFragmentTexture(occ, index: 3) }  // world occupancy grid (fine)
                    if let occc = shadowVolCoarseTex { enc.setFragmentTexture(occc, index: 4) }  // coarse mip
                    enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                    enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
        }

        // In-game screenshot (backslash): if requested, composite the final scene
        // into a CPU-readable texture in THIS command buffer (the drawable itself is
        // framebufferOnly and cannot be read back). The same compositePipeline + post
        // uniforms as the on-screen frame are reused, so the captured image is the
        // real frame, not an approximation. The HUD overlay is added on the CPU after
        // the GPU finishes (see captureScreenshot). Needs no Screen Recording
        // permission and uses no deprecated API.
        let wantShot = gameView?.consumeScreenshotRequest() ?? false
        if wantShot {
            let rb = screenshotTexture(width: drawable.texture.width, height: drawable.texture.height)
            if let rb = rb {
                let srp = MTLRenderPassDescriptor()
                srp.colorAttachments[0].texture     = rb
                srp.colorAttachments[0].loadAction  = .dontCare
                srp.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: srp) {
                    enc.setRenderPipelineState(compositePipeline)
                    enc.setDepthStencilState(noDepthState)
                    enc.setCullMode(.none)
                    enc.setFragmentTexture(hdrColor,    index: 0)
                    enc.setFragmentTexture(bloomBright, index: 1)
                    enc.setFragmentTexture(hdrDepth,    index: 2)   // #119 scene depth for the raymarch
                    if let occ = shadowVolTex { enc.setFragmentTexture(occ, index: 3) }  // world occupancy grid (fine)
                    if let occc = shadowVolCoarseTex { enc.setFragmentTexture(occc, index: 4) }  // coarse mip
                    enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                    enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    enc.endEncoding()
                }
            }
        }

        // Present inside the Core Animation transaction so the AppKit HUD overlay
        // (hotbar, hearts, inventory) composites ON TOP of the Metal layer. With
        // the default async present the metal content draws over the overlay and
        // the HUD is invisible. Requires view.presentsWithTransaction = true.
        // This path is unchanged regardless of whether MetalFX is active.
        if view.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }

        // Finish the screenshot once the GPU has produced the readback texture. We
        // only block on completion for the (rare) screenshot frame, so normal frames
        // keep their async-present timing.
        if wantShot, let rb = screenshotReadback {
            cmd.waitUntilCompleted()
            captureScreenshot(gameTexture: rb, meta: shotMetaString(frame.camera, frame.hud))
        }

        // Audio: drive day/evening music + splash when entering water.
        audio?.setTimeOfDay(frame.camera.time_of_day)
        audio?.tickGrey(inGrey: frame.hud.in_dim != 0, dt: Float(dt))   // #88 darker music in the grey
        let nowUnder = frame.camera.underwater > 0.5
        if nowUnder && !lastUnderwater { audio?.play(.splash) }
        lastUnderwater = nowUnder

        hud?.update(from: frame.hud)

        // #109 chests: poll the engine for an open chest (set by a right-click on a
        // chest block) and push its live contents to the HUD so the chest panel shows
        // and stays current after every take/deposit. When no chest is open the panel
        // is hidden. One cheap poll per frame; no struct-layout change.
        if let hudView = hud {
            var cpos = bf_ivec3()
            var nowOpen = false
            if bf_chest_open_pos(e, &cpos) != 0 {
                var view = bf_chest_view()
                if bf_chest_query(e, cpos, &view) == BF_OK && view.present != 0 {
                    openChestPos = cpos
                    hudView.setChestOpen(pos: cpos, view: view)
                    nowOpen = true
                } else {
                    openChestPos = nil
                    hudView.setChestClosed()
                }
            } else {
                openChestPos = nil
                hudView.setChestClosed()
            }
            // Release/recapture the pointer so the panel is clickable while open.
            gameView?.setChestPanel(open: nowOpen)

            // #95 living villages: poll the nearest village's tier/donation status and
            // push it to the HUD donation panel. One cheap read per frame; the engine
            // returns present=0 when none is near, which hides the panel.
            var vview = bf_village_view()
            if bf_village_query(e, &vview) == BF_OK && vview.present != 0 {
                hudView.setVillage(vview)
            } else {
                hudView.setVillage(nil)
            }
        }

        bf_frame_end(e)
        registry.collect()
    }

    // ---- In-game screenshot (backslash key) ---------------------------------
    // Directory every screenshot is written to. A stable absolute path under the
    // user's home directory (~/blockfall-shots) so it is the same no matter how the
    // .app was launched (Finder, `open`, play.sh) — the running bundle has no
    // reliable notion of the source repo root, and the save-game dir is per-world.
    // Created on first use. Documented and .gitignore'd.
    private static let screenshotDir: String =
        (NSHomeDirectory() as NSString).appendingPathComponent("blockfall-shots")

    // Lazily create / resize the CPU-readable bgra8 texture the screenshot composite
    // renders into. Shared storage so getBytes works; .renderTarget so the composite
    // pass can write it.
    private func screenshotTexture(width: Int, height: Int) -> MTLTexture? {
        if let t = screenshotReadback, t.width == width, t.height == height { return t }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        screenshotReadback = device.makeTexture(descriptor: td)
        return screenshotReadback
    }

    // Compose the captured game texture with the live AppKit HUD overlay and write a
    // timestamped PNG. The game image comes from the readback texture (the same
    // PNG-readback path PerfHarness.cgImageFromTexture uses); the HUD is rendered
    // into an NSBitmapImageRep via the standard AppKit cacheDisplay path (no Screen
    // Recording permission, no deprecated CGWindowList call). Both are drawn into one
    // CGContext at the drawable's pixel size and encoded with writeCGImagePNG.
    // Build a filename-safe metadata tag (coords, compass facing, day/night phase,
    // biome) so the screenshot filename alone carries the context, no need to read the
    // HUD text off the image. Mirrors HUDView.cardinal()/timePhase() so it matches the
    // on-screen readout.
    private func shotMetaString(_ cam: bf_camera, _ hud: bf_hud_state) -> String {
        let x = Int(cam.position.x.rounded()), y = Int(cam.position.y.rounded()), z = Int(cam.position.z.rounded())
        let names = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
        var deg = Double(atan2(cam.forward.x, cam.forward.z)) * 180.0 / .pi
        deg = deg.truncatingRemainder(dividingBy: 360); if deg < 0 { deg += 360 }
        let face = names[Int((deg / 45.0).rounded()) % 8]
        let phase: String
        switch cam.time_of_day {
        case 0.23..<0.30: phase = "dawn"
        case 0.30..<0.70: phase = "day"
        case 0.70..<0.77: phase = "dusk"
        default:          phase = "night"
        }
        let biome = withUnsafeBytes(of: hud.biome_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let bsafe = String(biome.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        var parts = ["x\(x)y\(y)z\(z)", face, phase]
        if !bsafe.isEmpty { parts.append(bsafe) }
        return parts.joined(separator: "_")
    }

    private func captureScreenshot(gameTexture: MTLTexture, meta: String) {
        let w = gameTexture.width, h = gameTexture.height
        guard let gameImg = cgImageFromTexture(gameTexture) else {
            NSLog("Blockfall: screenshot failed (could not read game texture)"); return
        }

        // Render the HUD NSView into a bitmap. bitmapImageRepForCachingDisplay sizes
        // the backing store in PIXELS for the view's bounds at the current backing
        // scale, so a Retina HUD comes back at the same pixel size as the drawable.
        var hudImg: CGImage? = nil
        if let hudView = hud, hudView.bounds.width > 0, hudView.bounds.height > 0,
           let rep = hudView.bitmapImageRepForCachingDisplay(in: hudView.bounds) {
            hudView.cacheDisplay(in: hudView.bounds, to: rep)
            hudImg = rep.cgImage
        }

        // Composite game first, HUD on top, at the drawable pixel size. Both the
        // Metal readback CGImage and the AppKit-cached HUD CGImage are drawn with the
        // default CTM: CGContext.draw + makeImage apply Core Graphics' bottom-left
        // origin symmetrically, so an image drawn straight is reproduced in the same
        // memory order (this is why the headless writeTexturePNG path is upright with
        // no flip). Drawing the HUD second layers it on top, matching the on-screen
        // z-order (Metal layer below, AppKit HUD above).
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: bi) else {
            NSLog("Blockfall: screenshot failed (could not allocate composite context)"); return
        }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(gameImg, in: full)             // game scene (Metal readback)
        if let hudImg = hudImg {
            ctx.draw(hudImg, in: full)          // HUD overlay on top (matches on-screen z-order)
        }
        guard let composite = ctx.makeImage() else {
            NSLog("Blockfall: screenshot failed (could not build composite image)"); return
        }

        // Write to <screenshotDir>/shot_<timestamp>.png, creating the dir if needed.
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Renderer.screenshotDir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let name = "shot_\(fmt.string(from: Date()))_\(meta).png"
        let path = (Renderer.screenshotDir as NSString).appendingPathComponent(name)
        if writeCGImagePNG(composite, to: path) {
            NSLog("Blockfall: screenshot saved -> %@", path)
            hud?.flashScreenshot()   // brief on-screen confirmation (does not pause)
        } else {
            NSLog("Blockfall: screenshot failed to encode PNG at %@", path)
        }
    }

    // ---- #13: Multiplayer compass builder -----------------------------------
    // Scans frame.entities for remote players (kind == 100). For each it decides
    // whether the peer is on-screen-and-in-front (project through view*proj and
    // test clip.w > 0 with |ndc| < 1) → a screen point; otherwise it computes a
    // stable off-screen arrow direction from the peer's offset projected onto the
    // camera right/up axes. The behind-camera case (forwardDot <= 0) keeps the
    // arrow from flipping: we point it outward along the (right,up) components.
    // Results are pushed to the HUD which draws the markers/arrows.
    //
    // The HUD draws in the GameView's point coordinate space (origin bottom-left,
    // y-up, same as the non-flipped NSView). NDC is x∈[-1,1] right, y∈[-1,1] up,
    // so the point conversion is a straightforward remap with no y-flip needed.
    private func buildPeerCompass(hud: HUDView,
                                  frame: bf_render_frame,
                                  viewProj: simd_float4x4,
                                  camPos: SIMD3<Float>,
                                  camFwd: SIMD3<Float>,
                                  camRight: SIMD3<Float>,
                                  camUp: SIMD3<Float>) {
        let n = Int(frame.entity_count)
        guard n > 0, let ents = frame.entities else {
            hud.setPeers([])
            return
        }

        // View size in POINTS (HUD overlay shares this frame). Fall back to the
        // capped scene size only if the view isn't available yet.
        let vb = gameView?.bounds.size ?? sceneSize
        let vw = CGFloat(max(1, vb.width))
        let vh = CGFloat(max(1, vb.height))

        // Turn a world position into a HUD marker: an on-screen point if it projects
        // inside the viewport, else an off-screen edge-arrow direction. Edge direction
        // uses raw right/up dot products (not w-divided clip) so it stays stable when
        // the target is behind the camera.
        func marker(at worldPos: SIMD3<Float>, color: NSColor, label: String) -> HUDView.PeerMarker {
            let to = worldPos - camPos
            let distM = Int(simd_length(to).rounded())
            let clip = viewProj * SIMD4<Float>(worldPos.x, worldPos.y, worldPos.z, 1)
            var onScreen = false
            var screenPt = CGPoint.zero
            if clip.w > 0.0001 {
                let ndcX = clip.x / clip.w, ndcY = clip.y / clip.w
                if abs(ndcX) <= 1 && abs(ndcY) <= 1 {
                    onScreen = true
                    screenPt = CGPoint(x: (CGFloat(ndcX) * 0.5 + 0.5) * vw,
                                       y: (CGFloat(ndcY) * 0.5 + 0.5) * vh)
                }
            }
            var edgeDir = CGVector(dx: 0, dy: 1)
            if !onScreen {
                var dx = CGFloat(simd_dot(to, camRight))
                var dy = CGFloat(simd_dot(to, camUp))
                let len = (dx * dx + dy * dy).squareRoot()
                if len < 1e-5 { dx = 0; dy = 1 } else { dx /= len; dy /= len }
                edgeDir = CGVector(dx: dx, dy: dy)
            }
            return HUDView.PeerMarker(onScreen: onScreen, screenPt: screenPt,
                                      edgeDir: edgeDir, distM: distM,
                                      color: color, label: label)
        }

        var markers: [HUDView.PeerMarker] = []

        // Remote players (#13): one marker each, in the peer's tint.
        for i in 0..<n {
            let e = ents[i]
            guard e.kind == 100 else { continue }
            let head = SIMD3<Float>(e.position.x, e.position.y + e.scale * 0.9, e.position.z)
            let color = NSColor(srgbRed: CGFloat(max(0, min(1, e.color.x))),
                                green:   CGFloat(max(0, min(1, e.color.y))),
                                blue:    CGFloat(max(0, min(1, e.color.z))), alpha: 1)
            markers.append(marker(at: head, color: color, label: "Player"))
        }

        // Quest target (#41): the ONE creature the active quest wants you to reach —
        // not every boss. Red for a boss to calm, gold for a creature to befriend.
        if let e = engine {
            var qt = bf_quest_target()
            if bf_quest_target_get(e, &qt) == 1 && qt.active == 1 {
                let pos = SIMD3<Float>(qt.position.x, qt.position.y + 1.0, qt.position.z)
                let color = qt.is_boss == 1
                    ? NSColor(srgbRed: 0.95, green: 0.25, blue: 0.20, alpha: 1)   // fight
                    : NSColor(srgbRed: 1.0,  green: 0.80, blue: 0.20, alpha: 1)   // befriend
                let label = withUnsafeBytes(of: qt.label) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                markers.append(marker(at: pos, color: color, label: label))
            }
        }

        hud.setPeers(markers)
    }

    // Helper: fullscreen triangle pass with one input + one output texture.
    private func encodeFullscreenPass(cmd: MTLCommandBuffer,
                                      pipeline: MTLRenderPipelineState,
                                      inTexture: MTLTexture,
                                      outTexture: MTLTexture,
                                      uniforms: UnsafeRawPointer?,
                                      uniformsSize: Int) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture     = outTexture
        rp.colorAttachments[0].loadAction  = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(noDepthState)
        enc.setCullMode(.none)
        enc.setFragmentTexture(inTexture, index: 0)
        if let u = uniforms, uniformsSize > 0 {
            enc.setFragmentBytes(u, length: uniformsSize, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: Ambient life sprite update (CPU procedural, ~80 sprites max)

    /// Fills ambientLifeBuffer with this frame's bird/firefly sprites.
    /// Returns the sprite count written (may be 0 when completely faded).
    @discardableResult
    private func updateAmbientSprites(wallClock: Float, timeOfDay: Float, camPos: SIMD3<Float>,
                                      greyAmt: Float = 0) -> Int {
        // dayT: 0=night, 1=day (sun-elevation based so birds/fireflies swap when the
        // sun actually sets, not a quarter-cycle off — see Renderer.dayLight).
        let dayT  = Renderer.dayLight(timeOfDay)
        // nightT: inverse
        let nightT = max(0, 1.0 - dayT * 2.0)   // 0 during day, >0 during dusk/night

        // Spawn budget
        let birdCount: Int     = Int((dayT * dayT * 12).rounded())    // 0..12 birds by day
        let fireflyCount: Int  = Int((nightT * nightT * 40).rounded()) // 0..40 fireflies by night
        let pollenCount: Int   = gfxPollen ? Int((dayT * 16).rounded()) : 0   // 0..16 motes by day (#45, toggle)
        // Grey ash motes: density scales with how drained the player's region is, so
        // walking into The Grey is viscerally obvious (dust/ash thickening in the air).
        let g = max(0, min(1, greyAmt))
        let ashCount: Int      = Int((g * g * 42).rounded())          // 0..42 motes, ramps in the Grey
        let totalSprites = min(birdCount + fireflyCount + pollenCount + ashCount, kMaxAmbientSprites)
        guard totalSprites > 0 else { return 0 }

        let ptr = ambientLifeBuffer.contents().bindMemory(to: AmbientSpritePod.self, capacity: kMaxAmbientSprites)

        // --- Birds (daytime, sky sprites, large) ---
        for i in 0..<birdCount {
            let fi = Float(i)
            // Each bird orbits the player slowly at a random angle offset
            let angle = wallClock * 0.06 + fi * 2.399              // golden-angle spacing
            let radius = 30.0 + sin(fi * 1.618 + wallClock * 0.02) * 18.0
            let height = camPos.y + 22.0 + sin(fi * 0.9 + wallClock * 0.07) * 6.0
            let bx = camPos.x + cos(angle) * radius
            let bz = camPos.z + sin(angle) * radius
            let by = height
            // Fade birds out at dawn/dusk edges
            let birdAlpha = min(1.0, dayT * 3.0)
            ptr[i] = AmbientSpritePod(
                posW:  SIMD4<Float>(bx, by, bz, 0.9),                        // w=size
                color: SIMD4<Float>(0.15, 0.12, 0.10, birdAlpha * 0.85))    // dark silhouette
        }

        // --- Fireflies (nighttime, near-ground, small emissive) ---
        for i in 0..<fireflyCount {
            let fi = Float(i)
            // Bob around the player at low altitude in a rough disc
            let angle = wallClock * 0.03 + fi * 2.399 + sin(fi * 1.1 + wallClock * 0.15) * 0.8
            let radius = 5.0 + fmod(fi * 3.14159, 18.0)
            let bobY = sin(fi * 0.87 + wallClock * (0.4 + fi * 0.003)) * 1.8
            let fx = camPos.x + cos(angle) * radius
            let fz = camPos.z + sin(angle) * radius
            let fy = camPos.y + 1.5 + bobY   // hover near ground level
            // Blink: each firefly has its own blink phase
            let blink = max(0.0, sin(wallClock * (1.0 + fi * 0.37) + fi * 2.1))
            let blink2 = blink * blink
            let ffAlpha = min(1.0, nightT * 2.0) * (0.4 + blink2 * 0.6)
            // Warm yellow-green, HDR overbright so they bloom
            let r = 1.2 + blink2 * 0.6
            let g = 1.8 + blink2 * 0.3
            let b = 0.3 + blink2 * 0.1
            let idx = birdCount + i
            ptr[idx] = AmbientSpritePod(
                posW:  SIMD4<Float>(fx, fy, fz, 0.22),              // w=size (tiny)
                color: SIMD4<Float>(r, g, b, ffAlpha))
        }

        // --- Pollen / dust motes (daytime, near-ground, slow drift) (#45) ---
        // Faint pale-gold specks that drift around the player by day, so the world
        // feels alive in sunlight the way fireflies do at night.
        for i in 0..<pollenCount {
            let idx = birdCount + fireflyCount + i
            if idx >= kMaxAmbientSprites { break }              // defensive cap
            let fi = Float(i)
            let angle  = wallClock * 0.02 + fi * 2.399
            let radius = 8.0 + Float(fmod(Double(fi) * 2.71, 12.0))   // 8-20: kept well away from the eye (#76)
            let px = camPos.x + cos(angle) * radius + sin(wallClock * 0.30 + fi) * 1.4
            let pz = camPos.z + sin(angle) * radius + cos(wallClock * 0.27 + fi) * 1.4
            let py = camPos.y + 0.8 + sin(fi * 0.6 + wallClock * 0.25) * 1.3
            let twinkle = 0.5 + 0.5 * sin(wallClock * 0.8 + fi * 1.7)
            // Fade motes that drift near the eye so they never flash across the HUD.
            let pdx = px - camPos.x, pdy = py - camPos.y, pdz = pz - camPos.z
            // Hard fade anything within 5 blocks of the eye so no mote ever flashes
            // across the HUD; full strength only past ~8 blocks. (#76)
            let pNear = max(0, min(1, ((pdx*pdx + pdy*pdy + pdz*pdz).squareRoot() - 5.0) / 3.0))
            let pAlpha  = dayT * (0.08 + twinkle * 0.10) * pNear   // faint, never busy, never up-close
            ptr[idx] = AmbientSpritePod(
                posW:  SIMD4<Float>(px, py, pz, 0.09),          // w=size (very tiny)
                color: SIMD4<Float>(1.0, 0.97, 0.80, pAlpha))  // pale warm gold
        }

        // --- Grey ash / dust motes (The Grey ambience) ---
        // Cold grey flecks that drift and slowly sink around the player, thickening
        // the more drained the region is — so being in The Grey feels like ash in the
        // air, not just desaturated terrain. Cover a wider/taller volume than pollen.
        for i in 0..<ashCount {
            let idx = birdCount + fireflyCount + pollenCount + i
            if idx >= kMaxAmbientSprites { break }              // defensive cap
            let fi = Float(i)
            let angle  = wallClock * 0.015 + fi * 2.399
            let radius = 4.0 + Float(fmod(Double(fi) * 3.37, 20.0))      // 4-24 blocks (kept off the eye)
            // Slow downward drift that wraps, plus lateral sway → ash settling.
            let fall   = Float(fmod(Double(wallClock * 0.6 + fi * 1.3), 9.0))   // 0..9 wrap
            let px = camPos.x + cos(angle) * radius + sin(wallClock * 0.2 + fi) * 1.2
            let pz = camPos.z + sin(angle) * radius + cos(wallClock * 0.18 + fi) * 1.2
            let py = camPos.y + 4.5 - fall + sin(fi * 0.5 + wallClock * 0.3) * 0.6
            let twinkle = 0.6 + 0.4 * sin(wallClock * 0.5 + fi * 2.1)
            let adx = px - camPos.x, ady = py - camPos.y, adz = pz - camPos.z
            let aNear = max(0, min(1, ((adx*adx + ady*ady + adz*adz).squareRoot() - 2.5) / 2.5))
            let aAlpha  = g * (0.12 + twinkle * 0.14) * aNear  // fade in with greyness, never up-close
            // Cold ashen grey, faintly blue, slight value variation per mote.
            let v = 0.40 + 0.18 * Float(fmod(Double(fi) * 0.61, 1.0))
            ptr[idx] = AmbientSpritePod(
                posW:  SIMD4<Float>(px, py, pz, 0.11),          // w=size (small)
                color: SIMD4<Float>(v, v * 1.02, v * 1.08, aAlpha))   // ashen grey
        }

        return totalSprites
    }

    // MARK: Sub-voxel props (#51/#52 GPU-instanced)
    // Prop model = a few coloured cuboids (centre, half-extent, colour) in 0..1
    // block space. Bold flat toy colours.
    private static func propModel(_ type: UInt32) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        let green = SIMD3<Float>(0.27, 0.62, 0.20)
        switch type {
        case 36, 37:   // flowers (red / yellow)
            let bloom: SIMD3<Float> = (type == 36) ? SIMD3(0.90, 0.20, 0.22) : SIMD3(0.97, 0.82, 0.16)
            return [
                (SIMD3(0.5, 0.28, 0.5), SIMD3(0.05, 0.28, 0.05), green),               // stem
                (SIMD3(0.5, 0.66, 0.5), SIMD3(0.20, 0.10, 0.20), bloom),               // bloom
                (SIMD3(0.5, 0.70, 0.5), SIMD3(0.09, 0.11, 0.09), SIMD3(0.98,0.80,0.22)),// center
            ]
        case 39:       // mushroom
            return [
                (SIMD3(0.5, 0.22, 0.5), SIMD3(0.09, 0.22, 0.09), SIMD3(0.92,0.88,0.78)),// stem
                (SIMD3(0.5, 0.52, 0.5), SIMD3(0.24, 0.12, 0.24), SIMD3(0.85,0.16,0.14)),// cap
            ]
        case 40:       // color crystal (pink, matches its light)
            return [
                (SIMD3(0.5,  0.40, 0.5),  SIMD3(0.11, 0.40, 0.11), SIMD3(0.96,0.42,0.86)),
                (SIMD3(0.33, 0.22, 0.52), SIMD3(0.07, 0.22, 0.07), SIMD3(0.82,0.52,0.96)),
                (SIMD3(0.66, 0.26, 0.43), SIMD3(0.06, 0.26, 0.06), SIMD3(0.92,0.46,0.92)),
            ]
        case 38:       // grass tuft — a few thin blades of varying height + green
            let g1 = SIMD3<Float>(0.32, 0.68, 0.22)
            let g2 = SIMD3<Float>(0.25, 0.58, 0.18)
            let g3 = SIMD3<Float>(0.38, 0.74, 0.27)
            return [
                (SIMD3(0.50, 0.34, 0.50), SIMD3(0.045, 0.34, 0.045), g1),  // tall centre blade
                (SIMD3(0.36, 0.24, 0.57), SIMD3(0.038, 0.24, 0.038), g2),  // shorter left-back
                (SIMD3(0.64, 0.27, 0.44), SIMD3(0.038, 0.27, 0.038), g3),  // medium right
                (SIMD3(0.49, 0.19, 0.37), SIMD3(0.034, 0.19, 0.034), g2),  // short front
            ]
        case 41:       // pebble / small rock — a couple of low grey stones
            let s1 = SIMD3<Float>(0.56, 0.56, 0.59)
            let s2 = SIMD3<Float>(0.46, 0.46, 0.49)
            return [
                (SIMD3(0.48, 0.11, 0.50), SIMD3(0.22, 0.11, 0.19), s1),    // main stone
                (SIMD3(0.68, 0.07, 0.40), SIMD3(0.10, 0.07, 0.10), s2),    // small side stone
            ]
        case 42:       // berry bush — leafy green clump with red berries
            let leaf  = SIMD3<Float>(0.20, 0.50, 0.22)
            let leaf2 = SIMD3<Float>(0.16, 0.42, 0.18)
            let berry = SIMD3<Float>(0.84, 0.14, 0.18)
            return [
                (SIMD3(0.50, 0.28, 0.50), SIMD3(0.28, 0.26, 0.28), leaf),   // bush body
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.19, 0.13, 0.19), leaf2),  // rounded top
                (SIMD3(0.34, 0.34, 0.62), SIMD3(0.05, 0.05, 0.05), berry),  // berry
                (SIMD3(0.66, 0.24, 0.40), SIMD3(0.05, 0.05, 0.05), berry),  // berry
            ]
        case 43:       // reed / cattail — TWO blocks tall, fuller clump, taller brown poof
            let stalk = SIMD3<Float>(0.28, 0.55, 0.30)
            let tip   = SIMD3<Float>(0.42, 0.26, 0.12)
            return [
                (SIMD3(0.44, 0.95, 0.50), SIMD3(0.055, 0.92, 0.055), stalk),  // tall stalk (~2 tall)
                (SIMD3(0.58, 0.86, 0.46), SIMD3(0.050, 0.84, 0.050), stalk),  // second stalk
                (SIMD3(0.50, 0.78, 0.57), SIMD3(0.048, 0.76, 0.048), stalk),  // third stalk (more fill)
                (SIMD3(0.46, 1.70, 0.50), SIMD3(0.10, 0.30, 0.10), tip),      // taller, fuller brown poof
            ]
        case 44:       // cactus — tall varied desert silhouette; shader scales per seed
            let cac = SIMD3<Float>(0.27, 0.52, 0.26)
            let cac2 = SIMD3<Float>(0.22, 0.45, 0.22)
            return [
                (SIMD3(0.50, 0.48, 0.50), SIMD3(0.16, 0.48, 0.16), cac),    // trunk
                (SIMD3(0.74, 0.44, 0.50), SIMD3(0.10, 0.09, 0.09), cac),    // right arm out
                (SIMD3(0.82, 0.58, 0.50), SIMD3(0.07, 0.18, 0.07), cac),    // right arm up
                (SIMD3(0.28, 0.62, 0.50), SIMD3(0.10, 0.09, 0.09), cac2),   // left arm out
                (SIMD3(0.20, 0.78, 0.50), SIMD3(0.07, 0.20, 0.07), cac2),   // left arm up
            ]
        case 45:       // seashell — small pale shell on the sand
            let sh  = SIMD3<Float>(0.94, 0.86, 0.80)
            let sh2 = SIMD3<Float>(0.90, 0.72, 0.70)
            return [
                (SIMD3(0.50, 0.08, 0.50), SIMD3(0.13, 0.07, 0.16), sh),     // shell body (low)
                (SIMD3(0.50, 0.15, 0.42), SIMD3(0.08, 0.06, 0.07), sh2),    // ridge
            ]
        case 46:       // lily pad — flat green disc floating on the water
            let pad  = SIMD3<Float>(0.30, 0.58, 0.30)
            let pad2 = SIMD3<Float>(0.24, 0.50, 0.26)
            return [
                (SIMD3(0.50, 0.04, 0.50), SIMD3(0.40, 0.03, 0.40), pad),    // wide flat pad
                (SIMD3(0.62, 0.05, 0.40), SIMD3(0.14, 0.03, 0.14), pad2),   // second leaf
            ]
        case 47:       // fallen stick — a low brown twig on the ground
            let bark  = SIMD3<Float>(0.42, 0.28, 0.16)
            let bark2 = SIMD3<Float>(0.36, 0.24, 0.14)
            return [
                (SIMD3(0.50, 0.06, 0.46), SIMD3(0.34, 0.05, 0.06), bark),   // main twig
                (SIMD3(0.40, 0.06, 0.60), SIMD3(0.16, 0.045, 0.05), bark2), // little branch
            ]
        case 5:        // #62 OAK foliage — BIG overlapping spheres. Each exposed leaf is
                       // a sphere wide enough (radius ~0.85) to merge with its 1-block
                       // neighbours into one continuous lumpy canopy, not separate dots.
            let g1 = SIMD3<Float>(0.20, 0.44, 0.16)
            let g2 = SIMD3<Float>(0.16, 0.37, 0.13)
            let g3 = SIMD3<Float>(0.25, 0.51, 0.19)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.88, 0.82, 0.88), g1),  // big main ball
                (SIMD3(0.34, 0.64, 0.46), SIMD3(0.58, 0.58, 0.58), g3),  // upper lump
                (SIMD3(0.64, 0.40, 0.58), SIMD3(0.56, 0.56, 0.56), g2),  // lower lump
            ]
        case 27:       // #62 BIRCH foliage — lighter, big overlapping spheres
            let b1 = SIMD3<Float>(0.31, 0.50, 0.20)
            let b2 = SIMD3<Float>(0.26, 0.44, 0.16)
            let b3 = SIMD3<Float>(0.38, 0.57, 0.25)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.86, 0.80, 0.86), b1),
                (SIMD3(0.36, 0.64, 0.48), SIMD3(0.57, 0.57, 0.57), b3),
                (SIMD3(0.63, 0.41, 0.56), SIMD3(0.55, 0.55, 0.55), b2),
            ]
        case 21:       // #62 OAK trunk — a rounded brown column, thinner than a full
                       // block so the trunk reads as round, not a stack of cubes
            let woak = SIMD3<Float>(0.40, 0.27, 0.16)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.40, 0.50, 0.40), woak),
            ]
        case 22:       // #62 BIRCH trunk — pale, slightly thinner column
            let wbirch = SIMD3<Float>(0.82, 0.80, 0.74)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.36, 0.50, 0.36), wbirch),
            ]
        case 49:       // #62 PINE trunk — dark reddish-brown conifer wood
            let wpine = SIMD3<Float>(0.34, 0.22, 0.14)
            return [
                (SIMD3(0.50, 0.50, 0.50), SIMD3(0.40, 0.50, 0.40), wpine),
            ]
        case 48:       // #62 PINE needles — dark green cones. Tall, slim silhouette, but a
                       // fuller lower skirt so the canopy reads dense, not see-through.
            let p1 = SIMD3<Float>(0.16, 0.34, 0.20)
            let p2 = SIMD3<Float>(0.13, 0.29, 0.17)
            return [
                (SIMD3(0.50, 0.44, 0.50), SIMD3(0.52, 0.96, 0.52), p1),  // tall slim main cone
                (SIMD3(0.50, 0.26, 0.50), SIMD3(0.74, 0.56, 0.74), p2),  // fuller lower skirt (density)
                (SIMD3(0.49, 0.72, 0.50), SIMD3(0.32, 0.60, 0.32), p1),  // upper spike
            ]
        default: return []
        }
    }

    // Build all visible props' world-space geometry into `out` (shared by the live
    // renderer). The GPU expands these per instance (#52) — no CPU geometry build.
    // #62: which primitive each prop type's parts use. 0=box, 1=sphere, 2=cone,
    // 3=cylinder. Tree foliage becomes round spheres, trunks become round (octagonal)
    // cylinders. Everything else stays a box.
    private static func propPartShape(_ type: UInt32) -> Float {
        switch type {
        case 5, 27: return 1   // oak/birch foliage → sphere
        case 48:    return 2   // pine needles → cone (conifer look)
        case 21, 22, 49: return 3  // oak/birch/pine trunk → cylinder
        default:     return 0  // box
        }
    }

    // Build the static model table: type rows × cuboid slots of PropCuboidGPU.
    // Unused slots are left zero (zero half-extent → the vertex shader skips them).
    static func makePropModelTable(device: MTLDevice) -> MTLBuffer {
        let rows = 18, slots = 5
        var table = [PropCuboidGPU](repeating: PropCuboidGPU(cx:0,cy:0,cz:0, hx:0,hy:0,hz:0, r:0,g:0,b:0),
                                    count: rows * slots)
        let typeForRow: [UInt32] = [36, 37, 39, 40, 38, 41, 42, 43, 44, 45, 46, 47,
                                    5, 27, 21, 22, 48, 49]  // #62 foliage(12,13) trunk(14,15) pine needles(16) pine log(17)
        for row in 0..<rows {
            let model = propModel(typeForRow[row])
            let shape = propPartShape(typeForRow[row])   // #62 box/sphere/cone/cylinder
            for (s, cu) in model.prefix(slots).enumerated() {
                table[row * slots + s] = PropCuboidGPU(cx: cu.0.x, cy: cu.0.y, cz: cu.0.z,
                                                       hx: cu.1.x, hy: cu.1.y, hz: cu.1.z,
                                                       r: cu.2.x, g: cu.2.y, b: cu.2.z,
                                                       shape: shape)
            }
        }
        return device.makeBuffer(bytes: table, length: table.count * MemoryLayout<PropCuboidGPU>.stride,
                                 options: .storageModeShared)!
    }

    // MARK: Sky colour (clear colour tint — sky pass renders on top)

    private func skyColor(_ t: Float) -> (Double, Double, Double) {
        let dayT  = Double(max(0.0, sin(t * .pi)))
        let dawnT = Double(max(0.0, 1.0 - abs(t - 0.25) * 8.0))
        let duskT = Double(max(0.0, 1.0 - abs(t - 0.75) * 8.0))
        let sunsetT = min(dawnT + duskT, 1.0)
        let nr = 0.08; let ng = 0.10; let nb = 0.22
        let dr = 0.68; let dg = 0.84; let db = 1.00
        let sr = 1.00; let sg = 0.52; let sb = 0.18
        var r = nr + (dr - nr) * dayT
        var g = ng + (dg - ng) * dayT
        var b = nb + (db - nb) * dayT
        r = r + (sr - r) * sunsetT * 0.85
        g = g + (sg - g) * sunsetT * 0.85
        b = b + (sb - b) * sunsetT * 0.85
        return (min(r, 1.0), min(g, 1.0), min(b, 1.0))
    }

    // MARK: Matrix helpers

    // bf_mat4 (column-major float[16]) -> simd_float4x4
    static func mat(_ m: bf_mat4) -> simd_float4x4 {
        let c = m.m
        return simd_float4x4(columns: (
            SIMD4<Float>(c.0,  c.1,  c.2,  c.3),
            SIMD4<Float>(c.4,  c.5,  c.6,  c.7),
            SIMD4<Float>(c.8,  c.9,  c.10, c.11),
            SIMD4<Float>(c.12, c.13, c.14, c.15)))
    }

    // Day/night light level (0 = full night, 1 = full day), driven by the sun's
    // actual elevation rather than sin(t*pi).
    //
    // FIX (night washout): the old terrain/prop/sky brightness used
    // 0.15 + 0.85*max(0, sin(t*pi)), which peaks at t=0.5 and only reaches its
    // night floor at the single instant t=0 / t=1. But the sun arc is
    // sun_dir = {cos(ang)*0.6, -sin(ang)-0.25, 0.90} with ang = t*2*pi, so the
    // sun is BELOW the horizon for t in ~(0.54, 0.96) and lowest at t=0.75 — a
    // quarter-cycle out of phase with sin(t*pi). The result: the world stayed lit
    // at 65-99% of noon through the whole night (no sun, so no shadows = a flat,
    // low-contrast, washed-out bright scene that is hard to read), and only went
    // dark at t~0/1 when the sun was actually back up. The shadow toggle never
    // touched this ambient term, so disabling lighting did not help — matching the
    // report ("washed out even with lighting off").
    //
    // Now we derive brightness from the real (normalized) sun elevation, so the
    // world is bright while the sun is up, falls through dusk, and holds a low
    // night floor across the entire night window. Noon stays at full brightness so
    // the daytime look is unchanged.
    static func dayLight(_ t: Float) -> Float {
        let ang = t * 2.0 * Float.pi
        // Sun direction (matches world.hpp). Elevation = -normalize(dir).y, positive
        // when the sun is above the horizon.
        let dx = cos(ang) * 0.6, dy = -sin(ang) - 0.25, dz: Float = 0.90
        let elev = -dy / (dx * dx + dy * dy + dz * dz).squareRoot()
        // smoothstep(-0.12, 0.25): full day when the sun is comfortably up, fading
        // to the night floor through dusk/dawn as it crosses the horizon.
        let x = max(0.0, min(1.0, (elev + 0.12) / 0.37))
        return x * x * (3.0 - 2.0 * x)
    }

    // #132 LENS-FLARE GATE (CPU side).
    // Project the (directional) sun onto the screen and derive the master flare strength
    // BEFORE it reaches the shader. The directional sun has no world position, so we place
    // it a long way down the toSun ray from the camera and project that point. Returns:
    //   onScreenUV : the sun's screen-space uv (matches compositeFrag's top-left uv), or
    //                (-1,-1) when the sun is behind the camera / off-screen.
    //   strength   : the master flare strength, 0..1, folding:
    //                  - daylight  (0 at night so the flare is impossible after dark)
    //                  - in-front-of-camera (flare needs the sun roughly ahead)
    //                  - look-at-sun: peaks when the sun sits near screen centre, fades
    //                    to 0 toward the screen edge (looking away -> no flare).
    // The shader still does the occlusion (scene-depth) test and the per-element draw; this
    // just kills the whole pass cheaply when it cannot possibly contribute.
    static func sunFlareGate(viewProj: simd_float4x4, camPos: SIMD3<Float>,
                             sunDir: SIMD3<Float>, dayT: Float)
        -> (uv: SIMD2<Float>, strength: Float) {
        // toSun points from the scene toward the sun (sunDir points downward from the sun).
        let toSun = simd_normalize(-sunDir)
        // A far point along the sun ray; projecting it gives the sun's screen position.
        let sunWorld = camPos + toSun * 1.0e6
        let clip = viewProj * SIMD4<Float>(sunWorld.x, sunWorld.y, sunWorld.z, 1.0)
        // Behind the camera (w <= 0): the sun is not in front, no flare.
        if clip.w <= 1e-4 { return (SIMD2<Float>(-1, -1), 0) }
        let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
        // Metal top-left uv: x maps [-1,1]->[0,1]; y is flipped.
        let uv = SIMD2<Float>(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5))
        // Off-screen (with a small margin so ghosts entering frame are not popped): no flare.
        let m: Float = 0.15
        if uv.x < -m || uv.x > 1 + m || uv.y < -m || uv.y > 1 + m {
            return (uv, 0)
        }
        // Look-at-sun: how close the sun is to the screen centre (0..1). Strongest when you
        // look straight at the sun, fading smoothly to the edges so a sun in the corner only
        // gives a faint flare and one off-screen gives none.
        let off = simd_length(SIMD2<Float>(uv.x - 0.5, uv.y - 0.5)) * 2.0   // 0 centre .. ~1.4 corner
        let centred = max(0.0, 1.0 - off / kFlareEdgeFade)
        let look = centred * centred * (3.0 - 2.0 * centred)   // smoothstep-ish ease
        return (uv, dayT * look)
    }

    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let t = tan(fovy * 0.5)
        var m = simd_float4x4(0)
        m.columns.0.x = 1 / (aspect * t)
        m.columns.1.y = 1 / t
        m.columns.2.z = far / (near - far)
        m.columns.2.w = -1
        m.columns.3.z = (far * near) / (near - far)
        return m
    }

    // The sun light-space matrix builders (buildLightMatrix / buildLightMatrixD) and the
    // LightFrustumDebug struct were retired with the shadow map. World-space voxel shadows
    // need no light-space projection: fmain marches the world occupancy grid toward the sun.

    // MARK: - Shaders (MSL, runtime compiled)
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // =========================================================
    // TERRAIN STRUCTS & HELPERS
    // =========================================================

    // PackedVertex: same layout as the C++ BFVertex.
    //   pos    : 18-bit packed voxel coord (6+6+6), bits [0..17]
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
        float pad2;
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

    // VolUniforms (240 bytes) — #119 volumetric god-ray raymarch, composite buffer(1).
    // Must EXACTLY match the Swift VolUniforms struct.
    struct VolUniforms {
        float4x4 invViewProj;    // clip -> world
        float4   voxOrigin;      // xyz = shadow grid origin (world block coords), w = march distance
        float4   voxDims;        // xyz = grid dims (voxels), w = soft-shadow flag
        float4   camPosW;        // xyz = camera world pos, w = far coverage radius
        float4   sunDir;         // xyz = sun dir (downward), w unused
        float4   sunColor;       // rgb = sun colour, w = volumetric strength (0 = off)
    };

    // (ShadowVertUniforms retired with the shadow-map render pass.)

    // WindUniforms (16 bytes) — foliage sway + weather.  buffer(3) on vertex AND frag.
    struct WindUniforms {
        float wallClockSecs;
        float rainStrength;   // 0..1
        float swayScale;      // #: foliage-sway toggle (0=off)
        float pad1;
    };

    // Vertex output for terrain pass.
    struct VOut {
        float4 position  [[position]];
        float3 color;
        float  shade;
        float  sat;
        float3 worldPos;
        uint   faceNorm  [[flat]];
        uint   material  [[flat]];
        float  ao;               // 0=fully occluded, 1=fully open (from bits [3:5])
    };

    // AmbientSprite: 32 bytes, matches Swift AmbientSpritePod.
    struct AmbientSprite {
        float4 posW;    // xyz=world pos, w=size
        float4 color;   // rgb=HDR colour (>1 ok), a=alpha
    };

    // AmbientLifeUniforms: matches Swift AmbientLifeUniforms.
    struct AmbientLifeUniforms {
        float4x4 viewProj;   // 64 bytes
        float4   camPosW;    // 16 bytes
        float    timeOfDay;
        float    wallClock;
        float    pad0;
        float    pad1;
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

        // ---- CHEST (31) --------------------------------------------------------
        // Wood box: SIDE faces show a lid-seam line across the upper third + a
        // metal latch clasp centred on the face.  TOP face = lid planks with a
        // clasp hinge bar across the middle.  BOTTOM = plain wood planks.
        if (matID == 31u) {
            float grain  = noise2(float2(uv.x * 4.5, worldPos.y * 0.9 + vH * 2.0)) * 0.55
                         + noise2(float2(uv.x * 10.0, worldPos.y * 2.2 + vH * 1.4)) * 0.45;
            float seam   = 1.0 - step(0.92, fract(uv.x * 2.8));
            float woodBri = mix(0.84, 1.14, grain) * mix(0.80, 1.0, seam);

            if (isTop) {
                // Lid planks + a hinge bar across the middle
                float2 lidUV = fract(worldPos.xz);
                float plankS = 1.0 - step(0.92, fract(lidUV.x * 2.5));
                float hinge  = smoothstep(0.04, 0.0, abs(lidUV.y - 0.5));   // dark line at centre
                float bri    = woodBri * mix(0.78, 1.0, plankS) * (1.0 - hinge * 0.45);
                return float3(clamp(bri, 0.72, 1.16));
            } else if (isBot) {
                return float3(clamp(woodBri, 0.78, 1.12));
            } else {
                // Side: lid seam at ~70% of height (upper third = lid)
                float localY = fract(worldPos.y);
                float lidSeam = smoothstep(0.04, 0.0, abs(localY - 0.68));   // 1 = on seam
                // Metal clasp: small rectangular bright patch at centre-bottom of lid band
                float cx  = fract(uv.x);   // 0..1 across face
                float cy  = localY;
                float claspX = smoothstep(0.04, 0.0, abs(cx - 0.5));        // centred in X
                float claspY = smoothstep(0.02, 0.0, abs(cy - 0.60));       // just below seam
                float clasp  = claspX * claspY;
                // Lid slightly brighter than body
                float lidBri  = mix(woodBri, woodBri * 1.10, step(0.68, localY));
                float bri     = lidBri * (1.0 - lidSeam * 0.40);
                // Clasp is iron-grey: pull colour toward neutral brightness
                float3 col    = float3(clamp(bri, 0.70, 1.16));
                col           = mix(col, float3(0.88), clasp * 0.70);
                return clamp(col, 0.70, 1.16);
            }
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
        float x = float(p.pos & 0x3f)         + float((p.pos >> 18) & 0xf) / 16.0;
        float y = float((p.pos >> 6) & 0x3f)  + float((p.pos >> 22) & 0xf) / 16.0;
        float z = float((p.pos >> 12) & 0x3f) + float((p.pos >> 26) & 0xf) / 16.0;
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
        o.position = u.viewProj * float4(swayedWorld, 1.0);

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
        if (!isEmissive && wu.shadowScale > 0.5) {
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
        float3 detail = blockDetail(in.worldPos, in.faceNorm, in.material);

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
        if (!isEmissive) {
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
    float3 evalSkyColor(float3 ray, float3 sd, float t, float clk, float cloudsOn, float2 ditherPx);

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
                                          wu.sunDirTime.xyz, wu.sunDirTime.w, t, 0.0, float2(0.0, 0.0));
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
        float lum = dot(col, float3(0.299, 0.587, 0.114));
        float sat = clamp(in.sat, 0.0, 1.0);
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

    static float cloudFbm(float2 p) { return fbm2(p); }

    // ===================================================================
    // #47 VOLUMETRIC CLOUDS — bold/toy-styled raymarched cumulus.
    // ===================================================================
    // Cheap 3D value noise (trilinear hash lerp). Reuses the same integer hash the
    // 2D noise uses so the cost is 8 hashes per sample, no trig, no texture fetch.
    static float cloudHash3(float3 i) {
        return uhash(uint(i.x) * 1597u + uint(i.y) * 2749u + uint(i.z) * 3433u);
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
        p.xz += wind;                                  // slow drift
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
        q += (w3 - 0.5) * 1.6;
        float base = cloudNoise3(q);                   // big puffy lobes (dominant)
        base += cloudNoise3(q * 2.4) * 0.34;           // medium billow
        base += cloudNoise3(q * 5.3) * 0.14;           // fluffy edge
        base /= 1.48;
        // BOLD shaping: a tight smoothstep carves a CRISP, graphic silhouette (defined toy
        // cumulus with clear blue gaps), not a soft connected haze. `cover` sets how much
        // sky the puffs fill. A vertical falloff thins the slab edges so the puffs have
        // rounded tops/bottoms rather than a hard sliced top and bottom.
        // #140 crisper silhouette: a TIGHTER smoothstep window (0.10 -> 0.065) gives the toy
        // cumulus a more defined, graphic edge with clear blue gaps, so the forms read as
        // separated chunky puffs instead of fuzzy feathered wisps near grazing angles.
        float lo = 0.52 - cover * 0.16;
        float d  = smoothstep(lo, lo + 0.065, base);
        return d;
    }

    // Sky colour along a view ray (gradient, sun/moon, stars, clouds, weather).
    // Shared by the sky pass AND reflective water (#43) — forward-declared above
    // waterFmain. Does NOT apply the underground fade (that's sky-pass only).
    float3 evalSkyColor(float3 ray, float3 sd, float t, float clk, float cloudsOn, float2 ditherPx) {
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

        float weatherCycle = sin(clk * (3.14159265f / 150.0f)) * 0.5f + 0.5f;
        float overcast = smoothstep(0.52, 0.80, weatherCycle) * 0.65;
        float rainStrength = smoothstep(0.60, 0.82, weatherCycle);

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
            float ocFade = smoothstep(0.0, 0.12, ray.y);
            skyCol = mix(skyCol, ocColor, ocCloud * overcast * ocFade);
        }

        // Lightning: rare (appears ~every 45s during storm), brief full-sky flash.
        if (rainStrength > 0.5) {
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

        float fairCloud = clamp(1.0 - overcast * 1.6, 0.0, 1.0);
        // Day/night gate (clouds fade out as the sun sets so night stays clean) AND the
        // toggle (cloudsOn). The ray must point above the horizon to enter the cloud slab.
        float cloudVis  = smoothstep(0.12, 0.38, dayT)
                        * smoothstep(0.08, 0.20, ray.y)
                        * fairCloud * clamp(cloudsOn, 0.0, 1.0);
        if (cloudVis > 0.001) {
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
            // CONCENTRIC rings. Use true fragment-space coordinates for the sky pass so adjacent
            // pixels receive a small well-distributed start offset. Falling back to ray-derived
            // coordinates is only for non-screen callers; water passes cloudsOn=0 and skips this.
            float2 cpix  = ((abs(ditherPx.x) + abs(ditherPx.y)) > 0.0) ? ditherPx : (ray.xz * 720.0);
            float cdith  = fract(52.9829189 * fract(dot(cpix, float2(0.06711056, 0.00583715))));
            tEnter += dt * (cdith - 0.5) * 0.10;
            float wind = clk * 1.10;           // slow horizontal drift
            // `cover` modulates how much sky the clouds fill; a slow weather-ish breathe
            // keeps the sky from being uniformly packed. Kept modest so the sky still reads.
            // #140 bolder presence: raise the coverage floor so the puffs read as solid toy
            // cumulus (chunky, opaque cores) rather than thin translucent wisps, which also
            // masks the faint radial sampling ringing under solid cloud. Still breathes so the
            // sky is not uniformly packed.
            float cover = 0.62 + 0.14 * (sin(clk * (3.14159265 / 90.0)) * 0.5 + 0.5);
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
                    float a = clamp(d * 1.6 * clamp(stepRef, 0.5, 2.0), 0.0, 1.0);
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
        float3 skyCol = evalSkyColor(ray, su.sunDirTime.xyz, su.sunDirTime.w, wu.wallClockSecs, wu.cloudsOn, in.position.xy);

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
    // #119 VOLUMETRIC GOD RAYS — shadow-map raymarch helpers
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
    constant int   GR_STEPS   = 80;   // #147: up from 64 for finer sampling (less grain to denoise)
    constant float GR_MAXDIST = 140.0;
    constant float GR_DENSITY = 0.030;
    constant float GR_HG_G    = 0.88;

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
    constant float GR_FLOOR_LO    = 0.30;
    constant float GR_FLOOR_HI    = 0.95;
    constant float GR_SHAFT_GAMMA = 2.20;
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
    constant float GR_SHAFT_SHARP  = 1.7;
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
    constant float CEL_DEPTH_SENS   = 0.022;
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

    // Sun-lit test for one world-space god-ray step: march the SAME world occupancy
    // grid the terrain shadows use, from this step's world point toward the sun.
    // Returns 1 = lit, 0 = shadowed. Using the same voxel volume means the god-ray
    // occlusion matches the cast shadows exactly and the shadow map is fully retired.
    static float volShadowLit(texture3d<uint, access::read> occ,
                              texture3d<uint, access::read> coarse,
                              float3 gridOrigin, float3 gridDims,
                              float3 worldP, float3 toSun, float maxDist) {
        return marchSunOcclusion(occ, coarse, gridOrigin, gridDims, worldP, toSun, maxDist);
    }

    fragment float4 compositeFrag(FSVOut in [[stage_in]],
                                  texture2d<float> hdrTex   [[texture(0)]],
                                  texture2d<float> bloomTex [[texture(1)]],
                                  constant PostUniforms& pu [[buffer(0)]],
                                  constant VolUniforms&  vu [[buffer(1)]],
                                  depth2d<float, access::sample> sceneDepth [[texture(2)]],
                                  texture3d<uint, access::read> occ         [[texture(3)]],
                                  texture3d<uint, access::read> occCoarse   [[texture(4)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

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
            // Reconstruct this pixel's world position from depth (clip -> world).
            // FSVOut uv is Metal top-left; NDC y is flipped, z in [0,1] on Metal.
            float d = sceneDepth.sample(s, in.uv);
            float2 ndcXY = float2(in.uv.x * 2.0 - 1.0, (1.0 - in.uv.y) * 2.0 - 1.0);
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
            float stepLen  = marchLen / float(GR_STEPS);

            // toSun points from the scene toward the sun (sunDir points downward).
            float3 toSun = normalize(-vu.sunDir.xyz);
            float  cosT  = dot(viewDir, toSun);
            float  phase = hgPhase(cosT, GR_HG_G);

            // #141 BLUE-NOISE JITTER: the old jitter was fract(sin(dot(px,...))), a white-noise
            // hash whose value jumps randomly between neighbouring pixels, so the residual
            // banding turned into salt-and-pepper GRAIN in the shafts. Interleaved Gradient
            // Noise (Jimenez 2014) is a cheap blue-noise-like dither: its values are
            // well-distributed over any small pixel neighbourhood, so the per-pixel start
            // offsets are spread evenly and the eye reads the result as a smooth gradient
            // instead of grain. Same one-line cost, far cleaner shafts.
            float2 px = in.position.xy;
            float dither = fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715))));

            float farR      = vu.camPosW.w;
            float voxMaxDist = vu.voxOrigin.w;
            // Accumulate the LIT length and the TOTAL marched length separately, so the
            // raw signal is a lit FRACTION in [0,1] (how much of the air toward the sun
            // along this ray is sunlit). Normalising this way decouples the strength from
            // the ray length, so short ground rays and long sky rays are on the same
            // scale and a single threshold reads consistently.
            float litLen = 0.0, totLen = 0.0;
            // #147: keep the start jitter, but make it a small centred offset rather than
            // a full-step random shift. Full-step jitter removes bands but leaves visible
            // pixel variance after the steep shaft shaping; a small centred jitter still
            // breaks lockstep bands while feeding the denoise pass a calmer signal.
            float t = stepLen * (0.5 + (dither - 0.5) * 0.15);
            for (int i = 0; i < GR_STEPS; ++i) {
                float3 sp = camP + viewDir * t;
                float dc  = length(sp - camP);
                // Same world occupancy march as the cast shadows (no shadow map).
                float lit = volShadowLit(occ, occCoarse, vu.voxOrigin.xyz, vu.voxDims.xyz,
                                         sp, toSun, voxMaxDist);
                // Fade contribution out toward the coverage edge so no hard boundary
                // shows where the occupancy grid ends.
                float coverage = 1.0 - smoothstep(farR * 0.85, farR, dc);
                litLen += lit * coverage * stepLen;
                totLen += stepLen;
                t += stepLen;
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
            float shaftRaw = smoothstep(GR_FLOOR_LO, GR_FLOOR_HI, litFrac);
            float shaft    = pow(shaftRaw, GR_SHAFT_GAMMA);
            // #132 DISTINCT BEAMS: sharpen the shaft around its mid-value with a contrast
            // curve so the smooth in-scatter SEGMENTS into separated bright cores and dark
            // gaps — the player can point at the sun through trees and see real shafts, not a
            // broad warm glare. A logistic-ish contrast about 0.5 keeps it in [0,1] (cannot
            // raise the mean past the carved beams, so it cannot reintroduce a wash).
            shaft = clamp((shaft - 0.5) * GR_SHAFT_SHARP + 0.5, 0.0, 1.0);
            shaft *= shaft;   // square biases toward the cores: gaps go darker, beams stay
            float shaftQ = (shaft
                            + quad_shuffle_xor(shaft, 1u)
                            + quad_shuffle_xor(shaft, 2u)
                            + quad_shuffle_xor(shaft, 3u)) * 0.25;
            shaft = mix(shaft, clamp(shaftQ, 0.0, 1.0), 0.82);
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
                // #134 cheaper edge: a 3-tap forward-difference cross (centre + right + down)
                // replaces the 4-tap diagonal Roberts (5 depth samples + 5 linearizations →
                // 3 of each). The centre sample is already needed for the sky-skip and the
                // normalization, so this adds only two taps. The largest of the two forward
                // gaps still inks every silhouette boldly; visually indistinguishable from the
                // 4-tap cross at this thickness, at a noticeably lower per-pixel cost.
                float lR = celLinearizeDepth(sceneDepth.sample(s, in.uv + float2(texel.x, 0.0)));
                float lD = celLinearizeDepth(sceneDepth.sample(s, in.uv + float2(0.0, texel.y)));
                // Largest neighbour gap, normalised by centre distance so the sensitivity is
                // scale-free (a one-block ledge inks the same near and far).
                float g = max(abs(lc - lR), abs(lc - lD)) / max(lc, 1.0);
                // Smoothstep gate around CEL_DEPTH_SENS so the line antialiases instead of a
                // hard 1-px jaggy. Above ~2x the threshold it is a full-strength edge.
                float edge = smoothstep(CEL_DEPTH_SENS, CEL_DEPTH_SENS * 2.2, g);
                // Fade the ink in the far haze so the distant render edge does not get a
                // busy net of lines (keeps the vista readable, matches the terrain fog).
                float farFade = 1.0 - smoothstep(CEL_FAR * 0.6, CEL_FAR * 0.92, lc);
                // #136 scale the ink darkness by the cel-outline intensity slider (0..1).
                tonemapped *= (1.0 - edge * CEL_OUTLINE_DARK * pu.celOutlineStr * farFade);
            }
        }

        // Gamma: drawable is bgra8Unorm (no hardware sRGB), apply manual gamma 2.2.
        tonemapped = pow(clamp(tonemapped, 0.0, 1.0), float3(1.0 / 2.2));

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
    // Birds: large (~1 world unit), dark silhouette, drawn at fixed sky
    //        height — we skip depth testing effect by always writing to
    //        a far position, so they sit in the sky.
    // Fireflies: tiny emissive warm-green, HDR > 1, depth-tested so they
    //            hide behind terrain. They bloom via the existing bloom pass.
    // =========================================================

    struct ALVOut {
        float4 position [[position]];
        float4 color;    // rgba (HDR allowed)
        float2 uv;       // normalised quad UV (−1..1)
        uint   isBird [[flat]];  // 1=bird (screen-facing, no depth), 0=firefly
    };

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

        float size   = sp.posW.w;   // screen-space half-size in clip units
        float4 clipCenter = au.viewProj * float4(sp.posW.xyz, 1.0);

        // Billboard: offset in clip space so the quad always faces the camera.
        // We scale the offset by size / clipCenter.w to keep it view-independent.
        float screenSize = size / max(clipCenter.w, 0.001);
        float4 pos = clipCenter + float4(corner.x * screenSize,
                                          corner.y * screenSize * 1.5, // slight vertical stretch for birds
                                          0.0, 0.0);

        ALVOut o;
        o.position = pos;
        o.color    = sp.color;
        o.uv       = corner;
        // Determine bird vs firefly by size: birds have size > 0.5, fireflies < 0.5
        o.isBird   = (size > 0.5) ? 1u : 0u;
        return o;
    }

    fragment float4 ambientLifeFrag(ALVOut in [[stage_in]]) {
        // Soft circular mask (both birds and fireflies are round/dot)
        float d = dot(in.uv, in.uv);
        if (d > 1.0) discard_fragment();

        float alpha = in.color.a;

        if (in.isBird == 1u) {
            // Bird silhouette: simple V-wing shape using the UV.
            // Wing tips: |x| > |y|*1.5 → draw, else discard for the body gap.
            float wingMask = step(abs(in.uv.y) * 1.6, abs(in.uv.x));
            // Also mask off the inner part to make a V (not a full disc)
            float innerGap = 1.0 - step(abs(in.uv.y) * 0.6, d);
            float mask = wingMask * (1.0 - innerGap * 0.5);
            if (mask < 0.1) discard_fragment();
            // Soft edge
            float edge = 1.0 - smoothstep(0.60, 1.0, d);
            return float4(in.color.rgb * edge * mask, alpha * edge * mask);
        } else {
            // Firefly: gaussian glow dot.  Multiply out to HDR levels for bloom.
            float glow = exp(-d * 3.5);
            // Outer halo (broader, dimmer)
            float halo = exp(-d * 1.2) * 0.35;
            float total = glow + halo;
            return float4(in.color.rgb * total, alpha * total);
        }
    }

    // =========================================================
    // SUB-VOXEL PROPS (#51/#52) — detailed toy models for flowers / mushrooms /
    // crystals, GPU-INSTANCED: the CPU uploads only the tiny instance list and the
    // vertex shader expands each instance's model from a model table. No per-frame
    // geometry rebuild, so prop count is nearly free (scales to dense grass).
    // =========================================================
    struct PropUniforms { float4x4 viewProj; float4 params; };  // params.x = day brightness
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
    constant uint kPropMaxCuboids = 4u;   // model table stride per type
    constant uint kVertsPerShape  = 144u; // max verts per part (an 8x3 sphere)

    // #62: build a unit primitive (extent [-0.5,0.5]) from a local vertex id, as a
    // surface of revolution with 8 slices. shape: 1=sphere, 2=cone, 3=cylinder. Writes
    // the outward normal. Verts past the shape's own count are returned degenerate.
    static float3 propRevVert(uint lv, uint shape, thread float3& nrm) {
        const uint S = 8u;
        uint T = (shape == 1u) ? 3u : 1u;             // sphere: 3 stacks; cone/cyl: 1 side band
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
        bool isTrunk = (row == 14 || row == 15 || row == 17);
        uint cuboidIdx = vid / kVertsPerShape;
        if (row < 0 || cuboidIdx >= kPropMaxCuboids) { o.position = float4(0); o.nrm = float3(0); o.col = float3(0); return o; }
        PropCuboid cu = models[uint(row) * kPropMaxCuboids + cuboidIdx];
        float3 half_ = float3(cu.half_);
        if (half_.x == 0.0 && half_.y == 0.0 && half_.z == 0.0) { o.position = float4(0); o.nrm = float3(0); o.col = float3(0); return o; } // unused slot

        // #62: choose the part's primitive. 0=box (cube face table), else a surface of
        // revolution (sphere/cone/cylinder).
        uint shape = uint(cu.shape + 0.5);
        float3 cpos, cnrm;
        uint lv = vid % kVertsPerShape;
        if (shape == 0u) {
            if (lv >= 36u) { o.position = float4(0); o.nrm = float3(0); o.col = float3(0); return o; }
            uint face = lv / 6u, corner = kTriIdx[lv % 6u];
            cpos = kFaceCorner[face * 4u + corner];
            cnrm = kFaceNrm[face];
        } else {
            cpos = propRevVert(lv, shape, cnrm);
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
        // #68 clustering: grass (row 4) and berry bush (row 6) grow bigger where many of
        // the same kind are packed together (density in the seed's top nibble), so a patch
        // reads as one merged clump and shrinks as you break pieces. A lone plant = normal.
        if (row == 4 || row == 6) {
            float dens = float((inst.seed >> 28u) & 0xFu);   // 0..8 same-kind neighbours
            float gscale = 1.0 + dens * 0.13;                // up to ~2x in a packed patch
            lp.x = 0.5 + (lp.x - 0.5) * gscale;
            lp.z = 0.5 + (lp.z - 0.5) * gscale;
            lp.y *= gscale;                                  // taller from the ground up
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
        o.position = u.viewProj * float4(world, 1.0);
        o.nrm = nm;
        // flat colour, drained by region saturation, scaled by day brightness
        float3 base = float3(cu.color);
        // Per-instance variety: flower blooms (rows 0/1, cuboid 1) take a palette
        // colour by seed; every prop gets a small brightness jitter so clumps of
        // grass/flowers don't look stamped from one mould.
        if ((row == 0 || row == 1) && cuboidIdx == 1u) base = kFlowerPalette[inst.seed % 6u];
        if (row == 2 && cuboidIdx == 1u) base = kMushroomPalette[inst.seed % 4u];  // mushroom cap variety
        // #62: foliage gets a per-puff green/gold hue shift so the canopy is mottled
        // and natural rather than one flat green.
        if (row == 12 || row == 13) {
            float gv = float(inst.seed % 7u) / 6.0;     // 0..1
            base *= float3(0.90 + 0.16 * gv, 0.97 + 0.07 * gv, 0.86 + 0.06 * gv);
        }
        base *= 0.90 + 0.20 * (float((inst.seed >> 5u) & 255u) / 255.0);
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

// (ShadowVertUniforms removed: the shadow-map render pass is retired in favour of
//  world-space voxel sun shadows.)

// MARK: - Ambient sprite POD (matches MSL AmbientSprite, 32 bytes)
/// 32 bytes per sprite, written by Swift, read by MSL ambientLifeVert.
struct AmbientSpritePod {
    var posW:    SIMD4<Float>   // xyz = world pos, w = size (screen-space radius)
    var color:   SIMD4<Float>   // rgb = HDR colour (>1 allowed for bloom), a = alpha
}

// MARK: - Precipitation particle POD (matches MSL PrecipParticle, 16 bytes)
/// One per particle. seed = a stable per-particle offset within the spawn box +
/// a phase, written ONCE at init; the vertex shader derives the animated world
/// position from it each frame (no per-frame CPU update — cheap & recycling-free).
struct PrecipParticlePod {
    var seed: SIMD4<Float>   // xyz = offset within box [-0.5..0.5]^3, w = per-particle phase 0..1
}

// MARK: - Offscreen render self-test (CI: proves terrain pixels actually draw)

func runRenderSelfTest(savePath: String? = nil, width: Int = 320, height: Int = 240) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return false }
    let queue = device.makeCommandQueue()!
    let registry = BufferRegistry(device: device)

    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else {
        print("shader compile failed"); return false
    }

    // ---- Build terrain pipeline (renders into rgba16Float then composited) ---
    let pdesc = MTLRenderPipelineDescriptor()
    pdesc.vertexFunction   = lib.makeFunction(name: "vmain")
    pdesc.fragmentFunction = lib.makeFunction(name: "fmain")
    pdesc.colorAttachments[0].pixelFormat = .rgba16Float
    pdesc.depthAttachmentPixelFormat = .depth32Float
    guard let terrainPipeline = try? device.makeRenderPipelineState(descriptor: pdesc) else {
        print("terrain pipeline failed"); return false
    }
    let dsd = MTLDepthStencilDescriptor()
    dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)

    // Sky pipeline
    let spdesc = MTLRenderPipelineDescriptor()
    spdesc.vertexFunction   = lib.makeFunction(name: "skyVmain")
    spdesc.fragmentFunction = lib.makeFunction(name: "skyFmain")
    spdesc.colorAttachments[0].pixelFormat = .rgba16Float
    spdesc.depthAttachmentPixelFormat = .depth32Float
    let skyPipeline = try? device.makeRenderPipelineState(descriptor: spdesc)
    let sdsd = MTLDepthStencilDescriptor()
    sdsd.depthCompareFunction = .always; sdsd.isDepthWriteEnabled = false
    let skyDepthState = device.makeDepthStencilState(descriptor: sdsd)

    // World-space voxel shadows: no shadow-map pipeline in the offscreen test.

    // Composite pipeline
    let cpdesc = MTLRenderPipelineDescriptor()
    cpdesc.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
    cpdesc.fragmentFunction = lib.makeFunction(name: "compositeFrag")
    cpdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
    let compositePipeline = try? device.makeRenderPipelineState(descriptor: cpdesc)

    let nodd = MTLDepthStencilDescriptor()
    nodd.depthCompareFunction = .always; nodd.isDepthWriteEnabled = false
    let noDepthState = device.makeDepthStencilState(descriptor: nodd)

    let entR = EntityRenderer(device: device, colorFormat: .rgba16Float)

    // Engine
    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION; cfg.role = BF_ROLE_SINGLEPLAYER; cfg.start_mode = BF_MODE_CREATIVE
    cfg.content_dir = persistentCString("."); cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_rt")
    cfg.player_name = persistentCString("ci")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { print("engine create"); return false }
    defer { bf_engine_destroy(e) }
    var alloc = bf_gpu_allocator()
    alloc.user = Unmanaged.passUnretained(registry).toOpaque()
    alloc.alloc = allocTrampoline; alloc.free_ = freeTrampoline
    _ = bf_set_gpu_allocator(e, &alloc)
    _ = bf_world_new(e, 1)

    let W = width, H = height
    let HW = max(1, W/2), HH = max(1, H/2)

    func makeTex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage, priv: Bool = true) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage
        td.storageMode = priv ? .private : .shared
        return device.makeTexture(descriptor: td)!
    }

    let hdrColor   = makeTex(.rgba16Float,  W, H, usage: [.renderTarget, .shaderRead])
    let hdrDepth   = makeTex(.depth32Float, W, H, usage: [.renderTarget, .shaderRead])   // #119 readable for composite
    let bloomBrt   = makeTex(.rgba16Float,  HW, HH, usage: [.renderTarget, .shaderRead])
    let bloomBlurA = makeTex(.rgba16Float,  HW, HH, usage: [.renderTarget, .shaderRead])
    // Final readable output
    let output = makeTex(.bgra8Unorm, W, H, usage: [.renderTarget], priv: false)

    var rendered = false

    for f in 0..<64 {
        registry.currentFrame = f
        var input = bf_frame_input()
        // Stream chunks in normally for the first frames, then fast-forward the
        // day clock to golden hour so the screenshot shows long cast shadows and
        // warm low-angle light (a representative, flattering scene).
        let dt = f < 24 ? 1.0/60.0 : 6.0
        _ = bf_frame_begin(e, &input, dt)
        var frame = bf_render_frame()
        _ = bf_frame_acquire_render(e, &frame)

        let proj = Renderer.perspective(fovy: 1.20, aspect: Float(W)/Float(H), near: 0.05, far: 512)
        let viewM = Renderer.mat(frame.camera.view)
        let viewProj = proj * viewM
        let sun = frame.camera.sun_dir

        // Real angled sun + camera for the shadow matrix, so the screenshot is
        // representative of gameplay (not a flat overhead-sun scene).
        let vt = viewM.columns.3
        let camPosW = SIMD3<Float>(
            -(viewM.columns.0.x*vt.x + viewM.columns.1.x*vt.y + viewM.columns.2.x*vt.z),
            -(viewM.columns.0.y*vt.x + viewM.columns.1.y*vt.y + viewM.columns.2.y*vt.z),
            -(viewM.columns.0.z*vt.x + viewM.columns.1.z*vt.y + viewM.columns.2.z*vt.z))
        let camFwdST = SIMD3<Float>(-viewM.columns.0.z, -viewM.columns.1.z, -viewM.columns.2.z)
        _ = camPosW

        guard let cmd = queue.makeCommandBuffer() else { bf_frame_end(e); continue }

        // World-space voxel shadows: pull the engine occupancy grid into a 3D texture.
        let shadowVol = harnessUploadShadowVolume(device, e)

        // --- HDR scene pass ---
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdrColor
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.3, green: 0.12, blue: 0.22, alpha: 1)
        rp.depthAttachment.texture = hdrDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.storeAction = .dontCare

        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            // Sky
            if let sp = skyPipeline {
                enc.setRenderPipelineState(sp)
                enc.setDepthStencilState(skyDepthState)
                enc.setCullMode(.none)
                let cr = SIMD3<Float>(viewM.columns.0.x, viewM.columns.1.x, viewM.columns.2.x)
                let cu = SIMD3<Float>(viewM.columns.0.y, viewM.columns.1.y, viewM.columns.2.y)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    camRight: SIMD4<Float>(cr.x, cr.y, cr.z, 0.6841),
                    camUp:    SIMD4<Float>(cu.x, cu.y, cu.z, Float(W)/Float(H)),
                    camFwd:   SIMD4<Float>(camFwdST.x, camFwdST.y, camFwdST.z, 0))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: Float(f)/60.0, underwater: 0.0)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            // Terrain
            enc.setRenderPipelineState(terrainPipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
            var wu = WaterUniforms(wallClockSecs: Float(f)/60.0, underwater: 0.0,
                                   cameraPosW: SIMD4<Float>(camPosW.x, camPosW.y, camPosW.z, 0))
            wu.shadowScale = (shadowVol != nil) ? 1.0 : 0.0   // world-space voxel shadows
            wu.sunDirTime = SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day)
            if let sv = shadowVol { wu.voxOrigin = sv.voxOrigin; wu.voxDims = sv.voxDims }
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            if let sv = shadowVol { enc.setFragmentTexture(sv.tex, index: 0); enc.setFragmentTexture(sv.coarse, index: 1) }  // world occupancy grid + coarse
            var windST = WindUniforms(wallClockSecs: Float(f)/60.0, rainStrength: 0)
            enc.setVertexBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setFragmentBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
            for i in 0..<Int(frame.draw_count) {
                let d = frame.draws[i]
                guard d.index_count > 0,
                      let vb = registry.lookup(d.vertex_buffer),
                      let ib = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(
                    viewProj: viewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, frame.camera.time_of_day),
                    lightViewProj: matrix_identity_float4x4,
                    dimSatN: SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ib,
                                          indexBufferOffset: Int(d.index_offset))
                rendered = true
            }
            enc.setDepthStencilState(depthState)
            entR.encode(enc, viewProj: viewProj, entities: frame.entities, count: Int(frame.entity_count))
            enc.endEncoding()
        }

        // --- Bloom bright-pass (HDR → half-res) ---
        if let bpPipeline = try? { () throws -> MTLRenderPipelineState in
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
            d.fragmentFunction = lib.makeFunction(name: "bloomBrightFrag")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: d)
        }() {
            let brp = MTLRenderPassDescriptor()
            brp.colorAttachments[0].texture = bloomBrt
            brp.colorAttachments[0].loadAction = .dontCare
            brp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: brp) {
                enc.setRenderPipelineState(bpPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // --- Blur H ---
        if let bhPipeline = try? { () throws -> MTLRenderPipelineState in
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
            d.fragmentFunction = lib.makeFunction(name: "bloomBlurHFrag")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: d)
        }() {
            let brp = MTLRenderPassDescriptor()
            brp.colorAttachments[0].texture = bloomBlurA
            brp.colorAttachments[0].loadAction = .dontCare
            brp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: brp) {
                enc.setRenderPipelineState(bhPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(bloomBrt, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // --- Blur V → back into bloomBrt ---
        if let bvPipeline = try? { () throws -> MTLRenderPipelineState in
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction   = lib.makeFunction(name: "fullscreenVert")
            d.fragmentFunction = lib.makeFunction(name: "bloomBlurVFrag")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: d)
        }() {
            let brp = MTLRenderPassDescriptor()
            brp.colorAttachments[0].texture = bloomBrt
            brp.colorAttachments[0].loadAction = .dontCare
            brp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: brp) {
                enc.setRenderPipelineState(bvPipeline)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(bloomBlurA, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        // --- Composite → bgra8 output ---
        if let cp = compositePipeline {
            let crp = MTLRenderPassDescriptor()
            crp.colorAttachments[0].texture = output
            crp.colorAttachments[0].loadAction = .dontCare
            crp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: crp) {
                enc.setRenderPipelineState(cp)
                enc.setDepthStencilState(noDepthState)
                enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor,  index: 0)
                enc.setFragmentTexture(bloomBrt,  index: 1)
                enc.setFragmentTexture(hdrDepth,  index: 2)   // #119 (raymarch off in this test path)
                if let sv = shadowVol { enc.setFragmentTexture(sv.tex, index: 3); enc.setFragmentTexture(sv.coarse, index: 4) }  // world occupancy grid + coarse
                var pu = PostUniforms(bloomStrength: 0.12, vignetteStr: 0.22, satBoost: 1.18,
                                      rainStrength: 0, wallClockSecs: Float(f)/60.0)
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                var vu = VolUniforms()   // #119 volStrength = 0 -> raymarch is a no-op
                enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        cmd.commit(); cmd.waitUntilCompleted()
        bf_frame_end(e); registry.collect()
    }
    guard rendered else { print("no draws encoded"); return false }

    // Read back from composite output (bgra8)
    var px = [UInt8](repeating: 0, count: W*H*4)
    output.getBytes(&px, bytesPerRow: W*4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    let clear = (0.30, 0.12, 0.22)
    var terrain = 0
    for p in stride(from: 0, to: px.count, by: 4) {
        let b = Double(px[p])/255, g = Double(px[p+1])/255, r = Double(px[p+2])/255
        let dist = abs(r-clear.0) + abs(g-clear.1) + abs(b-clear.2)
        if dist > 0.15 { terrain += 1 }
    }
    let frac = Double(terrain) / Double(W*H)
    print(String(format: "OK: render self-test — %.1f%% of pixels are terrain (drew chunk meshes)", frac*100))

    if let path = savePath {
        var rgba = [UInt8](repeating: 0, count: W*H*4)
        for i in stride(from: 0, to: px.count, by: 4) {
            rgba[i] = px[i+2]; rgba[i+1] = px[i+1]; rgba[i+2] = px[i]; rgba[i+3] = 255
        }
        rgba.withUnsafeMutableBytes { raw in
            var planes: [UnsafeMutablePointer<UInt8>?] = [raw.bindMemory(to: UInt8.self).baseAddress]
            if let rep = NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: W, pixelsHigh: H,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: W*4, bitsPerPixel: 32),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote screenshot: \(path)")
            }
        }
    }
    return frac > 0.05
}

// MARK: - Washout regression test (#33)
// Negative test for the recurring "turn toward the sun and the whole frame washes
// out" bug. Renders the FULL gameplay pipeline (sky + terrain → bloom → ACES
// composite, with the gameplay PostUniforms) over real streamed terrain, sweeping
// the camera through a full 360° yaw at several sun elevations / times of day. At
// each step it measures the fraction of "washed" pixels — bright AND desaturated
// (near-white) — in the final image. Facing away from the sun this is tiny; a
// washout spikes it. The test FAILS if any direction/time exceeds the threshold,
// so a future change that re-breaks the sun shading is caught automatically.
func runWashoutTest() -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { print("SKIP: washout test (no Metal device)"); return true }
    let queue = device.makeCommandQueue()!
    let registry = BufferRegistry(device: device)
    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else {
        print("shader compile failed"); return false
    }
    func pipe(_ vfn: String, _ ffn: String, _ fmt: MTLPixelFormat, depth: Bool) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: vfn); d.fragmentFunction = lib.makeFunction(name: ffn)
        d.colorAttachments[0].pixelFormat = fmt
        if depth { d.depthAttachmentPixelFormat = .depth32Float }
        return try? device.makeRenderPipelineState(descriptor: d)
    }
    guard let skyPipe = pipe("skyVmain", "skyFmain", .rgba16Float, depth: true),
          let terrPipe = pipe("vmain", "fmain", .rgba16Float, depth: true),
          let brightPipe = pipe("fullscreenVert", "bloomBrightFrag", .rgba16Float, depth: false),
          let blurHPipe = pipe("fullscreenVert", "bloomBlurHFrag", .rgba16Float, depth: false),
          let blurVPipe = pipe("fullscreenVert", "bloomBlurVFrag", .rgba16Float, depth: false),
          let compPipe = pipe("fullscreenVert", "compositeFrag", .bgra8Unorm, depth: false)
    else { print("pipeline build failed"); return false }

    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)
    let sdsd = MTLDepthStencilDescriptor(); sdsd.depthCompareFunction = .always; sdsd.isDepthWriteEnabled = false
    let skyDepthState = device.makeDepthStencilState(descriptor: sdsd)
    let nodd = MTLDepthStencilDescriptor(); nodd.depthCompareFunction = .always; nodd.isDepthWriteEnabled = false
    let noDepthState = device.makeDepthStencilState(descriptor: nodd)

    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION; cfg.role = BF_ROLE_SINGLEPLAYER; cfg.start_mode = BF_MODE_CREATIVE
    cfg.content_dir = persistentCString("."); cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_wt")
    cfg.player_name = persistentCString("ci")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { print("engine create"); return false }
    defer { bf_engine_destroy(e) }
    var alloc = bf_gpu_allocator()
    alloc.user = Unmanaged.passUnretained(registry).toOpaque()
    alloc.alloc = allocTrampoline; alloc.free_ = freeTrampoline
    _ = bf_set_gpu_allocator(e, &alloc)
    _ = bf_world_new(e, 1)

    let W = 320, H = 240, HW = W/2, HH = H/2
    func makeTex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ shared: Bool) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: td)!
    }
    let hdrColor = makeTex(.rgba16Float, W, H, [.renderTarget, .shaderRead], false)
    let hdrDepth = makeTex(.depth32Float, W, H, [.renderTarget, .shaderRead], false)   // #119 readable for composite binding
    // #119 a comparison sampler so compositeFrag has sampler(0) (god rays are off here).
    let vsd = MTLSamplerDescriptor(); vsd.compareFunction = .lessEqual
    let washoutVolSampler = device.makeSamplerState(descriptor: vsd)!
    let bloomBrt = makeTex(.rgba16Float, HW, HH, [.renderTarget, .shaderRead], false)
    let bloomBlurA = makeTex(.rgba16Float, HW, HH, [.renderTarget, .shaderRead], false)
    let output = makeTex(.bgra8Unorm, W, H, [.renderTarget], true)

    // Stream terrain in so the sweep renders a real scene (not empty sky).
    var camEye = SIMD3<Float>(0, 48, 0)
    for f in 0..<64 {
        registry.currentFrame = f
        var input = bf_frame_input()
        _ = bf_frame_begin(e, &input, f < 48 ? 1.0/60.0 : 2.0)
        var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
        let vm = Renderer.mat(fr.camera.view); let vt = vm.columns.3
        camEye = SIMD3<Float>(
            -(vm.columns.0.x*vt.x + vm.columns.1.x*vt.y + vm.columns.2.x*vt.z),
            -(vm.columns.0.y*vt.x + vm.columns.1.y*vt.y + vm.columns.2.y*vt.z),
            -(vm.columns.0.z*vt.x + vm.columns.1.z*vt.y + vm.columns.2.z*vt.z))
        bf_frame_end(e); registry.collect()
    }

    let proj = Renderer.perspective(fovy: 1.20, aspect: Float(W)/Float(H), near: 0.05, far: 512)
    let tanHalf = tan(0.60) as Float
    func lookView(_ eye: SIMD3<Float>, _ fwd: SIMD3<Float>, _ up: SIMD3<Float>) -> simd_float4x4 {
        let s = normalize(cross(fwd, up)); let u = cross(s, fwd)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -fwd.x, 0),
            SIMD4<Float>(s.y, u.y, -fwd.y, 0),
            SIMD4<Float>(s.z, u.z, -fwd.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(fwd, eye), 1)))
    }

    // Scenarios: (label, sun elevation°, time_of_day). The sun sits toward +X
    // (azimuth 0); the yaw sweep therefore faces it at yaw≈0.
    // tod is chosen so the dawn/dusk cases land on the sunset PEAK (t≈0.25 / 0.78),
    // where the orange haze + sun glow terms are strongest — that's the user's "as
    // night came in" directional brightening, which earlier low-but-not-sunset times
    // (0.06/0.10) never exercised.
    // NOTE: the gameplay sun arcs LOW — sun_dir.y = -sin(ang)-0.25 peaks at only ~20°
    // elevation at noon, so the sun sits in-frame at eye level all day when you face
    // its azimuth. Earlier scenarios used a 70° "noon" (overhead, out of frame) and
    // never reproduced the daytime washout. These match the real arc.
    // Night scenarios (sun BELOW the horizon, elevation < 0) catch the night whiteout:
    // a view-dependent over-brightness that only shows when the sun has set. The earlier
    // sweep stopped at +7° (sun still up) so true night was never exercised; a sun-only
    // specular that glows at night, or a view-keyed sky/reflection term, would slip past.
    // tod is set so dayLight()==0 (full night) for these.
    let scenarios: [(String, Float, Float)] = [
        ("midday",    20, 0.50),
        ("morning",   16, 0.36),
        ("afternoon", 14, 0.64),
        ("dawn",      10, 0.25),
        ("dusk",       7, 0.78),
        ("nightfall", -6, 0.84),
        ("midnight", -20, 0.75),
    ]
    let yawSteps = 24
    var worstWash: Double = 0, worstAt = ""
    var awayWash: Double = 0   // reference: wash when facing AWAY from the sun
    // Directional brightening ("the light thing"): the scene's overall brightness
    // must not jump when you turn toward the sun's azimuth — this catches a COLOURED
    // glow (e.g. the orange dusk cone) that the bright+desaturated metric misses.
    var maxLumaDelta: Double = 0, maxLumaDeltaAt = ""

    for (label, elevDeg, tod) in scenarios {
        let E = elevDeg * Float.pi / 180
        let toward = SIMD3<Float>(cos(E), sin(E), 0)     // direction toward the sun
        let sd = -toward                                  // sun_dir: from sun into scene
        let lookP = min(E, 18 * Float.pi / 180)           // pitch up toward the sun a bit
        var scMinLuma = 2.0, scMaxLuma = 0.0              // mean-luma spread across yaws
        for yi in 0..<yawSteps {
            let phi = 2 * Float.pi * Float(yi) / Float(yawSteps)
            let fwd = normalize(SIMD3<Float>(cos(phi) * cos(lookP), sin(lookP), sin(phi) * cos(lookP)))
            let view = lookView(camEye, fwd, SIMD3<Float>(0, 1, 0))
            let viewProj = proj * view
            let cr = SIMD3<Float>(view.columns.0.x, view.columns.1.x, view.columns.2.x)
            let cu = SIMD3<Float>(view.columns.0.y, view.columns.1.y, view.columns.2.y)

            registry.currentFrame = 64 + yi
            var input = bf_frame_input()
            _ = bf_frame_begin(e, &input, 1.0/60.0)
            var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
            guard let cmd = queue.makeCommandBuffer() else { bf_frame_end(e); continue }

            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = hdrColor
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            rp.depthAttachment.texture = hdrDepth
            rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0
            rp.depthAttachment.storeAction = .dontCare
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(skyPipe); enc.setDepthStencilState(skyDepthState); enc.setCullMode(.none)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sd.x, sd.y, sd.z, tod),
                    camRight: SIMD4<Float>(cr.x, cr.y, cr.z, tanHalf),
                    camUp:    SIMD4<Float>(cu.x, cu.y, cu.z, Float(W)/Float(H)),
                    camFwd:   SIMD4<Float>(fwd.x, fwd.y, fwd.z, 0))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: 0, underwater: 0)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

                enc.setRenderPipelineState(terrPipe); enc.setDepthStencilState(depthState)
                enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
                var wu = WaterUniforms(wallClockSecs: 0, underwater: 0, cameraPosW: SIMD4<Float>(camEye.x, camEye.y, camEye.z, 0))
                enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
                var windST = WindUniforms(wallClockSecs: 0, rainStrength: 0)
                enc.setVertexBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
                enc.setFragmentBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
                for i in 0..<Int(fr.draw_count) {
                    let d = fr.draws[i]
                    guard d.index_count > 0, let vb = registry.lookup(d.vertex_buffer), let ib = registry.lookup(d.index_buffer) else { continue }
                    var u = Uniforms(
                        viewProj: viewProj,
                        chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                        sunDirTime: SIMD4<Float>(sd.x, sd.y, sd.z, tod),
                        lightViewProj: matrix_identity_float4x4,
                        dimSatN: SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                    enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                              indexType: .uint32, indexBuffer: ib, indexBufferOffset: Int(d.index_offset))
                }
                enc.endEncoding()
            }
            // Bloom bright → blurH → blurV (into bloomBrt), then ACES composite.
            func fsPass(_ p: MTLRenderPipelineState, _ inTex: MTLTexture, _ outTex: MTLTexture) {
                let d = MTLRenderPassDescriptor()
                d.colorAttachments[0].texture = outTex; d.colorAttachments[0].loadAction = .dontCare; d.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: d) {
                    enc.setRenderPipelineState(p); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                    enc.setFragmentTexture(inTex, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
                }
            }
            fsPass(brightPipe, hdrColor, bloomBrt)
            fsPass(blurHPipe, bloomBrt, bloomBlurA)
            fsPass(blurVPipe, bloomBlurA, bloomBrt)
            // Composite with the SAME PostUniforms gameplay uses (bloomStrength 0.08).
            let crp = MTLRenderPassDescriptor()
            crp.colorAttachments[0].texture = output; crp.colorAttachments[0].loadAction = .dontCare; crp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: crp) {
                enc.setRenderPipelineState(compPipe); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor, index: 0); enc.setFragmentTexture(bloomBrt, index: 1)
                enc.setFragmentTexture(hdrDepth, index: 2)   // occupancy grid (index 3) unread when volStrength 0
                enc.setFragmentSamplerState(washoutVolSampler, index: 0)
                var pu = PostUniforms(bloomStrength: 0.08, vignetteStr: 0.22, satBoost: 1.18, rainStrength: 0, wallClockSecs: 0)
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                var vu = VolUniforms()   // #119 volStrength = 0 -> raymarch is a no-op in this test path
                enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
            }
            cmd.commit(); cmd.waitUntilCompleted()
            bf_frame_end(e); registry.collect()

            // Measure washed pixels: bright (luma>0.82) AND desaturated (sat<0.18).
            var px = [UInt8](repeating: 0, count: W*H*4)
            output.getBytes(&px, bytesPerRow: W*4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            var washed = 0
            var lumaSum = 0.0
            for p in stride(from: 0, to: px.count, by: 4) {
                let b = Double(px[p])/255, g = Double(px[p+1])/255, r = Double(px[p+2])/255
                let luma = 0.2126*r + 0.7152*g + 0.0722*b
                lumaSum += luma
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let sat = mx > 0.001 ? (mx - mn) / mx : 0
                if luma > 0.82 && sat < 0.18 { washed += 1 }
            }
            let frac = Double(washed) / Double(W*H)
            let meanLuma = lumaSum / Double(W*H)
            if meanLuma < scMinLuma { scMinLuma = meanLuma }
            if meanLuma > scMaxLuma { scMaxLuma = meanLuma }
            // yaw≈0 faces the sun; yaw≈π faces away (reference).
            if yi == 0 {
                print(String(format: "  %@: sun-facing washed %.1f%%", label, frac*100))
                if ProcessInfo.processInfo.environment["WASH_SAVE"] != nil {
                    var rgba = [UInt8](repeating: 255, count: W*H*4)
                    for i in stride(from: 0, to: px.count, by: 4) { rgba[i]=px[i+2]; rgba[i+1]=px[i+1]; rgba[i+2]=px[i] }
                    rgba.withUnsafeMutableBytes { raw in
                        var planes: [UnsafeMutablePointer<UInt8>?] = [raw.bindMemory(to: UInt8.self).baseAddress]
                        if let rep = NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: W, pixelsHigh: H,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                            colorSpaceName: .deviceRGB, bytesPerRow: W*4, bitsPerPixel: 32),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/wash_\(label).png"))
                        }
                    }
                }
            }
            if yi == yawSteps/2 { awayWash = max(awayWash, frac) }
            if frac > worstWash { worstWash = frac; worstAt = "\(label)@yaw\(Int(phi*180/Float.pi))°" }
        }
        let delta = scMaxLuma - scMinLuma
        print(String(format: "    %@: mean-luma yaw range %.1f%%..%.1f%% (Δ %.1f%%)",
                     label, scMinLuma*100, scMaxLuma*100, delta*100))
        if delta > maxLumaDelta { maxLumaDelta = delta; maxLumaDeltaAt = label }
    }
    // #33 cave-darkness: when the eye is underground (camFwd.w = 1), the sky must be
    // dark in EVERY direction. Surface-priority streaming doesn't load the far
    // underground, so the sky shows through those gaps; without the underground fade
    // it bled the bright, sun-directional daytime sky into a "pitch black" cave —
    // bright toward E/W, dark at N/S, as the player turned. Render sky-only (the gap)
    // underground at a low, bright sun and assert it stays dark at all yaws.
    var caveMaxLuma = 0.0
    do {
        let E = 12 * Float.pi / 180
        let sd = -SIMD3<Float>(cos(E), sin(E), 0)        // bright low sun toward +X
        for yi in 0..<yawSteps {
            let phi = 2 * Float.pi * Float(yi) / Float(yawSteps)
            let fwd = normalize(SIMD3<Float>(cos(phi), 0, sin(phi)))
            let view = lookView(camEye, fwd, SIMD3<Float>(0, 1, 0))
            let cr = SIMD3<Float>(view.columns.0.x, view.columns.1.x, view.columns.2.x)
            let cu = SIMD3<Float>(view.columns.0.y, view.columns.1.y, view.columns.2.y)
            guard let cmd = queue.makeCommandBuffer() else { continue }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = hdrColor
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rp.colorAttachments[0].storeAction = .store
            rp.depthAttachment.texture = hdrDepth
            rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = .dontCare
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(skyPipe); enc.setDepthStencilState(skyDepthState); enc.setCullMode(.none)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sd.x, sd.y, sd.z, 0.10),
                    camRight: SIMD4<Float>(cr.x, cr.y, cr.z, tanHalf),
                    camUp:    SIMD4<Float>(cu.x, cu.y, cu.z, Float(W)/Float(H)),
                    camFwd:   SIMD4<Float>(fwd.x, fwd.y, fwd.z, 1.0))   // underground = 1
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: 0, underwater: 0)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
            }
            let crp = MTLRenderPassDescriptor()
            crp.colorAttachments[0].texture = output; crp.colorAttachments[0].loadAction = .dontCare; crp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: crp) {
                enc.setRenderPipelineState(compPipe); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor, index: 0); enc.setFragmentTexture(hdrColor, index: 1)
                enc.setFragmentTexture(hdrDepth, index: 2)   // occupancy grid (index 3) unread when volStrength 0
                enc.setFragmentSamplerState(washoutVolSampler, index: 0)
                var pu = PostUniforms(bloomStrength: 0.0, vignetteStr: 0.22, satBoost: 1.18, rainStrength: 0, wallClockSecs: 0)
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                var vu = VolUniforms()   // #119 volStrength = 0 -> raymarch is a no-op in this test path
                enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
            }
            cmd.commit(); cmd.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: W*H*4)
            output.getBytes(&px, bytesPerRow: W*4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            for p in stride(from: 0, to: px.count, by: 4) {
                let b = Double(px[p])/255, g = Double(px[p+1])/255, r = Double(px[p+2])/255
                let luma = 0.2126*r + 0.7152*g + 0.0722*b
                if luma > caveMaxLuma { caveMaxLuma = luma }
            }
        }
    }

    // NIGHT RELIEF-SPECULAR GATE (regression guard for the #47/#105 sun sheen at night).
    // The full-scene night sweep above is viewed top-down over flat terrain (top faces,
    // dot(N,sun)<0) and the night ambient (in.shade≈0.15) crushes the term, so the scene
    // cannot exercise the worst case: a WALL turned toward the sun's azimuth after the sun
    // has set. Ld=normalize(-sunDir) points DOWN once the sun is below the horizon, so such
    // a wall scored a big dot(pN,Ld) and pow()'d into a glint AT NIGHT. This mirrors the
    // exact fmain formula on the CPU for that worst case and asserts the sun-above gate
    // kills it. A day reference (sun up) must keep a healthy glint so the fix only touches
    // night. Deterministic; no scene/streaming confound.
    func smoothstepF(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
    func reliefSpec(sunDirY: Float, wallToward sx: Float) -> Float {
        // Worst-case: perturbed normal == the wall normal, pointing toward the sun azimuth.
        let pN = SIMD3<Float>(sx, 0, 0)
        let sunDir = SIMD3<Float>(-sx * abs(sx), sunDirY, 0)   // sun behind the wall's facing dir
        let Ld = simd_normalize(-sunDir)
        // Same gate the shader uses: smoothstep(0.0, -0.12, sunDir.y); 1 sun up, 0 sun set.
        let sunAbove = smoothstepF(0.0, -0.12, sunDirY)
        let base = pow(max(0, simd_dot(pN, Ld)), 18.0)
        return base * sunAbove
    }
    // Sun WELL up (sunDir.y = -0.30): the sheen must still fire (fix preserves daytime).
    let dayGlint   = reliefSpec(sunDirY: -0.30, wallToward: 1.0)
    // Sun SET (sunDir.y = +0.34, the midnight value): the sheen must be ~0 (the fix).
    let nightGlint = reliefSpec(sunDirY:  0.34, wallToward: 1.0)
    let specGateOK = dayGlint > 0.05 && nightGlint < 0.001
    print(String(format: "    night-spec gate: day glint %.3f (want >0.05), night glint %.3f (want ~0): %@",
                 dayGlint, nightGlint, specGateOK ? "OK" : "FAIL"))

    let thresh = 0.30, caveThresh = 0.30, deltaThresh = 0.12
    let pass = worstWash < thresh && caveMaxLuma < caveThresh && maxLumaDelta < deltaThresh && specGateOK
    print(String(format: "%@ washout test — worst washed %.1f%% (%@); turn-brightening Δluma %.1f%% (%@, max %.0f%%); cave sky max-luma %.0f%%",
                 pass ? "OK:" : "FAIL:", worstWash*100, worstAt, maxLumaDelta*100, maxLumaDeltaAt, deltaThresh*100, caveMaxLuma*100))
    return pass
}

// MARK: - Headless self-test (CI, no display) — unchanged boundary check

func runHeadlessSelfTest() -> Bool {
    guard bf_abi_version() == BF_ABI_VERSION else { return false }
    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION
    cfg.role = BF_ROLE_SINGLEPLAYER
    cfg.start_mode = BF_MODE_SURVIVAL
    cfg.content_dir = persistentCString(".")
    cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_selftest")
    cfg.player_name = persistentCString("ci")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { return false }
    defer { bf_engine_destroy(e) }
    guard bf_world_new(e, 7) == BF_OK else { return false }
    for _ in 0..<5 {
        var input = bf_frame_input()
        guard bf_frame_begin(e, &input, 1.0 / 60.0) == BF_OK else { return false }
        var frame = bf_render_frame()
        guard bf_frame_acquire_render(e, &frame) == BF_OK else { return false }
        if frame.hud.health != 20.0 { return false }
        bf_frame_end(e)
    }
    print("OK: swift<->c++ self-test (5 frames, hud populated)")
    return true
}
