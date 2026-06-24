// ============================================================================
// Blockfall — Greedy voxel mesher implementation (Track D)
// engine/src/mesher.cpp
//
// Algorithm: standard Mikola Lysenko / 0fps greedy meshing.
//
// For each of the 6 axis-aligned face directions (±X, ±Y, ±Z):
//   For each of the 16 slices perpendicular to that axis (coord d ∈ 0..15):
//     Build a 16×16 mask[u][v]:
//       - non-zero (= block id) when the voxel at (d,u,v) is SOLID and the
//         neighbour in the face direction (d±1, u, v) is AIR.
//       - 0 (no face) otherwise.
//     Greedy-merge mask into maximal same-id rectangles (also matching light
//     and per-corner AO — any difference splits the merge):
//       Scan in (u,v) order; on each unmerged non-zero cell:
//         Extend width w in +u while mask[u+w][v] == same key and unmerged.
//         Extend height h in +v while entire row [u..u+w-1][v+h] matches.
//         Mark the w×h region merged (set mask to 0).
//         Emit one quad (4 BFVertex + 6 uint32 indices).
//
// Vertex positions are within-chunk corners (0..16 inclusive).
// Winding: CCW as seen from outside (consistent with Metal front-face = CCW).
//
// Per-vertex AO (Mikola Lysenko "0fps" method):
//   For each of the 4 quad corners, sample 3 neighbours in the tangent plane
//   one step out along the face normal.  For corner (du, dv) ∈ {(0,0),(1,0),
//   (1,1),(0,1)}, the two edge neighbours and one diagonal:
//     s1 = solid(n + du_tangent), s2 = solid(n + dv_tangent),
//     c  = solid(n + du_tangent + dv_tangent)
//   If s1 && s2 => ao=0; else ao = 3 - s1 - s2 - c.
//   3 = fully open, 0 = fully occluded.
//   WATER (id 9) does NOT occlude.
// ============================================================================
#include "blockcore/mesher.hpp"
#include "blockcore/vertex.hpp"
#include <cstring>

namespace bf {

namespace {

// ---- axis description -------------------------------------------------------
// For each face direction we describe:
//   axis  : which world axis is the sweep axis (0=X,1=Y,2=Z)
//   sign  : +1 or -1 (which way the face points)
//   u_axis: first tangent axis
//   v_axis: second tangent axis
//   normal: BFNormal code
struct FaceDir {
    int      axis;   // 0,1,2
    int      sign;   // +1 or -1: neighbour offset along axis
    int      u_axis; // tangent axes
    int      v_axis;
    std::uint32_t normal;
    bool     reverse; // reverse u-winding so the quad is CCW from OUTSIDE
};

// `reverse` is true when cross(u_axis, v_axis) points OPPOSITE the outward
// normal (axis*sign) — i.e. the (u,v,outward) basis is left-handed, so the
// default (u,v)-CCW order would be back-facing. For Y faces, X×Z = -Y, which
// flips the handedness relative to X/Z faces — the source of the original
// top-face culling bug. Correct reverse set: {-X, +Y, -Z}.
static constexpr FaceDir kFaceDirs[6] = {
    {0, +1, 1, 2, BF_NX_POS, false}, // +X : Y×Z=+X, outward +X -> ok
    {0, -1, 1, 2, BF_NX_NEG, true },  // -X : outward -X -> reverse
    {1, +1, 0, 2, BF_NY_POS, true },  // +Y : X×Z=-Y, outward +Y -> reverse
    {1, -1, 0, 2, BF_NY_NEG, false}, // -Y : outward -Y -> ok
    {2, +1, 0, 1, BF_NZ_POS, false}, // +Z : X×Y=+Z, outward +Z -> ok
    {2, -1, 0, 1, BF_NZ_NEG, true },  // -Z : outward -Z -> reverse
};

// ---- coordinate helpers -----------------------------------------------------
// Convert (axis, u_axis, v_axis, d, u, v) -> (x,y,z)
inline void axes_to_xyz(const FaceDir& fd, int d, int u, int v,
                        int& ox, int& oy, int& oz) {
    int arr[3] = {0, 0, 0};
    arr[fd.axis]   = d;
    arr[fd.u_axis] = u;
    arr[fd.v_axis] = v;
    ox = arr[0]; oy = arr[1]; oz = arr[2];
}

// Block at (x,y,z) in the given chunk; no bounds checking needed (x,y,z ∈ 0..15).
inline BlockId chunk_get(IChunk* chunk, int x, int y, int z) {
    if (!chunk) return 0;
    return chunk->get(x, y, z);
}

// Neighbour block at local (x,y,z) with offset along fd.axis.
// May cross into an adjacent chunk (fetched from store).
inline BlockId neighbour_block(IChunk* current_chunk, ChunkCoord cc,
                               IChunkStore& store, const FaceDir& fd,
                               int x, int y, int z) {
    int nx = x, ny = y, nz = z;
    // Apply the face-direction step in world-local coords.
    if      (fd.axis == 0) nx += fd.sign;
    else if (fd.axis == 1) ny += fd.sign;
    else                   nz += fd.sign;

    // Check if we crossed a chunk boundary.
    if (nx >= 0 && nx < kChunkDim &&
        ny >= 0 && ny < kChunkDim &&
        nz >= 0 && nz < kChunkDim) {
        return chunk_get(current_chunk, nx, ny, nz);
    }

    // Crossed into adjacent chunk.
    ChunkCoord nc = cc;
    if      (nx < 0)         { nc.x -= 1; nx += kChunkDim; }
    else if (nx >= kChunkDim){ nc.x += 1; nx -= kChunkDim; }
    if      (ny < 0)         { nc.y -= 1; ny += kChunkDim; }
    else if (ny >= kChunkDim){ nc.y += 1; ny -= kChunkDim; }
    if      (nz < 0)         { nc.z -= 1; nz += kChunkDim; }
    else if (nz >= kChunkDim){ nc.z += 1; nz -= kChunkDim; }

    IChunk* neighbour = store.get(nc);
    if (!neighbour) return 0;  // not resident -> treat as air
    return neighbour->get(nx, ny, nz);
}

// Light (sky, block) of the air cell adjacent to a face (Track F, ADR 0004).
// That cell is the visible side, so its light is what the face shows.
inline void neighbour_light(IChunk* current_chunk, ChunkCoord cc, IChunkStore& store,
                            const FaceDir& fd, int x, int y, int z,
                            std::uint8_t& sky, std::uint8_t& blk) {
    int nx = x, ny = y, nz = z;
    if      (fd.axis == 0) nx += fd.sign;
    else if (fd.axis == 1) ny += fd.sign;
    else                   nz += fd.sign;
    if (nx >= 0 && nx < kChunkDim && ny >= 0 && ny < kChunkDim && nz >= 0 && nz < kChunkDim) {
        sky = current_chunk->sky_light(nx, ny, nz);
        blk = current_chunk->block_light(nx, ny, nz);
        return;
    }
    ChunkCoord nc = cc;
    if      (nx < 0)          { nc.x -= 1; nx += kChunkDim; }
    else if (nx >= kChunkDim) { nc.x += 1; nx -= kChunkDim; }
    if      (ny < 0)          { nc.y -= 1; ny += kChunkDim; }
    else if (ny >= kChunkDim) { nc.y += 1; ny -= kChunkDim; }
    if      (nz < 0)          { nc.z -= 1; nz += kChunkDim; }
    else if (nz >= kChunkDim) { nc.z += 1; nz -= kChunkDim; }
    IChunk* nb = store.get(nc);
    if (!nb) { sky = 15; blk = 0; return; }   // outside loaded area -> open sky
    sky = nb->sky_light(nx, ny, nz);
    blk = nb->block_light(nx, ny, nz);
}

// ---- plant helpers ----------------------------------------------------------

// Cross-plant block ids: flower_red(36), flower_yellow(37), tall_grass(38), mushroom(39).
// Plants are non-opaque (like air/water) for face culling purposes: a solid block
// next to a plant must still emit its face.  Plants are also non-occluders for AO.
// They emit cross-billboard geometry instead of cube faces.
// Sub-voxel props (#51/#52): flower_red(36), flower_yellow(37), tall_grass(38),
// mushroom(39), color_crystal(40). The RENDERER draws these as detailed little
// instanced models, so the mesher emits NO geometry for them — but they stay
// non-opaque / non-occluding so neighbours still show their faces and AO isn't
// darkened around them.
inline bool is_subvoxel_prop(BlockId id) {
    return id == 36 || id == 37 || id == 38 || id == 39 || id == 40 || id == 41 || id == 42;
}
// No cross-billboard plants remain in the mesher (all are sub-voxel props now).
inline bool is_cross_plant(BlockId) {
    return false;
}

// Torch block id (32): a thin sub-cell prop, not a full cube.  Like cross-plants
// it is non-opaque (does not cull neighbours' cube faces), is not an AO occluder,
// and emits its own custom geometry instead of cube faces (see emit_torch).
inline bool is_torch(BlockId id) {
    return id == 32;
}

// A "billboard"/prop block emits custom geometry in the prop pass instead of
// greedy cube faces: cross-plants (36-39) and torches (32).
inline bool is_prop(BlockId id) {
    return is_cross_plant(id) || is_torch(id) || is_subvoxel_prop(id);
}

// ---- opacity / transparency helpers -----------------------------------------

// A cell is OPAQUE if it is non-air, not water (id 9), and not a prop.
// Air (0), water (9), plants (36-39), and torches (32) are NON-opaque.
inline bool is_opaque(BlockId id) {
    return id != 0 && id != 9 && !is_prop(id);
}

// ---- AO helpers -------------------------------------------------------------

// Is this block id an AO-occluder?  Air (0), water (9), and props do not occlude.
inline bool is_occluder(BlockId id) {
    return id != 0 && id != 9 && !is_prop(id);
}

// Sample a block at an arbitrary world offset from (x,y,z) in chunk cc.
// Used for AO neighbour lookups — may cross chunk boundaries.
inline BlockId sample_block(IChunk* current_chunk, ChunkCoord cc,
                            IChunkStore& store, int x, int y, int z) {
    if (x >= 0 && x < kChunkDim &&
        y >= 0 && y < kChunkDim &&
        z >= 0 && z < kChunkDim) {
        return chunk_get(current_chunk, x, y, z);
    }
    ChunkCoord nc = cc;
    int nx = x, ny = y, nz = z;
    if      (nx < 0)          { nc.x -= 1; nx += kChunkDim; }
    else if (nx >= kChunkDim) { nc.x += 1; nx -= kChunkDim; }
    if      (ny < 0)          { nc.y -= 1; ny += kChunkDim; }
    else if (ny >= kChunkDim) { nc.y += 1; ny -= kChunkDim; }
    if      (nz < 0)          { nc.z -= 1; nz += kChunkDim; }
    else if (nz >= kChunkDim) { nc.z += 1; nz -= kChunkDim; }
    IChunk* nb = store.get(nc);
    if (!nb) return 0;
    return nb->get(nx, ny, nz);
}

// Compute the AO value (0..3) for one quad corner.
//
// Parameters:
//   face_origin: the voxel whose face we are shading (in chunk-local coords)
//   face_sign  : fd.sign (+1 or -1) — which direction the face points
//   norm_axis  : fd.axis (which world axis the face normal is along)
//   u_axis     : fd.u_axis (first tangent axis)
//   v_axis     : fd.v_axis (second tangent axis)
//   du, dv     : corner offsets in tangent plane: 0 or +1 for the lo corner,
//                or -1/0 when the corner is at the hi end.
//
// The AO sample point is one step out along the normal, at the corner where
// the two tangent-plane edges meet.  We examine the 3 voxels in that plane:
//   side1 = (norm_step) + (du_step)        [edge along u]
//   side2 = (norm_step) + (dv_step)        [edge along v]
//   corner= (norm_step) + (du_step) + (dv_step)
//
// Lysenko formula: if s1 && s2 -> ao=0; else ao = 3 - s1 - s2 - corner.
inline std::uint32_t compute_ao(IChunk* chunk, ChunkCoord cc, IChunkStore& store,
                                int bx, int by, int bz,
                                int norm_axis, int face_sign,
                                int u_axis, int v_axis,
                                int du, int dv) {
    // Step one voxel out along the face normal (into the air).
    int step[3] = {0, 0, 0};
    step[norm_axis] = face_sign;

    // Tangent steps for this corner.
    int su[3] = {0, 0, 0};
    int sv[3] = {0, 0, 0};
    su[u_axis] = du;
    sv[v_axis] = dv;

    // The three AO-sample positions.
    int s1x = bx + step[0] + su[0];
    int s1y = by + step[1] + su[1];
    int s1z = bz + step[2] + su[2];

    int s2x = bx + step[0] + sv[0];
    int s2y = by + step[1] + sv[1];
    int s2z = bz + step[2] + sv[2];

    int scx = bx + step[0] + su[0] + sv[0];
    int scy = by + step[1] + su[1] + sv[1];
    int scz = bz + step[2] + su[2] + sv[2];

    bool s1 = is_occluder(sample_block(chunk, cc, store, s1x, s1y, s1z));
    bool s2 = is_occluder(sample_block(chunk, cc, store, s2x, s2y, s2z));
    bool c  = is_occluder(sample_block(chunk, cc, store, scx, scy, scz));

    if (s1 && s2) return 0u;
    return 3u - (s1 ? 1u : 0u) - (s2 ? 1u : 0u) - (c ? 1u : 0u);
}

// Compute all 4 corner AO values for a face on block (bx,by,bz).
// The 4 corners correspond to (du,dv) pairs for the quad corners c0..c3:
//   c0 = (u,   v  ) -> tangent offsets relative to the lo-u, lo-v corner
//   c1 = (u+1, v  )
//   c2 = (u+1, v+1)
//   c3 = (u,   v+1)
//
// For a face at position (u,v) in the mask, the block occupies the cell.
// The corner samples use du ∈ {-1,+1} and dv ∈ {-1,+1} because the corners
// are at the edges of the voxel face.  Specifically:
//   c0: side toward -u, -v  -> du=-1, dv=-1
//   c1: side toward +u, -v  -> du=+1, dv=-1
//   c2: side toward +u, +v  -> du=+1, dv=+1
//   c3: side toward -u, +v  -> du=-1, dv=+1
struct AOCorners { std::uint32_t a0, a1, a2, a3; };

inline AOCorners compute_face_ao(IChunk* chunk, ChunkCoord cc, IChunkStore& store,
                                 const FaceDir& fd, int bx, int by, int bz) {
    AOCorners ao;
    ao.a0 = compute_ao(chunk, cc, store, bx, by, bz,
                       fd.axis, fd.sign, fd.u_axis, fd.v_axis, -1, -1);
    ao.a1 = compute_ao(chunk, cc, store, bx, by, bz,
                       fd.axis, fd.sign, fd.u_axis, fd.v_axis, +1, -1);
    ao.a2 = compute_ao(chunk, cc, store, bx, by, bz,
                       fd.axis, fd.sign, fd.u_axis, fd.v_axis, +1, +1);
    ao.a3 = compute_ao(chunk, cc, store, bx, by, bz,
                       fd.axis, fd.sign, fd.u_axis, fd.v_axis, -1, +1);
    return ao;
}

// Pack 4 AO corner values (each 0..3, 2 bits) into 8 bits for the merge key.
inline std::uint8_t pack_ao(const AOCorners& ao) {
    return static_cast<std::uint8_t>(
        (ao.a0 & 0x3u) | ((ao.a1 & 0x3u) << 2) | ((ao.a2 & 0x3u) << 4) | ((ao.a3 & 0x3u) << 6));
}

// ---- quad emission ----------------------------------------------------------
// Emit one quad at position (d,u,v) in axis space with width w along u_axis
// and height h along v_axis.  Face points along fd.axis * fd.sign.
// Returns false if vtx_out / idx_out lacks space (caller stops and returns).
// base_vtx: current vertex count already emitted (for index offset).
// ao0..ao3: AO values for corners c0,c1,c2,c3 respectively.
bool emit_quad(const FaceDir& fd, int d, int u, int v, int w, int h,
               BlockId id, std::uint8_t sky, std::uint8_t block,
               std::uint32_t ao0, std::uint32_t ao1, std::uint32_t ao2, std::uint32_t ao3,
               std::span<std::byte>& vtx_out, std::uint32_t& vtx_written,
               std::span<std::byte>& idx_out, std::uint32_t& idx_written,
               std::uint32_t base_vtx) {

    // 4 vertices needed.
    if (vtx_out.size() - vtx_written < 4 * sizeof(BFVertex)) return false;
    if (idx_out.size()  - idx_written < 6 * sizeof(std::uint32_t)) return false;

    // The quad lives in the plane at d (along fd.axis).
    // If sign is +1 the face is at d+1 (the outward-facing surface of the block).
    // If sign is -1 the face is at d (the near surface).
    int face_d = (fd.sign > 0) ? d + 1 : d;

    // Four corners of the quad in (u,v) space (before mapping to world):
    // c0=(u,   v),   c1=(u+w, v)
    // c2=(u+w, v+h), c3=(u,   v+h)
    struct Corner { int d, u, v; };
    Corner c0{face_d, u,   v    };
    Corner c1{face_d, u+w, v    };
    Corner c2{face_d, u+w, v+h  };
    Corner c3{face_d, u,   v+h  };

    // Convert each corner to (x,y,z).
    auto to_xyz = [&](Corner c, std::uint32_t& ox, std::uint32_t& oy, std::uint32_t& oz) {
        int ix, iy, iz;
        axes_to_xyz(fd, c.d, c.u, c.v, ix, iy, iz);
        ox = static_cast<std::uint32_t>(ix);
        oy = static_cast<std::uint32_t>(iy);
        oz = static_cast<std::uint32_t>(iz);
    };

    std::uint32_t x0,y0,z0, x1,y1,z1, x2,y2,z2, x3,y3,z3;
    to_xyz(c0, x0, y0, z0);
    to_xyz(c1, x1, y1, z1);
    to_xyz(c2, x2, y2, z2);
    to_xyz(c3, x3, y3, z3);

    std::uint32_t uw = static_cast<std::uint32_t>(w);
    std::uint32_t vh = static_cast<std::uint32_t>(h);
    std::uint16_t mat = static_cast<std::uint16_t>(id);

    // Build vertices with per-corner AO.
    BFVertex verts[4] = {
        bf_make_vertex(x0,y0,z0, fd.normal, ao0, 0,  0,  mat, sky, block),
        bf_make_vertex(x1,y1,z1, fd.normal, ao1, uw, 0,  mat, sky, block),
        bf_make_vertex(x2,y2,z2, fd.normal, ao2, uw, vh, mat, sky, block),
        bf_make_vertex(x3,y3,z3, fd.normal, ao3, 0,  vh, mat, sky, block),
    };
    std::memcpy(vtx_out.data() + vtx_written, verts, 4 * sizeof(BFVertex));
    vtx_written += static_cast<std::uint32_t>(4 * sizeof(BFVertex));

    // The WINDING is what makes a face front- or back-facing. For faces whose
    // (u_axis,v_axis,outward) basis is left-handed ({-X,+Y,-Z}, fd.reverse),
    // emit the triangles in reversed order so the quad is CCW from outside.
    //
    // AO flip-quad: if the AO gradient is asymmetric (a0+a2 != a1+a3), flip
    // the diagonal so the interpolation follows the dominant gradient direction,
    // avoiding a hard seam along the wrong diagonal.
    //   Normal triangulation: tri0=(0,1,2), tri1=(0,2,3)
    //   Flipped triangulation: tri0=(0,1,3), tri1=(1,2,3)
    bool flip_diag = (ao0 + ao2) != (ao1 + ao3);

    std::uint32_t b = base_vtx;
    // Indices for normal and flipped diagonals (forward winding):
    std::uint32_t fwd_normal[6] = {b+0, b+1, b+2,  b+0, b+2, b+3};
    std::uint32_t fwd_flip[6]   = {b+0, b+1, b+3,  b+1, b+2, b+3};
    // Reversed winding variants:
    std::uint32_t rev_normal[6] = {b+0, b+2, b+1,  b+0, b+3, b+2};
    std::uint32_t rev_flip[6]   = {b+0, b+3, b+1,  b+1, b+3, b+2};

    const std::uint32_t* idx_pattern;
    if (fd.reverse) {
        idx_pattern = flip_diag ? rev_flip : rev_normal;
    } else {
        idx_pattern = flip_diag ? fwd_flip : fwd_normal;
    }
    std::memcpy(idx_out.data() + idx_written, idx_pattern, 6 * sizeof(std::uint32_t));
    idx_written += static_cast<std::uint32_t>(6 * sizeof(std::uint32_t));

    return true;
}

// ---- mask cell: combines material id, light values, and AO signature --------
// Two cells can only be greedy-merged if ALL fields match.
struct MaskCell {
    BlockId      id;
    std::uint8_t sky;
    std::uint8_t blk;
    std::uint8_t ao_packed; // pack_ao(AOCorners)

    bool operator==(const MaskCell& o) const {
        return id == o.id && sky == o.sky && blk == o.blk && ao_packed == o.ao_packed;
    }
};

// ---- cross-plant billboard emission -----------------------------------------
// Emit an X-shaped billboard for a single plant cell at (bx, by, bz).
// Two quads along the cell's two XZ diagonals, each emitted twice with opposite
// winding (4 quads total = 16 verts = 8 triangles = 48 indices), so the plant
// is visible from all directions under back-face culling.
//
// Diagonal A: XZ (0,0)-(1,1) — corners at:
//   p0 = (bx,   by,   bz  )   p1 = (bx+1, by,   bz+1)
//   p2 = (bx+1, by+1, bz+1)   p3 = (bx,   by+1, bz  )
// Diagonal B: XZ (1,0)-(0,1) — corners at:
//   p0 = (bx+1, by,   bz  )   p1 = (bx,   by,   bz+1)
//   p2 = (bx,   by+1, bz+1)   p3 = (bx+1, by+1, bz  )
//
// Each diagonal: emit winding (0,1,2),(0,2,3) then reverse (0,2,1),(0,3,2).
// UVs: U along the diagonal (0 at lo-X end, 1 at hi-X end), V along height (0=bottom,1=top).
// Normal: BF_NY_POS (used as a sentinel; the fragment shader keys off material_id).
// AO: 3 (fully unoccluded).  Light: sampled from the plant cell itself.
//
// Returns false if buffers are full (caller stops).
bool emit_cross_plant(int bx, int by, int bz,
                      BlockId id, std::uint8_t sky, std::uint8_t blk,
                      std::span<std::byte>& vtx_out, std::uint32_t& vtx_written,
                      std::span<std::byte>& idx_out, std::uint32_t& idx_written,
                      std::uint32_t& vtx_count) {
    // Need 16 verts + 48 indices (4 quads × 4 verts, 4 quads × 2 tris × 3 idx).
    if (vtx_out.size() - vtx_written < 16 * sizeof(BFVertex))        return false;
    if (idx_out.size()  - idx_written < 48 * sizeof(std::uint32_t))  return false;

    constexpr std::uint32_t AO   = 3u;
    constexpr std::uint32_t NORM = static_cast<std::uint32_t>(BF_NY_POS); // shader uses mat_id, not normal
    const std::uint16_t     mat  = static_cast<std::uint16_t>(id);

    // Integer corner coordinates (fits in 6-bit pos field, values 0..16).
    std::uint32_t x0 = static_cast<std::uint32_t>(bx);
    std::uint32_t x1 = static_cast<std::uint32_t>(bx + 1);
    std::uint32_t y0 = static_cast<std::uint32_t>(by);
    std::uint32_t y1 = static_cast<std::uint32_t>(by + 1);
    std::uint32_t z0 = static_cast<std::uint32_t>(bz);
    std::uint32_t z1 = static_cast<std::uint32_t>(bz + 1);

    // Emit a single quad + its back-face twin.
    // v0..v3: the four corners, with UVs (u0v0, u1v0, u1v1, u0v1).
    // Forward winding: (0,1,2),(0,2,3) — CCW from one side.
    // Reverse winding: (0,2,1),(0,3,2) — CCW from the other side.
    auto emit_both_faces = [&](
        std::uint32_t px0, std::uint32_t py0, std::uint32_t pz0,  // corner (U=0,V=0)
        std::uint32_t px1, std::uint32_t py1, std::uint32_t pz1,  // corner (U=1,V=0)
        std::uint32_t px2, std::uint32_t py2, std::uint32_t pz2,  // corner (U=1,V=1)
        std::uint32_t px3, std::uint32_t py3, std::uint32_t pz3   // corner (U=0,V=1)
    ) -> bool {
        BFVertex v0 = bf_make_vertex(px0,py0,pz0, NORM, AO, 0u, 0u, mat, sky, blk);
        BFVertex v1 = bf_make_vertex(px1,py1,pz1, NORM, AO, 1u, 0u, mat, sky, blk);
        BFVertex v2 = bf_make_vertex(px2,py2,pz2, NORM, AO, 1u, 1u, mat, sky, blk);
        BFVertex v3 = bf_make_vertex(px3,py3,pz3, NORM, AO, 0u, 1u, mat, sky, blk);

        // Write 4 verts for the forward quad.
        std::uint32_t b = vtx_count;
        std::memcpy(vtx_out.data() + vtx_written, &v0, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v1, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v2, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v3, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        vtx_count += 4;

        // Forward winding indices.
        std::uint32_t fwd[6] = {b+0,b+1,b+2, b+0,b+2,b+3};
        std::memcpy(idx_out.data() + idx_written, fwd, 6 * sizeof(std::uint32_t));
        idx_written += static_cast<std::uint32_t>(6 * sizeof(std::uint32_t));

        // Write 4 verts again for the reverse quad (same positions, opposite winding).
        b = vtx_count;
        std::memcpy(vtx_out.data() + vtx_written, &v0, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v1, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v2, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v3, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        vtx_count += 4;

        // Reverse winding indices.
        std::uint32_t rev[6] = {b+0,b+2,b+1, b+0,b+3,b+2};
        std::memcpy(idx_out.data() + idx_written, rev, 6 * sizeof(std::uint32_t));
        idx_written += static_cast<std::uint32_t>(6 * sizeof(std::uint32_t));

        return true;
    };

    // Diagonal A: (bx,bz)-(bx+1,bz+1).
    if (!emit_both_faces(x0,y0,z0,  x1,y0,z1,  x1,y1,z1,  x0,y1,z0)) return false;
    // Diagonal B: (bx+1,bz)-(bx,bz+1).
    if (!emit_both_faces(x1,y0,z0,  x0,y0,z1,  x0,y1,z1,  x1,y1,z0)) return false;

    return true;
}

// ---- torch emission ---------------------------------------------------------
// Emit a CLOSED, torch-shaped prop for a single torch cell (id 32) at
// (bx, by, bz).  Two stacked sub-cell boxes (issues #23, #24):
//
//   POST  : a thin wooden shaft, 4/16 wide (X/Z frac 6..10), from the cell
//           floor (Y frac 0) up to Y frac 7.  4 side faces + a bottom cap.
//   HEAD  : a wider glowing tuft, 6/16 wide (X/Z frac 5..11), from Y frac 7 up
//           to Y frac 11.  4 side faces + a top cap + a bottom cap.
//
// The head is WIDER than the post, so its full bottom cap (frac 5..11) sits at
// Y frac 7 and completely covers the post's top — no post top cap is needed and
// there is no see-through gap at the post/head junction.  Together the caps make
// the prop a closed solid from every angle: bottom (post bottom cap), top (head
// top cap), the seam at Y frac 7 (head bottom cap), and all eight side faces.
// This fixes #23 (see-through top/bottom) and #24 (it now reads as a torch: a
// narrow neutral post with a brighter, fatter glowing head).
//
//   11 quads = 44 verts + 66 indices.
//
// Sub-cell positions use bf_pack_pos(x,y,z, fx,fy,fz) where fx/fy/fz are
// sixteenths of a block (the shader adds frac/16 to the integer corner).
//
// Both boxes use material id 32 so the shader's torch coloring/emissive applies;
// the post and head therefore share the glow.  (A distinct "torch_post" material
// id would let the shader render the post as neutral/brown wood while only the
// head glows — see summary; we can't add one here without touching content.)
//
// Winding matches the cube faces (CCW from outside) with the same BFNormal
// codes.  AO = full (3); light = the torch cell's own sky/block values, like the
// cross-plant pass.
//
// Returns false if buffers are full (caller stops).
bool emit_torch(int bx, int by, int bz,
                std::uint8_t sky, std::uint8_t blk,
                std::span<std::byte>& vtx_out, std::uint32_t& vtx_written,
                std::span<std::byte>& idx_out, std::uint32_t& idx_written,
                std::uint32_t& vtx_count) {
    // 11 quads: 44 verts + 66 indices.
    if (vtx_out.size() - vtx_written < 44 * sizeof(BFVertex))       return false;
    if (idx_out.size()  - idx_written < 66 * sizeof(std::uint32_t)) return false;

    constexpr std::uint32_t AO = 3u;                  // fully unoccluded
    const std::uint16_t mat = static_cast<std::uint16_t>(32);

    // Integer block coords (each fits the 6-bit pos field).
    const std::uint32_t X = static_cast<std::uint32_t>(bx);
    const std::uint32_t Y = static_cast<std::uint32_t>(by);
    const std::uint32_t Z = static_cast<std::uint32_t>(bz);

    // Build a BFVertex directly with fractional position + packed normal/uv.
    auto vert = [&](std::uint32_t fx, std::uint32_t fy, std::uint32_t fz,
                    std::uint32_t normal, std::uint32_t u, std::uint32_t v) -> BFVertex {
        return BFVertex{
            bf_pack_pos(X, Y, Z, fx, fy, fz),
            bf_pack_normal_uv(normal, AO, u, v),
            mat, sky, blk, 0u
        };
    };

    // Emit one quad (4 verts, 6 indices) with the given corner order. Corner
    // order is chosen per-face so triangles (0,1,2),(0,2,3) are CCW from outside.
    auto quad = [&](const BFVertex& v0, const BFVertex& v1,
                    const BFVertex& v2, const BFVertex& v3) {
        std::uint32_t b = vtx_count;
        std::memcpy(vtx_out.data() + vtx_written, &v0, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v1, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v2, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        std::memcpy(vtx_out.data() + vtx_written, &v3, sizeof(BFVertex)); vtx_written += sizeof(BFVertex);
        vtx_count += 4;
        std::uint32_t idx[6] = {b+0, b+1, b+2, b+0, b+2, b+3};
        std::memcpy(idx_out.data() + idx_written, idx, 6 * sizeof(std::uint32_t));
        idx_written += static_cast<std::uint32_t>(6 * sizeof(std::uint32_t));
    };

    // Emit a closed box's 4 side faces between Y fracs [yb..yt] with the X/Z
    // square spanning [lo..hi].  Caps are emitted separately so we can skip the
    // post's top cap (covered by the head) while still capping the head.
    auto sides = [&](std::uint32_t lo, std::uint32_t hi,
                     std::uint32_t yb, std::uint32_t yt) {
        // +X face (plane at frac hi, normal +X). Start lo, walk +Y then +Z so
        // cross(e0,e1) points +X.
        quad(vert(hi, yb, lo, BF_NX_POS, 0u, 0u),
             vert(hi, yt, lo, BF_NX_POS, 0u, 1u),
             vert(hi, yt, hi, BF_NX_POS, 1u, 1u),
             vert(hi, yb, hi, BF_NX_POS, 1u, 0u));
        // -X face (plane at frac lo, normal -X). CCW from outside (-X side).
        quad(vert(lo, yb, hi, BF_NX_NEG, 0u, 0u),
             vert(lo, yt, hi, BF_NX_NEG, 0u, 1u),
             vert(lo, yt, lo, BF_NX_NEG, 1u, 1u),
             vert(lo, yb, lo, BF_NX_NEG, 1u, 0u));
        // +Z face (plane at frac hi, normal +Z). CCW from outside (+Z side).
        quad(vert(hi, yb, hi, BF_NZ_POS, 0u, 0u),
             vert(hi, yt, hi, BF_NZ_POS, 0u, 1u),
             vert(lo, yt, hi, BF_NZ_POS, 1u, 1u),
             vert(lo, yb, hi, BF_NZ_POS, 1u, 0u));
        // -Z face (plane at frac lo, normal -Z). CCW from outside (-Z side).
        quad(vert(lo, yb, lo, BF_NZ_NEG, 0u, 0u),
             vert(lo, yt, lo, BF_NZ_NEG, 0u, 1u),
             vert(hi, yt, lo, BF_NZ_NEG, 1u, 1u),
             vert(hi, yb, lo, BF_NZ_NEG, 1u, 0u));
    };

    // +Y cap at frac y over the square [lo..hi]. Outward +Y, CCW from above:
    // walk -X then +Z so cross(edge0,edge1) points +Y.
    auto top_cap = [&](std::uint32_t lo, std::uint32_t hi, std::uint32_t y) {
        quad(vert(hi, y, lo, BF_NY_POS, 0u, 0u),
             vert(lo, y, lo, BF_NY_POS, 1u, 0u),
             vert(lo, y, hi, BF_NY_POS, 1u, 1u),
             vert(hi, y, hi, BF_NY_POS, 0u, 1u));
    };
    // -Y cap at frac y over the square [lo..hi]. Outward -Y, CCW from below:
    // walk +X then +Z so cross(edge0,edge1) points -Y.
    auto bottom_cap = [&](std::uint32_t lo, std::uint32_t hi, std::uint32_t y) {
        quad(vert(lo, y, lo, BF_NY_NEG, 0u, 0u),
             vert(hi, y, lo, BF_NY_NEG, 1u, 0u),
             vert(hi, y, hi, BF_NY_NEG, 1u, 1u),
             vert(lo, y, hi, BF_NY_NEG, 0u, 1u));
    };

    // POST: narrow shaft, X/Z frac 6..10, Y frac 0..7. Sides + bottom cap.
    // (No post top cap — the wider head's bottom cap covers frac 6..10 at y=7.)
    constexpr std::uint32_t PLO = 6u,  PHI = 10u;  // post X/Z span (4/16 wide)
    constexpr std::uint32_t PBOT = 0u, PTOP = 7u;  // post Y span
    sides(PLO, PHI, PBOT, PTOP);
    bottom_cap(PLO, PHI, PBOT);

    // HEAD: wider glowing tuft, X/Z frac 5..11, Y frac 7..11. Sides + both caps.
    // Its full bottom cap (frac 5..11) closes the seam over the post at y=7.
    constexpr std::uint32_t HLO = 5u,  HHI = 11u;  // head X/Z span (6/16 wide)
    constexpr std::uint32_t HBOT = 7u, HTOP = 11u; // head Y span
    sides(HLO, HHI, HBOT, HTOP);
    bottom_cap(HLO, HHI, HBOT);
    top_cap(HLO, HHI, HTOP);

    return true;
}

} // anonymous namespace

// ============================================================================
MeshResult GreedyMesher::mesh(ChunkCoord c, IChunkStore& store,
                              std::span<std::byte> vtx_out,
                              std::span<std::byte> idx_out,
                              bool simplified) {
    // TODO(M2): handle `simplified` flag for LOD meshing (currently ignored).
    (void)simplified;

    IChunk* chunk = store.get(c);

    // Null chunk or uniform-air chunk -> empty.
    if (!chunk) {
        return MeshResult{0, 0, 0, true};
    }
    if (chunk->is_uniform() && chunk->get(0,0,0) == 0) {
        return MeshResult{0, 0, 0, true};
    }

    std::uint32_t vtx_written = 0;
    std::uint32_t idx_written = 0;
    std::uint32_t vtx_count  = 0;  // vertices (not bytes)

    // Mask arrays reused across slices and directions.
    // mask[u][v] carries material, light, and AO for each visible face cell.
    // ao_corners[u][v] keeps the unpacked AOCorners for emit_quad.
    MaskCell  mask[kChunkDim][kChunkDim];
    AOCorners ao_corners[kChunkDim][kChunkDim];

    for (const FaceDir& fd : kFaceDirs) {
        // Sweep the 16 slices along fd.axis.
        for (int d = 0; d < kChunkDim; ++d) {
            // Build visibility mask for this slice.
            for (int u = 0; u < kChunkDim; ++u) {
                for (int v = 0; v < kChunkDim; ++v) {
                    // Map (d,u,v) -> (x,y,z).
                    int x, y, z;
                    axes_to_xyz(fd, d, u, v, x, y, z);

                    BlockId here = chunk_get(chunk, x, y, z);
                    mask[u][v] = {0, 15, 0, 0};
                    if (here == 0) continue;

                    // Check the neighbour in the face direction.
                    BlockId nb = neighbour_block(chunk, c, store, fd, x, y, z);

                    // Opacity rules:
                    //   OPAQUE block (non-air, non-water): emit face when neighbour
                    //     is NON-opaque (air OR water).  This makes terrain walls
                    //     visible from inside water and water-side-walls visible.
                    //   WATER block (id 9): emit face only when neighbour is AIR.
                    //     Water-against-water and water-against-opaque do not emit
                    //     (opaque block already drew its wall; no internal faces).
                    bool emit = false;
                    if (is_opaque(here)) {
                        // Solid terrain: face visible against any non-opaque cell.
                        emit = !is_opaque(nb);      // nb is air (0) or water (9)
                    } else if (here == 9) {
                        // Water surface: only against air.
                        emit = (nb == 0);
                    }

                    if (emit) {
                        std::uint8_t sky = 15, blk = 0;
                        neighbour_light(chunk, c, store, fd, x, y, z, sky, blk);

                        // Compute per-corner AO for this face.
                        AOCorners ao = compute_face_ao(chunk, c, store, fd, x, y, z);
                        ao_corners[u][v] = ao;

                        mask[u][v] = {here, sky, blk, pack_ao(ao)};
                    }
                    // else mask stays {0,...} = no face
                }
            }

            // Greedy merge the mask.
            // Use a boolean merged[u][v] to track consumed cells.
            bool merged[kChunkDim][kChunkDim] = {};

            for (int u = 0; u < kChunkDim; ++u) {
                for (int v = 0; v < kChunkDim; ++v) {
                    MaskCell cell = mask[u][v];
                    if (cell.id == 0 || merged[u][v]) continue;

                    auto same = [&](int uu, int vv) {
                        return mask[uu][vv] == cell && !merged[uu][vv];
                    };

                    // Find max width w in +u direction (same key).
                    int w = 1;
                    while (u + w < kChunkDim && same(u + w, v)) ++w;

                    // Find max height h in +v direction while entire row matches.
                    int h = 1;
                    bool row_ok = true;
                    while (v + h < kChunkDim && row_ok) {
                        for (int k = 0; k < w; ++k) {
                            if (!same(u + k, v + h)) { row_ok = false; break; }
                        }
                        if (row_ok) ++h;
                    }

                    // Mark merged.
                    for (int ku = 0; ku < w; ++ku)
                        for (int kv = 0; kv < h; ++kv)
                            merged[u+ku][v+kv] = true;

                    // The AO corner values for this quad come from the single
                    // representative cell (u,v) — all merged cells have the
                    // same AO signature (enforced by same() above).
                    AOCorners ao = ao_corners[u][v];

                    // Emit quad; stop early if buffers full.
                    bool ok = emit_quad(fd, d, u, v, w, h, cell.id, cell.sky, cell.blk,
                                        ao.a0, ao.a1, ao.a2, ao.a3,
                                        vtx_out, vtx_written,
                                        idx_out, idx_written,
                                        vtx_count);
                    if (!ok) {
                        // Buffers exhausted — return what we have.
                        std::uint32_t ic = idx_written / static_cast<std::uint32_t>(sizeof(std::uint32_t));
                        return MeshResult{vtx_written, idx_written, ic, false};
                    }
                    vtx_count += 4;
                }
            }
        }
    }

    // ---- Prop pass ---------------------------------------------------------
    // Scan every cell; for each prop block emit its custom geometry:
    //   cross-plants (36-39) -> X-shaped billboard (emit_cross_plant)
    //   torch (32)           -> thin torch post + cap (emit_torch)
    // This is done after the greedy cube meshing so prop geometry is appended.
    for (int y = 0; y < kChunkDim; ++y) {
        for (int x = 0; x < kChunkDim; ++x) {
            for (int z = 0; z < kChunkDim; ++z) {
                BlockId here = chunk_get(chunk, x, y, z);
                if (!is_prop(here)) continue;
                if (is_subvoxel_prop(here)) continue;   // #51 drawn by the prop renderer, no mesh geometry

                // Sample light from the prop cell itself (not an adjacent air face).
                std::uint8_t sky = chunk->sky_light(x, y, z);
                std::uint8_t blk = chunk->block_light(x, y, z);

                bool ok;
                if (is_torch(here)) {
                    ok = emit_torch(x, y, z, sky, blk,
                                    vtx_out, vtx_written,
                                    idx_out, idx_written,
                                    vtx_count);
                } else {
                    ok = emit_cross_plant(x, y, z, here, sky, blk,
                                          vtx_out, vtx_written,
                                          idx_out, idx_written,
                                          vtx_count);
                }
                if (!ok) {
                    std::uint32_t ic2 = idx_written / static_cast<std::uint32_t>(sizeof(std::uint32_t));
                    return MeshResult{vtx_written, idx_written, ic2, false};
                }
            }
        }
    }

    std::uint32_t ic = idx_written / static_cast<std::uint32_t>(sizeof(std::uint32_t));
    bool is_empty = (ic == 0);
    return MeshResult{vtx_written, idx_written, ic, is_empty};
}

} // namespace bf
