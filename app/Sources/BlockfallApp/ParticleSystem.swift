// ============================================================================
// Blockfall — break particles (juice). Small debris cubes that pop out of a
// broken block, fall under gravity, and fade. Self-contained (own pipeline +
// unit cube). Owned by the Renderer; updated + encoded each frame.
// ============================================================================
import MetalKit
import simd
import CBlockcore

final class ParticleSystem {
    private struct P { var pos: SIMD3<Float>; var vel: SIMD3<Float>; var life: Float; var color: SIMD3<Float> }
    private var parts: [P] = []
    private var rng: UInt64 = 0x9E3779B97F4A7C15

    private let pipeline: MTLRenderPipelineState
    private let cubeVB: MTLBuffer
    private let cubeIB: MTLBuffer
    private let indexCount: Int

    private func rnd() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float(rng >> 40) / Float(1 << 24) }

    init(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let lib = try? device.makeLibrary(source: ParticleSystem.shaderSource, options: nil) else {
            fatalError("particle shader failed")
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pvmain")
        pd.fragmentFunction = lib.makeFunction(name: "pfmain")
        pd.colorAttachments[0].pixelFormat = colorFormat
        pd.depthAttachmentPixelFormat = .depth32Float
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)
        // unit cube: 24 pos-only verts, 36 indices
        var verts: [Float] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0,0,1), SIMD3(1,0,0), SIMD3(0,1,0)), (SIMD3(0,0,-1), SIMD3(-1,0,0), SIMD3(0,1,0)),
            (SIMD3(1,0,0), SIMD3(0,0,-1), SIMD3(0,1,0)), (SIMD3(-1,0,0), SIMD3(0,0,1), SIMD3(0,1,0)),
            (SIMD3(0,1,0), SIMD3(1,0,0), SIMD3(0,0,-1)), (SIMD3(0,-1,0), SIMD3(1,0,0), SIMD3(0,0,1)),
        ]
        var idx: [UInt16] = []; var base: UInt16 = 0
        for (n, u, v) in faces {
            let c = n * 0.5
            for p in [c-u*0.5-v*0.5, c+u*0.5-v*0.5, c+u*0.5+v*0.5, c-u*0.5+v*0.5] { verts += [p.x, p.y, p.z] }
            idx += [base, base+1, base+2, base, base+2, base+3]; base += 4
        }
        cubeVB = device.makeBuffer(bytes: verts, length: verts.count*4, options: .storageModeShared)!
        cubeIB = device.makeBuffer(bytes: idx, length: idx.count*2, options: .storageModeShared)!
        indexCount = idx.count
    }

    func spawn(at v: bf_ivec3) {
        let base = SIMD3<Float>(Float(v.x) + 0.5, Float(v.y) + 0.5, Float(v.z) + 0.5)
        let tint = SIMD3<Float>(0.55 + 0.15*rnd(), 0.42 + 0.12*rnd(), 0.30 + 0.10*rnd())  // earthy debris
        for _ in 0..<10 {
            let vel = SIMD3<Float>((rnd()-0.5)*4, 2 + rnd()*3, (rnd()-0.5)*4)
            parts.append(P(pos: base + SIMD3((rnd()-0.5)*0.6, (rnd()-0.5)*0.6, (rnd()-0.5)*0.6),
                           vel: vel, life: 0.5 + rnd()*0.3, color: tint))
        }
        if parts.count > 400 { parts.removeFirst(parts.count - 400) }
    }

    func update(_ dt: Float) {
        let g: Float = 18
        for i in parts.indices { parts[i].vel.y -= g*dt; parts[i].pos += parts[i].vel*dt; parts[i].life -= dt }
        parts.removeAll { $0.life <= 0 }
    }

    func encode(_ enc: MTLRenderCommandEncoder, viewProj: simd_float4x4) {
        guard !parts.isEmpty else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(cubeVB, offset: 0, index: 0)
        for p in parts {
            let s: Float = 0.12 * min(1, p.life * 3)
            var m = matrix_identity_float4x4
            m.columns.0.x = s; m.columns.1.y = s; m.columns.2.z = s
            m.columns.3 = SIMD4(p.pos.x, p.pos.y, p.pos.z, 1)
            var u = ParticleUniforms(mvp: viewProj * m, color: SIMD4(p.color.x, p.color.y, p.color.z, 1))
            enc.setVertexBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16,
                                      indexBuffer: cubeIB, indexBufferOffset: 0)
        }
    }

    struct ParticleUniforms { var mvp: simd_float4x4; var color: SIMD4<Float> }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4x4 mvp; float4 color; };
    struct VO { float4 position [[position]]; float3 color; };
    vertex VO pvmain(uint vid [[vertex_id]], device const float3* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
        VO o; o.position = u.mvp * float4(v[vid], 1.0); o.color = u.color.rgb; return o;
    }
    fragment float4 pfmain(VO in [[stage_in]]) { return float4(in.color, 1.0); }
    """
}
