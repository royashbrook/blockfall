// ============================================================================
// Blockfall — frozen mesh vertex packing (engine/include/blockcore/vertex.hpp)
// Realizes the BFVertex layout from contract/formats.md §4 (16 bytes). The
// greedy mesher (Track D) writes these; the Metal renderer (Track E) declares a
// vertex descriptor matching the SAME byte/bit layout. Changing this is an ABI
// change — bump the format version in formats.md.
//
//   offset 0  uint32 pos_packed   : x[0:6] y[6:12] z[12:18]  (0..16 incl. seam)
//   offset 4  uint32 normal_uv    : normal[0:3] ao[3:5] u[5:13] v[13:21]
//   offset 8  uint16 material_id
//   offset 10 uint8  sky_light    (0..15)
//   offset 11 uint8  block_light  (0..15)
//   offset 12 uint32 _reserved
// ============================================================================
#pragma once
#include <cstdint>

namespace bf {

struct BFVertex {
    std::uint32_t pos_packed;
    std::uint32_t normal_uv;
    std::uint16_t material_id;
    std::uint8_t  sky_light;
    std::uint8_t  block_light;
    std::uint32_t reserved;
};
static_assert(sizeof(BFVertex) == 16, "BFVertex must be 16 bytes (formats.md §4)");

// Face/normal codes (also the index the renderer uses for flat shading).
enum BFNormal : std::uint32_t {
    BF_NX_POS = 0, BF_NX_NEG = 1,
    BF_NY_POS = 2, BF_NY_NEG = 3,
    BF_NZ_POS = 4, BF_NZ_NEG = 5,
};

// Position packs the integer block corner (6 bits/axis, 0..16 within a chunk) plus
// an optional 4-bit sub-cell fraction per axis (bits 18..29, value/16 of a block)
// so small props like torches can be placed off the block grid. Default frac = 0
// keeps all normal block geometry byte-identical to before.
inline std::uint32_t bf_pack_pos(std::uint32_t x, std::uint32_t y, std::uint32_t z,
                                 std::uint32_t fx = 0, std::uint32_t fy = 0, std::uint32_t fz = 0) {
    return (x & 0x3F) | ((y & 0x3F) << 6) | ((z & 0x3F) << 12)
         | ((fx & 0xF) << 18) | ((fy & 0xF) << 22) | ((fz & 0xF) << 26);
}
inline std::uint32_t bf_pack_normal_uv(std::uint32_t normal, std::uint32_t ao,
                                       std::uint32_t u, std::uint32_t v) {
    return (normal & 0x7) | ((ao & 0x3) << 3) | ((u & 0xFF) << 5) | ((v & 0xFF) << 13);
}

inline BFVertex bf_make_vertex(std::uint32_t x, std::uint32_t y, std::uint32_t z,
                               std::uint32_t normal, std::uint32_t ao,
                               std::uint32_t u, std::uint32_t v,
                               std::uint16_t material,
                               std::uint8_t sky, std::uint8_t block) {
    return BFVertex{
        bf_pack_pos(x, y, z),
        bf_pack_normal_uv(normal, ao, u, v),
        material, sky, block, 0u
    };
}

} // namespace bf
