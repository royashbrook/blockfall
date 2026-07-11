// ============================================================================
// Blockfall — break particles (juice). Chunky voxel debris that bounces and
// settles, colored per block type. Self-contained (own pipeline + unit cube).
// Owned by the Renderer; updated + encoded each frame.
// ============================================================================
import MetalKit
import simd
import CBlockcore

final class ParticleSystem {

    // -------------------------------------------------------------------------
    // Per-particle state
    // -------------------------------------------------------------------------
    private struct P {
        var pos:         SIMD3<Float>
        var vel:         SIMD3<Float>
        var color:       SIMD3<Float>
        var size:        Float       // world-space half-extent (before scale fade)
        var life:        Float       // remaining lifetime in seconds
        var maxLife:     Float       // total lifetime (for fade math)
        var angle:       SIMD3<Float>  // Euler angles (radians) — tumble orientation
        var angVel:      SIMD3<Float>  // angular velocity (rad/s)
        var floorY:      Float       // Y of the block base — bounce plane
        var bounces:     Int         // number of bounces so far
    }

    private var parts:   [P]   = []
    private var rng:     UInt64 = 0x9E3779B97F4A7C15

    // -------------------------------------------------------------------------
    // Metal resources (immutable after init)
    // -------------------------------------------------------------------------
    private let pipeline:   MTLRenderPipelineState
    private let cubeVB:     MTLBuffer
    private let cubeIB:     MTLBuffer
    private let indexCount: Int

    // -------------------------------------------------------------------------
    // Block-id → base colour table
    //  IDs match the game's block registry:
    //   1=grass 2=dirt 3=stone 4=oak_planks 5=oak_leaves 6=sand 7=glow
    //   8=stone_brick 10=cobblestone 11=gravel 12=snow 13=ice
    //   21=oak_log 22=birch_log 27=birch_leaves 29=mossy_stone
    //   36=flower_red 37=flower_yellow 38=tall_grass
    // -------------------------------------------------------------------------
    private static let blockColours: [Int: SIMD3<Float>] = [
         1: SIMD3(0.35, 0.60, 0.22),   // grass — green
         2: SIMD3(0.50, 0.33, 0.18),   // dirt — brown
         3: SIMD3(0.52, 0.52, 0.52),   // stone — grey
         4: SIMD3(0.72, 0.57, 0.36),   // oak_planks — tan
         5: SIMD3(0.28, 0.55, 0.18),   // oak_leaves — green
         6: SIMD3(0.86, 0.82, 0.62),   // sand — pale yellow
         7: SIMD3(1.00, 0.95, 0.50),   // glow — bright warm (HDR-ish)
         8: SIMD3(0.46, 0.46, 0.46),   // stone_brick — grey
        10: SIMD3(0.44, 0.44, 0.44),   // cobblestone — grey
        11: SIMD3(0.48, 0.46, 0.42),   // gravel — grey-brown
        12: SIMD3(0.92, 0.94, 0.96),   // snow — near white
        13: SIMD3(0.72, 0.88, 0.96),   // ice — pale blue
        21: SIMD3(0.48, 0.32, 0.16),   // oak_log — brown
        22: SIMD3(0.82, 0.76, 0.58),   // birch_log — light tan
        27: SIMD3(0.30, 0.58, 0.20),   // birch_leaves — green
        29: SIMD3(0.35, 0.52, 0.28),   // mossy_stone — mossy
        36: SIMD3(0.88, 0.18, 0.14),   // flower_red
        37: SIMD3(0.90, 0.82, 0.12),   // flower_yellow
        38: SIMD3(0.32, 0.60, 0.22),   // tall_grass — green
        56: SIMD3(0.47, 0.31, 0.16),   // chopping_block — oak stump
        57: SIMD3(0.46, 0.48, 0.45),   // shaped mixed stone rubble
        58: SIMD3(0.52, 0.53, 0.56),   // mason bench — dressed stone
        59: SIMD3(0.28, 0.30, 0.34),   // blacksmith forge — iron/stone
        60: SIMD3(0.38, 0.58, 0.32),   // herbalist table — herbs/wood
        61: SIMD3(0.68, 0.48, 0.25),   // builder sawbench — fresh timber
    ]
    private static let defaultColour = SIMD3<Float>(0.55, 0.55, 0.55)   // mid-grey

    // -------------------------------------------------------------------------
    // Physics constants
    // -------------------------------------------------------------------------
    private let kGravity:   Float = 22.0   // m/s² downward
    private let kBounceY:   Float = 0.48   // restitution on vertical bounce
    private let kFriction:  Float = 0.62   // XZ velocity multiplier on bounce
    private let kMaxBounces: Int  = 3      // after this, slide to rest
    private let kCapCount:  Int   = 300    // max live particles (recycle oldest)

    // -------------------------------------------------------------------------
    // Fast xorshift LCG — no Foundation dependency
    // -------------------------------------------------------------------------
    @inline(__always)
    private func rnd() -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(rng >> 40) / Float(1 << 24)   // [0, 1)
    }

    // Returns value in [-1, 1)
    @inline(__always)
    private func rndS() -> Float { rnd() * 2.0 - 1.0 }

    // -------------------------------------------------------------------------
    // Initialiser — build Metal pipeline and unit-cube geometry
    // -------------------------------------------------------------------------
    init(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let lib = try? device.makeLibrary(source: ParticleSystem.shaderSource, options: nil) else {
            fatalError("particle shader failed")
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction  = lib.makeFunction(name: "pvmain")
        pd.fragmentFunction = lib.makeFunction(name: "pfmain")
        pd.colorAttachments[0].pixelFormat = colorFormat
        pd.depthAttachmentPixelFormat = .depth32Float
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)

        // Unit cube: 24 unique verts (4 per face × 6 faces), 36 indices.
        var verts: [Float] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0,0,1),  SIMD3(1,0,0),  SIMD3(0,1,0)),
            (SIMD3(0,0,-1), SIMD3(-1,0,0), SIMD3(0,1,0)),
            (SIMD3(1,0,0),  SIMD3(0,0,-1), SIMD3(0,1,0)),
            (SIMD3(-1,0,0), SIMD3(0,0,1),  SIMD3(0,1,0)),
            (SIMD3(0,1,0),  SIMD3(1,0,0),  SIMD3(0,0,-1)),
            (SIMD3(0,-1,0), SIMD3(1,0,0),  SIMD3(0,0,1)),
        ]
        var idx: [UInt16] = []; var base: UInt16 = 0
        for (n, u, v) in faces {
            let c = n * 0.5
            for p in [c-u*0.5-v*0.5, c+u*0.5-v*0.5, c+u*0.5+v*0.5, c-u*0.5+v*0.5] {
                verts += [p.x, p.y, p.z]
            }
            idx += [base, base+1, base+2, base, base+2, base+3]; base += 4
        }
        cubeVB     = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)!
        cubeIB     = device.makeBuffer(bytes: idx,   length: idx.count   * 2, options: .storageModeShared)!
        indexCount = idx.count
    }

    // -------------------------------------------------------------------------
    // MARK: spawn(at:blockId:)
    // Emit 8-14 chunky voxel debris pieces, coloured by block type.
    // -------------------------------------------------------------------------
    func spawn(at v: bf_ivec3, blockId: Int) {
        let base  = SIMD3<Float>(Float(v.x) + 0.5, Float(v.y), Float(v.z) + 0.5)
        let floorY = Float(v.y)   // bounce plane is the bottom face of the broken block

        // Look up base colour; fall back to default if block id unknown.
        let baseCol = ParticleSystem.blockColours[blockId] ?? ParticleSystem.defaultColour

        // Number of debris pieces: 8-14.
        let count = 8 + Int(rnd() * 7)   // 8..14

        for _ in 0 ..< count {
            // Brightness jitter: ±15% on each channel, clamped 0..1.5 (HDR ok).
            let brite = 0.85 + rnd() * 0.30   // [0.85, 1.15]
            let colJitter = SIMD3<Float>(
                min(1.5, baseCol.x * brite + (rnd() - 0.5) * 0.08),
                min(1.5, baseCol.y * brite + (rnd() - 0.5) * 0.08),
                min(1.5, baseCol.z * brite + (rnd() - 0.5) * 0.08)
            )

            // Size: chunky (0.14-0.22) or small (0.05-0.09).
            let chunky  = rnd() > 0.45   // ~55% chunky, 45% small chips
            let size: Float = chunky ? 0.14 + rnd() * 0.08
                                      : 0.05 + rnd() * 0.04

            // Spawn position: scattered in a half-block radius around centre.
            let spawnPos = SIMD3<Float>(
                base.x + rndS() * 0.45,
                Float(v.y) + 0.5 + rnd() * 0.3,   // slightly inside block
                base.z + rndS() * 0.45
            )

            // Launch velocity: outward + upward burst.
            let lateral = SIMD3<Float>(rndS(), 0, rndS())
            let lateralMag: Float = 1.5 + rnd() * 3.5
            let upward: Float     = 3.0 + rnd() * 5.0
            let vel = SIMD3<Float>(
                lateral.x * lateralMag,
                upward,
                lateral.z * lateralMag
            )

            // Tumble: random angular velocity (rad/s) on all axes.
            let angVel = SIMD3<Float>(
                rndS() * 8.0,
                rndS() * 6.0,
                rndS() * 8.0
            )

            // Lifetime: 0.8-1.5 s.
            let life: Float = 0.8 + rnd() * 0.7

            parts.append(P(
                pos:      spawnPos,
                vel:      vel,
                color:    colJitter,
                size:     size,
                life:     life,
                maxLife:  life,
                angle:    SIMD3(rnd() * .pi * 2, rnd() * .pi * 2, rnd() * .pi * 2),
                angVel:   angVel,
                floorY:   floorY,
                bounces:  0
            ))
        }

        // Recycle oldest to stay within cap.
        if parts.count > kCapCount {
            parts.removeFirst(parts.count - kCapCount)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: update(_:)  — called by Renderer each frame
    // -------------------------------------------------------------------------
    func update(_ dt: Float) {
        let safeDt = min(dt, 0.05)   // clamp large dt spikes (e.g. first frame)

        for i in parts.indices {
            // Gravity.
            parts[i].vel.y -= kGravity * safeDt

            // Integrate position.
            parts[i].pos   += parts[i].vel * safeDt

            // Tumble.
            parts[i].angle += parts[i].angVel * safeDt

            // Bounce off floor plane.
            let halfSize = parts[i].size * 0.5
            let floor    = parts[i].floorY + halfSize

            if parts[i].pos.y < floor && parts[i].vel.y < 0 {
                parts[i].pos.y = floor

                if parts[i].bounces < kMaxBounces {
                    parts[i].vel.y  = -parts[i].vel.y * kBounceY
                    parts[i].vel.x *=  kFriction
                    parts[i].vel.z *=  kFriction
                    // Damp spin on bounce.
                    parts[i].angVel *= 0.55
                    parts[i].bounces += 1
                } else {
                    // Settled: zero vertical motion, slide to stop.
                    parts[i].vel.y  = 0
                    parts[i].vel.x *= kFriction * 0.5
                    parts[i].vel.z *= kFriction * 0.5
                    parts[i].angVel *= 0.3
                }
            }

            parts[i].life -= safeDt
        }

        parts.removeAll { $0.life <= 0 }
    }

    // -------------------------------------------------------------------------
    // MARK: encode(_:viewProj:)  — called by Renderer each frame
    // -------------------------------------------------------------------------
    func encode(_ enc: MTLRenderCommandEncoder, viewProj: simd_float4x4) {
        guard !parts.isEmpty else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(cubeVB, offset: 0, index: 0)

        for p in parts {
            // Fade out in the last 25% of life + shrink slightly.
            let t       = p.life / max(p.maxLife, 1e-6)   // 1→0 as particle ages
            let fadeT   = min(t / 0.25, 1.0)              // 0→1 ramp in last 25%
            let scale   = p.size * (0.7 + 0.3 * t)        // subtle size reduction

            // Build model matrix: scale × rotation (ZXY Euler) × translation.
            // Rotation: cheap intrinsic Euler — good enough for tumbling debris.
            let cx = cos(p.angle.x), sx = sin(p.angle.x)
            let cy = cos(p.angle.y), sy = sin(p.angle.y)
            let cz = cos(p.angle.z), sz = sin(p.angle.z)

            // R = Ry * Rx * Rz  (standard YXZ order — arbitrary for visual tumble)
            let r00 = cy*cz + sy*sx*sz;  let r01 = cy*sz - sy*sx*cz;  let r02 =  sy*cx
            let r10 =   -cx*sz          ;  let r11 =    cx*cz          ;  let r12 =     sx
            let r20 = -sy*cz + cy*sx*sz ;  let r21 = -sy*sz - cy*sx*cz;  let r22 =  cy*cx

            let m = simd_float4x4(columns: (
                SIMD4(scale*r00, scale*r10, scale*r20, 0),
                SIMD4(scale*r01, scale*r11, scale*r21, 0),
                SIMD4(scale*r02, scale*r12, scale*r22, 0),
                SIMD4(p.pos.x, p.pos.y, p.pos.z, 1)
            ))

            var u = ParticleUniforms(
                mvp:   viewProj * m,
                color: SIMD4(p.color.x, p.color.y, p.color.z, fadeT)
            )
            enc.setVertexBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint16,
                                      indexBuffer: cubeIB, indexBufferOffset: 0)
        }
    }

    // -------------------------------------------------------------------------
    // Uniform struct passed to vertex shader (unchanged layout).
    // -------------------------------------------------------------------------
    struct ParticleUniforms { var mvp: simd_float4x4; var color: SIMD4<Float> }

    // -------------------------------------------------------------------------
    // Metal shaders — unchanged from original; colour alpha carries the fade.
    // -------------------------------------------------------------------------
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4x4 mvp; float4 color; };
    struct VO { float4 position [[position]]; float3 color; float alpha; };
    vertex VO pvmain(uint vid [[vertex_id]],
                     device const float3* v [[buffer(0)]],
                     constant U& u [[buffer(1)]]) {
        VO o;
        o.position = u.mvp * float4(v[vid], 1.0);
        o.color    = u.color.rgb;
        o.alpha    = u.color.a;
        return o;
    }
    fragment float4 pfmain(VO in [[stage_in]]) {
        return float4(in.color * in.alpha, in.alpha);
    }
    """
}
