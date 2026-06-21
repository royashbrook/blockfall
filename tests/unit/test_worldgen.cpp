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

    auto is_decoration = [](BlockId b) -> bool {
        return b == 5 || b == 21 || b == 22 || b == 27
            || b == 36 || b == 37 || b == 38 || b == 39 || b == 12;
    };

    // Surface can now reach well above one chunk (the wider biome distribution
    // (#6) lets tall mountains/plateaus appear near the origin), so we scan a
    // vertical STACK of y-chunks and report the true top-solid world-y rather
    // than peeking into only chunk y=0/-1.  Underground cave voids below the real
    // surface must not be mistaken for "the surface".
    constexpr int CY_MIN = -2;
    constexpr int CY_MAX =  4;   // covers surfaces up to y~79
    constexpr int NUM_CY = CY_MAX - CY_MIN + 1;

    // X-direction seams: chunks (cx, 0, cz) vs (cx+1, 0, cz)
    for (int cx = -4; cx <= 4; ++cx) {
        for (int cz = -4; cz <= 4; ++cz) {
            std::unique_ptr<PaletteChunk> a_slices[NUM_CY];
            std::unique_ptr<PaletteChunk> b_slices[NUM_CY];
            for (int ci = 0; ci < NUM_CY; ++ci) {
                int cy = CY_MIN + ci;
                a_slices[ci] = std::make_unique<PaletteChunk>(ChunkCoord{cx,   cy, cz}, BlockId(0));
                b_slices[ci] = std::make_unique<PaletteChunk>(ChunkCoord{cx+1, cy, cz}, BlockId(0));
                g.generate({cx,   cy, cz}, *a_slices[ci]);
                g.generate({cx+1, cy, cz}, *b_slices[ci]);
            }

            auto top_solid = [&](std::unique_ptr<PaletteChunk> (&slices)[NUM_CY],
                                 int lx, int lz_col) -> std::int32_t {
                for (int ci = NUM_CY - 1; ci >= 0; --ci) {
                    std::int32_t base = (CY_MIN + ci) * kChunkDim;
                    for (int ly = kChunkDim - 1; ly >= 0; --ly) {
                        BlockId b = slices[ci]->get(lx, ly, lz_col);
                        if (b != 0 && b != 9u && !is_decoration(b)) return base + ly;
                    }
                }
                return bf::kColumnMinY - 1;
            };

            for (int lz = 0; lz < kChunkDim; ++lz) {
                std::int32_t hl = top_solid(a_slices, 15, lz);
                std::int32_t hr = top_solid(b_slices,  0, lz);
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

    // Pick the chunk-y that actually contains the surface at (0,0).  With the
    // wider biome distribution (#6) the origin column can sit in a biome whose
    // surface is above chunk y=0 (e.g. a snowy plateau at y=18), so hard-coding
    // chunk (0,0,0) would scan a pure-fill chunk.  Snow is a legitimate surface
    // cover, so we accept grass/sand/snow_layer as a "surface cover" block.
    int surf_h = worldgen_surface_height(0, 0, SEED);
    int surf_cy = surf_h >= 0 ? surf_h / kChunkDim : (surf_h - (kChunkDim - 1)) / kChunkDim;

    PaletteChunk ch({0, surf_cy, 0}, 0);
    g.generate({0, surf_cy, 0}, ch);

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
                if (b == 1 || b == 6 || b == 12)  has_grass_or_sand = true;  // grass/sand/snow
                if (b == 2 || b == 3)  has_dirt_or_stone = true;
            }

    CHECK(has_air,           "not trivial: surface chunk has AIR cells");
    CHECK(has_grass_or_sand, "not trivial: surface chunk has GRASS, SAND, or SNOW cover");
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

    // Verify a very tall mountain (y>=45) exists in a ±20-chunk scan with a seed
    // known to produce tall peaks — confirms Mountains biome reaches its intended height.
    {
        constexpr std::uint64_t SEED2 = 0xB10BE5EED1234567ull;
        TerrainGen g2;
        g2.seed(SEED2);
        int max_h2 = -999;
        for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
            for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
                std::unique_ptr<PaletteChunk> slices2[NUM_CY_M];
                for (int ci = 0; ci < NUM_CY_M; ++ci) {
                    int cy = CY_MIN + ci;
                    slices2[ci] = std::make_unique<PaletteChunk>(ChunkCoord{cx, cy, cz}, BlockId(0));
                    g2.generate({cx, cy, cz}, *slices2[ci]);
                }
                for (int lz = 0; lz < kChunkDim; ++lz) {
                    for (int lx = 0; lx < kChunkDim; ++lx) {
                        bool col_found2 = false;
                        for (int ci = NUM_CY_M - 1; ci >= 0 && !col_found2; --ci) {
                            std::int32_t base2 = (CY_MIN + ci) * kChunkDim;
                            for (int ly = kChunkDim - 1; ly >= 0 && !col_found2; --ly) {
                                BlockId b = slices2[ci]->get(lx, ly, lz);
                                if (b != 0 && b != 9u && !is_decoration(b)) {
                                    int wy = static_cast<int>(base2) + ly;
                                    if (wy > max_h2) max_h2 = wy;
                                    col_found2 = true;
                                }
                            }
                        }
                    }
                }
            }
        }
        CHECK(max_h2 >= 45,
              "mountain height: tall mountain (y>=45) found with mountain-biome seed");
    }
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

                    // Exempt deliberate cave-entrance columns (#11): these are
                    // intentionally open from the surface downward, so the
                    // sub-surface AIR is expected.  We use the public helper
                    // to identify them with the same seed used by TerrainGen.
                    std::int32_t col_wx = static_cast<std::int32_t>(cx) * kChunkDim + lx;
                    std::int32_t col_wz = static_cast<std::int32_t>(cz) * kChunkDim + lz;
                    if (worldgen_is_cave_entrance(col_wx, col_wz, SEED)) continue;

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
// 15. TREE VARIETY (M5)
//     Verify that:
//       a) Trees of at least two distinct trunk heights appear in a scan
//          (confirming the new 4..12 range rather than uniform 4..6).
//       b) At least one "short" tree (trunk ≤ 5 blocks) and one "tall" tree
//          (trunk ≥ 7 blocks) appear — confirming the full height range.
//
//     Strategy: generate many chunks, record trunk heights by counting
//     contiguous log columns.
// ---------------------------------------------------------------------------
static void test_tree_variety_and_undergrowth() {
    constexpr std::uint64_t SEED = 0x7A3E2B1C5D0F9E8Aull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId OAK_LOG_ID   = 21;
    constexpr BlockId BIRCH_LOG_ID = 22;

    // We collect trunk heights by scanning vertical log columns.
    bool found_short_tree = false;  // trunk height <= 5
    bool found_tall_tree  = false;  // trunk height >= 7

    constexpr int SCAN_R = 10;

    for (int cz = -SCAN_R; cz <= SCAN_R && !(found_short_tree && found_tall_tree); ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R && !(found_short_tree && found_tall_tree); ++cx) {
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

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    // Count consecutive log blocks starting from ground up.
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
                }
            }
        }
    }

    CHECK(found_short_tree,
          "tree variety: short trees (trunk height 4-5) found in world scan");
    CHECK(found_tall_tree,
          "tree variety: tall trees (trunk height >=7) found in world scan");
}

// ---------------------------------------------------------------------------
// 16. ORE GENERATION
//     Scan a large underground volume and verify:
//       a) Coal ore (17) appears underground in stone (common, shallow).
//       b) Iron ore (19) appears underground (less common, deeper).
//       c) Crystal ore (20) appears (rare, deep).
//       d) Crystal is rarer than coal across the scanned region.
//       e) Coal appears at shallower depths than crystal (coal y > crystal_max_y).
//       f) No ores appear at or above y=0 (they should be underground only).
// ---------------------------------------------------------------------------
static void test_ore_generation() {
    constexpr std::uint64_t SEED = 0x0ADFACE50ADE0ADAull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId COAL_ORE_ID    = 17;
    constexpr BlockId COPPER_ORE_ID  = 18;
    constexpr BlockId IRON_ORE_ID    = 19;
    constexpr BlockId CRYSTAL_ORE_ID = 20;

    int coal_count    = 0;
    int copper_count  = 0;
    int iron_count    = 0;
    int crystal_count = 0;
    int ore_above_ground = 0;  // ores at wy >= 0 (should be zero)

    int coal_max_y    = -999;  // highest y coal is found
    int crystal_max_y = -999;  // highest y crystal is found

    // Scan underground chunks: x,z in ±8 chunks, y in -1..-6 (world y -16..-96)
    for (int cz = -8; cz <= 8; ++cz) {
        for (int cx = -8; cx <= 8; ++cx) {
            for (int cy = -1; cy >= -6; --cy) {
                PaletteChunk ch({cx, cy, cz}, 0);
                g.generate({cx, cy, cz}, ch);

                std::int32_t wy_base = cy * kChunkDim;

                for (int lz = 0; lz < kChunkDim; ++lz) {
                    for (int ly = 0; ly < kChunkDim; ++ly) {
                        for (int lx = 0; lx < kChunkDim; ++lx) {
                            BlockId b = ch.get(lx, ly, lz);
                            std::int32_t wy = wy_base + ly;

                            switch (b) {
                                case COAL_ORE_ID:
                                    ++coal_count;
                                    if (wy > coal_max_y) coal_max_y = static_cast<int>(wy);
                                    break;
                                case COPPER_ORE_ID:
                                    ++copper_count;
                                    break;
                                case IRON_ORE_ID:
                                    ++iron_count;
                                    break;
                                case CRYSTAL_ORE_ID:
                                    ++crystal_count;
                                    if (wy > crystal_max_y) crystal_max_y = static_cast<int>(wy);
                                    break;
                                default: break;
                            }

                            bool is_ore = (b == COAL_ORE_ID || b == COPPER_ORE_ID
                                        || b == IRON_ORE_ID || b == CRYSTAL_ORE_ID);
                            if (is_ore && wy >= 0) ++ore_above_ground;
                        }
                    }
                }
            }
        }
    }

    CHECK(coal_count    > 0, "ores: coal ore (17) found underground");
    CHECK(copper_count  > 0, "ores: copper ore (18) found underground");
    CHECK(iron_count    > 0, "ores: iron ore (19) found underground");
    CHECK(crystal_count > 0, "ores: crystal ore (20) found underground");

    // Coal should be much more common than crystal.
    CHECK(coal_count > crystal_count * 3,
          "ores: coal is significantly more common than crystal");

    // Coal should appear at shallower depths than crystal.
    // coal_max_y will be relatively high (close to 0), crystal_max_y deep.
    CHECK(coal_max_y > crystal_max_y,
          "ores: coal found at shallower depths than crystal (progression)");

    // No ores should appear above ground (y >= 0).
    CHECK(ore_above_ground == 0,
          "ores: no ore blocks appear at y >= 0 (underground only)");
}

// ---------------------------------------------------------------------------
// 17. EXTENDED TREE VARIETY
//     Verify that:
//       a) Trees with very tall trunks (>= 8 blocks) exist in the world.
//          The new tree system goes up to 12, so some tall trees must appear.
//       b) Trees with trunks >= 10 exist (giant or tall pine).
//       c) Short trees (trunk 4..5) still exist.
//       d) The new PINE shape produces the correct silhouette (conical):
//          a log column flanked by leaves that extend downward, i.e. there
//          exist leaf blocks below the trunk top (dy < 0 from trunk top).
//          We approximate: leaf blocks appear at a y lower than the tree
//          top in columns adjacent to a trunk column.
// ---------------------------------------------------------------------------
static void test_extended_tree_variety() {
    constexpr std::uint64_t SEED = 0xE4570EE0501D1234ull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId OAK_LOG_ID      = 21;
    constexpr BlockId BIRCH_LOG_ID    = 22;
    constexpr BlockId OAK_LEAVES_ID   = 5;
    constexpr BlockId BIRCH_LEAVES_ID = 27;

    bool found_short_trunk  = false;  // trunk <= 5
    bool found_tall_trunk8  = false;  // trunk >= 8
    bool found_tall_trunk10 = false;  // trunk >= 10

    constexpr int SCAN_R = 12;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            // Generate enough y-slices to see tall trees (trunk up to 12).
            PaletteChunk ch0({cx, 0, cz}, 0);
            PaletteChunk ch1({cx, 1, cz}, 0);
            PaletteChunk ch2({cx, 2, cz}, 0);
            g.generate({cx, 0, cz}, ch0);
            g.generate({cx, 1, cz}, ch1);
            g.generate({cx, 2, cz}, ch2);

            auto get_block = [&](int lx, int wy, int lz) -> BlockId {
                if (wy >= 0  && wy < 16) return ch0.get(lx, wy,      lz);
                if (wy >= 16 && wy < 32) return ch1.get(lx, wy - 16, lz);
                if (wy >= 32 && wy < 48) return ch2.get(lx, wy - 32, lz);
                return BlockId(0);
            };
            auto is_log = [](BlockId b) -> bool {
                return b == OAK_LOG_ID || b == BIRCH_LOG_ID;
            };
            (void)OAK_LEAVES_ID;
            (void)BIRCH_LEAVES_ID;

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    // Count consecutive log blocks (trunk height).
                    int log_start = -1;
                    int log_count = 0;
                    for (int wy = 0; wy < 48; ++wy) {
                        if (is_log(get_block(lx, wy, lz))) {
                            if (log_start < 0) log_start = wy;
                            ++log_count;
                        } else if (log_start >= 0) {
                            break;
                        }
                    }
                    if (log_count == 0) continue;

                    if (log_count <= 5) found_short_trunk  = true;
                    if (log_count >= 8) found_tall_trunk8  = true;
                    if (log_count >= 10) found_tall_trunk10 = true;
                }
            }
        }
    }

    CHECK(found_short_trunk,
          "extended tree variety: short trees (trunk <= 5) still exist");
    CHECK(found_tall_trunk8,
          "extended tree variety: tall trees (trunk >= 8) found in world scan");
    CHECK(found_tall_trunk10,
          "extended tree variety: very tall trees (trunk >= 10) found (giant/pine/birch)");
}

// ---------------------------------------------------------------------------
// 18. STRUCTURES EXIST
//     Scan a large world region and verify that at least one world structure
//     appears.  We look for telltale blocks that only structures place:
//       - CHEST (31)       — treasure marker
//       - GLOW_BLOCK (7)   — campfire ring center
//       - OAK_PLANKS (4)   — hut walls / watchtower platform
//     These blocks only appear in structures (trees use OAK_LOG not OAK_PLANKS;
//     terrain never uses CHEST or GLOW_BLOCK).
//     We also verify cobblestone on the surface (from cairns, pillars, huts,
//     campfire rings, or treasure markers) appears somewhere above sea level.
//
//     Coverage: structures spawn ~12% of 64×64 cells; a ±192 block scan
//     (~12 cells per axis, 144 cells total) gives a ~99.99% hit rate.
// ---------------------------------------------------------------------------
static void test_structures_exist() {
    constexpr std::uint64_t SEED = 0x5704C705EED2024ull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId CHEST_ID      = 31;
    constexpr BlockId GLOW_BLOCK_ID = 7;
    constexpr BlockId OAK_PLANKS_ID = 4;
    constexpr BlockId COBBLE_ID2    = 10;
    constexpr int SEA_LEVEL_TEST    = 6;

    bool found_chest     = false;
    bool found_glow      = false;
    bool found_planks    = false;
    bool found_cobble_surf = false;

    // Scan a ±12 chunk radius (±192 world blocks), y-chunks 0..3 (surface range).
    constexpr int SCAN_R = 12;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            for (int cy = -1; cy <= 3; ++cy) {
                PaletteChunk ch({cx, cy, cz}, 0);
                g.generate({cx, cy, cz}, ch);
                std::int32_t wy_base = cy * kChunkDim;

                for (int lz = 0; lz < kChunkDim; ++lz) {
                    for (int ly = 0; ly < kChunkDim; ++ly) {
                        for (int lx = 0; lx < kChunkDim; ++lx) {
                            BlockId b = ch.get(lx, ly, lz);
                            std::int32_t wy = wy_base + ly;
                            if (b == CHEST_ID)      found_chest  = true;
                            if (b == GLOW_BLOCK_ID) found_glow   = true;
                            if (b == OAK_PLANKS_ID) found_planks = true;
                            if (b == COBBLE_ID2 && wy > SEA_LEVEL_TEST)
                                found_cobble_surf = true;
                        }
                    }
                }
            }
        }
    }

    // At least one of these structure-specific blocks must be present.
    bool any_structure_block = found_chest || found_glow || found_planks;
    CHECK(any_structure_block,
          "structures exist: chest, glow_block, or oak_planks found in world scan");
    CHECK(found_cobble_surf,
          "structures exist: cobblestone found above sea level (from structures)");
}

// ---------------------------------------------------------------------------
// 19. NEW TREE VARIETY — thick trunks and leaning trees
//     Verify that:
//       a) Thick (2×2) trunks exist in the world scan: two adjacent log columns
//          at the same y both contain log blocks.
//       b) Leaning trees exist: a log column where the upper half is offset
//          by 1 block from the lower half (L-bend signature).
//       c) WEEPING or FORKED canopy shapes exist: check for leaf blocks
//          significantly below (≥2 below) the trunk-top of a tree.
// ---------------------------------------------------------------------------
static void test_new_tree_variety() {
    constexpr std::uint64_t SEED = 0x30B1D5EED3C7E8FFull;
    TerrainGen g;
    g.seed(SEED);

    constexpr BlockId OAK_LOG_ID      = 21;
    constexpr BlockId BIRCH_LOG_ID    = 22;
    constexpr BlockId OAK_LEAVES_ID   = 5;
    constexpr BlockId BIRCH_LEAVES_ID = 27;

    bool found_thick_trunk  = false;  // two adjacent logs at same y level
    bool found_leaning_tree = false;  // L-bend: upper trunk offset from lower
    bool found_drooping_leaves = false;  // leaves ≥2 below a trunk top (weeping)

    constexpr int SCAN_R = 15;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            PaletteChunk ch0({cx, 0, cz}, 0);
            PaletteChunk ch1({cx, 1, cz}, 0);
            PaletteChunk ch2({cx, 2, cz}, 0);
            g.generate({cx, 0, cz}, ch0);
            g.generate({cx, 1, cz}, ch1);
            g.generate({cx, 2, cz}, ch2);

            auto get_block = [&](int lx, int wy, int lz) -> BlockId {
                if (wy >= 0  && wy < 16) return ch0.get(lx, wy,      lz);
                if (wy >= 16 && wy < 32) return ch1.get(lx, wy - 16, lz);
                if (wy >= 32 && wy < 48) return ch2.get(lx, wy - 32, lz);
                return BlockId(0);
            };
            auto is_log = [](BlockId b) -> bool {
                return b == OAK_LOG_ID || b == BIRCH_LOG_ID;
            };
            auto is_leaf = [](BlockId b) -> bool {
                return b == OAK_LEAVES_ID || b == BIRCH_LEAVES_ID;
            };

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    // Thick trunk: check (lx, lz) and its +X neighbor both have
                    // contiguous log columns starting at the same y.
                    if (lx + 1 < kChunkDim) {
                        // Find lowest log at (lx, lz).
                        int log_start_a = -1;
                        for (int wy = 0; wy < 48; ++wy) {
                            if (is_log(get_block(lx, wy, lz))) {
                                log_start_a = wy;
                                break;
                            }
                        }
                        if (log_start_a >= 0) {
                            int log_start_b = -1;
                            for (int wy = 0; wy < 48; ++wy) {
                                if (is_log(get_block(lx+1, wy, lz))) {
                                    log_start_b = wy;
                                    break;
                                }
                            }
                            // Same start y and both have ≥3 consecutive logs:
                            // this is a thick trunk.
                            if (log_start_b == log_start_a && log_start_a >= 0) {
                                int count_a = 0, count_b = 0;
                                for (int wy = log_start_a; wy < 48 && is_log(get_block(lx,   wy, lz)); ++wy) ++count_a;
                                for (int wy = log_start_b; wy < 48 && is_log(get_block(lx+1, wy, lz)); ++wy) ++count_b;
                                if (count_a >= 3 && count_b >= 3) {
                                    found_thick_trunk = true;
                                }
                            }
                        }
                    }

                    // Leaning trunk (L-bend): the lower half of the trunk is at
                    // (lx, lz), the upper half shifts by 1 block to (lx+ldx, lz)
                    // or (lx, lz+ldz).  Detection: a log column at (lx, lz)
                    // ends at some y, and EXACTLY at that y+1 an adjacent column
                    // starts a new log run.  This creates a clear L-bend signature.
                    {
                        // Find where the log column at (lx, lz) ends.
                        int log_start = -1, log_end = -1;
                        for (int wy = 1; wy < 40; ++wy) {
                            if (is_log(get_block(lx, wy, lz))) {
                                if (log_start < 0) log_start = wy;
                                log_end = wy;
                            } else if (log_start >= 0) {
                                break;  // column ends here
                            }
                        }
                        if (log_start >= 0 && log_end > log_start + 1) {
                            // A log column exists at (lx, lz) from log_start..log_end.
                            // For a leaning tree, the upper portion continues in an
                            // adjacent column starting at log_end + 1 (or within 1-2 y).
                            for (int ldx = -1; ldx <= 1; ldx += 2) {
                                if (lx + ldx < 0 || lx + ldx >= kChunkDim) continue;
                                // Neighbor should have NO log at log_start (not a side-by-side
                                // thick trunk started earlier) but HAVE a log right above
                                // this column's top.
                                bool no_early_log = !is_log(get_block(lx+ldx, log_start, lz));
                                bool has_upper_log = is_log(get_block(lx+ldx, log_end+1, lz))
                                                  || is_log(get_block(lx+ldx, log_end,   lz));
                                if (no_early_log && has_upper_log) {
                                    found_leaning_tree = true;
                                }
                            }
                        }
                    }

                    // Weeping/droopy leaves: find a log column top (highest log y),
                    // then check if leaves exist 2 or more blocks below that top
                    // in adjacent columns.
                    {
                        int trunk_top = -1;
                        for (int wy = 47; wy >= 0; --wy) {
                            if (is_log(get_block(lx, wy, lz))) {
                                trunk_top = wy;
                                break;
                            }
                        }
                        if (trunk_top >= 4) {
                            // Check adjacent columns for leaves at trunk_top - 2 or lower.
                            for (int ldx = -1; ldx <= 1; ++ldx) {
                                for (int ldz = -1; ldz <= 1; ++ldz) {
                                    if (ldx == 0 && ldz == 0) continue;
                                    int nlx = lx + ldx;
                                    int nlz = lz + ldz;
                                    if (nlx < 0 || nlx >= kChunkDim) continue;
                                    if (nlz < 0 || nlz >= kChunkDim) continue;
                                    if (is_leaf(get_block(nlx, trunk_top - 2, nlz)) ||
                                        is_leaf(get_block(nlx, trunk_top - 3, nlz))) {
                                        found_drooping_leaves = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    CHECK(found_thick_trunk,
          "new tree variety: thick (2x2) trunks found in world scan");
    CHECK(found_leaning_tree,
          "new tree variety: leaning (L-bend) trees found in world scan");
    CHECK(found_drooping_leaves,
          "new tree variety: drooping leaves (weeping canopy) found in world scan");
}

// ---------------------------------------------------------------------------
// 20. CAVE ENTRANCES (#11)
//     Verify that at least one surface-connected cave entrance exists in a
//     scanned region.  A cave entrance is a column where:
//       a) The worldgen_is_cave_entrance() helper returns true (i.e., the
//          worldgen placed a shaft there), AND
//       b) There are AIR blocks in the first several blocks below the top
//          solid block (confirming the shaft was actually carved).
//     We also verify that entrance density is not excessive (< 5% of columns).
// ---------------------------------------------------------------------------
static void test_cave_entrances() {
    constexpr std::uint64_t SEED = 0xCA4EF00D5EED9A11ull;
    TerrainGen g;
    g.seed(SEED);

    auto is_decoration = [](BlockId b) -> bool {
        return b == 5 || b == 21 || b == 22 || b == 27
            || b == 36 || b == 37 || b == 38 || b == 39 || b == 12;
    };

    constexpr int SCAN_R = 16;
    constexpr int CY_MIN = -2;
    constexpr int CY_MAX =  4;
    constexpr int NUM_CY = CY_MAX - CY_MIN + 1;

    int entrance_cols_found = 0;
    int entrance_with_air   = 0;
    int total_columns_scanned = 0;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            std::unique_ptr<PaletteChunk> slices[NUM_CY];
            for (int ci = 0; ci < NUM_CY; ++ci) {
                int cy = CY_MIN + ci;
                slices[ci] = std::make_unique<PaletteChunk>(
                    ChunkCoord{cx, cy, cz}, BlockId(0));
                g.generate({cx, cy, cz}, *slices[ci]);
            }

            auto block_at_wy = [&](int lx2, int lz2, std::int32_t wy) -> BlockId {
                for (int ci = NUM_CY - 1; ci >= 0; --ci) {
                    std::int32_t base = (CY_MIN + ci) * kChunkDim;
                    if (wy >= base && wy < base + kChunkDim) {
                        return slices[ci]->get(lx2, static_cast<int>(wy - base), lz2);
                    }
                }
                return 0;
            };

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    ++total_columns_scanned;

                    std::int32_t col_wx = static_cast<std::int32_t>(cx) * kChunkDim + lx;
                    std::int32_t col_wz = static_cast<std::int32_t>(cz) * kChunkDim + lz;

                    if (!worldgen_is_cave_entrance(col_wx, col_wz, SEED)) continue;
                    ++entrance_cols_found;

                    // Find top solid block (non-air, non-water, non-decoration).
                    std::int32_t top_wy = std::int32_t(CY_MIN) * kChunkDim - 1;
                    bool found_surf = false;
                    for (int ci = NUM_CY - 1; ci >= 0 && !found_surf; --ci) {
                        std::int32_t base = (CY_MIN + ci) * kChunkDim;
                        for (int ly = kChunkDim - 1; ly >= 0 && !found_surf; --ly) {
                            BlockId b = slices[ci]->get(lx, ly, lz);
                            if (b != 0 && b != 9u && !is_decoration(b)) {
                                top_wy = base + ly;
                                found_surf = true;
                            }
                        }
                    }
                    if (!found_surf) continue;

                    // Check for AIR in blocks below the top solid (the shaft).
                    bool has_shaft_air = false;
                    for (int depth = 1; depth <= 8; ++depth) {
                        if (block_at_wy(lx, lz, top_wy - depth) == 0) {
                            has_shaft_air = true;
                            break;
                        }
                    }
                    if (has_shaft_air) ++entrance_with_air;
                }
            }
        }
    }

    // Entrance density should be substantially higher than the old 1/48² ~15% scheme.
    // New: 32×32 cell, 25% probability, 2×2 shaft = ~4 columns per ~1024 block area.
    // In a ±16 chunk (512-block) scan ≈ 1024 cells × 25% × 4 shaft blocks = ~1024 cols.
    // We require at minimum >100 entrance columns to confirm denser coverage.
    CHECK(entrance_cols_found > 100,
          "cave entrances: at least 100 entrance columns in scan (denser with 32-cell 25% 2x2)");
    // The carved shafts must actually have AIR below the surface.
    CHECK(entrance_with_air > 0,
          "cave entrances: entrance column(s) have AIR below the surface (shaft carved)");
    // Entrances should still be sparse enough to feel special — less than 1% of columns.
    // (4 shaft blocks / 1024 cell blocks = 0.39%, safely under 1%.)
    int pct_times_1000 = (total_columns_scanned > 0)
        ? (entrance_cols_found * 1000) / total_columns_scanned : 0;
    CHECK(pct_times_1000 < 10,  // < 1% of columns
          "cave entrances: entrance columns are sparse (< 1% of all columns)");
}

// ---------------------------------------------------------------------------
// 21. OCEAN DEPTH (#12)
//     Verify that water bodies reach a proper depth (>= 4 blocks) somewhere
//     in a scanned region.  We find water columns and measure how many
//     consecutive WATER blocks appear from the top down to the ocean floor.
//     At least one water column must have >= 4 blocks of continuous water depth.
// ---------------------------------------------------------------------------
static void test_ocean_depth() {
    constexpr std::uint64_t OCEAN_SEED = 0x0CE4B0CA5E1D07BBull;
    TerrainGen g;
    g.seed(OCEAN_SEED);

    constexpr int SCAN_R = 20;
    constexpr int CY_MIN = -2;
    constexpr int CY_MAX =  2;
    constexpr int NUM_CY = CY_MAX - CY_MIN + 1;

    int max_water_depth = 0;
    int columns_with_deep_water = 0;  // depth >= 4

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            std::unique_ptr<PaletteChunk> slices[NUM_CY];
            for (int ci = 0; ci < NUM_CY; ++ci) {
                int cy = CY_MIN + ci;
                slices[ci] = std::make_unique<PaletteChunk>(
                    ChunkCoord{cx, cy, cz}, BlockId(0));
                g.generate({cx, cy, cz}, *slices[ci]);
            }

            auto block_at_wy = [&](int lx2, int lz2, std::int32_t wy) -> BlockId {
                for (int ci = NUM_CY - 1; ci >= 0; --ci) {
                    std::int32_t base = (CY_MIN + ci) * kChunkDim;
                    if (wy >= base && wy < base + kChunkDim) {
                        return slices[ci]->get(lx2, static_cast<int>(wy - base), lz2);
                    }
                }
                return 0;  // out of range = AIR
            };

            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    // SEA_LEVEL is 6.  Check if the block at y=SEA_LEVEL is WATER.
                    constexpr std::int32_t SEA_LVL = 6;
                    if (block_at_wy(lx, lz, SEA_LVL) != 9u) continue;  // not water surface

                    // Count consecutive WATER blocks downward from SEA_LEVEL.
                    int depth = 0;
                    for (std::int32_t wy = SEA_LVL; wy >= SEA_LVL - 15; --wy) {
                        if (block_at_wy(lx, lz, wy) == 9u) {
                            ++depth;
                        } else {
                            break;  // hit solid floor
                        }
                    }

                    if (depth > max_water_depth) max_water_depth = depth;
                    if (depth >= 4) ++columns_with_deep_water;
                }
            }
        }
    }

    CHECK(columns_with_deep_water > 0,
          "ocean depth: at least one water column reaches >= 4 blocks deep");
    CHECK(max_water_depth >= 4,
          "ocean depth: maximum water depth found is >= 4 blocks");
}

// ---------------------------------------------------------------------------
// 22. CLIMATE / BIOME COVERAGE (#6 MORE BIOME VARIETY)
//     Using the dominant-biome probe directly, assert that every biome —
//     including the previously near-absent desert (3), snowy (4) and swamp (5)
//     — appears within a reasonable area, and that no single biome dominates the
//     map.  Order: 0=Plains 1=Forest 2=Mountains 3=Desert 4=Snowy 5=Swamp 6=Beach.
// ---------------------------------------------------------------------------
static void test_biome_coverage() {
    constexpr std::uint64_t SEED = 0xB10BE5EED1234567ull;

    long counts[7] = {0,0,0,0,0,0,0};
    long total = 0;
    // ±256 world blocks (a short walk), sampled every 4 blocks.
    for (int wz = -256; wz < 256; wz += 4) {
        for (int wx = -256; wx < 256; wx += 4) {
            int b = worldgen_dominant_biome(wx, wz, SEED);
            if (b >= 0 && b < 7) ++counts[b];
            ++total;
        }
    }

    for (int i = 0; i < 7; ++i) {
        CHECK(counts[i] > 0, "biome coverage: every biome appears within a short walk");
    }
    // The three biomes the player reported missing must each be clearly present
    // (> 3% of the area), not just a stray column.
    CHECK(counts[3] * 100 > total * 3, "biome coverage: desert is well represented (>3%)");
    CHECK(counts[4] * 100 > total * 3, "biome coverage: snowy is well represented (>3%)");
    CHECK(counts[5] * 100 > total * 3, "biome coverage: swamp is well represented (>3%)");
    // No single biome should swamp the map (plains was ~70% before the spread fix).
    for (int i = 0; i < 7; ++i) {
        CHECK(counts[i] * 100 < total * 50,
              "biome coverage: no single biome exceeds 50% of the map");
    }
}

// ---------------------------------------------------------------------------
// 23. ROCKY MOUNTAINS (#6) — mountains read as rock, not grassy hills.
//     Scan a large area and confirm that stone/gravel surfaces appear on
//     mountain ground BELOW the snow line (the new ROCK_LINE behaviour), so
//     mountains are visually distinct from plains/forest.
// ---------------------------------------------------------------------------
static void test_rocky_mountains() {
    constexpr std::uint64_t SEED = 0xA0041A5EED123456ull;
    TerrainGen g;
    g.seed(SEED);

    auto is_decoration = [](BlockId b) -> bool {
        return b == 5 || b == 21 || b == 22 || b == 27
            || b == 36 || b == 37 || b == 38 || b == 39 || b == 12;
    };

    constexpr int SCAN_R = 16;
    constexpr int CY_MIN = 0;
    constexpr int CY_MAX = 3;   // mid mountain ground (ROCK_LINE=16 .. SNOW_LINE=32)
    constexpr int NUM_CY = CY_MAX - CY_MIN + 1;

    int rock_below_snowline = 0;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            std::unique_ptr<PaletteChunk> slices[NUM_CY];
            for (int ci = 0; ci < NUM_CY; ++ci) {
                int cy = CY_MIN + ci;
                slices[ci] = std::make_unique<PaletteChunk>(ChunkCoord{cx, cy, cz}, BlockId(0));
                g.generate({cx, cy, cz}, *slices[ci]);
            }
            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    bool found = false;
                    for (int ci = NUM_CY - 1; ci >= 0 && !found; --ci) {
                        std::int32_t base = (CY_MIN + ci) * kChunkDim;
                        for (int ly = kChunkDim - 1; ly >= 0 && !found; --ly) {
                            BlockId b = slices[ci]->get(lx, ly, lz);
                            if (b != 0 && b != 9u && !is_decoration(b)) {
                                int wy = static_cast<int>(base) + ly;
                                // Rock/gravel surface between ROCK_LINE(16) and below
                                // SNOW_LINE(32): the new "rocky mountain" surface.
                                if ((b == 3u || b == 11u || b == 10u) &&
                                    wy >= 16 && wy < 32) {
                                    ++rock_below_snowline;
                                }
                                found = true;
                            }
                        }
                    }
                }
            }
        }
    }

    CHECK(rock_below_snowline > 0,
          "rocky mountains: stone/gravel surface appears on mid mountains (below snow line)");
}

// ---------------------------------------------------------------------------
// 24. DESERT DECORATION (#18 DESERTS ARE FLAT/DEAD)
//     Confirm deserts now carry scatter: dead bushes (mushroom billboard),
//     small rock piles (stone/gravel bump on sand), or cacti (short log column).
//     We look for these features sitting directly on dry desert sand.
// ---------------------------------------------------------------------------
static void test_desert_decoration() {
    constexpr std::uint64_t SEED = 0xB10BE5EED1234567ull;
    TerrainGen g;
    g.seed(SEED);

    constexpr int SCAN_R = 16;

    int dead_bush = 0;   // mushroom on sand
    int rock_pile = 0;   // stone/gravel bump on sand
    int cactus    = 0;   // oak_log column on sand

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            PaletteChunk c0({cx, 0, cz}, 0);
            PaletteChunk c1({cx, 1, cz}, 0);
            g.generate({cx, 0, cz}, c0);
            g.generate({cx, 1, cz}, c1);
            auto at = [&](int lx, int wy, int lz) -> BlockId {
                if (wy >= 0 && wy < 16)  return c0.get(lx, wy, lz);
                if (wy >= 16 && wy < 32) return c1.get(lx, wy - 16, lz);
                return 0;
            };
            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    int wx = cx * 16 + lx, wz = cz * 16 + lz;
                    if (worldgen_dominant_biome(wx, wz, SEED) != 3) continue;  // desert
                    int H = worldgen_surface_height(wx, wz, SEED);
                    if (H <= 6) continue;
                    // surface should be sand
                    if (at(lx, H, lz) != 6u) continue;
                    BlockId above = at(lx, H + 1, lz);
                    if (above == 39u)                  ++dead_bush;
                    else if (above == 3u || above == 11u) ++rock_pile;
                    else if (above == 21u)             ++cactus;
                }
            }
        }
    }

    CHECK(dead_bush + rock_pile + cactus > 0,
          "desert decoration: deserts carry scattered decoration (was flat/dead)");
    CHECK(dead_bush > 0, "desert decoration: dead bushes (mushroom billboard) present");
    CHECK(rock_pile > 0, "desert decoration: small rock piles present");
    CHECK(cactus    > 0, "desert decoration: cacti (log stand-in) present");
}

// ---------------------------------------------------------------------------
// 25. UNDERWATER VEGETATION (#19 WATER IS EMPTY)
//     Confirm seagrass/kelp (tall_grass billboard) is placed on the ocean floor
//     and surrounded by water (i.e. it is genuinely submerged, not on dry land).
// ---------------------------------------------------------------------------
static void test_underwater_vegetation() {
    constexpr std::uint64_t SEED = 0x0CE4B0CA5E1D07BBull;
    TerrainGen g;
    g.seed(SEED);

    constexpr int SCAN_R = 18;
    constexpr int CY_MIN = -1;
    constexpr int CY_MAX =  1;
    constexpr int NUM_CY = CY_MAX - CY_MIN + 1;

    int submerged_kelp = 0;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            std::unique_ptr<PaletteChunk> slices[NUM_CY];
            for (int ci = 0; ci < NUM_CY; ++ci) {
                int cy = CY_MIN + ci;
                slices[ci] = std::make_unique<PaletteChunk>(ChunkCoord{cx, cy, cz}, BlockId(0));
                g.generate({cx, cy, cz}, *slices[ci]);
            }
            auto at = [&](int lx, std::int32_t wy, int lz) -> BlockId {
                for (int ci = NUM_CY - 1; ci >= 0; --ci) {
                    std::int32_t base = (CY_MIN + ci) * kChunkDim;
                    if (wy >= base && wy < base + kChunkDim)
                        return slices[ci]->get(lx, static_cast<int>(wy - base), lz);
                }
                return 0;
            };
            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx < kChunkDim; ++lx) {
                    for (std::int32_t wy = 0; wy <= 6; ++wy) {
                        // tall_grass (38) is the seagrass id; it counts as
                        // underwater if there is WATER (9) directly above it.
                        if (at(lx, wy, lz) == 38u && at(lx, wy + 1, lz) == 9u) {
                            ++submerged_kelp;
                        }
                    }
                }
            }
        }
    }

    CHECK(submerged_kelp > 0,
          "underwater vegetation: seagrass/kelp (tall_grass) found submerged under water");
}

// ---------------------------------------------------------------------------
// 26. STRUCTURE DENSITY INCREASED (#17 STRUCTURES TOO RARE)
//     The structure-count probe must report substantially more structures than
//     the old ~12% spawn scheme.  We assert a healthy count in a 512×512 region
//     (old scheme yielded ~5-6; new should be roughly 2-3× that).
// ---------------------------------------------------------------------------
static void test_structure_density() {
    // Several seeds so we don't rely on one lucky layout.
    const std::uint64_t seeds[] = {
        0x5704C705EED2024ull, 0xB10BE5EED1234567ull, 0xDEADBEEFCAFEBABEull
    };
    int worst = 1 << 30;
    for (std::uint64_t s : seeds) {
        int n = worldgen_count_structures(-256, -256, 512, s);
        if (n < worst) worst = n;
    }
    // Old (12%) scheme gave ~5-6 structures here; the new (~31%) scheme should
    // comfortably exceed 10 even on the sparsest of these seeds.
    CHECK(worst >= 10,
          "structure density: >=10 structures per 512x512 region (was ~5-6) — #17");
}

// ---------------------------------------------------------------------------
// 27. DEADWOOD (#22) — stumps and fallen logs on the forest floor.
//     Confirm short log remnants (stumps) and horizontal log runs (fallen logs)
//     appear in wooded biomes.  We detect a horizontal pair of logs at the same
//     y resting just above the surface (fallen-log signature) OR a 1-2 high log
//     stub standing alone (stump).  This is in addition to full trees.
// ---------------------------------------------------------------------------
static void test_deadwood() {
    constexpr std::uint64_t SEED = 0x7A3E2B1C5D0F9E8Aull;
    TerrainGen g;
    g.seed(SEED);

    constexpr int SCAN_R = 14;
    int horizontal_log_runs = 0;

    for (int cz = -SCAN_R; cz <= SCAN_R; ++cz) {
        for (int cx = -SCAN_R; cx <= SCAN_R; ++cx) {
            PaletteChunk c0({cx, 0, cz}, 0);
            PaletteChunk c1({cx, 1, cz}, 0);
            g.generate({cx, 0, cz}, c0);
            g.generate({cx, 1, cz}, c1);
            auto at = [&](int lx, int wy, int lz) -> BlockId {
                if (wy >= 0 && wy < 16)  return c0.get(lx, wy, lz);
                if (wy >= 16 && wy < 32) return c1.get(lx, wy - 16, lz);
                return 0;
            };
            auto is_log = [](BlockId b) { return b == 21u || b == 22u; };
            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int lx = 0; lx + 2 < kChunkDim; ++lx) {
                    int wx = cx * 16 + lx, wz = cz * 16 + lz;
                    int H = worldgen_surface_height(wx, wz, SEED);
                    if (H <= 6) continue;
                    int wy = H + 1;
                    if (wy < 0 || wy >= 31) continue;
                    // Fallen-log signature: 3 consecutive logs along +X at surface+1,
                    // with NO log directly below the middle (i.e. not a trunk).
                    if (is_log(at(lx, wy, lz)) && is_log(at(lx + 1, wy, lz)) &&
                        is_log(at(lx + 2, wy, lz)) &&
                        !is_log(at(lx + 1, wy + 1, lz))) {
                        ++horizontal_log_runs;
                    }
                }
            }
        }
    }

    CHECK(horizontal_log_runs > 0,
          "deadwood: horizontal fallen-log runs found on the forest floor (#22)");
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
    test_ore_generation();
    test_extended_tree_variety();
    test_structures_exist();
    test_new_tree_variety();
    test_cave_entrances();
    test_ocean_depth();
    test_biome_coverage();
    test_rocky_mountains();
    test_desert_decoration();
    test_underwater_vegetation();
    test_structure_density();
    test_deadwood();

    if (fails == 0) {
        std::printf("OK: worldgen tests\n");
        return 0;
    }
    std::printf("%d test(s) FAILED\n", fails);
    return 1;
}
