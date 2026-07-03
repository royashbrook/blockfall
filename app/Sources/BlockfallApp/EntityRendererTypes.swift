import MetalKit
import simd

// Passed to the vertex shader once per cube draw.
struct EUniforms {
    var mvp:   simd_float4x4
    var color: SIMD4<Float>   // rgb + sat (w); w = -1 means emissive (no shading)
    // #116 model matrix (object -> world) so the fragment can recover its WORLD position and
    // march the world voxel sun shadow the same way the terrain does.
    var model: simd_float4x4 = matrix_identity_float4x4
    // #180 horizon curvature: camPosH.xyz = camera world pos, .w = enable (0 = flat).
    // vpYCol = viewProj column 1 so the vertex shader can apply the world-Y drop to
    // the precomputed mvp result in clip space (see EUniforms in the MSL).
    var camPosH: SIMD4<Float> = .zero
    var vpYCol:  SIMD4<Float> = .zero
}

// #116 character-shadow uniforms: shared by the entity cube fragment (RECEIVE: march toward the
// sun against the world occupancy grid) and the ground contact-shadow pass (CAST: a stretched,
// offset soft blob under the entity). Mirrors the terrain's voxel-shadow fields exactly so the
// shade a creature gets agrees with the ground around it.
//   sunDirTime : xyz = sun dir (pointing FROM the sun, i.e. downward), w = time_of_day
//   voxOrigin  : xyz = grid origin (world block coords),               w = march distance (world units)
//   voxDims    : xyz = grid dims (voxels),                             w = soft-shadow flag (unused here, hard)
//   params     : x = char-shadow enable (0/1, already grid-gated by the host), rest reserved
struct EntityShadowUniforms {
    var sunDirTime: SIMD4<Float> = .zero
    var voxOrigin:  SIMD4<Float> = .zero
    var voxDims:    SIMD4<Float> = .zero
    var params:     SIMD4<Float> = .zero
}

// #116 per-entity ground contact-shadow instance (CAST). One flat quad per entity, anchored at the
// entity's foot ground position; the fragment shader stretches/offsets a soft SDF blob along the
// sun azimuth and snaps to the surface via the occupancy grid. 32 bytes.
struct EntityShadowInstance {
    var footRadius: SIMD4<Float> = .zero  // xyz = foot world pos (ground contact), w = blob radius (world units)
    var meta:       SIMD4<Float> = .zero  // reserved
}

// #116 uniforms for the ground contact-shadow pass (CAST). viewProj + the same voxel grid the
// terrain marches, so the blob snaps to the real surface and tracks the sun. 64 + 48 = 112 bytes.
struct GroundShadowUniforms {
    var viewProj:   simd_float4x4
    var sunDirTime: SIMD4<Float>
    var voxOrigin:  SIMD4<Float>
    var voxDims:    SIMD4<Float>
    var camPosH:    SIMD4<Float> = .zero  // #180 horizon curvature: xyz = cam pos, w = enable
}
