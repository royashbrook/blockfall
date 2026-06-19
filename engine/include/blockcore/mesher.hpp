// ============================================================================
// Blockfall — Greedy voxel mesher (Track D)
// engine/include/blockcore/mesher.hpp
//
// Declares GreedyMesher, the M1 implementation of bf::IMesher.
// Algorithm: standard 0fps/Mikola Lysenko greedy meshing — for each of the
// 6 face directions, sweep 16 slices, build a visibility mask, then greedily
// merge maximal same-material rectangles into quads.
// ============================================================================
#pragma once
#include "blockcore_interfaces.hpp"

namespace bf {

class GreedyMesher final : public IMesher {
public:
    GreedyMesher() = default;
    ~GreedyMesher() override = default;

    // Mesh chunk `c` using neighbour access via `store` for seam-correct face
    // culling.  Writes BFVertex into vtx_out and uint32 indices into idx_out.
    // Returns MeshResult{0,0,0,true} for all-air chunks or null chunks.
    // Never overflows the provided spans — bounds-checked on every write.
    MeshResult mesh(ChunkCoord c, IChunkStore& store,
                    std::span<std::byte> vtx_out,
                    std::span<std::byte> idx_out,
                    bool simplified) override;

    // Worst-case byte budgets.
    //
    // A 16^3 checkerboard (worst case for face count):
    //   kChunkVol = 4096 cells, worst-case solid cells ≈ 2048
    //   each solid cell exposes at most 6 faces
    //   BUT greedy meshing never improves the worst case for isolated voxels
    //   so we bound by: kChunkVol * 6 faces * 4 verts  =  4096*6*4 = 98304 verts
    //   vertex bytes: 98304 * 16 bytes = 1 572 864  (~1.5 MiB)
    //   index  bytes: 98304 * 6 / 4   (6 indices per quad, 4 verts per quad)
    //               = 98304 * 6 / 4 * 4 bytes = 98304 * 6 bytes = 589 824  (~576 KiB)
    //   (i.e. 4096*6 quads * 6 indices * 4 bytes = 589824)
    //   Round up to power-of-two-friendly values.
    static constexpr std::uint32_t kMaxQuads        = kChunkVol * 6;  // 24576
    static constexpr std::uint32_t kMaxVertexBytes  = kMaxQuads * 4u * 16u; // 1 572 864
    static constexpr std::uint32_t kMaxIndexBytes   = kMaxQuads * 6u * 4u;  //   589 824

    std::uint32_t max_vertex_bytes() const override { return kMaxVertexBytes; }
    std::uint32_t max_index_bytes()  const override { return kMaxIndexBytes;  }
};

} // namespace bf
