// ============================================================================
// Blockfall — Track C: deterministic procedural world generation
// (engine/include/blockcore/worldgen.hpp)
//
// TerrainGen implements bf::IWorldGen using a seeded, hash-based fractal noise
// pipeline. All randomness derives from integer coordinate hashing with the
// seed — no mutable static state, no rand()/time().
// ============================================================================
#pragma once
#include "blockcore_interfaces.hpp"

#include <cstdint>

namespace bf {

// ---------------------------------------------------------------------------
// TerrainGen — concrete IWorldGen implementation
// ---------------------------------------------------------------------------
class TerrainGen final : public IWorldGen {
public:
    TerrainGen() = default;

    void          seed(std::uint64_t s) override;
    void          generate(ChunkCoord c, IChunk& chunk) override;
    std::uint64_t content_hash(ChunkCoord c) const override;

private:
    std::uint64_t seed_{0};
};

// ---------------------------------------------------------------------------
// Worldgen query helpers (pure functions — no mutable state)
// ---------------------------------------------------------------------------

// Returns true if the world column (wx, wz) is the deliberate shaft of a
// cave entrance generated with the given seed.  Tests use this to exempt
// entrance columns from the "no surface holes" check, since those columns
// are intentionally open from the surface downward.
bool worldgen_is_cave_entrance(std::int32_t wx, std::int32_t wz,
                                std::uint64_t seed) noexcept;

} // namespace bf
