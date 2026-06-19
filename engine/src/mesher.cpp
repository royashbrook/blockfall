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
//     Greedy-merge mask into maximal same-id rectangles:
//       Scan in (u,v) order; on each unmerged non-zero cell:
//         Extend width w in +u while mask[u+w][v] == same id and unmerged.
//         Extend height h in +v while entire row [u..u+w-1][v+h] matches.
//         Mark the w×h region merged (set mask to 0).
//         Emit one quad (4 BFVertex + 6 uint32 indices).
//
// Vertex positions are within-chunk corners (0..16 inclusive).
// Winding: CCW as seen from outside (consistent with Metal front-face = CCW).
// ============================================================================
#include "blockcore/mesher.hpp"
#include "blockcore/vertex.hpp"
#include <cstring>
#include <cstdio>  // only for debug; unused in final build

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

// ---- quad emission ----------------------------------------------------------
// Emit one quad at position (d,u,v) in axis space with width w along u_axis
// and height h along v_axis.  Face points along fd.axis * fd.sign.
// Returns false if vtx_out / idx_out lacks space (caller stops and returns).
// base_vtx: current vertex count already emitted (for index offset).
bool emit_quad(const FaceDir& fd, int d, int u, int v, int w, int h,
               BlockId id, std::uint8_t sky, std::uint8_t block,
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

    // Build vertices.  CCW winding as seen from the outside.
    // For +sign faces we want CCW from the +axis direction.
    // For -sign faces we reverse the u winding.
    // Positions are always c0,c1,c2,c3 (texture u/v follow the same order).
    // sky/block light come from the adjacent air cell (uniform across the quad
    // because the greedy merge splits on differing light — ADR 0004).
    BFVertex verts[4] = {
        bf_make_vertex(x0,y0,z0, fd.normal, 0, 0,  0,  mat, sky, block),
        bf_make_vertex(x1,y1,z1, fd.normal, 0, uw, 0,  mat, sky, block),
        bf_make_vertex(x2,y2,z2, fd.normal, 0, uw, vh, mat, sky, block),
        bf_make_vertex(x3,y3,z3, fd.normal, 0, 0,  vh, mat, sky, block),
    };
    std::memcpy(vtx_out.data() + vtx_written, verts, 4 * sizeof(BFVertex));
    vtx_written += static_cast<std::uint32_t>(4 * sizeof(BFVertex));

    // The WINDING is what makes a face front- or back-facing. For faces whose
    // (u_axis,v_axis,outward) basis is left-handed ({-X,+Y,-Z}, fd.reverse),
    // emit the triangles in reversed order so the quad is CCW from outside.
    std::uint32_t b = base_vtx;
    std::uint32_t fwd[6] = {b+0, b+1, b+2,  b+0, b+2, b+3};
    std::uint32_t rev[6] = {b+0, b+2, b+1,  b+0, b+3, b+2};
    std::memcpy(idx_out.data() + idx_written, fd.reverse ? rev : fwd, 6 * sizeof(std::uint32_t));
    idx_written += static_cast<std::uint32_t>(6 * sizeof(std::uint32_t));

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
    // mask[u][v] = block id of visible face (0 = none); mask_sky/mask_blk carry
    // the adjacent air cell's light so the greedy merge keeps light uniform.
    BlockId      mask[kChunkDim][kChunkDim];
    std::uint8_t mask_sky[kChunkDim][kChunkDim];
    std::uint8_t mask_blk[kChunkDim][kChunkDim];

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
                    mask_sky[u][v] = 15; mask_blk[u][v] = 0;
                    if (here == 0) {
                        mask[u][v] = 0;
                        continue;
                    }

                    // Check the neighbour in the face direction.
                    BlockId nb = neighbour_block(chunk, c, store, fd, x, y, z);
                    // Face is visible if neighbour is air.
                    if (nb == 0) {
                        mask[u][v] = here;
                        neighbour_light(chunk, c, store, fd, x, y, z, mask_sky[u][v], mask_blk[u][v]);
                    } else {
                        mask[u][v] = static_cast<BlockId>(0);
                    }
                }
            }

            // Greedy merge the mask.
            // Use a boolean merged[u][v] to track consumed cells.
            bool merged[kChunkDim][kChunkDim] = {};

            for (int u = 0; u < kChunkDim; ++u) {
                for (int v = 0; v < kChunkDim; ++v) {
                    BlockId id = mask[u][v];
                    if (id == 0 || merged[u][v]) continue;
                    std::uint8_t sky0 = mask_sky[u][v], blk0 = mask_blk[u][v];
                    auto same = [&](int uu, int vv) {
                        return mask[uu][vv] == id && !merged[uu][vv]
                            && mask_sky[uu][vv] == sky0 && mask_blk[uu][vv] == blk0;
                    };

                    // Find max width w in +u direction (same id AND same light).
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

                    // Emit quad; stop early if buffers full.
                    bool ok = emit_quad(fd, d, u, v, w, h, id, sky0, blk0,
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

    std::uint32_t ic = idx_written / static_cast<std::uint32_t>(sizeof(std::uint32_t));
    bool is_empty = (ic == 0);
    return MeshResult{vtx_written, idx_written, ic, is_empty};
}

} // namespace bf
