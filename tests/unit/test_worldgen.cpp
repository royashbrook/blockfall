// Track C — TerrainGen deterministic worldgen tests. Framework-free.
// Tests: determinism, seed sensitivity, no seams, non-trivial output, caves.
#include "blockcore/worldgen.hpp"
#include "blockcore/chunk.hpp"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

using namespace bf;

// ---------------------------------------------------------------------------
// 1. DETERMINISM
//    Same seed+coord -> byte-identical block-by-block and equal content_hash.
//    content_hash stable across fresh TerrainGen with same seed.
// ---------------------------------------------------------------------------
static void test_determinism() {
    constexpr std::uint64_t SEED = 0xDEADBEEFCAFEBABEull;
    constexpr ChunkCoord COORD   = {2, 0, -3};

    TerrainGen g1;
    g1.seed(SEED);
    PaletteChunk c1(COORD, 0);
    g1.generate(COORD, c1);

    TerrainGen g2;
    g2.seed(SEED);
    PaletteChunk c2(COORD, 0);
    g2.generate(COORD, c2);

    // Block-by-block identical
    int mismatches = 0;
    for (int lz = 0; lz < kChunkDim; ++lz)
        for (int ly = 0; ly < kChunkDim; ++ly)
            for (int lx = 0; lx < kChunkDim; ++lx)
                if (c1.get(lx, ly, lz) != c2.get(lx, ly, lz)) ++mismatches;
    CHECK(mismatches == 0, "determinism: two generates of same seed+coord are byte-identical");

    // content_hash consistent with generate output
    std::uint64_t h1 = g1.content_hash(COORD);
    std::uint64_t h2 = g2.content_hash(COORD);
    CHECK(h1 == h2, "determinism: content_hash equal for same seed+coord");

    // Manually compute FNV-1a over c1 to verify content_hash
    constexpr std::uint64_t FNV_OFFSET = 14695981039346656037ull;
    constexpr std::uint64_t FNV_PRIME  = 1099511628211ull;
    std::uint64_t manual = FNV_OFFSET;
    for (int lz = 0; lz < kChunkDim; ++lz)
        for (int ly = 0; ly < kChunkDim; ++ly)
            for (int lx = 0; lx < kChunkDim; ++lx) {
                BlockId b = c1.get(lx, ly, lz);
                manual ^= static_cast<std::uint64_t>(b & 0xFFu);
                manual *= FNV_PRIME;
                manual ^= static_cast<std::uint64_t>((b >> 8u) & 0xFFu);
                manual *= FNV_PRIME;
            }
    CHECK(h1 == manual, "determinism: content_hash matches manual FNV-1a over block ids");

    // Stable across new TerrainGen object (same seed)
    TerrainGen g3;
    g3.seed(SEED);
    CHECK(g3.content_hash(COORD) == h1, "determinism: content_hash stable across fresh TerrainGen");
}

// ---------------------------------------------------------------------------
// 2. SEED SENSITIVITY
//    A different seed yields a different content_hash for the same coord.
// ---------------------------------------------------------------------------
static void test_seed_sensitivity() {
    constexpr ChunkCoord COORD = {0, 0, 0};

    TerrainGen ga, gb;
    ga.seed(0x1111111111111111ull);
    gb.seed(0x2222222222222222ull);

    bool any_diff = false;
    // Check a handful of coords
    constexpr ChunkCoord coords[] = {{0,0,0},{1,0,0},{0,0,1},{-1,0,-1},{3,0,2}};
    for (auto& coord : coords) {
        if (ga.content_hash(coord) != gb.content_hash(coord)) {
            any_diff = true;
            break;
        }
    }
    (void)COORD;
    CHECK(any_diff, "seed sensitivity: different seed produces different content_hash");
}

// ---------------------------------------------------------------------------
// 3. NO SEAMS
//    Adjacent chunks share continuous terrain at their boundary.
//    For chunks (0,0,0) and (1,0,0) sharing world x=15..16 boundary:
//    The highest solid block at world x=15 (from chunk0) and at world x=16
//    (from chunk1) must differ by at most 1 for all z in the chunk.
//    (Continuity check — value noise is C1 continuous.)
// ---------------------------------------------------------------------------
static void test_no_seams() {
    constexpr std::uint64_t SEED = 0xFACEFEEDF00DC0DEull;
    TerrainGen g;
    g.seed(SEED);

    // Surface chunk (y=0 covers world y 0..15)
    // We'll check multiple y-chunks to find solid tops
    // Grab chunk (0,0,0) and (1,0,0)
    // Also grab (0,-1,0) and (1,-1,0) to cover below-surface
    PaletteChunk c0_y0({0, 0, 0}, 0);  g.generate({0, 0, 0}, c0_y0);
    PaletteChunk c0_yn({0,-1, 0}, 0);  g.generate({0,-1, 0}, c0_yn);
    PaletteChunk c1_y0({1, 0, 0}, 0);  g.generate({1, 0, 0}, c1_y0);
    PaletteChunk c1_yn({1,-1, 0}, 0);  g.generate({1,-1, 0}, c1_yn);

    // Helper: find highest solid (non-AIR, non-WATER) world-y in a column
    // across two stacked chunks (lower, upper).
    // Returns kColumnMinY-1 if not found.
    constexpr BlockId AIR   = 0;
    constexpr BlockId WATER = 9;

    auto top_solid = [&](const PaletteChunk& upper, const PaletteChunk& lower,
                         int lx, int lz) -> std::int32_t {
        // upper covers y 0..15 (chunk.y=0), lower covers y -16..-1 (chunk.y=-1)
        for (int ly = kChunkDim - 1; ly >= 0; --ly) {
            BlockId b = upper.get(lx, ly, lz);
            if (b != AIR && b != WATER) return ly;   // world y = 0*16+ly
        }
        for (int ly = kChunkDim - 1; ly >= 0; --ly) {
            BlockId b = lower.get(lx, ly, lz);
            if (b != AIR && b != WATER) return -kChunkDim + ly;  // world y = -1*16+ly
        }
        return bf::kColumnMinY - 1;
    };

    // Shared boundary: in chunk0 lx=15 is world x=15; in chunk1 lx=0 is world x=16.
    int seam_violations = 0;
    for (int lz = 0; lz < kChunkDim; ++lz) {
        std::int32_t h_left  = top_solid(c0_y0, c0_yn, 15, lz);  // world x=15
        std::int32_t h_right = top_solid(c1_y0, c1_yn,  0, lz);  // world x=16

        std::int32_t diff = h_left - h_right;
        if (diff < 0) diff = -diff;
        if (diff > 1) ++seam_violations;
    }
    CHECK(seam_violations == 0,
          "no seams: boundary columns (x=15 vs x=16) differ by at most 1 for all z");
}

// ---------------------------------------------------------------------------
// 4. NOT TRIVIAL
//    A surface chunk is not uniform and contains a mix of block types.
// ---------------------------------------------------------------------------
static void test_not_trivial() {
    constexpr std::uint64_t SEED = 0xC0FFEE00DEADC0DEull;
    TerrainGen g;
    g.seed(SEED);

    // Generate a surface chunk where terrain should be visible
    PaletteChunk ch({0, 0, 0}, 0);
    g.generate({0, 0, 0}, ch);

    CHECK(!ch.is_uniform(), "not trivial: surface chunk is not uniform");

    bool has_grass_or_sand = false;
    bool has_dirt_or_stone = false;
    bool has_air           = false;
    int air_count = 0, solid_count = 0;

    for (int lz = 0; lz < kChunkDim; ++lz)
        for (int ly = 0; ly < kChunkDim; ++ly)
            for (int lx = 0; lx < kChunkDim; ++lx) {
                BlockId b = ch.get(lx, ly, lz);
                if (b == 0)                     { ++air_count;   has_air = true; }
                else                            { ++solid_count; }
                if (b == 1 || b == 6)           has_grass_or_sand = true;
                if (b == 2 || b == 3)           has_dirt_or_stone = true;
            }

    CHECK(has_air,           "not trivial: surface chunk has AIR cells");
    CHECK(has_grass_or_sand, "not trivial: surface chunk has GRASS or SAND");
    CHECK(has_dirt_or_stone, "not trivial: surface chunk has DIRT or STONE");
    CHECK(solid_count > 0,   "not trivial: surface chunk has solid blocks");
    CHECK(air_count > 0,     "not trivial: surface chunk has air blocks");
}

// ---------------------------------------------------------------------------
// 5. CAVES EXIST
//    Across a vertical span of chunks, underground AIR cells exist from carving.
//    We sample deep chunks where surface is above and look for carved AIR.
// ---------------------------------------------------------------------------
static void test_caves_exist() {
    constexpr std::uint64_t SEED = 0xCA4EF00D5EEDull;
    TerrainGen g;
    g.seed(SEED);

    // Generate several vertical chunks at x=0,z=0 region spanning underground
    // Surface is around y=0..32, so chunk y=-1 (wy=-16..-1) should be underground
    // and carved by cave noise.
    int underground_air_total = 0;
    constexpr int NUM_CHUNKS = 6;
    constexpr ChunkCoord coords[NUM_CHUNKS] = {
        {0,-1,0}, {0,-2,0}, {0,-3,0},
        {1,-1,1}, {-1,-2,1}, {2,-1,-1}
    };

    for (int ci = 0; ci < NUM_CHUNKS; ++ci) {
        PaletteChunk ch(coords[ci], 0);
        g.generate(coords[ci], ch);
        for (int lz = 0; lz < kChunkDim; ++lz)
            for (int ly = 0; ly < kChunkDim; ++ly)
                for (int lx = 0; lx < kChunkDim; ++lx)
                    if (ch.get(lx, ly, lz) == 0 /* AIR */) ++underground_air_total;
    }

    CHECK(underground_air_total > 0,
          "caves exist: underground chunks contain AIR cells (caves carved)");
    // Expect at least ~5% air in the underground volume = 0.05 * 6 * 4096 = 1228
    CHECK(underground_air_total > 200,
          "caves exist: enough cave volume (>200 air cells in 6 underground chunks)");
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main() {
    test_determinism();
    test_seed_sensitivity();
    test_no_seams();
    test_not_trivial();
    test_caves_exist();

    if (fails == 0) {
        std::printf("OK: worldgen tests\n");
        return 0;
    }
    std::printf("%d test(s) FAILED\n", fails);
    return 1;
}
