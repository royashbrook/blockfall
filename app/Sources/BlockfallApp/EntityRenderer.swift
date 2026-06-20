// ============================================================================
// Blockfall — EntityRenderer (Track G/E, M3)
// Draws creatures (ABI v2 bf_entity_draw) as friendly blocky models — a body
// cube + a head cube — tinted per type and desaturated by region Dim state.
// Shared by the live Renderer and the offscreen render self-test.
// ============================================================================
import MetalKit
import simd
import CBlockcore

struct EUniforms {
    var mvp: simd_float4x4
    var color: SIMD4<Float>   // rgb + sat (w)
}

final class EntityRenderer {
    private let pipeline: MTLRenderPipelineState
    private let cubeVB: MTLBuffer
    private let cubeIB: MTLBuffer
    private let indexCount: Int

    init(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let lib = try? device.makeLibrary(source: EntityRenderer.shaderSource, options: nil) else {
            fatalError("entity shader compile failed")
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "evmain")
        pd.fragmentFunction = lib.makeFunction(name: "efmain")
        pd.colorAttachments[0].pixelFormat = colorFormat
        pd.depthAttachmentPixelFormat = .depth32Float
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        // Unit cube centered at origin, 24 verts (pos.xyz + normal.xyz), 36 indices.
        var verts: [Float] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0,0,1), SIMD3(1,0,0), SIMD3(0,1,0)),   // +Z
            (SIMD3(0,0,-1), SIMD3(-1,0,0), SIMD3(0,1,0)), // -Z
            (SIMD3(1,0,0), SIMD3(0,0,-1), SIMD3(0,1,0)),  // +X
            (SIMD3(-1,0,0), SIMD3(0,0,1), SIMD3(0,1,0)),  // -X
            (SIMD3(0,1,0), SIMD3(1,0,0), SIMD3(0,0,-1)),  // +Y
            (SIMD3(0,-1,0), SIMD3(1,0,0), SIMD3(0,0,1)),  // -Y
        ]
        var indices: [UInt16] = []
        var base: UInt16 = 0
        for (n, u, v) in faces {
            let c = n * 0.5
            let corners = [c - u*0.5 - v*0.5, c + u*0.5 - v*0.5, c + u*0.5 + v*0.5, c - u*0.5 + v*0.5]
            for p in corners { verts += [p.x, p.y, p.z, n.x, n.y, n.z] }
            indices += [base, base+1, base+2, base, base+2, base+3]
            base += 4
        }
        cubeVB = device.makeBuffer(bytes: verts, length: verts.count*4, options: .storageModeShared)!
        cubeIB = device.makeBuffer(bytes: indices, length: indices.count*2, options: .storageModeShared)!
        indexCount = indices.count
    }

    func encode(_ enc: MTLRenderCommandEncoder, viewProj: simd_float4x4,
                entities: UnsafePointer<bf_entity_draw>?, count: Int) {
        guard let entities = entities, count > 0 else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(cubeVB, offset: 0, index: 0)
        for i in 0..<count {
            let e = entities[i]
            let s = e.scale
            let pos = SIMD3<Float>(e.position.x, e.position.y, e.position.z)
            let rot = EntityRenderer.rotY(e.yaw)
            // Body sits on the ground; head is up and forward.
            let body = EntityRenderer.trans(pos + SIMD3(0, s*0.5, 0)) * rot * EntityRenderer.scaleM(SIMD3(s*0.9, s*0.9, s*1.15))
            let head = EntityRenderer.trans(pos + SIMD3(0, s*1.0, 0)) * rot * EntityRenderer.trans(SIMD3(0, 0, s*0.6)) * EntityRenderer.scaleM(SIMD3(s*0.6, s*0.6, s*0.6))
            for model in [body, head] {
                var u = EUniforms(mvp: viewProj * model,
                                  color: SIMD4<Float>(e.color.x, e.color.y, e.color.z, e.sat))
                enc.setVertexBytes(&u, length: MemoryLayout<EUniforms>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                          indexType: .uint16, indexBuffer: cubeIB, indexBufferOffset: 0)
            }
        }
    }

    // ---- tiny matrix helpers ----
    static func trans(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4; m.columns.3 = SIMD4(t.x, t.y, t.z, 1); return m
    }
    static func scaleM(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = s.x; m.columns.1.y = s.y; m.columns.2.z = s.z; return m
    }
    static func rotY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(c, 0, -s, 0)
        m.columns.2 = SIMD4(s, 0, c, 0)
        return m
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct CVert { packed_float3 pos; packed_float3 normal; };
    struct EUniforms { float4x4 mvp; float4 color; };
    struct EOut { float4 position [[position]]; float3 color; float shade; float sat; };
    vertex EOut evmain(uint vid [[vertex_id]],
                       device const CVert* v [[buffer(0)]],
                       constant EUniforms& u [[buffer(1)]]) {
        CVert cv = v[vid];
        float3 n = float3(cv.normal);
        float shade = clamp(0.55 + 0.30 * n.y + 0.15 * n.x, 0.0, 1.0);
        EOut o;
        o.position = u.mvp * float4(float3(cv.pos), 1.0);
        o.color = u.color.rgb;
        o.shade = shade;
        o.sat = u.color.w;
        return o;
    }
    fragment float4 efmain(EOut in [[stage_in]]) {
        float3 c = in.color * in.shade;
        float l = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(l), c, clamp(in.sat, 0.0, 1.0));
        return float4(c, 1.0);
    }
    """
}
