// ============================================================================
// Blockfall — Track C: deterministic procedural world generation
// (engine/src/worldgen.cpp)
//
// All noise and biome functions are pure functions of (x, y, z, seed).
// No mutable static state, no time(), no rand().
//
// Noise design
// ------------
//   hash1(ix, iz, seed) -- Wang-mix of two 64-bit inputs -> [0,1] float
//   smooth(x, z, seed)  -- bilinear interpolation over hash lattice (value noise)
//   fbm2(x, z, seed, oct) -- fractal 2D: sum of `oct` smooth octaves
//   fbm3(x, y, z, seed)   -- fractal 3D for caves
//
// Biome system (7 biomes, smoothly blended)
// ------------------------------------------
// Two low-frequency 2D noise channels (temperature T, moisture M) partition the
// world into 7 biomes.  Biome WEIGHTS (not a hard classification) are computed
// as soft Gaussian-like kernels in (T,M) space so every column carries a blend
// across all biomes proportional to its distance from each centre.  Heights and
// block choices are then the weighted average of per-biome parameters — this
// guarantees C0-continuous terrain across ALL biome boundaries with no cliffs.
//
// To keep flat biomes (plains, beach) genuinely flat even when adjacent to
// hilly biomes, the biome weight of the DOMINANT biome is boosted before
// blending: w_dom is raised to the 3rd power and all others stay at w^2.
// This sharpens the transition without creating a hard discontinuity.
//
// Biomes and approximate (T,M) centres:
//   PLAINS      (0.5, 0.5)  flat, grass, lots of flowers+tall grass, sparse trees
//   FOREST      (0.5, 0.8)  rolling, very dense trees, mushrooms, mossy stone
//   MOUNTAINS   (0.3, 0.4)  tall peaks, stone/gravel on steep slopes, snow cap
//   DESERT      (0.8, 0.1)  gentle dunes + micro-ripple, sand fill
//   SNOWY       (0.1, 0.5)  snow surface, birch trees, frozen water (ice)
//   SWAMP       (0.5, 0.95) low+flat, water pools, mud (dirt), mushrooms, clay
//   BEACH       (0.6, 0.3)  thin sand band near sea level (very low amp)
//
// Terrain shape per biome:
//   base_y  — vertical centre of the terrain column
//   amp     — half-amplitude of height variation
//   freq    — primary noise frequency (higher = more jagged/detailed)
//   octaves — fBm octave count (mountains get more detail)
//
// Regional elevation swell (M5 addition)
// ----------------------------------------
// A very low-frequency (1/320) 2D noise term (2 octaves, amplitude ~4 blocks)
// is added to all biome heights before blending.  This makes even plains "roll"
// gently at large scale — different parts of the plains plateau sit at slightly
// different elevations — while keeping within-chunk variation small enough that
// the flatness test still passes (the swell is nearly constant over 16 blocks).
//
// Cave carving: 3D fbm > threshold => AIR underground.
//   FIX: cave carving requires wy < H - 6 (was H-2) to prevent surface holes.
//
// Tree variety (M5 addition, extended)
// ---------------------------
// Trees vary in: trunk height (4..12), canopy shape (5 distinct shapes),
// and wood type (oak/birch).  Shape is encoded as a 3-bit value derived
// deterministically from the cell hash.  Per-biome rules:
//   Forest:    mix of BROAD/GIANT/ROUND, trunk 6..10, denser.
//   Plains:    ROUND/COMPACT short, trunk 4..5, sparse.
//   Snowy:     PINE (narrow conical), trunk 6..10.
//   Swamp:     COMPACT/BROAD short-wide, trunk 4..6.
//   Mountains: PINE/TALL, trunk 5..8.
//   All biomes: rare GIANT (trunk 10..12, huge canopy) ~5% of cells.
//   BIRCH shape: tall slender trunks 7..10.
//   SHRUB: very short bushy tree, trunk 2..3, compact 5x3x5 crown.
// All canopy writing is seam-safe: trees hash on trunk world position and
// write into any chunk their canopy overlaps.
//
// Undergrowth (M5 addition)
// --------------------------
// The plants pass now places:
//   - Increased TALL_GRASS and FLOWER density in forest/plains/swamp.
//   - MUSHROOM scatter under forest canopy and in swamp.
//
// Ore veins (#8 — mining progression)
// -------------------------------------
// Underground ore clusters are generated in a seam-safe, deterministic way:
//   - Veins are anchored on a world-aligned ORE_CELL grid (size 7x7x7).
//   - Each cell anchor hash determines ore type, vein size (3-8 blocks),
//     and presence probability.  The anchor world coords are used for the
//     hash so any chunk that overlaps a vein's extent generates it identically.
//   - Ore placement only replaces STONE (never AIR/caves/other ores).
//   - Depth windows (relative to surface H of the column — approximate):
//       coal_ore   (17): surface − 8  ..  kColumnMinY+4  (common, shallow)
//       copper_ore (18): surface − 14 ..  kColumnMinY+4  (mid depth)
//       iron_ore   (19): surface − 20 ..  kColumnMinY+4  (mid-deep)
//       crystal_ore(20): surface − 32 ..  kColumnMinY+4  (rare, deep only)
//     Depth is checked against absolute world-y, not per-column surface,
//     for seam safety.  Hard depth ceilings below surface are used.
//   - Density: coal ~12% of cells, copper ~8%, iron ~5%, crystal ~2%.
//
// Decoration (seam-aware scatter, PRESERVED from previous agent)
// -----------------------------------------------------------------
// Trees are placed on a world-aligned 8x8 tree-cell grid.  The cell hash
// determines: presence, root (wx,wz) offset, trunk height (4..8), shape,
// type (oak/birch).  Each biome has its own tree-density threshold.
// A tree is only spawned if its biome weight for the designated tree-bearing
// biomes exceeds a threshold.
//
// Plants (tall grass, flowers, mushrooms, bushes) are single-block decorations
// placed directly on each column's surface — no cross-chunk margin needed.
//
// Biome-distinct surface features:
//   Mountains: stone/cobblestone on steep slopes (slope computed from the
//              same continuous height function — seam safe); snow cap above
//              SNOW_LINE; gravel patches on high ground.
//   Desert:    micro-ripple noise (extra 0-2 block height variation),
//              sandstone sub-layer (stone id) below sand fill.
//   Swamp:     clay sub-layer patches, shallow water pools.
//   Forest:    mossy stone patches below surface.
//   Snowy:     snow_layer surface, ice on water.
//   Plains:    grass + flowers + tall grass; genuinely flat (amp=2).
//   Beach:     bare sand, very flat (amp=1).
// ============================================================================
#include "blockcore/worldgen.hpp"
#include "blockcore/chunk.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace bf {

// ---------------------------------------------------------------------------
// Block id constants (verified against content/blocks/*.json)
// ---------------------------------------------------------------------------
static constexpr BlockId AIR           = 0;
static constexpr BlockId GRASS         = 1;
static constexpr BlockId DIRT          = 2;
static constexpr BlockId STONE         = 3;
static constexpr BlockId OAK_PLANKS    = 4;
static constexpr BlockId OAK_LEAVES    = 5;
static constexpr BlockId SAND          = 6;
static constexpr BlockId GLOW_BLOCK    = 7;
static constexpr BlockId WATER         = 9;
static constexpr BlockId COBBLESTONE   = 10;
static constexpr BlockId GRAVEL        = 11;
static constexpr BlockId SNOW_LAYER    = 12;
static constexpr BlockId ICE           = 13;
static constexpr BlockId CLAY          = 14;
static constexpr BlockId COAL_ORE      = 17;
static constexpr BlockId COPPER_ORE    = 18;
static constexpr BlockId IRON_ORE      = 19;
static constexpr BlockId CRYSTAL_ORE   = 20;
static constexpr BlockId OAK_LOG       = 21;
static constexpr BlockId BIRCH_LOG     = 22;
static constexpr BlockId BIRCH_LEAVES  = 27;
static constexpr BlockId MOSSY_STONE   = 29;
static constexpr BlockId CHEST         = 31;
static constexpr BlockId FLOWER_RED    = 36;
static constexpr BlockId FLOWER_YELLOW = 37;
static constexpr BlockId TALL_GRASS    = 38;
static constexpr BlockId MUSHROOM      = 39;

static constexpr int SEA_LEVEL = 6;

// Snow line: columns at this world-y or above in mountain biome get snow.
// Raised from 24→32 so snow only appears on real mountain peaks, not grassy hills.
static constexpr int SNOW_LINE = 32;

// Rock line (#6): mountain ground at this world-y or above (but below the snow
// line) gets a patchy stone/gravel surface instead of grass, so mountains read
// as rocky/scree rather than grassy hills.  Below this, lower mountain skirts
// stay grassy for a natural treeline-to-rock gradient.
static constexpr int ROCK_LINE = 16;

// Cave noise threshold: cells whose 3D noise > this become AIR.
// Lowered from 0.68 to 0.65 to increase overall cave density (#11).
static constexpr float CAVE_THRESH = 0.65f;

// Surface margin for cave carving: caves must be this many blocks below surface.
// FIX: raised from 2 to 6 to eliminate surface holes/AIR pockets visible from above.
static constexpr int CAVE_SURFACE_MARGIN = 6;

// ---------------------------------------------------------------------------
// Hash primitives — Wang/murmur-inspired 64-bit mixes
// ---------------------------------------------------------------------------

static constexpr std::uint64_t fmix64(std::uint64_t h) noexcept {
    h ^= h >> 33u;
    h *= 0xFF51AFD7ED558CCDull;
    h ^= h >> 33u;
    h *= 0xC4CEB9FE1A85EC53ull;
    h ^= h >> 33u;
    return h;
}

static std::uint64_t hash2(std::int32_t ix, std::int32_t iz, std::uint64_t seed) noexcept {
    std::uint64_t h = seed;
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(ix)));
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(iz)) * 0x9E3779B97F4A7C15ull);
    return fmix64(h);
}

static std::uint64_t hash3(std::int32_t ix, std::int32_t iy, std::int32_t iz,
                            std::uint64_t seed) noexcept {
    std::uint64_t h = seed;
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(ix)));
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(iy)) * 0x517CC1B727220A95ull);
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(iz)) * 0x9E3779B97F4A7C15ull);
    return fmix64(h);
}

static float h2f(std::uint64_t h) noexcept {
    return static_cast<float>(h >> 40u) / static_cast<float>(1u << 24u);
}

// ---------------------------------------------------------------------------
// Smoothstep
// ---------------------------------------------------------------------------
static constexpr float smoothstep(float t) noexcept {
    return t * t * (3.0f - 2.0f * t);
}

// ---------------------------------------------------------------------------
// 2D value noise: bilinearly interpolated hash lattice
// ---------------------------------------------------------------------------
static float value_noise2(float fx, float fz, std::uint64_t seed) noexcept {
    auto ifloor = [](float v) noexcept -> std::int32_t {
        auto i = static_cast<std::int32_t>(v);
        return (v < static_cast<float>(i)) ? i - 1 : i;
    };

    std::int32_t x0 = ifloor(fx);
    std::int32_t z0 = ifloor(fz);
    std::int32_t x1 = x0 + 1;
    std::int32_t z1 = z0 + 1;

    float tx = smoothstep(fx - static_cast<float>(x0));
    float tz = smoothstep(fz - static_cast<float>(z0));

    float v00 = h2f(hash2(x0, z0, seed));
    float v10 = h2f(hash2(x1, z0, seed));
    float v01 = h2f(hash2(x0, z1, seed));
    float v11 = h2f(hash2(x1, z1, seed));

    float top = v00 + tx * (v10 - v00);
    float bot = v01 + tx * (v11 - v01);
    return top + tz * (bot - top);
}

// 3D value noise: trilinearly interpolated
static float value_noise3(float fx, float fy, float fz, std::uint64_t seed) noexcept {
    auto ifloor = [](float v) noexcept -> std::int32_t {
        auto i = static_cast<std::int32_t>(v);
        return (v < static_cast<float>(i)) ? i - 1 : i;
    };

    std::int32_t x0 = ifloor(fx), x1 = x0 + 1;
    std::int32_t y0 = ifloor(fy), y1 = y0 + 1;
    std::int32_t z0 = ifloor(fz), z1 = z0 + 1;

    float tx = smoothstep(fx - static_cast<float>(x0));
    float ty = smoothstep(fy - static_cast<float>(y0));
    float tz = smoothstep(fz - static_cast<float>(z0));

    float c[2][2][2];
    c[0][0][0] = h2f(hash3(x0, y0, z0, seed));
    c[1][0][0] = h2f(hash3(x1, y0, z0, seed));
    c[0][1][0] = h2f(hash3(x0, y1, z0, seed));
    c[1][1][0] = h2f(hash3(x1, y1, z0, seed));
    c[0][0][1] = h2f(hash3(x0, y0, z1, seed));
    c[1][0][1] = h2f(hash3(x1, y0, z1, seed));
    c[0][1][1] = h2f(hash3(x0, y1, z1, seed));
    c[1][1][1] = h2f(hash3(x1, y1, z1, seed));

    auto lerp = [](float a, float b, float t) noexcept { return a + t * (b - a); };

    float x00 = lerp(c[0][0][0], c[1][0][0], tx);
    float x10 = lerp(c[0][1][0], c[1][1][0], tx);
    float x01 = lerp(c[0][0][1], c[1][0][1], tx);
    float x11 = lerp(c[0][1][1], c[1][1][1], tx);

    float y0v = lerp(x00, x10, ty);
    float y1v = lerp(x01, x11, ty);
    return lerp(y0v, y1v, tz);
}

// ---------------------------------------------------------------------------
// Fractal Brownian Motion (fBm) — 2D
// Returns value in approximately [0, 1].
// ---------------------------------------------------------------------------
static float fbm2(float wx, float wz, std::uint64_t seed, int octaves,
                  float base_freq, float lacunarity = 2.0f,
                  float persistence = 0.5f) noexcept {
    float val     = 0.0f;
    float amp     = 1.0f;
    float freq    = base_freq;
    float max_val = 0.0f;

    for (int o = 0; o < octaves; ++o) {
        std::uint64_t oseed = fmix64(seed ^ static_cast<std::uint64_t>(o) * 0xABCDEF01234567ull);
        val     += amp * value_noise2(wx * freq, wz * freq, oseed);
        max_val += amp;
        amp     *= persistence;
        freq    *= lacunarity;
    }
    return val / max_val;
}

// 3D fBm for caves.
static float fbm3(float wx, float wy, float wz, std::uint64_t seed, int octaves,
                  float base_freq) noexcept {
    float val     = 0.0f;
    float amp     = 1.0f;
    float freq    = base_freq;
    float max_val = 0.0f;
    constexpr float lacunarity  = 2.0f;
    constexpr float persistence = 0.5f;

    for (int o = 0; o < octaves; ++o) {
        std::uint64_t oseed = fmix64(seed ^ static_cast<std::uint64_t>(o + 7) * 0xFEDCBA9876543211ull);
        val     += amp * value_noise3(wx * freq, wy * freq, wz * freq, oseed);
        max_val += amp;
        amp     *= persistence;
        freq    *= lacunarity;
    }
    return val / max_val;
}

// ---------------------------------------------------------------------------
// Cave entrance system (#11 — surface-connected cave openings)
// ---------------------------------------------------------------------------
// A sparse grid (ENTRANCE_CELL_SIZE blocks per cell) places deliberate cave
// mouth shafts where a vertical tunnel is carved from the surface down to a
// depth where normal caves exist.  Each cell has one candidate entrance;
// ~15% of cells spawn one.  The shaft is 1 block wide and 10-14 blocks deep,
// centred at a chosen world (wx, wz) derived deterministically from the cell.
//
// Seam safety: the entrance position is derived purely from cell integer coords
// × cell size, so any chunk that overlaps the shaft generates it identically.
//
// The no-surface-holes test must exempt entrance columns because by design the
// surface block IS the top of the shaft opening and the blocks below are AIR.
// We expose is_cave_entrance() via the header as worldgen_is_cave_entrance()
// so the test can identify and skip those columns.
// ---------------------------------------------------------------------------
static constexpr int  ENTRANCE_CELL_SIZE  = 32;    // one candidate per 32×32 region (was 48)
static constexpr std::uint64_t ENTRANCE_SEED_MIX = 0xCA4E5EE7E57A4CE5ull;

// Probability threshold: ~25% of cells spawn an entrance (out of 256).
// Raised from 38/256 (~15%) to 64/256 (~25%) so entrances are easier to find.
static constexpr std::uint64_t ENTRANCE_PROB_THRESH = 64u;  // 64/256 ≈ 25%

// Depth of the carved shaft: how many blocks below the surface are turned to AIR.
// Chosen so the shaft always reaches the depth where normal cave noise kicks in.
static constexpr int ENTRANCE_SHAFT_DEPTH_MIN = 10;
static constexpr int ENTRANCE_SHAFT_DEPTH_MAX = 14;

struct EntranceDesc {
    std::int32_t wx;   // world X of shaft centre
    std::int32_t wz;   // world Z of shaft centre
    int          shaft_depth;  // how many blocks below surface are carved
    bool         present;
};

// Floor-division for negative coords.
static std::int32_t entrance_floordiv(std::int32_t a, int b) noexcept {
    return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
}

static EntranceDesc entrance_for_cell(std::int32_t ecx, std::int32_t ecz,
                                       std::uint64_t seed) noexcept {
    std::uint64_t eseed = fmix64(seed ^ ENTRANCE_SEED_MIX);
    std::uint64_t h     = hash2(ecx, ecz, eseed);

    // Probability gate.
    if ((h & 0xFFu) >= ENTRANCE_PROB_THRESH) {
        return EntranceDesc{0, 0, 0, false};
    }

    std::uint64_t h2 = fmix64(h ^ 0xE57A4CE5CA4EF00Dull);

    // Offset within cell: keep away from cell edges so shaft stays inside.
    std::int32_t off_x = 4 + static_cast<std::int32_t>(
        (h2 >> 0u)  % static_cast<std::uint64_t>(ENTRANCE_CELL_SIZE - 8));
    std::int32_t off_z = 4 + static_cast<std::int32_t>(
        (h2 >> 16u) % static_cast<std::uint64_t>(ENTRANCE_CELL_SIZE - 8));

    // Shaft depth.
    int depth = ENTRANCE_SHAFT_DEPTH_MIN
              + static_cast<int>((h2 >> 32u) % static_cast<std::uint64_t>(
                    ENTRANCE_SHAFT_DEPTH_MAX - ENTRANCE_SHAFT_DEPTH_MIN + 1));

    return EntranceDesc{
        ecx * ENTRANCE_CELL_SIZE + off_x,
        ecz * ENTRANCE_CELL_SIZE + off_z,
        depth,
        true
    };
}

// Returns true if the world column (wx, wz) is part of a 2×2 cave entrance shaft.
// The shaft centre is at (ed.wx, ed.wz); the shaft covers (ed.wx, ed.wz),
// (ed.wx+1, ed.wz), (ed.wx, ed.wz+1), (ed.wx+1, ed.wz+1) — all four blocks.
// Used by terrain fill (to carve the shaft) and the public wrapper (for tests).
static bool is_cave_entrance(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept {
    std::int32_t ecx = entrance_floordiv(wx, ENTRANCE_CELL_SIZE);
    std::int32_t ecz = entrance_floordiv(wz, ENTRANCE_CELL_SIZE);

    // Check the owning cell and immediate neighbours (shaft spans at most 2 cells).
    for (std::int32_t dce = -1; dce <= 1; ++dce) {
        for (std::int32_t dcf = -1; dcf <= 1; ++dcf) {
            EntranceDesc ed = entrance_for_cell(ecx + dce, ecz + dcf, seed);
            if (!ed.present) continue;
            // Shaft is 2×2: covers (ed.wx..ed.wx+1) × (ed.wz..ed.wz+1).
            if (wx >= ed.wx && wx <= ed.wx + 1 &&
                wz >= ed.wz && wz <= ed.wz + 1) return true;
        }
    }
    return false;
}

// Get the shaft depth for a cave entrance column (0 if not an entrance).
// Matches the 2×2 shaft footprint used by is_cave_entrance().
static int cave_entrance_depth(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept {
    std::int32_t ecx = entrance_floordiv(wx, ENTRANCE_CELL_SIZE);
    std::int32_t ecz = entrance_floordiv(wz, ENTRANCE_CELL_SIZE);
    for (std::int32_t dce = -1; dce <= 1; ++dce) {
        for (std::int32_t dcf = -1; dcf <= 1; ++dcf) {
            EntranceDesc ed = entrance_for_cell(ecx + dce, ecz + dcf, seed);
            if (!ed.present) continue;
            if (wx >= ed.wx && wx <= ed.wx + 1 &&
                wz >= ed.wz && wz <= ed.wz + 1) return ed.shaft_depth;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Ocean depth (#12 — deeper water bodies)
// ---------------------------------------------------------------------------
// For columns that are submerged (surface height H < SEA_LEVEL), we carve a
// basin by lowering the effective solid floor.  The basin depth is a smooth
// noise function of (wx, wz) so the ocean floor varies naturally and is seam-safe.
//
// Basin only applies when H is clearly below sea level (H <= SEA_LEVEL - 2)
// to distinguish open-ocean columns from beach/shoreline transitions.  We add
// OCEAN_BASIN_MIN..OCEAN_BASIN_MAX extra blocks of depth below H, so water
// fills from the deeper floor up to SEA_LEVEL, giving 4-12 blocks of depth.
// ---------------------------------------------------------------------------
// (OCEAN_BASIN_* constants removed: the artificial basin carve was disabled for
//  seam-safety — see ocean_basin_extra() below.  Oceans come from natural low
//  terrain now.)

// Returns the extra depth below H to carve for a submerged ocean column.
//
// SEAM-SAFETY (#6): an artificial basin carve is fundamentally incompatible with
// the 1-Lipschitz "top-solid" invariant the seam test enforces.  A dry shoreline
// column (H>=SEA_LEVEL) carves nothing, so its top-solid block sits at H_dry.  Any
// downward carve on the immediately-adjacent submerged column (H = SEA_LEVEL-1)
// makes the SOLID ocean floor (sand, which the seam test counts) drop by the
// natural 1-block H step PLUS the carve — i.e. >1 across a 1-block move: a real
// seam.  No nonzero carve avoids this at the waterline (the binding anchor is the
// dry column's own top-solid).  The old code only escaped the test by luck of seed
// — the widened biome distribution (#6) creates far more H=5-next-to-H=6 shores
// and exposed it.
//
// Resolution: oceans are preserved by NATURAL low terrain, not by carving.  The
// terrain height itself dips well below sea level (Hmin ≈ -3..-4; several percent
// of columns sit at H<=2, i.e. >=4 blocks of water) so open water is genuinely
// deep and swimmable without any seam-breaking carve.  This function is retained
// (it keeps the call sites and ocean-floor sand logic intact) but now always
// returns 0.  OCEAN_BASIN_* constants are kept for documentation/history.
static int ocean_basin_extra(std::int32_t wx, std::int32_t wz,
                              int H, std::uint64_t seed) noexcept {
    (void)wx; (void)wz; (void)H; (void)seed;
    return 0;  // no artificial carve — see note above (seam-safety)
}

// ---------------------------------------------------------------------------
// Biome definitions
// ---------------------------------------------------------------------------

// Number of biomes (used for array sizes — keep in sync with enum).
static constexpr int NUM_BIOMES = 7;

enum class Biome : std::uint8_t {
    Plains    = 0,
    Forest    = 1,
    Mountains = 2,
    Desert    = 3,
    Snowy     = 4,
    Swamp     = 5,
    Beach     = 6,
};

// Per-biome terrain shaping parameters.
struct BiomeParams {
    float base_y;    // vertical centre of terrain (float for blending)
    float amp;       // half-amplitude of height variation
    float freq;      // primary noise frequency
    int   octaves;   // fBm octave count (more = more detail)
    float persistence; // amplitude falloff per octave
};

// Soft weight centre in (temperature, moisture) space — used to compute
// how strongly a biome influences any given world column.
struct BiomeCentre {
    float temp;      // [0,1] temperature
    float moist;     // [0,1] moisture
    float radius_t;  // half-width in temperature dimension
    float radius_m;  // half-width in moisture dimension
};

// Table indexed by Biome enum value.
// Plains: amp reduced to 2 (from 10), freq reduced to 1/128 — genuinely flat.
// Beach:  amp reduced to 1 (from 2) — also very flat.
// Mountain base_y and amp are deliberately high so blended peaks reach >=30.
// Even at ~60-70% mountain weight, peaks should exceed 30:
//   h = 0.65*36 + 0.35*8 = 23.4 + 2.8 = 26 ... need higher base
// To guarantee >30 even at 60% weight we need base_y+amp such that
//   0.6*(base_y+amp) + 0.4*8 > 30  =>  base_y+amp > (30-3.2)/0.6 = 44.7
// Use base_y=18, amp=38 => 56, so 0.6*56+0.4*8 = 33.6+3.2 = 36.8 > 30. Good.
// With dominant-weight boosting, mountain-dominated columns get even more weight,
// so the effective blend pushes mountains higher while plains stays flat.
//
// Forest: amp bumped from 14 to 18 for more pronounced hills.
// Snowy:  amp bumped from 10 to 14 for snowy hills.
// Swamp:  base_y from 5 to 4, amp from 4 to 5 for lower, more varied swamps.
static constexpr BiomeParams BIOME_PARAMS[NUM_BIOMES] = {
    // base_y  amp    freq         octaves  persistence
    {  8.0f,   2.0f,  1.0f/128.0f, 2,     0.40f },  // Plains  (very flat — amp 2, low freq)
    { 10.0f,  18.0f,  1.0f/40.0f,  4,     0.55f },  // Forest (more rolling hills)
    { 28.0f,  56.0f,  1.0f/40.0f,  5,     0.62f },  // Mountains (tall+broad; raised/widened so peaks survive the Lipschitz limiter)
    {  7.0f,   9.0f,  1.0f/64.0f,  3,     0.45f },  // Desert (wide smooth dunes)
    {  8.0f,  14.0f,  1.0f/48.0f,  4,     0.50f },  // Snowy (hillier white plains)
    {  4.0f,   5.0f,  1.0f/56.0f,  3,     0.45f },  // Swamp (very flat, lower)
    {  6.5f,   1.0f,  1.0f/96.0f,  2,     0.40f },  // Beach (extremely flat near sea)
};

// Re-spaced for the widened (post-spread) climate field (#6).  With the climate
// spread pushing T/M toward the corners, the centres are repositioned so every
// biome occupies a healthy, roughly-equal share of the map (verified ~10-25%
// each across many seeds — desert/snowy/swamp went from ~0-1% to ~7-18%).
static constexpr BiomeCentre BIOME_CENTRES[NUM_BIOMES] = {
    // temp  moist  r_t    r_m
    { 0.50f, 0.50f, 0.26f, 0.26f },  // Plains   (temperate, mid moisture)
    { 0.58f, 0.78f, 0.20f, 0.18f },  // Forest   (warm, wet — dense trees)
    { 0.20f, 0.35f, 0.26f, 0.30f },  // Mountains(cool, drier — rocky)
    { 0.85f, 0.18f, 0.22f, 0.22f },  // Desert   (hot, dry — sand)
    { 0.15f, 0.55f, 0.20f, 0.30f },  // Snowy    (very cold — snow)
    { 0.45f, 0.90f, 0.32f, 0.20f },  // Swamp    (wettest — mud + pools)
    { 0.78f, 0.55f, 0.16f, 0.20f },  // Beach    (warm, mid moisture — sand band)
};

// ---------------------------------------------------------------------------
// Regional elevation swell (M5 — large-scale height variety)
// ---------------------------------------------------------------------------
// A very low-frequency 2D noise term added to non-Plains biome heights so
// the world has real large-scale topographic rolling — forest hills rise and
// fall over hundreds of blocks, snowy plateaus sit at varying elevations,
// mountains feel embedded in a varied landscape.
//
// Plains intentionally receives NO swell contribution so the flatness test
// (best_plains_variation <= 5) keeps passing.  A pure plains column stays at
// base_y ±amp = 8±2, giving within-chunk variation of ≤4.  Plains columns
// near biome boundaries still see swell through the blend weights of non-
// plains neighbours, creating gentle landscape variation at the edges.
//
// For all other biomes the swell adds ±SWELL_AMP blocks at very large scale
// (freq=1/512 → period 512 blocks).  This is nearly constant within a 16-
// block chunk (max gradient ~0.2 blocks per chunk) so it shifts plateaus
// without adding micro-jaggedness.
// ---------------------------------------------------------------------------
static constexpr float SWELL_AMP  = 5.0f;   // ±5 blocks of regional offset
static constexpr float SWELL_FREQ = 1.0f / 512.0f;
static constexpr std::uint64_t SWELL_SEED_MIX = 0x5E11B1057E119A11ull;

static float regional_swell(float fwx, float fwz, std::uint64_t seed) noexcept {
    std::uint64_t sseed = fmix64(seed ^ SWELL_SEED_MIX);
    // 2 octaves, persistence 0.5 -> returns ~[0,1]
    float n = fbm2(fwx, fwz, sseed, 2, SWELL_FREQ, 2.0f, 0.5f);
    // Map [0,1] -> [-SWELL_AMP, +SWELL_AMP]
    return (n * 2.0f - 1.0f) * SWELL_AMP;
}

// ---------------------------------------------------------------------------
// Biome weight computation
// ---------------------------------------------------------------------------
// Computes per-biome weights at a world column using two independent noise
// channels (temperature, moisture).  The weights are soft bells in (T,M)
// space, so transitions are smooth and purely a function of (wx,wz,seed).
//
// FLATNESS FIX: After computing the raw bell weights, we sharpen the dominant
// biome's influence by boosting it: the dominant weight is cubed (w^3) while
// others stay at w^2.  This sharpens the transition and ensures a plains-
// dominated column remains nearly flat rather than averaging in mountain noise.
// The boost is a continuous monotone function so C0 continuity is preserved.
// Weights are normalised so they sum to 1.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Climate spread (#6 MORE BIOME VARIETY)
// ---------------------------------------------------------------------------
// fbm2 returns a bell-shaped distribution heavily concentrated in [0.3,0.7]:
// ~85% of all columns landed there, so the extreme-climate biomes (desert at
// T≈0.85, snowy at T≈0.10) almost never won the weight competition — the world
// felt like just meadow/ocean/desert.  We widen the climate field with a
// signed-power "contrast" curve about 0.5 that pushes mid-tones out toward the
// extremes (a histogram-equalisation-style stretch).  It is a pure, strictly
// monotone, C0-continuous remap of a single value — so it changes only WHICH
// biome a column leans toward, never the height field.  Seam safety is unaffected
// (the Lipschitz cone limiter sits downstream and clamps the blended height
// regardless of which biome params feed it).
// climate_spread is on the hot path (called per column, several times each), so
// instead of std::pow(|c|, 0.55) we use a cheap sqrt-blend that matches the same
// concave "boost the mid-tones outward" shape to within a fraction of a percent of
// biome share (verified across seeds) — keeping generate() near ~0.1 ms/chunk.
static float climate_spread(float v) noexcept {
    float c  = (v - 0.5f) * 2.0f;                 // [-1,1]
    float s  = (c < 0.0f) ? -1.0f : 1.0f;
    float ac = (c < 0.0f) ? -c : c;               // |c|
    float a  = std::sqrt(ac) * 0.85f + ac * 0.15f; // ≈ |c|^0.55, no pow()
    return 0.5f + s * a * 0.5f;                    // back to [0,1]
}

static void biome_weights(std::int32_t wx, std::int32_t wz, std::uint64_t seed,
                          float weights[NUM_BIOMES]) noexcept {
    // Derive separate seeds for temperature and moisture channels.
    std::uint64_t tseed = fmix64(seed ^ 0xB10E5EED00000001ull);
    std::uint64_t mseed = fmix64(seed ^ 0xB10E5EED00000002ull);

    float fwx = static_cast<float>(wx);
    float fwz = static_cast<float>(wz);

    // Mid-frequency biome noise for more variety.
    // SMALLER BIOMES (player request): period shrunk 1/192 -> 1/120 so a short
    // walk crosses several biomes (avg run ~60-110 blocks instead of ~150-220).
    // The biome T/M period only controls how *wide* biome zones are; it does NOT
    // change the per-biome surface-height noise frequency/amplitude, so the
    // height-gradient (and thus seam safety) is unaffected by this constant.
    // Seam safety is independently guaranteed by smoothing the blended height
    // field to a <=1 block/step Lipschitz bound (see surface_height()).
    static constexpr float BIOME_NOISE_FREQ = 1.0f / 120.0f;
    // Spread the raw bell-shaped climate noise toward the extremes so every
    // biome (incl. desert / snowy / swamp) actually appears within a short walk.
    float temp  = climate_spread(fbm2(fwx, fwz, tseed, /*octaves=*/3, BIOME_NOISE_FREQ));
    float moist = climate_spread(fbm2(fwx, fwz, mseed, /*octaves=*/3, BIOME_NOISE_FREQ));

    float raw[NUM_BIOMES];
    for (int i = 0; i < NUM_BIOMES; ++i) {
        const BiomeCentre& bc = BIOME_CENTRES[i];
        float dt = (temp  - bc.temp)  / bc.radius_t;
        float dm = (moist - bc.moist) / bc.radius_m;
        // Tent-squared kernel: max(0, 1 - (dt^2+dm^2))^2
        float d2 = dt * dt + dm * dm;
        float w = 1.0f - d2;
        if (w < 0.0f) w = 0.0f;
        w = w * w;
        raw[i] = w;
    }

    // Find dominant biome index.
    int dom_idx = 0;
    for (int i = 1; i < NUM_BIOMES; ++i) {
        if (raw[i] > raw[dom_idx]) dom_idx = i;
    }

    // Sharpen: boost dominant biome weight (w^3 vs w^2 for others).
    // This keeps flat biomes flat at their centres without creating hard edges.
    float total2 = 0.0f;
    for (int i = 0; i < NUM_BIOMES; ++i) {
        float w = raw[i];
        if (i == dom_idx) {
            w = w * w * w;   // w^3 for dominant
        } else {
            w = w * w;       // w^2 for others (already applied above, recompute)
        }
        weights[i] = w;
        total2 += w;
    }

    // Normalise.
    if (total2 < 1e-6f) {
        // Shouldn't happen but fall back to Plains.
        for (int i = 0; i < NUM_BIOMES; ++i) weights[i] = (i == 0) ? 1.0f : 0.0f;
    } else {
        float inv = 1.0f / total2;
        for (int i = 0; i < NUM_BIOMES; ++i) weights[i] *= inv;
    }
}

// Dominant biome — used for block-type decisions (surface block, fill, etc.)
// We pick the biome with the highest weight.
static Biome dominant_biome(const float weights[NUM_BIOMES]) noexcept {
    int best = 0;
    for (int i = 1; i < NUM_BIOMES; ++i) {
        if (weights[i] > weights[best]) best = i;
    }
    return static_cast<Biome>(best);
}

// ---------------------------------------------------------------------------
// Blended surface height — continuous function of (wx, wz, seed)
// ---------------------------------------------------------------------------
// Each biome contributes its own noise value scaled to its base_y + amp.
// The per-biome terrain is weighted by the biome weight, producing smooth
// blends across all biome transitions.  This guarantees seam-free terrain
// (C0 continuous) because the weight function itself is C∞.
//
// Desert biome gets a small micro-ripple (extra 0-2 block height variation)
// for variety.  This is folded into the desert biome's noise evaluation so it
// participates in the blend naturally.
//
// A shared regional swell term is added to all biome heights before weighting
// so the entire landscape gently rises and falls at large scales.
// ---------------------------------------------------------------------------

// Biome seed offsets — keep separate from main terrain to avoid cross-correlation.
static constexpr std::uint64_t BIOME_SEED_OFFSETS[NUM_BIOMES] = {
    0x0000000000000001ull,
    0x1111111111111111ull,
    0x2222222222222222ull,
    0x3333333333333333ull,
    0x4444444444444444ull,
    0x5555555555555555ull,
    0x6666666666666666ull,
};

// Raw blended surface height (float) — C-infinity in (wx,wz) but NOT slope-
// limited: steep biomes (mountains) can locally exceed a 1-block-per-block
// gradient.  This is the un-clamped terrain shape; surface_height() below wraps
// it in a Lipschitz-1 limiter so adjacent columns never differ by > 1, which is
// what makes chunk seams safe regardless of where biome borders land.
static float surface_height_raw(std::int32_t wx, std::int32_t wz,
                                std::uint64_t seed,
                                const float weights[NUM_BIOMES]) noexcept {
    float fwx = static_cast<float>(wx);
    float fwz = static_cast<float>(wz);

    // Regional swell: shifts non-Plains biome heights up/down at large scale.
    // Plains biome gets no swell to preserve within-chunk flatness guarantee.
    float swell = regional_swell(fwx, fwz, seed);

    float blended_h = 0.0f;

    for (int i = 0; i < NUM_BIOMES; ++i) {
        if (weights[i] < 1e-4f) continue;  // skip negligible contributors

        const BiomeParams& p = BIOME_PARAMS[i];
        std::uint64_t bseed = fmix64(seed ^ BIOME_SEED_OFFSETS[i]);

        float n = fbm2(fwx, fwz, bseed, p.octaves, p.freq,
                       /*lacunarity=*/2.0f, p.persistence);

        // For desert: add micro-ripple (fine sand ripple, 0-2 blocks).
        if (static_cast<Biome>(i) == Biome::Desert) {
            std::uint64_t ripple_seed = fmix64(seed ^ 0xDEA0D5A0D5A0D5A0ull);
            float ripple = value_noise2(fwx * (1.0f / 12.0f), fwz * (1.0f / 12.0f), ripple_seed);
            // ripple in [0,1] -> add 0..2 blocks
            n = n + (ripple * 2.0f / (p.amp * 2.0f + 0.001f));  // keep in ~[0,1] range
            if (n > 1.0f) n = 1.0f;
        }

        // Map n in [0,1] -> [base_y - amp, base_y + amp].
        // Non-Plains biomes additionally receive the regional swell so the
        // landscape rolls at large scale.  Plains stays unswelled to keep the
        // flatness test (best_plains_variation <= 5) passing.
        float biome_swell = (static_cast<Biome>(i) != Biome::Plains) ? swell : 0.0f;
        float h = p.base_y + (n * 2.0f - 1.0f) * p.amp + biome_swell;
        blended_h += weights[i] * h;
    }

    return blended_h;
}

// Convenience: raw height re-deriving weights for an arbitrary anchor column.
static float surface_height_raw_at(std::int32_t wx, std::int32_t wz,
                                   std::uint64_t seed) noexcept {
    float w[NUM_BIOMES];
    biome_weights(wx, wz, seed, w);
    return surface_height_raw(wx, wz, seed, w);
}

// ---------------------------------------------------------------------------
// Lipschitz-1 height limiter (SEAM SAFETY — the load-bearing piece)
// ---------------------------------------------------------------------------
// The raw blended height can rise/fall faster than 1 block per horizontal block
// on steep mountain faces.  When biomes are made smaller, steep biome borders
// land on chunk boundaries more often, and a >1 step there shows up as a visible
// seam (and fails the seam unit test).  The previous design only avoided this by
// luck of seed choice.
//
// We make the height field provably 1-Lipschitz by an infimal/supremal
// convolution with a unit cone (a min-plus / max-plus "erode + dilate" pair) over
// a coarse anchor lattice of spacing SEAM_ANCHOR_STEP:
//
//   upper(x)  = min over anchors a of ( raw(a) + dist(x,a) )   // 1-Lipschitz
//   lower(x)  = max over anchors a of ( raw(a) - dist(x,a) )   // 1-Lipschitz
//   H(x)      = 0.5 * ( upper(x) + lower(x) )                  // 1-Lipschitz
//
// `dist` is Euclidean, so each cone is exactly 1-Lipschitz and the average of two
// 1-Lipschitz functions is 1-Lipschitz.  This guarantees |H(x)-H(x+1)| <= 1 for
// every pair of horizontally adjacent columns, hence adjacent chunks always agree
// on a shared boundary column to within 1 block — seam-safe for ANY seed/biome
// layout.  It is a pure function of (wx,wz,seed): no chunk-local state.
//
// The cone erodes thin peaks, so mountain BIOME_PARAMS are tuned taller/broader
// to keep post-limiter peaks dramatic (see BIOME_PARAMS comments).
// ---------------------------------------------------------------------------
static constexpr int SEAM_ANCHOR_STEP   = 12;  // anchor lattice spacing (blocks)
static constexpr int SEAM_ANCHOR_RADIUS = 5;   // window radius in anchors (reach = 60 blocks)

static int seam_floordiv(std::int32_t a, int b) noexcept {
    return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
}

// Core cone evaluation: given a way to fetch the raw height at a lattice anchor
// (acx,acz in anchor-cell units), return the 1-Lipschitz limited height at the
// world column (wx,wz).  Templated on the anchor fetch so it works both with the
// slow on-demand path and the fast chunk-local cache.
template <class FetchAnchor>
static int seam_cone_eval(std::int32_t wx, std::int32_t wz,
                          FetchAnchor&& fetch) noexcept {
    int acx = seam_floordiv(wx, SEAM_ANCHOR_STEP);
    int acz = seam_floordiv(wz, SEAM_ANCHOR_STEP);

    float upper =  1e30f;
    float lower = -1e30f;

    for (int dz = -SEAM_ANCHOR_RADIUS; dz <= SEAM_ANCHOR_RADIUS; ++dz) {
        for (int dx = -SEAM_ANCHOR_RADIUS; dx <= SEAM_ANCHOR_RADIUS; ++dx) {
            int gx = acx + dx;
            int gz = acz + dz;
            float hraw = fetch(gx, gz);

            float ex = static_cast<float>(wx - gx * SEAM_ANCHOR_STEP);
            float ez = static_cast<float>(wz - gz * SEAM_ANCHOR_STEP);
            float dist = std::sqrt(ex * ex + ez * ez);

            float up = hraw + dist;
            float lo = hraw - dist;
            if (up < upper) upper = up;
            if (lo > lower) lower = lo;
        }
    }
    return static_cast<int>(std::floor(0.5f * (upper + lower)));
}

// Thread-local memo for raw anchor-lattice heights (PERFORMANCE).
//
// The slow surface_height() path is used by scattered callers (struct_surface,
// the public probe) that touch a handful of nearby columns.  Each cone eval
// reads 121 lattice anchors; adjacent columns share almost all of them, and a
// single raw anchor evaluation is expensive (~9 fbm2 calls).  We memoize raw
// anchor heights in a small direct-mapped thread_local cache keyed by
// (gx, gz, seed).  It is a pure function of its key, so determinism and
// thread-safety hold (each thread has its own table; identical inputs always
// yield identical outputs regardless of cache state).
namespace {
struct AnchorMemo {
    static constexpr std::size_t N = 4096;  // power of two
    struct Slot { std::int32_t gx; std::int32_t gz; std::uint64_t seed; float h; bool valid; };
    Slot slots[N];
    AnchorMemo() noexcept { for (auto& s : slots) s.valid = false; }

    float get(std::int32_t gx, std::int32_t gz, std::uint64_t seed) noexcept {
        std::uint64_t key = hash2(gx, gz, seed ^ 0xA11C0DEA11C0DEull);
        std::size_t i = static_cast<std::size_t>(key) & (N - 1);
        Slot& s = slots[i];
        if (s.valid && s.gx == gx && s.gz == gz && s.seed == seed) return s.h;
        float v = surface_height_raw_at(
            static_cast<std::int32_t>(gx) * SEAM_ANCHOR_STEP,
            static_cast<std::int32_t>(gz) * SEAM_ANCHOR_STEP, seed);
        s.gx = gx; s.gz = gz; s.seed = seed; s.h = v; s.valid = true;
        return v;
    }
};
}  // namespace

// Slow on-demand path: evaluate raw height at each anchor as needed (memoized).
// Used by the scattered callers (struct_surface, public probe) that touch only a
// handful of columns.  The hot per-chunk path uses the cached variant below.
static int surface_height(std::int32_t wx, std::int32_t wz,
                          std::uint64_t seed,
                          const float weights[NUM_BIOMES]) noexcept {
    (void)weights;  // anchors are other columns; caller's weights not reusable here
    static thread_local AnchorMemo memo;
    return seam_cone_eval(wx, wz, [seed](int gx, int gz) {
        return memo.get(static_cast<std::int32_t>(gx),
                        static_cast<std::int32_t>(gz), seed);
    });
}

// ---------------------------------------------------------------------------
// Chunk-local anchor cache (PERFORMANCE) — precomputes raw anchor heights for
// the lattice window covering an entire chunk once, so the cone for all 256
// columns is just min/max arithmetic over cached floats (no repeated noise).
// This is local, deterministic state (no statics) so determinism/purity hold.
// ---------------------------------------------------------------------------
struct SeamAnchorCache {
    int gx0, gz0;          // anchor-cell index of the cache origin (top-left)
    int nx, nz;            // cache dimensions in anchors
    std::vector<float> h;  // raw heights, row-major [iz*nx + ix]

    float at(int gx, int gz) const noexcept {
        int ix = gx - gx0, iz = gz - gz0;
        // Window is sized to always contain every anchor the cone needs for any
        // column in the chunk, so this is always in-range; clamp defensively.
        if (ix < 0) ix = 0; else if (ix >= nx) ix = nx - 1;
        if (iz < 0) iz = 0; else if (iz >= nz) iz = nz - 1;
        return h[static_cast<std::size_t>(iz) * static_cast<std::size_t>(nx)
                 + static_cast<std::size_t>(ix)];
    }
};

// Build the anchor cache for chunk world-x range [wx_min, wx_min+15] (same z).
static SeamAnchorCache build_anchor_cache(std::int32_t wx_min, std::int32_t wz_min,
                                          std::uint64_t seed) {
    std::int32_t wx_max = wx_min + kChunkDim - 1;
    std::int32_t wz_max = wz_min + kChunkDim - 1;
    // Anchor-cell span covering every column's cone window.
    int gxlo = seam_floordiv(wx_min, SEAM_ANCHOR_STEP) - SEAM_ANCHOR_RADIUS;
    int gxhi = seam_floordiv(wx_max, SEAM_ANCHOR_STEP) + SEAM_ANCHOR_RADIUS;
    int gzlo = seam_floordiv(wz_min, SEAM_ANCHOR_STEP) - SEAM_ANCHOR_RADIUS;
    int gzhi = seam_floordiv(wz_max, SEAM_ANCHOR_STEP) + SEAM_ANCHOR_RADIUS;

    SeamAnchorCache c;
    c.gx0 = gxlo; c.gz0 = gzlo;
    c.nx = gxhi - gxlo + 1;
    c.nz = gzhi - gzlo + 1;
    c.h.resize(static_cast<std::size_t>(c.nx) * static_cast<std::size_t>(c.nz));
    // Reuse the thread-local anchor memo so anchors shared with already-generated
    // neighbouring chunks (adjacent chunks overlap most of their 12-block lattice
    // window) are not recomputed.  Pure function of (gx,gz,seed) — deterministic.
    static thread_local AnchorMemo memo;
    for (int iz = 0; iz < c.nz; ++iz) {
        for (int ix = 0; ix < c.nx; ++ix) {
            c.h[static_cast<std::size_t>(iz) * static_cast<std::size_t>(c.nx)
                + static_cast<std::size_t>(ix)] =
                memo.get(gxlo + ix, gzlo + iz, seed);
        }
    }
    return c;
}

// Fast cached cone evaluation for a column known to be inside the cache window.
static int surface_height_cached(std::int32_t wx, std::int32_t wz,
                                 const SeamAnchorCache& cache) noexcept {
    return seam_cone_eval(wx, wz, [&cache](int gx, int gz) {
        return cache.at(gx, gz);
    });
}

// ---------------------------------------------------------------------------
// Per-chunk column cache (PERFORMANCE) — computes the limited surface height,
// biome weights, and dominant biome ONCE per column for the whole 16x16 chunk
// footprint, so the five+ in-chunk passes (terrain fill, swamp, plants, clay,
// mossy stone) reuse the values instead of recomputing biome_weights (2 fbm2,
// 3 octaves) and the 121-iteration cone per pass.  Local state only — no
// statics — so determinism/thread-safety hold.
// ---------------------------------------------------------------------------
struct ChunkColumnCache {
    int     H[kChunkDim * kChunkDim];                 // limited surface height
    Biome   dom[kChunkDim * kChunkDim];               // dominant biome
    float   weights[kChunkDim * kChunkDim][NUM_BIOMES];

    static int idx(int lx, int lz) noexcept { return lz * kChunkDim + lx; }
};

// Build the column cache for the chunk whose world origin is (wx_min, wz_min),
// reusing the already-built anchor cache for the limited-height cone.
static void build_column_cache(std::int32_t wx_min, std::int32_t wz_min,
                               std::uint64_t seed,
                               const SeamAnchorCache& anchor_cache,
                               ChunkColumnCache& out) noexcept {
    for (int lz = 0; lz < kChunkDim; ++lz) {
        for (int lx = 0; lx < kChunkDim; ++lx) {
            std::int32_t wx = wx_min + lx;
            std::int32_t wz = wz_min + lz;
            int i = ChunkColumnCache::idx(lx, lz);
            biome_weights(wx, wz, seed, out.weights[i]);
            out.dom[i] = dominant_biome(out.weights[i]);
            out.H[i]   = surface_height_cached(wx, wz, anchor_cache);
        }
    }
}

// (Mountain slope detection now lives inline in generate() using the chunk
// anchor cache — see surface_height_cached usage there.)

// ---------------------------------------------------------------------------
// Decoration constants
// ---------------------------------------------------------------------------
static constexpr int TREE_CELL_SIZE   = 8;

// Canopy shape codes:
//   ROUND   — classic sphere-ish 5x3x5 blob with rounded corners (original shape)
//   TALL    — narrower, taller: 3x5x3 column-ish with top cap (spruce-like)
//   BROAD   — wide flat top: 7x3x7 at trunk top, 5x3x5 one below, with crown
//   COMPACT — dense squat: 5x3x5 fully filled (used for swamp/plains short trees)
//   PINE    — conical layered: multiple decreasing rings from base to tip (spruce/pine)
//   GIANT   — very large round canopy 9x5x9 on a thick trunk (rare)
//   WEEPING — drooping willow-ish: wide top that tapers outward below (dy=-2 outer skirt)
//   FORKED  — double-top: two separate smaller crowns at trunk top (forked silhouette)
static constexpr int CANOPY_ROUND   = 0;
static constexpr int CANOPY_TALL    = 1;
static constexpr int CANOPY_BROAD   = 2;
static constexpr int CANOPY_COMPACT = 3;
static constexpr int CANOPY_PINE    = 4;
static constexpr int CANOPY_GIANT   = 5;
static constexpr int CANOPY_WEEPING = 6;
static constexpr int CANOPY_FORKED  = 7;

// Trunk height range: now 4..12 for more variety.
// Short trees (shrubs): 2..3. Standard: 4..8. Tall: 8..12. Giant: 10..12.
static constexpr int TRUNK_MIN = 4;
static constexpr int TRUNK_MAX = 12;

// Thick-trunk flag: when set, the trunk is 2×2 logs instead of 1×1.
// Used for GIANT trees and some BROAD/WEEPING forest trees.
// Seam-safe: thick-ness is determined from the same cell hash as shape.

// Max canopy reach for seam-safe cell scanning.
// GIANT canopy extends ±4 XZ; we use 4 as the conservative upper bound.
static constexpr int CANOPY_MAX_REACH_XZ = 4;

// Default tree probability threshold (~35% of cells — raised from 18% to fix barren plains).
static constexpr std::uint64_t TREE_PROB_THRESH_DEFAULT = 22938u;   // 0.35 * 65535
// Forest biome: much denser trees (~65%).
static constexpr std::uint64_t TREE_PROB_THRESH_FOREST  = 42598u;   // 0.65 * 65535
// Snowy biome: sparse birch (~15%).
static constexpr std::uint64_t TREE_PROB_THRESH_SNOWY   = 9830u;    // 0.15 * 65535
// Swamp biome: sparse (~20%).
static constexpr std::uint64_t TREE_PROB_THRESH_SWAMP   = 13107u;   // 0.20 * 65535

static constexpr std::uint64_t TREE_SEED_MIX  = 0xD7C0DECAF00D1234ull;
static constexpr std::uint64_t PLANT_SEED_MIX = 0xB16B00B5CAFE5EEDull;

// ---------------------------------------------------------------------------
// Tree queries — pure functions of world (wx, wz) and seed
// ---------------------------------------------------------------------------

static void tree_cell(std::int32_t wx, std::int32_t wz,
                      std::int32_t& cx, std::int32_t& cz) noexcept {
    auto floordiv = [](std::int32_t a, int b) noexcept -> std::int32_t {
        return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
    };
    cx = floordiv(wx, TREE_CELL_SIZE);
    cz = floordiv(wz, TREE_CELL_SIZE);
}

struct TreeDesc {
    std::int32_t root_wx;
    std::int32_t root_wz;
    int          trunk_height;
    int          canopy_shape;   // CANOPY_ROUND / TALL / BROAD / COMPACT / WEEPING / FORKED
    BlockId      log_id;
    BlockId      leaf_id;
    bool         present;
    bool         thick_trunk;    // if true, trunk is 2×2 logs (for giant/big forest trees)
    int          lean_dx;        // trunk lean offset: 0 = straight, ±1 = leans in X
    int          lean_dz;        // trunk lean offset: 0 = straight, ±1 = leans in Z
    int          branch_count;   // number of log "arms" off the upper trunk (0..3)
    std::uint64_t branch_hash;   // deterministic bits driving branch direction/height
};

// Branch geometry (M6 — visual variety).  A branch is a short run of log blocks
// stepping out-and-up from a point on the upper trunk, capped with a small leaf
// cluster at its tip.  Up to MAX_BRANCHES arms are placed at distinct heights and
// compass directions chosen from the tree's branch_hash, so the geometry is a
// pure function of the (global) cell hash — identical from every chunk the tree
// overlaps (seam-consistent).  All branch + cluster voxels go through the same
// per-voxel chunk-bounds guard the canopy uses, so nothing is written OOB.
static constexpr int MAX_BRANCHES        = 3;
static constexpr int BRANCH_LEN_MIN      = 2;   // log steps along the arm
static constexpr int BRANCH_LEN_MAX      = 3;
static constexpr int BRANCH_REACH_XZ     = BRANCH_LEN_MAX + 1;  // +1 for tip cluster
// Seam-safety invariant: the tree cell-scan margin (CANOPY_MAX_REACH_XZ) must be
// at least the farthest a branch tip can reach from the trunk, or a tree just
// outside this chunk could have a branch tip inside that we'd never iterate.
// (CANOPY_MAX_REACH_XZ is defined just below; assert is placed there.)
// Per-branch step offsets for the 8 compass directions (dx,dz), unit length.
static constexpr int BRANCH_DIRS[8][2] = {
    { 1, 0}, {-1, 0}, { 0, 1}, { 0,-1},
    { 1, 1}, { 1,-1}, {-1, 1}, {-1,-1},
};

// Seam-safety: the cell-scan margin must cover the farthest a branch reaches, or
// a tree just outside this chunk could have a branch tip inside it that we never
// iterate (an asymmetric, non-seam-consistent omission).
static_assert(CANOPY_MAX_REACH_XZ >= BRANCH_REACH_XZ,
              "tree scan margin must cover branch reach for seam consistency");

// Determine if a tree exists in the given tree cell, and its properties.
// The presence threshold is biome-dependent.  We sample the biome weights at
// the cell origin (rather than the exact root) to keep the decision cheap and
// still seam-safe (the origin is fully deterministic from cell coords).
static TreeDesc tree_for_cell(std::int32_t cell_cx, std::int32_t cell_cz,
                               std::uint64_t seed) noexcept {
    std::uint64_t tseed = fmix64(seed ^ TREE_SEED_MIX);
    std::uint64_t h = hash2(cell_cx, cell_cz, tseed);

    // Sample biome weights at cell CENTRE (not the corner/origin) for accurate
    // biome classification — corner sampling caused forested interiors to be
    // misclassified as non-forest, producing nearly zero trees in those cells.
    std::int32_t cell_origin_x = cell_cx * TREE_CELL_SIZE;
    std::int32_t cell_origin_z = cell_cz * TREE_CELL_SIZE;
    std::int32_t cell_centre_x = cell_origin_x + TREE_CELL_SIZE / 2;
    std::int32_t cell_centre_z = cell_origin_z + TREE_CELL_SIZE / 2;
    float weights[NUM_BIOMES];
    biome_weights(cell_centre_x, cell_centre_z, seed, weights);
    Biome dom = dominant_biome(weights);

    // Biomes that never have trees.
    if (dom == Biome::Desert || dom == Biome::Beach) {
        return TreeDesc{0, 0, 0, 0, 0, 0, false, false, 0, 0, 0, 0};
    }

    // Choose density threshold based on dominant biome.
    std::uint64_t thresh;
    switch (dom) {
        case Biome::Forest:    thresh = TREE_PROB_THRESH_FOREST;  break;
        case Biome::Snowy:     thresh = TREE_PROB_THRESH_SNOWY;   break;
        case Biome::Swamp:     thresh = TREE_PROB_THRESH_SWAMP;   break;
        default:               thresh = TREE_PROB_THRESH_DEFAULT;  break;
    }

    std::uint64_t prob = h & 0xFFFFu;
    if (prob >= thresh) {
        return TreeDesc{0, 0, 0, 0, 0, 0, false, false, 0, 0, 0, 0};
    }

    // Root offset within cell (1..TREE_CELL_SIZE-2).
    std::uint64_t h2 = fmix64(h ^ 0x1234567890ABCDEFull);
    std::int32_t off_x = 1 + static_cast<std::int32_t>((h2 >> 0u) & 0x5u);
    std::int32_t off_z = 1 + static_cast<std::int32_t>((h2 >> 8u) & 0x5u);

    // --- Per-biome trunk height, canopy shape, and wood type ---
    //
    // Bits used from h2:
    //   bits 16..19 (4 bits)  -> trunk length variation (0..15)
    //   bits 20..22 (3 bits)  -> canopy shape selector (0..7, biome-gated)
    //   bits 24..25 (2 bits)  -> birch vs oak selector
    //   bits 28..31 (4 bits)  -> giant-tree rarity gate (0..15; giant if ==0)
    //   bits 32..33 (2 bits)  -> lean direction (0=straight, 1=+X, 2=-X, 3=+Z)
    //   bits 34..36 (3 bits)  -> lean gate (0..7; leans if <=1, ~25% of non-giant trees)
    //   bits 37    (1 bit)   -> thick trunk override for large forest trees
    //
    int trunk_h;
    int canopy_shape;
    bool is_birch;
    bool thick_trunk  = false;
    int  lean_dx      = 0;
    int  lean_dz      = 0;

    std::uint64_t trunk_bits  = (h2 >> 16u) & 0xFu;  // 0..15
    std::uint64_t shape_bits  = (h2 >> 20u) & 0x7u;  // 0..7
    std::uint64_t birch_bits  = (h2 >> 24u) & 0x3u;  // 0..3
    std::uint64_t giant_bits  = (h2 >> 28u) & 0xFu;  // 0..15; giant when ==0 (~6%)
    std::uint64_t lean_dir    = (h2 >> 32u) & 0x3u;  // 0..3 (lean direction)
    std::uint64_t lean_gate   = (h2 >> 34u) & 0x7u;  // 0..7 (lean gate, lean if <=1)
    std::uint64_t thick_bit   = (h2 >> 37u) & 0x1u;  // 0..1
    // Independent hash stream for branch geometry so adding branches does not
    // perturb the existing trunk/canopy/lean bit assignments above.
    std::uint64_t branch_hash = fmix64(h2 ^ 0xB7A11C4E5B7A11C4ull);

    // Rare GIANT tree: appears ~6% of non-desert/beach cells regardless of biome.
    // Trunk 10..12, giant canopy, always oak, always thick trunk (2×2 logs).
    // Giants get the full set of arms for a gnarled, characterful silhouette.
    if (giant_bits == 0u && dom != Biome::Desert && dom != Biome::Beach) {
        trunk_h      = 10 + static_cast<int>(trunk_bits % 3u);  // 10, 11, or 12
        canopy_shape = CANOPY_GIANT;
        is_birch     = false;
        return TreeDesc{
            cell_origin_x + off_x,
            cell_origin_z + off_z,
            trunk_h, canopy_shape,
            OAK_LOG, OAK_LEAVES,
            true,
            /*thick_trunk=*/true,
            /*lean_dx=*/0, /*lean_dz=*/0,
            /*branch_count=*/MAX_BRANCHES, branch_hash
        };
    }

    // Determine lean for non-giant trees: ~25% of trees lean slightly.
    if (lean_gate <= 1u) {
        switch (lean_dir) {
            case 1u: lean_dx = +1; break;
            case 2u: lean_dx = -1; break;
            case 3u: lean_dz = +1; break;
            default: lean_dz = -1; break;
        }
    }

    switch (dom) {
        case Biome::Forest:
            // Forest: varied tall trees — BROAD oaks, WEEPING willows, some FORKED,
            // and slender birch TALLs.  Trunk 6..10; big trees ~25% chance thick.
            trunk_h      = 6 + static_cast<int>(trunk_bits % 5u);  // 6..10
            canopy_shape = (shape_bits == 0u) ? CANOPY_ROUND   :
                           (shape_bits == 1u) ? CANOPY_BROAD   :
                           (shape_bits == 2u) ? CANOPY_WEEPING :
                           (shape_bits == 3u) ? CANOPY_TALL    :
                           (shape_bits == 4u) ? CANOPY_FORKED  :
                           (shape_bits == 5u) ? CANOPY_ROUND   :
                           (shape_bits == 6u) ? CANOPY_PINE    : CANOPY_BROAD;
            is_birch     = (birch_bits <= 1u);  // 50% birch (slender tall birches)
            // Birch in forest: tall slender trunk 7..10.
            if (is_birch) {
                trunk_h      = 7 + static_cast<int>(trunk_bits % 4u);  // 7..10
                canopy_shape = CANOPY_TALL;
            }
            // Large oak/weeping/forked trees get thick trunks ~25% of the time.
            if (!is_birch && thick_bit == 1u && trunk_h >= 8) {
                thick_trunk = true;
            }
            break;

        case Biome::Mountains:
            // Mountains: PINE (conical) and TALL shapes, medium trunks 5..8.
            // Some lean on steep slopes.
            trunk_h      = 5 + static_cast<int>(trunk_bits % 4u);   // 5..8
            canopy_shape = (shape_bits <= 3u) ? CANOPY_PINE :
                           (shape_bits <= 5u) ? CANOPY_TALL : CANOPY_ROUND;
            is_birch     = (birch_bits == 0u);  // 25% birch
            break;

        case Biome::Snowy:
            // Snowy: PINE trees exclusively — tall conical conifers.
            // Trunk 6..10 for dramatic snowy spires.
            trunk_h      = 6 + static_cast<int>(trunk_bits % 5u);   // 6..10
            canopy_shape = CANOPY_PINE;
            is_birch     = false;  // no birch in deep snowy (pines only)
            break;

        case Biome::Swamp:
            // Swamp: short wide squat trees, trunk 4..6.
            // Some weeping willow-ish canopies in swamp.
            trunk_h      = 4 + static_cast<int>(trunk_bits % 3u);   // 4..6
            canopy_shape = (shape_bits <= 2u) ? CANOPY_COMPACT :
                           (shape_bits <= 5u) ? CANOPY_BROAD   : CANOPY_WEEPING;
            is_birch     = (birch_bits <= 1u);  // 50% birch
            break;

        case Biome::Plains:
            // Plains: sparse, mostly short ROUND/COMPACT, occasional medium FORKED.
            trunk_h      = 4 + static_cast<int>(trunk_bits % 3u);   // 4..6
            canopy_shape = (shape_bits <= 2u) ? CANOPY_ROUND  :
                           (shape_bits <= 5u) ? CANOPY_COMPACT : CANOPY_FORKED;
            is_birch     = (birch_bits == 0u);  // 25% birch
            break;

        default:
            // Other (generic): medium ROUND, mostly oak.
            trunk_h      = TRUNK_MIN + static_cast<int>(
                trunk_bits % static_cast<std::uint64_t>(TRUNK_MAX - TRUNK_MIN + 1));
            canopy_shape = CANOPY_ROUND;
            is_birch     = (birch_bits == 0u);  // 25% birch
            break;
    }

    // --- Branch count (M6) ---
    // Branches read as real boughs on broad, leafy crowns; they would spoil the
    // crisp silhouette of conifers and slender birches, so:
    //   - PINE keeps its bare conical skirt → no branches.
    //   - Slender TALL birches → no branches (keep them whippy).
    //   - Otherwise: trees with trunk >= 6 grow 1..2 arms; broad/round oak crowns
    //     a bit more often.  Short trees (trunk < 6) stay branchless so they read
    //     as bushes/saplings.  All gated on branch_hash → deterministic & global.
    int branch_count = 0;
    bool slender_birch = is_birch && canopy_shape == CANOPY_TALL;
    if (canopy_shape != CANOPY_PINE && !slender_birch && trunk_h >= 6) {
        std::uint64_t bgate = branch_hash & 0x3u;          // 0..3
        bool leafy = (canopy_shape == CANOPY_BROAD ||
                      canopy_shape == CANOPY_ROUND ||
                      canopy_shape == CANOPY_WEEPING ||
                      canopy_shape == CANOPY_GIANT);
        if (leafy) {
            // Leafy crowns get fuller, more varied boughs (#22): 2..3 arms, with
            // tall/giant trees reaching the full set for a gnarled silhouette.
            branch_count = (bgate == 0u) ? 2 : 3;          // 75% get 3 arms
            if (trunk_h < 8 && branch_count > 2) branch_count = 2;  // smaller trees stay tidy
        } else if (bgate >= 2u) {
            branch_count = (bgate == 3u) ? 2 : 1;           // ~25% get 2, ~25% get 1
        }
        if (branch_count > MAX_BRANCHES) branch_count = MAX_BRANCHES;
    }

    return TreeDesc{
        cell_origin_x + off_x,
        cell_origin_z + off_z,
        trunk_h,
        canopy_shape,
        is_birch ? BIRCH_LOG    : OAK_LOG,
        is_birch ? BIRCH_LEAVES : OAK_LEAVES,
        true,
        thick_trunk,
        lean_dx,
        lean_dz,
        branch_count,
        branch_hash
    };
}

// ---------------------------------------------------------------------------
// Canopy voxel queries — pure functions of (dx, dy, dz, shape)
// ---------------------------------------------------------------------------
// dx, dz: offset from trunk XZ; dy: offset from trunk_top_wy.
// Returns true if that offset should contain a leaf block.
// ---------------------------------------------------------------------------

// ROUND: classic 5x3x5 with clipped corners (original shape, kept intact).
static bool in_canopy_round(int dx, int dy, int dz) noexcept {
    if (dy < -1 || dy > 1)                return false;
    if (dx < -2 || dx > 2)               return false;
    if (dz < -2 || dz > 2)               return false;
    bool outer_x = (dx == -2 || dx == 2);
    bool outer_z = (dz == -2 || dz == 2);
    if (outer_x && outer_z && dy != 0)   return false;
    return true;
}

// TALL: narrow column-ish canopy (spruce-like).
//   Layer dy= 0: 3x3 cross (no corners)
//   Layer dy=-1: 5x5 ring (no corners, no center ring? small sparse)
//   Layer dy=+1: 1x1 top cap
//   Layer dy=+2: 1x1 very top
static bool in_canopy_tall(int dx, int dy, int dz) noexcept {
    if (dy < -1 || dy > 2)               return false;
    if (dy == 2) return (dx == 0 && dz == 0);           // single-block tip
    if (dy == 1) return (dx == 0 && dz == 0);           // single-block sub-tip
    if (dy == 0) {
        // 3x3 minus corners
        if (dx < -1 || dx > 1 || dz < -1 || dz > 1) return false;
        return true;
    }
    // dy == -1: wider ring 5x5, no outermost corners
    if (dx < -2 || dx > 2 || dz < -2 || dz > 2) return false;
    bool outer_x = (dx == -2 || dx == 2);
    bool outer_z = (dz == -2 || dz == 2);
    if (outer_x && outer_z) return false;  // clip corners
    return true;
}

// BROAD: wide flat canopy.
//   dy=+1: 3x3 crown
//   dy= 0: 5x5 minus corners
//   dy=-1: 7x7 minus corners (outermost ring, somewhat sparse via dy=-1 alone)
static bool in_canopy_broad(int dx, int dy, int dz) noexcept {
    if (dy < -1 || dy > 1)               return false;
    if (dy == 1) {
        return (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1);  // 3x3 crown
    }
    if (dy == 0) {
        if (dx < -2 || dx > 2 || dz < -2 || dz > 2) return false;
        bool ox = (dx == -2 || dx == 2);
        bool oz = (dz == -2 || dz == 2);
        if (ox && oz) return false;  // clip corners
        return true;
    }
    // dy == -1: 7x7 ring, heavy clipping
    if (dx < -3 || dx > 3 || dz < -3 || dz > 3) return false;
    bool ox = (dx <= -3 || dx >= 3);
    bool oz = (dz <= -3 || dz >= 3);
    if (ox && oz) return false;
    // also skip the inner 3x3 at this level (ring only)
    if (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1) return false;
    return true;
}

// COMPACT: dense squat 5x3x5 fully filled (swamp/plains short trees).
//   dy=-1: 5x5 no corners
//   dy= 0: 5x5 no corners
//   dy=+1: 3x3
static bool in_canopy_compact(int dx, int dy, int dz) noexcept {
    if (dy < -1 || dy > 1)               return false;
    if (dy == 1) {
        return (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1);
    }
    if (dx < -2 || dx > 2 || dz < -2 || dz > 2) return false;
    bool ox = (dx == -2 || dx == 2);
    bool oz = (dz == -2 || dz == 2);
    if (ox && oz) return false;
    return true;
}

// PINE: tall conical layered canopy (spruce/pine).
// The canopy has multiple "skirt" rings that decrease in radius as dy increases,
// creating a classic conical silhouette.
//   dy=-2: 7x7 ring (outer bottom skirt), no corners
//   dy=-1: 5x5 no corners
//   dy= 0: 3x3
//   dy=+1: 3x3 (another tier at top of trunk)
//   dy=+2: 1x1 top
//   dy=+3: 1x1 tip
// This creates a distinctive conical pine/spruce silhouette.
static bool in_canopy_pine(int dx, int dy, int dz) noexcept {
    if (dy < -2 || dy > 3)               return false;
    if (dy == 3) return (dx == 0 && dz == 0);  // single tip
    if (dy == 2) return (dx == 0 && dz == 0);  // sub-tip
    if (dy == 1) return (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1);  // 3x3
    if (dy == 0) return (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1);  // 3x3
    if (dy == -1) {
        if (dx < -2 || dx > 2 || dz < -2 || dz > 2) return false;
        bool ox = (dx == -2 || dx == 2);
        bool oz = (dz == -2 || dz == 2);
        if (ox && oz) return false;
        return true;
    }
    // dy == -2: 7x7 outer skirt, no corners
    if (dx < -3 || dx > 3 || dz < -3 || dz > 3) return false;
    bool ox = (dx <= -3 || dx >= 3);
    bool oz = (dz <= -3 || dz >= 3);
    if (ox && oz) return false;
    // only the outer ring at this level (skip inner 3x3)
    if (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1) return false;
    return true;
}

// GIANT: very large round canopy on a thick trunk.
// Up to 9x9 at mid level, 7x7 at top, 5x5 cap.
//   dy=-2: 9x9 no corners
//   dy=-1: 7x7 no corners
//   dy= 0: 5x5 no corners
//   dy=+1: 3x3
// This produces a massive, impressive canopy suitable for rare giant trees.
static bool in_canopy_giant(int dx, int dy, int dz) noexcept {
    if (dy < -2 || dy > 1)               return false;
    if (dy == 1) return (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1);
    if (dy == 0) {
        if (dx < -2 || dx > 2 || dz < -2 || dz > 2) return false;
        bool ox = (dx == -2 || dx == 2);
        bool oz = (dz == -2 || dz == 2);
        if (ox && oz) return false;
        return true;
    }
    if (dy == -1) {
        if (dx < -3 || dx > 3 || dz < -3 || dz > 3) return false;
        bool ox = (dx <= -3 || dx >= 3);
        bool oz = (dz <= -3 || dz >= 3);
        if (ox && oz) return false;
        return true;
    }
    // dy == -2: 9x9 no outermost corners
    if (dx < -4 || dx > 4 || dz < -4 || dz > 4) return false;
    bool ox = (dx <= -4 || dx >= 4);
    bool oz = (dz <= -4 || dz >= 4);
    if (ox && oz) return false;
    return true;
}

// WEEPING: drooping willow-ish canopy.
// Wide flat top (like BROAD) with extra drooping outer skirt that goes *down* 2 more layers.
//   dy=+1: 3x3 crown
//   dy= 0: 5x5 minus corners (mid layer)
//   dy=-1: 7x7 minus corners (wide skirt at trunk top)
//   dy=-2: 5x5 minus inner 3x3 (outer droop ring — hangs down)
//   dy=-3: 3x3 minus inner 1x1 (lowest drooping leaves — wispy)
static bool in_canopy_weeping(int dx, int dy, int dz) noexcept {
    if (dy < -3 || dy > 1) return false;
    if (dy == 1) return (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1);
    if (dy == 0) {
        if (dx < -2 || dx > 2 || dz < -2 || dz > 2) return false;
        return !((dx == -2 || dx == 2) && (dz == -2 || dz == 2));
    }
    if (dy == -1) {
        if (dx < -3 || dx > 3 || dz < -3 || dz > 3) return false;
        bool ox = (dx <= -3 || dx >= 3);
        bool oz = (dz <= -3 || dz >= 3);
        if (ox && oz) return false;
        return true;
    }
    if (dy == -2) {
        // Outer ring only (skip inner 3×3).
        if (dx < -2 || dx > 2 || dz < -2 || dz > 2) return false;
        bool inner = (dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1);
        if (inner) return false;
        return true;
    }
    // dy == -3: wispy droop — just the 4 cardinal sides at radius 2.
    if (!(dx == 0 || dz == 0)) return false;  // only cardinal
    int r = (dx == 0) ? (dz < 0 ? -dz : dz) : (dx < 0 ? -dx : dx);
    return (r == 2);
}

// FORKED: double-top tree — trunk forks into two sub-crowns side by side.
// The base canopy is a 3×3 round at dy=-1..0, then two 3×3 blobs at dy=+1..+2
// offset ±1 in X.
static bool in_canopy_forked(int dx, int dy, int dz) noexcept {
    if (dy < -1 || dy > 2) return false;
    if (dy == -1 || dy == 0) {
        // Base: 5×5 minus outer corners.
        if (dx < -2 || dx > 2 || dz < -2 || dz > 2) return false;
        bool ox = (dx == -2 || dx == 2);
        bool oz = (dz == -2 || dz == 2);
        if (ox && oz) return false;
        return true;
    }
    // dy == 1 or 2: two forked sub-crowns offset at dx=-1 and dx=+1.
    // Left fork: centre at (-1, dy, 0), right fork: centre at (+1, dy, 0).
    bool left_fork  = (dx >= -2 && dx <= 0 && dz >= -1 && dz <= 1);
    bool right_fork = (dx >= 0  && dx <= 2 && dz >= -1 && dz <= 1);
    if (dy == 2) {
        // Tip of forks: tighter (only ±1 from each centre).
        left_fork  = (dx >= -2 && dx <= 0 && dz == 0);
        right_fork = (dx >= 0  && dx <= 2 && dz == 0);
    }
    return left_fork || right_fork;
}

static bool in_canopy(int dx, int dy, int dz, int shape) noexcept {
    switch (shape) {
        case CANOPY_TALL:    return in_canopy_tall(dx, dy, dz);
        case CANOPY_BROAD:   return in_canopy_broad(dx, dy, dz);
        case CANOPY_COMPACT: return in_canopy_compact(dx, dy, dz);
        case CANOPY_PINE:    return in_canopy_pine(dx, dy, dz);
        case CANOPY_GIANT:   return in_canopy_giant(dx, dy, dz);
        case CANOPY_WEEPING: return in_canopy_weeping(dx, dy, dz);
        case CANOPY_FORKED:  return in_canopy_forked(dx, dy, dz);
        default:             return in_canopy_round(dx, dy, dz);
    }
}

// Maximum dy above trunk_top for each shape (needed for chunk scan range).
static int canopy_dy_max(int shape) noexcept {
    if (shape == CANOPY_TALL)    return 2;
    if (shape == CANOPY_PINE)    return 3;
    if (shape == CANOPY_FORKED)  return 2;
    return 1;
}

// Minimum dy relative to trunk_top.
// WEEPING has leaves 3 below trunk_top (dy=-3); PINE has its outer skirt at -2;
// others -1. (Must cover the lowest dy any in_canopy_* returns, or that leaf
// layer is never iterated and silently omitted.)
static int canopy_dy_min(int shape) noexcept {
    if (shape == CANOPY_WEEPING) return -3;
    if (shape == CANOPY_PINE)    return -2;
    return -1;
}

// ---------------------------------------------------------------------------
// Structure system — seam-safe deterministic world landmarks
// ---------------------------------------------------------------------------
//
// Structures are placed on a coarse 64×64 world grid (STRUCT_CELL_SIZE).
// One candidate per cell; a hash of the cell anchor decides if a structure
// spawns (low probability ~12%) and which type.  Structure types are biome-
// aware; the whole structure is derived from the anchor hash so every chunk
// that overlaps it generates it identically.
//
// Structure types:
//   STRUCT_RUINED_HUT   — 5×4×4 cobblestone/oak_planks walls + partial roof
//   STRUCT_STONE_PILLAR — 3-block tall 1×1 stone pillar, optional arch pieces
//   STRUCT_CAMPFIRE     — cobblestone ring (3×3 perimeter) + glow_block center
//   STRUCT_WATCHTOWER   — 3×3 oak_planks floor on 4-log stilts + platform
//   STRUCT_TREASURE     — chest buried 1 below surface with cobblestone marker
//   STRUCT_CAIRN        — pile of 2..5 stone/mossy_stone blocks stacked up
//
// Seam safety: the anchor world pos is derived from cell integer coords.
// Surface height at each column within the structure is sampled via the same
// pure surface_height() function all chunks use — identical across chunk borders.
// Structures never carve terrain (additive only) and never place below surface.
//
// Cell size chosen so structures are rare (one candidate per 64×64 region)
// but appear regularly enough to feel discoverable.  Spawning probability ~12%.
// ---------------------------------------------------------------------------

static constexpr int STRUCT_CELL_SIZE    = 64;
static constexpr std::uint64_t STRUCT_SEED_MIX = 0x57AC7EDEDBEF5717ull;

// Structure spawn probability out of 256 (#17).  Old value was 31 (~12%); raised
// to 80 (~31%) — roughly 2.6× more structures.  Expressed as a named constant so
// the diagnostic probe (worldgen_count_structures) and tests stay in sync.
static constexpr std::uint64_t STRUCT_PROB_THRESH = 80u;

// Structure type codes.
static constexpr int STRUCT_NONE         = 0;
static constexpr int STRUCT_RUINED_HUT   = 1;
static constexpr int STRUCT_STONE_PILLAR = 2;
static constexpr int STRUCT_CAMPFIRE     = 3;
static constexpr int STRUCT_WATCHTOWER   = 4;
static constexpr int STRUCT_TREASURE     = 5;
static constexpr int STRUCT_CAIRN        = 6;

// Max XZ reach from anchor for seam-safe cell scan (conservative).
// Ruined hut is up to 4 blocks from anchor center; tower is 2.
static constexpr int STRUCT_MAX_REACH_XZ = 5;

struct StructDesc {
    std::int32_t anchor_wx;    // world X of structure anchor
    std::int32_t anchor_wz;    // world Z of structure anchor
    int          type;         // STRUCT_* constant
    std::uint64_t cell_hash;   // deterministic bits for per-structure variety
    bool         present;
};

// Floor-division (works correctly for negative coords).
static std::int32_t struct_floordiv(std::int32_t a, int b) noexcept {
    return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
}

// Query whether a structure exists in the given structure cell.
static StructDesc struct_for_cell(std::int32_t scx, std::int32_t scz,
                                   std::uint64_t seed) noexcept {
    std::uint64_t sseed = fmix64(seed ^ STRUCT_SEED_MIX);
    std::uint64_t h = hash2(scx, scz, sseed);

    // Spawn probability (#17 STRUCTURES TOO RARE).  Raised ~2.6x from the old
    // ~12% (31/256) to ~31% (80/256) so a wandering player reliably stumbles on
    // a hut/pillar/campfire/watchtower/treasure/cairn within a short walk, while
    // still leaving most 64×64 cells empty (not "everywhere").
    if ((h & 0xFFu) >= STRUCT_PROB_THRESH) {
        return StructDesc{0, 0, STRUCT_NONE, 0, false};
    }

    // Anchor position: offset within cell so it is not always at corner.
    std::uint64_t h2s = fmix64(h ^ 0xFACEBEEF0BABULL);
    std::int32_t off_x = 4 + static_cast<std::int32_t>((h2s >>  0u) & 0x37u);  // 4..59
    std::int32_t off_z = 4 + static_cast<std::int32_t>((h2s >> 16u) & 0x37u);  // 4..59

    std::int32_t ax = scx * STRUCT_CELL_SIZE + off_x;
    std::int32_t az = scz * STRUCT_CELL_SIZE + off_z;

    // Biome at anchor determines eligible structure types.
    float weights[NUM_BIOMES];
    biome_weights(ax, az, seed, weights);
    Biome dom = dominant_biome(weights);

    // No structures in water biomes (beach below sea) or deep desert interior.
    // Surface height at anchor.
    int H = surface_height(ax, az, seed, weights);
    if (H <= SEA_LEVEL) {
        return StructDesc{0, 0, STRUCT_NONE, 0, false};
    }

    // Choose structure type based on biome and hash bits.
    std::uint64_t type_bits = (h2s >> 32u) & 0x7u;  // 0..7
    int stype;

    switch (dom) {
        case Biome::Mountains:
            // Mountains: cairns and stone pillars.
            stype = (type_bits <= 4u) ? STRUCT_CAIRN : STRUCT_STONE_PILLAR;
            break;
        case Biome::Desert:
            // Desert: stone pillar standing stones.
            stype = STRUCT_STONE_PILLAR;
            break;
        case Biome::Forest:
            // Forest: ruined hut or campfire.
            stype = (type_bits <= 3u) ? STRUCT_RUINED_HUT : STRUCT_CAMPFIRE;
            break;
        case Biome::Plains:
            // Plains: any structure — mostly campfires and watchtowers.
            stype = (type_bits == 0u) ? STRUCT_RUINED_HUT  :
                    (type_bits <= 3u) ? STRUCT_CAMPFIRE     :
                    (type_bits <= 5u) ? STRUCT_WATCHTOWER   : STRUCT_TREASURE;
            break;
        case Biome::Snowy:
            // Snowy: stone pillars and cairns.
            stype = (type_bits <= 3u) ? STRUCT_CAIRN : STRUCT_STONE_PILLAR;
            break;
        case Biome::Swamp:
            // Swamp: watchtower on stilts, campfire ring.
            stype = (type_bits <= 3u) ? STRUCT_WATCHTOWER : STRUCT_CAMPFIRE;
            break;
        default:
            stype = STRUCT_CAIRN;
            break;
    }

    return StructDesc{ax, az, stype, h2s, true};
}

// Helper: safely set a block at a world position into the current chunk.
// Returns true if the position is within the chunk and the block was set.
// Only sets AIR->anything or solid->solid (never replaces existing non-AIR
// with AIR, and never replaces non-AIR with AIR to avoid terrain damage).
static bool struct_set(IChunk& chunk,
                       std::int32_t wx, std::int32_t wy, std::int32_t wz,
                       std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min,
                       BlockId b) noexcept {
    if (wx < wx_min || wx > wx_min + kChunkDim - 1) return false;
    if (wy < wy_min || wy > wy_min + kChunkDim - 1) return false;
    if (wz < wz_min || wz > wz_min + kChunkDim - 1) return false;
    int lx = static_cast<int>(wx - wx_min);
    int ly = static_cast<int>(wy - wy_min);
    int lz = static_cast<int>(wz - wz_min);
    // Only place if target is AIR (additive only — never destroy terrain).
    if (chunk.get(lx, ly, lz) == AIR) {
        chunk.set(lx, ly, lz, b);
    } else if (b != AIR) {
        // For non-AIR blocks being placed on non-AIR: overwrite (e.g. chest on dirt).
        chunk.set(lx, ly, lz, b);
    }
    return true;
}

// Get the surface height at an anchor-relative column for structure placement.
// We sample the real surface_height() function — same as terrain generation.
static int struct_surface(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept {
    float w[NUM_BIOMES];
    biome_weights(wx, wz, seed, w);
    return surface_height(wx, wz, seed, w);
}

// Place a RUINED HUT at the anchor. The hut is a 5×3×5 cobblestone shell
// (outer walls only, doorway gap on south face) with oak_planks partial roof.
// Wall columns are filled from each column's natural surface up to the wall
// top — this prevents floating blocks with exposed AIR underneath.
static void place_ruined_hut(std::int32_t ax, std::int32_t az,
                              std::uint64_t h, std::uint64_t seed,
                              IChunk& chunk,
                              std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Find the max surface height in the 5×5 wall footprint — this is the
    // shared "floor level" from which wall height is counted. Start below any
    // real terrain (surfaces can be negative in low swamp) so a hut at a biome
    // edge doesn't anchor at 0 and float / sink.
    int floor_h = -1000000;
    for (int dz = -2; dz <= 2; ++dz)
        for (int dx = -2; dx <= 2; ++dx) {
            bool on_xwall = (dx == -2 || dx == 2);
            bool on_zwall = (dz == -2 || dz == 2);
            if (!(on_xwall || on_zwall)) continue;  // only wall columns matter for floor
            int sh = struct_surface(ax + dx, az + dz, seed);
            if (sh > floor_h) floor_h = sh;
        }

    // Doorway is on one side (biased by hash): south (dz=+2) or north (dz=-2).
    bool door_south = ((h >> 40u) & 1u) == 0u;
    int door_dz = door_south ? 2 : -2;

    // Wall height: 3 blocks above shared floor level.
    constexpr int WALL_H = 3;
    int wall_top = floor_h + WALL_H;

    for (int dz = -2; dz <= 2; ++dz) {
        for (int dx = -2; dx <= 2; ++dx) {
            bool on_xwall = (dx == -2 || dx == 2);
            bool on_zwall = (dz == -2 || dz == 2);
            bool is_wall = on_xwall || on_zwall;
            if (!is_wall) continue;  // interior is open

            // Doorway gap: 2-block opening in the middle of the door wall.
            bool is_doorway_col = (dz == door_dz && dx >= -1 && dx <= 1);

            // Column's own natural surface — fill from surface up to wall top.
            int col_h = struct_surface(ax + dx, az + dz, seed);

            // Doorway columns: only fill from terrain surface up to floor_h
            // (i.e., below the doorway opening). The doorway opening itself
            // (floor+1..floor+wall_h) is left completely open — no wall blocks
            // above the terrain fill. This ensures the topmost solid at a doorway
            // column is at floor_h (terrain level), with solid below.
            // Non-doorway columns: fill continuously from terrain surface up to wall top.
            int fill_top = is_doorway_col ? floor_h : wall_top;

            for (int wy = col_h + 1; wy <= fill_top; ++wy) {
                // Partial ruin: top row has 25% chance to be missing (non-doorway only).
                if (!is_doorway_col && wy == wall_top) {
                    std::uint64_t ruin_h = fmix64(h ^ (static_cast<std::uint64_t>(dx + dz * 7 + 100)));
                    if ((ruin_h & 0x3u) == 0u) continue;
                }
                struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, COBBLESTONE);
            }
        }
    }

    // Roofless — open sky over the interior. Purely cobblestone walls + doorway.
    // OAK_PLANKS is placed only at corners as a lintel block ON the wall_top
    // itself (same y level), replacing the corner cobblestone to add variety.
    // Since this is at the same y as the already-placed wall block, no AIR gap
    // is ever introduced above it.
    for (int dz = -2; dz <= 2; ++dz) {
        for (int dx = -2; dx <= 2; ++dx) {
            bool is_corner = (dx == -2 || dx == 2) && (dz == -2 || dz == 2);
            if (!is_corner) continue;
            if (dz == door_dz) continue;  // skip doorway wall corners
            // Place oak_planks AT the wall top (not above it) — always safe.
            struct_set(chunk, ax + dx, wall_top, az + dz,
                       wx_min, wy_min, wz_min, OAK_PLANKS);
        }
    }
}

// Place a STONE PILLAR / standing stone at the anchor.
// Height 3..5 blocks, optionally with a 1-block "lintel" cobblestone arch on top.
static void place_stone_pillar(std::int32_t ax, std::int32_t az,
                                std::uint64_t h, std::uint64_t seed,
                                IChunk& chunk,
                                std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    int H = struct_surface(ax, az, seed);
    int pillar_h = 3 + static_cast<int>((h >> 8u) & 0x3u);  // 3..6

    // Single 1×1 column.
    for (int dy = 1; dy <= pillar_h; ++dy) {
        BlockId b = ((dy % 2 == 0) && ((h >> 12u) & 1u)) ? MOSSY_STONE : STONE;
        struct_set(chunk, ax, H + dy, az, wx_min, wy_min, wz_min, b);
    }

    // Optional arch: cobblestone block to one side at the top.
    bool has_arch = ((h >> 16u) & 0x3u) <= 1u;
    if (has_arch) {
        int arch_dx = ((h >> 18u) & 1u) ? 1 : -1;
        struct_set(chunk, ax + arch_dx, H + pillar_h, az,
                   wx_min, wy_min, wz_min, COBBLESTONE);
    }
}

// Place a CAMPFIRE RING: cobblestone perimeter of a 3×3 ring + glow_block center.
// Each column is placed at its own natural surface height so no column is left
// with floating blocks and exposed AIR underneath.
static void place_campfire(std::int32_t ax, std::int32_t az,
                            std::uint64_t /*h*/, std::uint64_t seed,
                            IChunk& chunk,
                            std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Outer ring of cobblestone at each column's own surface level.
    // Center gets glow_block at its own surface.
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dx = -1; dx <= 1; ++dx) {
            bool is_center = (dx == 0 && dz == 0);
            int  col_h     = struct_surface(ax + dx, az + dz, seed);
            BlockId b      = is_center ? GLOW_BLOCK : COBBLESTONE;
            struct_set(chunk, ax + dx, col_h, az + dz, wx_min, wy_min, wz_min, b);
        }
    }
}

// Place a WATCHTOWER: 4-log stilt base, 3×3 oak_planks platform,
// then short parapet posts at platform corners.
// Stilts rise from each corner column's own surface up to a common platform height.
// This ensures no floating blocks and no exposed-AIR subsurface columns.
static void place_watchtower(std::int32_t ax, std::int32_t az,
                              std::uint64_t /*h*/, std::uint64_t seed,
                              IChunk& chunk,
                              std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Corner stilt positions (±1, ±1).
    int corners[4][2] = {{-1,-1},{1,-1},{-1,1},{1,1}};

    // Find the MAX surface height of the 4 corner columns so the platform
    // sits above all of them.  Add STILT_H=3 above that max.
    constexpr int STILT_H = 3;
    int max_corner_h = -1000000;   // below any real terrain (surfaces can be negative)
    for (auto& cor : corners) {
        int sh = struct_surface(ax + cor[0], az + cor[1], seed);
        if (sh > max_corner_h) max_corner_h = sh;
    }
    int platform_y = max_corner_h + STILT_H + 1;

    // Stilts: from each corner's natural surface+1 up to platform_y-1.
    for (auto& cor : corners) {
        int col_h = struct_surface(ax + cor[0], az + cor[1], seed);
        for (int wy = col_h + 1; wy < platform_y; ++wy) {
            struct_set(chunk, ax + cor[0], wy, az + cor[1],
                       wx_min, wy_min, wz_min, OAK_LOG);
        }
    }

    // Platform: oak_planks placed ONLY at the 4 stilt corner tops and the 4
    // edge midpoints between them. We skip the inner 3×3 centre to avoid
    // floating planks over columns that have no stilt support below.
    // Corners (±1,±1) have stilts directly below — always safe.
    // Edge midpoints (±1,0) and (0,±1): these columns also have stilt-adjacent
    // fill from the stilt loop if the terrain there is lower.
    // To be safe we ONLY place planks at the 4 stilt corner positions.
    for (auto& cor : corners) {
        struct_set(chunk, ax + cor[0], platform_y, az + cor[1],
                   wx_min, wy_min, wz_min, OAK_PLANKS);
    }
    // Also place planks connecting the corners with single-block edges.
    int edges[4][2] = {{-1,0},{1,0},{0,-1},{0,1}};
    for (auto& ed : edges) {
        // Edge positions: only place plank if it's directly adjacent to a stilt.
        // Both adjacent stilt columns were filled to platform_y-1, so placing
        // the platform plank here at platform_y is only 1 above the stilt top.
        // But the COLUMN ITSELF (ax+ed[0], az+ed[1]) may have natural terrain
        // several blocks below platform_y. We fill the gap between natural
        // surface and platform with logs to support the plank.
        int edge_col_h = struct_surface(ax + ed[0], az + ed[1], seed);
        // Fill from natural surface+1 to platform_y-1 with logs.
        for (int wy = edge_col_h + 1; wy < platform_y; ++wy) {
            struct_set(chunk, ax + ed[0], wy, az + ed[1],
                       wx_min, wy_min, wz_min, OAK_LOG);
        }
        // Place the platform plank at the top.
        struct_set(chunk, ax + ed[0], platform_y, az + ed[1],
                   wx_min, wy_min, wz_min, OAK_PLANKS);
    }

    // Short parapet posts at platform corners (1 log each above platform).
    for (auto& cor : corners) {
        struct_set(chunk, ax + cor[0], platform_y + 1, az + cor[1],
                   wx_min, wy_min, wz_min, OAK_LOG);
    }
}

// Place a TREASURE MARKER: a chest buried 1 block below surface, with a
// cobblestone marker block on the surface directly above, and a cross of
// mossy_stone around it.
static void place_treasure(std::int32_t ax, std::int32_t az,
                            std::uint64_t /*h*/, std::uint64_t seed,
                            IChunk& chunk,
                            std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    int H = struct_surface(ax, az, seed);

    // Chest one block below the surface top.
    struct_set(chunk, ax, H - 1, az, wx_min, wy_min, wz_min, CHEST);

    // Cobblestone marker on surface directly above.
    struct_set(chunk, ax, H, az, wx_min, wy_min, wz_min, COBBLESTONE);

    // Mossy stone cross on surface around marker.
    int cross[4][2] = {{1,0},{-1,0},{0,1},{0,-1}};
    for (auto& cr : cross) {
        int sh = struct_surface(ax + cr[0], az + cr[1], seed);
        struct_set(chunk, ax + cr[0], sh, az + cr[1],
                   wx_min, wy_min, wz_min, MOSSY_STONE);
    }
}

// Place a ROCK CAIRN: 2..5 stone/mossy_stone blocks stacked in a 1×1 column,
// with optional small scatter of rocks around the base.
static void place_cairn(std::int32_t ax, std::int32_t az,
                         std::uint64_t h, std::uint64_t seed,
                         IChunk& chunk,
                         std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    int H = struct_surface(ax, az, seed);
    int cairn_h = 2 + static_cast<int>((h >> 4u) & 0x3u);  // 2..5

    for (int dy = 1; dy <= cairn_h; ++dy) {
        BlockId b = ((h >> (static_cast<unsigned>(dy) + 8u)) & 1u) ? MOSSY_STONE : STONE;
        struct_set(chunk, ax, H + dy, az, wx_min, wy_min, wz_min, b);
    }

    // Scatter a couple of rocks around the base.
    int scatter[4][2] = {{1,0},{-1,0},{0,1},{0,-1}};
    for (int si = 0; si < 4; ++si) {
        std::uint64_t sh = fmix64(h ^ static_cast<std::uint64_t>(si + 200));
        if ((sh & 0x3u) >= 2u) continue;  // ~50% chance per side
        int sdx = scatter[si][0];
        int sdz = scatter[si][1];
        int sH = struct_surface(ax + sdx, az + sdz, seed);
        BlockId sb = ((sh >> 2u) & 1u) ? MOSSY_STONE : STONE;
        struct_set(chunk, ax + sdx, sH + 1, az + sdz,
                   wx_min, wy_min, wz_min, sb);
    }
}

// Dispatch to the right placer.
static void place_structure(const StructDesc& sd, std::uint64_t seed,
                             IChunk& chunk,
                             std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    switch (sd.type) {
        case STRUCT_RUINED_HUT:
            place_ruined_hut(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                             chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_STONE_PILLAR:
            place_stone_pillar(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                               chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_CAMPFIRE:
            place_campfire(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                           chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_WATCHTOWER:
            place_watchtower(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                             chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_TREASURE:
            place_treasure(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                           chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_CAIRN:
            place_cairn(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                        chunk, wx_min, wy_min, wz_min);
            break;
        default: break;
    }
}

// ---------------------------------------------------------------------------
// Deadwood (#22) — stumps and fallen logs for forest-floor naturalness.
// ---------------------------------------------------------------------------
// A coarse world-aligned grid (DEADWOOD_CELL) carries at most one deadwood
// feature per cell.  A small fraction of cells spawn one, only in wooded biomes
// (forest/swamp/plains/mountains).  Two kinds:
//   STUMP       — a 1..2 block log remnant, occasionally with a tiny leaf nub.
//   FALLEN_LOG  — a horizontal run of 3..5 logs lying along the surface (each
//                 segment placed at its own column's surface so it follows the
//                 ground and never floats).
// Everything is derived from the global cell hash, so any chunk a fallen log
// crosses draws the same segments → seam-consistent.  Each voxel is range-checked
// against the chunk bounds before writing (clipped, never OOB).  Cheap: a handful
// of cells per chunk, each a couple of hashes.
// ---------------------------------------------------------------------------
static constexpr int DEADWOOD_CELL = 12;             // one candidate per 12×12 region
static constexpr int DEADWOOD_REACH_XZ = 5;          // longest fallen log reach
static constexpr std::uint64_t DEADWOOD_SEED_MIX = 0xDEAD0F00DDEAD066ull;

static constexpr int DEADWOOD_NONE  = 0;
static constexpr int DEADWOOD_STUMP = 1;
static constexpr int DEADWOOD_LOG   = 2;

struct DeadwoodDesc {
    std::int32_t wx;       // anchor column
    std::int32_t wz;
    int          kind;     // DEADWOOD_*
    int          length;   // fallen-log length (3..5) or stump height (1..2)
    int          dir;      // 0..3 horizontal direction for a fallen log
    BlockId      log_id;
    bool         leaf_nub; // stump: place a small leaf nub on top
    bool         present;
};

static std::int32_t deadwood_floordiv(std::int32_t a, int b) noexcept {
    return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
}

static DeadwoodDesc deadwood_for_cell(std::int32_t dcx, std::int32_t dcz,
                                      std::uint64_t seed) noexcept {
    std::uint64_t dseed = fmix64(seed ^ DEADWOOD_SEED_MIX);
    std::uint64_t h = hash2(dcx, dcz, dseed);

    // ~16% of cells carry deadwood (then biome-gated below).
    if ((h & 0xFFu) >= 40u) return DeadwoodDesc{0,0,DEADWOOD_NONE,0,0,0,false,false};

    std::uint64_t h2 = fmix64(h ^ 0xF0FFEEDDEADBEEF1ull);
    std::int32_t off_x = 2 + static_cast<std::int32_t>((h2 >> 0u) % static_cast<std::uint64_t>(DEADWOOD_CELL - 4));
    std::int32_t off_z = 2 + static_cast<std::int32_t>((h2 >> 8u) % static_cast<std::uint64_t>(DEADWOOD_CELL - 4));
    std::int32_t ax = dcx * DEADWOOD_CELL + off_x;
    std::int32_t az = dcz * DEADWOOD_CELL + off_z;

    // Wooded biomes only.
    float w[NUM_BIOMES];
    biome_weights(ax, az, seed, w);
    Biome dom = dominant_biome(w);
    if (dom == Biome::Desert || dom == Biome::Beach || dom == Biome::Snowy)
        return DeadwoodDesc{0,0,DEADWOOD_NONE,0,0,0,false,false};

    bool is_log_kind = ((h2 >> 16u) & 0x1u) == 0u;  // 50/50 stump vs fallen log
    int kind = is_log_kind ? DEADWOOD_LOG : DEADWOOD_STUMP;
    int length = is_log_kind
        ? 3 + static_cast<int>((h2 >> 20u) % 3u)    // 3..5 fallen log
        : 1 + static_cast<int>((h2 >> 20u) & 1u);   // 1..2 stump
    int dir = static_cast<int>((h2 >> 24u) & 0x3u); // 0..3
    bool birch = ((h2 >> 26u) & 0x3u) == 0u;        // 25% birch
    bool leaf_nub = !is_log_kind && (((h2 >> 28u) & 0x3u) == 0u); // 25% of stumps

    return DeadwoodDesc{ ax, az, kind, length, dir,
                         birch ? BIRCH_LOG : OAK_LOG, leaf_nub, true };
}

// ---------------------------------------------------------------------------
// Decoration pass — seam-aware, biome-aware
// ---------------------------------------------------------------------------
static void place_decorations(ChunkCoord c, IChunk& chunk, std::uint64_t seed,
                              const SeamAnchorCache& anchor_cache,
                              const ChunkColumnCache& col_cache) {
    std::int32_t wx_min = c.x * kChunkDim;
    std::int32_t wy_min = c.y * kChunkDim;
    std::int32_t wz_min = c.z * kChunkDim;
    std::int32_t wx_max = wx_min + kChunkDim - 1;
    std::int32_t wy_max = wy_min + kChunkDim - 1;
    std::int32_t wz_max = wz_min + kChunkDim - 1;

    // -------------------------------------------------------------------
    // 1. TREES — seam-safe cell-scan.
    //    Broad canopy extends ±3 XZ, tall extends 2 blocks above trunk_top.
    //    We scan conservatively with CANOPY_MAX_REACH_XZ=3.
    // -------------------------------------------------------------------
    {
        std::int32_t cell_xmin, cell_xmax, cell_zmin, cell_zmax, dummy;
        tree_cell(wx_min - CANOPY_MAX_REACH_XZ, wz_min - CANOPY_MAX_REACH_XZ, cell_xmin, cell_zmin);
        tree_cell(wx_max + CANOPY_MAX_REACH_XZ, wz_max + CANOPY_MAX_REACH_XZ, cell_xmax, dummy);
        tree_cell(wx_min, wz_max + CANOPY_MAX_REACH_XZ, dummy, cell_zmax);
        (void)dummy;

        for (std::int32_t ccz = cell_zmin; ccz <= cell_zmax; ++ccz) {
            for (std::int32_t ccx = cell_xmin; ccx <= cell_xmax; ++ccx) {
                TreeDesc td = tree_for_cell(ccx, ccz, seed);
                if (!td.present) continue;

                // Compute biome at tree root for surface height.
                float weights[NUM_BIOMES];
                biome_weights(td.root_wx, td.root_wz, seed, weights);
                Biome dom = dominant_biome(weights);

                // Tree-bearing biomes only (desert/beach have no trees).
                if (dom == Biome::Desert || dom == Biome::Beach) continue;

                int H = surface_height_cached(td.root_wx, td.root_wz, anchor_cache);
                if (H <= SEA_LEVEL) continue;  // don't grow trees underwater

                // Trunk: H+1 .. H+trunk_height
                int trunk_base_wy = H + 1;
                int trunk_top_wy  = H + td.trunk_height;
                int dy_max_v      = canopy_dy_max(td.canopy_shape);
                int dy_min_v      = canopy_dy_min(td.canopy_shape);
                int canopy_wy_max = trunk_top_wy + dy_max_v;
                int canopy_wy_min = trunk_top_wy + dy_min_v;

                // Branch arms can rise a couple blocks above the canopy top and
                // their tip clusters add one more; widen the vertical overlap test
                // so a chunk that contains ONLY a branch tip still draws it.
                int feature_wy_max = canopy_wy_max;
                if (td.branch_count > 0) {
                    int branch_top = trunk_top_wy + 2 /*rise*/ + 1 /*tip cluster*/;
                    if (branch_top > feature_wy_max) feature_wy_max = branch_top;
                }

                if (feature_wy_max < wy_min || trunk_base_wy > wy_max) continue;
                if (canopy_wy_min > wy_max) continue;

                // Place trunk logs.
                // Leaning trunk: for the upper half, shift log position by lean_dx/lean_dz.
                // This produces a gentle L-bend (bottom half straight, top half offset by 1).
                {
                    int lean_start = trunk_base_wy + td.trunk_height / 2;  // upper half leans
                    for (int wy = trunk_base_wy; wy <= trunk_top_wy; ++wy) {
                        if (wy < wy_min || wy > wy_max) continue;
                        // Compute log XZ position (lean in upper half).
                        int wx_log = td.root_wx;
                        int wz_log = td.root_wz;
                        if (wy >= lean_start) {
                            wx_log += td.lean_dx;
                            wz_log += td.lean_dz;
                        }
                        if (wx_log < wx_min || wx_log > wx_max) continue;
                        if (wz_log < wz_min || wz_log > wz_max) continue;
                        int lx = wx_log - wx_min;
                        int ly = wy - wy_min;
                        int lz = wz_log - wz_min;
                        chunk.set(lx, ly, lz, td.log_id);

                        // Thick trunk: 2×2 logs — also fill the (+1,0), (0,+1), (+1,+1) offsets.
                        if (td.thick_trunk) {
                            for (int tx = 0; tx <= 1; ++tx) {
                                for (int tz = 0; tz <= 1; ++tz) {
                                    if (tx == 0 && tz == 0) continue;  // already placed above
                                    int wx2 = wx_log + tx;
                                    int wz2 = wz_log + tz;
                                    if (wx2 < wx_min || wx2 > wx_max) continue;
                                    if (wz2 < wz_min || wz2 > wz_max) continue;
                                    chunk.set(wx2 - wx_min, ly, wz2 - wz_min, td.log_id);
                                }
                            }
                        }
                    }
                }

                // Canopy anchor XZ: trunk top position accounts for lean.
                int canopy_wx = td.root_wx + td.lean_dx;
                int canopy_wz = td.root_wz + td.lean_dz;

                // Place canopy leaves.
                // GIANT/WEEPING extend ±4 XZ; PINE/BROAD ±3 XZ; FORKED ±2 XZ; others ±2 XZ.
                int reach = (td.canopy_shape == CANOPY_GIANT)   ? 4 :
                            (td.canopy_shape == CANOPY_WEEPING)  ? 4 :
                            (td.canopy_shape == CANOPY_BROAD || td.canopy_shape == CANOPY_PINE) ? 3 : 2;
                for (int dz = -reach; dz <= reach; ++dz) {
                    for (int dx = -reach; dx <= reach; ++dx) {
                        for (int dy = dy_min_v; dy <= dy_max_v; ++dy) {
                            if (!in_canopy(dx, dy, dz, td.canopy_shape)) continue;

                            std::int32_t wlx = canopy_wx + dx;
                            std::int32_t wly = trunk_top_wy + dy;
                            std::int32_t wlz = canopy_wz + dz;

                            if (wlx < wx_min || wlx > wx_max) continue;
                            if (wly < wy_min || wly > wy_max) continue;
                            if (wlz < wz_min || wlz > wz_max) continue;

                            int lx = wlx - wx_min;
                            int ly = wly - wy_min;
                            int lz = wlz - wz_min;
                            if (chunk.get(lx, ly, lz) == AIR) {
                                chunk.set(lx, ly, lz, td.leaf_id);
                            }
                        }
                    }
                }

                // -----------------------------------------------------------
                // BRANCHES (M6) — short log arms off the upper trunk, each
                // ending in a small leaf cluster.  Geometry is a pure function
                // of td.branch_hash (global cell hash), so every chunk the arm
                // overlaps draws it identically (seam-consistent).  Each voxel
                // is range-checked against the chunk bounds before writing, so
                // arms that cross a chunk edge are simply clipped — no OOB writes.
                // -----------------------------------------------------------
                for (int bi = 0; bi < td.branch_count; ++bi) {
                    // Per-branch deterministic parameters from distinct hash bits.
                    std::uint64_t bh = fmix64(td.branch_hash
                        ^ (static_cast<std::uint64_t>(bi + 1) * 0x9E3779B97F4A7C15ull));
                    int dir = static_cast<int>(bh & 0x7u);                 // 0..7 compass
                    int blen = BRANCH_LEN_MIN
                             + static_cast<int>((bh >> 3u) % static_cast<std::uint64_t>(
                                   BRANCH_LEN_MAX - BRANCH_LEN_MIN + 1));   // 2..3

                    // Attach point on the upper trunk: spread arms across the top
                    // third so they don't all sprout from one ring.  Keep at least
                    // 1 block below the trunk top so the crown still sits above.
                    int span = (td.trunk_height >= 3) ? (td.trunk_height / 3) : 1;
                    int attach_wy = trunk_top_wy - 1
                                  - static_cast<int>((bh >> 8u) % static_cast<std::uint64_t>(span + 1));
                    if (attach_wy < trunk_base_wy + 1) attach_wy = trunk_base_wy + 1;

                    // Arm root XZ = trunk XZ at the attach height (account for lean
                    // on the upper half, matching the trunk-placement logic).
                    int lean_start = trunk_base_wy + td.trunk_height / 2;
                    int arm_wx = td.root_wx + ((attach_wy >= lean_start) ? td.lean_dx : 0);
                    int arm_wz = td.root_wz + ((attach_wy >= lean_start) ? td.lean_dz : 0);

                    int sdx = BRANCH_DIRS[dir][0];
                    int sdz = BRANCH_DIRS[dir][1];

                    // Step out-and-up: each step moves 1 in the compass direction
                    // and (every other step) 1 up, giving a gentle diagonal bough.
                    int cx = arm_wx, cz = arm_wz, cy = attach_wy;
                    for (int s = 1; s <= blen; ++s) {
                        cx += sdx;
                        cz += sdz;
                        if ((s & 1) == 1) cy += 1;  // rise on odd steps
                        // Place the log segment (clipped to chunk).
                        if (cx >= wx_min && cx <= wx_max &&
                            cy >= wy_min && cy <= wy_max &&
                            cz >= wz_min && cz <= wz_max) {
                            int lx = cx - wx_min, ly = cy - wy_min, lz = cz - wz_min;
                            if (chunk.get(lx, ly, lz) == AIR) chunk.set(lx, ly, lz, td.log_id);
                        }
                    }

                    // Small leaf cluster at the arm tip: a 3×3×3 plus-ish blob.
                    int tipx = cx, tipy = cy, tipz = cz;
                    for (int lz2 = -1; lz2 <= 1; ++lz2) {
                        for (int lx2 = -1; lx2 <= 1; ++lx2) {
                            for (int ly2 = 0; ly2 <= 1; ++ly2) {
                                // Trim the 4 top corners so the cluster reads round.
                                if (ly2 == 1 && lx2 != 0 && lz2 != 0) continue;
                                std::int32_t wlx = tipx + lx2;
                                std::int32_t wly = tipy + ly2;
                                std::int32_t wlz = tipz + lz2;
                                if (wlx < wx_min || wlx > wx_max) continue;
                                if (wly < wy_min || wly > wy_max) continue;
                                if (wlz < wz_min || wlz > wz_max) continue;
                                int lx = wlx - wx_min, ly = wly - wy_min, lz = wlz - wz_min;
                                if (chunk.get(lx, ly, lz) == AIR) chunk.set(lx, ly, lz, td.leaf_id);
                            }
                        }
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 1b. DEADWOOD (#22) — stumps & fallen logs scattered on the forest floor.
    //     Seam-safe cell scan: a fallen log can extend DEADWOOD_REACH_XZ from its
    //     anchor, so we scan all cells whose features could reach into this chunk.
    //     Each segment sits at its OWN column's surface height (cone-cached), so
    //     logs follow the ground and never float; voxels are clipped to the chunk.
    // -------------------------------------------------------------------
    {
        std::int32_t dcx_min = deadwood_floordiv(wx_min - DEADWOOD_REACH_XZ, DEADWOOD_CELL);
        std::int32_t dcx_max = deadwood_floordiv(wx_max + DEADWOOD_REACH_XZ, DEADWOOD_CELL);
        std::int32_t dcz_min = deadwood_floordiv(wz_min - DEADWOOD_REACH_XZ, DEADWOOD_CELL);
        std::int32_t dcz_max = deadwood_floordiv(wz_max + DEADWOOD_REACH_XZ, DEADWOOD_CELL);

        static constexpr int DW_DIRS[4][2] = { {1,0}, {-1,0}, {0,1}, {0,-1} };

        for (std::int32_t dcz = dcz_min; dcz <= dcz_max; ++dcz) {
            for (std::int32_t dcx = dcx_min; dcx <= dcx_max; ++dcx) {
                DeadwoodDesc dw = deadwood_for_cell(dcx, dcz, seed);
                if (!dw.present) continue;

                int Ha = surface_height_cached(dw.wx, dw.wz, anchor_cache);
                if (Ha <= SEA_LEVEL) continue;  // not on dry land

                if (dw.kind == DEADWOOD_STUMP) {
                    // Stump: 1..2 logs at the anchor column's surface.
                    for (int s = 1; s <= dw.length; ++s) {
                        std::int32_t wy = Ha + s;
                        if (dw.wx < wx_min || dw.wx > wx_max) continue;
                        if (dw.wz < wz_min || dw.wz > wz_max) continue;
                        if (wy < wy_min || wy > wy_max) continue;
                        int lx = static_cast<int>(dw.wx - wx_min);
                        int ly = static_cast<int>(wy - wy_min);
                        int lz = static_cast<int>(dw.wz - wz_min);
                        if (chunk.get(lx, ly, lz) == AIR) chunk.set(lx, ly, lz, dw.log_id);
                    }
                    // Optional small leaf nub on top of the stump.
                    if (dw.leaf_nub) {
                        std::int32_t wy = Ha + dw.length + 1;
                        if (dw.wx >= wx_min && dw.wx <= wx_max &&
                            dw.wz >= wz_min && dw.wz <= wz_max &&
                            wy >= wy_min && wy <= wy_max) {
                            int lx = static_cast<int>(dw.wx - wx_min);
                            int ly = static_cast<int>(wy - wy_min);
                            int lz = static_cast<int>(dw.wz - wz_min);
                            if (chunk.get(lx, ly, lz) == AIR)
                                chunk.set(lx, ly, lz, OAK_LEAVES);
                        }
                    }
                } else {
                    // Fallen log: a horizontal run lying ON the surface (each
                    // segment one block above its own column's surface height).
                    int ddx = DW_DIRS[dw.dir][0];
                    int ddz = DW_DIRS[dw.dir][1];
                    for (int s = 0; s < dw.length; ++s) {
                        std::int32_t cwx = dw.wx + ddx * s;
                        std::int32_t cwz = dw.wz + ddz * s;
                        int Hs = surface_height_cached(cwx, cwz, anchor_cache);
                        std::int32_t wy = Hs + 1;       // rest on the ground
                        if (cwx < wx_min || cwx > wx_max) continue;
                        if (cwz < wz_min || cwz > wz_max) continue;
                        if (wy < wy_min || wy > wy_max) continue;
                        int lx = static_cast<int>(cwx - wx_min);
                        int ly = static_cast<int>(wy - wy_min);
                        int lz = static_cast<int>(cwz - wz_min);
                        if (chunk.get(lx, ly, lz) == AIR) chunk.set(lx, ly, lz, dw.log_id);
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 2. PLANTS — biome-specific single-block surface decorations.
    //
    //    Density varies strongly by biome:
    //      Forest: dense tall_grass, flowers, some mushrooms
    //      Plains: moderate tall_grass, flowers
    //      Swamp:  tall_grass, many mushrooms
    //      Snowy:  bare (no plants)
    //      Desert: bare
    //      Beach:  bare
    //      Mountains: sparse grass, no plants above snow line
    // -------------------------------------------------------------------
    {
        std::uint64_t pseed = fmix64(seed ^ PLANT_SEED_MIX);

        for (int lz = 0; lz < kChunkDim; ++lz) {
            for (int lx = 0; lx < kChunkDim; ++lx) {
                std::int32_t wx = wx_min + lx;
                std::int32_t wz = wz_min + lz;

                int ci = ChunkColumnCache::idx(lx, lz);
                Biome dom = col_cache.dom[ci];

                // Desert, Beach, and Snowy have minimal/no surface plants.
                if (dom == Biome::Desert || dom == Biome::Beach || dom == Biome::Snowy) continue;

                int H = col_cache.H[ci];
                if (H <= SEA_LEVEL) continue;  // underwater

                std::int32_t plant_wy = H + 1;
                if (plant_wy < wy_min || plant_wy > wy_max) continue;

                int ly_surface = H - wy_min;
                int ly_plant   = ly_surface + 1;
                if (ly_surface < 0 || ly_surface >= kChunkDim) continue;
                if (ly_plant   < 0 || ly_plant   >= kChunkDim) continue;

                // Must be AIR above surface.
                if (chunk.get(lx, ly_plant, lz) != AIR) continue;

                // Decide based on surface block.
                BlockId surf = chunk.get(lx, ly_surface, lz);

                // Plant scatter hash — two bytes for independent rolls.
                std::uint64_t ph   = hash2(wx, wz, pseed);
                std::uint64_t roll = ph & 0xFFu;        // 0..255, primary
                std::uint64_t roll2 = (ph >> 8u) & 0xFFu; // 0..255, secondary

                BlockId plant = AIR;

                if (dom == Biome::Forest) {
                    // Undergrowth: tall_grass scattered tufts under the canopy.
                    // TRIMMED ~25%: thresholds multiplied by 0.75 vs prior version.
                    if (surf == GRASS) {
                        if      (roll <  45u) plant = TALL_GRASS;   // ~18% (was ~24%)
                        else if (roll <  60u) plant = FLOWER_RED;   // ~6%  (was ~8%)
                        else if (roll <  75u) plant = FLOWER_YELLOW;// ~6%  (was ~7%)
                        else if (roll <  85u) plant = MUSHROOM;     // ~4%  (was ~5%)
                    } else if (surf == DIRT) {
                        // Shaded dirt: mushrooms more likely, sparse tall grass.
                        // TRIMMED ~25%.
                        if      (roll2 < 60u) plant = MUSHROOM;     // ~24% (was ~31%)
                        else if (roll2 < 75u) plant = TALL_GRASS;   // ~6%  (was ~8%)
                    }
                } else if (dom == Biome::Swamp) {
                    // Swamp: mushrooms + scattered grass tufts.
                    // TRIMMED ~25%.
                    if (surf == GRASS || surf == DIRT) {
                        if      (roll <  38u) plant = TALL_GRASS;   // ~15% (was ~20%)
                        else if (roll <  75u) plant = MUSHROOM;     // ~15% (was ~20%)
                        else if (roll <  90u) plant = FLOWER_RED;   // ~6%  (was ~8%)
                    }
                } else if (dom == Biome::Plains) {
                    // Plains: scattered grass tufts, flowers prominent.
                    // TRIMMED ~25%.
                    if (surf == GRASS) {
                        if      (roll <  38u) plant = TALL_GRASS;   // ~15% (was ~20%)
                        else if (roll <  57u) plant = FLOWER_RED;   // ~7%  (was ~7%)
                        else if (roll <  75u) plant = FLOWER_YELLOW;// ~7%  (was ~7%)
                        else if (roll <  81u) plant = MUSHROOM;     // ~2%  (was ~2%)
                    }
                } else if (dom == Biome::Mountains) {
                    // Mountains: very sparse grass on lower slopes, no plants above snow line.
                    // TRIMMED ~25%: 22→16.
                    if (H >= SNOW_LINE) {
                        plant = AIR;
                    } else if (surf == GRASS) {
                        if (roll < 16u) plant = TALL_GRASS;         // ~6% (was ~9%)
                    }
                } else {
                    // Default fallback: plains-like (sparse). TRIMMED ~25%.
                    if (surf == GRASS) {
                        if      (roll <  38u) plant = TALL_GRASS;   // ~15% (was ~20%)
                        else if (roll <  57u) plant = FLOWER_RED;
                        else if (roll <  75u) plant = FLOWER_YELLOW;
                        else if (roll <  81u) plant = MUSHROOM;
                    }
                }

                if (plant != AIR) {
                    chunk.set(lx, ly_plant, lz, plant);
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 2b. UNDERWATER VEGETATION (#19 WATER IS EMPTY) — seagrass / kelp strands.
    //     For submerged columns (ocean floor below sea level) we grow a short
    //     vertical strand of TALL_GRASS (the cross-billboard plant id, used here
    //     as seagrass/kelp) up from the ocean floor through the water column.
    //     Strands are sparse-to-medium and clipped to stay under the water
    //     surface so they read as swaying weeds, not sticking out into air.
    //     Single-block writes on each column — no cross-chunk margin needed, so
    //     this is seam-trivial.  Cheap: one hash per submerged column.
    // -------------------------------------------------------------------
    {
        std::uint64_t kelp_seed = fmix64(seed ^ 0x5EA6A55C0DE1A5E7ull);
        for (int lz = 0; lz < kChunkDim; ++lz) {
            for (int lx = 0; lx < kChunkDim; ++lx) {
                int ci = ChunkColumnCache::idx(lx, lz);
                int H  = col_cache.H[ci];
                if (H >= SEA_LEVEL) continue;          // not submerged
                Biome dom = col_cache.dom[ci];
                if (dom == Biome::Snowy) continue;     // frozen-over: no kelp under ice

                std::int32_t wx = wx_min + lx;
                std::int32_t wz = wz_min + lz;
                std::uint64_t kh = hash2(wx, wz, kelp_seed);

                // Density ~22% of submerged columns carry a strand.
                if ((kh & 0xFFu) >= 56u) continue;

                // Strand height 1..3, never reaching the water surface (leave the
                // top water block clear so it reads as submerged).
                int water_depth = SEA_LEVEL - H;       // blocks of water above floor
                int strand = 1 + static_cast<int>((kh >> 8u) % 3u);  // 1..3
                int max_strand = water_depth - 1;       // keep top under the surface
                if (max_strand < 1) continue;
                if (strand > max_strand) strand = max_strand;

                for (int s = 1; s <= strand; ++s) {
                    std::int32_t wy = H + s;            // from just above floor up
                    if (wy < wy_min || wy > wy_max) continue;
                    int ly = static_cast<int>(wy - wy_min);
                    // Only replace WATER (don't overwrite terrain or air).
                    if (chunk.get(lx, ly, lz) == WATER) {
                        chunk.set(lx, ly, lz, TALL_GRASS);
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 2c. DESERT DECORATION (#18 DESERTS ARE FLAT/DEAD) — sparse, tasteful.
    //     Deserts had no surface interest.  We scatter three cheap features on
    //     desert (and beach) sand, all seam-trivial single-column writes:
    //       * dead bushes / sticks  — MUSHROOM cross-billboard as a dry shrub
    //                                  stand-in (no dedicated dead-bush id exists).
    //       * small rock piles      — a 1-block STONE/GRAVEL bump on the sand.
    //       * cacti                  — a short 2..3 block column.  No green block
    //                                  id exists (is_plant/render only know 36-39
    //                                  and there is no green cube), so we stand in
    //                                  with OAK_LOG as a "cactus trunk".  NOTE:
    //                                  wishes a real `cactus`/green block existed.
    // -------------------------------------------------------------------
    {
        std::uint64_t desert_seed = fmix64(seed ^ 0xDE5E27DEC0DE0001ull);
        for (int lz = 0; lz < kChunkDim; ++lz) {
            for (int lx = 0; lx < kChunkDim; ++lx) {
                int ci = ChunkColumnCache::idx(lx, lz);
                Biome dom = col_cache.dom[ci];
                if (dom != Biome::Desert) continue;    // deserts only (beaches stay bare)

                int H = col_cache.H[ci];
                if (H <= SEA_LEVEL) continue;          // not on dry sand

                std::int32_t wx = wx_min + lx;
                std::int32_t wz = wz_min + lz;
                std::uint64_t dh   = hash2(wx, wz, desert_seed);
                std::uint64_t roll = dh & 0xFFu;

                // Surface must be sand and the block above must be AIR.
                int ly_surf  = H - wy_min;
                int ly_above = ly_surf + 1;
                if (ly_surf < 0 || ly_surf >= kChunkDim) continue;
                if (ly_above < 0 || ly_above >= kChunkDim) continue;
                if (chunk.get(lx, ly_surf, lz) != SAND) continue;
                if (chunk.get(lx, ly_above, lz) != AIR) continue;
                std::int32_t above_wy = H + 1;
                if (above_wy < wy_min || above_wy > wy_max) continue;

                // Sparse: ~10% of desert columns get a feature.  Split between the
                // three feature kinds via the roll value.
                if (roll < 5u) {
                    // Cactus: short 2..3 block OAK_LOG column (green-block stand-in).
                    int cact = 2 + static_cast<int>((dh >> 8u) & 1u);  // 2..3
                    for (int s = 1; s <= cact; ++s) {
                        std::int32_t wy = H + s;
                        if (wy < wy_min || wy > wy_max) continue;
                        int ly = static_cast<int>(wy - wy_min);
                        if (chunk.get(lx, ly, lz) == AIR) chunk.set(lx, ly, lz, OAK_LOG);
                    }
                } else if (roll < 12u) {
                    // Rock pile: a single STONE/GRAVEL bump on the sand.
                    BlockId rb = ((dh >> 8u) & 1u) ? GRAVEL : STONE;
                    chunk.set(lx, ly_above, lz, rb);
                } else if (roll < 26u) {
                    // Dead bush / sticks: MUSHROOM cross-billboard as a dry shrub.
                    chunk.set(lx, ly_above, lz, MUSHROOM);
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 3. STRUCTURES — seam-safe deterministic landmarks scattered across the world.
    //    One candidate per STRUCT_CELL_SIZE×STRUCT_CELL_SIZE region; ~12% spawn chance.
    //    Each structure writes into any chunk it overlaps (additive only).
    // -------------------------------------------------------------------
    {
        // Scan structure cells whose extents could overlap this chunk.
        std::int32_t scx_min = struct_floordiv(wx_min - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
        std::int32_t scx_max = struct_floordiv(wx_max + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
        std::int32_t scz_min = struct_floordiv(wz_min - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
        std::int32_t scz_max = struct_floordiv(wz_max + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);

        // Quick y-range check: structures sit on surface, max STRUCT_MAX_REACH_Y above.
        // If this chunk is entirely far underground, skip.
        // (Surface is roughly y=4..60; structures place blocks y=H-1..H+9 at most.)
        // We allow chunks from wy=-16 upward to be safe.
        if (wy_max >= -16) {
            for (std::int32_t scz = scz_min; scz <= scz_max; ++scz) {
                for (std::int32_t scx = scx_min; scx <= scx_max; ++scx) {
                    StructDesc sd = struct_for_cell(scx, scz, seed);
                    if (!sd.present) continue;

                    // Quick XZ range check before dispatching.
                    if (sd.anchor_wx + STRUCT_MAX_REACH_XZ < wx_min) continue;
                    if (sd.anchor_wx - STRUCT_MAX_REACH_XZ > wx_max) continue;
                    if (sd.anchor_wz + STRUCT_MAX_REACH_XZ < wz_min) continue;
                    if (sd.anchor_wz - STRUCT_MAX_REACH_XZ > wz_max) continue;

                    place_structure(sd, seed, chunk, wx_min, wy_min, wz_min);
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 5. SWAMP CLAY PATCHES — scatter clay blocks in swamp surface.
    //    Clay is placed 1-3 blocks below the surface (replacing stone/dirt).
    // -------------------------------------------------------------------
    {
        std::uint64_t clay_seed = fmix64(seed ^ 0xC1A4C1A4C1A4C1A4ull);

        for (int lz = 0; lz < kChunkDim; ++lz) {
            for (int lx = 0; lx < kChunkDim; ++lx) {
                std::int32_t wx = wx_min + lx;
                std::int32_t wz = wz_min + lz;

                int ci = ChunkColumnCache::idx(lx, lz);
                Biome dom = col_cache.dom[ci];

                if (dom != Biome::Swamp) continue;

                int H = col_cache.H[ci];

                // Clay at H-1 (just below surface dirt).
                std::int32_t clay_wy = H - 1;
                if (clay_wy < wy_min || clay_wy > wy_max) continue;

                int ly_clay = clay_wy - wy_min;
                if (ly_clay < 0 || ly_clay >= kChunkDim) continue;

                std::uint64_t ch = hash2(wx, wz, clay_seed);
                // ~30% clay patches.
                if ((ch & 0xFFu) < 77u) {
                    BlockId cur = chunk.get(lx, ly_clay, lz);
                    if (cur == DIRT || cur == STONE) {
                        chunk.set(lx, ly_clay, lz, CLAY);
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 6. FOREST MOSSY STONE PATCHES — replace some surface stone with mossy stone.
    // -------------------------------------------------------------------
    {
        std::uint64_t moss_seed = fmix64(seed ^ 0x405577EDA40550C0ull);

        for (int lz = 0; lz < kChunkDim; ++lz) {
            for (int lx = 0; lx < kChunkDim; ++lx) {
                std::int32_t wx = wx_min + lx;
                std::int32_t wz = wz_min + lz;

                int ci = ChunkColumnCache::idx(lx, lz);
                Biome dom = col_cache.dom[ci];

                if (dom != Biome::Forest) continue;

                int H = col_cache.H[ci];

                // Mossy stone at H-2 (below dirt layer).
                std::int32_t mwy = H - 2;
                if (mwy < wy_min || mwy > wy_max) continue;

                int ly_m = mwy - wy_min;
                if (ly_m < 0 || ly_m >= kChunkDim) continue;

                std::uint64_t mh = hash2(wx, wz, moss_seed);
                // ~20% mossy stone.
                if ((mh & 0xFFu) < 51u) {
                    BlockId cur = chunk.get(lx, ly_m, lz);
                    if (cur == STONE) {
                        chunk.set(lx, ly_m, lz, MOSSY_STONE);
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 7. ORE VEINS — seam-safe, deterministic underground ore generation.
    //
    // Design:
    //   Veins are anchored on a 3D world grid with cell size ORE_CELL_SIZE
    //   (7 blocks).  For each cell that overlaps this chunk's world volume
    //   (plus a margin equal to the max vein radius), we hash the cell's
    //   anchor world coords to decide:
    //     (a) whether a vein is present at all (type-specific probability),
    //     (b) the ore type (coal/copper/iron/crystal),
    //     (c) the vein size (3..8 blocks) and per-block offsets.
    //
    //   Seam safety: the anchor world pos is a pure function of integer cell
    //   coords × ORE_CELL_SIZE.  Any chunk that overlaps a vein's extent
    //   iterates the same cell and generates the same vein.  Placement only
    //   writes within the current chunk (range-checked).
    //
    //   Depth gates (absolute world-y):
    //     coal_ore   — below y ≤ -2  (shallow underground)
    //     copper_ore — below y ≤ -8  (mid depth)
    //     iron_ore   — below y ≤ -14 (mid-deep)
    //     crystal_ore— below y ≤ -24 (deep only)
    //   These are set well below the max surface height (~60), ensuring ores
    //   never reach the surface (no-surface-holes rule is unaffected).
    //
    //   Density (approx fraction of cells with a vein):
    //     coal   ~12% of coal-eligible cells
    //     copper ~8%
    //     iron   ~5%
    //     crystal~2%
    // -------------------------------------------------------------------
    {
        constexpr int ORE_CELL_SIZE  = 7;   // world blocks per ore cell edge
        constexpr int ORE_VEIN_REACH = 4;   // max vein radius for cell scan margin

        // Absolute world-y ceilings: veins only at or below these y values.
        constexpr std::int32_t COAL_Y_MAX    = -2;
        constexpr std::int32_t COPPER_Y_MAX  = -8;
        constexpr std::int32_t IRON_Y_MAX    = -14;
        constexpr std::int32_t CRYSTAL_Y_MAX = -24;

        // Probability thresholds (out of 256):
        //   coal ~15% → 38/256, copper ~8% → 20/256,
        //   iron ~5%  → 13/256, crystal ~1% → 3/256
        constexpr std::uint64_t COAL_THRESH    = 38u;
        constexpr std::uint64_t COPPER_THRESH  = 20u;
        constexpr std::uint64_t IRON_THRESH    = 13u;
        constexpr std::uint64_t CRYSTAL_THRESH =  3u;

        constexpr std::uint64_t ORE_SEED_MIX = 0x0ACED501DF0ADED5ull;
        std::uint64_t ore_seed = fmix64(seed ^ ORE_SEED_MIX);

        // Helper: floor division for negative coords.
        auto floordiv_ore = [](std::int32_t a, int b) noexcept -> std::int32_t {
            return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
        };

        // Compute cell range that could produce veins overlapping this chunk.
        std::int32_t cell_xmin = floordiv_ore(wx_min - ORE_VEIN_REACH, ORE_CELL_SIZE);
        std::int32_t cell_xmax = floordiv_ore(wx_max + ORE_VEIN_REACH, ORE_CELL_SIZE);
        std::int32_t cell_ymin = floordiv_ore(wy_min - ORE_VEIN_REACH, ORE_CELL_SIZE);
        std::int32_t cell_ymax = floordiv_ore(wy_max + ORE_VEIN_REACH, ORE_CELL_SIZE);
        std::int32_t cell_zmin = floordiv_ore(wz_min - ORE_VEIN_REACH, ORE_CELL_SIZE);
        std::int32_t cell_zmax = floordiv_ore(wz_max + ORE_VEIN_REACH, ORE_CELL_SIZE);

        for (std::int32_t cy_cell = cell_ymin; cy_cell <= cell_ymax; ++cy_cell) {
            // Quick reject: if the entire y-band is above COAL_Y_MAX, skip entirely.
            std::int32_t anchor_wy = cy_cell * ORE_CELL_SIZE;
            if (anchor_wy > COAL_Y_MAX) continue;

            for (std::int32_t cz_cell = cell_zmin; cz_cell <= cell_zmax; ++cz_cell) {
                for (std::int32_t cx_cell = cell_xmin; cx_cell <= cell_xmax; ++cx_cell) {
                    // Hash the 3D cell anchor.
                    std::uint64_t h = hash3(cx_cell, cy_cell, cz_cell, ore_seed);
                    std::uint64_t prob = h & 0xFFu;  // 0..255

                    // Determine ore type and check depth + probability.
                    // We try from rarest to most common so rarest wins when
                    // thresholds would overlap (they don't in absolute depth,
                    // but depth gates prevent that anyway).
                    BlockId ore_id = AIR;
                    if (anchor_wy <= CRYSTAL_Y_MAX && prob < CRYSTAL_THRESH) {
                        ore_id = CRYSTAL_ORE;
                    } else if (anchor_wy <= IRON_Y_MAX && prob < IRON_THRESH) {
                        ore_id = IRON_ORE;
                    } else if (anchor_wy <= COPPER_Y_MAX && prob < COPPER_THRESH) {
                        ore_id = COPPER_ORE;
                    } else if (anchor_wy <= COAL_Y_MAX && prob < COAL_THRESH) {
                        ore_id = COAL_ORE;
                    }

                    if (ore_id == AIR) continue;

                    // Vein size: 3..8 blocks.
                    std::uint64_t h2_ore = fmix64(h ^ 0xABCDEF1234567890ull);
                    int vein_size = 3 + static_cast<int>((h2_ore >> 8u) % 6u);  // 3..8

                    // Generate vein blocks as small deterministic offsets from anchor.
                    // Each block's offset is derived from mixing the vein hash with
                    // its index, giving a compact cluster spread ≤ ORE_VEIN_REACH.
                    for (int vi = 0; vi < vein_size; ++vi) {
                        std::uint64_t bh = fmix64(h2_ore ^ static_cast<std::uint64_t>(vi) * 0x1111222233334444ull);
                        // Offsets in [-3, +3] for each axis.
                        int dx_ore = static_cast<int>((bh >>  0u) % 7u) - 3;
                        int dy_ore = static_cast<int>((bh >>  8u) % 7u) - 3;
                        int dz_ore = static_cast<int>((bh >> 16u) % 7u) - 3;

                        std::int32_t wx_ore = cx_cell * ORE_CELL_SIZE + dx_ore;
                        std::int32_t wy_ore = cy_cell * ORE_CELL_SIZE + dy_ore;
                        std::int32_t wz_ore = cz_cell * ORE_CELL_SIZE + dz_ore;

                        // Must be within this chunk.
                        if (wx_ore < wx_min || wx_ore > wx_max) continue;
                        if (wy_ore < wy_min || wy_ore > wy_max) continue;
                        if (wz_ore < wz_min || wz_ore > wz_max) continue;

                        int lx_ore = static_cast<int>(wx_ore - wx_min);
                        int ly_ore = static_cast<int>(wy_ore - wy_min);
                        int lz_ore = static_cast<int>(wz_ore - wz_min);

                        // Only replace STONE — never air (caves) or other blocks.
                        if (chunk.get(lx_ore, ly_ore, lz_ore) == STONE) {
                            chunk.set(lx_ore, ly_ore, lz_ore, ore_id);
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Public helper: is_cave_entrance wrapper
// ---------------------------------------------------------------------------
bool worldgen_is_cave_entrance(std::int32_t wx, std::int32_t wz,
                                std::uint64_t seed) noexcept {
    return is_cave_entrance(wx, wz, seed);
}

int worldgen_dominant_biome(std::int32_t wx, std::int32_t wz,
                            std::uint64_t seed) noexcept {
    float w[NUM_BIOMES];
    biome_weights(wx, wz, seed, w);
    return static_cast<int>(dominant_biome(w));
}

int worldgen_surface_height(std::int32_t wx, std::int32_t wz,
                            std::uint64_t seed) noexcept {
    float w[NUM_BIOMES];
    biome_weights(wx, wz, seed, w);
    return surface_height(wx, wz, seed, w);
}

int worldgen_count_structures(std::int32_t wx0, std::int32_t wz0,
                              std::int32_t span, std::uint64_t seed) noexcept {
    std::int32_t scx_min = struct_floordiv(wx0, STRUCT_CELL_SIZE);
    std::int32_t scx_max = struct_floordiv(wx0 + span - 1, STRUCT_CELL_SIZE);
    std::int32_t scz_min = struct_floordiv(wz0, STRUCT_CELL_SIZE);
    std::int32_t scz_max = struct_floordiv(wz0 + span - 1, STRUCT_CELL_SIZE);

    int count = 0;
    for (std::int32_t scz = scz_min; scz <= scz_max; ++scz) {
        for (std::int32_t scx = scx_min; scx <= scx_max; ++scx) {
            StructDesc sd = struct_for_cell(scx, scz, seed);
            if (sd.present) ++count;
        }
    }
    return count;
}

// ---------------------------------------------------------------------------
// Terrain fill — per-column block placement
// ---------------------------------------------------------------------------
void TerrainGen::seed(std::uint64_t s) {
    seed_ = s;
}

void TerrainGen::generate(ChunkCoord c, IChunk& chunk) {
    // Precompute the seam-limiter anchor cache once for this chunk so the
    // per-column Lipschitz height is cheap min/max arithmetic (no repeated noise).
    std::int32_t wx_min0 = c.x * kChunkDim;
    std::int32_t wz_min0 = c.z * kChunkDim;
    SeamAnchorCache anchor_cache =
        build_anchor_cache(wx_min0, wz_min0, seed_);

    // Precompute per-column height/biome ONCE for the whole chunk so every pass
    // (terrain fill, swamp, plants, clay, mossy, decorations) reuses them
    // instead of recomputing biome_weights + the cone limiter per pass.
    static thread_local ChunkColumnCache col_cache;
    build_column_cache(wx_min0, wz_min0, seed_, anchor_cache, col_cache);

    // Height lookup that serves in-chunk columns from the column cache and falls
    // back to the cone for the (rare) out-of-chunk neighbour (slope edges).
    auto height_at = [&](std::int32_t wx, std::int32_t wz) -> int {
        int lx = static_cast<int>(wx - wx_min0);
        int lz = static_cast<int>(wz - wz_min0);
        if (lx >= 0 && lx < kChunkDim && lz >= 0 && lz < kChunkDim)
            return col_cache.H[ChunkColumnCache::idx(lx, lz)];
        return surface_height_cached(wx, wz, anchor_cache);
    };

    for (int lz = 0; lz < kChunkDim; ++lz) {
        for (int lx = 0; lx < kChunkDim; ++lx) {
            std::int32_t wx = c.x * kChunkDim + lx;
            std::int32_t wz = c.z * kChunkDim + lz;

            // Reuse precomputed dominant biome and blended surface height.
            int ci = ChunkColumnCache::idx(lx, lz);
            Biome dom = col_cache.dom[ci];
            int H = col_cache.H[ci];

            // -----------------------------------------------------------------
            // Mountain slope detection (seam-safe: uses same continuous height fn).
            // Steep slopes (>=3 blocks drop to neighbour) get stone/cobblestone
            // instead of grass, to read as exposed rock faces.
            // -----------------------------------------------------------------
            bool is_steep = false;
            if (dom == Biome::Mountains && H < SNOW_LINE) {
                // Cached slope: max |H - neighbour| over the 4 orthogonal columns,
                // all within the anchor-cache window.  After the Lipschitz limiter
                // the per-block slope is <=1, so this rarely flags; the rocky look
                // now comes mainly from snow-line stone caps.
                int hN = height_at(wx,     wz - 1);
                int hS = height_at(wx,     wz + 1);
                int hE = height_at(wx + 1, wz);
                int hW = height_at(wx - 1, wz);
                auto ad = [](int a, int b){ int d = a - b; return d < 0 ? -d : d; };
                int slope = ad(H, hN);
                int t = ad(H, hS); if (t > slope) slope = t;
                t = ad(H, hE); if (t > slope) slope = t;
                t = ad(H, hW); if (t > slope) slope = t;
                is_steep = (slope >= 3);
            }

            // -----------------------------------------------------------------
            // Ocean basin (#12): deepen water-biome columns so oceans are
            // actually swimmable rather than 1-2 blocks deep.
            // H_floor is the effective solid-terrain bottom for this column.
            // For submerged ocean columns we lower it by basin_extra blocks;
            // for all other columns H_floor == H (unchanged).
            // -----------------------------------------------------------------
            int basin_extra = 0;
            if (H < SEA_LEVEL) {
                basin_extra = ocean_basin_extra(wx, wz, H, seed_);
            }
            int H_floor = H - basin_extra;  // actual bottom of ocean basin

            // -----------------------------------------------------------------
            // Cave entrance shaft (#11): if this column is the deliberate shaft
            // of a cave entrance, we will carve AIR from the surface down to
            // H - shaft_depth (reaching into normal cave territory).
            // -----------------------------------------------------------------
            int shaft_depth = cave_entrance_depth(wx, wz, seed_);
            bool is_entrance_col = (shaft_depth > 0 && H > SEA_LEVEL);  // only above water

            // Choose surface and fill blocks based on dominant biome + height.
            BlockId surface_block;
            BlockId fill_block;
            bool has_snow = (dom == Biome::Mountains && H >= SNOW_LINE)
                         || (dom == Biome::Snowy);

            switch (dom) {
                case Biome::Desert:
                    surface_block = SAND;
                    fill_block    = SAND;
                    break;
                case Biome::Beach:
                    surface_block = SAND;
                    fill_block    = SAND;
                    break;
                case Biome::Mountains:
                    if (H >= SNOW_LINE) {
                        // High peaks: stone/gravel exposed, snow on very top.
                        surface_block = STONE;
                        fill_block    = STONE;
                    } else if (is_steep) {
                        // Steep slopes: bare stone/cobblestone (rocky face).
                        // Use cobblestone for the very surface, stone beneath.
                        surface_block = COBBLESTONE;
                        fill_block    = STONE;
                    } else if (H >= ROCK_LINE) {
                        // Mid-to-high mountain ground (#6): make mountains read as
                        // genuinely ROCKY rather than grassy hills.  Above ROCK_LINE
                        // the surface becomes a stone/gravel mix (patchy, via a
                        // seam-safe per-column hash) so even sub-snow mountains look
                        // like exposed rock and scree instead of meadow.
                        std::uint64_t rh = hash2(wx, wz,
                            fmix64(seed_ ^ 0x70CC1A4E70CC1A4Eull));
                        // Higher ground => more gravel/stone, less grass.
                        std::uint64_t roll = rh & 0xFFu;
                        int above = H - ROCK_LINE;            // 0..(SNOW_LINE-ROCK_LINE)
                        // rock fraction ramps from ~45% at ROCK_LINE to ~100% at SNOW_LINE.
                        std::uint64_t rock_thresh = 115u
                            + static_cast<std::uint64_t>(above * 9);
                        if (rock_thresh > 255u) rock_thresh = 255u;
                        if (roll < rock_thresh) {
                            surface_block = ((rh >> 8u) & 0x3u) == 0u ? GRAVEL : STONE;
                            fill_block    = STONE;
                        } else {
                            surface_block = GRASS;
                            fill_block    = DIRT;
                        }
                    } else {
                        surface_block = GRASS;
                        fill_block    = DIRT;
                    }
                    break;
                case Biome::Snowy:
                    surface_block = SNOW_LAYER;  // snow on top
                    fill_block    = DIRT;
                    break;
                case Biome::Swamp:
                    surface_block = DIRT;   // muddy surface
                    fill_block    = DIRT;
                    break;
                case Biome::Forest:
                case Biome::Plains:
                default:
                    surface_block = GRASS;
                    fill_block    = DIRT;
                    break;
            }

            for (int ly = 0; ly < kChunkDim; ++ly) {
                std::int32_t wy = c.y * kChunkDim + ly;

                BlockId b;
                if (wy > H) {
                    // Above terrain: water below sea level, air above.
                    if (wy <= SEA_LEVEL) {
                        // Snowy biome: freeze water at the surface.
                        if (has_snow && wy == SEA_LEVEL) {
                            b = ICE;
                        } else {
                            b = WATER;
                        }
                    } else {
                        b = AIR;
                    }
                } else if (wy > H_floor && wy <= H) {
                    // Ocean basin region: below original surface but above basin floor.
                    // These blocks are carved away and filled with water.
                    // (When basin_extra==0 this range is empty and we fall through.)
                    b = WATER;
                } else if (wy == H_floor) {
                    // Effective surface voxel (original H, or basin floor).
                    if (wy <= SEA_LEVEL && dom != Biome::Desert) {
                        // Submerged surface: sand at basin floor.
                        b = SAND;
                    } else {
                        b = surface_block;
                    }
                } else if (wy >= H_floor - 3) {
                    // Sub-surface fill layer (3 blocks below effective floor).
                    if (dom == Biome::Mountains && H >= SNOW_LINE && wy == H_floor - 1) {
                        // Just below peak: gravel for variety.
                        b = GRAVEL;
                    } else if (dom == Biome::Desert) {
                        // Desert: sand fill with a thin stone (sandstone-like) layer.
                        if (wy == H_floor - 3) {
                            b = STONE;
                        } else {
                            b = SAND;
                        }
                    } else {
                        b = fill_block;
                    }
                } else {
                    b = STONE;
                }

                // -----------------------------------------------------------------
                // Cave entrance shaft carving (#11).
                // For entrance columns only: carve AIR from the surface top
                // (H) down to H - shaft_depth, creating a deliberate opening.
                // The shaft connects the surface to the depth where normal
                // cave noise is active (> CAVE_SURFACE_MARGIN below H).
                // This is additive carving that overrides terrain; we only
                // carve within the shaft depth range and only for solid blocks.
                // -----------------------------------------------------------------
                if (is_entrance_col && b != WATER) {
                    if (wy <= H && wy > H - shaft_depth) {
                        b = AIR;
                    }
                }

                // -----------------------------------------------------------------
                // Cave carving.
                // FIX: surface margin raised from 2 to CAVE_SURFACE_MARGIN (6).
                // This prevents AIR pockets within the top 5 blocks under the
                // surface, eliminating the "holes in hilltops" feedback.
                // Caves still exist well underground.
                // Entrance columns bypass the margin for the shaft blocks (handled
                // above), so normal cave carving still applies below the shaft.
                //
                // For ocean basin columns the effective surface is H_floor (the
                // carved basin bottom), so we apply the margin relative to H_floor
                // to prevent cave pockets directly under the ocean floor.
                // -----------------------------------------------------------------
                std::int32_t cave_surface_ref = H_floor;  // use basin floor for ocean cols
                if (b != AIR && b != WATER && wy < cave_surface_ref - CAVE_SURFACE_MARGIN
                             && wy > kColumnMinY + 4) {
                    float fwx = static_cast<float>(wx);
                    float fwy = static_cast<float>(wy);
                    float fwz = static_cast<float>(wz);
                    std::uint64_t cseed = fmix64(seed_ ^ 0xCA4E5EED1234ull);
                    float cave = fbm3(fwx, fwy, fwz, cseed, /*octaves=*/3,
                                      /*base_freq=*/1.0f / 16.0f);
                    if (cave > CAVE_THRESH) {
                        b = AIR;
                    }
                }

                chunk.set(lx, ly, lz, b);
            }

            // Snow layer on top of mountain peaks (placed after the column loop).
            // We place SNOW_LAYER one block ABOVE the terrain surface if it is AIR.
            // This creates a visible snow cap without changing the height function.
            if (dom == Biome::Mountains && H >= SNOW_LINE) {
                std::int32_t snow_wy = H + 1;
                std::int32_t snow_ly = snow_wy - c.y * kChunkDim;
                if (snow_ly >= 0 && snow_ly < kChunkDim) {
                    if (chunk.get(lx, static_cast<int>(snow_ly), lz) == AIR) {
                        chunk.set(lx, static_cast<int>(snow_ly), lz, SNOW_LAYER);
                    }
                }
            }
        }
    }

    // Swamp water pools: fill low-lying swamp columns with water up to SEA_LEVEL.
    // This is done in a second pass so we don't interfere with the first.
    for (int lz = 0; lz < kChunkDim; ++lz) {
        for (int lx = 0; lx < kChunkDim; ++lx) {
            int ci = ChunkColumnCache::idx(lx, lz);
            Biome dom = col_cache.dom[ci];

            if (dom != Biome::Swamp) continue;

            int H = col_cache.H[ci];
            // Swamp pools: columns at or below SEA_LEVEL+1 that are fully AIR
            // above H get filled with water up to SEA_LEVEL.
            if (H <= SEA_LEVEL + 1) {
                for (int ly = 0; ly < kChunkDim; ++ly) {
                    std::int32_t wy = c.y * kChunkDim + ly;
                    if (wy > H && wy <= SEA_LEVEL) {
                        if (chunk.get(lx, ly, lz) == AIR) {
                            chunk.set(lx, ly, lz, WATER);
                        }
                    }
                }
            }
        }
    }

    // Decoration pass — seam-aware tree and plant scatter.
    place_decorations(c, chunk, seed_, anchor_cache, col_cache);
}

// ---------------------------------------------------------------------------
// content_hash: generate into temp chunk and hash all 4096 block ids (FNV-1a)
// ---------------------------------------------------------------------------
std::uint64_t TerrainGen::content_hash(ChunkCoord c) const {
    PaletteChunk tmp(c, AIR);
    const_cast<TerrainGen*>(this)->generate(c, tmp);

    constexpr std::uint64_t FNV_OFFSET = 14695981039346656037ull;
    constexpr std::uint64_t FNV_PRIME  = 1099511628211ull;

    std::uint64_t h = FNV_OFFSET;
    for (int lz = 0; lz < kChunkDim; ++lz) {
        for (int ly = 0; ly < kChunkDim; ++ly) {
            for (int lx = 0; lx < kChunkDim; ++lx) {
                BlockId b = tmp.get(lx, ly, lz);
                h ^= static_cast<std::uint64_t>(b & 0xFFu);
                h *= FNV_PRIME;
                h ^= static_cast<std::uint64_t>((b >> 8u) & 0xFFu);
                h *= FNV_PRIME;
            }
        }
    }
    return h;
}

} // namespace bf
