import MetalKit
import simd
import CBlockcore

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
        registry.markFrameCompleted(f)
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
        // #183/#197: camera of a world-to-view [R | t] is -(R transpose * t), a dot
        // with each rotation COLUMN. The old row form was yaw-dependent, so the
        // spawn-facing change (#197) moved this (wrongly extracted) camEye onto
        // different terrain and tripped the washout guard. This makes camEye the
        // true player position, independent of facing.
        let vm = Renderer.mat(fr.camera.view); let vt = vm.columns.3
        camEye = SIMD3<Float>(
            -(vm.columns.0.x*vt.x + vm.columns.0.y*vt.y + vm.columns.0.z*vt.z),
            -(vm.columns.1.x*vt.x + vm.columns.1.y*vt.y + vm.columns.1.z*vt.z),
            -(vm.columns.2.x*vt.x + vm.columns.2.y*vt.y + vm.columns.2.z*vt.z))
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
            registry.markFrameCompleted(64 + yi)
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
