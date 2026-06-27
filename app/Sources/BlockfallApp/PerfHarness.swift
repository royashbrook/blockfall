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

// Write a (shared-storage) bgra8 texture to a PNG. Used by the headless --shot mode
// so visuals can be verified from the terminal without taking over the desktop. (#52)
private func writeTexturePNG(_ tex: MTLTexture, to path: String) {
    let w = tex.width, h = tex.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&data, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let cs = CGColorSpaceCreateDeviceRGB()
    let bi = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs, bitmapInfo: bi.rawValue),
          let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     "public.png" as CFString, 1, nil) else {
        print("shot: failed to encode PNG"); return
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote shot: \(path)")
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

    let shadowDesc = MTLRenderPipelineDescriptor()
    shadowDesc.vertexFunction = lib.makeFunction(name: "shadowVmain")
    shadowDesc.fragmentFunction = nil
    shadowDesc.depthAttachmentPixelFormat = .depth32Float
    let shadowPipeline = try? device.makeRenderPipelineState(descriptor: shadowDesc)

    // Prop pipeline (#52: GPU-instanced, same as the live renderer).
    let propPipeline: MTLRenderPipelineState? = {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction   = lib.makeFunction(name: "propInstVmain")
        d.fragmentFunction = lib.makeFunction(name: "propFmain")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        d.depthAttachmentPixelFormat = .depth32Float
        return try? device.makeRenderPipelineState(descriptor: d)
    }()
    // #80 depth-only prop pipeline so props (trees) cast shadows in --shot too.
    let propShadowPipeline: MTLRenderPipelineState? = {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction   = lib.makeFunction(name: "propInstVmain")
        d.fragmentFunction = nil
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
    let kPropVertsPerInstance = 4 * 36

    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)
    let skyDSD = MTLDepthStencilDescriptor(); skyDSD.depthCompareFunction = .always; skyDSD.isDepthWriteEnabled = false
    let skyDepthState = device.makeDepthStencilState(descriptor: skyDSD)
    let shDSD = MTLDepthStencilDescriptor(); shDSD.depthCompareFunction = .lessEqual; shDSD.isDepthWriteEnabled = true
    let shadowDepthState = device.makeDepthStencilState(descriptor: shDSD)
    let noDSD = MTLDepthStencilDescriptor(); noDSD.depthCompareFunction = .always; noDSD.isDepthWriteEnabled = false
    let noDepthState = device.makeDepthStencilState(descriptor: noDSD)

    let entR = EntityRenderer(device: device, colorFormat: .rgba16Float)

    let ssd = MTLSamplerDescriptor()
    ssd.minFilter = .linear; ssd.magFilter = .linear
    ssd.sAddressMode = .clampToEdge; ssd.tAddressMode = .clampToEdge
    ssd.compareFunction = .lessEqual
    let shadowSampler = device.makeSamplerState(descriptor: ssd)!

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
    _ = bf_world_new(e, 2026)

    // ---- Render targets (full size; shadow map at the live 2048) ----------
    let W = 1280, H = 800
    let HW = W/2, HH = H/2
    let kShadowRes = 2048
    func makeTex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ priv: Bool = true) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = priv ? .private : .shared
        return device.makeTexture(descriptor: td)!
    }
    let shadowTex  = makeTex(.depth32Float, kShadowRes, kShadowRes, [.renderTarget, .shaderRead])
    let hdrColor   = makeTex(.rgba16Float,  W, H, [.renderTarget, .shaderRead])
    let hdrDepth   = makeTex(.depth32Float, W, H, [.renderTarget])
    let bloomBrt   = makeTex(.rgba16Float,  HW, HH, [.renderTarget, .shaderRead])
    let bloomBlurA = makeTex(.rgba16Float,  HW, HH, [.renderTarget, .shaderRead])
    let output     = makeTex(.bgra8Unorm,   W, H, [.renderTarget], false)

    var frameIdx = 0
    var lastShotPropN = 0
    var fpsSamples: [Double] = []
    var peakMem = 0.0
    let start = CACurrentMediaTime()
    var lastDt = CACurrentMediaTime()

    // #89 diagnosis: lets the yaw-sweep experiment turn the camera WITHOUT walking
    // forward, so the camera ORIGIN is identical at every yaw and the only variable is
    // the view direction. (The default keeps move_forward=1 so streaming churns.)
    var lastLightVP = simd_float4x4(0)
    var lastCamPosProbe = SIMD3<Float>(0, 0, 0)
    func renderOneFrame(pitch: Float = 0, yaw: Float = 0.004, forward: Float = 1) {
        frameIdx += 1; registry.currentFrame = frameIdx
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
        let camPosW = SIMD4<Float>(
            -(viewM.columns.0.x*vt.x + viewM.columns.1.x*vt.y + viewM.columns.2.x*vt.z),
            -(viewM.columns.0.y*vt.x + viewM.columns.1.y*vt.y + viewM.columns.2.y*vt.z),
            -(viewM.columns.0.z*vt.x + viewM.columns.1.z*vt.y + viewM.columns.2.z*vt.z), 0)
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
        var lightCam = SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z)
        if let s = ProcessInfo.processInfo.environment["BF_LIGHT_FIXCAM"] {
            let p = s.split(separator: ",").compactMap { Float($0) }
            if p.count == 3 { lightCam = SIMD3<Float>(p[0], p[1], p[2]) }
        }
        let lightViewProj = Renderer.buildLightMatrix(
            sunDir: SIMD3<Float>(sun.x, sun.y, sun.z),
            camPos: lightCam, radius: 150, res: 1536)
        lastLightVP = lightViewProj
        lastCamPosProbe = lightCam

        var windU = WindUniforms(wallClockSecs: wallClock, rainStrength: 0)
        let cmd = queue.makeCommandBuffer()!

        // PASS 1: shadow depth
        if let sp = shadowPipeline {
            let srp = MTLRenderPassDescriptor()
            srp.depthAttachment.texture = shadowTex
            srp.depthAttachment.loadAction = .clear; srp.depthAttachment.storeAction = .store
            srp.depthAttachment.clearDepth = 1.0
            if let enc = cmd.makeRenderCommandEncoder(descriptor: srp) {
                enc.setRenderPipelineState(sp); enc.setDepthStencilState(shadowDepthState)
                enc.setCullMode(.front); enc.setDepthBias(2.0, slopeScale: 2.0, clamp: 0.0)
                // #49: mirror the live renderer — cast from the UN-culled shadow occluder
                // list, not the view-cone-culled draw list (the harness was lying: it made
                // terrain shadows look view-dependent when the shipping path is not).
                let sN = Int(f.shadow_draw_count); let sD = f.shadow_draws
                let useS = (sN > 0 && sD != nil)
                for i in 0..<(useS ? sN : Int(f.draw_count)) {
                    let d = useS ? sD![i] : f.draws[i]
                    guard d.index_count > 0, let vb = registry.lookup(d.vertex_buffer),
                          let ib = registry.lookup(d.index_buffer) else { continue }
                    var su = ShadowVertUniforms(lightViewProj: lightViewProj,
                        chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), 0))
                    enc.setVertexBuffer(vb, offset: Int(d.vertex_offset), index: 0)
                    enc.setVertexBytes(&su, length: MemoryLayout<ShadowVertUniforms>.stride, index: 1)
                    enc.setVertexBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 2)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: Int(d.index_count),
                                              indexType: .uint32, indexBuffer: ib, indexBufferOffset: Int(d.index_offset))
                }
                // #80 props (trees) cast shadows here too, with the light matrix as viewProj.
                let spropN = Int(f.prop_instance_count)
                if spropN > 0, let insts = f.prop_instances, let psp = propShadowPipeline {
                    let need = spropN * MemoryLayout<bf_prop_instance>.stride
                    if propInstBuf == nil || propInstBuf!.length < need {
                        propInstBuf = device.makeBuffer(length: max(need, 65536), options: .storageModeShared)
                    }
                    if let ib = propInstBuf {
                        memcpy(ib.contents(), insts, need)
                        let dayBright = 0.30 + 0.70 * Renderer.dayLight(f.camera.time_of_day)
                        var psu = PropUniforms(viewProj: lightViewProj,
                                               params: SIMD4<Float>(dayBright, Float(wallClock), 0, 0))
                        enc.setRenderPipelineState(psp); enc.setCullMode(.front)
                        enc.setDepthBias(2.0, slopeScale: 2.0, clamp: 0.0)
                        enc.setVertexBuffer(ib, offset: 0, index: 0)
                        enc.setVertexBytes(&psu, length: MemoryLayout<PropUniforms>.stride, index: 1)
                        enc.setVertexBuffer(propModelTable, offset: 0, index: 2)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0,
                                           vertexCount: kPropVertsPerInstance, instanceCount: spropN)
                    }
                }
                enc.endEncoding()
            }
        }

        // PASS 2: HDR scene (sky + terrain + entities)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdrColor
        rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.45, green: 0.62, blue: 0.86, alpha: 1)
        rp.depthAttachment.texture = hdrDepth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = .dontCare
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
            if ProcessInfo.processInfo.environment["BF_SHADOW_DEBUG"] == "1" { wu.shadowScale = 2.0 } // #72 debug view
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            enc.setFragmentBytes(&windU, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setFragmentTexture(shadowTex, index: 0)
            enc.setFragmentTexture(shadowTex, index: 1)   // #46 far cascade (same map in perf harness)
            enc.setFragmentSamplerState(shadowSampler, index: 0)
            for i in 0..<Int(f.draw_count) {
                let d = f.draws[i]
                guard d.index_count > 0, let vb = registry.lookup(d.vertex_buffer),
                      let ib = registry.lookup(d.index_buffer) else { continue }
                var u = Uniforms(viewProj: viewProj,
                    chunkOrigin: SIMD4<Float>(Float(d.chunk_origin.x), Float(d.chunk_origin.y), Float(d.chunk_origin.z), d.dim_saturation),
                    sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, f.camera.time_of_day),
                    lightViewProj: lightViewProj,
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
                    var pu2 = PropUniforms(viewProj: viewProj, params: SIMD4<Float>(dayBright, Float(wallClock), 0, 0))
                    enc.setRenderPipelineState(pp); enc.setDepthStencilState(depthState); enc.setCullMode(.none)
                    enc.setVertexBuffer(ib, offset: 0, index: 0)
                    enc.setVertexBytes(&pu2, length: MemoryLayout<PropUniforms>.stride, index: 1)
                    enc.setVertexBuffer(propModelTable, offset: 0, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: kPropVertsPerInstance, instanceCount: propN)
                }
            }

            enc.setRenderPipelineState(terrainPipeline)
            enc.setDepthStencilState(depthState)
            entR.encode(enc, viewProj: viewProj, entities: f.entities, count: Int(f.entity_count))

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
            let crp = MTLRenderPassDescriptor()
            crp.colorAttachments[0].texture = output
            crp.colorAttachments[0].loadAction = .dontCare; crp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: crp) {
                enc.setRenderPipelineState(cp); enc.setDepthStencilState(noDepthState); enc.setCullMode(.none)
                enc.setFragmentTexture(hdrColor, index: 0)
                enc.setFragmentTexture(bloomBrt, index: 1)
                // God rays (#44): mirror the LIVE renderer so the headless --shot composites
                // the same scattered sun shafts. The harness previously left these off
                // (godrayStrength defaulted to 0), so the screenshot path could not reproduce
                // the live dusk ground-whiteout the rays cause. Match the live formula.
                let dayT  = Renderer.dayLight(f.camera.time_of_day)
                let toSun = simd_normalize(SIMD3<Float>(-sun.x, -sun.y, -sun.z))
                let sunClip = viewProj * SIMD4<Float>(camPosW.x + toSun.x * 2000,
                                                      camPosW.y + toSun.y * 2000,
                                                      camPosW.z + toSun.z * 2000, 1)
                var grStrength: Float = 0, sunSX: Float = 0, sunSY: Float = 0
                let godOff = ProcessInfo.processInfo.environment["BF_SHOT_NOGODRAY"] == "1"
                if sunClip.w > 0.001 && !godOff {
                    sunSX = (sunClip.x / sunClip.w) * 0.5 + 0.5
                    sunSY = 0.5 - (sunClip.y / sunClip.w) * 0.5
                    grStrength = dayT * 0.45
                }
                var pu = PostUniforms(bloomStrength: 0.12, vignetteStr: 0.22, satBoost: 1.30,
                                      rainStrength: 0, wallClockSecs: 0,
                                      godrayStrength: grStrength, sunScreenX: sunSX, sunScreenY: sunSY,
                                      sunColorR: 1.0, sunColorG: 0.6 + 0.35 * dayT, sunColorB: 0.3 + 0.5 * dayT)
                enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
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
        let travel = treeMode ? 320 : 700
        for _ in 0..<travel { renderOneFrame(yaw: 0) }       // travel STRAIGHT to cross into grass/forest
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
        let noWalk = ProcessInfo.processInfo.environment["BF_SHOT_NOWALK"] == "1"
        // #89: before the yaw sweep, stand still long enough for gravity + async streaming
        // to converge, so the camera lands on the SAME ground column at every yaw (otherwise
        // free-fall + per-run streaming timing drift the origin and confound the experiment).
        if noWalk { for _ in 0..<400 { renderOneFrame(yaw: 0, forward: 0) } }
        if let yawStr = ProcessInfo.processInfo.environment["BF_SHOT_YAW"], let yawDeg = Float(yawStr) {
            let total = yawDeg * Float.pi / 180.0
            let frames = 60
            for _ in 0..<frames { renderOneFrame(yaw: total / Float(frames), forward: noWalk ? 0 : 1.0) }
        }
        for _ in 0..<24  { renderOneFrame(yaw: 0, forward: noWalk ? 0 : 1.0) } // settle
        // #89 decisive probe: dump the camera world pos and the FULL light-space view-proj
        // matrix. The shadow map content and every fragment's shadowPos derive solely from
        // this matrix + world position, so if it is identical across yaws, no fixed world
        // point's shadow can change with yaw. Compared against the rendered pixels below.
        if ProcessInfo.processInfo.environment["BF_SHADOW_PROBE"] == "1" {
            let m = lastLightVP
            print(String(format: "PROBE camPos= %.4f %.4f %.4f",
                         lastCamPosProbe.x, lastCamPosProbe.y, lastCamPosProbe.z))
            for c in 0..<4 {
                let col = m[c]
                print(String(format: "PROBE lightVP col%d = % .8f % .8f % .8f % .8f",
                             c, col.x, col.y, col.z, col.w))
            }
        }
        print("shot: prop instances in final frame = \(lastShotPropN)")
        writeTexturePNG(output, to: shot)
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
    let hdrDepth = tex(.depth32Float, [.renderTarget], false)
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
    rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = .dontCare
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
        enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
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
func runShadowYawProbe() -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); return false }
    let queue = device.makeCommandQueue()!
    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else {
        print("shader compile failed"); return false
    }

    func pipe(_ v: String, _ frag: String?, color: MTLPixelFormat?, depth: Bool) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = frag.flatMap { lib.makeFunction(name: $0) }
        if let c = color { d.colorAttachments[0].pixelFormat = c }
        if depth { d.depthAttachmentPixelFormat = .depth32Float }
        return try? device.makeRenderPipelineState(descriptor: d)
    }
    guard let shadowPipe = pipe("shadowVmain", nil, color: nil, depth: true),
          let terrainPipe = pipe("vmain", "fmain", color: .bgra8Unorm, depth: true) else {
        print("pipeline build failed"); return false
    }
    let shDSD = MTLDepthStencilDescriptor(); shDSD.depthCompareFunction = .lessEqual; shDSD.isDepthWriteEnabled = true
    let shadowDepthState = device.makeDepthStencilState(descriptor: shDSD)
    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)

    let ssd = MTLSamplerDescriptor()
    ssd.minFilter = .linear; ssd.magFilter = .linear
    ssd.sAddressMode = .clampToEdge; ssd.tAddressMode = .clampToEdge
    ssd.compareFunction = .lessEqual
    let shadowSampler = device.makeSamplerState(descriptor: ssd)!

    // ---- Build a fixed scene as PackedVertex triangles (no engine, no streaming) ----
    // PackedVertex: pos = x|y<<6|z<<12 (+ sub-voxel in high bits, unused here),
    // normuv bits[0:3]=faceNorm, bits[3:5]=AO. sky=15 (full daylight), block=0.
    struct PV { var pos: UInt32; var normuv: UInt32; var material: UInt16; var sky: UInt8; var block: UInt8; var reserved: UInt32 }
    func pv(_ x: Int, _ y: Int, _ z: Int, _ norm: UInt32, _ mat: UInt16) -> PV {
        let pos = UInt32(x & 0x3f) | (UInt32(y & 0x3f) << 6) | (UInt32(z & 0x3f) << 12)
        let normuv = norm | (3 << 3)   // AO = 3 (fully open)
        return PV(pos: pos, normuv: normuv, material: mat, sky: 15, block: 0, reserved: 0)
    }
    var verts: [PV] = []
    var idx: [UInt32] = []
    func quad(_ a: PV, _ b: PV, _ c: PV, _ d: PV) {
        let base = UInt32(verts.count)
        verts.append(a); verts.append(b); verts.append(c); verts.append(d)
        // CCW winding (terrain pass uses .back cull, .counterClockwise front).
        idx.append(base); idx.append(base+1); idx.append(base+2)
        idx.append(base); idx.append(base+2); idx.append(base+3)
    }
    // Ground: a flat slab of top faces (faceNorm 2 = +Y) at y=0, mat 3 (stone, mid-luma
    // so the #47 specular is active). Spans x,z in [0,40].
    let gy = 0, gMat: UInt16 = 3
    for gx in 0..<40 { for gz in 0..<40 {
        // CCW when viewed from above (+Y) so the top face is front-facing.
        quad(pv(gx, gy, gz, 2, gMat), pv(gx, gy, gz+1, 2, gMat),
             pv(gx+1, gy, gz+1, 2, gMat), pv(gx+1, gy, gz, 2, gMat))
    } }
    // Occluder pillar: a tall thin box near the centre (x 19..21, z 19..21, y 1..12).
    // Four side faces are enough to cast a clear shadow across the ground.
    let px0 = 19, px1 = 21, pz0 = 19, pz1 = 21, py0 = 1, py1 = 12, pMat: UInt16 = 3
    for y in py0..<py1 {
        // +X face (norm 0), -X (norm 1), +Z (norm 4), -Z (norm 5)
        quad(pv(px1, y, pz0, 0, pMat), pv(px1, y, pz1, 0, pMat), pv(px1, y+1, pz1, 0, pMat), pv(px1, y+1, pz0, 0, pMat))
        quad(pv(px0, y, pz1, 1, pMat), pv(px0, y, pz0, 1, pMat), pv(px0, y+1, pz0, 1, pMat), pv(px0, y+1, pz1, 1, pMat))
        quad(pv(px0, y, pz1, 4, pMat), pv(px1, y, pz1, 4, pMat), pv(px1, y+1, pz1, 4, pMat), pv(px0, y+1, pz1, 4, pMat))
        quad(pv(px1, y, pz0, 5, pMat), pv(px0, y, pz0, 5, pMat), pv(px0, y+1, pz0, 5, pMat), pv(px1, y+1, pz0, 5, pMat))
    }
    let vbuf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<PV>.stride, options: .storageModeShared)!
    let ibuf = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)!

    // Fixed HIGH sun (worst case for the reported bug) pointing down + slightly toward
    // +X/+Z so the pillar throws a definite ground shadow. (sun_dir points FROM the sun.)
    let sun = simd_normalize(SIMD3<Float>(0.45, -1.25, 0.35))
    // Fixed camera POSITION (the whole point: only yaw varies). Up high, looking down at
    // the pillar + its shadow.
    let camPos = SIMD3<Float>(20, 42, 20)
    // World point we probe: a ground texel that sits INSIDE the pillar's cast shadow.
    // With the sun coming from +X/+Z and high, the shadow falls toward -X/-Z of the pillar.
    // A line of probe points marching from the pillar base outward along the SHADOW
    // direction. The shadow ray travels in +sun_dir (downward, toward +X/+Z here), so the
    // pillar's shadow lands on the ground toward +X/+Z. We march the ground from just past
    // the pillar (x>21) outward; some points land in shadow, some in light. The test is
    // whether EACH fixed world point's shadow value is constant across yaws.
    var probeLine: [SIMD3<Float>] = []
    let shadowDir = simd_normalize(SIMD3<Float>(sun.x, 0, sun.z))   // ground-plane shadow direction
    for k in 0..<12 {
        let t = Float(k) * 1.3
        probeLine.append(SIMD3<Float>(21.5 + shadowDir.x * t, 0.02, 21.5 + shadowDir.z * t))
    }

    let W = 1600, H = 1200
    let kShadowRes = 1536
    func tex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ shared: Bool) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: td)!
    }
    // Shared so we can read the depth back and HASH it: proves the shadow MAP content is
    // byte-identical across yaws (it must be - lightVP + geometry never change with yaw).
    let shadowTex = tex(.depth32Float, kShadowRes, kShadowRes, [.renderTarget, .shaderRead], true)
    let outTex    = tex(.bgra8Unorm, W, H, [.renderTarget, .shaderRead], true)
    let outDepth  = tex(.depth32Float, W, H, [.renderTarget], false)

    let proj = Renderer.perspective(fovy: 1.35, aspect: Float(W)/Float(H), near: 0.05, far: 512)
    // The light matrix depends only on (sun, camPos); camPos is FIXED here, so it is the
    // SAME for every yaw by construction; print it once to confirm.
    let lightVP = Renderer.buildLightMatrix(sunDir: sun, camPos: camPos, radius: 60, res: Float(kShadowRes))

    // Average a small block so a fixed world point that projects to slightly different
    // SUBPIXEL screen coords at each yaw is not read off the soft PCF penumbra at a
    // different spot (which would masquerade as a yaw-dependent shadow). Averaging over
    // an 11x11 block cancels that subpixel sampling jitter.
    func readPixel(_ t: MTLTexture, _ x: Int, _ y: Int, half: Int = 5) -> SIMD3<Float> {
        var acc = SIMD3<Float>(0, 0, 0); var n: Float = 0
        for dy in -half...half { for dx in -half...half {
            let cx = min(max(0, x + dx), t.width - 1), cy = min(max(0, y + dy), t.height - 1)
            var px = [UInt8](repeating: 0, count: 4)
            t.getBytes(&px, bytesPerRow: t.width * 4, from: MTLRegionMake2D(cx, cy, 1, 1), mipmapLevel: 0)
            acc += SIMD3<Float>(Float(px[2]) / 255.0, Float(px[1]) / 255.0, Float(px[0]) / 255.0)
            n += 1
        } }
        return acc / n
    }
    func project(_ p: SIMD3<Float>, _ vp: simd_float4x4) -> (Int, Int) {
        let clip = vp * SIMD4<Float>(p.x, p.y, p.z, 1)
        let ndc = SIMD3<Float>(clip.x/clip.w, clip.y/clip.w, clip.z/clip.w)
        let sx = Int((ndc.x * 0.5 + 0.5) * Float(W))
        let sy = Int((1.0 - (ndc.y * 0.5 + 0.5)) * Float(H))
        return (sx, sy)
    }

    // Build a yaw-only view matrix at the fixed camPos. yaw rotates about world Y; we
    // tilt down a fixed pitch so the ground + shadow stay framed at every yaw.
    func viewMatrix(yawDeg: Float) -> simd_float4x4 {
        let yaw = yawDeg * Float.pi / 180.0
        let pitch: Float = -1.25   // look almost straight down (keeps the ground framed at every yaw)
        // Camera basis
        let cp = cos(pitch), sp = sin(pitch), cy = cos(yaw), sy = sin(yaw)
        // forward (into scene)
        let fwd = simd_normalize(SIMD3<Float>(sy * cp, sp, -cy * cp))
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(fwd, worldUp))
        let up = simd_cross(right, fwd)
        // View = inverse(rotation) then translate. Column-major, forward = -z.
        let r = right, u = up, f = -fwd
        return simd_float4x4(columns: (
            SIMD4<Float>(r.x, u.x, f.x, 0),
            SIMD4<Float>(r.y, u.y, f.y, 0),
            SIMD4<Float>(r.z, u.z, f.z, 0),
            SIMD4<Float>(-simd_dot(r, camPos), -simd_dot(u, camPos), -simd_dot(f, camPos), 1)))
    }

    print(String(format: "PROBE fixed camPos = %.3f %.3f %.3f  sun = %.3f %.3f %.3f",
                 camPos.x, camPos.y, camPos.z, sun.x, sun.y, sun.z))
    print("PROBE light matrix is built once from (sun,camPos) only - identical for every yaw by construction.")
    print("shadowDbg per world point (rows) x yaw (cols). 1.0 = lit, <1 = shadowed.")

    // Collect shadowDbg for every probe point at every yaw, then print as a table so
    // each ROW (a fixed world point) can be read across yaws.
    let yaws: [Float] = [0, 45, 90, 135]
    var dbgTable = [[Float]](repeating: [Float](repeating: 0, count: yaws.count), count: probeLine.count)
    var colTable = [[SIMD3<Float>]](repeating: [SIMD3<Float>](repeating: .zero, count: yaws.count), count: probeLine.count)

    for (yi, yawDeg) in yaws.enumerated() {
        let viewM = viewMatrix(yawDeg: yawDeg)
        let viewProj = proj * viewM

        // Render twice: once in #72 debug mode (shadowScale=2 => grayscale = raw shadow),
        // once in normal colour (shadowScale=1 => includes the #47 specular).
        func renderPass(debug: Bool) {
            let cmd = queue.makeCommandBuffer()!
            // Shadow depth
            let srp = MTLRenderPassDescriptor()
            srp.depthAttachment.texture = shadowTex
            srp.depthAttachment.loadAction = .clear; srp.depthAttachment.storeAction = .store; srp.depthAttachment.clearDepth = 1.0
            if let enc = cmd.makeRenderCommandEncoder(descriptor: srp) {
                enc.setRenderPipelineState(shadowPipe); enc.setDepthStencilState(shadowDepthState)
                enc.setCullMode(.front); enc.setDepthBias(2.0, slopeScale: 2.0, clamp: 0.0)
                var su = ShadowVertUniforms(lightViewProj: lightVP, chunkOrigin: SIMD4<Float>(0, 0, 0, 0))
                var wind = WindUniforms(wallClockSecs: 0, rainStrength: 0)
                enc.setVertexBuffer(vbuf, offset: 0, index: 0)
                enc.setVertexBytes(&su, length: MemoryLayout<ShadowVertUniforms>.stride, index: 1)
                enc.setVertexBytes(&wind, length: MemoryLayout<WindUniforms>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: idx.count, indexType: .uint32, indexBuffer: ibuf, indexBufferOffset: 0)
                enc.endEncoding()
            }
            // Colour pass
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = outTex
            rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.45, green: 0.62, blue: 0.86, alpha: 1)
            rp.depthAttachment.texture = outDepth
            rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = .dontCare
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                enc.setRenderPipelineState(terrainPipe); enc.setDepthStencilState(depthState)
                enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
                var u = Uniforms(viewProj: viewProj, chunkOrigin: SIMD4<Float>(0, 0, 0, 1),
                                 sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, 0.25),
                                 lightViewProj: lightVP, dimSatN: SIMD4<Float>(1, 1, 1, 0),
                                 lightViewProjF: lightVP)
                var wu = WaterUniforms(wallClockSecs: 0, underwater: 0,
                                       shadowScale: debug ? 2.0 : 1.0,
                                       cameraPosW: SIMD4<Float>(camPos.x, camPos.y, camPos.z, 0),
                                       sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, 0.25))
                var wind = WindUniforms(wallClockSecs: 0, rainStrength: 0)
                enc.setVertexBuffer(vbuf, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
                enc.setVertexBytes(&wind, length: MemoryLayout<WindUniforms>.stride, index: 3)
                enc.setFragmentBytes(&wind, length: MemoryLayout<WindUniforms>.stride, index: 3)
                enc.setFragmentTexture(shadowTex, index: 0)
                enc.setFragmentTexture(shadowTex, index: 1)
                enc.setFragmentSamplerState(shadowSampler, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: idx.count, indexType: .uint32, indexBuffer: ibuf, indexBufferOffset: 0)
                enc.endEncoding()
            }
            cmd.commit(); cmd.waitUntilCompleted()
        }

        // Sample the shadow-debug grayscale at each fixed world point.
        renderPass(debug: true)
        // Hash the whole shadow depth map to prove its content is identical across yaws.
        do {
            let n = kShadowRes * kShadowRes
            var buf = [Float](repeating: 0, count: n)
            shadowTex.getBytes(&buf, bytesPerRow: kShadowRes * 4,
                               from: MTLRegionMake2D(0, 0, kShadowRes, kShadowRes), mipmapLevel: 0)
            var h: UInt64 = 1469598103934665603
            for v in buf { h = (h ^ UInt64(v.bitPattern)) &* 1099511628211 }
            print(String(format: "PROBE yaw %3.0f  shadowMap hash = %016llx", yawDeg, h))
        }
        for (pi, p) in probeLine.enumerated() {
            let (sx, sy) = project(p, viewProj)
            dbgTable[pi][yi] = readPixel(outTex, sx, sy).x
        }
        // Sample full colour (includes #47 specular) at each point.
        renderPass(debug: false)
        for (pi, p) in probeLine.enumerated() {
            let (sx, sy) = project(p, viewProj)
            colTable[pi][yi] = readPixel(outTex, sx, sy)
        }
        // Save a colour shot per yaw for visual inspection.
        writeTexturePNG(outTex, to: String(format: "/tmp/syawprobe_%03.0f.png", yawDeg))
    }

    // ---- Report: shadow factor per fixed world point across yaws ----
    print("worldPoint            | shadowDbg @ yaw 0/45/90/135 | max-min  (shadow yaw-dependence)")
    var worstShadow: Float = 0
    for (pi, p) in probeLine.enumerated() {
        let row = dbgTable[pi]
        let spread = (row.max() ?? 0) - (row.min() ?? 0)
        worstShadow = max(worstShadow, spread)
        print(String(format: "(%.1f,%.1f)            |  %.4f %.4f %.4f %.4f       |  %.4f",
                     p.x, p.z, row[0], row[1], row[2], row[3], spread))
    }
    print("")
    print("worldPoint            | colour luma @ yaw 0/45/90/135 | max-min  (#47 specular yaw-dependence)")
    var worstColor: Float = 0
    for (pi, p) in probeLine.enumerated() {
        let lumas = colTable[pi].map { 0.299 * $0.x + 0.587 * $0.y + 0.114 * $0.z }
        let spread = (lumas.max() ?? 0) - (lumas.min() ?? 0)
        worstColor = max(worstColor, spread)
        print(String(format: "(%.1f,%.1f)            |  %.4f %.4f %.4f %.4f       |  %.4f",
                     p.x, p.z, lumas[0], lumas[1], lumas[2], lumas[3], spread))
    }
    print("")
    print(String(format: "VERDICT: worst shadow-factor yaw-spread = %.4f   worst colour-luma yaw-spread = %.4f",
                 worstShadow, worstColor))

    // ---- #47 specular: analytic yaw sensitivity at a GRAZING (eye-level) view ----
    // Mirror the exact fmain specular: V = normalize(cam - worldPos), Ld = normalize(-sun),
    // H = normalize(V+Ld), spec = pow(max(0,dot(pN,H)),18). On a flat top face pN≈(0,1,0).
    // At eye level the view vector swings a lot with yaw, so the highlight rides across the
    // ground as you turn, exactly what reads as "shadows shifting". Top-down hid this
    // because V barely changes when you are looking almost straight down.
    let litGround = SIMD3<Float>(20, 0, 30)            // a flat lit ground point ahead
    let pN = SIMD3<Float>(0, 1, 0)                      // top-face normal (specular uses ~this)
    let Ld = simd_normalize(SIMD3<Float>(-sun.x, -sun.y, -sun.z))
    print("")
    print("#47 specular at a fixed lit point, eye-level camera, vs yaw  (OLD = half-vector, NEW = sun-only):")
    var oldMin: Float = 1e9, oldMax: Float = -1e9, newMin: Float = 1e9, newMax: Float = -1e9
    let newSpec = pow(max(0, simd_dot(pN, Ld)), 18.0)   // sun-only: independent of yaw
    for yawDeg in stride(from: Float(0), through: 315, by: 45) {
        // eye-level camera position circling so it always faces the lit point (the player's
        // eye is what moves the V vector; position change is what a real "look around" does).
        let yaw = yawDeg * Float.pi / 180.0
        let eye = SIMD3<Float>(20 + 6 * sin(yaw), 2.0, 30 - 6 * cos(yaw))
        let V = simd_normalize(eye - litGround)
        let Hh = simd_normalize(V + Ld)
        let oldSpec = pow(max(0, simd_dot(pN, Hh)), 18.0)
        oldMin = min(oldMin, oldSpec); oldMax = max(oldMax, oldSpec)
        newMin = min(newMin, newSpec); newMax = max(newMax, newSpec)
        print(String(format: "  yaw %3.0f  OLD spec = %.4f   NEW spec = %.4f", yawDeg, oldSpec, newSpec))
    }
    print(String(format: "#47 yaw-spread:  OLD (half-vector) = %.4f   NEW (sun-only) = %.4f",
                 oldMax - oldMin, newMax - newMin))
    return true
}

// ============================================================================
// --shadowposprobe : the POSITION + SUN probe (the player's actual report).
//
// The reported wipe depends on PLAYER POSITION and SUN POSITION, not yaw, and it
// gets worse as the sun climbs and big occluders (mountains, tall trees) throw
// large shadows. This probe builds a synthetic scene with a TALL occluder (a
// mountain-height pillar reaching world y ~50) on a wide ground plane, renders the
// REAL shadow pipeline (shadowVmain / vmain / fmain / sampleShadowPCF), and then:
//
//   - sweeps the CAMERA POSITION through several world offsets (and a couple yaws),
//   - at a HIGH (midday) sun AND a LOW (morning) sun,
//   - samples the shadow factor at a set of FIXED world points each time,
//   - dumps the light-matrix params (ortho extents R/Ry, near/far, eye, and the
//     depth-along-L of the TALL caster's top + each probe point), the depth-map
//     hash, and the shadow factor per fixed point.
//
// A fixed world point's shadow factor MUST be constant as the camera position moves
// (the sun and geometry did not change). If it changes, that IS the wipe, and the
// dumped frustum params show why (depth slab clips the tall caster, box too small,
// or translation not snapped).
// ============================================================================
// strict == true turns this into a GREEN/RED regression gate (used by check.sh): it returns
// false if a fixed world point's shadow factor moves more than a small tolerance as the
// player walks (the #115 wipe). strict == false is the verbose investigation probe.
func runShadowPosProbe(strict: Bool = false) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else {
        // No Metal device (headless CI): cannot run; treat as non-fatal skip.
        log("no Metal device (shadow stability test skipped)"); return true
    }
    let queue = device.makeCommandQueue()!
    guard let lib = try? device.makeLibrary(source: Renderer.shaderSource, options: nil) else {
        log("shader compile failed"); return false
    }
    func pipe(_ v: String, _ frag: String?, color: MTLPixelFormat?, depth: Bool) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = frag.flatMap { lib.makeFunction(name: $0) }
        if let c = color { d.colorAttachments[0].pixelFormat = c }
        if depth { d.depthAttachmentPixelFormat = .depth32Float }
        return try? device.makeRenderPipelineState(descriptor: d)
    }
    guard let shadowPipe = pipe("shadowVmain", nil, color: nil, depth: true),
          let terrainPipe = pipe("vmain", "fmain", color: .bgra8Unorm, depth: true) else {
        log("pipeline build failed"); return false
    }
    let shDSD = MTLDepthStencilDescriptor(); shDSD.depthCompareFunction = .lessEqual; shDSD.isDepthWriteEnabled = true
    let shadowDepthState = device.makeDepthStencilState(descriptor: shDSD)
    let dsd = MTLDepthStencilDescriptor(); dsd.depthCompareFunction = .less; dsd.isDepthWriteEnabled = true
    let depthState = device.makeDepthStencilState(descriptor: dsd)
    let ssd = MTLSamplerDescriptor()
    ssd.minFilter = .linear; ssd.magFilter = .linear
    ssd.sAddressMode = .clampToEdge; ssd.tAddressMode = .clampToEdge
    ssd.compareFunction = .lessEqual
    let shadowSampler = device.makeSamplerState(descriptor: ssd)!

    // ---- Synthetic scene as PackedVertex triangles. The PackedVertex voxel coord is
    // 6 bits per axis (0..63), so we can reach world y ~50 for a tall caster. The ground
    // is a single wide chunk; the tall pillar is built from stacked 64-high columns.
    struct PV { var pos: UInt32; var normuv: UInt32; var material: UInt16; var sky: UInt8; var block: UInt8; var reserved: UInt32 }
    func pv(_ x: Int, _ y: Int, _ z: Int, _ norm: UInt32, _ mat: UInt16) -> PV {
        let pos = UInt32(x & 0x3f) | (UInt32(y & 0x3f) << 6) | (UInt32(z & 0x3f) << 12)
        return PV(pos: pos, normuv: norm | (3 << 3), material: mat, sky: 15, block: 0, reserved: 0)
    }
    var verts: [PV] = []; var idx: [UInt32] = []
    func quad(_ a: PV, _ b: PV, _ c: PV, _ d: PV) {
        let base = UInt32(verts.count)
        verts.append(a); verts.append(b); verts.append(c); verts.append(d)
        idx.append(base); idx.append(base+1); idx.append(base+2)
        idx.append(base); idx.append(base+2); idx.append(base+3)
    }
    // Ground: top faces (+Y, norm 2) at y=0 spanning x,z in [0,63] (one chunk's worth).
    let gMat: UInt16 = 3
    for gx in 0..<63 { for gz in 0..<63 {
        quad(pv(gx, 0, gz, 2, gMat), pv(gx, 0, gz+1, 2, gMat),
             pv(gx+1, 0, gz+1, 2, gMat), pv(gx+1, 0, gz, 2, gMat))
    } }
    // TALL occluder: a 3x3 column from y=1 to y=50 (mountain / tall-tree height). Four
    // side faces per layer cast a long shadow across the ground at a high sun.
    let px0 = 30, px1 = 33, pz0 = 30, pz1 = 33, pTop = 50, pMat: UInt16 = 3
    for y in 1..<pTop {
        quad(pv(px1, y, pz0, 0, pMat), pv(px1, y, pz1, 0, pMat), pv(px1, y+1, pz1, 0, pMat), pv(px1, y+1, pz0, 0, pMat))
        quad(pv(px0, y, pz1, 1, pMat), pv(px0, y, pz0, 1, pMat), pv(px0, y+1, pz0, 1, pMat), pv(px0, y+1, pz1, 1, pMat))
        quad(pv(px0, y, pz1, 4, pMat), pv(px1, y, pz1, 4, pMat), pv(px1, y+1, pz1, 4, pMat), pv(px0, y+1, pz1, 4, pMat))
        quad(pv(px1, y, pz0, 5, pMat), pv(px0, y, pz0, 5, pMat), pv(px0, y+1, pz0, 5, pMat), pv(px1, y+1, pz0, 5, pMat))
    }
    let vbuf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<PV>.stride, options: .storageModeShared)!
    let ibuf = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)!

    let W = 1200, H = 900
    let kShadowRes = 1536
    func tex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ shared: Bool) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: td)!
    }
    let shadowTexN = tex(.depth32Float, kShadowRes, kShadowRes, [.renderTarget, .shaderRead], true)
    let shadowTexF = tex(.depth32Float, kShadowRes, kShadowRes, [.renderTarget, .shaderRead], true)
    let outTex   = tex(.bgra8Unorm, W, H, [.renderTarget, .shaderRead], true)
    let outDepth = tex(.depth32Float, W, H, [.renderTarget], false)

    func readPixel(_ t: MTLTexture, _ x: Int, _ y: Int, half: Int = 4) -> SIMD3<Float> {
        var acc = SIMD3<Float>(0, 0, 0); var n: Float = 0
        for dy in -half...half { for dx in -half...half {
            let cx = min(max(0, x + dx), t.width - 1), cy = min(max(0, y + dy), t.height - 1)
            var px = [UInt8](repeating: 0, count: 4)
            t.getBytes(&px, bytesPerRow: t.width * 4, from: MTLRegionMake2D(cx, cy, 1, 1), mipmapLevel: 0)
            acc += SIMD3<Float>(Float(px[2]) / 255.0, Float(px[1]) / 255.0, Float(px[0]) / 255.0)
            n += 1
        } }
        return acc / n
    }
    func project(_ p: SIMD3<Float>, _ vp: simd_float4x4) -> (Int, Int) {
        let clip = vp * SIMD4<Float>(p.x, p.y, p.z, 1)
        let ndc = SIMD3<Float>(clip.x/clip.w, clip.y/clip.w, clip.z/clip.w)
        return (Int((ndc.x * 0.5 + 0.5) * Float(W)), Int((1.0 - (ndc.y * 0.5 + 0.5)) * Float(H)))
    }
    // Top-down-ish view at an arbitrary camera position + yaw so every fixed probe point
    // is on screen at every offset.
    func viewMatrix(_ camPos: SIMD3<Float>, yawDeg: Float) -> simd_float4x4 {
        let yaw = yawDeg * Float.pi / 180.0, pitch: Float = -1.35
        let cp = cos(pitch), sp = sin(pitch), cy = cos(yaw), sy = sin(yaw)
        let fwd = simd_normalize(SIMD3<Float>(sy * cp, sp, -cy * cp))
        let right = simd_normalize(simd_cross(fwd, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, fwd)
        let r = right, u = up, f = -fwd
        return simd_float4x4(columns: (
            SIMD4<Float>(r.x, u.x, f.x, 0), SIMD4<Float>(r.y, u.y, f.y, 0),
            SIMD4<Float>(r.z, u.z, f.z, 0),
            SIMD4<Float>(-simd_dot(r, camPos), -simd_dot(u, camPos), -simd_dot(f, camPos), 1)))
    }
    let proj = Renderer.perspective(fovy: 1.30, aspect: Float(W)/Float(H), near: 0.05, far: 600)

    // FIXED world points on the ground in the tall pillar's shadow direction. The sun
    // points toward +X/+Z, so the shadow lands toward +X/+Z of the pillar (x>33,z>33).
    // We march out far enough to span both cascades and the radial fade.
    func probePoints(_ sun: SIMD3<Float>) -> [SIMD3<Float>] {
        let dir = simd_normalize(SIMD3<Float>(sun.x, 0, sun.z))
        var pts: [SIMD3<Float>] = []
        for k in 0..<10 {
            let t = 4.0 + Float(k) * 6.0
            pts.append(SIMD3<Float>(33.5 + dir.x * t, 0.05, 33.5 + dir.z * t))
        }
        return pts
    }
    // Pillar top centre: the tall caster point whose depth-along-L we watch for clipping.
    let pillarTop = SIMD3<Float>(31.5, Float(pTop), 31.5)

    // Two suns: HIGH (near midday, steep) and LOW (early morning, shallow). Both point
    // toward +X/+Z so the shadow falls the same direction for both.
    let sunHigh = simd_normalize(SIMD3<Float>(0.30, -1.40, 0.25))
    let sunLow  = simd_normalize(SIMD3<Float>(0.85, -0.42, 0.55))

    // Camera position offsets: the player walking around the SAME scene. The fixed probe
    // points do not move; only the camera does.
    // Player walks around the SAME scene near the tall occluder. Eye ~ a couple blocks up
    // (a real player height), translating across the ground. The fixed probe points (the
    // pillar's cast shadow streak) do not move; only the player does.
    let baseCam = SIMD3<Float>(20, 8, 20)
    let offsets: [(SIMD3<Float>, Float)] = [
        (SIMD3<Float>(  0, 0,   0), 0),
        (SIMD3<Float>(  8, 0,   4), 0),
        (SIMD3<Float>( 16, 0,   8), 0),
        (SIMD3<Float>( 26, 1,  14), 0),
        (SIMD3<Float>( 36, 2,  20), 0),
        (SIMD3<Float>( 16, 0,   8), 60),   // a view-yaw too, to confirm yaw still does not matter
    ]

    // The VIEW eye is FIXED (a high overhead camera that always frames the whole scene), so
    // a fixed world point projects to the same on-screen ground texel at every offset and is
    // never lost off-screen. Only `playerPos` (what the in-game light matrix + shadow
    // distance code key off of) varies. That isolates the ONE variable the player reported:
    // moving through the world. If a fixed point's shadow changes, it is purely because the
    // light matrix / cascade selection changed with player position.
    let viewEye = SIMD3<Float>(48, 95, 48)
    // PROBE_ONE_CASCADE=1 makes the near radius equal the far radius so both cascades are the
    // SAME map -> isolates whether the wipe is cascade DISAGREEMENT (gone if this stabilizes).
    let oneCascade = ProcessInfo.processInfo.environment["PROBE_ONE_CASCADE"] == "1"
    // PROBE_BIAS overrides the shadow-caster depth-bias slopeScale (default 2.0).
    let biasSlope = Float(ProcessInfo.processInfo.environment["PROBE_BIAS"] ?? "") ?? 2.0
    let probeFarR = Float(ProcessInfo.processInfo.environment["PROBE_FARR"] ?? "") ?? 150
    // Light matrices last used by renderAt, so the analytic sampler can use the exact ones.
    var lastLvpN = matrix_identity_float4x4
    var lastLvpF = matrix_identity_float4x4
    func renderAt(_ playerPos: SIMD3<Float>, viewYawDeg: Float, sun: SIMD3<Float>, debug: Bool) {
        let probeNearR = Float(ProcessInfo.processInfo.environment["PROBE_NEARR"] ?? "") ?? 48
        let kNearR: Float = oneCascade ? probeFarR : probeNearR, kFarR: Float = probeFarR
        let lvpN = Renderer.buildLightMatrix(sunDir: sun, camPos: playerPos, radius: kNearR, res: Float(kShadowRes))
        let lvpF = Renderer.buildLightMatrix(sunDir: sun, camPos: playerPos, radius: kFarR,  res: Float(kShadowRes))
        lastLvpN = lvpN; lastLvpF = lvpF
        let viewProj = proj * viewMatrix(viewEye, yawDeg: viewYawDeg)
        let cmd = queue.makeCommandBuffer()!
        func shadowPass(_ map: MTLTexture, _ m: simd_float4x4) {
            let srp = MTLRenderPassDescriptor()
            srp.depthAttachment.texture = map; srp.depthAttachment.loadAction = .clear
            srp.depthAttachment.storeAction = .store; srp.depthAttachment.clearDepth = 1.0
            if let enc = cmd.makeRenderCommandEncoder(descriptor: srp) {
                enc.setRenderPipelineState(shadowPipe); enc.setDepthStencilState(shadowDepthState)
                enc.setCullMode(.front); enc.setDepthBias(2.0, slopeScale: biasSlope, clamp: 0.0)
                var su = ShadowVertUniforms(lightViewProj: m, chunkOrigin: SIMD4<Float>(0, 0, 0, 0))
                var wind = WindUniforms(wallClockSecs: 0, rainStrength: 0)
                enc.setVertexBuffer(vbuf, offset: 0, index: 0)
                enc.setVertexBytes(&su, length: MemoryLayout<ShadowVertUniforms>.stride, index: 1)
                enc.setVertexBytes(&wind, length: MemoryLayout<WindUniforms>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: idx.count, indexType: .uint32, indexBuffer: ibuf, indexBufferOffset: 0)
                enc.endEncoding()
            }
        }
        shadowPass(shadowTexN, lvpN); shadowPass(shadowTexF, lvpF)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = outTex
        rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.45, green: 0.62, blue: 0.86, alpha: 1)
        rp.depthAttachment.texture = outDepth
        rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 1.0; rp.depthAttachment.storeAction = .dontCare
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
            enc.setRenderPipelineState(terrainPipe); enc.setDepthStencilState(depthState)
            enc.setCullMode(.back); enc.setFrontFacing(.counterClockwise)
            var u = Uniforms(viewProj: viewProj, chunkOrigin: SIMD4<Float>(0, 0, 0, 1),
                             sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, 0.25),
                             lightViewProj: lvpN, dimSatN: SIMD4<Float>(1, 1, 1, 0),
                             lightViewProjF: lvpF)
            // cameraPosW = the PLAYER position (drives distFade + cascade nearBlend in fmain),
            // NOT the fixed view eye.
            var wu = WaterUniforms(wallClockSecs: 0, underwater: 0, shadowScale: debug ? 2.0 : 1.0,
                                   cameraPosW: SIMD4<Float>(playerPos.x, playerPos.y, playerPos.z, 0),
                                   sunDirTime: SIMD4<Float>(sun.x, sun.y, sun.z, 0.25))
            var wind = WindUniforms(wallClockSecs: 0, rainStrength: 0)
            enc.setVertexBuffer(vbuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&wu, length: MemoryLayout<WaterUniforms>.stride, index: 2)
            enc.setVertexBytes(&wind, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setFragmentBytes(&wind, length: MemoryLayout<WindUniforms>.stride, index: 3)
            enc.setFragmentTexture(shadowTexN, index: 0)
            enc.setFragmentTexture(shadowTexF, index: 1)
            enc.setFragmentSamplerState(shadowSampler, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: idx.count, indexType: .uint32, indexBuffer: ibuf, indexBufferOffset: 0)
            enc.endEncoding()
        }
        cmd.commit(); cmd.waitUntilCompleted()
    }
    func mapHash(_ t: MTLTexture) -> UInt64 {
        let n = kShadowRes * kShadowRes
        var buf = [Float](repeating: 0, count: n)
        t.getBytes(&buf, bytesPerRow: kShadowRes * 4, from: MTLRegionMake2D(0, 0, kShadowRes, kShadowRes), mipmapLevel: 0)
        var h: UInt64 = 1469598103934665603
        for v in buf { h = (h ^ UInt64(v.bitPattern)) &* 1099511628211 }
        return h
    }

    // Read the rendered shadow depth map back ONCE into a CPU buffer so a world point can be
    // PCF-sampled analytically (exactly like sampleShadowPCF in fmain), with NO dependence on
    // the screen view / projection. This is the clean measurement: a fixed world point's
    // shadow factor as a pure function of (depth map, lightVP, playerPos) only.
    func readDepthMap(_ t: MTLTexture) -> [Float] {
        var buf = [Float](repeating: 0, count: kShadowRes * kShadowRes)
        t.getBytes(&buf, bytesPerRow: kShadowRes * 4, from: MTLRegionMake2D(0, 0, kShadowRes, kShadowRes), mipmapLevel: 0)
        return buf
    }
    // Mirror of fmain's sampleShadowPCF (5x5 PCF, edge fade, same bias). depthBuf is the
    // CPU copy of the rendered map; lvp is the matrix used to render it.
    func analyticPCF(_ depthBuf: [Float], _ lvp: simd_float4x4, _ p: SIMD3<Float>, bias: Float) -> Float {
        let clip = lvp * SIMD4<Float>(p.x, p.y, p.z, 1)
        let ndc = SIMD3<Float>(clip.x/clip.w, clip.y/clip.w, clip.z/clip.w)
        var uv = SIMD2<Float>(ndc.x * 0.5 + 0.5, ndc.y * 0.5 + 0.5)
        uv.y = 1.0 - uv.y
        let depth = ndc.z - bias
        if uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1 { return 1.0 }
        if depth >= 1.0 { return 1.0 }
        let eDist = SIMD2<Float>(min(uv.x, 1 - uv.x), min(uv.y, 1 - uv.y))
        let e = min(eDist.x, eDist.y)
        let edgeFade: Float = e <= 0 ? 0 : (e >= 0.14 ? 1 : (e/0.14) * (e/0.14) * (3 - 2 * (e/0.14)))
        let texelSize: Float = 1.0 / 1536.0
        var shadow: Float = 0
        for dy in -2...2 { for dx in -2...2 {
            let su = uv.x + Float(dx) * texelSize, sv = uv.y + Float(dy) * texelSize
            let tx = min(max(0, Int(su * Float(kShadowRes))), kShadowRes - 1)
            let ty = min(max(0, Int(sv * Float(kShadowRes))), kShadowRes - 1)
            let stored = depthBuf[ty * kShadowRes + tx]
            shadow += (depth <= stored) ? 1.0 : 0.0   // lessEqual compare (1=lit)
        } }
        shadow /= 25.0
        return 1.0 * (1 - edgeFade) + shadow * edgeFade
    }

    // The shadow factor for a fixed world point, sampled analytically against the maps
    // rendered by the most recent renderAt(), with the SAME cascade blend + radial distFade
    // fmain uses. View-independent (no screen readback), so it measures only the real signal.
    func shadowFactorAt(_ depthN: [Float], _ depthF: [Float], _ p: SIMD3<Float>, playerPos: SIMD3<Float>) -> Float {
        let distToCam = simd_length(p - playerPos)
        let t = max(0, min(1, (distToCam - 30) / 12))
        let nearBlend = 1.0 - (t * t * (3 - 2 * t))          // smoothstep(30,42)
        // PROBE_OLDBLEND=1 reproduces the pre-#115 linear cascade blend (the bug) for the
        // before/after comparison; default mirrors the shipped #115 UNION (min) of cascades.
        let oldBlend = ProcessInfo.processInfo.environment["PROBE_OLDBLEND"] == "1"
        _ = nearBlend
        let rn = analyticPCF(depthN, lastLvpN, p, bias: 0.0028)
        let rf = analyticPCF(depthF, lastLvpF, p, bias: 0.0050)
        var raw: Float
        if oldBlend {
            if nearBlend >= 0.999 { raw = rn }
            else if nearBlend <= 0.001 { raw = rf }
            else { raw = rf * (1 - nearBlend) + rn * nearBlend }
        } else {
            raw = min(rn, rf)   // #115 union
        }
        let td = max(0, min(1, (distToCam - 135) / 14))
        let distFade = 1.0 - (td * td * (3 - 2 * td))        // smoothstep(135,149)
        return 1.0 * (1 - distFade) + raw * distFade
    }

    // In the strict gate, suppress the verbose investigation tables (keep check.sh clean).
    func log(_ s: String) { if !strict { print(s) } }

    // First, a SWEEP of sun elevations so we can see where the position-spread peaks across
    // the day (the player reports it worsens as the sun climbs). Pure measurement.
    log("=== sun-elevation sweep: worst fixed-point position-spread vs sun elevation ===")
    log("elevDeg | farRy | worst position-spread (0=stable)")
    var sweepWorst: Float = 0
    for elevDeg in stride(from: Float(15), through: 80, by: 5) {
        let e = elevDeg * Float.pi / 180.0
        // azimuth toward +X/+Z so the streak direction is consistent
        let sun = simd_normalize(SIMD3<Float>(cos(e) * 0.7, -sin(e), cos(e) * 0.5))
        let pts = probePoints(sun)
        let (_, dbg) = Renderer.buildLightMatrixD(sunDir: sun, camPos: baseCam, radius: 150, res: Float(kShadowRes))
        var worst: Float = 0
        var rows = [[Float]](repeating: [Float](repeating: 0, count: offsets.count), count: pts.count)
        for (oi, off) in offsets.enumerated() {
            let playerPos = baseCam + off.0
            renderAt(playerPos, viewYawDeg: off.1, sun: sun, debug: true)
            let dN = readDepthMap(shadowTexN), dF = readDepthMap(shadowTexF)
            for (pi, p) in pts.enumerated() {
                rows[pi][oi] = shadowFactorAt(dN, dF, p, playerPos: playerPos)
            }
        }
        for r in rows { worst = max(worst, (r.max() ?? 0) - (r.min() ?? 0)) }
        sweepWorst = max(sweepWorst, worst)
        log(String(format: "  %5.0f | %5.1f | %.4f", elevDeg, dbg.Ry, worst))
    }
    log(String(format: "sweep worst position-spread across all sun elevations = %.4f", sweepWorst))

    var worstSpreadHigh: Float = 0
    var worstSpreadLow: Float = 0
    for (sunName, sun) in [("HIGH", sunHigh), ("LOW", sunLow)] {
        let pts = probePoints(sun)
        log("")
        log("================ SUN \(sunName)  dir=\(String(format: "%.2f %.2f %.2f", sun.x, sun.y, sun.z)) ================")
        // Per offset: dump the FAR-cascade frustum params + tall-caster depth slab check.
        log("offset(dx,dz,yaw) | nearR/farR Ry(far) | far-cascade eye | depthL(pillarTop) vs [near,far] | mapHashN")
        var table = [[Float]](repeating: [Float](repeating: 0, count: offsets.count), count: pts.count)
        // shaderTable holds the ACTUAL rendered shader shadow value (fixed view) for the gate.
        var shaderTable = [[Float]](repeating: [Float](repeating: 0, count: offsets.count), count: pts.count)
        // Does a world point fall inside the FAR cascade's ortho XY box? (|ndc.x|,|ndc.y|<=1)
        func inBox(_ vp: simd_float4x4, _ p: SIMD3<Float>) -> Bool {
            let c = vp * SIMD4<Float>(p.x, p.y, p.z, 1)
            return abs(c.x/c.w) <= 1.0 && abs(c.y/c.w) <= 1.0
        }
        for (oi, off) in offsets.enumerated() {
            let playerPos = baseCam + off.0
            let (vpF, dbgF) = Renderer.buildLightMatrixD(sunDir: sun, camPos: playerPos, radius: 150, res: Float(kShadowRes))
            let dL = dbgF.depthAlongL(pillarTop)
            let inSlab = (dL >= dbgF.near && dL <= dbgF.far) ? "IN " : "OUT"
            // Is the tall caster's top INSIDE the far cascade's ortho XY box at this offset?
            let pillarInBox = inBox(vpF, pillarTop) ? "pillarBOX:IN " : "pillarBOX:OUT"
            let p0 = pts[0], p4 = pts[min(4, pts.count-1)]
            let p0b = inBox(vpF, p0) ? "p0:IN " : "p0:OUT"
            let p4b = inBox(vpF, p4) ? "p4:IN " : "p4:OUT"
            // Is the pillar (the CASTER) inside the NEAR cascade's box? If not, the near map
            // holds no pillar -> contact shadows vanish for points using the near cascade.
            let vpN = Renderer.buildLightMatrix(sunDir: sun, camPos: playerPos, radius: 48, res: Float(kShadowRes))
            let pillarTopNear = inBox(vpN, pillarTop) ? "pillarNEARtop:IN " : "pillarNEARtop:OUT"
            let pillarBaseNear = inBox(vpN, SIMD3<Float>(31.5, 1, 31.5)) ? "base:IN " : "base:OUT"
            renderAt(playerPos, viewYawDeg: off.1, sun: sun, debug: true)
            let hN = mapHash(shadowTexN)
            log(String(format: "player(%5.0f,%5.0f,%3.0f) | %@ %@ | %@ %@ %@ | %016llx",
                         off.0.x, off.0.z, off.1,
                         pillarTopNear, pillarBaseNear,
                         pillarInBox, p0b, p4b, hN))
            // VIEW-INDEPENDENT analytic shadow sample of the fixed world points (mirrors
            // fmain, fast, view-free).
            let dN = readDepthMap(shadowTexN), dF = readDepthMap(shadowTexF)
            for (pi, p) in pts.enumerated() {
                table[pi][oi] = shadowFactorAt(dN, dF, p, playerPos: playerPos)
            }
            // ALSO read the ACTUAL shader output (debug grayscale = raw shadow) at the fixed
            // view, so the strict gate tests the REAL shipped fmain blend (not just the Swift
            // replica). The view is identical for all NON-yaw offsets, so a fixed world point
            // maps to the same screen pixel -> any change is purely the shader's shadow value.
            if off.1 == 0 {
                let viewProj = proj * viewMatrix(viewEye, yawDeg: 0)
                for (pi, p) in pts.enumerated() {
                    let (sx, sy) = project(p, viewProj)
                    shaderTable[pi][oi] = readPixel(outTex, sx, sy).x
                }
            } else {
                for pi in 0..<pts.count { shaderTable[pi][oi] = shaderTable[pi][0] } // skip yaw col
            }
            if !strict { writeTexturePNG(outTex, to: String(format: "/tmp/sposprobe_%@_%d.png", sunName, oi)) }
        }
        log("")
        log("fixed worldPoint (x,z) | shadowDbg across camera offsets | max-min (POSITION-dependence)")
        var worst: Float = 0
        for (pi, p) in pts.enumerated() {
            let row = table[pi]
            let spread = (row.max() ?? 0) - (row.min() ?? 0)
            worst = max(worst, spread)
            var s = String(format: "(%5.1f,%5.1f) |", p.x, p.z)
            for v in row { s += String(format: " %.3f", v) }
            s += String(format: " | %.4f", spread)
            log(s)
        }
        // Also fold in the spread of the ACTUAL rendered shader value (position offsets only,
        // fixed view) so the gate validates the shipped fmain blend, not just the replica.
        var shaderWorst: Float = 0
        for pi in 0..<pts.count {
            let row = Array(shaderTable[pi].prefix(5))   // first 5 are the position offsets
            shaderWorst = max(shaderWorst, (row.max() ?? 0) - (row.min() ?? 0))
        }
        log(String(format: "  (rendered-shader spread, fixed view, position offsets) = %.4f", shaderWorst))
        worst = max(worst, shaderWorst)
        // distToCam per point per offset: which fade band (cascade 30..42, radial 135..149)
        // does each flip cross? This correlates the shadow change with a camera-relative fade.
        log("fixed worldPoint (x,z) | distToCam across offsets (cascade 30..42, radial 135..149)")
        for p in pts {
            var s = String(format: "(%5.1f,%5.1f) |", p.x, p.z)
            for off in offsets {
                let cam = baseCam + off.0
                let d = simd_length(cam - SIMD3<Float>(p.x, 0.05, p.z))
                s += String(format: " %5.0f", d)
            }
            log(s)
        }
        log(String(format: "VERDICT SUN %@: worst fixed-point shadow spread across camera POSITION = %.4f", sunName, worst))
        if sunName == "HIGH" { worstSpreadHigh = worst } else { worstSpreadLow = worst }
    }
    log("")
    print(String(format: "SUMMARY: worst position-spread HIGH sun = %.4f   LOW sun = %.4f   (0 = stable, the goal)",
                 worstSpreadHigh, worstSpreadLow))
    if strict {
        // The fix drives both to 0.0000; allow a small tolerance for PCF/quantization noise.
        // The pre-fix bug was ~0.40, so this catches any reintroduction with wide margin.
        let tol: Float = 0.08
        let worst = max(sweepWorst, max(worstSpreadHigh, worstSpreadLow))
        if worst > tol {
            print(String(format: "SHADOW-STABILITY regression: worst position-spread %.4f > tol %.2f (the #115 wipe)", worst, tol))
            return false
        }
        print(String(format: "shadow-stability OK: worst position-spread %.4f <= %.2f", worst, tol))
    }
    return true
}
