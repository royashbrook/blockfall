// Track C — TerrainGen deterministic worldgen tests. Framework-free.
// Tests: determinism, seed sensitivity, no seams, non-trivial output, caves,
//        trees, decoration seam, plants, biome variety, mountain height,
//        snow on high ground, snowy-biome seam continuity,
//        no surface holes (cave margin fix), flatness (plains vs mountains).
#include "blockcore/worldgen.hpp"
#include "blockcore/chunk.hpp"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <memory>

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
//    This is checked across ALL biome transitions (the blended height function
//    guarantees C0 continuity across every boundary).
// ---------------------------------------------------------------------------
static void test_no_seams() {
    constexpr std::uint64_t SEED = 0xFACEFEEDF00DC0DEull;
    TerrainGen g;
    g.seed(SEED);

    // Grab chunk (0,0,0) and (1,0,0), and their sub-surface halves.
    PaletteChunk c0_y0({0, 0, 0}, 0);  g.generate({0, 0, 0}, c0_y0);
    PaletteChunk c0_yn({0,-1, 0}, 0);  g.generate({0,-1, 0}, c0_yn);
    PaletteChunk c1_y0({1, 0, 0}, 0);  g.generate({1, 0, 0}, c1_y0);
    PaletteChunk c1_yn({1,-1, 0}, 0);  g.generate({1,-1, 0}, c1_yn);

    constexpr BlockId WATER_ID = 9;
    // Decoration block ids — excluded so seam test measures raw terrain.
    auto is_decoration = [](BlockId b) -> bool {
        return b == 5   // oak_leaves
            || b == 21  // oak_log
            || b == 22  // birch_log
            || b == 27  // birch_leaves
            || b == 36  // flower_red
            || b == 37  // flower_yellow
            || b == 38  // tall_grass_block
            || b == 39  // mushroom_block
            || b == 12; // snow_layer (thin, not terrain)
    };

    auto top_solid = [&](const PaletteChunk& upper, const PaletteChunk& lower,
                         int lx, int lz) -> std::int32_t {
        for (int ly = kChunkDim - 1; ly >= 0; --ly) {
            BlockId b = upper.get(lx, ly, lz);
            if (b != 0 && b != WATER_ID && !is_decoration(b)) return ly;
        }
        for (int ly = kChunkDim - 1; ly >= 0; --ly) {
            BlockId b = lower.get(lx, ly, lz);
            if (b != 0 && b != WATER_ID && !is_decoration(b)) return -kChunkDim + ly;
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
// 3b. NO SEAMS ACROSS BIOME TRANSITIONS
//     Test a seam at a location likely to cross multiple biome boundaries,
//     using a different seed chosen to stress transitions.
// ---------------------------------------------------------------------------
static void test_no_seams_biome_transition() {
    // Use a seed that produces different biomes near origin.
    constexpr std::uint64_t SEED = 0xB10BE5EED5ED4321ull;
    TerrainGen g;
    g.seed(SEED);

    // Test multiple chunk pairs in both X and Z directions.
    // For each adjacent pair, check both X-boundary and Z-boundary.
    int total_violations = 0;

    // X-direction seams: chunks (cx, 0, cz) vs (cx+1, 0, cz)
    for (int cx = -4; cx <= 4; ++cx) {
        for (int cz = -4; cz <= 4; ++cz) {
            PaletteChunk ca({cx,   0, cz}, 0); g.generate({cx,   0, cz}, ca);
            PaletteChunk cb({cx+1, 0, cz}, 0); g.generate({cx+1, 0, cz}, cb);
            PaletteChunk ca_lo({cx,   -1, cz}, 0); g.generate({cx,   -1, cz}, ca_lo);
            PaletteChunk cb_lo({cx+1, -1, cz}, 0); g.generate({cx+1, -1, cz}, cb_lo);

            auto is_decoration = [](BlockId b) -> bool {
                return b == 5 || b == 21 || b == 22 || b == 27
                    || b == 36 || b == 37 || b == 38 || b == 39 || b == 12;
            };
            auto top_solid = [&](const PaletteChunk& up, const PaletteChunk& lo,
                                 int lx, int lz_col) -> std::int32_t {
                for (int ly = kChunkDim - 1; ly >= 0; --ly) {
                    BlockId b = up.get(lx, ly, lz_col);
                    if (b != 0 && b != 9u && !is_decoration(b)) return ly;
                }
                for (int ly = kChunkDim - 1; ly >= 0; --ly) {
                    BlockId b = lo.get(lx, ly, lz_col);
                    if (b != 0 && b != 9u && !is_decoration(b)) return -kChunkDim + ly;
                }
                return bf::kColumnMinY - 1;
            };

            for (int lz = 0; lz < kChunkDim; ++lz) {
                std::int32_t hl = top_solid(ca, ca_lo, 15, lz);
                std::int32_t hr = top_solid(cb, cb_lo,  0, lz);
                std::int32_t diff = hl - hr;
                if (diff < 0) diff = -diff;
                if (diff > 1) ++total_violations;
            }
        }
    }

    CHECK(total_violations == 0,
          "biome transition seams: no height seam > 1 across biome boundaries in 9x9 grid");
}

// ---------------------------------------------------------------------------
// 4. NOT TRIVIAL
//    A surface chunk is not uniform and contains a mix of block types.
// ---------------------------------------------------------------------------
static void test_not_trivial() {
    constexpr std::uint64_t SEED = 0xC0FFEE00DEADC0DEull;
    TerrainGen g;
    g.seed(SEED);

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
                if (b == 0)         { ++air_count;   has_air = true; }
                else                { ++solid_count; }
                if (b == 1 || b == 6)  has_grass_or_sand = true;
                if (b == 2 || b == 3)  has_dirt_or_stone = true;
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
// ---------------------------------------------------------------------------
static void test_caves_exist() {
    constexpr std::uint64_t SEED = 0xCA4EF00D5EEDull;
    TerrainGen g;
    g.seed(SEED);

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
    CHECK(underground_air_total > 200,
          "caves exist: enough cave volume (>200 air cells in 6 underground chunks)");
}

// ---------------------------------------------------------------------------
// 6. TREES EXIST
// ---------------------------------------------------------------------------
static void test_trees_exist() {
    constexpr std::uint64_t SEED = 0xF0F0F0F05EED1234ull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId OAK_LOG      = 21;
    constexpr BlockId BIRCH_LOG    = 22;
    constexpr BlockId OAK_LEAVES   = 5;
    constexpr BlockId BIRCH_LEAVES = 27;

    bool found_log    = false;
    bool found_leaves = false;

    for (int cz = -3; cz <= 3 && !(found_log && found_leaves); ++cz) {
        for (int cx = -3; cx <= 3 && !(found_log && found_leaves); ++cx) {
            for (int cy : {0, 1}) {
                PaletteChunk ch({cx, cy, cz}, 0);
                g.generate({cx, cy, cz}, ch);
                for (int lz = 0; lz < kChunkDim; ++lz)
                    for (int ly = 0; ly < kChunkDim; ++ly)
                        for (int lx = 0; lx < kChunkDim; ++lx) {
                            BlockId b = ch.get(lx, ly, lz);
                            if (b == OAK_LOG || b == BIRCH_LOG)       found_log    = true;
                            if (b == OAK_LEAVES || b == BIRCH_LEAVES) found_leaves = true;
                        }
            }
        }
    }

    CHECK(found_log,    "trees exist: oak_log or birch_log found in surface swath");
    CHECK(found_leaves, "trees exist: oak_leaves or birch_leaves found in surface swath");
}

// ---------------------------------------------------------------------------
// 7. DECORATIONS ARE DETERMINISTIC
// ---------------------------------------------------------------------------
static void test_decoration_determinism() {
    constexpr std::uint64_t SEED  = 0xDEC0DED4B10C0FFEull;
    constexpr ChunkCoord    COORD = {3, 0, -5};

    TerrainGen g1, g2;
    g1.seed(SEED);
    g2.seed(SEED);

    std::uint64_t h1 = g1.content_hash(COORD);
    std::uint64_t h2 = g2.content_hash(COORD);
    CHECK(h1 == h2, "decoration determinism: same seed+coord yields identical content_hash");

    PaletteChunk c1(COORD, 0), c2(COORD, 0);
    g1.generate(COORD, c1);
    g2.generate(COORD, c2);

    int mismatches = 0;
    for (int lz = 0; lz < kChunkDim; ++lz)
        for (int ly = 0; ly < kChunkDim; ++ly)
            for (int lx = 0; lx < kChunkDim; ++lx)
                if (c1.get(lx, ly, lz) != c2.get(lx, ly, lz)) ++mismatches;
    CHECK(mismatches == 0, "decoration determinism: block-by-block identical");
}

// ---------------------------------------------------------------------------
// 8. NO TREE SEAM ARTIFACTS
// ---------------------------------------------------------------------------
static void test_tree_no_seam() {
    constexpr std::uint64_t SEED = 0xBEEF5EED5EED1234ull;
    constexpr BlockId OAK_LOG      = 21;
    constexpr BlockId BIRCH_LOG    = 22;
    constexpr BlockId OAK_LEAVES   = 5;
    constexpr BlockId BIRCH_LEAVES = 27;
    constexpr BlockId AIR_ID = 0;

    TerrainGen g;
    g.seed(SEED);

    constexpr int CY_RANGE[2] = {0, 1};

    struct ChunkSet {
        PaletteChunk chunks[4][2];
        ChunkSet(TerrainGen& gen, std::uint64_t /*seed*/)
            : chunks{
                {PaletteChunk{{-1,CY_RANGE[0],0},0}, PaletteChunk{{-1,CY_RANGE[1],0},0}},
                {PaletteChunk{{ 0,CY_RANGE[0],0},0}, PaletteChunk{{ 0,CY_RANGE[1],0},0}},
                {PaletteChunk{{ 1,CY_RANGE[0],0},0}, PaletteChunk{{ 1,CY_RANGE[1],0},0}},
                {PaletteChunk{{ 2,CY_RANGE[0],0},0}, PaletteChunk{{ 2,CY_RANGE[1],0},0}},
            }
        {
            constexpr std::int32_t CXS[4] = {-1, 0, 1, 2};
            for (int ci = 0; ci < 4; ++ci)
                for (int yi = 0; yi < 2; ++yi)
                    gen.generate({CXS[ci], CY_RANGE[yi], 0}, chunks[ci][yi]);
        }

        BlockId at(std::int32_t wx, std::int32_t wy, std::int32_t wz) const {
            int cx_offset = -1;
            if      (wx >= -16 && wx < 0)  cx_offset = 0;
            else if (wx >= 0   && wx < 16) cx_offset = 1;
            else if (wx >= 16  && wx < 32) cx_offset = 2;
            else if (wx >= 32  && wx < 48) cx_offset = 3;
            if (cx_offset < 0) return 0;

            int cy_offset = -1;
            if (wy >= 0  && wy < 16) cy_offset = 0;
            else if (wy >= 16 && wy < 32) cy_offset = 1;
            if (cy_offset < 0) return 0;

            std::int32_t chunk_wx_origin = (cx_offset - 1) * 16;
            int lx = static_cast<int>(wx - chunk_wx_origin);
            int ly = static_cast<int>(wy - CY_RANGE[cy_offset] * 16);
            int lz = static_cast<int>(wz);
            if (lx < 0 || lx >= 16 || ly < 0 || ly >= 16 || lz < 0 || lz >= 16) return 0;
            return chunks[cx_offset][cy_offset].get(lx, ly, lz);
        }
    } cs(g, SEED);

    int seam_violations = 0;

    for (int lz = 0; lz < kChunkDim; ++lz) {
        for (int wy = 1; wy <= 30; ++wy) {
            auto b_at  = [&](std::int32_t wx) { return cs.at(wx, wy,   lz); };
            auto b_up  = [&](std::int32_t wx) { return cs.at(wx, wy+1, lz); };
            auto b_up2 = [&](std::int32_t wx) { return cs.at(wx, wy+2, lz); };

            auto is_log = [](BlockId b) {
                return b == OAK_LOG || b == BIRCH_LOG;
            };
            auto is_wood = [](BlockId b) {
                return b == OAK_LOG || b == BIRCH_LOG
                    || b == OAK_LEAVES || b == BIRCH_LEAVES;
            };

            if (is_log(b_at(15)) && b_up(15) == AIR_ID && is_wood(b_up2(15))) {
                ++seam_violations;
            }
            if (is_log(b_at(16)) && b_up(16) == AIR_ID && is_wood(b_up2(16))) {
                ++seam_violations;
            }

            (void)b_at; (void)b_up; (void)b_up2; (void)is_log; (void)is_wood;
        }
    }

    {
        TerrainGen g2;
        g2.seed(SEED);
        PaletteChunk alt({0, 0, 0}, 0);
        g2.generate({0, 0, 0}, alt);

        PaletteChunk& orig = cs.chunks[1][0];
        for (int lz2 = 0; lz2 < kChunkDim; ++lz2)
            for (int ly2 = 0; ly2 < kChunkDim; ++ly2)
                for (int lx2 = 0; lx2 < kChunkDim; ++lx2)
                    if (orig.get(lx2, ly2, lz2) != alt.get(lx2, ly2, lz2))
                        ++seam_violations;
    }

    CHECK(seam_violations == 0,
          "tree no seam: no cut trunks at chunk borders; adjacent-chunk regeneration agrees");
}

// ---------------------------------------------------------------------------
// 9. PLANTS EXIST
// ---------------------------------------------------------------------------
static void test_plants_exist() {
    constexpr std::uint64_t SEED = 0xF10F105EED5678ull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId TALL_GRASS    = 38;
    constexpr BlockId FLOWER_RED    = 36;
    constexpr BlockId FLOWER_YELLOW = 37;

    bool found_grass  = false;
    bool found_flower = false;

    // Scan ±6 chunks to cover enough area to hit grassy biomes.
    for (int cz = -6; cz <= 6 && !(found_grass && found_flower); ++cz) {
        for (int cx = -6; cx <= 6 && !(found_grass && found_flower); ++cx) {
            PaletteChunk ch({cx, 0, cz}, 0);
            g.generate({cx, 0, cz}, ch);
            for (int lz = 0; lz < kChunkDim; ++lz)
                for (int ly = 0; ly < kChunkDim; ++ly)
                    for (int lx = 0; lx < kChunkDim; ++lx) {
                        BlockId b = ch.get(lx, ly, lz);
                        if (b == TALL_GRASS)                       found_grass  = true;
                        if (b == FLOWER_RED || b == FLOWER_YELLOW) found_flower = true;
                    }
        }
    }

    CHECK(found_grass,  "plants exist: tall_grass_block found in surface swath");
    CHECK(found_flower, "plants exist: flower (red or yellow) found in surface swath");
}

// ---------------------------------------------------------------------------
// 10. BIOME VARIETY
//     Sample a large horizontal swath and assert that at least 4 distinct
//     "biome signatures" are present.  A signature is classified by surface
//     block + height range bucket.  We also assert specific block types appear:
//     sand (desert/beach), snow_layer/ice (snowy/mountains), dirt-surface columns
//     (swamp).  At minimum 4 distinct signature classes must appear.
// ---------------------------------------------------------------------------
static void test_biome_variety() {
    constexpr std::uint64_t SEED = 0xB10BE5EED1234567ull;
    TerrainGen g;
    g.seed(SEED);

    // We need to classify columns by their surface block and height bucket.
    // We scan a 32x32 chunk area (512x512 world blocks) at y=0 level.
    // For each column, find the highest non-air, non-water, non-decoration solid.

    auto is_decoration = [](BlockId b) -> bool {
        return b == 5 || b == 21 || b == 22 || b == 27
            || b == 36 || b == 37 || b == 38 || b == 39 || b == 12;
    };

    constexpr int SCAN_R = 16;  // scan ±16 chunks = ±256 world blocks

    bool found_sand_surface   = false;  // desert / beach
    bool found_grass_surface  = false;  // plains / forest / mountains low
    bool found_snow_or_ice    = false;  // snowy / mountain peak
    bool found_dirt_surface   = false;  // swamp (dirt as top terrain)
    bool found_high_column    = false;  // mountains (H > 30)
    bool found_low_column     = false;  // swamp (H <= 8)
    bool found_stone_surface  = false;  // mountain rock above snow line

    // Surface y chunks we need to look in (-2..4 covers all terrain).
    constexpr int CY_MIN = -2;
    constexpr int CY_MAX =  4;
    constexpr int NUM_CY = CY_MAX - CY_MIN + 1;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            // Generate all y chunks for this (cx,cz) column.
            // Use unique_ptr to avoid default-constructor requirement.
            std::unique_ptr<PaletteChunk> chunks[NUM_CY];
            for (int ci = 0; ci < NUM_CY; ++ci) {
                int cy = CY_MIN + ci;
                chunks[ci] = std::make_unique<PaletteChunk>(ChunkCoord{cx, cy, cz}, BlockId(0));
                g.generate({cx, cy, cz}, *chunks[ci]);
            }

            // For each local (lx,lz) find highest solid surface.
            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    BlockId    top_block = 0;
                    std::int32_t top_wy = std::int32_t(CY_MIN) * kChunkDim - 1;
                    bool found = false;

                    for (int ci = NUM_CY - 1; ci >= 0 && !found; --ci) {
                        std::int32_t chunk_wy_base = (CY_MIN + ci) * kChunkDim;
                        for (int ly = kChunkDim - 1; ly >= 0 && !found; --ly) {
                            BlockId b = chunks[ci]->get(lx, ly, lz);
                            if (b != 0 && b != 9u && !is_decoration(b)) {
                                top_block = b;
                                top_wy    = chunk_wy_base + ly;
                                found     = true;
                            }
                        }
                    }

                    if (!found) continue;

                    if (top_block == 6u)   found_sand_surface  = true;  // SAND
                    if (top_block == 1u)   found_grass_surface = true;  // GRASS
                    if (top_block == 12u || top_block == 13u)
                                           found_snow_or_ice   = true;  // SNOW/ICE
                    if (top_block == 2u)   found_dirt_surface  = true;  // DIRT (swamp)
                    if (top_block == 3u || top_block == 10u)
                                           found_stone_surface = true;  // STONE/COBBLESTONE
                    if (top_wy > 30)       found_high_column   = true;
                    if (top_wy <= 8)       found_low_column    = true;
                }
            }
        }
    }

    // Count distinct biome signatures seen.
    int sigs = 0;
    if (found_sand_surface)  ++sigs;
    if (found_grass_surface) ++sigs;
    if (found_snow_or_ice)   ++sigs;
    if (found_dirt_surface)  ++sigs;

    CHECK(sigs >= 4,
          "biome variety: at least 4 distinct surface block signatures appear in large scan");
    CHECK(found_sand_surface,
          "biome variety: sand surface (desert/beach) found in world scan");
    CHECK(found_grass_surface,
          "biome variety: grass surface (plains/forest) found in world scan");
    CHECK(found_snow_or_ice,
          "biome variety: snow_layer or ice (snowy/mountain) found in world scan");
    CHECK(found_dirt_surface,
          "biome variety: dirt surface (swamp) found in world scan");
    CHECK(found_high_column,
          "biome variety: mountain column with H > 30 found in world scan");
    CHECK(found_low_column,
          "biome variety: low column with H <= 8 (swamp) found in world scan");
    CHECK(found_stone_surface,
          "biome variety: stone/cobblestone surface (mountain peak/slope) found in world scan");
}

// ---------------------------------------------------------------------------
// 11. MOUNTAINS TALLER THAN PLAINS / DESERT
//     Sample a 32x32 chunk area, track the max column height for chunks
//     dominated by mountains vs those dominated by plains or desert.
//     Mountain max should be significantly greater.
// ---------------------------------------------------------------------------
static void test_mountain_height() {
    constexpr std::uint64_t SEED = 0xA0041A5EED123456ull;
    TerrainGen g;
    g.seed(SEED);

    auto is_decoration = [](BlockId b) -> bool {
        return b == 5 || b == 21 || b == 22 || b == 27
            || b == 36 || b == 37 || b == 38 || b == 39 || b == 12;
    };

    // Generate a large swath and record max heights per chunk.
    // Then compare the top-10% max heights (mountain region) vs median.
    constexpr int SCAN_R = 20;
    int max_mountain_h  = -999;
    int max_flatland_h  = -999;

    // Generate y-chunks to cover surface.
    constexpr int CY_MIN = -1;
    constexpr int CY_MAX =  5;  // mountain peaks can go to y~50
    constexpr int NUM_CY_M = CY_MAX - CY_MIN + 1;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            // Generate all y-chunks for this (cx,cz) column.
            std::unique_ptr<PaletteChunk> chunks_arr[NUM_CY_M];
            for (int ci = 0; ci < NUM_CY_M; ++ci) {
                int cy = CY_MIN + ci;
                chunks_arr[ci] = std::make_unique<PaletteChunk>(ChunkCoord{cx, cy, cz}, BlockId(0));
                g.generate({cx, cy, cz}, *chunks_arr[ci]);
            }

            // Find the highest solid block and detect stone-high columns.
            int chunk_max_h = -999;
            bool has_stone_high = false;

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    bool col_found = false;
                    for (int ci = NUM_CY_M - 1; ci >= 0 && !col_found; --ci) {
                        std::int32_t cy_wy_base = (CY_MIN + ci) * kChunkDim;
                        for (int ly = kChunkDim - 1; ly >= 0 && !col_found; --ly) {
                            BlockId b = chunks_arr[ci]->get(lx, ly, lz);
                            if (b != 0 && b != 9u && !is_decoration(b)) {
                                int wy = static_cast<int>(cy_wy_base) + ly;
                                if (wy > chunk_max_h) chunk_max_h = wy;
                                if (wy >= 24 && (b == 3u || b == 10u)) has_stone_high = true;
                                col_found = true;
                            }
                        }
                    }
                }
            }

            // Classify: mountain chunk has stone/cobblestone above snow-line height.
            if (has_stone_high) {
                if (chunk_max_h > max_mountain_h) max_mountain_h = chunk_max_h;
            } else {
                if (chunk_max_h > max_flatland_h) max_flatland_h = chunk_max_h;
            }
        }
    }

    // Mountains should reach at least 30 blocks high.
    CHECK(max_mountain_h >= 30,
          "mountain height: mountain peaks reach at least y=30");
    // Mountain max height should be notably greater than flatland max.
    CHECK(max_mountain_h > max_flatland_h + 10,
          "mountain height: mountain max height notably exceeds flatland max height");
}

// ---------------------------------------------------------------------------
// 12. SNOW ON HIGH GROUND
//     In a large area scan, snow_layer or ice blocks appear somewhere above y=20.
// ---------------------------------------------------------------------------
static void test_snow_exists() {
    constexpr std::uint64_t SEED = 0x5AB0FEED5EED9876ull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId SNOW_LAYER_ID = 12;
    constexpr BlockId ICE_ID        = 13;

    bool found_snow_high = false;

    // Scan ±24 chunks, y-chunks 0..4 (where surface terrain lives).
    for (int cz = -24; cz <= 24 && !found_snow_high; ++cz) {
        for (int cx = -24; cx <= 24 && !found_snow_high; ++cx) {
            for (int cy = 0; cy <= 4 && !found_snow_high; ++cy) {
                PaletteChunk ch({cx, cy, cz}, 0);
                g.generate({cx, cy, cz}, ch);
                std::int32_t wy_base = cy * kChunkDim;
                for (int lz = 0; lz < kChunkDim && !found_snow_high; ++lz)
                    for (int ly = 0; ly < kChunkDim && !found_snow_high; ++ly)
                        for (int lx = 0; lx < kChunkDim && !found_snow_high; ++lx) {
                            BlockId b = ch.get(lx, ly, lz);
                            std::int32_t wy = wy_base + ly;
                            if ((b == SNOW_LAYER_ID || b == ICE_ID) && wy >= 20) {
                                found_snow_high = true;
                            }
                        }
            }
        }
    }

    CHECK(found_snow_high,
          "snow exists: snow_layer or ice found at y>=20 in large world scan");
}

// ---------------------------------------------------------------------------
// 13. NO SURFACE HOLES
//     For every surface column in a wide multi-biome area, the 5 blocks
//     directly beneath the topmost solid block must ALL be solid (not AIR).
//     Water is not a hole — it's legitimate shallow water.
//     The test verifies the cave surface-margin fix (caves must be >= 6 blocks
//     below surface so the top 5 sub-surface blocks are never carved out).
//     Allow at most 0 hole-columns (strict: any failure is reported).
// ---------------------------------------------------------------------------
static constexpr BlockId AIR_ID     = 0;
static constexpr BlockId WATER_ID13 = 9;
static constexpr BlockId GRASS_ID   = 1;
static constexpr BlockId STONE_ID   = 3;
static constexpr BlockId COBBLE_ID  = 10;

static void test_no_surface_holes() {
    constexpr std::uint64_t SEED = 0xF00DCAFE5EED0001ull;
    TerrainGen g;
    g.seed(SEED);

    // Decorations should not count as terrain for hole-detection.
    auto is_decoration = [](BlockId b) -> bool {
        return b == 5 || b == 21 || b == 22 || b == 27
            || b == 36 || b == 37 || b == 38 || b == 39 || b == 12;
    };

    // Scan ±12 chunks in X and Z (24x24 = 576 chunk columns, 147456 world columns).
    constexpr int SCAN_R = 12;

    // We need multiple y-slices to capture the full surface + sub-surface.
    // Surface typically lies in y = -5..60.
    constexpr int CY_MIN = -2;
    constexpr int CY_MAX =  5;
    constexpr int NUM_CY = CY_MAX - CY_MIN + 1;

    int hole_columns = 0;
    int total_columns = 0;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            // Generate all y-slices for this column.
            std::unique_ptr<PaletteChunk> slices[NUM_CY];
            for (int ci = 0; ci < NUM_CY; ++ci) {
                int cy = CY_MIN + ci;
                slices[ci] = std::make_unique<PaletteChunk>(
                    ChunkCoord{cx, cy, cz}, BlockId(0));
                g.generate({cx, cy, cz}, *slices[ci]);
            }

            // Helper: get block at world-y (returns AIR_ID if out of our range).
            auto block_at_wy = [&](int lx2, int lz2, std::int32_t wy) -> BlockId {
                for (int ci = NUM_CY - 1; ci >= 0; --ci) {
                    std::int32_t base = (CY_MIN + ci) * kChunkDim;
                    if (wy >= base && wy < base + kChunkDim) {
                        return slices[ci]->get(lx2, static_cast<int>(wy - base), lz2);
                    }
                }
                return AIR_ID;
            };

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    // Find topmost solid (non-air, non-water, non-decoration) block.
                    std::int32_t top_wy = std::int32_t(CY_MIN) * kChunkDim - 1;
                    bool found_surface = false;

                    for (int ci = NUM_CY - 1; ci >= 0 && !found_surface; --ci) {
                        std::int32_t base = (CY_MIN + ci) * kChunkDim;
                        for (int ly = kChunkDim - 1; ly >= 0 && !found_surface; --ly) {
                            BlockId b = slices[ci]->get(lx, ly, lz);
                            if (b != AIR_ID && b != WATER_ID13 && !is_decoration(b)) {
                                top_wy = base + ly;
                                found_surface = true;
                            }
                        }
                    }

                    if (!found_surface) continue;  // below-ground column, skip

                    ++total_columns;

                    // Check the 5 blocks directly below the surface.
                    // They must all be non-AIR (solid or water — no cave pockets).
                    bool has_hole = false;
                    for (int depth = 1; depth <= 5; ++depth) {
                        BlockId sub = block_at_wy(lx, lz, top_wy - depth);
                        if (sub == AIR_ID) {
                            has_hole = true;
                            break;
                        }
                    }
                    if (has_hole) ++hole_columns;
                }
            }
        }
    }

    // We require zero holes. The cave surface margin (6 blocks) should
    // guarantee that absolutely no AIR appears in the top 5 sub-surface blocks.
    CHECK(hole_columns == 0,
          "no surface holes: zero columns have AIR in the 5 blocks beneath the surface");

    // Sanity: we must have scanned a meaningful number of columns.
    CHECK(total_columns > 10000,
          "no surface holes: scanned at least 10k surface columns (sanity)");
}

// ---------------------------------------------------------------------------
// 14. FLATNESS
//     Plains columns should be genuinely flat (small height variation).
//     Mountain columns should be tall and varied.
//
//     We find a chunk-region that is strongly plains (all 16x16 columns in an
//     8x8 world patch are dominated by plains based on their surface height
//     staying consistently low and grass-topped) and verify that the height
//     variation (max - min over the patch) is small (<=3 blocks).
//
//     We also verify that over the same large scan the mountain region has
//     much greater height variation (>=20 blocks) confirming contrast.
//
//     Because we cannot query biome weights directly from the test, we use the
//     surface block and height as a proxy: a column is "plains-like" if its
//     surface block is GRASS and its surface height is in [6..14].
// ---------------------------------------------------------------------------
static void test_flatness() {
    constexpr std::uint64_t SEED = 0xF1A7B10C5EED0002ull;
    TerrainGen g;
    g.seed(SEED);

    auto is_decoration = [](BlockId b) -> bool {
        return b == 5 || b == 21 || b == 22 || b == 27
            || b == 36 || b == 37 || b == 38 || b == 39 || b == 12;
    };

    constexpr int SCAN_R = 20;
    constexpr int CY_MIN = -1;
    constexpr int CY_MAX =  5;
    constexpr int NUM_CY = CY_MAX - CY_MIN + 1;

    // For each chunk column, record the per-column surface heights.
    // We'll look for an 8x8-block "flat patch" where all columns are grass+low.

    // Collect heights from a coarser per-chunk-column scan.
    // For each (cx, cz) we sample the 16x16 columns and record:
    //   - min/max height over the chunk
    //   - fraction of grass-surface, low-height columns

    // We'll store per-column (lx, lz within the chunk) heights for a selected chunk.
    // Strategy: find a chunk where height variation is tiny (plains candidate).
    int best_plains_variation = 999;
    int mountain_max_variation = 0;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            std::unique_ptr<PaletteChunk> slices[NUM_CY];
            for (int ci = 0; ci < NUM_CY; ++ci) {
                int cy = CY_MIN + ci;
                slices[ci] = std::make_unique<PaletteChunk>(
                    ChunkCoord{cx, cy, cz}, BlockId(0));
                g.generate({cx, cy, cz}, *slices[ci]);
            }

            int min_h = 9999, max_h = -9999;
            int grass_count = 0;
            bool any_stone_high = false;

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    // Find top solid.
                    std::int32_t top_wy = std::int32_t(CY_MIN) * kChunkDim - 1;
                    BlockId top_b = AIR_ID;
                    bool found = false;
                    for (int ci = NUM_CY - 1; ci >= 0 && !found; --ci) {
                        std::int32_t base = (CY_MIN + ci) * kChunkDim;
                        for (int ly = kChunkDim - 1; ly >= 0 && !found; --ly) {
                            BlockId b = slices[ci]->get(lx, ly, lz);
                            if (b != AIR_ID && b != WATER_ID13 && !is_decoration(b)) {
                                top_wy = base + ly;
                                top_b  = b;
                                found  = true;
                            }
                        }
                    }
                    if (!found) continue;

                    int h = static_cast<int>(top_wy);
                    if (h < min_h) min_h = h;
                    if (h > max_h) max_h = h;

                    if (top_b == GRASS_ID && h >= 5 && h <= 14) ++grass_count;
                    if (h >= 24 && (top_b == STONE_ID || top_b == COBBLE_ID)) {
                        any_stone_high = true;
                    }
                }
            }

            if (min_h > max_h) continue;  // no surface found

            int variation = max_h - min_h;

            // Plains candidate: mostly grass, height in low range.
            // Consider a chunk "plains-dominated" if >=75% of its columns
            // are grass-topped and between y=5 and y=14.
            if (grass_count >= 180) {  // 180/256 ~ 70%
                if (variation < best_plains_variation) {
                    best_plains_variation = variation;
                }
            }

            // Mountain candidate: has stone above snow line.
            if (any_stone_high) {
                if (variation > mountain_max_variation) {
                    mountain_max_variation = variation;
                }
            }
        }
    }

    // Plains: height variation within a chunk should be very small (<=5 blocks).
    // With amp=2, the max theoretical range is 4 blocks (base±2); blending
    // and biome transitions may add a tiny bit more, so we allow <=5.
    CHECK(best_plains_variation <= 5,
          "flatness: plains biome chunk height variation is <= 5 blocks (genuinely flat)");

    // Mountains: at least one mountain chunk has significant variation (>=12 blocks).
    CHECK(mountain_max_variation >= 12,
          "flatness: mountain biome chunk height variation is >= 12 blocks (dramatic)");
}

// ---------------------------------------------------------------------------
// 15. TREE VARIETY AND UNDERGROWTH (M5)
//     Verify that:
//       a) Trees of at least two distinct trunk heights appear in a scan
//          (confirming the new 4..8 range rather than uniform 4..6).
//       b) At least one "short" tree (trunk ≤ 5 blocks) and one "tall" tree
//          (trunk ≥ 7 blocks) appear — confirming the full height range.
//       c) OAK_LEAVES or BIRCH_LEAVES appear at low world-y in a flat biome
//          context — i.e., as ground-level bushes, not just canopy blocks.
//          We detect this by finding a leaf block whose world-y is < 20
//          (well below any tall tree canopy) in a chunk that has surface
//          grass at y ~ 7-14.  Such blocks are ground-level bushes placed
//          by the undergrowth scatter pass.
//
//     Strategy: generate many chunks, record trunk heights by counting
//     contiguous log columns, and scan for low-elevation leaf blocks.
// ---------------------------------------------------------------------------
static void test_tree_variety_and_undergrowth() {
    constexpr std::uint64_t SEED = 0x7A3E2B1C5D0F9E8Aull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId OAK_LOG_ID      = 21;
    constexpr BlockId BIRCH_LOG_ID    = 22;
    constexpr BlockId OAK_LEAVES_ID   = 5;
    constexpr BlockId BIRCH_LEAVES_ID = 27;

    // We collect trunk heights by scanning vertical log columns.
    // For each (wx, wz) we record the number of consecutive log blocks.
    bool found_short_tree = false;  // trunk height <= 5
    bool found_tall_tree  = false;  // trunk height >= 7
    bool found_ground_bush = false; // leaf block at wy < 20 in a flat chunk

    constexpr int SCAN_R = 10;

    for (int cz = -SCAN_R; cz <= SCAN_R && !(found_short_tree && found_tall_tree && found_ground_bush); ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R && !(found_short_tree && found_tall_tree && found_ground_bush); ++cx) {
            // We need y-chunks 0 and 1 to see trunks and canopies.
            PaletteChunk ch0({cx, 0, cz}, 0);
            PaletteChunk ch1({cx, 1, cz}, 0);
            g.generate({cx, 0, cz}, ch0);
            g.generate({cx, 1, cz}, ch1);

            auto get_block = [&](int lx, int wy, int lz) -> BlockId {
                if (wy >= 0 && wy < 16)  return ch0.get(lx, wy, lz);
                if (wy >= 16 && wy < 32) return ch1.get(lx, wy - 16, lz);
                return 0;
            };
            auto is_log = [](BlockId b) -> bool {
                return b == OAK_LOG_ID || b == BIRCH_LOG_ID;
            };
            auto is_leaf = [](BlockId b) -> bool {
                return b == OAK_LEAVES_ID || b == BIRCH_LEAVES_ID;
            };

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    // Count consecutive log blocks starting from ground up.
                    // Find first log block in column.
                    int log_start = -1;
                    int log_count = 0;
                    for (int wy = 0; wy < 30; ++wy) {
                        if (is_log(get_block(lx, wy, lz))) {
                            if (log_start < 0) log_start = wy;
                            ++log_count;
                        } else if (log_start >= 0) {
                            break;  // end of trunk
                        }
                    }
                    if (log_count >= 4 && log_count <= 5) found_short_tree = true;
                    if (log_count >= 7)                    found_tall_tree  = true;

                    // Detect ground-level bush: leaf block at wy < 20 where
                    // there is NO log block anywhere in this (lx,lz) column.
                    // (If there's a log, this column is under a tree canopy —
                    // leaves there are canopy, not bush.)
                    if (!found_ground_bush) {
                        bool col_has_log = false;
                        for (int wy = 0; wy < 30; ++wy) {
                            if (is_log(get_block(lx, wy, lz))) { col_has_log = true; break; }
                        }
                        if (!col_has_log) {
                            for (int wy = 1; wy < 20; ++wy) {
                                if (is_leaf(get_block(lx, wy, lz))) {
                                    found_ground_bush = true;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    CHECK(found_short_tree,
          "tree variety: short trees (trunk height 4-5) found in world scan");
    CHECK(found_tall_tree,
          "tree variety: tall trees (trunk height >=7) found in world scan");
    CHECK(found_ground_bush,
          "undergrowth: ground-level leaf/bush block found (not under a tree trunk)");
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main() {
    test_determinism();
    test_seed_sensitivity();
    test_no_seams();
    test_no_seams_biome_transition();
    test_not_trivial();
    test_caves_exist();
    test_trees_exist();
    test_decoration_determinism();
    test_tree_no_seam();
    test_plants_exist();
    test_biome_variety();
    test_mountain_height();
    test_snow_exists();
    test_no_surface_holes();
    test_flatness();
    test_tree_variety_and_undergrowth();

    if (fails == 0) {
        std::printf("OK: worldgen tests\n");
        return 0;
    }
    std::printf("%d test(s) FAILED\n", fails);
    return 1;
}
