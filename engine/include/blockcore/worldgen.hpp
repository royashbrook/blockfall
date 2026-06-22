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

// ---------------------------------------------------------------------------
// #17 ENGINE HOOK — where structures are, so the engine can spawn an NPC there.
// ---------------------------------------------------------------------------
// Returns true if the world column (wx, wz) is the CENTRE (anchor) of a structure
// generated with `seed`, writing the structure's surface world-y into out_y.  It
// is a cheap, pure query (no voxel scan) that reuses the exact deterministic cell
// hash the generator uses, so it always agrees with the built world.  Intended
// use: the engine probes columns (or iterates structure cells) and, on a hit,
// spawns a creature/NPC at (wx, out_y+1, wz).
//
// In addition, generate() buries a MARKER block — BEACON_BLOCK (id 34), which
// worldgen produces nowhere else — at (wx, out_y-1, wz) of every structure, so
// engines that prefer to scan voxels can detect structure centres that way too.
bool worldgen_structure_marker_at(std::int32_t wx, std::int32_t wz,
                                  std::uint64_t seed, int& out_y) noexcept;

// ---------------------------------------------------------------------------
// #39 ENGINE HOOK — NPC spawning: find the structure that CONTAINS a column.
// ---------------------------------------------------------------------------
// Returns the structure TYPE (STRUCT_* int below; 0 = none) of the structure
// cell that contains world column (wx, wz) for `seed`, writing the structure's
// anchor column into (*out_ax, *out_az) and its anchor surface Y into *out_y.
// Unlike worldgen_structure_marker_at() (which only fires when (wx,wz) IS the
// anchor), this resolves the WHOLE 64×64 cell: any column in a cell that holds a
// structure returns that structure's type + anchor, so the engine can iterate
// nearby cells (e.g. step by STRUCT_CELL_SIZE = 64) and spawn a villager/NPC at
// each anchor (ax, *out_y + 1, az).  Cells with no structure (empty land, ocean,
// submerged anchors) return 0 and leave the out-params untouched.
//
// Pure function of (wx, wz, seed) — no global state, thread-safe, deterministic;
// it reuses the exact same per-cell resolution the generator uses, so the answer
// always agrees with the built world.  Any out_* pointer may be null.
//
// STRUCT_* return value -> name table (mirrors the engine-visible codes):
//   0  STRUCT_NONE        no structure in this cell
//   1  STRUCT_CABIN       walled cabin: roof, door, windows, chimney
//   2  STRUCT_OBELISK     tapering monolith on a plinth + lamp capstone
//   3  STRUCT_CAMP        campfire + wool tents + a log fence
//   4  STRUCT_WATCHTOWER  multi-storey cobble tower w/ external stair + beacon
//   5  STRUCT_TEMPLE      ruined stone-brick shrine: columns, steps, altar, chest
//   6  STRUCT_CAIRN       stacked rock pile with a broad base silhouette
//   7  STRUCT_WELL        stone-brick well: rim, roofed canopy, bucket
//   8  STRUCT_VILLAGE     cluster of 2-3 tiny huts around a shared campfire
//   9  STRUCT_SHRINE      ring of standing stones around a lit offering altar
int worldgen_structure_near(std::int32_t wx, std::int32_t wz, std::uint64_t seed,
                            std::int32_t* out_ax, std::int32_t* out_az,
                            int* out_y) noexcept;

// Returns true if (wx, wz) lies within the footprint of any structure for `seed`.
// Exposed so the no-surface-holes probe can exempt structure columns (a roofed or
// hollow build legitimately has interior air beneath its topmost solid), exactly
// as cave-entrance columns are exempted.
bool worldgen_structure_footprint(std::int32_t wx, std::int32_t wz,
                                  std::uint64_t seed) noexcept;

} // namespace bf
