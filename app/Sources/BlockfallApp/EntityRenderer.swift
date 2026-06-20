// ============================================================================
// Blockfall — EntityRenderer (M5, charming blocky creatures)
// Draws creatures as multi-part blocky animals (Minecraft-style) with:
//   body, head (+ two dark eyes), 4 legs, 2 ears, tail
//   bosses get extra crown/horn cubes and bulkier proportions
//   walk-cycle animation: leg swing + body/head bob driven by CACurrentMediaTime()
//   Dim desaturation and directional face shading preserved
//
// Public API is unchanged:
//   init(device:colorFormat:)
//   encode(_ enc:viewProj:entities:count:)
// ============================================================================
import MetalKit
import simd
import QuartzCore   // CACurrentMediaTime()
import CBlockcore

// Passed to the vertex shader once per cube draw.
struct EUniforms {
    var mvp:   simd_float4x4
    var color: SIMD4<Float>   // rgb + sat (w)
}

final class EntityRenderer {
    private let pipeline:   MTLRenderPipelineState
    private let cubeVB:     MTLBuffer
    private let cubeIB:     MTLBuffer
    private let indexCount: Int

    // -----------------------------------------------------------------------
    init(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let lib = try? device.makeLibrary(source: EntityRenderer.shaderSource, options: nil) else {
            fatalError("entity shader compile failed")
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction   = lib.makeFunction(name: "evmain")
        pd.fragmentFunction = lib.makeFunction(name: "efmain")
        pd.colorAttachments[0].pixelFormat = colorFormat
        pd.depthAttachmentPixelFormat      = .depth32Float
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        // Unit cube centered at origin: 24 verts (pos.xyz + normal.xyz), 36 indices.
        var verts: [Float] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3( 0, 0, 1), SIMD3( 1, 0, 0), SIMD3(0, 1,  0)),  // +Z front
            (SIMD3( 0, 0,-1), SIMD3(-1, 0, 0), SIMD3(0, 1,  0)),  // -Z back
            (SIMD3( 1, 0, 0), SIMD3( 0, 0,-1), SIMD3(0, 1,  0)),  // +X right
            (SIMD3(-1, 0, 0), SIMD3( 0, 0, 1), SIMD3(0, 1,  0)),  // -X left
            (SIMD3( 0, 1, 0), SIMD3( 1, 0, 0), SIMD3(0, 0, -1)),  // +Y top
            (SIMD3( 0,-1, 0), SIMD3( 1, 0, 0), SIMD3(0, 0,  1)),  // -Y bottom
        ]
        var indices: [UInt16] = []
        var base: UInt16 = 0
        for (n, u, v) in faces {
            let c = n * 0.5
            let corners = [c - u*0.5 - v*0.5,
                           c + u*0.5 - v*0.5,
                           c + u*0.5 + v*0.5,
                           c - u*0.5 + v*0.5]
            for p in corners { verts += [p.x, p.y, p.z, n.x, n.y, n.z] }
            indices += [base, base+1, base+2, base, base+2, base+3]
            base += 4
        }
        cubeVB     = device.makeBuffer(bytes: verts,   length: verts.count   * 4, options: .storageModeShared)!
        cubeIB     = device.makeBuffer(bytes: indices,  length: indices.count * 2, options: .storageModeShared)!
        indexCount = indices.count
    }

    // -----------------------------------------------------------------------
    func encode(_ enc: MTLRenderCommandEncoder,
                viewProj: simd_float4x4,
                entities: UnsafePointer<bf_entity_draw>?,
                count:    Int) {
        guard let entities = entities, count > 0 else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(cubeVB, offset: 0, index: 0)

        // Time source: wall-clock seconds, continuous across frames.
        let t = Float(CACurrentMediaTime())

        for i in 0..<count {
            let e      = entities[i]
            let s      = e.scale
            let pos    = SIMD3<Float>(e.position.x, e.position.y, e.position.z)
            let isBoss = (e.kind == 1)
            let sat    = e.sat

            // Per-entity phase offset so animals don't all step in sync.
            // Hash from grid position (coarse).
            let phaseHash = sin(pos.x * 1.3 + pos.z * 2.7)
            let phase     = t + phaseHash * 3.14159

            // Walk cycle parameters
            let walkSpeed : Float = 2.8                        // radians/sec
            let legSwing  : Float = isBoss ? 0.28 : 0.32      // max leg angle
            let bodyBob   : Float = isBoss ? 0.012 : 0.016    // vertical bob amplitude in model-space
            let headBob   : Float = isBoss ? 0.008 : 0.012

            let legAngle  = sin(phase * walkSpeed) * legSwing  // front/back swing
            let bobOffset = abs(sin(phase * walkSpeed)) * bodyBob * s

            // Boss is bigger/bulkier: wider body, larger head
            let bossScale: Float = isBoss ? 1.35 : 1.0

            // ---- anatomy dimensions (all in world units = s * fraction) ----
            // Body: wide rectangle, sitting low
            let bW = s * 0.80 * bossScale  // body width  (X)
            let bH = s * 0.60 * bossScale  // body height (Y)
            let bD = s * 1.10 * bossScale  // body depth  (Z, length nose-to-tail)

            // Head: cube, slightly wider than body height
            let hS = s * 0.55 * bossScale

            // Leg: thin rectangle
            let legW = s * 0.20 * bossScale
            let legH = s * 0.45 * bossScale
            let legD = s * 0.20 * bossScale

            // Ear: small slab on top of head
            let earW = s * 0.18 * bossScale
            let earH = s * 0.22 * bossScale
            let earD = s * 0.10 * bossScale

            // Tail: tiny slab behind body
            let tailW = s * 0.18 * bossScale
            let tailH = s * 0.18 * bossScale
            let tailD = s * 0.15 * bossScale

            // Ground offset: legs hang down; body bottom is at legH, body center at legH + bH/2
            let groundY = pos.y     // entity position is at ground level
            let bodyY   = groundY + legH + bH * 0.5 + bobOffset
            let bodyZ   = Float(0)  // local forward offset (rotated later)

            // Rotation around Y (yaw)
            let R = EntityRenderer.rotY(e.yaw)
            // Helper: build world matrix for a part at local offset, scaled to part dims
            func partWorld(localOffset: SIMD3<Float>, dims: SIMD3<Float>, extraRot: simd_float4x4 = matrix_identity_float4x4) -> simd_float4x4 {
                // 1. Scale unit cube to part size
                // 2. Apply any extra local rotation (leg swing around top-of-leg)
                // 3. Translate to local offset
                // 4. Apply entity yaw
                // 5. Translate to world position
                let worldCenter = SIMD3<Float>(pos.x, bodyY, pos.z)
                return EntityRenderer.trans(worldCenter)
                     * R
                     * EntityRenderer.trans(localOffset)
                     * extraRot
                     * EntityRenderer.scaleM(dims)
            }

            // We build world matrix differently for legs since they pivot at hip.
            // Hip pivot = top of leg local position.
            func legWorld(hipLocal: SIMD3<Float>, swingAngle: Float) -> simd_float4x4 {
                // Swing around X axis (forward/back) at the hip
                let swing = EntityRenderer.rotX(swingAngle)
                // Leg cube center is half-leg-height below hip in local-leg space
                let legCenterInLeg = SIMD3<Float>(0, -legH * 0.5, 0)
                let worldCenter    = SIMD3<Float>(pos.x, bodyY, pos.z)
                return EntityRenderer.trans(worldCenter)
                     * R
                     * EntityRenderer.trans(hipLocal)
                     * swing
                     * EntityRenderer.trans(legCenterInLeg)
                     * EntityRenderer.scaleM(SIMD3(legW, legH, legD))
            }

            // Head position: forward from body center, at top of body
            // Forward in local space is +Z direction (before yaw rotation)
            let headLocalOffset = SIMD3<Float>(0, bH * 0.5 + hS * 0.5 + headBob * sin(phase * walkSpeed) * s, bD * 0.38)

            // Colors
            let baseCol  = SIMD3<Float>(e.color.x, e.color.y, e.color.z)
            let darkCol  = baseCol * 0.72   // legs, ears, tail slightly darker
            let eyeCol   = SIMD3<Float>(0.05, 0.05, 0.07)  // near-black eyes

            // ---- draw all parts ----

            // 1. BODY
            drawCube(enc: enc, viewProj: viewProj,
                     model: partWorld(localOffset: SIMD3(0, 0, bodyZ), dims: SIMD3(bW, bH, bD)),
                     rgb: baseCol, sat: sat)

            // 2. HEAD
            drawCube(enc: enc, viewProj: viewProj,
                     model: partWorld(localOffset: headLocalOffset, dims: SIMD3(hS, hS, hS)),
                     rgb: baseCol, sat: sat)

            // 3. EYES — two small dark cubes on the front face of the head
            //    placed slightly forward (z + hS*0.5) and to left/right
            let eyeSize = SIMD3<Float>(s * 0.10 * bossScale, s * 0.10 * bossScale, s * 0.04 * bossScale)
            let eyeY    = headLocalOffset.y + hS * 0.12
            let eyeZ    = headLocalOffset.z + hS * 0.50
            let eyeLX   = -hS * 0.22
            let eyeRX   =  hS * 0.22
            drawCube(enc: enc, viewProj: viewProj,
                     model: partWorld(localOffset: SIMD3(eyeLX, eyeY, eyeZ), dims: eyeSize),
                     rgb: eyeCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj,
                     model: partWorld(localOffset: SIMD3(eyeRX, eyeY, eyeZ), dims: eyeSize),
                     rgb: eyeCol, sat: sat)

            // 4. EARS — on top of head, slightly apart
            let earBaseY = headLocalOffset.y + hS * 0.50
            let earZ     = headLocalOffset.z
            drawCube(enc: enc, viewProj: viewProj,
                     model: partWorld(localOffset: SIMD3(-hS * 0.28, earBaseY + earH * 0.5, earZ), dims: SIMD3(earW, earH, earD)),
                     rgb: darkCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj,
                     model: partWorld(localOffset: SIMD3( hS * 0.28, earBaseY + earH * 0.5, earZ), dims: SIMD3(earW, earH, earD)),
                     rgb: darkCol, sat: sat)

            // 5. TAIL — behind body (local -Z), wagging a tiny bit
            let tailWag  = sin(phase * walkSpeed * 1.5) * 0.15
            let tailSwing = EntityRenderer.rotX(tailWag)
            let tailHipLocal = SIMD3<Float>(0, bH * 0.30, -bD * 0.50)
            let tailLocal    = SIMD3<Float>(0, tailH * 0.5, 0)
            do {
                let worldCenter = SIMD3<Float>(pos.x, bodyY, pos.z)
                let tailModel = EntityRenderer.trans(worldCenter)
                    * R
                    * EntityRenderer.trans(tailHipLocal)
                    * tailSwing
                    * EntityRenderer.trans(tailLocal)
                    * EntityRenderer.scaleM(SIMD3(tailW, tailH, tailD))
                drawCube(enc: enc, viewProj: viewProj, model: tailModel, rgb: darkCol, sat: sat)
            }

            // 6. LEGS — 4 legs, paired front/back, diagonal swing
            // Hip positions in local (body) space, at the bottom of the body
            let hipY  = -bH * 0.5   // bottom of body
            let hipXL = -bW * 0.35  // left side
            let hipXR =  bW * 0.35  // right side
            let hipZF =  bD * 0.30  // front
            let hipZB = -bD * 0.30  // back

            // Diagonals swing opposite — front-left with back-right
            drawCube(enc: enc, viewProj: viewProj,
                     model: legWorld(hipLocal: SIMD3(hipXL, hipY, hipZF), swingAngle:  legAngle),
                     rgb: darkCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj,
                     model: legWorld(hipLocal: SIMD3(hipXR, hipY, hipZF), swingAngle: -legAngle),
                     rgb: darkCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj,
                     model: legWorld(hipLocal: SIMD3(hipXL, hipY, hipZB), swingAngle: -legAngle),
                     rgb: darkCol, sat: sat)
            drawCube(enc: enc, viewProj: viewProj,
                     model: legWorld(hipLocal: SIMD3(hipXR, hipY, hipZB), swingAngle:  legAngle),
                     rgb: darkCol, sat: sat)

            // 7. BOSS extras: two horn/crown cubes on top of head
            if isBoss {
                let hornW = s * 0.14
                let hornH = s * 0.28
                let hornD = s * 0.14
                let hornY = headLocalOffset.y + hS * 0.50 + hornH * 0.5
                let hornTilt = EntityRenderer.rotZ(0.18)  // slight outward lean
                let hornTiltIn = EntityRenderer.rotZ(-0.18)
                let hornDims = SIMD3<Float>(hornW, hornH, hornD)
                // Use SIMD3<Float> to avoid ambiguity
                let hornOffset1 = SIMD3<Float>(-hS * 0.22, hornY, headLocalOffset.z)
                let hornOffset2 = SIMD3<Float>( hS * 0.22, hornY, headLocalOffset.z)
                let worldCenter = SIMD3<Float>(pos.x, bodyY, pos.z)

                let hornModel1 = EntityRenderer.trans(worldCenter)
                    * R
                    * EntityRenderer.trans(hornOffset1)
                    * hornTiltIn
                    * EntityRenderer.scaleM(hornDims)
                drawCube(enc: enc, viewProj: viewProj, model: hornModel1, rgb: baseCol * 1.15, sat: sat)

                let hornModel2 = EntityRenderer.trans(worldCenter)
                    * R
                    * EntityRenderer.trans(hornOffset2)
                    * hornTilt
                    * EntityRenderer.scaleM(hornDims)
                drawCube(enc: enc, viewProj: viewProj, model: hornModel2, rgb: baseCol * 1.15, sat: sat)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Draw one unit cube with given model matrix and color.
    @inline(__always)
    private func drawCube(enc: MTLRenderCommandEncoder,
                          viewProj: simd_float4x4,
                          model: simd_float4x4,
                          rgb: SIMD3<Float>,
                          sat: Float) {
        var u = EUniforms(mvp: viewProj * model,
                          color: SIMD4<Float>(rgb.x, rgb.y, rgb.z, sat))
        enc.setVertexBytes(&u, length: MemoryLayout<EUniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                  indexType: .uint16, indexBuffer: cubeIB, indexBufferOffset: 0)
    }

    // -----------------------------------------------------------------------
    // Matrix helpers
    static func trans(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }
    static func scaleM(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = s.x
        m.columns.1.y = s.y
        m.columns.2.z = s.z
        return m
    }
    static func rotY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4( c, 0, -s, 0)
        m.columns.2 = SIMD4( s, 0,  c, 0)
        return m
    }
    static func rotX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.1 = SIMD4(0,  c, s, 0)
        m.columns.2 = SIMD4(0, -s, c, 0)
        return m
    }
    static func rotZ(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4( c, s, 0, 0)
        m.columns.1 = SIMD4(-s, c, 0, 0)
        return m
    }

    // -----------------------------------------------------------------------
    // MSL shader — unchanged from M3; EUniforms matches struct above.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CVert    { packed_float3 pos; packed_float3 normal; };
    struct EUniforms { float4x4 mvp; float4 color; };
    struct EOut     { float4 position [[position]]; float3 color; float shade; float sat; };

    vertex EOut evmain(uint vid [[vertex_id]],
                       device const CVert* v [[buffer(0)]],
                       constant EUniforms& u [[buffer(1)]]) {
        CVert cv = v[vid];
        float3 n = float3(cv.normal);
        // Simple directional shading: top face bright, side faces medium, bottom dim
        float shade = clamp(0.55 + 0.30 * n.y + 0.15 * n.x, 0.0, 1.0);
        EOut o;
        o.position = u.mvp * float4(float3(cv.pos), 1.0);
        o.color    = u.color.rgb;
        o.shade    = shade;
        o.sat      = u.color.w;
        return o;
    }

    fragment float4 efmain(EOut in [[stage_in]]) {
        float3 c = in.color * in.shade;
        // Dim desaturation: mix toward luminance by (1 - sat)
        float l = dot(c, float3(0.299, 0.587, 0.114));
        c = mix(float3(l), c, clamp(in.sat, 0.0, 1.0));
        return float4(c, 1.0);
    }
    """
}
