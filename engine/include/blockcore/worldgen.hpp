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

// Returns the dominant biome index [0,6] at world column (wx, wz) for the given
// seed.  Exposed for diagnostic probes (e.g. measuring average biome run length
// across a transect).  Order matches the internal Biome enum:
//   0=Plains 1=Forest 2=Mountains 3=Desert 4=Snowy 5=Swamp 6=Beach
int worldgen_dominant_biome(std::int32_t wx, std::int32_t wz,
                            std::uint64_t seed) noexcept;

// Returns the blended surface height at world column (wx, wz) for the given
// seed.  Pure function of (wx, wz, seed) — exposed so a seam-equality probe can
// confirm adjacent chunks agree on shared boundary columns.
int worldgen_surface_height(std::int32_t wx, std::int32_t wz,
                            std::uint64_t seed) noexcept;

// Counts how many world structures (huts/pillars/campfires/watchtowers/treasure/
// cairns) are present in the square block region [wx0, wx0+span) × [wz0, wz0+span)
// for the given seed.  Pure function of its inputs — exposed so tests/benchmarks
// can assert structure density without scanning generated voxels.  Used to verify
// issue #17 (structure spawn gate raised again to ~50% of 64×64 cells after a
// second playtest found none — a couple are now findable within ~120 blocks of
// any spawn).
int worldgen_count_structures(std::int32_t wx0, std::int32_t wz0,
                              std::int32_t span, std::uint64_t seed) noexcept;

} // namespace bf
