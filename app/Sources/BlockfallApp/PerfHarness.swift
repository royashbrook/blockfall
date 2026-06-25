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

    func renderOneFrame(pitch: Float = 0, yaw: Float = 0.004) {
        frameIdx += 1; registry.currentFrame = frameIdx
        let now = CACurrentMediaTime(); let dt = now - lastDt; lastDt = now
        // Keep the player slowly orbiting so chunks stream continuously (worst case).
        var input = bf_frame_input(); input.move_forward = 1; input.look_yaw_delta = yaw
        input.look_pitch_delta = pitch   // #52 shot mode tilts down to frame ground props
        _ = bf_frame_begin(e, &input, dt)
        var f = bf_render_frame(); _ = bf_frame_acquire_render(e, &f)

        let aspect = Float(W)/Float(H), fovy: Float = 1.20
        let proj = Renderer.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 512)
        let viewM = Renderer.mat(f.camera.view)
        let viewProj = proj * viewM
        var sun = f.camera.sun_dir
        // #72 debug: force a low-ish angled sun so occluders cast clear ground shadows
        // (the test world's high midday sun casts almost none, so the wipe is invisible).
        if ProcessInfo.processInfo.environment["BF_SHADOW_DEBUG"] == "1" {
            sun = bf_vec3(x: 0.55, y: -0.62, z: 0.56)   // points down-and-sideways (sun in the NW)
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
        let lightViewProj = Renderer.buildLightMatrix(
            sunDir: SIMD3<Float>(sun.x, sun.y, sun.z),
            camPos: SIMD3<Float>(camPosW.x, camPosW.y, camPosW.z), radius: 90, res: 1536)

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
                for i in 0..<Int(f.draw_count) {
                    let d = f.draws[i]
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
                        let dayBright = 0.30 + 0.70 * max(0, sin(f.camera.time_of_day * Float.pi))
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
                    skyTod = 0.0                        // midnight
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
            var wu = WaterUniforms(wallClockSecs: wallClock, underwater: 0, cameraPosW: camPosW)
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
                    let dayBright = 0.30 + 0.70 * max(0, sin(f.camera.time_of_day * Float.pi))
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
                let dayB = 0.30 + 0.70 * max(0, sin(f.camera.time_of_day * Float.pi))
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
                var pu = PostUniforms(bloomStrength: 0.12, vignetteStr: 0.22, satBoost: 1.30,
                                      rainStrength: 0, wallClockSecs: 0)
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
        if skyMode {
            for _ in 0..<30 { renderOneFrame(pitch: 0.02, yaw: 0) }  // tilt UP into clear sky for the moon
        } else if treeMode {
            for _ in 0..<12 { renderOneFrame(pitch: 0.012, yaw: 0) } // look level/up to frame trees ahead
        } else {
            for _ in 0..<10 { renderOneFrame(pitch: -0.006, yaw: 0) } // look slightly down at the ground ahead
        }
        // #72 diagnosis: turn the camera by BF_SHOT_YAW degrees before capture, so the
        // same spot can be shot at several yaws to reveal the view-dependent shadow wipe.
        if let yawStr = ProcessInfo.processInfo.environment["BF_SHOT_YAW"], let yawDeg = Float(yawStr) {
            let total = yawDeg * Float.pi / 180.0
            let frames = 60
            for _ in 0..<frames { renderOneFrame(yaw: total / Float(frames)) }
        }
        for _ in 0..<24  { renderOneFrame(yaw: 0) }          // settle (stream + dirty converge)
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
    let kinds: [UInt32] = [0,1,2,3,4,5,7,8,9,10,11,12,13,14,15,16,17,18,19,20,100]
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
