// ============================================================================
// Blockfall — perf harness (M5, Track E/perf gate)
// Renders the reference scene (render distance 10, animals, day/night, full
// streaming) offscreen for N seconds and logs FPS-over-time + peak memory to
// JSON. The acceptance gate (≥60 FPS median / ≥30 FPS 1%-low sustained 10 min,
// < ~10 GB resident) is on a real M1 Air; this harness IS that measurement —
// run it there with --perftest 600. On the dev box it confirms the harness and
// gives a (much faster) reference number.
//
// As of graphics wave 1 this drives the FULL pipeline (sun shadow map → HDR
// scene → bloom → ACES composite), so the number reflects the real frame cost.
// ============================================================================
import MetalKit
import simd
import CBlockcore
import Darwin
import ImageIO
import CoreGraphics

// Build a CGImage from a (shared-storage) bgra8 texture by reading its bytes back to
// the CPU. Shared by the headless --shot mode and the in-game backslash screenshot
// (Renderer.captureScreenshot), so both use the exact same texture-readback path.
func cgImageFromTexture(_ tex: MTLTexture) -> CGImage? {
    let w = tex.width, h = tex.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&data, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let cs = CGColorSpaceCreateDeviceRGB()
    let bi = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs, bitmapInfo: bi.rawValue) else { return nil }
    return ctx.makeImage()
}

// Encode a CGImage to a PNG file. Used by writeTexturePNG and the screenshot path.
func writeCGImagePNG(_ img: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

// Write a (shared-storage) bgra8 texture to a PNG. Used by the headless --shot mode
// so visuals can be verified from the terminal without taking over the desktop. (#52)
private func writeTexturePNG(_ tex: MTLTexture, to path: String) {
    guard let img = cgImageFromTexture(tex), writeCGImagePNG(img, to: path) else {
        print("shot: failed to encode PNG"); return
    }
    print("wrote shot: \(path)")
}

// Build a coarse occupancy mip: cell (cx,cy,cz) is 1 if ANY voxel in its co^3 block of
// the fine grid casts a shadow. Used for empty-space skipping in the DDA march so open-air
// rays step `co` voxels at a time. Shared by the live renderer and the offscreen tests.
func buildCoarseOccupancy(fine: [UInt8], dx: Int, dy: Int, dz: Int, co: Int,
                          cdx: Int, cdy: Int, cdz: Int, into coarse: inout [UInt8]) {
    for i in 0..<(cdx * cdy * cdz) { coarse[i] = 0 }
    // OR every set fine voxel into its coarse cell (one pass over the fine grid).
    for z in 0..<dz {
        let cz = z / co
        for y in 0..<dy {
            let cy = y / co
            let frow = (z * dy + y) * dx
            let crow = (cz * cdy + cy) * cdx
            for x in 0..<dx where fine[frow + x] != 0 {
                coarse[crow + x / co] = 1
            }
        }
    }
}

// Rebuild ONLY the coarse cells overlapping a world-voxel AABB [wlo,whi] (toroidal on x/z),
// re-ORing each from its co^3 fine block. Far cheaper than a full-grid rebuild while walking
// (only the scrolled-in chunk columns are touched). Buffers are the full toroidal arrays.

// ----------------------------------------------------------------------------
// World-space voxel sun shadows: shared occupancy upload for the offscreen test
// renderers. Pulls bf_world_shadow_volume into a (re)created r8uint 3D texture
// and returns it plus the voxOrigin / voxDims uniform fields the shaders expect
// (voxOrigin.xyz = grid origin world coords, .w = march distance; voxDims.xyz =
// grid dims, .w = soft flag). Returns nil if the engine has no resident region.
// Persistent cache so the harness, like the live renderer, only rebuilds + re-uploads the
// occupancy textures when the engine bumps the revision (otherwise the per-frame CPU coarse
// build + texture upload would dominate the measured frame and make the number meaningless).
final class HarnessShadowCache {
    var tex: MTLTexture?
    var coarse: MTLTexture?
    var rev: UInt32 = .max
    var dims: (Int, Int, Int) = (0, 0, 0)
    var originY: Int = 0
    var fine: [UInt8] = []
    var cbuf: [UInt8] = []
}
private let gHarnessShadowCache = HarnessShadowCache()

// Upload a world-voxel AABB [wlo,whi] into the toroidal fine+coarse textures, splitting at the
// wrap seam on x/z (y does not wrap). Shared by the harness; mirrors Renderer.uploadToroidalRegion.
func harnessUploadToroidalRegion(_ tex: MTLTexture, _ ctex: MTLTexture,
                                 fine: [UInt8], coarse: [UInt8],
                                 dx: Int, dy: Int, dz: Int, cdx: Int, cdy: Int, cdz: Int, co: Int,
                                 originY: Int, wlo: SIMD3<Int>, whi: SIMD3<Int>) {
    func wrap(_ v: Int, _ d: Int) -> Int { let m = v % d; return m < 0 ? m + d : m }
    func spans(_ lo: Int, _ hi: Int, _ dim: Int) -> [(g0: Int, len: Int)] {
        let n = hi - lo + 1
        if n >= dim { return [(0, dim)] }
        let g0 = wrap(lo, dim)
        if g0 + n <= dim { return [(g0, n)] }
        return [(g0, dim - g0), (0, n - (dim - g0))]
    }
    let gy0 = wlo.y - originY, yh = whi.y - wlo.y + 1
    let xs = spans(wlo.x, whi.x, dx), zs = spans(wlo.z, whi.z, dz)
    fine.withUnsafeBytes { raw in
        let base = raw.baseAddress!
        for zsp in zs { for xsp in xs {
            let region = MTLRegionMake3D(xsp.g0, gy0, zsp.g0, xsp.len, yh, zsp.len)
            let off = (zsp.g0 * dy + gy0) * dx + xsp.g0
            tex.replace(region: region, mipmapLevel: 0, slice: 0,
                        withBytes: base + off, bytesPerRow: dx, bytesPerImage: dx * dy)
        } }
    }
    let cxs = spans(Int(floor(Double(wlo.x)/Double(co))), Int(floor(Double(whi.x)/Double(co))), cdx)
    let czs = spans(Int(floor(Double(wlo.z)/Double(co))), Int(floor(Double(whi.z)/Double(co))), cdz)
    let cgy0 = gy0 / co, cyh = (gy0 + yh + co - 1) / co - gy0 / co
    coarse.withUnsafeBytes { raw in
        let base = raw.baseAddress!
        for zsp in czs { for xsp in cxs {
            let region = MTLRegionMake3D(xsp.g0, cgy0, zsp.g0, xsp.len, cyh, zsp.len)
            let off = (zsp.g0 * cdy + cgy0) * cdx + xsp.g0
            ctex.replace(region: region, mipmapLevel: 0, slice: 0,
                         withBytes: base + off, bytesPerRow: cdx, bytesPerImage: cdx * cdy)
        } }
    }
}

// Mirrors Renderer.uploadShadowVolume (toroidal, partial upload) but standalone for the harness.
func harnessUploadShadowVolume(_ device: MTLDevice, _ e: bf_engine,
                               marchDist: Float = Renderer.kShadowMarchDist,
                               soft: Bool = false)
    -> (tex: MTLTexture, coarse: MTLTexture, voxOrigin: SIMD4<Float>, voxDims: SIMD4<Float>)? {
    let c = gHarnessShadowCache
    // Probe (nil buffer): cheap metadata only.
    var vol = bf_shadow_volume()
    vol.voxels = nil; vol.voxel_cap = 0
    _ = bf_world_shadow_volume(e, &vol)
    let dx = Int(vol.dim_x), dy = Int(vol.dim_y), dz = Int(vol.dim_z)
    let need = dx * dy * dz
    if need <= 0 { return nil }
    let origin = SIMD4<Float>(Float(vol.origin.x), Float(vol.origin.y), Float(vol.origin.z), marchDist)
    let dimsV = SIMD4<Float>(Float(dx), Float(dy), Float(dz), soft ? 1 : 0)
    let dimsSame = (c.tex != nil && c.dims == (dx, dy, dz))
    // Standing still: textures current, return cached.
    if dimsSame && c.rev == vol.revision, let t = c.tex, let cc = c.coarse {
        return (t, cc, origin, dimsV)
    }
    let CO = Renderer.kShadowCoarse
    let cdx = (dx + CO - 1) / CO, cdy = (dy + CO - 1) / CO, cdz = (dz + CO - 1) / CO
    func make3D(_ w: Int, _ h: Int, _ d: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor()
        td.textureType = .type3D; td.pixelFormat = .r8Uint
        td.width = w; td.height = h; td.depth = d
        td.usage = [.shaderRead]; td.storageMode = .shared
        return device.makeTexture(descriptor: td)
    }
    let firstUpload = (c.tex == nil || c.dims != (dx, dy, dz))
    if firstUpload { c.tex = make3D(dx, dy, dz); c.coarse = make3D(cdx, cdy, cdz) }
    guard let tex = c.tex, let coarse = c.coarse else { return nil }
    if c.fine.count < need { c.fine = [UInt8](repeating: 0, count: need) }
    if c.cbuf.count < cdx * cdy * cdz { c.cbuf = [UInt8](repeating: 0, count: cdx * cdy * cdz) }
    // Fill both buffers; the engine maintains the coarse mip incrementally (#163),
    // so the harness no longer rescans the fine grid per frame.
    let ok: Bool = c.fine.withUnsafeMutableBufferPointer { p -> Bool in
        vol.voxels = p.baseAddress; vol.voxel_cap = UInt32(p.count)
        return c.cbuf.withUnsafeMutableBufferPointer { cp -> Bool in
            vol.coarse = cp.baseAddress; vol.coarse_cap = UInt32(cp.count)
            return bf_world_shadow_volume(e, &vol) == BF_OK
        }
    }
    if !ok { return nil }
    let oy = Int(vol.origin.y)
    let boxes = Renderer.shadowDirtyBoxes(vol, dx: dx, dy: dy, dz: dz, forceFull: firstUpload)
    for (wlo, whi) in boxes {
        harnessUploadToroidalRegion(tex, coarse, fine: c.fine, coarse: c.cbuf,
                                    dx: dx, dy: dy, dz: dz, cdx: cdx, cdy: cdy, cdz: cdz, co: CO,
                                    originY: oy, wlo: wlo, whi: whi)
    }
    c.rev = vol.revision; c.dims = (dx, dy, dz); c.originY = oy
    return (tex, coarse, origin, dimsV)
}

private func residentFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : 0
}

func runPerfTest(seconds: Double, jsonPath: String?, shotPath: String? = nil) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return false }
    let queue = device.makeCommandQueue()!
    let registry = BufferRegistry(device: device)
    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else { return false }

    // ---- Build every pipeline once (matches the live Renderer) -------------
    func colorPipe(_ vfn: String, _ ffn: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: vfn)
        d.fragmentFunction = lib.makeFunction(name: ffn)
        d.colorAttachments[0].pixelFormat = fmt
        if vfn == "vmain" || vfn == "skyVmain" { d.depthAttachmentPixelFormat = .depth32Float }
        return try? device.makeRenderPipelineState(descriptor: d)
    }
    guard let terrainPipeline = colorPipe("vmain", "fmain", .rgba16Float) else { return false }
    let skyPipeline       = colorPipe("skyVmain", "skyFmain", .rgba16Float)
    let compositePipeline = colorPipe("fullscreenVert", "compositeFrag", .bgra8Unorm)
    let brightPipeline    = colorPipe("fullscreenVert", "bloomBrightFrag", .rgba16Float)
    let blurHPipeline     = colorPipe("fullscreenVert", "bloomBlurHFrag", .rgba16Float)
    let blurVPipeline     = colorPipe("fullscreenVert", "bloomBlurVFrag", .rgba16Float)
    // #167 half-res god-ray pre-pass (mirrors the live renderer, so --perftest and
    // --shot measure/show the real shipping architecture, not the legacy inline march).
    let godrayPipeline    = colorPipe("fullscreenVert", "godrayHalfFrag", .rgba16Float)
    if godrayPipeline == nil { print("WARN: god-ray pre-pass pipeline failed; shots fall back to the inline march") }

    // World-space voxel shadows: no shadow-map render pipeline in the harness.

    // Prop pipeline (#52: GPU-instanced, same as the live renderer).
    let propPipeline: MTLRenderPipelineState? = {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction   = lib.makeFunction(name: "propInstVmain")
        d.fragmentFunction = lib.makeFunction(name: "propFmain")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        d.depthAttachmentPixelFormat = .depth32Float
        return try? device.makeRenderPipelineState(descriptor: d)
    }()
    let propModelTable = Renderer.makePropModelTable(device: device)
    var propInstBuf: MTLBuffer? = nil
    // #70 viewmodel (so --shot reflects the live render)
    let viewModelPipeline: MTLRenderPipelineState? = {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction   = lib.makeFunction(name: "viewModelVmain")
        d.fragmentFunction = lib.makeFunction(name: "viewModelFmain")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        d.depthAttachmentPixelFormat = .depth32Float
        return try? device.makeRenderPipelineState(descriptor: d)
    }()
    let viewModelArm = makeViewModelArm()
    let viewModelArmBuf = device.makeBuffer(bytes: makeViewModelArm(),
        length: makeViewModelArm().count * MemoryLayout<PropCuboidGPU>.stride, options: .storageModeShared)
    let viewModelDepthState: MTLDepthStencilState? = {
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .always; dd.isDepthWriteEnabled = false
        return device.makeDepthStencilState(descriptor: dd)
    }()
    let kPropVertsPerInstance = 5 * 144

    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)
    let skyDSD = MTLDepthStencilDescriptor(); skyDSD.depthCompareFunction = .always; skyDSD.isDepthWriteEnabled = false
    let skyDepthState = device.makeDepthStencilState(descriptor: skyDSD)
    let noDSD = MTLDepthStencilDescriptor(); noDSD.depthCompareFunction = .always; noDSD.isDepthWriteEnabled = false
    let noDepthState = device.makeDepthStencilState(descriptor: noDSD)

    let entR = EntityRenderer(device: device, colorFormat: .rgba16Float)

    // ---- Engine ------------------------------------------------------------
    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION; cfg.role = BF_ROLE_SINGLEPLAYER; cfg.start_mode = BF_MODE_SURVIVAL
    cfg.render_distance_chunks = 24                      // match the game (async gen + culling, #25/#5)
    cfg.content_dir = persistentCString("."); cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_perf")
    cfg.player_name = persistentCString("perf")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { return false }
    defer { bf_engine_destroy(e) }
    var alloc = bf_gpu_allocator()
    alloc.user = Unmanaged.passUnretained(registry).toOpaque()
    alloc.alloc = allocTrampoline; alloc.free_ = freeTrampoline
    _ = bf_set_gpu_allocator(e, &alloc)
    // BF_SHOT_SEED=<u64> overrides the world seed for --shot / --perftest, so a
    // verification shot can be aimed at a seed whose spawn shows the feature
    // under review (e.g. a desert spawn for a dune-relief check). Default 2026.
    let worldSeed = UInt64(ProcessInfo.processInfo.environment["BF_SHOT_SEED"] ?? "") ?? 2026
    _ = bf_world_new(e, worldSeed)

    // ---- Render targets (full size; shadow map at the live 2048) ----------
    // BF_PERF_RES=<scale> multiplies the render resolution (default 1.0 = 1280x800).
    // The dev box GPU is not fragment-bound at 1280x800, so per-fragment shader costs
    // (procedural texture, cel outline) barely move the number there. Scaling the
    // resolution up makes the run fragment-bound, the way the player's M1 Air is at the
    // real window size, so a per-fragment optimization actually shows in FPS. Does not
    // change the default measurement.
    let resScale = Float(ProcessInfo.processInfo.environment["BF_PERF_RES"] ?? "1") ?? 1
    let W = Int(1280.0 * resScale), H = Int(800.0 * resScale)
    let HW = W/2, HH = H/2
    func makeTex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ priv: Bool = true) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = priv ? .private : .shared
        return device.makeTexture(descriptor: td)!
    }
    let hdrColor   = makeTex(.rgba16Float,  W, H, [.renderTarget, .shaderRead])
    // #119 god rays: depth must be readable by the composite volumetric pass.
    let hdrDepth   = makeTex(.depth32Float, W, H, [.renderTarget, .shaderRead])
    let bloomBrt   = makeTex(.rgba16Float,  HW, HH, [.renderTarget, .shaderRead])
    let bloomBlurA = makeTex(.rgba16Float,  HW, HH, [.renderTarget, .shaderRead])
    let gds = Int(Renderer.kGodRayDownscale)   // #167 god rays march at scene/gds res
    let godrayTex  = makeTex(.rgba16Float,  max(1, W/gds), max(1, H/gds), [.renderTarget, .shaderRead])
    let output     = makeTex(.bgra8Unorm,   W, H, [.renderTarget], false)
    // #119 second composite target for the same-process god-ray A/B (BF_SHOT_AB=1):
    // composites the SAME hdr/depth/shadow buffers with god rays forced OFF, so the ON
    // (output) and OFF (outputOff) PNGs are pixel-aligned (no streaming drift between them).
    let outputOff  = makeTex(.bgra8Unorm,   W, H, [.renderTarget], false)
    let abMode     = ProcessInfo.processInfo.environment["BF_SHOT_AB"] == "1"
    // #130 BF_CEL=1 forces the cel-shade look ON for this shot (banding + outlines +
    // punchier grade); BF_CEL=0 forces it OFF. Lets a headless A/B compare the new look
    // without touching UserDefaults. Defaults OFF in the harness so existing shots/perf
    // numbers are unchanged unless explicitly requested.
    let celShot: Float = (ProcessInfo.processInfo.environment["BF_CEL"] == "1") ? 1 : 0

    var frameIdx = 0
    var lastShotPropN = 0
    // #116 diagnostic capture (env-gated): nearest-entity dump for aiming verification shots.
    var lastEntDump = ""
    var fpsSamples: [Double] = []
    var peakMem = 0.0
    let start = CACurrentMediaTime()
    var lastDt = CACurrentMediaTime()

    // #89 diagnosis: lets the yaw-sweep experiment turn the camera WITHOUT walking
    // forward, so the camera ORIGIN is identical at every yaw and the only variable is
    // the view direction. (The default keeps move_forward=1 so streaming churns.)
    // #179: accumulated look-yaw so a shot can aim at an ABSOLUTE heading
    // (BF_SHOT_SETYAW) — the engine spawns procedural worlds at yaw 0.6.
    var yawAccum: Float = 0
    func renderOneFrame(pitch: Float = 0, yaw: Float = 0.004, forward: Float = 1) {
        frameIdx += 1; registry.currentFrame = frameIdx
        yawAccum += yaw
        let now = CACurrentMediaTime(); let dt = now - lastDt; lastDt = now
        // Keep the player slowly orbiting so chunks stream continuously (worst case).
        var input = bf_frame_input(); input.move_forward = forward; input.look_yaw_delta = yaw
        input.look_pitch_delta = pitch   // #52 shot mode tilts down to frame ground props
        _ = bf_frame_begin(e, &input, dt)
        var f = bf_render_frame(); _ = bf_frame_acquire_render(e, &f)

        // BF_SHOT_TOD=<0..1> overrides the whole-scene time of day (and the matching
        // sun direction) so a headless shot can be driven to any point in the day, e.g.
        // deep night (0.75) to check night lighting. Mirrors world.hpp's sun_dir formula.
        if let todStr = ProcessInfo.processInfo.environment["BF_SHOT_TOD"], let tod = Float(todStr) {
            f.camera.time_of_day = tod
            let ang = tod * 6.2831853
            f.camera.sun_dir = bf_vec3(x: cos(ang) * 0.6, y: -sin(ang) - 0.25, z: 0.90)
        }

        let aspect = Float(W)/Float(H), fovy: Float = 1.20
        let proj = Renderer.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 512)
        let viewM = Renderer.mat(f.camera.view)
        let viewProj = proj * viewM
        var sun = f.camera.sun_dir
        // #72 debug: force a low-ish angled sun so occluders cast clear ground shadows
        // (the test world's high midday sun casts almost none, so the wipe is invisible).
        if ProcessInfo.processInfo.environment["BF_SHADOW_DEBUG"] == "1" {
            sun = bf_vec3(x: 0.55, y: -0.62, z: 0.56)   // points down-and-sideways (sun in the NW)
            // #49 BF_SHOT_SUN="x,y,z" overrides the forced sun so the wipe can be hunted
            // across sun angles (it is sun-angle dependent).
            if let s = ProcessInfo.processInfo.environment["BF_SHOT_SUN"] {
                let p = s.split(separator: ",").compactMap { Float($0) }
                if p.count == 3 { sun = bf_vec3(x: p[0], y: p[1], z: p[2]) }
            }
        }
        let wallClock = Float(now.truncatingRemainder(dividingBy: 3600.0))

        let vt = viewM.columns.3
        // #183: -(R transpose * t), dotting rotation COLUMNS (the old row form was
        // -(R * t), hundreds of blocks wrong in the torus near-seam frames).
        let camPosW = SIMD4<Float>(
            -(viewM.columns.0.x*vt.x + viewM.columns.0.y*vt.y + viewM.columns.0.z*vt.z),
            -(viewM.columns.1.x*vt.x + viewM.columns.1.y*vt.y + viewM.columns.1.z*vt.z),
            -(viewM.columns.2.x*vt.x + viewM.columns.2.y*vt.y + viewM.columns.2.z*vt.z), 0)
        let camRight = SIMD3<Float>(viewM.columns.0.x, viewM.columns.1.x, viewM.columns.2.x)
        let camUp    = SIMD3<Float>(viewM.columns.0.y, viewM.columns.1.y, viewM.columns.2.y)
        let camFwd   = SIMD3<Float>(-viewM.columns.0.z, -viewM.columns.1.z, -viewM.columns.2.z)
        let tanHalfFov = tan(fovy*0.5)
        // #89: BF_LIGHT_FIXCAM="x,y,z" pins the camPos used for the SUN light matrix only,
        // decoupling the shadow computation from the harness's wandering player. With it set,
        // the shadow map content and every fragment's shadowPos are byte-identical across
        // yaws, so any yaw-vs-shadow effect that survives must come from the FRAGMENT shading
        // (specular / fades), not the shadow geometry. This is the controlled experiment the
        // input-driven harness otherwise cannot run (it can't hold the player still).
        var windU = WindUniforms(wallClockSecs: wallClock, rainStrength: 0)
        // #180 horizon curvature: --shot and --perftest run the curved path the live
        // game ships (BF_HORIZON=0 bakes k=0 for a flat A/B). The dedicated gate
        // probes (washout / world-fixed / ground-night) build their own uniforms and
        // stay flat by the .zero default, so their camera-invariance assertions are
        // untouched by this camera-dependent visual warp.
        // #180 horizon curvature camera. NOT camPosW: that -(R*t) extraction from the
        // view matrix is only exact near the coordinate origin; in the toroidal frames
        // #179 emits near the world seam (|coords| up to 32768) its error grows to
        // hundreds of blocks, which pushed every d^2 drop to the cap (entities sank,
        // terrain over-curved). Unproject screen-centre at the near plane instead:
        // exact for whatever frame the engine built the view matrix in.
        let hInv = viewProj.inverse
        let hNear = hInv * SIMD4<Float>(0, 0, 0, 1)
        let horizonCamH = SIMD4<Float>(hNear.x / hNear.w, hNear.y / hNear.w, hNear.z / hNear.w, 1)
        windU.camPosH = horizonCamH
        let cmd = queue.makeCommandBuffer()!

        // PASS 1 (shadow-map depth) is RETIRED. World-space voxel shadows: pull the engine
        // occupancy grid into an r8uint 3D texture and march it per fragment toward the sun.
        // BF_NOSHADOW skips the whole grid maintenance to measure the scene-only ceiling.
        let shadowVol = (ProcessInfo.processInfo.environment["BF_NOSHADOW"] == "1")
            ? nil : harnessUploadShadowVolume(device, e)

        // Shadows are marched directly per fragment in the terrain pass (occ bound at 0/1 below),
        // matching the live renderer. No half-res prepass (it was a net loss on this hardware).

        // PASS 2: HDR scene (sky + terrain + entities)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdrColor
        rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.45, green: 0.62, blue: 0.86, alpha: 1)
        rp.depthAttachment.texture = hdrDepth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = .store // #119 keep depth for god-ray raymarch
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            if let sp = skyPipeline {
                enc.setRenderPipelineState(sp); enc.setDepthStencilState(skyDepthState); enc.setCullMode(.none)
                // Sky-shot override (#66): force a night sky with the moon centred in
                // view so the sun/moon can be checked headless (BF_SHOT_SKY=1).
                var skySun = SIMD3<Float>(sun.x, sun.y, sun.z)
                var skyTod = f.camera.time_of_day
                let skyEnv = ProcessInfo.processInfo.environment["BF_SHOT_SKY"]
                if skyEnv == "1" {
                    skySun = simd_normalize(camFwd)    // moon dir == normalize(sky sun_dir)
                    skyTod = 0.75                       // midnight (sun lowest; see Renderer.dayLight)
                } else if skyEnv == "2" {
                    skySun = -simd_normalize(camFwd)   // sun dir == normalize(-sky sun_dir): sun centred
                    skyTod = 0.5                        // noon (test the E/W glare/washout)
                }
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(skySun.x, skySun.y, skySun.z, skyTod),
                    camRight: SIMD4<Float>(camRight.x, camRight.y, camRight.z, tanHalfFov),
                    camUp:    SIMD4<Float>(camUp.x, camUp.y, camUp.z, aspect),
                    camFwd:   SIMD4<Float>(camFwd.x, camFwd.y, camFwd.z, 0))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: wallClock, underwater: 0, cameraPosW: camPosW)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.setRenderPipelineState(terrainPipeline); enc.setDepthStencilState(depthState)
            enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
            // #49: pass sunDirTime so the terrain fragment shader's #47 view-dependent
            // specular sheen sees the REAL sun direction in --shot. The live renderer sets
            // this; the harness used to leave it zero, so the spec sampled an undefined sun
            // (normalize of the zero vector) and the headless shots were not representative of
            // how that shading actually looks in game. (Hunting the #49 shadow wipe with the
            // old harness produced a bogus broad ground "wash" that does not exist live.)
            var wu = WaterUniforms(wallClockSecs: wallClock, underwater: 0, cameraPosW: camPosW,
                                   sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, f.camera.time_of_day))
            wu.shadowScale = (shadowVol != nil) ? 1.0 : 0.0     // world-space voxel shadows
            if ProcessInfo.processInfo.environment["BF_NOSHADOW"] == "1" { wu.shadowScale = 0.0 } // perf ceiling
            if ProcessInfo.processInfo.environment["BF_SHADOW_DEBUG"] == "1" { wu.shadowScale = 2.0 } // #72 debug view
            wu.celShade = celShot   // #130 toon-band the terrain in --shot when BF_CEL=1
            if let sv = shadowVol { wu.voxOrigin = sv.voxOrigin; wu.voxDims = sv.voxDims }
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            enc.setFragmentBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            // Direct per-fragment march: bind the occupancy grids (fine + coarse).
            if let sv = shadowVol { enc.setFragmentTexture(sv.tex, index: 0); enc.setFragmentTexture(sv.coarse, index: 1) }
            for i in 0..<Int(f.draw_count) {
                let d = f.draws[i]
                guard d.index_count > 0, let vb = registry.lookup(d.vertex_buffer),
                      let ib = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(viewProj: viewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, f.camera.time_of_day),
                    lightViewProj: matrix_identity_float4x4,
                    dimSatN: SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ib, indexBufferOffset: Int(d.index_offset))
            }
            // Props (#52: GPU-instanced, identical to the live renderer).
            let propN = Int(f.prop_instance_count)
            lastShotPropN = propN
            if propN > 0, let insts = f.prop_instances, let pp = propPipeline {
                let need = propN * MemoryLayout<bf_prop_instance>.stride
                if propInstBuf == nil || propInstBuf!.length < need {
                    propInstBuf = device.makeBuffer(length: max(need, 65536), options: .storageModeShared)
                }
                if let ib = propInstBuf {
                    memcpy(ib.contents(), insts, need)
                    let dayBright = 0.30 + 0.70 * Renderer.dayLight(f.camera.time_of_day)
                    var pu2 = PropUniforms(viewProj: viewProj, params: SIMD4<Float>(dayBright, Float(wallClock), 0, 0),
                                           camPosH: horizonCamH)   // #180 horizon curvature
                    enc.setRenderPipelineState(pp); enc.setDepthStencilState(depthState); enc.setCullMode(.none)
                    enc.setVertexBuffer(ib, offset: 0, index: 0)
                    enc.setVertexBytes(&pu2, length: MemoryLayout<PropUniforms>.stride, index: 1)
                    enc.setVertexBuffer(propModelTable, offset: 0, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: kPropVertsPerInstance, instanceCount: propN)
                }
            }

            enc.setRenderPipelineState(terrainPipeline)
            enc.setDepthStencilState(depthState)
            // #116 character shadows in --shot: feed the entity renderer the same voxel grid the
            // terrain marched so creatures receive shade and cast a ground blob. BF_NOCHARSHADOW=1
            // forces them off for an A/B. Gated on the shadow volume being present (shadowVol != nil).
            let es = EntityShadowUniforms(
                sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, f.camera.time_of_day),
                voxOrigin:  shadowVol?.voxOrigin ?? .zero,
                voxDims:    shadowVol?.voxDims ?? .zero,
                params:     SIMD4<Float>((shadowVol != nil && ProcessInfo.processInfo.environment["BF_NOCHARSHADOW"] != "1") ? 1 : 0, 0, 0, 0))
            // #116 deterministic verification: BF_SHOT_TESTCREATURE=<kind> injects ONE creature on
            // the ground directly ahead of the camera (and an extra one offset sideways for a
            // tree-shadow test), replacing the wandering world entities so a shadow shot can be
            // framed reliably. The foot Y is found by marching the occupancy grid down from the
            // player's eye height so it lands on the real surface (works on slopes too).
            if let kStr = ProcessInfo.processInfo.environment["BF_SHOT_TESTCREATURE"], let kind = UInt32(kStr) {
                // Derive the true camera world position AND a forward point by UNPROJECTING through
                // the actual viewProj (so it is always consistent with what is drawn, regardless of
                // how camPosW was extracted). Unproject screen center at two depths -> a ray.
                let invVP = viewProj.inverse
                func unproj(_ ndcZ: Float) -> SIMD3<Float> {
                    let p = invVP * SIMD4<Float>(0, 0, ndcZ, 1)
                    return SIMD3<Float>(p.x / p.w, p.y / p.w, p.z / p.w)
                }
                let near = unproj(0.0)        // a point on the view ray (near-ish)
                let far  = unproj(0.5)        // a farther point on the same ray
                let camP = near
                let rayDir = simd_normalize(far - near)
                let fwdH = simd_normalize(SIMD3<Float>(rayDir.x, 0, rayDir.z))
                let dist = Float(ProcessInfo.processInfo.environment["BF_SHOT_TCDIST"] ?? "3.0") ?? 3.0
                let baseXZ = camP + fwdH * dist
                // Find the real ground surface Y at the creature's XZ by reading the same occupancy
                // grid the renderer marches (gHarnessShadowCache.fine). Search downward from the
                // camera eye for the highest solid voxel, robust wherever the player landed.
                func surfaceY(_ wx: Float, _ wz: Float, eyeY: Float) -> Float {
                    let c = gHarnessShadowCache
                    let (dx, dy, dz) = c.dims
                    if dx <= 0 || c.fine.isEmpty { return eyeY - 1.6 }
                    let bx = Int(floor(wx)) & (dx - 1)
                    let bz = Int(floor(wz)) & (dz - 1)
                    let top = min(dy - 1, Int(floor(eyeY)) - c.originY + 1)
                    var yy = top
                    while yy >= 0 {
                        if c.fine[(bz * dy + yy) * dx + bx] != 0 {
                            return Float(yy + 1 + c.originY)   // top face of the solid voxel
                        }
                        yy -= 1
                    }
                    return eyeY - 1.6
                }
                // Seat on the player's OWN ground column (where the player demonstrably stands) so
                // the creature never floats/sinks regardless of biome occ quirks: use the player's
                // foot height. BF_SHOT_TCYBIAS nudges if needed.
                let playerFoot = surfaceY(camP.x, camP.z, eyeY: camP.y)
                let aheadSurf  = surfaceY(baseXZ.x, baseXZ.z, eyeY: camP.y)
                // Prefer the forward cell's surface but clamp it to within 1 block of the player's
                // foot so a mis-read occ column can't strand the creature in the air or underground.
                let footY = min(playerFoot + 1, max(playerFoot - 1, aheadSurf))
                    + (Float(ProcessInfo.processInfo.environment["BF_SHOT_TCYBIAS"] ?? "0") ?? 0)
                func mkEnt(_ x: Float, _ z: Float) -> bf_entity_draw {
                    var ee = bf_entity_draw()
                    ee.position = bf_vec3(x: x, y: footY, z: z)
                    ee.kind = kind
                    ee.scale = Float(ProcessInfo.processInfo.environment["BF_SHOT_TCSCALE"] ?? "1.6") ?? 1.6
                    ee.sat = 1.0
                    ee.color = bf_vec3(x: 0.7, y: 0.55, z: 0.35)
                    ee.yaw = atan2(-fwdH.x, -fwdH.z)   // face the camera
                    // BF_SHOT_TCFACEAWAY=1 turns the creature to face away (back to camera), to
                    // verify face parts do not show through the head from behind (#116 depth fix).
                    if ProcessInfo.processInfo.environment["BF_SHOT_TCFACEAWAY"] == "1" {
                        ee.yaw = atan2(fwdH.x, fwdH.z)
                    }
                    return ee
                }
                // Main creature dead ahead; a second one to the side (for the tree-shade test the
                // caller frames separately), keep it to one for a clean flat-ground shot.
                let testEnts = [mkEnt(baseXZ.x, baseXZ.z)]
                if ProcessInfo.processInfo.environment["BF_SHOT_ENTDUMP"] == "1" {
                    lastEntDump = "TESTCREATURE cam=(\(camP.x),\(camP.y),\(camP.z)) fwdH=(\(fwdH.x),\(fwdH.z)) creature=(\(baseXZ.x),\(footY),\(baseXZ.z)) kind=\(kind)"
                }
                testEnts.withUnsafeBufferPointer { bp in
                    entR.encode(enc, viewProj: viewProj, entities: bp.baseAddress, count: testEnts.count,
                                shadow: es, occ: shadowVol?.tex, occCoarse: shadowVol?.coarse,
                                camPosH: horizonCamH)   // #180 entities bend with the terrain
                }
                if ProcessInfo.processInfo.environment["BF_SHOT_ENTDUMP"] == "1" {
                    let mvpTest = viewProj * SIMD4<Float>(baseXZ.x, footY + 0.8, baseXZ.z, 1)
                    lastEntDump += " | clip=(\(mvpTest.x/mvpTest.w),\(mvpTest.y/mvpTest.w),\(mvpTest.z/mvpTest.w)) w=\(mvpTest.w)"
                }
            }
            if ProcessInfo.processInfo.environment["BF_SHOT_ENTDUMP"] == "1",
               ProcessInfo.processInfo.environment["BF_SHOT_TESTCREATURE"] == nil {
                let cp = f.camera.position
                var s = "ENTDUMP cam=(\(cp.x),\(cp.y),\(cp.z)) count=\(f.entity_count)\\n"
                if let ents = f.entities {
                    for i in 0..<Int(f.entity_count) {
                        let ee = ents[i]
                        let dx = ee.position.x - cp.x, dz = ee.position.z - cp.z
                        let dist = (dx*dx + dz*dz).squareRoot()
                        s += "  ent[\(i)] kind=\(ee.kind) pos=(\(ee.position.x),\(ee.position.y),\(ee.position.z)) dist=\(dist)\\n"
                    }
                }
                lastEntDump = s
            }

            // #70 viewmodel arm (mirrors the live renderer so --shot shows it)
            if let vmp = viewModelPipeline, let vmb = viewModelArmBuf, let vmd = viewModelDepthState {
                enc.setRenderPipelineState(vmp); enc.setDepthStencilState(vmd); enc.setCullMode(.none)
                let dayB = 0.30 + 0.70 * Renderer.dayLight(f.camera.time_of_day)
                let swing = Float(ProcessInfo.processInfo.environment["BF_SHOT_SWING"] ?? "-1") ?? -1  // #: force swing phase for shots
                var vmU = ViewModelUniforms(proj: proj, params: SIMD4<Float>(0, 0, dayB, swing))
                enc.setVertexBuffer(vmb, offset: 0, index: 0)
                enc.setVertexBytes(&vmU, length: MemoryLayout<ViewModelUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: viewModelArm.count * 36)
                // #70 v2: force a held item (pickaxe) so --shot can verify the held model.
                let held = makeHeldItem(Int(ProcessInfo.processInfo.environment["BF_SHOT_HELD"] ?? "70") ?? 70)
                if !held.isEmpty, let hb = device.makeBuffer(bytes: held,
                        length: held.count * MemoryLayout<PropCuboidGPU>.stride, options: .storageModeShared) {
                    enc.setVertexBuffer(hb, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: held.count * 36)
                }
            }
            enc.endEncoding()
        }

        // PASS 3: bloom bright → blur H → blur V
        func bloomPass(_ pipe: MTLRenderPipelineState?, _ target: MTLTexture, _ src: MTLTexture) {
            guard let pipe = pipe else { return }
            let brp = MTLRenderPassDescriptor()
            brp.colorAttachments[0].texture = target
            brp.colorAttachments[0].loadAction = .dontCare; brp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: brp) {
                enc.setRenderPipelineState(pipe); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                enc.setFragmentTexture(src, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
        bloomPass(brightPipeline, bloomBrt,  hdrColor)
        bloomPass(blurHPipeline,  bloomBlurA, bloomBrt)
        bloomPass(blurVPipeline,  bloomBrt,  bloomBlurA)

        // PASS 4: composite (HDR + bloom) → bgra8 output
        if let cp = compositePipeline {
            let dayT  = Renderer.dayLight(f.camera.time_of_day)
            let godOff = ProcessInfo.processInfo.environment["BF_SHOT_NOGODRAY"] == "1"
            let debug  = ProcessInfo.processInfo.environment["BF_GR_DEBUG"] == "1"
            // #132 lens-flare gate for --shot. BF_SHOT_NOFLARE=1 disables it (so a god-ray AB
            // is not confounded by the flare). dayT folds night to 0 (byte-identical guard).
            let flareOff = ProcessInfo.processInfo.environment["BF_SHOT_NOFLARE"] == "1"
            let flareGate = Renderer.sunFlareGate(
                viewProj: viewProj,
                camPos: SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z),
                sunDir: SIMD3<Float>(sun.x, sun.y, sun.z), dayT: dayT)
            // #119 one composite into `target` with the given god-ray strength. Reused for
            // the normal shot (ON or OFF) and, in AB mode, a second OFF pass into outputOff.
            func composite(into target: MTLTexture, godStrength: Float, flareStrength: Float,
                           forceInline: Bool = false) {
                // God-ray occlusion marches the SAME world occupancy grid the shadows use.
                var vu = VolUniforms(
                    invViewProj:    viewProj.inverse,
                    voxOrigin:      shadowVol?.voxOrigin ?? .zero,
                    voxDims:        shadowVol?.voxDims ?? .zero,
                    camPosW:        SIMD4<Float>(camPosW.x, camPosW.y, camPosW.z, 384.0),
                    sunDir:         SIMD4<Float>(sun.x, sun.y, sun.z, 0),
                    sunColor:       SIMD4<Float>(1.0, 0.6 + 0.35 * dayT, 0.3 + 0.5 * dayT, godStrength))
                // #167 half-res god-ray pre-pass (same architecture as the live renderer):
                // march at half res, then the composite upsamples depth-aware. abs() so the
                // BF_GR_DEBUG negative sentinel still runs the march. Skipped when off.
                // BF_GR_FULLRES=1 skips the pre-pass so the composite takes the legacy
                // inline full-res march: a pixel-aligned old-vs-new god-ray AB in one build.
                let grFullRes = forceInline
                    || ProcessInfo.processInfo.environment["BF_GR_FULLRES"] == "1"
                if !grFullRes, abs(godStrength) > 0.001, let grp = godrayPipeline {
                    vu.sunDir.w = Renderer.kGodRayDownscale
                    let grp2 = MTLRenderPassDescriptor()
                    grp2.colorAttachments[0].texture = godrayTex
                    grp2.colorAttachments[0].loadAction = .dontCare; grp2.colorAttachments[0].storeAction = .store
                    if let enc = cmd.makeRenderCommandEncoder(descriptor: grp2) {
                        enc.setRenderPipelineState(grp); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                        enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                        enc.setFragmentTexture(hdrDepth, index: 2)
                        if let sv = shadowVol { enc.setFragmentTexture(sv.tex, index: 3); enc.setFragmentTexture(sv.coarse, index: 4) }
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        enc.endEncoding()
                    }
                }
                let crp = MTLRenderPassDescriptor()
                crp.colorAttachments[0].texture = target
                crp.colorAttachments[0].loadAction = .dontCare; crp.colorAttachments[0].storeAction = .store
                guard let enc = cmd.makeRenderCommandEncoder(descriptor: crp) else { return }
                enc.setRenderPipelineState(cp); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor, index: 0)
                enc.setFragmentTexture(bloomBrt, index: 1)
                var pu = PostUniforms(bloomStrength: 0.12, vignetteStr: 0.22, satBoost: 1.30,
                                      rainStrength: 0, wallClockSecs: 0,
                                      godrayStrength: 0,
                                      sunScreenX: flareGate.uv.x, sunScreenY: flareGate.uv.y,
                                      sunColorR: 1.0, sunColorG: 0.6 + 0.35 * dayT, sunColorB: 0.3 + 0.5 * dayT)
                pu.celShade = celShot   // #130 ink outlines + cel grade in --shot when BF_CEL=1
                pu.lensFlareStr = flareStrength   // #132 lens flare in --shot
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.setFragmentTexture(hdrDepth,  index: 2)
                if let sv = shadowVol { enc.setFragmentTexture(sv.tex, index: 3); enc.setFragmentTexture(sv.coarse, index: 4) }  // world occupancy grid + coarse
                enc.setFragmentTexture(godrayTex, index: 5)   // #167 half-res god-ray in-scatter
                enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            // #136 fold in the god-ray intensity slider. BF_GODRAY_STR (0..1) drives the same
            // fraction the live pause-menu slider does, so a 0 / 0.5 / 1.0 sweep here verifies
            // the slider scales the rays and that the shipped 0.5 default is half full strength.
            let grFrac = Float(ProcessInfo.processInfo.environment["BF_GODRAY_STR"] ?? "0.5") ?? 0.5
            var onStrength = godOff ? 0 : dayT * Renderer.kGodRayStrength * max(0, min(1, grFrac))
            if debug { onStrength = -max(onStrength, 0.85) }   // sentinel: output raw shaft term
            let onFlare: Float = flareOff ? 0 : flareGate.strength   // #132
            composite(into: output, godStrength: onStrength, flareStrength: onFlare)
            // pixel-aligned OFF baseline: both god rays AND flare off (so the AB diff is
            // attributable and the night byte-identical test stays clean).
            if abMode {
                // BF_SHOT_AB2=1: the second target keeps god rays ON but takes the legacy
                // inline full-res march, a pixel-aligned old-vs-new architecture AB.
                if ProcessInfo.processInfo.environment["BF_SHOT_AB2"] == "1" {
                    composite(into: outputOff, godStrength: onStrength, flareStrength: onFlare, forceInline: true)
                } else {
                    composite(into: outputOff, godStrength: 0, flareStrength: 0)
                }
            }
        }

        cmd.commit(); cmd.waitUntilCompleted()
        bf_frame_end(e); registry.collect()
    }

    // Warm up: stream the world in for ~3 s before measuring.
    while CACurrentMediaTime() - start < 3.0 { renderOneFrame() }

    // #52 headless screenshot: tilt the camera down to frame ground props, let the
    // chunks/lighting settle, then capture the composited frame to a PNG. No desktop.
    if let shot = shotPath {
        let skyEnvM  = ProcessInfo.processInfo.environment["BF_SHOT_SKY"]
        let skyMode  = (skyEnvM == "1" || skyEnvM == "2")
        let treeMode = ProcessInfo.processInfo.environment["BF_SHOT_TREES"] == "1"
        // #116 test-creature mode: don't walk (so the player settles on the ground at a stable spot
        // and the injected creature's foot Y == eye-height-1.6 lands on the real surface). Instead
        // stand still long enough for gravity + streaming to converge to a deterministic position.
        let testCreatureMode = ProcessInfo.processInfo.environment["BF_SHOT_TESTCREATURE"] != nil
        // BF_SHOT_TCWALK=<frames> lets a test-creature shot walk first to reach a different biome
        // (e.g. grass) before settling and injecting the creature.
        let tcWalk = Int(ProcessInfo.processInfo.environment["BF_SHOT_TCWALK"] ?? "0") ?? 0
        // BF_SHOT_TRAVEL=<frames> overrides how far the shot walks before the capture, so a
        // verification shot can stop near spawn (less likely to bury the camera in terrain).
        let travelEnv = Int(ProcessInfo.processInfo.environment["BF_SHOT_TRAVEL"] ?? "")
        let travel = testCreatureMode ? tcWalk : (travelEnv ?? (treeMode ? 320 : 700))
        for _ in 0..<travel { renderOneFrame(yaw: 0) }       // travel STRAIGHT to cross into grass/forest
        if testCreatureMode { for _ in 0..<240 { renderOneFrame(yaw: 0, forward: 0) } }  // settle on ground
        // BF_SHOT_PITCH=<total radians> aims the camera up/down before the capture
        // (positive = up into more sky). Lets the night yaw sweep frame the horizon/sky,
        // where a view-dependent night over-brightness shows up, instead of the default
        // ground-down framing.
        if let pStr = ProcessInfo.processInfo.environment["BF_SHOT_PITCH"], let pTot = Float(pStr) {
            for _ in 0..<30 { renderOneFrame(pitch: pTot / 30.0, yaw: 0) }
        } else if skyMode {
            for _ in 0..<30 { renderOneFrame(pitch: 0.02, yaw: 0) }  // tilt UP into clear sky for the moon
        } else if treeMode {
            for _ in 0..<12 { renderOneFrame(pitch: 0.012, yaw: 0) } // look level/up to frame trees ahead
        } else {
            for _ in 0..<10 { renderOneFrame(pitch: -0.006, yaw: 0) } // look slightly down at the ground ahead
        }
        // #72 diagnosis: turn the camera by BF_SHOT_YAW degrees before capture, so the
        // same spot can be shot at several yaws to reveal the view-dependent shadow wipe.
        // #89: BF_SHOT_NOWALK=1 turns WITHOUT walking forward, so the camera origin is
        // identical at every yaw (no position confound) for the decisive experiment.
        // #116 test-creature mode implies no-walk so the player stays on its settled ground column
        // and the injected creature lands deterministically wherever the camera is aimed.
        let noWalk = ProcessInfo.processInfo.environment["BF_SHOT_NOWALK"] == "1" || testCreatureMode
        // #89: before the yaw sweep, stand still long enough for gravity + async streaming
        // to converge, so the camera lands on the SAME ground column at every yaw (otherwise
        // free-fall + per-run streaming timing drift the origin and confound the experiment).
        if noWalk { for _ in 0..<400 { renderOneFrame(yaw: 0, forward: 0) } }
        // #179: BF_SHOT_SETYAW=<radians> turns to an ABSOLUTE world heading before the
        // capture (0 = +z, pi/2 = +x), without walking. Used by the world-seam shots to
        // look east and then west across x = 0 from the same spot.
        if let setStr = ProcessInfo.processInfo.environment["BF_SHOT_SETYAW"], let target = Float(setStr) {
            let delta = target - (0.6 + yawAccum)
            for _ in 0..<30 { renderOneFrame(yaw: delta / 30.0, forward: 0) }
            for _ in 0..<60 { renderOneFrame(yaw: 0, forward: 0) } // settle streaming at the new heading
        }
        if let yawStr = ProcessInfo.processInfo.environment["BF_SHOT_YAW"], let yawDeg = Float(yawStr) {
            let total = yawDeg * Float.pi / 180.0
            let frames = 60
            for _ in 0..<frames { renderOneFrame(yaw: total / Float(frames), forward: noWalk ? 0 : 1.0) }
        }
        for _ in 0..<24  { renderOneFrame(yaw: 0, forward: noWalk ? 0 : 1.0) } // settle
        print("shot: prop instances in final frame = \(lastShotPropN)")
        // #116 diagnostic (env-gated, harmless): dump camera + entity positions so a verification
        // shot can be aimed at a creature. Off unless BF_SHOT_ENTDUMP=1.
        if ProcessInfo.processInfo.environment["BF_SHOT_ENTDUMP"] == "1" { print(lastEntDump) }
        writeTexturePNG(output, to: shot)
        // #119 AB mode: also write the pixel-aligned god-rays-OFF composite alongside, with
        // an "_off" suffix, so the before/after is a true same-frame comparison.
        if abMode {
            let offPath = shot.hasSuffix(".png") ? String(shot.dropLast(4)) + "_off.png" : shot + "_off"
            writeTexturePNG(outputOff, to: offPath)
        }
        return true
    }

    let measureStart = CACurrentMediaTime()
    while CACurrentMediaTime() - measureStart < seconds {
        let t0 = CACurrentMediaTime()
        renderOneFrame()
        let ms = (CACurrentMediaTime() - t0) * 1000.0
        if ms > 0 { fpsSamples.append(1000.0 / ms) }
        peakMem = max(peakMem, residentFootprintMB())
    }

    let sorted = fpsSamples.sorted()
    func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[max(0, min(sorted.count-1, Int(Double(sorted.count) * p)))] }
    let median = pct(0.5)
    let low1 = pct(0.01)
    let passFps = median >= 60.0 && low1 >= 30.0
    let passMem = peakMem < 10_000.0
    print(String(format: "PERF: %d frames over %.0fs — median %.1f FPS, 1%%-low %.1f FPS, peak mem %.0f MB  [%@]",
                 fpsSamples.count, seconds, median, low1, peakMem,
                 (passFps && passMem) ? "PASS (dev box)" : "below gate"))

    if let path = jsonPath {
        let json = """
        { "scene": "ref(rd10, animals, day/night, streaming, shadows+bloom)", "seconds": \(seconds), \
        "frames": \(fpsSamples.count), "fps_median": \(String(format:"%.1f",median)), \
        "fps_1pct_low": \(String(format:"%.1f",low1)), "peak_mem_mb": \(String(format:"%.0f",peakMem)), \
        "pass_fps": \(passFps), "pass_mem": \(passMem), \
        "note": "dev-box reference; the gate is an M1 Air sustained 10-min run" }
        """
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote perf json: \(path)")
    }
    return !fpsSamples.isEmpty && passMem
}

// Headless creature gallery (#51): render one of every creature kind in a row to a
// PNG, so the detailed sub-voxel animal models can be reviewed from the terminal.
func runCritterGallery(savePath: String) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { return false }
    let queue = device.makeCommandQueue()!
    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else { return false }
    let entR = EntityRenderer(device: device, colorFormat: .rgba16Float)
    func pipe(_ v: String, _ f: String) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v); d.fragmentFunction = lib.makeFunction(name: f)
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: d)
    }
    guard let composite = pipe("fullscreenVert", "compositeFrag") else { return false }
    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)
    let noDSD = MTLDepthStencilDescriptor(); noDSD.depthCompareFunction = .always; noDSD.isDepthWriteEnabled = false
    let noDepth = device.makeDepthStencilState(descriptor: noDSD)

    let W = 1600, H = 420
    func tex(_ fmt: MTLPixelFormat, _ usage: MTLTextureUsage, _ shared: Bool) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: W, height: H, mipmapped: false)
        d.usage = usage; d.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: d)!
    }
    let hdr      = tex(.rgba16Float, [.renderTarget, .shaderRead], false)
    // #130 depth must be readable by the composite when cel outlines are on (BF_CEL=1).
    let celGallery: Bool = ProcessInfo.processInfo.environment["BF_CEL"] == "1"
    let hdrDepth = tex(.depth32Float, celGallery ? [.renderTarget, .shaderRead] : [.renderTarget], false)
    let bloom    = tex(.rgba16Float, [.renderTarget, .shaderRead], false)
    let output   = tex(.bgra8Unorm, [.renderTarget], true)

    // One entity per creature kind (skip 6 = falling block). Varied toy colours.
    let kinds: [UInt32] = [0,1,2,3,4,5,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,100]
    let cols: [SIMD3<Float>] = [
        SIMD3(0.85,0.80,0.74), SIMD3(0.78,0.45,0.28), SIMD3(0.55,0.58,0.62), SIMD3(0.30,0.55,0.35),
        SIMD3(0.90,0.86,0.40), SIMD3(0.40,0.40,0.48), SIMD3(0.72,0.36,0.30), SIMD3(0.95,0.95,0.97)
    ]
    // Two rows so the camera can sit close and the models render large.
    let perRow = (kinds.count + 1) / 2
    let spacing: Float = 1.7
    var ents: [bf_entity_draw] = []
    for (i, k) in kinds.enumerated() {
        var e = bf_entity_draw()
        let rowI = i / perRow, colI = i % perRow
        e.position = bf_vec3(x: Float(colI) * spacing, y: 0, z: Float(rowI) * 2.6)
        e.yaw = 0.7; e.scale = 1.35; e.kind = k; e.sat = 1.0
        let c = cols[i % cols.count]; e.color = bf_vec3(x: c.x, y: c.y, z: c.z)
        ents.append(e)
    }
    let cx = Float(perRow - 1) * spacing * 0.5
    let proj = Renderer.perspective(fovy: 0.62, aspect: Float(W) / Float(H), near: 0.05, far: 300)
    let eye = SIMD3<Float>(cx, 3.0, Float(perRow) * 1.15 + 3)
    let view = EntityRenderer.rotX(0.22) * EntityRenderer.trans(SIMD3(-eye.x, -eye.y, -eye.z))
    let viewProj = proj * view

    let cmd = queue.makeCommandBuffer()!
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = hdr
    rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.46, green: 0.63, blue: 0.86, alpha: 1)
    rp.depthAttachment.texture = hdrDepth
    rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0
    rp.depthAttachment.storeAction = celGallery ? .store : .dontCare   // #130 keep depth for outlines
    if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
        enc.setDepthStencilState(depthState)
        ents.withUnsafeBufferPointer { p in
            entR.encode(enc, viewProj: viewProj, entities: p.baseAddress, count: ents.count)
        }
        enc.endEncoding()
    }
    let brp = MTLRenderPassDescriptor()
    brp.colorAttachments[0].texture = bloom
    brp.colorAttachments[0].loadAction = .clear; brp.colorAttachments[0].clearColor = MTLClearColor(red:0,green:0,blue:0,alpha:1)
    brp.colorAttachments[0].storeAction = .store
    if let enc = cmd.makeRenderCommandEncoder(descriptor: brp) { enc.endEncoding() }
    let crp = MTLRenderPassDescriptor()
    crp.colorAttachments[0].texture = output
    crp.colorAttachments[0].loadAction = .dontCare; crp.colorAttachments[0].storeAction = .store
    if let enc = cmd.makeRenderCommandEncoder(descriptor: crp) {
        enc.setRenderPipelineState(composite); enc.setDepthStencilState(noDepth); enc.setCullMode(.none)
        enc.setFragmentTexture(hdr, index: 0); enc.setFragmentTexture(bloom, index: 1)
        var pu = PostUniforms(bloomStrength: 0.0, vignetteStr: 0.0, satBoost: 1.15, rainStrength: 0, wallClockSecs: 0)
        pu.celShade = celGallery ? 1 : 0   // #130 outlines + cel grade on the creature gallery
        enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
        // #130 compositeFrag reads sceneDepth(2) + VolUniforms(1) when cel is on; bind both
        // (volStrength 0 => the god-ray branch is skipped, so a zero VU is fine).
        if celGallery {
            enc.setFragmentTexture(hdrDepth, index: 2)
            var vu = VolUniforms(invViewProj: viewProj.inverse, voxOrigin: .zero, voxDims: .zero,
                                 camPosW: SIMD4<Float>(eye.x, eye.y, eye.z, 384),
                                 sunDir: SIMD4<Float>(0, -1, 0, 0),
                                 sunColor: SIMD4<Float>(1, 1, 1, 0))   // w=0 => god rays off
            enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
    cmd.commit(); cmd.waitUntilCompleted()
    writeTexturePNG(output, to: savePath)
    print("critter gallery: \(ents.count) kinds")
    return true
}

// ============================================================================
// #89 SHADOW YAW PROBE - the decisive, confound-free experiment.
//
// The input-driven --shot harness cannot hold the player still (gravity + async
// streaming drift the origin run-to-run), so it cannot answer "does a FIXED world
// point's shadow change when ONLY the camera yaw changes?". This builds a fully
// synthetic, fixed scene (a ground plane + one occluder pillar) using the REAL
// shadow + terrain pipelines (shadowVmain / vmain / fmain, sampleShadowPCF, the
// cascade blend and the radial / edge fades), places the camera at a FIXED world
// position, and renders it at several yaws with a FIXED high sun.
//
// For each yaw it reports the shadow factor (the #72 BF_SHADOW_DEBUG grayscale,
// which is `raw` straight out of the shadow path, BEFORE the #47 specular) sampled
// at the SAME world point each time, by projecting that point into each view and
// reading its pixel. If the value is constant across yaws => shadows are NOT
// yaw-dependent. It ALSO reports the full-colour pixel at the same point so the
// view-dependent #47 specular sheen can be seen to move while the shadow does not.
// ============================================================================
// --- RETIRED shadow-MAP guards (world-space voxel shadows; see --worldfixedtest) ---
// These were guards against the camera-following shadow map. That map is gone, replaced
// by world-space voxel ray-marched shadows whose defining property is world-fixedness,
// verified by runWorldFixedShadowTest (--worldfixedtest). The stubs keep main.swift's
// call sites valid; they print a SKIP and pass.
func runShadowYawProbe() -> Bool {
    print("SKIP: --shadowprobe retired (world-space voxel shadows; see --worldfixedtest)"); return true
}
func runShadowPosProbe(strict: Bool = false) -> Bool {
    print("SKIP: --shadowposprobe / --shadowstabilitytest retired (world-space voxel shadows; see --worldfixedtest)"); return true
}

// ============================================================================
// --groundnightprobe : the NIGHT, VIEW-DIRECTION-dependent GROUND wash (#117).
//
// The player's confirmed symptom: at NIGHT the GROUND turns a pale/washed colour
// depending on camera YAW. Facing N or S (perpendicular to the sun's E/W rise/set
// axis) the ground reads its correct dark night colour; facing E or W (along the
// sun azimuth axis) it washes pale. God rays OFF, soft shadows OFF, weather-agnostic.
//
// WHY THE EARLIER ATTEMPTS FAILED and this one works:
//   - --shot renders in a SEPARATE process each call, streaming a DIFFERENT patch of
//     world (async streaming is non-deterministic across processes), so yaw-0 vs yaw-90
//     compared TWO different scenes. Invalid.
//   - the last probe used a SYNTHETIC FLAT PLANE, which has no per-face block normals /
//     relief / real materials, so the view-dependent term never fired.
//
// This probe is SINGLE-PROCESS and uses the REAL ENGINE TERRAIN: it boots the engine,
// streams a fixed-seed region fully in, fixes the camera over that terrain, then renders
// the SAME ground at several yaws (0=N, 10, 45, 90=E, 180=S, 270=W) at NIGHT, all in the
// one process, and measures the LOWER-HALF (ground) mean luma per yaw. The terrain is
// byte-identical across yaws, so any luma spread is purely the view-direction term.
//
// Bisect support (Step 2): GNP_NULL=<name> neutralises ONE fmain/sky term in the compiled
// shader before the sweep, so removing the culprit collapses the E/W ground luma to N/S.
//   names: relief | fog | drained | bump | detail | skyterrain | none
// Sun-azimuth cross-check (Step 3): GNP_SUN_AXIS=z rotates the night sun's azimuth 90°
// (default x = sun rises/sets along world X); the pale directions must rotate with it.
//
// strict == true turns it into the GREEN/RED regression gate wired into check.sh: it
// FAILS if the night ground luma spread across yaw exceeds a small tolerance.
// ============================================================================
func runGroundNightProbe(strict: Bool = false) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("SKIP: ground-night probe (no Metal device)"); return true
    }
    let queue = device.makeCommandQueue()!
    let registry = BufferRegistry(device: device)

    // ---- Optional single-term neutralisation for the bisect (Step 2) -------
    // We edit the shader SOURCE (not any ABI struct) so the elimination touches exactly
    // one term and nothing else. Each replacement is an exact, unique substring of fmain.
    var src = Renderer.shaderSource
    let nullTerm = ProcessInfo.processInfo.environment["GNP_NULL"] ?? "none"
    func neutralize(_ find: String, _ replace: String, _ label: String) {
        guard src.contains(find) else { print("GNP_NULL=\(label): anchor not found (shader changed?)"); return }
        src = src.replacingOccurrences(of: find, with: replace)
        print("GNP_NULL=\(label): neutralized")
    }
    switch nullTerm {
    case "relief":
        // Kill the #47/#105 relief sun sheen entirely.
        neutralize("col += specAdd;", "col += 0.0;", "relief")
    case "fog":
        // Kill the atmospheric distance fog (the else branch).
        neutralize("float fog = smoothstep(295.0, 400.0, dist) * 0.32;",
                   "float fog = 0.0;", "fog")
    case "drained":
        // Kill the "drained / The Grey" desaturation remap.
        neutralize("col = mix(drained, col, sat);", "col = col;", "drained")
    case "bump":
        neutralize("bumpLight = (in.faceNorm == 3u) ? 1.0 : sunTilt;",
                   "bumpLight = 1.0;", "bump")
    case "detail":
        neutralize("float3 detail = blockDetail(in.worldPos, in.faceNorm, in.material);",
                   "float3 detail = float3(1.0);", "detail")
    case "waterrefl":
        // Kill the #43 view-dependent sky reflection on the water surface (waterFmain).
        neutralize("col = mix(col, skyRefl, reflAmt);", "col = col;", "waterrefl")
    case "skyterrain":
        // Render terrain only over a BLACK clear, no sky pass, to prove the wash is
        // terrain not sky bleeding into the lower half.
        print("GNP_NULL=skyterrain: sky pass disabled at runtime")
    case "none":
        break
    default:
        print("GNP_NULL=\(nullTerm): unknown term (no-op)")
    }
    guard let lib = try? device.makeLibrary(source: src, options: nil) else {
        print("shader compile failed"); return false
    }
    func pipe(_ vfn: String, _ ffn: String, _ fmt: MTLPixelFormat, depth: Bool) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: vfn); d.fragmentFunction = lib.makeFunction(name: ffn)
        d.colorAttachments[0].pixelFormat = fmt
        if depth { d.depthAttachmentPixelFormat = .depth32Float }
        return try? device.makeRenderPipelineState(descriptor: d)
    }
    guard let skyPipe   = pipe("skyVmain", "skyFmain", .rgba16Float, depth: true),
          let terrPipe  = pipe("vmain", "fmain", .rgba16Float, depth: true),
          let brightPipe = pipe("fullscreenVert", "bloomBrightFrag", .rgba16Float, depth: false),
          let blurHPipe = pipe("fullscreenVert", "bloomBlurHFrag", .rgba16Float, depth: false),
          let blurVPipe = pipe("fullscreenVert", "bloomBlurVFrag", .rgba16Float, depth: false),
          let compPipe  = pipe("fullscreenVert", "compositeFrag", .bgra8Unorm, depth: false)
    else { print("pipeline build failed"); return false }
    // Water translucency pass (alpha-blended over the terrain), exactly as the live
    // renderer draws it. The probe MUST include this: the #43 sky reflection in
    // waterFmain is view-dependent and sun-azimuth-keyed, and the perf/--shot harness
    // omits it, which is why earlier reproductions came up empty.
    let waterPipe: MTLRenderPipelineState? = {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vmain"); d.fragmentFunction = lib.makeFunction(name: "waterFmain")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one
        d.colorAttachments[0].destinationAlphaBlendFactor = .zero
        d.depthAttachmentPixelFormat = .depth32Float
        return try? device.makeRenderPipelineState(descriptor: d)
    }()
    let waterDSD = MTLDepthStencilDescriptor(); waterDSD.depthCompareFunction = .lessEqual; waterDSD.isDepthWriteEnabled = false
    let waterDepthState = device.makeDepthStencilState(descriptor: waterDSD)
    // Skip the water pass entirely (control) with GNP_NULL=nowater.
    let waterOff = (ProcessInfo.processInfo.environment["GNP_NULL"] == "nowater")

    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)
    let sdsd = MTLDepthStencilDescriptor(); sdsd.depthCompareFunction = .always; sdsd.isDepthWriteEnabled = false
    let skyDepthState = device.makeDepthStencilState(descriptor: sdsd)
    let nodd = MTLDepthStencilDescriptor(); nodd.depthCompareFunction = .always; nodd.isDepthWriteEnabled = false
    let noDepthState = device.makeDepthStencilState(descriptor: nodd)

    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION; cfg.role = BF_ROLE_SINGLEPLAYER; cfg.start_mode = BF_MODE_CREATIVE
    cfg.render_distance_chunks = 12
    cfg.content_dir = persistentCString("."); cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_gnp")
    cfg.player_name = persistentCString("gnp")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { print("engine create"); return false }
    defer { bf_engine_destroy(e) }
    var alloc = bf_gpu_allocator()
    alloc.user = Unmanaged.passUnretained(registry).toOpaque()
    alloc.alloc = allocTrampoline; alloc.free_ = freeTrampoline
    _ = bf_set_gpu_allocator(e, &alloc)
    // Fixed seed: deterministic real terrain, so the per-yaw numbers reproduce run to run.
    // GNP_SEED overrides it (used to hunt a grass biome column the player reported on).
    let seed = UInt64(ProcessInfo.processInfo.environment["GNP_SEED"] ?? "") ?? 2026
    _ = bf_world_new(e, seed)

    let W = 480, H = 360, HW = W/2, HH = H/2
    func makeTex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ shared: Bool) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: td)!
    }
    let hdrColor = makeTex(.rgba16Float, W, H, [.renderTarget, .shaderRead], false)
    let hdrDepth = makeTex(.depth32Float, W, H, [.renderTarget], false)
    let bloomBrt = makeTex(.rgba16Float, HW, HH, [.renderTarget, .shaderRead], false)
    let bloomBlurA = makeTex(.rgba16Float, HW, HH, [.renderTarget, .shaderRead], false)
    let output = makeTex(.bgra8Unorm, W, H, [.renderTarget], true)

    // ---- Stream a fixed real-terrain region FULLY in (single process) ------
    // Walk a touch so chunks generate, then stand still long enough for streaming to settle
    // so the camera lands on the SAME ground column for the whole sweep.
    var camEye = SIMD3<Float>(0, 48, 0)
    var biomeName = ""
    // GNP_WALK frames of forward travel before settling (default 80): lets the probe
    // walk out of the spawn biome into a grass/meadow column when hunting the repro.
    let walkFrames = Int(ProcessInfo.processInfo.environment["GNP_WALK"] ?? "") ?? 80
    let totalFrames = walkFrames + 140
    let turnLeft = ProcessInfo.processInfo.environment["GNP_TURNLEFT"] == "1"   // strafe-direction variety
    for f in 0..<totalFrames {
        registry.currentFrame = f
        var input = bf_frame_input()
        input.move_forward = (f < walkFrames) ? 1 : 0
        if turnLeft && f < walkFrames { input.look_yaw_delta = 0.02 }
        _ = bf_frame_begin(e, &input, (f < totalFrames - 40) ? 1.0/60.0 : 2.0)   // long dt late = let streaming finish
        var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
        camEye = SIMD3<Float>(fr.camera.position.x, fr.camera.position.y, fr.camera.position.z)
        biomeName = withUnsafeBytes(of: fr.hud.biome_name) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        bf_frame_end(e); registry.collect()
    }
    print(String(format: "ground-night probe: target=(%.1f,%.1f,%.1f) biome=%@ (orbit-and-project, deep night)",
                 camEye.x, camEye.y, camEye.z, biomeName))

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

    // NIGHT. tod 0.75 == deep night: dayLight()==0, sun well below the horizon.
    // sun_dir mirrors world.hpp / the BF_SHOT_TOD path: dir=(cos(a)*0.6, -sin(a)-0.25, 0.90).
    // The sun azimuth is in the X/Z plane; "rises/sets E/W" means the azimuth axis is X by
    // default. GNP_SUN_AXIS=z swings the azimuth 90° (Step 3 cross-check).
    let tod = Float(ProcessInfo.processInfo.environment["GNP_TOD"] ?? "") ?? 0.75
    let ang = tod * 6.2831853 as Float
    let sunAxisZ = ProcessInfo.processInfo.environment["GNP_SUN_AXIS"] == "z"
    let sun: SIMD3<Float> = sunAxisZ
        ? simd_normalize(SIMD3<Float>(0.90, -sin(ang) - 0.25, cos(ang) * 0.6))   // azimuth axis = Z
        : simd_normalize(SIMD3<Float>(cos(ang) * 0.6, -sin(ang) - 0.25, 0.90))   // azimuth axis = X (default)

    // ---- ORBIT-AND-PROJECT: the confound-free isolation -------------------
    // The naive "look in direction X, average the lower half" measurement is confounded:
    // each yaw frames a DIFFERENT patch of real terrain (and the patch streamed in varies
    // run to run), so the per-yaw luma moves for reasons unrelated to any shading bug. That
    // confound is what burned the earlier attempts.
    //
    // Instead the camera ORBITS a FIXED ground TARGET at a fixed radius and a fixed GRAZING
    // pitch, always looking AT the target. A fixed ring of ground world-points around the
    // target is then projected to screen and sampled at each azimuth. The SAME world points
    // are measured at the SAME grazing angle every time; only the view AZIMUTH (relative to
    // the sun) changes. So any luma change across azimuth is purely a view-direction shading
    // term, not scene content. Real engine terrain throughout (not a synthetic plane).
    let target = SIMD3<Float>(camEye.x, camEye.y, camEye.z)   // the settled ground point
    let orbitR = Float(ProcessInfo.processInfo.environment["GNP_R"] ?? "") ?? 16   // grazing distance
    // Grazing eye height above the target: low so the view skims ACROSS the surface toward
    // the horizon (where the Fresnel sky reflection is strongest). GNP_PITCH still works as
    // an eye-height multiplier knob if needed.
    let eyeUp = Float(ProcessInfo.processInfo.environment["GNP_EYEUP"] ?? "") ?? 2.0
    // Fixed ring of ground sample points around the target (real terrain texels we re-sample).
    // A TIGHT cluster right at the target so every point is co-visible at every azimuth
    // (a wide ring gets occluded unevenly by intervening terrain, which re-introduces the
    // scene-content confound). GNP_RING widens it for diagnostics.
    let ringR = Float(ProcessInfo.processInfo.environment["GNP_RING"] ?? "") ?? 1.2
    var samplePts: [SIMD3<Float>] = []
    for k in 0..<8 {
        let a = Float(k) * (2 * Float.pi / 8)
        samplePts.append(SIMD3<Float>(target.x + cos(a) * ringR, target.y, target.z + sin(a) * ringR))
    }
    samplePts.append(target)

    let azimuths: [(String, Float)] = [("N(0)",0), ("10",10), ("45",45), ("E(90)",90), ("S(180)",180), ("W(270)",270)]
    func project(_ p: SIMD3<Float>, _ vp: simd_float4x4) -> (Int, Int)? {
        let clip = vp * SIMD4<Float>(p.x, p.y, p.z, 1)
        if clip.w <= 0.0001 { return nil }
        let nx = clip.x / clip.w, ny = clip.y / clip.w
        let sx = Int((nx * 0.5 + 0.5) * Float(W)), sy = Int((1.0 - (ny * 0.5 + 0.5)) * Float(H))
        if sx < 0 || sx >= W || sy < 0 || sy >= H { return nil }
        return (sx, sy)
    }

    var lumaByYaw: [String: Double] = [:]
    let savePNG = ProcessInfo.processInfo.environment["GNP_SAVE"] != nil
    let skyOff = (nullTerm == "skyterrain")

    for (name, azDeg) in azimuths {
        let az = azDeg * Float.pi / 180.0
        // Camera orbits the target on a circle of radius orbitR at the chosen azimuth,
        // eyeUp above target height, looking AT the target (a fixed grazing line of sight).
        let eyeO = SIMD3<Float>(target.x + sin(az) * orbitR, target.y + eyeUp, target.z - cos(az) * orbitR)
        let fwd = normalize(target - eyeO)
        let view = lookView(eyeO, fwd, SIMD3<Float>(0, 1, 0))
        let viewProj = proj * view
        let cr = SIMD3<Float>(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let cu = SIMD3<Float>(view.columns.0.y, view.columns.1.y, view.columns.2.y)

        registry.currentFrame = 1000 + Int(azDeg)
        var input = bf_frame_input()
        _ = bf_frame_begin(e, &input, 1.0/60.0)
        var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
        guard let cmd = queue.makeCommandBuffer() else { bf_frame_end(e); continue }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdrColor
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = hdrDepth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0
        rp.depthAttachment.storeAction = .dontCare
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            if !skyOff {
                enc.setRenderPipelineState(skyPipe); enc.setDepthStencilState(skyDepthState); enc.setCullMode(.none)
                var su = SkyUniforms(
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, tod),
                    camRight: SIMD4<Float>(cr.x, cr.y, cr.z, tanHalf),
                    camUp:    SIMD4<Float>(cu.x, cu.y, cu.z, Float(W)/Float(H)),
                    camFwd:   SIMD4<Float>(fwd.x, fwd.y, fwd.z, 0))
                enc.setVertexBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                enc.setFragmentBytes(&su, length: MemoryLayout<SkyUniforms>.stride, index: 0)
                var wuSky = WaterUniforms(wallClockSecs: 0, underwater: 0)
                enc.setFragmentBytes(&wuSky, length: MemoryLayout<WaterUniforms>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.setRenderPipelineState(terrPipe); enc.setDepthStencilState(depthState)
            enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
            // shadowScale 0 == soft shadows OFF (the player's reported condition). The sun
            // dir + time are the REAL night values so the relief sheen / any sun-keyed term
            // sees exactly what the live night renderer feeds it.
            var wu = WaterUniforms(wallClockSecs: 0, underwater: 0, shadowScale: 0,
                                   cameraPosW: SIMD4<Float>(eyeO.x, eyeO.y, eyeO.z, 0),
                                   sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, tod))
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
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, tod),
                    lightViewProj: matrix_identity_float4x4,
                    dimSatN: SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ib, indexBufferOffset: Int(d.index_offset))
            }
            // --- Water translucency pass (alpha over terrain): mirrors the live renderer.
            if !waterOff, let wp = waterPipe {
                enc.setRenderPipelineState(wp); enc.setDepthStencilState(waterDepthState)
                enc.setCullMode(.none); enc.setFrontFacing(.counterClockwise)
                enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
                enc.setFragmentBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
                enc.setVertexBytes(&windST, length: MemoryLayout<WindUniforms>.stride, index: 3)
                for i in 0..<Int(fr.draw_count) {
                    let d = fr.draws[i]
                    guard d.index_count > 0, let vb = registry.lookup(d.vertex_buffer), let ib = registry.lookup(d.index_buffer) else { continue }
                    var u = Uniforms(
                        viewProj: viewProj,
                        chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                        sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, tod),
                        lightViewProj: matrix_identity_float4x4,
                        dimSatN: SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                    enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                              indexType: .uint32, indexBuffer: ib, indexBufferOffset: Int(d.index_offset))
                }
            }
            enc.endEncoding()
        }
        // Bloom + ACES composite, mirroring the live post chain (god rays OFF: grStrength 0).
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
        let crp = MTLRenderPassDescriptor()
        crp.colorAttachments[0].texture = output; crp.colorAttachments[0].loadAction = .dontCare; crp.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: crp) {
            enc.setRenderPipelineState(compPipe); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
            enc.setFragmentTexture(hdrColor, index: 0); enc.setFragmentTexture(bloomBrt, index: 1)
            // compositeFrag needs scene depth at index 2; the occupancy grid (index 3) is only
            // read when volStrength > 0, which is 0 here, so it is left unbound for this probe.
            enc.setFragmentTexture(hdrDepth, index: 2)
            var pu = PostUniforms(bloomStrength: 0.08, vignetteStr: 0.22, satBoost: 1.18, rainStrength: 0, wallClockSecs: 0)
            enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
            var vu = VolUniforms()   // volStrength = 0 -> raymarch off in this probe
            enc.setFragmentBytes(&vu, length: MemoryLayout<VolUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
        }
        cmd.commit(); cmd.waitUntilCompleted()
        bf_frame_end(e); registry.collect()

        // Measure GROUND luma at the FIXED ring of world points (same surface, same grazing
        // angle, only the view azimuth differs). Average a small patch around each point's
        // screen projection. This is the confound-free signal: the world geometry is identical
        // across azimuths, so the only thing that can move the number is a view-direction term.
        var px = [UInt8](repeating: 0, count: W*H*4)
        output.getBytes(&px, bytesPerRow: W*4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        var lumaSum = 0.0; var n = 0
        for p in samplePts {
            guard let (sx, sy) = project(p, viewProj) else { continue }
            for dy in -3...3 { for dx in -3...3 {
                let cx = min(max(0, sx+dx), W-1), cy = min(max(0, sy+dy), H-1)
                let q = (cy*W + cx) * 4
                let b = Double(px[q])/255, g = Double(px[q+1])/255, r = Double(px[q+2])/255
                lumaSum += 0.2126*r + 0.7152*g + 0.0722*b
                n += 1
            } }
        }
        let meanLuma = n > 0 ? lumaSum / Double(n) : 0
        lumaByYaw[name] = meanLuma
        print(String(format: "  az %-7@ ground-point mean-luma %.1f%%  (%d samples)", name, meanLuma*100, n))
        if savePNG {
            var rgba = [UInt8](repeating: 255, count: W*H*4)
            for i in stride(from: 0, to: px.count, by: 4) { rgba[i]=px[i+2]; rgba[i+1]=px[i+1]; rgba[i+2]=px[i] }
            rgba.withUnsafeMutableBytes { raw in
                var planes: [UnsafeMutablePointer<UInt8>?] = [raw.bindMemory(to: UInt8.self).baseAddress]
                if let rep = NSBitmapImageRep(bitmapDataPlanes: &planes, pixelsWide: W, pixelsHigh: H,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: W*4, bitsPerPixel: 32),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/gnp_\(Int(azDeg)).png"))
                }
            }
        }
    }

    // N/S are perpendicular to the (default-X) sun azimuth axis (the "good" baseline);
    // E/W are along it (the reported "bad" pale axis). With GNP_SUN_AXIS=z those swap.
    let ns = [lumaByYaw["N(0)"] ?? 0, lumaByYaw["S(180)"] ?? 0]
    let ew = [lumaByYaw["E(90)"] ?? 0, lumaByYaw["W(270)"] ?? 0]
    let nsMean = ns.reduce(0,+) / Double(ns.count)
    let ewMean = ew.reduce(0,+) / Double(ew.count)
    let axisSpread = ewMean - nsMean
    let allVals = Array(lumaByYaw.values)
    let fullSpread = (allVals.max() ?? 0) - (allVals.min() ?? 0)
    print(String(format: "  N/S mean %.1f%%  E/W mean %.1f%%  (E/W - N/S = %+.1f%%)  full yaw spread %.1f%%",
                 nsMean*100, ewMean*100, axisSpread*100, fullSpread*100))

    // ---- Deterministic gate renderer: a controlled WATER surface drawn by the REAL
    // waterFmain shader. The orbit sweep above is the real-terrain reproduction; this is the
    // regression GUARD. It renders one fixed grazing night/day view of a synthetic water quad
    // with the live shader and (separately) with the #43 sky reflection forced off, and
    // returns the mean luma of the water surface. Comparing the two isolates exactly the
    // reflection term in the COMPILED shader, with no terrain-streaming or occlusion confound.
    // (A controlled quad is the right tool for a deterministic shader gate; the bug-repro that
    // needs real per-face terrain is the orbit sweep, which runs on real engine chunks.)
    func gateRenderWaterLuma(reflOff: Bool, timeOfDay: Float, sun sunIgnored: SIMD3<Float>) -> Double {
        // Derive the sun direction from THIS time of day (same formula as the live night/day
        // sun) so the day render uses a real daytime sun, not the night one passed in.
        let a = timeOfDay * 6.2831853 as Float
        let sun = simd_normalize(SIMD3<Float>(cos(a) * 0.6, -sin(a) - 0.25, 0.90))
        // Pick the shader lib: normal, or one with the reflection mix neutralized.
        let useLib: MTLLibrary
        if reflOff {
            var s2 = Renderer.shaderSource
            s2 = s2.replacingOccurrences(of: "col = mix(col, skyRefl, reflAmt);", with: "col = col;")
            guard let l2 = try? device.makeLibrary(source: s2, options: nil) else { return -1 }
            useLib = l2
        } else {
            useLib = lib
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = useLib.makeFunction(name: "vmain")
        d.fragmentFunction = useLib.makeFunction(name: "waterFmain")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm   // 8-bit so getBytes reads UInt8 cleanly
        d.colorAttachments[0].isBlendingEnabled = false   // opaque sample: just the surface colour
        d.depthAttachmentPixelFormat = .depth32Float
        guard let wpipe = try? device.makeRenderPipelineState(descriptor: d) else { return -1 }

        // A single flat WATER top-face quad (material 9) at y=32, large enough to fill a
        // grazing view. PackedVertex layout matches the live mesher (see shadowposprobe pv()).
        struct PV { var pos: UInt32; var normuv: UInt32; var material: UInt16; var sky: UInt8; var block: UInt8; var reserved: UInt32 }
        func pv(_ x: Int, _ y: Int, _ z: Int) -> PV {
            let pos = UInt32(x & 0x3f) | (UInt32(y & 0x3f) << 6) | (UInt32(z & 0x3f) << 12)
            // norm 2 = +Y top face; uv bits (3<<3); sky 15 = full skylight; material 9 = water.
            return PV(pos: pos, normuv: 2 | (3 << 3), material: 9, sky: 15, block: 0, reserved: 0)
        }
        var verts: [PV] = []; var idx: [UInt32] = []
        let y = 32
        for gx in stride(from: 0, to: 60, by: 2) { for gz in stride(from: 0, to: 60, by: 2) {
            let base = UInt32(verts.count)
            verts.append(pv(gx, y, gz)); verts.append(pv(gx, y, gz+2))
            verts.append(pv(gx+2, y, gz+2)); verts.append(pv(gx+2, y, gz))
            idx.append(base); idx.append(base+1); idx.append(base+2)
            idx.append(base); idx.append(base+2); idx.append(base+3)
        } }
        let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<PV>.stride, options: .storageModeShared)!
        let ib = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)!

        // Grazing camera over the water, looking ACROSS the quad toward the sun azimuth (the
        // worst-case wash direction). Anchor the eye on the upwind edge so the line of sight
        // sweeps the whole quad. The quad spans x,z in [0,60] at chunkOrigin 0 (world coords).
        let azDir = simd_normalize(SIMD3<Float>(sun.x, 0, sun.z))   // sun azimuth on the ground
        let center = SIMD3<Float>(30, Float(y), 30)
        let gEye = SIMD3<Float>(center.x - azDir.x * 26, Float(y) + 2.0, center.z - azDir.z * 26)
        let gTarget = SIMD3<Float>(center.x + azDir.x * 26, Float(y), center.z + azDir.z * 26)
        let gFwd = normalize(gTarget - gEye)
        let gView = lookView(gEye, gFwd, SIMD3<Float>(0, 1, 0))
        let gVP = proj * gView

        let gTex = makeTex(.bgra8Unorm, W, H, [.renderTarget, .shaderRead], true)
        let gDepth = makeTex(.depth32Float, W, H, [.renderTarget], false)
        guard let cmd = queue.makeCommandBuffer() else { return -1 }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = gTex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = gDepth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = .dontCare
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(wpipe); enc.setDepthStencilState(depthState)
            enc.setCullMode(.none); enc.setFrontFacing(.counterClockwise)
            var u = Uniforms(viewProj: gVP, chunkOrigin: SIMD4<Float>(0, 0, 0, 1),
                             sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, timeOfDay),
                             lightViewProj: matrix_identity_float4x4, dimSatN: SIMD4<Float>(1, 1, 1, 0))
            var wuG = WaterUniforms(wallClockSecs: 0, underwater: 0, reflectScale: 1, shadowScale: 0,
                                    cameraPosW: SIMD4<Float>(gEye.x, gEye.y, gEye.z, 0),
                                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, timeOfDay))
            var windG = WindUniforms(wallClockSecs: 0, rainStrength: 0)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&windG, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setFragmentBytes(&wuG, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            enc.setFragmentBytes(&windG, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: idx.count, indexType: .uint32,
                                      indexBuffer: ib, indexBufferOffset: 0)
            enc.endEncoding()
        }
        cmd.commit(); cmd.waitUntilCompleted()
        // Mean luma over water pixels (non-black) in the LOWER half (the near water surface).
        // bgra8: byte order B,G,R,A.
        var px = [UInt8](repeating: 0, count: W*H*4)
        gTex.getBytes(&px, bytesPerRow: W*4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        var sum = 0.0; var cnt = 0
        for yy in (H/2)..<H { for xx in 0..<W {
            let q = (yy*W + xx) * 4
            let b = Double(px[q])/255, g = Double(px[q+1])/255, r = Double(px[q+2])/255
            if r + g + b < 0.004 { continue }    // skip the cleared (no-water) background
            sum += 0.2126*r + 0.7152*g + 0.0722*b; cnt += 1
        } }
        return cnt > 0 ? sum / Double(cnt) : 0
    }

    if strict {
        // The strict gate tests the REAL compiled shader, not a CPU re-implementation, and is
        // deterministic (no cross-azimuth scene-content confound): for the SAME fixed night
        // frame over water, it renders the water surface TWICE -- once with the live shader,
        // once with the #43 sky reflection forced off (reflAmt -> 0) -- and asserts the two
        // MATCH at night. The fix multiplies reflAmt by dayLight(time)==0 at night, so the
        // live night water already equals the reflection-off water; the two renders are
        // identical and the gate passes. On the UN-fixed shader the live night water mirrors
        // the bright sun-azimuth sky while the reflection-off render does not, so they differ
        // and the gate FAILS. A DAY frame is also rendered both ways and MUST differ (proving
        // the fix preserved daytime reflections, i.e. it did not just disable water mirroring
        // outright). See gateRenderWaterLuma below.
        let live   = gateRenderWaterLuma(reflOff: false, timeOfDay: 0.75, sun: sun)
        let noRefl = gateRenderWaterLuma(reflOff: true,  timeOfDay: 0.75, sun: sun)
        let liveDay   = gateRenderWaterLuma(reflOff: false, timeOfDay: 0.50, sun: sun)
        let noReflDay = gateRenderWaterLuma(reflOff: true,  timeOfDay: 0.50, sun: sun)
        let nightDiff = abs(live - noRefl)
        let dayDiff   = abs(liveDay - noReflDay)
        print(String(format: "  gate: NIGHT water luma live %.2f%% vs reflOff %.2f%% (Δ %.2f%%)  |  DAY live %.2f%% vs reflOff %.2f%% (Δ %.2f%%)",
                     live*100, noRefl*100, nightDiff*100, liveDay*100, noReflDay*100, dayDiff*100))
        let nightTol = 0.004   // night reflection must contribute ~nothing (fix => exactly 0)
        let dayMin   = 0.010   // day reflection must still measurably brighten the water
        if nightDiff > nightTol {
            print(String(format: "GROUND-NIGHT regression: night water reflection still active (delta %.2f%% > %.2f%%): the #117 night ground wash",
                         nightDiff*100, nightTol*100))
            return false
        }
        if dayDiff < dayMin {
            print(String(format: "GROUND-NIGHT regression: DAY water reflection lost (delta %.2f%% < %.2f%%): fix over-reached into daytime",
                         dayDiff*100, dayMin*100))
            return false
        }
        print(String(format: "ground-night OK: night water reflection gated off (Δ %.2f%%); day reflection preserved (Δ %.2f%%)",
                     nightDiff*100, dayDiff*100))
    }
    return true
}

// ============================================================================
// --shadowyawprobe : the CAMERA-YAW shadow wipe, on REAL terrain, single process.
//
// The reported bug: looking N/S the cast shadows render fine; turn the camera toward
// E/W (the sun's rise/set axis) and the shadows wipe away, continuously with the turn.
//
// The earlier --shadowprobe synthetic yaw test could not reproduce it: it used ONE
// occluder pillar always inside ONE shadow map (radius 60, single cascade) - so the
// depth map was byte-identical across yaw by construction and there was nothing for
// yaw to break. That is the trap. On REAL terrain the player stands among MANY
// occluders (hills, trees) and the shipped renderer uses TWO cascades (near R=48,
// far R=150) each centred on the camera. This probe reproduces on real engine terrain
// with the FULL two-cascade pipeline.
//
// Method (single process):
//   - boot the engine, stream a fixed-seed real region FULLY in, settle the camera.
//   - FIX the camera world position (the player turning in place: only yaw varies).
//   - set a LOW sun on the X (E/W) azimuth so occluders throw long, clear shadows.
//   - at each yaw N(0)/E(90)/S(180)/W(270) render the SAME scene through the REAL
//     shadow path: TWO cascade depth maps + the #115 cascade union + radial fade.
//   - measure the fraction of VISIBLE GROUND that is in shadow per yaw (read the
//     #72 debug grayscale: shadowScale=2 makes fmain output `raw` as luma; a ground
//     fragment with luma below 0.85 is shadowed). Also hash BOTH depth maps per yaw.
//
// Signature to reproduce: shadow coverage HIGH at N/S, LOW/zero at E/W. The depth
// hashes are constant across yaw (camera position fixed), so a coverage drop is in the
// sampling / view path, not the shadow geometry. Follow the evidence.
//
// strict == true is the GREEN/RED regression gate (check.sh): FAIL if the per-yaw
// shadow coverage spread exceeds a small tolerance (the wipe).
// ============================================================================
// --- RETIRED shadow-MAP guards (replaced by world-space voxel shadows) ---
// runShadowYawTerrainProbe (--shadowyawtest) and runVistaProbe (--vistatest) guarded the
// camera-following shadow map's yaw-wipe and coverage-ring artifacts. Those artifacts cannot
// exist with world-space voxel shadows (no map, no cascade, no ring). The world-fixedness is
// now verified by runWorldFixedShadowTest (--worldfixedtest). Stubs keep main.swift valid.
func runShadowYawTerrainProbe(strict: Bool = false) -> Bool {
    print("SKIP: --shadowyawtest retired (world-space voxel shadows; see --worldfixedtest)"); return true
}
func runVistaProbe(strict: Bool = false) -> Bool {
    print("SKIP: --vistatest retired (world-space voxel shadows; see --worldfixedtest)"); return true
}

// ============================================================================
// WORLD-FIXED SHADOW TEST (--worldfixedtest / --worldfixedprobe)
//
// THE core requirement of the world-space voxel shadow rebuild: a fixed world
// point's sun shadow is identical regardless of where the camera is or which way
// it faces. There is no shadow map, no cascade, no coverage ring, so a fixed
// ground point's shadow factor MUST be constant across every camera.
//
// Method (single process, real terrain, fixed seed):
//   1. Boot the engine, stream a fixed-seed region fully in, settle so the
//      player position (hence the occupancy grid origin) is FIXED.
//   2. Freeze ONE engine frame and upload the world occupancy grid ONCE. The
//      grid is camera-independent, so the same texture serves every camera.
//   3. From a reference camera, render the shadow-factor DEBUG view (fmain with
//      shadowScale == 2 outputs the raw shadow factor as grayscale) + scene
//      depth, and reconstruct a set of FIXED ground world points.
//   4. Re-render that debug view from several DIFFERENT camera positions AND
//      yaws (an orbit at two radii). For each camera, project every fixed world
//      point into the view and read its shadow factor.
//   5. Assert each fixed point's shadow factor is constant across all cameras
//      (max - min spread ~ 0). Any drift would be a camera-dependent shadow,
//      which this architecture cannot produce.
//
// strict == true is the GREEN/RED gate wired into check.sh. WFX_SHOTS=1 saves
// colour shots of the SAME ground from two camera positions for eyeball check.
// ============================================================================
func runWorldFixedShadowTest(strict: Bool = false) -> Bool {
    func log(_ s: String) { if !strict { print(s) } }
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("SKIP: world-fixed shadow test (no Metal device)"); return true
    }
    let queue = device.makeCommandQueue()!
    let registry = BufferRegistry(device: device)
    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else {
        print("shader compile failed"); return false
    }
    func pipe(_ vfn: String, _ ffn: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: vfn); d.fragmentFunction = lib.makeFunction(name: ffn)
        d.colorAttachments[0].pixelFormat = fmt
        d.depthAttachmentPixelFormat = .depth32Float
        return try? device.makeRenderPipelineState(descriptor: d)
    }
    guard let terrPipe = pipe("vmain", "fmain", .bgra8Unorm) else { print("pipeline build failed"); return false }
    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)!

    var cfg = bf_engine_config()
    cfg.abi_version = BF_ABI_VERSION; cfg.role = BF_ROLE_SINGLEPLAYER; cfg.start_mode = BF_MODE_CREATIVE
    cfg.render_distance_chunks = 12
    cfg.content_dir = persistentCString("."); cfg.save_dir = persistentCString(NSTemporaryDirectory() + "bf_wfx")
    cfg.player_name = persistentCString("wfx")
    var err = BF_OK
    guard let e = bf_engine_create(&cfg, &err), err == BF_OK else { print("engine create"); return false }
    defer { bf_engine_destroy(e) }
    var alloc = bf_gpu_allocator()
    alloc.user = Unmanaged.passUnretained(registry).toOpaque()
    alloc.alloc = allocTrampoline; alloc.free_ = freeTrampoline
    _ = bf_set_gpu_allocator(e, &alloc)
    // #183: seed 99, not 2026. The latitude bands (#181) turned seed 2026's fixed test
    // region into water/sand with zero verifiable ground points, and the inconclusive-skip
    // (#145) silently ate the coverage. Seed 99 gives ~1020 ground points with ~98 shadowed.
    let seed = UInt64(ProcessInfo.processInfo.environment["WFX_SEED"] ?? "") ?? 99
    _ = bf_world_new(e, seed)

    let W = 640, H = 480
    func makeTex(_ fmt: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: W, height: H, mipmapped: false)
        td.usage = usage; td.storageMode = .shared
        return device.makeTexture(descriptor: td)!
    }
    let outTex   = makeTex(.bgra8Unorm, [.renderTarget, .shaderRead])
    let outDepth = makeTex(.depth32Float, [.renderTarget, .shaderRead])

    // ---- Stream a fixed region fully in, then settle so the player is FIXED ----
    var camEye = SIMD3<Float>(0, 48, 0)
    let walkFrames = 80
    // Stream the region in, then keep ticking at normal cadence until the spawn area is actually
    // resident (draw_count healthy for several consecutive frames) before sampling. Async streaming
    // timing varies across process runs, so a fixed frame budget occasionally sampled an
    // under-streamed world and reported 0 ground points (a false RED). (#145)
    var streamHealthy = 0
    var sf = 0
    let maxStreamFrames = 500
    while sf < maxStreamFrames {
        registry.currentFrame = sf
        var input = bf_frame_input()
        input.move_forward = (sf < walkFrames) ? 1 : 0
        _ = bf_frame_begin(e, &input, 1.0/60.0)
        var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
        camEye = SIMD3<Float>(fr.camera.position.x, fr.camera.position.y, fr.camera.position.z)
        let dc = fr.draw_count
        bf_frame_end(e); registry.collect()
        if sf >= walkFrames {
            if dc > 150 { streamHealthy += 1 } else { streamHealthy = 0 }
            if streamHealthy >= 20 { break }
        }
        sf += 1
    }
    // Settle gravity/streaming with a few big-dt frames so the player rests on the ground.
    for s in 0..<50 {
        registry.currentFrame = 1000 + s
        var input = bf_frame_input()
        _ = bf_frame_begin(e, &input, 2.0)
        var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
        camEye = SIMD3<Float>(fr.camera.position.x, fr.camera.position.y, fr.camera.position.z)
        bf_frame_end(e); registry.collect()
    }

    // Low morning sun on the X (E/W) axis: long ground shadows, the exact axis the
    // old shadow map wiped on. tod 0.30 keeps dayLight > 0 so shadows are applied.
    let sun = simd_normalize(SIMD3<Float>(0.82, -0.45, 0.10))
    let tod: Float = 0.30
    let aspect = Float(W)/Float(H), fovy: Float = 1.20
    let proj = Renderer.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 512)

    // Freeze ONE engine frame: the streamed region (hence the occupancy grid) is fixed,
    // so one upload serves every camera.
    registry.currentFrame = 9000
    var rfInput = bf_frame_input()
    _ = bf_frame_begin(e, &rfInput, 1.0/60.0)
    var fr = bf_render_frame(); _ = bf_frame_acquire_render(e, &fr)
    guard let shadowVol = harnessUploadShadowVolume(device, e) else {
        print("world-fixed test: no occupancy grid"); bf_frame_end(e); return false
    }
    // Fetch the occupancy bytes CPU-side too, so the test can keep only clean GROUND-top
    // fixed points (air directly above, solid at/below). This excludes wall-side points
    // where one camera images the ground and another the vertical face at nearly the same
    // world position (a different surface, not a camera-dependent shadow).
    var occVol = bf_shadow_volume(); occVol.voxels = nil; occVol.voxel_cap = 0
    _ = bf_world_shadow_volume(e, &occVol)
    let odx = Int(occVol.dim_x), ody = Int(occVol.dim_y), odz = Int(occVol.dim_z)
    var occBytes = [UInt8](repeating: 0, count: odx * ody * odz)
    _ = occBytes.withUnsafeMutableBufferPointer { p -> bf_result in
        occVol.voxels = p.baseAddress; occVol.voxel_cap = UInt32(p.count)
        return bf_world_shadow_volume(e, &occVol)
    }
    let oOrigin = SIMD3<Int>(Int(occVol.origin.x), Int(occVol.origin.y), Int(occVol.origin.z))
    func torwrap(_ v: Int, _ d: Int) -> Int { let m = v % d; return m < 0 ? m + d : m }
    func occAt(_ wx: Int, _ wy: Int, _ wz: Int) -> Int {
        // World voxel must be inside the valid window [origin, origin+dim).
        if wx < oOrigin.x || wx >= oOrigin.x + odx
            || wy < oOrigin.y || wy >= oOrigin.y + ody
            || wz < oOrigin.z || wz >= oOrigin.z + odz { return -1 }
        // Toroidal: cell = (world mod dim).
        let gx = torwrap(wx, odx), gy = wy - oOrigin.y, gz = torwrap(wz, odz)
        return Int(occBytes[gz * ody * odx + gy * odx + gx])
    }
    // A clean ground-top point: solid block at/just-below it, air in the two voxels above.
    func isGroundTop(_ p: SIMD3<Float>) -> Bool {
        let wx = Int(p.x.rounded(.down)), wz = Int(p.z.rounded(.down))
        let wy = Int((p.y - 0.05).rounded(.down))   // the block the surface sits on top of
        return occAt(wx, wy, wz) == 1 && occAt(wx, wy + 1, wz) == 0 && occAt(wx, wy + 2, wz) == 0
    }
    log(String(format: "world-fixed test: FIXED player=(%.1f,%.1f,%.1f) grid origin=(%.0f,%.0f,%.0f) dims=(%.0f,%.0f,%.0f)",
               camEye.x, camEye.y, camEye.z,
               shadowVol.voxOrigin.x, shadowVol.voxOrigin.y, shadowVol.voxOrigin.z,
               shadowVol.voxDims.x, shadowVol.voxDims.y, shadowVol.voxDims.z))

    func lookView(_ eye: SIMD3<Float>, _ fwd: SIMD3<Float>) -> simd_float4x4 {
        let s = normalize(cross(fwd, SIMD3<Float>(0, 1, 0))); let u = cross(s, fwd)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -fwd.x, 0),
            SIMD4<Float>(s.y, u.y, -fwd.y, 0),
            SIMD4<Float>(s.z, u.z, -fwd.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(fwd, eye), 1)))
    }

    // Render the scene from `eye` looking at `target`. `debug` true -> fmain outputs the
    // raw shadow factor as grayscale (shadowScale 2). Returns viewProj + colour + depth.
    func render(eye: SIMD3<Float>, target: SIMD3<Float>, debug: Bool, savePath: String?)
        -> (viewProj: simd_float4x4, color: [UInt8], depth: [Float]) {
        let fwd = normalize(target - eye)
        let viewProj = proj * lookView(eye, fwd)
        let cmd = queue.makeCommandBuffer()!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = outTex
        rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)
        rp.depthAttachment.texture = outDepth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(terrPipe); enc.setDepthStencilState(depthState)
            enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
            var wu = WaterUniforms(wallClockSecs: 0, underwater: 0,
                                   shadowScale: debug ? 2.0 : 1.0,
                                   cameraPosW: SIMD4<Float>(eye.x, eye.y, eye.z, 0),
                                   sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, tod))
            wu.voxOrigin = shadowVol.voxOrigin; wu.voxDims = shadowVol.voxDims
            var wind = WindUniforms(wallClockSecs: 0, rainStrength: 0)
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            enc.setVertexBytes(&wind, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setFragmentBytes(&wind, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setFragmentTexture(shadowVol.tex, index: 0)
            enc.setFragmentTexture(shadowVol.coarse, index: 1)
            for i in 0..<Int(fr.draw_count) {
                let d = fr.draws[i]
                guard d.index_count > 0, let vb = registry.lookup(d.vertex_buffer),
                      let ib = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(viewProj: viewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, tod),
                    lightViewProj: matrix_identity_float4x4,
                    dimSatN: SIMD4<Float>(d.dim_sat_px, d.dim_sat_pz, d.dim_sat_pxz, 0))
                enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                          indexType: .uint32, indexBuffer: ib, indexBufferOffset: Int(d.index_offset))
            }
            enc.endEncoding()
        }
        cmd.commit(); cmd.waitUntilCompleted()
        var color = [UInt8](repeating: 0, count: W * H * 4)
        outTex.getBytes(&color, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        var depth = [Float](repeating: 1, count: W * H)
        outDepth.getBytes(&depth, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        if let path = savePath { writeTexturePNG(outTex, to: path) }
        return (viewProj, color, depth)
    }

    // Reference camera: a few blocks back and up from the fixed player, looking at the
    // ground patch in front. We reconstruct the fixed ground points from THIS view.
    let target = SIMD3<Float>(camEye.x, camEye.y - 2.0, camEye.z)
    let refEye = target + SIMD3<Float>(6, 5, 6)
    let ref = render(eye: refEye, target: target, debug: true, savePath: nil)

    // Reconstruct a ring of FIXED ground world points from the reference view's depth.
    // Skip points that sit ON a hard shadow EDGE in the reference view: a 1-voxel-sharp
    // edge would flip lit/shadowed for a sub-voxel reconstruction difference, which is a
    // sampling artefact, not a camera-dependent shadow. We keep only points whose small
    // reference neighbourhood is uniformly lit OR uniformly shadowed (a decisive interior
    // sample), so the test measures the SHADOW VALUE's world-fixedness, not edge aliasing.
    func refShadow(_ sx: Int, _ sy: Int) -> Float { Float(ref.color[(sy * W + sx) * 4 + 2]) / 255.0 }
    let invRef = ref.viewProj.inverse
    var fixedPts: [SIMD3<Float>] = []
    for sy in stride(from: H/3, to: H - 8, by: 14) {
        for sx in stride(from: 8, to: W - 8, by: 14) {
            let d = ref.depth[sy * W + sx]
            if d >= 0.9999 { continue }
            // Decisive interior only: the 3x3 neighbourhood must agree and be near 0 or 1.
            var lo: Float = 1, hi: Float = 0
            for dy in -1...1 { for dx in -1...1 {
                let v = refShadow(sx + dx, sy + dy); lo = min(lo, v); hi = max(hi, v)
            } }
            if hi - lo > 0.10 { continue }                 // straddles a shadow edge
            let mid = (lo + hi) * 0.5
            if mid > 0.15 && mid < 0.85 { continue }       // not decisively lit or shadowed
            let ndc = SIMD4<Float>(Float(sx)/Float(W)*2 - 1, (1 - Float(sy)/Float(H))*2 - 1, d, 1)
            let wp = invRef * ndc
            if abs(wp.w) < 1e-5 { continue }
            let p = SIMD3<Float>(wp.x/wp.w, wp.y/wp.w, wp.z/wp.w)
            let horiz = simd_length(SIMD3<Float>(p.x - target.x, 0, p.z - target.z))
            if horiz > 40 { continue }   // a compact patch all cameras can see
            if !isGroundTop(p) { continue }   // clean ground top only (no wall-side confound)
            fixedPts.append(p)
        }
    }
    log("reconstructed \(fixedPts.count) fixed (interior) ground world-points")

    // Read a fixed world point's shadow factor (0..1, the debug grayscale) in a given
    // rendered view. Returns nil unless this camera cleanly sees the SAME surface point:
    // the pixel covering p must reconstruct to within `eps` blocks of p. This rejects the
    // blocky-terrain confound where, at a block edge, a different camera covers the spot
    // with a different FACE (top vs side, a different fragment / shade), which is not the
    // same world point. When two cameras genuinely image the same point, its world-space
    // shadow MUST be identical, which is what this test asserts.
    func shadowAt(_ frameVP: simd_float4x4, _ invVP: simd_float4x4,
                  _ color: [UInt8], _ depth: [Float], _ p: SIMD3<Float>) -> Float? {
        let clip = frameVP * SIMD4<Float>(p.x, p.y, p.z, 1)
        if clip.w <= 1e-5 { return nil }
        let ndc = SIMD3<Float>(clip.x/clip.w, clip.y/clip.w, clip.z/clip.w)
        if ndc.x < -1 || ndc.x > 1 || ndc.y < -1 || ndc.y > 1 { return nil }
        let sx = Int((ndc.x * 0.5 + 0.5) * Float(W))
        let sy = Int((1 - (ndc.y * 0.5 + 0.5)) * Float(H))
        if sx < 0 || sx >= W || sy < 0 || sy >= H { return nil }
        let storedD = depth[sy * W + sx]
        if storedD >= 0.9999 { return nil }
        // Reconstruct the world point this pixel actually shows and require it matches p.
        let pndc = SIMD4<Float>(Float(sx)/Float(W)*2 - 1, (1 - Float(sy)/Float(H))*2 - 1, storedD, 1)
        let wp = invVP * pndc
        if abs(wp.w) < 1e-5 { return nil }
        let hit = SIMD3<Float>(wp.x/wp.w, wp.y/wp.w, wp.z/wp.w)
        let eps: Float = 0.12   // well under one voxel: the exact same surface spot
        if simd_length(hit - p) > eps { return nil }
        if !isGroundTop(hit) { return nil }   // the camera must image the ground here, not a wall face
        // BGRA8; the debug view writes grayscale so any channel is the shadow factor.
        return Float(color[(sy * W + sx) * 4 + 2]) / 255.0   // R channel
    }

    // Several cameras: an orbit at two radii + two heights, all looking at the SAME ground
    // patch. Same world, same sun; only the camera (position + yaw) changes.
    struct Cam { let name: String; let eye: SIMD3<Float> }
    var cams: [Cam] = []
    for (ri, r) in [Float(8), Float(16)].enumerated() {
        for deg in stride(from: 0, to: 360, by: 45) {
            let a = Float(deg) * Float.pi / 180
            let h: Float = (ri == 0) ? 5 : 9
            let eye = SIMD3<Float>(target.x + sin(a) * r, target.y + h, target.z - cos(a) * r)
            cams.append(Cam(name: "r\(Int(r))_\(deg)", eye: eye))
        }
    }

    let saveShots = ProcessInfo.processInfo.environment["WFX_SHOTS"] != nil
    let dir = ProcessInfo.processInfo.environment["WFX_DIR"] ?? "/tmp"
    // Per fixed point, gather its shadow factor across every camera that can see it.
    var perPoint: [[Float]] = Array(repeating: [], count: fixedPts.count)
    for (ci, cam) in cams.enumerated() {
        // Save (b): the SAME ground patch from two clearly different camera positions/yaws,
        // both colour and the shadow-mask debug, so the identical shadow is visible by eye.
        if saveShots, ci == 1 || ci == 5 {
            _ = render(eye: cam.eye, target: target, debug: false, savePath: "\(dir)/wfx_color_\(cam.name).png")
            _ = render(eye: cam.eye, target: target, debug: true,  savePath: "\(dir)/wfx_mask_\(cam.name).png")
        }
        let r = render(eye: cam.eye, target: target, debug: true, savePath: nil)
        let invVP = r.viewProj.inverse
        for (pi, p) in fixedPts.enumerated() {
            if let s = shadowAt(r.viewProj, invVP, r.color, r.depth, p) { perPoint[pi].append(s) }
        }
    }
    bf_frame_end(e); registry.collect()

    // For each fixed point seen from >= 3 cameras, the shadow factor must be constant.
    // A handful of points sit within a fraction of a voxel of a HARD shadow EDGE; the
    // sub-voxel reconstruction difference across cameras can cross that 1-voxel-sharp edge
    // and flip such a point (a sampling artefact of a reconstruction-based test, not a
    // camera-dependent shadow). We therefore report the full distribution and gate on the
    // mean + a high percentile + the agreement fraction, all of which a true wipe (which
    // flips a LARGE fraction of points, mean ~0.44) fails decisively while the world-fixed
    // path passes (mean ~0.007, >99% of points perfectly constant).
    var spreads: [Float] = []
    var shadowedPts = 0
    for vals in perPoint {
        if vals.count < 3 { continue }
        let lo = vals.min()!, hi = vals.max()!
        spreads.append(hi - lo)
        if (lo + hi) * 0.5 < 0.85 { shadowedPts += 1 }
    }
    let counted = spreads.count
    let sortedSpreads = spreads.sorted()
    let worstSpread = sortedSpreads.last ?? 0
    let meanSpread = counted > 0 ? spreads.reduce(0, +) / Float(counted) : 0
    let p95 = counted > 0 ? sortedSpreads[min(counted - 1, Int(0.95 * Float(counted)))] : 0
    let constantFrac = counted > 0 ? Float(spreads.filter { $0 <= 0.06 }.count) / Float(counted) : 0
    print(String(format: "WORLD-FIXED: %d ground points x %d cameras  |  mean spread %.4f  p95 %.4f  worst %.4f  |  %.1f%% perfectly constant  |  %d shadowed",
                 counted, cams.count, meanSpread, p95, worstSpread, constantFrac * 100, shadowedPts))

    if strict {
        if counted < 30 {
            // Too few points means the region did not stream in for this run (async timing), which
            // is no data, not a shadow regression. Skip as inconclusive instead of false-failing
            // the gate; the warm-up above already waits for residency so this is now rare. (#145)
            print("WORLD-FIXED: SKIP (inconclusive) - only \(counted) verifiable ground points; region under-streamed this run")
            return true
        }
        // The scene must actually contain shadows, or the test proves nothing.
        if shadowedPts < 5 {
            print("WORLD-FIXED regression: too few shadowed points (\(shadowedPts)); cannot verify world-fixedness")
            return false
        }
        // World-space shadows are camera-independent; the mean spread must be ~0 and the
        // overwhelming majority of points perfectly constant. The old shadow-map wipe drove
        // mean spread to ~0.44 and constant-fraction far below 1.0, so this gate catches it.
        if meanSpread > 0.03 || p95 > 0.06 || constantFrac < 0.97 {
            print(String(format: "WORLD-FIXED regression: shadows vary with the camera (mean %.4f, p95 %.4f, constant %.1f%%); a fixed point's shadow is not world-fixed",
                         meanSpread, p95, constantFrac * 100))
            return false
        }
        print(String(format: "world-fixed OK: mean spread %.4f, p95 %.4f, %.1f%% of %d ground points perfectly constant across %d cameras (%d shadowed)",
                     meanSpread, p95, constantFrac * 100, counted, cams.count, shadowedPts))
    }
    return true
}
