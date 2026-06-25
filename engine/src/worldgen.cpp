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
static constexpr BlockId STONE_BRICK   = 8;
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
static constexpr BlockId WOOD_BEAM     = 51;   // cube-rendered timber for buildings (logs are cylinders now)
static constexpr BlockId BIRCH_LOG     = 22;
static constexpr BlockId BIRCH_PLANKS  = 23;
static constexpr BlockId GLASS_PANE    = 25;
static constexpr BlockId BIRCH_LEAVES  = 27;
static constexpr BlockId PINE_LEAVES   = 48;   // #62 conifer needles (rendered as cones)
static constexpr BlockId PINE_LOG      = 49;   // #62 conifer trunk (pine leaves belong on pine wood)
static constexpr BlockId WOOL_BLOCK    = 28;
static constexpr BlockId MOSSY_STONE   = 29;
static constexpr BlockId CHEST         = 31;
static constexpr BlockId TORCH         = 32;
static constexpr BlockId OAK_DOOR      = 33;
static constexpr BlockId CRYSTAL_LAMP  = 35;
static constexpr BlockId FLOWER_RED    = 36;
static constexpr BlockId FLOWER_YELLOW = 37;
static constexpr BlockId TALL_GRASS    = 38;
static constexpr BlockId MUSHROOM      = 39;
static constexpr BlockId COLOR_CRYSTAL = 40;   // glowing cave crystal; drops color_dust (#41 quest)
static constexpr BlockId PEBBLE        = 41;   // small surface rock prop (#51 m2)
static constexpr BlockId BERRY_BUSH    = 42;   // leafy bush w/ berries (#51 m2)
static constexpr BlockId REED          = 43;   // cattail reeds in wetlands (#58)
static constexpr BlockId CACTUS_PLANT  = 44;   // desert cactus (#58)
static constexpr BlockId SEASHELL      = 45;   // beach/shore seashell (#58)
static constexpr BlockId LILY_PAD      = 46;   // floats on shallow marsh/pond water (#58)
static constexpr BlockId FALLEN_STICK  = 47;   // twig on the forest floor (#58)

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
// Cave entrance system (#11 / #37 — surface-connected, VISUALLY VARIED openings)
// ---------------------------------------------------------------------------
// A sparse grid (ENTRANCE_CELL_SIZE blocks per cell) places deliberate cave
// MOUTHS the player can discover from the surface and climb/drop into.  Issue
// #37: instead of a single plain 2×2 vertical shaft, each cell rolls one of
// three deterministic entrance SHAPES, all of which carve down far enough to
// meet the cave-noise region below so they are genuinely enterable:
//
//   ENTR_SINKHOLE — a roughly circular funnel pit: wide at the surface (radius
//                   ~R) and narrowing as it descends (deepest at the centre,
//                   shallow at the rim) so it reads as a collapsed sink.
//   ENTR_RAVINE   — a long narrow crack a few blocks wide running along X or Z
//                   for a dozen-ish blocks, dropping straight down to a floor.
//   ENTR_POTHOLE  — the classic compact 2×2 (occasionally 3×3) vertical shaft,
//                   kept for variety as a small "pothole" mouth.
//
// Determinism / seam-safety: the entrance position, shape, size and orientation
// are ALL pure functions of the cell integer coords × cell size (a global hash),
// so any chunk overlapping the mouth computes the identical footprint and the
// identical per-column carve depth.  Carving happens per column in the terrain
// fill, using cave_entrance_depth(wx,wz) — the depth a given column is carved to
// (0 if the column is not part of any mouth).
//
// The no-surface-holes test exempts these columns (worldgen_is_cave_entrance):
// by design the surface block IS the lip of the opening and the blocks below it
// are AIR.  is_cave_entrance() and cave_entrance_depth() share the SAME
// footprint logic so the exemption and the carve always agree.
// ---------------------------------------------------------------------------
static constexpr int  ENTRANCE_CELL_SIZE  = 24;    // one candidate per 24×24 region (denser, was 32)
static constexpr std::uint64_t ENTRANCE_SEED_MIX = 0xCA4E5EE7E57A4CE5ull;

// Probability threshold: ~45% of cells spawn an entrance (out of 256).  Smaller
// cells + higher probability => a player reliably finds a mouth within a short
// walk (#37 "discover caves via interesting surface entrances").
static constexpr std::uint64_t ENTRANCE_PROB_THRESH = 115u;  // 115/256 ≈ 45%

// Entrance shape codes.
static constexpr int ENTR_POTHOLE  = 0;
static constexpr int ENTR_SINKHOLE = 1;
static constexpr int ENTR_RAVINE   = 2;

// Carve-floor depth below surface: every mouth carves AT LEAST this far so it
// reaches past CAVE_SURFACE_MARGIN into the cave-noise region (connecting it to
// the cave system below).  Deepest columns of a mouth reach this; rim/edge
// columns carve shallower to give funnels/ravines their shape.
static constexpr int ENTRANCE_FLOOR_MIN = 12;
static constexpr int ENTRANCE_FLOOR_MAX = 18;

// Sinkhole radius (top opening half-width) and ravine half-width / length.
static constexpr int SINKHOLE_R_MIN = 3;
static constexpr int SINKHOLE_R_MAX = 5;
static constexpr int RAVINE_HALF_W  = 1;   // width = 2*half+1 (3 blocks)
static constexpr int RAVINE_LEN_MIN = 8;
static constexpr int RAVINE_LEN_MAX = 14;

// Max XZ reach of any mouth from its anchor (conservative bound for the
// neighbour-cell scan in is_cave_entrance / cave_entrance_depth).  The widest
// shape is a ravine of half-length up to 7 plus the +X cell offset slack.
static constexpr int ENTRANCE_MAX_REACH = SINKHOLE_R_MAX > (RAVINE_LEN_MAX / 2 + RAVINE_HALF_W)
                                        ? SINKHOLE_R_MAX : (RAVINE_LEN_MAX / 2 + RAVINE_HALF_W);

struct EntranceDesc {
    std::int32_t wx;       // world X of mouth anchor (centre)
    std::int32_t wz;       // world Z of mouth anchor (centre)
    int          shape;    // ENTR_* code
    int          floor;    // deepest carve depth below surface (centre/floor)
    int          radius;   // sinkhole radius
    int          half_len; // ravine half-length (along its axis)
    bool         ravine_x; // ravine runs along X (else Z)
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
        return EntranceDesc{0, 0, 0, 0, 0, 0, false, false};
    }

    std::uint64_t h2 = fmix64(h ^ 0xE57A4CE5CA4EF00Dull);

    // Anchor offset within the cell — kept away from cell edges so the widest
    // shape (sinkhole radius / ravine half-length) plus its reach never escapes
    // the neighbour scan window.  Margin = ENTRANCE_MAX_REACH.
    int span = ENTRANCE_CELL_SIZE - 2 * ENTRANCE_MAX_REACH;
    if (span < 1) span = 1;
    std::int32_t off_x = ENTRANCE_MAX_REACH + static_cast<std::int32_t>(
        (h2 >> 0u)  % static_cast<std::uint64_t>(span));
    std::int32_t off_z = ENTRANCE_MAX_REACH + static_cast<std::int32_t>(
        (h2 >> 16u) % static_cast<std::uint64_t>(span));

    // Shape: ~40% sinkhole, ~35% ravine, ~25% pothole.
    std::uint64_t shape_roll = (h2 >> 32u) & 0xFFu;
    int shape = (shape_roll < 102u) ? ENTR_SINKHOLE
              : (shape_roll < 191u) ? ENTR_RAVINE
              :                       ENTR_POTHOLE;

    int floor = ENTRANCE_FLOOR_MIN
              + static_cast<int>((h2 >> 40u) % static_cast<std::uint64_t>(
                    ENTRANCE_FLOOR_MAX - ENTRANCE_FLOOR_MIN + 1));

    int radius = SINKHOLE_R_MIN
               + static_cast<int>((h2 >> 44u) % static_cast<std::uint64_t>(
                     SINKHOLE_R_MAX - SINKHOLE_R_MIN + 1));

    int half_len = (RAVINE_LEN_MIN
               + static_cast<int>((h2 >> 48u) % static_cast<std::uint64_t>(
                     RAVINE_LEN_MAX - RAVINE_LEN_MIN + 1))) / 2;

    bool ravine_x = ((h2 >> 52u) & 1u) != 0u;

    return EntranceDesc{
        ecx * ENTRANCE_CELL_SIZE + off_x,
        ecz * ENTRANCE_CELL_SIZE + off_z,
        shape, floor, radius, half_len, ravine_x,
        true
    };
}

// Per-column carve depth for one mouth: how many blocks below this column's own
// surface should be AIR (0 if the column is outside this mouth's footprint).
// Shape-dependent so sinkholes funnel and ravines form a slot.  PURE function of
// (column, EntranceDesc) — identical from every chunk that overlaps the mouth.
static int entrance_depth_in(const EntranceDesc& ed,
                             std::int32_t wx, std::int32_t wz) noexcept {
    std::int32_t dx = wx - ed.wx;
    std::int32_t dz = wz - ed.wz;
    switch (ed.shape) {
        case ENTR_SINKHOLE: {
            // Circular footprint of radius `radius`; depth ramps from a shallow
            // rim to the full floor at the centre (funnel).
            int r2   = static_cast<int>(dx * dx + dz * dz);
            int rad  = ed.radius;
            if (r2 > rad * rad) return 0;
            // dist 0..rad  ->  depth floor..(floor - rim_drop), min 1.
            // Use the radial distance to scale: centre deepest, rim shallow but
            // still open (so the rim is a visible lip, not flush ground).
            double dist = std::sqrt(static_cast<double>(r2));
            double t    = dist / static_cast<double>(rad);          // 0 centre .. 1 rim
            int depth = static_cast<int>(static_cast<double>(ed.floor) * (1.0 - 0.55 * t));
            if (depth < 4) depth = 4;     // rim still clearly open
            return depth;
        }
        case ENTR_RAVINE: {
            // #63: a WIDE, SHALLOW, gentle V-gully, not a deep narrow slot. The first
            // pass kept a deep centre slot with big shoulder steps, so you could still
            // drop into it. Now the depth ramps SMOOTHLY from the centre line out to the
            // rim over many columns (~1-2 block steps), and the whole thing is capped
            // shallow, so a ravine reads as a natural gully you can see coming and climb
            // out of with little effort. A per-column hash keeps the rim jagged.
            std::int32_t along  = ed.ravine_x ? dx : dz;
            std::int32_t across = ed.ravine_x ? dz : dx;
            if (along < -ed.half_len || along > ed.half_len) return 0;
            int aa = static_cast<int>(across < 0 ? -across : across);
            const int halfW = RAVINE_HALF_W + 5;       // wide gully (half-width ~6, ~13 wide)
            if (aa > halfW) return 0;
            int cap   = ed.floor < 9 ? ed.floor : 9;   // shallow: never a deep drop
            int depth = (cap * (halfW - aa)) / halfW;  // deepest at centre, 0 at the rim
            int a = static_cast<int>(along < 0 ? -along : along);
            depth -= a / 6;                             // taper toward the ends
            std::uint64_t jh = hash2(wx, wz, 0x9E3779B97F4A7C15ull);
            depth += static_cast<int>(jh % 3u) - 1;    // jagged rim
            if (depth < 1) return 0;
            return depth;
        }
        default: {  // ENTR_POTHOLE — a SMALL, SHALLOW dimple, not a deep sharp 2×2 shaft.
            // A 5-column plus (centre + 4 arms): stays a "small" mouth for variety,
            // but capped shallow and stepped so you can never fall 20 blocks into a
            // tight pit and can hop straight back out.  (#: ravines/holes too sharp)
            int r2 = static_cast<int>(dx * dx + dz * dz);
            if (r2 > 1) return 0;
            int pf = ed.floor < 6 ? ed.floor : 6;       // shallow cap
            if (r2 == 0) return pf;                     // centre
            return pf - 2;                              // arms: a step up out of the centre
        }
    }
}

// Sum of the entrance footprint across the owning cell and its neighbours.
// Returns the deepest carve depth at (wx,wz) over all overlapping mouths (0 if
// none).  is_cave_entrance() is just (depth > 0).
static int cave_entrance_depth(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept {
    std::int32_t ecx = entrance_floordiv(wx, ENTRANCE_CELL_SIZE);
    std::int32_t ecz = entrance_floordiv(wz, ENTRANCE_CELL_SIZE);
    int best = 0;
    for (std::int32_t dce = -1; dce <= 1; ++dce) {
        for (std::int32_t dcf = -1; dcf <= 1; ++dcf) {
            EntranceDesc ed = entrance_for_cell(ecx + dce, ecz + dcf, seed);
            if (!ed.present) continue;
            int d = entrance_depth_in(ed, wx, wz);
            if (d > best) best = d;
        }
    }
    return best;
}

// Returns true if the world column (wx, wz) is part of any cave entrance mouth.
// Used by the public wrapper (tests) to exempt these columns from the no-holes
// check.  Shares entrance_depth_in()'s footprint exactly with the carver.
static bool is_cave_entrance(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept {
    return cave_entrance_depth(wx, wz, seed) > 0;
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
    {  5.0f,   1.2f,  1.0f/56.0f,  3,     0.45f },  // Swamp (marsh: lowered so more sits under sea level → wetter, fewer dry patches, #57/#64)
    {  6.5f,   1.0f,  1.0f/96.0f,  2,     0.40f },  // Beach (extremely flat near sea)
};

// Re-spaced for the widened (post-spread) climate field (#6).  With the climate
// spread pushing T/M toward the corners, the centres are repositioned so every
// biome occupies a healthy, roughly-equal share of the map (verified ~10-25%
// each across many seeds — desert/snowy/swamp went from ~0-1% to ~7-18%).
// Extreme-biome catchment widened (#6): even with smaller zones, a region whose
// climate is biased away from an extreme (e.g. a cool-moist area) could still leave
// desert/swamp/snowy at <1% near a given spawn.  Widening the radii of the three
// corner biomes lets them win more border columns so they reliably punch through
// (verified: min biome share near origin across seeds 1..12 rose to >=3%), without
// letting any one biome dominate (still <40% on every seed).
static constexpr BiomeCentre BIOME_CENTRES[NUM_BIOMES] = {
    // temp  moist  r_t    r_m
    { 0.50f, 0.50f, 0.24f, 0.24f },  // Plains   (temperate, mid moisture)
    { 0.58f, 0.78f, 0.20f, 0.18f },  // Forest   (warm, wet — dense trees)
    { 0.20f, 0.35f, 0.27f, 0.32f },  // Mountains(cool, drier — rocky)
    { 0.85f, 0.18f, 0.28f, 0.28f },  // Desert   (hot, dry — sand)
    { 0.15f, 0.55f, 0.26f, 0.34f },  // Snowy    (very cold — snow)
    { 0.45f, 0.92f, 0.34f, 0.26f },  // Swamp    (wettest — mud + pools)
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

// Sample the (temperature, moisture) climate at a world column.  Shared by the
// smooth weight blend (height field) and the Voronoi biome-type map (#6) so both
// read the SAME climate field — the Voronoi sites just classify the climate at a
// jittered lattice of points and the height blend reads it per column.
static void sample_climate(std::int32_t wx, std::int32_t wz, std::uint64_t seed,
                           float& temp, float& moist) noexcept {
    std::uint64_t tseed = fmix64(seed ^ 0xB10E5EED00000001ull);
    std::uint64_t mseed = fmix64(seed ^ 0xB10E5EED00000002ull);
    float fwx = static_cast<float>(wx);
    float fwz = static_cast<float>(wz);
    static constexpr float BIOME_NOISE_FREQ = 1.0f / 72.0f;
    temp  = climate_spread(fbm2(fwx, fwz, tseed, /*octaves=*/3, BIOME_NOISE_FREQ));
    moist = climate_spread(fbm2(fwx, fwz, mseed, /*octaves=*/3, BIOME_NOISE_FREQ));
}

// Classify a (temperature, moisture) climate point to the single best-matching
// biome — the biome whose centre is nearest in the normalised (T,M) metric.
// This is the argmax of the same tent kernel biome_weights uses, so the Voronoi
// site biomes are consistent with the smooth weight field.
static int classify_climate(float temp, float moist) noexcept {
    int   best_i = 0;
    float best_d = 1e30f;
    for (int i = 0; i < NUM_BIOMES; ++i) {
        const BiomeCentre& bc = BIOME_CENTRES[i];
        float dt = (temp  - bc.temp)  / bc.radius_t;
        float dm = (moist - bc.moist) / bc.radius_m;
        float d2 = dt * dt + dm * dm;
        if (d2 < best_d) { best_d = d2; best_i = i; }
    }
    return best_i;
}

static void biome_weights(std::int32_t wx, std::int32_t wz, std::uint64_t seed,
                          float weights[NUM_BIOMES]) noexcept {
    float temp, moist;
    sample_climate(wx, wz, seed, temp, moist);

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

// ---------------------------------------------------------------------------
// Voronoi biome map (#6 BIOMES MIX IN A GRID — the fix)
// ---------------------------------------------------------------------------
// The old design picked the biome TYPE by argmax of the smooth (T,M) weight
// field.  Near a boundary that argmax flickered between 2-4 biomes block-to-block
// (the noisy weights traded the lead back and forth), so a few blocks of walking
// touched many biomes in a checkerboard — exactly the reported #6 mixing.
//
// We replace the TYPE decision with a cellular/Voronoi map that is contiguous by
// construction with a single clean edge between any two regions:
//
//   * The world is tiled by a coarse BIOME_CELL grid.  Each cell carries ONE
//     jittered "site" point, placed deterministically from the cell hash.
//   * Each site is assigned ONE biome by classifying the climate sampled AT the
//     site point (classify_climate) — so site biomes still follow temperature/
//     moisture and every biome appears, but each is committed once per cell.
//   * A column's biome = the biome of the NEAREST site (standard Voronoi).
//
// Why this kills the flicker: the "nearest site" function is piecewise-constant
// and changes value EXACTLY ONCE across the perpendicular bisector between two
// neighbouring sites.  So along any walk the biome is constant within a cell's
// catchment and flips a single clean time at each border — no A-B-A-C chatter,
// and every region is one contiguous blob whose minimum width is ~the cell size.
//
// Determinism / thread-safety: pure function of (wx,wz,seed) — integer cell
// coords + hashes, no statics.  Seam safety is UNAFFECTED: the height field still
// comes from the smooth weight blend + Lipschitz limiter (unchanged).  The biome
// TYPE only selects surface blocks / features, which need no cross-column slope
// continuity (a sand-next-to-grass edge is fine and intended).
//
// Cell size 44 with ±~33% jitter gives regions roughly 40-75 blocks across, so a
// ±256 transect crosses ~7-12 distinct biomes — several, but each clean.
// ---------------------------------------------------------------------------
static constexpr int BIOME_CELL = 44;
static constexpr std::uint64_t VORONOI_SEED_MIX = 0x901A0701B10E5EEDull;

static std::int32_t voronoi_floordiv(std::int32_t a, int b) noexcept {
    return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
}

// Resolved Voronoi cell: jittered site world position + its committed biome.
struct VoronoiCell { float sx; float sz; int biome; };

// Compute a cell's site position and biome from scratch (the expensive path:
// classifies the climate sampled AT the site point).  Pure fn of (cell,seed).
static VoronoiCell voronoi_cell_compute(std::int32_t cx, std::int32_t cz,
                                        std::uint64_t vseed, std::uint64_t seed) noexcept {
    std::uint64_t h = hash2(cx, cz, vseed);
    // Jitter within the central ~2/3 of the cell so sites never coincide on the
    // cell border (keeps every cell's catchment non-degenerate).
    float jx = (static_cast<float>((h >>  0u) & 0xFFFFu) / 65535.0f - 0.5f) * 0.66f;
    float jz = (static_cast<float>((h >> 16u) & 0xFFFFu) / 65535.0f - 0.5f) * 0.66f;
    float sx = (static_cast<float>(cx) + 0.5f + jx) * static_cast<float>(BIOME_CELL);
    float sz = (static_cast<float>(cz) + 0.5f + jz) * static_cast<float>(BIOME_CELL);
    float temp, moist;
    sample_climate(static_cast<std::int32_t>(sx + 0.5f),
                   static_cast<std::int32_t>(sz + 0.5f), seed, temp, moist);
    return VoronoiCell{sx, sz, classify_climate(temp, moist)};
}

// PERFORMANCE: the Voronoi TYPE map is queried per column (256× per chunk) and
// every query inspects a 3×3 cell neighbourhood — but a whole chunk spans only a
// handful of cells (BIOME_CELL=44).  Each cell resolution costs 2×3-octave fbm2
// (the climate sample) which dominates, so we memoise resolved cells in a small
// direct-mapped thread_local cache keyed by (cx,cz,seed).  Pure fn of its key →
// determinism + thread-safety hold (per-thread table, identical inputs ⇒
// identical output regardless of cache state).  Mirrors AnchorMemo's pattern.
namespace {
struct VoronoiMemo {
    static constexpr std::size_t N = 1024;  // power of two
    struct Slot { std::int32_t cx; std::int32_t cz; std::uint64_t seed; VoronoiCell cell; bool valid; };
    Slot slots[N];
    VoronoiMemo() noexcept { for (auto& s : slots) s.valid = false; }

    VoronoiCell get(std::int32_t cx, std::int32_t cz,
                    std::uint64_t vseed, std::uint64_t seed) noexcept {
        std::uint64_t key = hash2(cx, cz, seed ^ 0x509A0701B10E5EEDull);
        std::size_t i = static_cast<std::size_t>(key) & (N - 1);
        Slot& s = slots[i];
        if (s.valid && s.cx == cx && s.cz == cz && s.seed == seed) return s.cell;
        s.cell = voronoi_cell_compute(cx, cz, vseed, seed);
        s.cx = cx; s.cz = cz; s.seed = seed; s.valid = true;
        return s.cell;
    }
};
}  // namespace

// The single biome TYPE at a world column: nearest Voronoi site's biome.
static Biome voronoi_biome(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept {
    std::uint64_t vseed = fmix64(seed ^ VORONOI_SEED_MIX);
    std::int32_t cx = voronoi_floordiv(wx, BIOME_CELL);
    std::int32_t cz = voronoi_floordiv(wz, BIOME_CELL);

    float fwx = static_cast<float>(wx);
    float fwz = static_cast<float>(wz);

    static thread_local VoronoiMemo memo;

    float best_d2 = 1e30f;
    int   best_biome = 0;
    // 3×3 neighbourhood is sufficient: with jitter bounded to ±0.33 cell, the
    // nearest site is always in the owning cell or an immediate neighbour.
    for (std::int32_t dz = -1; dz <= 1; ++dz) {
        for (std::int32_t dx = -1; dx <= 1; ++dx) {
            VoronoiCell vc = memo.get(cx + dx, cz + dz, vseed, seed);
            float ex = fwx - vc.sx;
            float ez = fwz - vc.sz;
            float d2 = ex * ex + ez * ez;
            if (d2 < best_d2) {
                best_d2 = d2;
                best_biome = vc.biome;
            }
        }
    }
    return static_cast<Biome>(best_biome);
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
// ---------------------------------------------------------------------------
// Rivers (#60): winding water valleys, not carved channels.
// ---------------------------------------------------------------------------
// A river is the zero-contour of a low-frequency noise: where the noise sits near
// its median we sink the terrain into a smooth valley. Where that valley floor dips
// below sea level it fills with water, giving a meandering river. This is added to
// the RAW height, so the downstream 1-Lipschitz cone limiter both keeps it seam-safe
// and naturally widens it into gentle, climbable banks (no carved cliffs). Pure
// function of (wx,wz,seed). Deserts get no rivers (dry).
static constexpr float RIVER_FREQ  = 1.0f / 130.0f;  // meander scale
static constexpr float RIVER_HALFW = 0.040f;         // noise-space half width of a valley
static constexpr float RIVER_DEPTH = 9.0f;           // blocks the valley sinks at its centre
static float river_lower(float fwx, float fwz, std::uint64_t seed) noexcept {
    std::uint64_t rseed = fmix64(seed ^ 0x515E12D32C0DE011ull);
    float n = fbm2(fwx, fwz, rseed, 2, RIVER_FREQ, 2.0f, 0.5f);  // ~[0,1], bell around 0.5
    float d = n - 0.5f; if (d < 0.0f) d = -d;                    // distance from the median contour
    if (d >= RIVER_HALFW) return 0.0f;
    float t = 1.0f - d / RIVER_HALFW;          // 1 at the centreline .. 0 at the bank
    t = t * t * (3.0f - 2.0f * t);             // smoothstep valley profile
    return RIVER_DEPTH * t;
}

// Continentalness (#60): a very-low-frequency field that lifts inland "continent"
// regions and sinks "ocean" regions, so scattered inland flooding shrinks to rivers
// and lakes while open water gathers into genuine oceans. Gradual (huge scale), so it
// keeps within-chunk plains flatness and rides safely through the seam limiter.
static constexpr float CONTINENT_FREQ = 1.0f / 640.0f;
static constexpr float CONTINENT_AMP  = 6.0f;
static float continental_lift(float fwx, float fwz, std::uint64_t seed) noexcept {
    std::uint64_t cseed = fmix64(seed ^ 0xC0117E17A15C0DE1ull);
    float c = fbm2(fwx, fwz, cseed, 2, CONTINENT_FREQ, 2.0f, 0.5f);  // ~[0,1], bell ~0.5
    // LIFT-ONLY: raise inland continents so their fBm dips stop reaching sea level,
    // but never sink terrain (sinking would drown structure sites, which need
    // H > SEA_LEVEL, and deepen oceans we do not want). Open water stays where the
    // land is naturally low; the inland just gets drier.
    float t = (c - 0.46f) / 0.18f;
    if (t < 0.0f) t = 0.0f;
    if (t > 1.0f) t = 1.0f;
    return t * CONTINENT_AMP;
}

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

    // #60 continentalness: lift inland, sink oceans, so water concentrates into real
    // oceans and the inland reads as rivers and lakes rather than scattered seas.
    blended_h += continental_lift(fwx, fwz, seed);

    // #60 rivers: sink a meandering valley into the blended height. Faded out in
    // desert (dry) so we don't get rivers running through dunes.
    float desert_w = weights[static_cast<int>(Biome::Desert)];
    blended_h -= river_lower(fwx, fwz, seed) * (1.0f - desert_w);

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
            // Biome TYPE comes from the Voronoi map (#6 — contiguous, clean edge),
            // NOT the smooth-weight argmax (which flickered near borders).  The
            // smooth weights are still used for the blended height field only.
            out.dom[i] = voronoi_biome(wx, wz, seed);
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
    // #22 NATURALNESS (extended):
    std::uint64_t leaf_hash;     // drives the per-voxel irregular-edge "nibble" so
                                 // canopies are ragged, not perfect blobs.  Pure
                                 // function of the cell hash → seam-consistent.
    int          sparse;         // 0 = full crown, 1 = sparse/airy crown (more nibble)
    int          extra_skirt;    // extra lower leaf tiers for "elder" trees (0 normally,
                                 // 1 = one extra skirt ring 1 below the canopy bottom)
};

// Default-constructed "no tree" descriptor (keeps all the new fields zeroed so the
// many early-out return paths don't have to spell every field out).
static constexpr TreeDesc NO_TREE = TreeDesc{
    0, 0, 0, 0, 0, 0, /*present=*/false, false, 0, 0, 0, 0, /*leaf_hash=*/0, 0, 0
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
    // Biome TYPE from the Voronoi map (#6) so trees match the contiguous biome
    // regions rather than the flickery smooth-weight argmax.
    Biome dom = voronoi_biome(cell_centre_x, cell_centre_z, seed);

    // Biomes that never have trees.
    if (dom == Biome::Desert || dom == Biome::Beach) {
        return NO_TREE;
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
        return NO_TREE;
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
    // #22 NATURALNESS: a separate stream drives the per-voxel irregular-edge
    // nibble + the per-tree size/sparseness rolls, so these don't perturb the
    // trunk/canopy/lean/branch bit assignments above.
    std::uint64_t leaf_hash   = fmix64(h2 ^ 0x1EAF5EED1EAF5EEDull);
    // ~30% of (non-pine) trees get an airy/sparse crown for shape variety.
    int sparse = ((leaf_hash >> 40u) & 0x7u) <= 1u ? 1 : 0;
    int extra_skirt = 0;

    // #22 RARE "ELDER" tree: a giant that towers over the canopy — trunk 13..16,
    // a full GIANT crown PLUS an extra lower skirt tier, always thick, full arms.
    // ~1.5% of non-desert/beach cells (giant_bits==0 AND an extra rare gate), so
    // a forest occasionally has a true landmark tree.  Canopy stays within ±4 XZ
    // (the seam scan margin) — only the trunk/skirt change, so seam-safety holds.
    bool elder = (giant_bits == 0u) && (((leaf_hash >> 8u) & 0x3u) == 0u);

    // Rare GIANT tree: appears ~6% of non-desert/beach cells regardless of biome.
    // Trunk 10..12 (elder: 13..16), giant canopy, always oak, always thick trunk.
    // Giants get the full set of arms for a gnarled, characterful silhouette.
    if (giant_bits == 0u && dom != Biome::Desert && dom != Biome::Beach) {
        trunk_h      = elder ? (13 + static_cast<int>(trunk_bits % 4u))   // 13..16
                             : (10 + static_cast<int>(trunk_bits % 3u));  // 10..12
        canopy_shape = CANOPY_GIANT;
        is_birch     = false;
        return TreeDesc{
            cell_origin_x + off_x,
            cell_origin_z + off_z,
            trunk_h, canopy_shape,
            OAK_LOG, OAK_LEAVES,
            true,
            /*thick_trunk=*/false,  // #62: giants stay 1 block wide too
            /*lean_dx=*/0, /*lean_dz=*/0,
            /*branch_count=*/MAX_BRANCHES, branch_hash,
            leaf_hash, /*sparse=*/0, /*extra_skirt=*/(elder ? 1 : 0)
        };
    }

    // #22 SAPLING / small bushy tree: ~12% of remaining cells become a very short
    // bush — trunk 2..3, a tight COMPACT crown, no branches.  Mixed in among the
    // standard trees this gives the "small saplings next to mature trees" look and
    // keeps forests walkable (a low bush is easy to step around).
    bool sapling = (((leaf_hash >> 16u) & 0x7u) == 0u);
    if (sapling) {
        int strunk = 2 + static_cast<int>(trunk_bits % 2u);   // 2..3
        bool sbirch = (birch_bits == 0u);                      // 25% birch sapling
        // Lean is fine on saplings too (a windswept little bush), reuse gate below.
        if (lean_gate <= 1u) {
            switch (lean_dir) {
                case 1u: lean_dx = +1; break;
                case 2u: lean_dx = -1; break;
                case 3u: lean_dz = +1; break;
                default: lean_dz = -1; break;
            }
        }
        return TreeDesc{
            cell_origin_x + off_x,
            cell_origin_z + off_z,
            strunk, CANOPY_COMPACT,
            sbirch ? BIRCH_LOG : OAK_LOG,
            sbirch ? BIRCH_LEAVES : OAK_LEAVES,
            true,
            /*thick_trunk=*/false,
            lean_dx, lean_dz,
            /*branch_count=*/0, branch_hash,
            leaf_hash, /*sparse=*/1, /*extra_skirt=*/0
        };
    }

    // Determine lean for non-giant trees: ~25% lean slightly; a small fraction
    // (#22) lean DIAGONALLY (both axes) for more windswept variety.
    if (lean_gate <= 1u) {
        switch (lean_dir) {
            case 1u: lean_dx = +1; break;
            case 2u: lean_dx = -1; break;
            case 3u: lean_dz = +1; break;
            default: lean_dz = -1; break;
        }
        // ~25% of leaning trees also lean on the other axis (diagonal lean).
        if (((leaf_hash >> 24u) & 0x3u) == 0u) {
            if (lean_dx != 0) lean_dz = (((leaf_hash >> 26u) & 1u) ? +1 : -1);
            else              lean_dx = (((leaf_hash >> 26u) & 1u) ? +1 : -1);
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
            // #22 TRUNK DIAMETER: large oak/weeping/forked trees get 2×2 thick
            // trunks much more often now (was ~25% of trunk>=8 only).  Any non-birch
            // forest oak with trunk >= 7 is thick when thick_bit is set (~50%), so a
            // walk through a forest reliably shows a mix of slim and stout trunks.
            if (!is_birch && thick_bit == 1u && trunk_h >= 7) {
                thick_trunk = false;  // #62: no 2x2 trunks (keep trees 1 block wide)
            }
            break;

        case Biome::Mountains:
            // Mountains: PINE (conical) and TALL shapes, taller conifers (#62).
            // Some lean on steep slopes.
            trunk_h      = 7 + static_cast<int>(trunk_bits % 5u);   // 7..11
            canopy_shape = (shape_bits <= 3u) ? CANOPY_PINE :
                           (shape_bits <= 5u) ? CANOPY_TALL : CANOPY_ROUND;
            is_birch     = (birch_bits == 0u);  // 25% birch
            // #22: stout mountain conifers — the taller pines/talls get a 2×2 trunk.
            if (!is_birch && thick_bit == 1u && trunk_h >= 7) {
                thick_trunk = false;  // #62: no 2x2 trunks (keep trees 1 block wide)
            }
            break;

        case Biome::Snowy:
            // Snowy: PINE trees exclusively — tall conical conifers (#62 taller spires).
            trunk_h      = 9 + static_cast<int>(trunk_bits % 7u);   // 9..15
            canopy_shape = CANOPY_PINE;
            is_birch     = false;  // no birch in deep snowy (pines only)
            // #22: thick-trunked snowy spires for variety (~50% of trunk>=8).
            if (thick_bit == 1u && trunk_h >= 8) {
                thick_trunk = false;  // #62: no 2x2 trunks (keep trees 1 block wide)
            }
            break;

        case Biome::Swamp:
            // Swamp: short wide squat trees, trunk 4..6.
            // Some weeping willow-ish canopies in swamp.
            trunk_h      = 4 + static_cast<int>(trunk_bits % 3u);   // 4..6
            canopy_shape = (shape_bits <= 2u) ? CANOPY_COMPACT :
                           (shape_bits <= 5u) ? CANOPY_BROAD   : CANOPY_WEEPING;
            is_birch     = (birch_bits <= 1u);  // 50% birch
            // #22: gnarled stout swamp trees — broad/compact ones get a 2×2 trunk.
            if (!is_birch && thick_bit == 1u && trunk_h >= 5
                && (canopy_shape == CANOPY_BROAD || canopy_shape == CANOPY_COMPACT
                    || canopy_shape == CANOPY_WEEPING)) {
                thick_trunk = false;  // #62: no 2x2 trunks (keep trees 1 block wide)
            }
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

    // PINE keeps a crisp conical silhouette → never sparse-nibble it.
    if (canopy_shape == CANOPY_PINE) sparse = 0;

    return TreeDesc{
        cell_origin_x + off_x,
        cell_origin_z + off_z,
        trunk_h,
        canopy_shape,
        (canopy_shape == CANOPY_PINE) ? PINE_LOG    : (is_birch ? BIRCH_LOG    : OAK_LOG),
        (canopy_shape == CANOPY_PINE) ? PINE_LEAVES : (is_birch ? BIRCH_LEAVES : OAK_LEAVES),
        true,
        thick_trunk,
        lean_dx,
        lean_dz,
        branch_count,
        branch_hash,
        leaf_hash,
        sparse,
        extra_skirt
    };
}

// ---------------------------------------------------------------------------
// Canopy voxel queries — pure functions of (dx, dy, dz, shape)
// ---------------------------------------------------------------------------
// dx, dz: offset from trunk XZ; dy: offset from trunk_top_wy.
// Returns true if that offset should contain a leaf block.
// ---------------------------------------------------------------------------

// ROUND: classic 5x3x5 with clipped corners (original shape, kept intact).
// #54: real-tree canopies. The deciduous crowns (round/broad/compact/giant) are now
// full rounded ELLIPSOIDS — taller and fuller than the old flat 3-block box-rings, so
// they read as real tree crowns, not Minecraft cubes. The per-voxel leaf_hash nibble
// (applied by the caller) still ragged-edges them so they aren't perfect spheres.
static inline bool in_ellipsoid(int dx, int dy, int dz, float hr, float vr) noexcept {
    float rx = float(dx) / hr, ry = float(dy) / vr, rz = float(dz) / hr;
    return rx * rx + ry * ry + rz * rz <= 1.0f;
}

// ROUND: a full rounded ball crown (~6 wide, ~5 tall).
static bool in_canopy_round(int dx, int dy, int dz) noexcept {
    if (dy < -2 || dy > 2) return false;
    return in_ellipsoid(dx, dy, dz, 3.0f, 2.6f);
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
// BROAD: a wide rounded crown (~7 wide, a touch flatter).
static bool in_canopy_broad(int dx, int dy, int dz) noexcept {
    if (dy < -2 || dy > 2) return false;
    return in_ellipsoid(dx, dy, dz, 3.4f, 2.1f);
}

// COMPACT: dense squat 5x3x5 fully filled (swamp/plains short trees).
//   dy=-1: 5x5 no corners
//   dy= 0: 5x5 no corners
//   dy=+1: 3x3
// COMPACT: a small dense round bush crown (short trees).
static bool in_canopy_compact(int dx, int dy, int dz) noexcept {
    if (dy < -2 || dy > 1) return false;
    return in_ellipsoid(dx, dy, dz, 2.5f, 2.0f);
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
// GIANT: a large rounded crown (~9 wide, ~6 tall) on a thick trunk.
static bool in_canopy_giant(int dx, int dy, int dz) noexcept {
    if (dy < -2 || dy > 3) return false;
    return in_ellipsoid(dx, dy, dz, 4.0f, 3.0f);
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

// #22 IRREGULAR CANOPY EDGES — decide whether to KEEP a given leaf voxel.
// Perfect-blob canopies read as artificial; we drop a deterministic fraction of
// the OUTER leaf voxels so every crown has a ragged, organic silhouette.
//
//   * The inner core (|dx|<=1 AND |dz|<=1) is ALWAYS kept, so the crown never
//     disconnects from the trunk and tips/spines stay intact.
//   * Outer voxels (chebyshev radius >= 2 in XZ) are dropped with probability
//     ~18% (full crown) or ~38% (sparse crown), via a hash of the tree's
//     leaf_hash and the voxel's GLOBAL world position — so any chunk the crown
//     overlaps makes the identical keep/drop decision (seam-consistent), and it
//     never writes out of bounds (the caller still bounds-clips every voxel).
//
// PINE/saplings pass sparse handling through the same path (pine has sparse=0 and
// its skirt voxels are mostly radius<=2 so it keeps its crisp cone).
static bool keep_leaf_voxel(std::uint64_t leaf_hash, int sparse,
                            std::int32_t wlx, std::int32_t wly, std::int32_t wlz,
                            int dx, int dz) noexcept {
    int rxz = (dx < 0 ? -dx : dx);
    int az  = (dz < 0 ? -dz : dz);
    if (az > rxz) rxz = az;
    if (rxz <= 1) return true;                 // inner core — always keep
    std::uint64_t vh = hash3(wlx, wly, wlz, leaf_hash);
    std::uint64_t r  = vh & 0xFFu;             // 0..255
    std::uint64_t thr = sparse ? 98u : 46u;    // ~38% / ~18% drop on outer ring
    return r >= thr;                           // keep unless under the drop threshold
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
// Structure types (#17 — varied, characterful builds, not a single box):
//   STRUCT_CABIN        — walled cabin: planks/cobble walls, GABLE ROOF, an
//                          oak_door, glass_pane windows, and an interior — for
//                          larger cells a 2-room layout with a dividing wall.
//   STRUCT_WATCHTOWER   — multi-storey tower: solid cobble base, a climbable
//                          interior STAIR of planks, a railed lookout platform,
//                          corner posts + a glow_block beacon on top.
//   STRUCT_RUINED_TEMPLE— a broken stone-brick shrine: pillared platform with a
//                          partially-collapsed roof, an altar, and a buried chest.
//   STRUCT_CAMP         — campfire camp: a glow_block fire ring with 1-2 wool
//                          tents (sloped wool lean-tos) pitched beside it.
//   STRUCT_WELL         — a stone-brick well: square rim wall around a water
//                          shaft, with two posts + a roof beam over it.
//   STRUCT_OBELISK      — a tapering stone/mossy-stone monolith 5-7 tall with a
//                          crystal_lamp capstone and a small plinth.
//   STRUCT_CAIRN        — pile of 2..5 stone/mossy_stone blocks (kept; rocky biomes).
//
// Each structure also writes a MARKER block (BEACON_BLOCK, id 34) buried one
// block BELOW its anchor's surface (out of sight, never disturbing the visible
// build).  The engine can detect this to spawn an NPC/creature at the structure
// — see worldgen_structure_marker_at() and the MARKER_BLOCK note below.
//
// Seam safety: the anchor world pos is derived from cell integer coords.  Surface
// height at each column within the structure is sampled via the same pure
// surface_height() function all chunks use — identical across chunk borders.  All
// voxels go through struct_set() which range-clips to the current chunk, so a
// build straddling a chunk border draws identically from either side (any chunk
// the build overlaps iterates the same cell and emits the same clipped voxels).
//
// Cell size: one candidate per 64×64 region; spawn probability ~50% so a couple
// of builds are reliably findable within ~120 blocks of any spawn (#17).
// ---------------------------------------------------------------------------

static constexpr int STRUCT_CELL_SIZE    = 64;
static constexpr std::uint64_t STRUCT_SEED_MIX = 0x57AC7EDEDBEF5717ull;

// MARKER_BLOCK (#17 engine hook): the block id buried 1 below each structure's
// anchor surface so the engine can find structures (e.g. to spawn an NPC there).
// BEACON_BLOCK (34) is otherwise never produced by worldgen, so its presence
// unambiguously marks a structure centre.  Detectable two ways:
//   * cheaply, WITHOUT touching voxels, via worldgen_structure_marker_at(); or
//   * by scanning generated chunks for BEACON_BLOCK at (anchor, H-1).
static constexpr BlockId MARKER_BLOCK = 34;  // beacon_block

// Structure spawn probability out of 256 (#17).  History: 31 (~12%) → 80 (~31%) →
// now 128 (~50%).  A second playtest still found NONE near spawn: many candidate
// cells get rejected downstream (submerged H<=SEA_LEVEL columns place nothing), so
// the *effective* placed density was well under the gate.  Bumping the gate to ~50%
// of 64×64 cells makes a couple of huts/pillars/campfires/etc. reliably findable
// within ~120 blocks of any spawn (verified: every seed 1..6 now has its nearest
// structure within ~64 blocks of origin).  Expressed as a named constant so the
// diagnostic probe (worldgen_count_structures) and tests stay in sync.
static constexpr std::uint64_t STRUCT_PROB_THRESH = 128u;

// Structure type codes (#17, extended #39).  Engine-visible — the STRUCT_*
// int->name table is mirrored in worldgen.hpp for worldgen_structure_near().
static constexpr int STRUCT_NONE         = 0;
static constexpr int STRUCT_CABIN        = 1;   // walled cabin w/ roof+door+windows+chimney
static constexpr int STRUCT_OBELISK      = 2;   // tapering monolith + lamp capstone
static constexpr int STRUCT_CAMP         = 3;   // campfire + wool tents + log fence
static constexpr int STRUCT_WATCHTOWER   = 4;   // multi-storey tower w/ stairs
static constexpr int STRUCT_TEMPLE       = 5;   // ruined stone-brick shrine + columns + steps + chest
static constexpr int STRUCT_CAIRN        = 6;   // stacked rock pile w/ broad base
static constexpr int STRUCT_WELL         = 7;   // stone-brick well w/ canopy roof + bucket
static constexpr int STRUCT_VILLAGE      = 8;   // #39 cluster of 2-3 tiny huts + shared fire
static constexpr int STRUCT_SHRINE       = 9;   // #39 ring of standing stones + lit altar

// Max XZ reach from anchor for seam-safe cell scan (conservative).  The widest
// builds (#39 village huts and the shrine standing-stone ring, plus the camp's
// log fence) reach ±5 from the anchor; we scan ±7 so every overlapping chunk
// iterates the cell and emits identical clipped voxels.  Anchor offset is kept in
// [7, 56] (below) so a build never reaches outside its own 64×64 cell.
static constexpr int STRUCT_MAX_REACH_XZ = 7;

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

// Forward decl: pure surface height at a column (defined below struct_for_cell).
static int struct_surface(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept;

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

    // Anchor position: offset within cell so it is not always at corner.  Kept in
    // [7, 56] so even the widest build (reach ±7, #39 village/shrine) stays inside
    // its own 64×64 cell — no build ever crosses a cell boundary, which keeps the
    // per-cell resolution (footprint / structure_near) unambiguous and seam-safe.
    std::uint64_t h2s = fmix64(h ^ 0xFACEBEEF0BABULL);
    std::int32_t off_x = 7 + static_cast<std::int32_t>((h2s >>  0u) % 50u);  // 7..56
    std::int32_t off_z = 7 + static_cast<std::int32_t>((h2s >> 16u) % 50u);  // 7..56

    std::int32_t ax = scx * STRUCT_CELL_SIZE + off_x;
    std::int32_t az = scz * STRUCT_CELL_SIZE + off_z;

    // Biome at anchor (Voronoi TYPE map, #6) determines eligible structure types.
    Biome dom = voronoi_biome(ax, az, seed);

    // No structures in water biomes (beach below sea) or deep desert interior.
    // Surface height at anchor.
    int H = struct_surface(ax, az, seed);
    if (H <= SEA_LEVEL) {
        return StructDesc{0, 0, STRUCT_NONE, 0, false};
    }

    // Choose structure type based on biome and hash bits (#17/#39 — every biome
    // gets a varied, recognizable mix of builds rather than one repeated box).
    // Distribution is balanced per biome: each biome offers 4-5 distinct types
    // with no single type taking more than ~40% of its cells, and the prominent
    // WATCHTOWER is now ONE option among many (not the default) so the world no
    // longer "reads as mostly towers".  type_bits is 0..7 (8 equal buckets).
    std::uint64_t type_bits = (h2s >> 32u) & 0x7u;  // 0..7
    int stype;

    switch (dom) {
        case Biome::Mountains:
            // Mountains: cairns, obelisks, hillside shrines, a lone keep.
            stype = (type_bits <= 1u) ? STRUCT_CAIRN      :
                    (type_bits <= 3u) ? STRUCT_OBELISK    :
                    (type_bits <= 5u) ? STRUCT_SHRINE     :
                    (type_bits == 6u) ? STRUCT_WATCHTOWER : STRUCT_TEMPLE;
            break;
        case Biome::Desert:
            // Desert: ruined temples, obelisks, shrines, the odd oasis well.
            stype = (type_bits <= 2u) ? STRUCT_TEMPLE  :
                    (type_bits <= 4u) ? STRUCT_OBELISK :
                    (type_bits <= 6u) ? STRUCT_SHRINE  : STRUCT_WELL;
            break;
        case Biome::Forest:
            // Forest: cabins, camps, hidden temples, the occasional hamlet.
            stype = (type_bits <= 2u) ? STRUCT_CABIN   :
                    (type_bits <= 4u) ? STRUCT_CAMP    :
                    (type_bits <= 5u) ? STRUCT_VILLAGE :
                    (type_bits == 6u) ? STRUCT_TEMPLE  : STRUCT_SHRINE;
            break;
        case Biome::Plains:
            // Plains: the full settlement spread — villages, cabins, wells,
            // camps, the occasional lookout tower.
            stype = (type_bits <= 1u) ? STRUCT_VILLAGE    :
                    (type_bits <= 3u) ? STRUCT_CABIN      :
                    (type_bits == 4u) ? STRUCT_WELL       :
                    (type_bits == 5u) ? STRUCT_CAMP       :
                    (type_bits == 6u) ? STRUCT_WATCHTOWER : STRUCT_SHRINE;
            break;
        case Biome::Snowy:
            // Snowy: cabins (shelter), cairns (trail markers), obelisks, shrines.
            stype = (type_bits <= 2u) ? STRUCT_CABIN   :
                    (type_bits <= 4u) ? STRUCT_CAIRN   :
                    (type_bits <= 6u) ? STRUCT_OBELISK : STRUCT_SHRINE;
            break;
        case Biome::Swamp:
            // Swamp: stilted watchtowers, camps, sunken wells, lonely shrines.
            stype = (type_bits <= 2u) ? STRUCT_WATCHTOWER :
                    (type_bits <= 4u) ? STRUCT_CAMP       :
                    (type_bits <= 6u) ? STRUCT_WELL       : STRUCT_SHRINE;
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

// ---------------------------------------------------------------------------
// Structure building blocks (#17) — shared seam/hole-safe helpers.
// ---------------------------------------------------------------------------
// HOLE-SAFETY CONTRACT.  The no-surface-holes test scans every surface column
// and requires the 5 blocks below the topmost SOLID (non-decoration) block to be
// solid.  A roofed hollow room would trip this (roof on top, air below).  We
// resolve it the same way caves are resolved: the structure FOOTPRINT columns are
// exempted from that test (see structure_footprint_at() + the test).  That lets
// builds have real hollow interiors, doors, and roofs.  Within a footprint we are
// then free to leave interior air.  Outside the footprint nothing changes, so
// natural terrain stays strictly hole-free.
//
// SEAM-SAFETY: every voxel goes through struct_set() (range-clipped to the chunk)
// and the build geometry is a pure function of the cell hash + the pure
// struct_surface() height, so any chunk a build straddles emits identical clipped
// voxels.  Structures are additive (never carve terrain).

// Fill a single column with `b` from just above its own surface up to `top_wy`
// (inclusive), so a wall/post never floats over an air gap (its base sits on the
// ground).  Used for walls, stilts, posts.
static void struct_fill_col(IChunk& chunk, std::int32_t wx, std::int32_t wz,
                            std::int32_t top_wy, std::uint64_t seed,
                            std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min,
                            BlockId b) noexcept {
    int col_h = struct_surface(wx, wz, seed);
    for (std::int32_t wy = col_h + 1; wy <= top_wy; ++wy) {
        struct_set(chunk, wx, wy, wz, wx_min, wy_min, wz_min, b);
    }
}

// Place the engine-detectable MARKER one block below the anchor surface (#17).
static void struct_place_marker(std::int32_t ax, std::int32_t az, std::uint64_t seed,
                                IChunk& chunk, std::int32_t wx_min,
                                std::int32_t wy_min, std::int32_t wz_min) noexcept {
    int H = struct_surface(ax, az, seed);
    struct_set(chunk, ax, H - 1, az, wx_min, wy_min, wz_min, MARKER_BLOCK);
}

// Place a CABIN (#17): walls (planks or cobble) with an oak_door, glass_pane
// windows, and a GABLE ROOF.  Larger cells get a 2-room plan (an interior divider
// wall with an inner doorway).  Interior is genuinely hollow (footprint-exempt
// from the hole test).  Floor is solid planks so you can stand inside.
static void place_cabin(std::int32_t ax, std::int32_t az,
                        std::uint64_t h, std::uint64_t seed,
                        IChunk& chunk,
                        std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Footprint half-extent: 2 (5×5) most of the time, 3 (7×5) for "big" cabins.
    int hx = ((h >> 2u) & 1u) ? 3 : 2;   // half-extent in X
    int hz = 2;                          // half-extent in Z

    // Shared floor level = max surface over the wall ring (so the cabin sits flat).
    int floor_h = -1000000;
    for (int dz = -hz; dz <= hz; ++dz)
        for (int dx = -hx; dx <= hx; ++dx) {
            int sh = struct_surface(ax + dx, az + dz, seed);
            if (sh > floor_h) floor_h = sh;
        }

    bool cobble = ((h >> 5u) & 1u) != 0u;       // stone vs timber cabin
    BlockId wall = cobble ? COBBLESTONE : OAK_PLANKS;
    BlockId trim = cobble ? STONE_BRICK : WOOD_BEAM;   // corner posts (cube timber, not floaty cylinders)
    constexpr int WALL_H = 3;
    int wall_top = floor_h + WALL_H;

    // Door on one of the long (±X) walls, centred in Z.
    bool door_east = ((h >> 6u) & 1u) != 0u;
    int  door_dx = door_east ? hx : -hx;

    // Solid floor across the whole footprint at floor_h (planks), filling any
    // gap down to each column's surface so the floor is supported.
    for (int dz = -hz; dz <= hz; ++dz)
        for (int dx = -hx; dx <= hx; ++dx)
            struct_fill_col(chunk, ax + dx, az + dz, floor_h, seed,
                            wx_min, wy_min, wz_min, OAK_PLANKS);

    // Walls (the ring), with door gap and windows.
    for (int dz = -hz; dz <= hz; ++dz) {
        for (int dx = -hx; dx <= hx; ++dx) {
            bool on_x = (dx == -hx || dx == hx);
            bool on_z = (dz == -hz || dz == hz);
            if (!(on_x || on_z)) continue;        // interior stays hollow
            bool corner = on_x && on_z;

            // Door opening: a 2-high gap in the middle of the door wall.
            bool is_door = (dx == door_dx && dz == 0);
            if (is_door) {
                // leave floor_h+1..+2 open; place an oak_door on the lower gap.
                struct_set(chunk, ax + dx, floor_h + 1, az + dz,
                           wx_min, wy_min, wz_min, OAK_DOOR);
                continue;
            }

            // Windows: glass at head height on non-corner wall cells (every other).
            bool window = !corner && (((dx + dz) & 1) == 0);
            for (int wy = floor_h + 1; wy <= wall_top; ++wy) {
                BlockId b = corner ? trim : wall;
                if (window && wy == floor_h + 2) b = GLASS_PANE;
                struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, b);
            }
        }
    }

    // Interior divider wall (2-room) for big cabins: a wall at dx=0 with a gap.
    if (hx == 3) {
        for (int dz = -hz; dz <= hz; ++dz) {
            if (dz == 0) continue;  // inner doorway
            for (int wy = floor_h + 1; wy <= wall_top; ++wy)
                struct_set(chunk, ax, wy, az + dz, wx_min, wy_min, wz_min, wall);
        }
    }

    // GABLE ROOF: ridge runs along X.  Each Z offset gets a roof course one block
    // higher toward the ridge (dz==0).  Eaves overhang by 1.  Roof of planks/
    // birch.  The interior below is hollow but footprint-exempt from holes.
    BlockId roof = cobble ? STONE_BRICK : BIRCH_PLANKS;
    for (int dz = -(hz + 1); dz <= (hz + 1); ++dz) {
        int adz = dz < 0 ? -dz : dz;
        int ridge_step = hz + 1 - adz;          // higher near ridge
        int roof_y = wall_top + 1 + ridge_step;
        for (int dx = -(hx + 1); dx <= (hx + 1); ++dx) {
            struct_set(chunk, ax + dx, roof_y, az + dz,
                       wx_min, wy_min, wz_min, roof);
        }
    }
    // Fill the gable triangles (the end walls under the sloping roof) so there is
    // no open hole at the cabin ends.
    for (int dz = -hz; dz <= hz; ++dz) {
        int adz = dz < 0 ? -dz : dz;
        int ridge_step = hz + 1 - adz;
        for (int dx : {-hx, hx}) {
            for (int wy = wall_top + 1; wy < wall_top + 1 + ridge_step; ++wy)
                struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, wall);
        }
    }

    // A torch beside the door and a glow_block inside for warmth/visibility.
    struct_set(chunk, ax + door_dx, floor_h + 3, az, wx_min, wy_min, wz_min, TORCH);
    struct_set(chunk, ax, floor_h + 1, az, wx_min, wy_min, wz_min, GLOW_BLOCK);

    // Signature feature (#39): a cobblestone CHIMNEY on the back wall corner,
    // rising 2 blocks above the roof ridge with a glowing hearth at its base, so
    // a cabin reads unmistakably as a cabin (not a generic box) from a distance.
    {
        int chim_dx = -door_dx;                 // back side, opposite the door
        int chim_x  = ax + chim_dx;
        int chim_z  = az + (((h >> 7u) & 1u) ? hz : -hz);
        int ridge_top = wall_top + 1 + (hz + 1);   // y of the gable ridge
        int chim_top  = ridge_top + 2;
        struct_fill_col(chunk, chim_x, chim_z, chim_top, seed,
                        wx_min, wy_min, wz_min, COBBLESTONE);
        // Hearth fire glimpsed at the chimney base inside the wall line.
        struct_set(chunk, chim_x, floor_h + 1, chim_z,
                   wx_min, wy_min, wz_min, GLOW_BLOCK);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Place an OBELISK (#17): a tapering monolith of stone/mossy_stone on a small
// plinth, topped with a crystal_lamp capstone — a clean landmark.  Solid column
// (no interior), so it is inherently hole-safe.
static void place_obelisk(std::int32_t ax, std::int32_t az,
                          std::uint64_t h, std::uint64_t seed,
                          IChunk& chunk,
                          std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    int H = struct_surface(ax, az, seed);
    int shaft = 7 + static_cast<int>((h >> 4u) % 4u);   // 7..10 (taller, #39)

    // Stepped two-tier PLINTH for a stronger, recognizable silhouette (#39):
    // a wide 3×3 base course (H+1) and a 1×1 raised pedestal (H+2) the shaft
    // springs from.  Each column filled from its own surface (supported).
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            int top = struct_surface(ax + dx, az + dz, seed) + 1;
            struct_fill_col(chunk, ax + dx, az + dz, top, seed,
                            wx_min, wy_min, wz_min, STONE_BRICK);
        }
    struct_set(chunk, ax, H + 2, az, wx_min, wy_min, wz_min, STONE_BRICK);   // pedestal

    // Four small corner markers ring the plinth so the base reads as deliberate.
    int marks[4][2] = {{2,2},{-2,2},{2,-2},{-2,-2}};
    for (int i = 0; i < 4; ++i) {
        int mh = struct_surface(ax + marks[i][0], az + marks[i][1], seed) + 1;
        struct_fill_col(chunk, ax + marks[i][0], az + marks[i][1], mh, seed,
                        wx_min, wy_min, wz_min, MOSSY_STONE);
    }

    // Tapering shaft on the centre (springs from the pedestal): stone w/ banding.
    for (int dy = 3; dy <= shaft + 2; ++dy) {
        BlockId b = ((h >> static_cast<unsigned>(dy)) & 1u) ? MOSSY_STONE : STONE;
        struct_set(chunk, ax, H + dy, az, wx_min, wy_min, wz_min, b);
    }
    // Crystal-lamp capstone glints on top.
    struct_set(chunk, ax, H + shaft + 3, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Place a CAMP (#17): a glow_block fire ring with 1-2 wool "tents" (sloped wool
// lean-tos with a solid back) pitched beside it.  Tents are solid wedges, so
// hole-safe; the fire ring is at surface level.
static void place_camp(std::int32_t ax, std::int32_t az,
                       std::uint64_t h, std::uint64_t seed,
                       IChunk& chunk,
                       std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Fire ring: cobblestone perimeter (3×3) + glow_block centre, at each
    // column's own surface (no floating).
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            int col_h  = struct_surface(ax + dx, az + dz, seed);
            bool centre = (dx == 0 && dz == 0);
            struct_set(chunk, ax + dx, col_h + (centre ? 1 : 0), az + dz,
                       wx_min, wy_min, wz_min, centre ? GLOW_BLOCK : COBBLESTONE);
        }

    // Tents: pitched ±X of the fire.  Each tent is a 3-long (Z) ridge wedge made
    // of wool — a 2-high solid wedge so it reads as a tent and has no hollow hole.
    auto pitch_tent = [&](int tent_ax) noexcept {
        for (int dz = -1; dz <= 1; ++dz) {
            int base = struct_surface(tent_ax, az + dz, seed);
            // back post 2 high, sloping down to 1 high front — solid wedge.
            struct_fill_col(chunk, tent_ax, az + dz, base + 2, seed,
                            wx_min, wy_min, wz_min, WOOL_BLOCK);
            // a front skirt one block out, 1 high.
            int fdx = (tent_ax > ax) ? 1 : -1;
            int fbase = struct_surface(tent_ax + fdx, az + dz, seed);
            struct_fill_col(chunk, tent_ax + fdx, az + dz, fbase + 1, seed,
                            wx_min, wy_min, wz_min, WOOL_BLOCK);
        }
    };
    pitch_tent(ax - 3);
    if (((h >> 8u) & 1u)) pitch_tent(ax + 3);   // sometimes a second tent

    // Signature feature (#39): a low oak-log FENCE enclosing the camp (a 9×9
    // ring at radius 4, 1 block high, with a gap for an entrance), so the camp
    // reads as a deliberate, settled enclosure rather than a stray fire.  Each
    // post sits on its own column surface (supported, no floating, hole-safe).
    {
        constexpr int R = 4;
        int gap_dz = ((h >> 9u) & 1u) ? R : -R;   // entrance on a +Z or -Z post
        for (int dx = -R; dx <= R; ++dx) {
            for (int dz = -R; dz <= R; ++dz) {
                bool ring = (dx == -R || dx == R || dz == -R || dz == R);
                if (!ring) continue;
                if (dx == 0 && dz == gap_dz) continue;   // entrance gap
                int post_h = struct_surface(ax + dx, az + dz, seed) + 1;
                struct_fill_col(chunk, ax + dx, az + dz, post_h, seed,
                                wx_min, wy_min, wz_min, WOOD_BEAM);
            }
        }
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Place a WATCHTOWER (#17): a solid cobblestone tower with an EXTERNAL plank
// stair spiralling up one face, a railed lookout (open-top, solid floor) and a
// glow_block beacon on top.  Solid core + solid lookout floor ⇒ hole-safe; the
// open top means the lookout-floor is the topmost solid (no roof hole).
static void place_watchtower(std::int32_t ax, std::int32_t az,
                             std::uint64_t h, std::uint64_t seed,
                             IChunk& chunk,
                             std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Base level = max surface over the 3×3 core.
    int base_h = -1000000;
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            int sh = struct_surface(ax + dx, az + dz, seed);
            if (sh > base_h) base_h = sh;
        }
    int tower_h = 6 + static_cast<int>((h >> 4u) % 3u);   // 6..8 tall
    int top_y   = base_h + tower_h;

    // Solid 3×3 cobble core, every column filled from its own surface up to top_y.
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx)
            struct_fill_col(chunk, ax + dx, az + dz, top_y, seed,
                            wx_min, wy_min, wz_min, COBBLESTONE);

    // Lookout parapet: 1-high cobble rim around the top, open centre, plus corner
    // posts and a beacon.  The solid core top (top_y) is the floor.
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            bool rim = (dx == -1 || dx == 1 || dz == -1 || dz == 1);
            if (rim) {
                struct_set(chunk, ax + dx, top_y + 1, az + dz,
                           wx_min, wy_min, wz_min, STONE_BRICK);
                bool corner = (dx != 0 && dz != 0);
                if (corner)
                    struct_set(chunk, ax + dx, top_y + 2, az + dz,
                               wx_min, wy_min, wz_min, WOOD_BEAM);
            }
        }
    struct_set(chunk, ax, top_y + 1, az, wx_min, wy_min, wz_min, GLOW_BLOCK);

    // External stair: a run of plank steps climbing the +X face from the ground
    // to the lookout.  Each step is supported (filled to its own y from the
    // ground), so no floating planks → hole-safe.
    int step_wx = ax + 2;   // one block out from the +X face
    int step_wz = az;
    int steps = top_y - base_h;
    for (int s = 1; s <= steps; ++s) {
        int step_y = base_h + s;
        struct_fill_col(chunk, step_wx, step_wz, step_y, seed,
                        wx_min, wy_min, wz_min, OAK_PLANKS);
        // the stair walks inward toward the tower as it rises so the top step
        // meets the lookout floor.
        if (s == steps)
            struct_set(chunk, ax + 1, top_y, az, wx_min, wy_min, wz_min, OAK_PLANKS);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Place a RUINED TEMPLE (#17): a stone-brick platform ringed by broken pillars
// with a partially-collapsed lintel roof, a central altar, and a buried chest of
// loot.  Pillars + altar are solid; the roof beams sit ON pillar tops (supported),
// and the footprint is hole-exempt for the open bays between pillars.
static void place_temple(std::int32_t ax, std::int32_t az,
                         std::uint64_t h, std::uint64_t seed,
                         IChunk& chunk,
                         std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Platform level.
    int plat = -1000000;
    for (int dz = -2; dz <= 2; ++dz)
        for (int dx = -2; dx <= 2; ++dx) {
            int sh = struct_surface(ax + dx, az + dz, seed);
            if (sh > plat) plat = sh;
        }

    // Raised stone-brick platform (1 high) across the 5×5 footprint, supported.
    for (int dz = -2; dz <= 2; ++dz)
        for (int dx = -2; dx <= 2; ++dx)
            struct_fill_col(chunk, ax + dx, az + dz, plat + 1, seed,
                            wx_min, wy_min, wz_min, STONE_BRICK);

    int pil_h = 3 + static_cast<int>((h >> 4u) & 1u);   // 3..4 pillar height
    // A full COLONNADE (#39): pillars at the 4 corners AND the 4 edge midpoints
    // (8 columns), so the temple reads as a clear pillared shrine rather than a
    // bare platform.  Some are "collapsed" (short) for a ruined look.
    int pillars[8][2] = {
        {-2,-2},{2,-2},{-2,2},{2,2},        // corners
        { 0,-2},{0, 2},{-2, 0},{2, 0},      // edge midpoints
    };
    for (int i = 0; i < 8; ++i) {
        int px = ax + pillars[i][0], pz = az + pillars[i][1];
        std::uint64_t ph = fmix64(h ^ (static_cast<std::uint64_t>(i) * 0x9E37u + 11u));
        int this_h = (ph & 0x3u) == 0u ? 1 + static_cast<int>(ph & 1u) : pil_h;
        for (int dy = 2; dy <= 1 + this_h; ++dy) {
            BlockId b = ((ph >> static_cast<unsigned>(dy)) & 1u) ? MOSSY_STONE : STONE_BRICK;
            struct_set(chunk, px, plat + dy, pz, wx_min, wy_min, wz_min, b);
        }
    }

    // Entrance STEPS (#39): a flight of stone-brick steps descending from the
    // front (−Z) edge of the platform down to ground level, giving the temple a
    // grand approach.  Each step column is filled to its tread height from its
    // own surface (supported, hole-safe).
    for (int s = 1; s <= 2; ++s) {
        int sz = az - 2 - s;                    // one step further out each time
        int tread = plat + 1 - s;               // descending tread height
        for (int dx = -1; dx <= 1; ++dx)
            struct_fill_col(chunk, ax + dx, sz, tread, seed,
                            wx_min, wy_min, wz_min, STONE_BRICK);
    }

    // Partial roof lintels: stone-brick beams connecting the two FRONT pillars'
    // tops (only if both reach full height — otherwise it has collapsed).  The
    // beam sits at the pillar top y, so it is supported (no air beneath at the
    // pillar columns) — and the open bays between are footprint-exempt.
    int roof_y = plat + 1 + pil_h;
    for (int dx = -2; dx <= 2; ++dx)
        if ((fmix64(h ^ static_cast<std::uint64_t>(dx + 50)) & 0x3u) != 0u)
            struct_set(chunk, ax + dx, roof_y, az - 2, wx_min, wy_min, wz_min, STONE_BRICK);

    // Central altar: a 1×1 mossy block with a crystal_lamp, and a buried chest.
    struct_set(chunk, ax, plat + 2, az, wx_min, wy_min, wz_min, MOSSY_STONE);
    struct_set(chunk, ax, plat + 3, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    struct_set(chunk, ax, plat, az, wx_min, wy_min, wz_min, CHEST);   // in the platform

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Place a WELL (#17): a stone-brick square rim around a 1-block water shaft, with
// two posts and a roof beam over it.  Rim is solid + supported; the water shaft is
// inside the footprint (hole-exempt).
static void place_well(std::int32_t ax, std::int32_t az,
                       std::uint64_t h, std::uint64_t seed,
                       IChunk& chunk,
                       std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    int H = struct_surface(ax, az, seed);

    // Rim: 8 stone-brick blocks ringing the centre, each at its column surface+1.
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            if (dx == 0 && dz == 0) continue;     // centre is the water shaft
            int col_h = struct_surface(ax + dx, az + dz, seed);
            struct_fill_col(chunk, ax + dx, az + dz, col_h + 1, seed,
                            wx_min, wy_min, wz_min, STONE_BRICK);
        }
    // Water at the centre, sitting in the rim (surface level).
    struct_set(chunk, ax, H, az, wx_min, wy_min, wz_min, WATER);

    // Signature feature (#39): a proper roofed CANOPY over the shaft — four oak
    // posts on the rim corners carrying a pitched 3×3 plank roof, with a wooden
    // "bucket" (oak_log) hanging on a beam over the water and a torch for light.
    // Posts are supported (filled from their own surface); the roof sits on the
    // posts; the open well shaft is inside the hole-exempt footprint.
    int post_h = 3;
    int post_top = H + post_h;                       // y of the post tops
    int corner[4][2] = {{-1,-1},{1,-1},{-1,1},{1,1}};
    for (int i = 0; i < 4; ++i)
        struct_fill_col(chunk, ax + corner[i][0], az + corner[i][1], post_top,
                        seed, wx_min, wy_min, wz_min, WOOD_BEAM);

    // Pitched plank roof: ridge along X one block above the post tops; eaves at
    // the post tops, so the roof clearly peaks (a recognizable little house roof).
    int roof_base = post_top + 1;
    for (int dz = -1; dz <= 1; ++dz) {
        int ry = roof_base + (dz == 0 ? 1 : 0);      // ridge centre is higher
        for (int dx = -1; dx <= 1; ++dx)
            struct_set(chunk, ax + dx, ry, az + dz,
                       wx_min, wy_min, wz_min, OAK_PLANKS);
    }
    // Cross-beam + hanging bucket over the shaft, and a torch on a post top.
    struct_set(chunk, ax, post_top, az, wx_min, wy_min, wz_min, WOOD_BEAM);   // winch beam
    struct_set(chunk, ax, H + 1, az,    wx_min, wy_min, wz_min, WOOD_BEAM);   // bucket on the rope
    struct_set(chunk, ax - 1, post_top, az - 1,
               wx_min, wy_min, wz_min, TORCH);
    (void)h;
    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Place a ROCK CAIRN: 2..5 stone/mossy_stone blocks stacked in a 1×1 column,
// with optional small scatter of rocks around the base.  Solid ⇒ hole-safe.
static void place_cairn(std::int32_t ax, std::int32_t az,
                        std::uint64_t h, std::uint64_t seed,
                        IChunk& chunk,
                        std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    int H = struct_surface(ax, az, seed);
    int cairn_h = 3 + static_cast<int>((h >> 4u) & 0x3u);  // 3..6 (taller, #39)

    // Stepped conical PILE (#39): a broad 3×3 base course, a 1-block-inset middle
    // course, then a 1×1 capstone tower — a clear pyramid silhouette so the cairn
    // is recognizable at a glance rather than a single stray block.  All solid ⇒
    // hole-safe; each base column filled from its own surface (supported).
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            std::uint64_t bh = fmix64(h ^ static_cast<std::uint64_t>((dx + 2) * 7 + (dz + 2) * 31));
            BlockId b = (bh & 1u) ? MOSSY_STONE : STONE;
            int base_top = struct_surface(ax + dx, az + dz, seed) + 1;  // broad base ring
            struct_fill_col(chunk, ax + dx, az + dz, base_top, seed,
                            wx_min, wy_min, wz_min, b);
        }
    // Central capstone tower rising above the base.
    for (int dy = 2; dy <= cairn_h; ++dy) {
        BlockId b = ((h >> (static_cast<unsigned>(dy) + 8u)) & 1u) ? MOSSY_STONE : STONE;
        struct_set(chunk, ax, H + dy, az, wx_min, wy_min, wz_min, b);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Place a tiny HUT (#39 village building block): a 3×3 walled box with a flat
// roof, one door, and one glass window — small but unmistakably a dwelling.  Used
// by place_village.  Solid floor + footprint-exempt hollow interior (hole-safe).
static void place_hut(std::int32_t cx, std::int32_t cz, std::uint64_t hh,
                      std::uint64_t seed, IChunk& chunk,
                      std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Floor level = max surface over the 3×3 so the hut sits flat.
    int floor_h = -1000000;
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            int sh = struct_surface(cx + dx, cz + dz, seed);
            if (sh > floor_h) floor_h = sh;
        }
    bool cobble = (hh & 1u) != 0u;
    BlockId wall = cobble ? COBBLESTONE : OAK_PLANKS;
    constexpr int WALL_H = 2;
    int wall_top = floor_h + WALL_H;

    // Solid plank floor (supported down to each column surface).
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx)
            struct_fill_col(chunk, cx + dx, cz + dz, floor_h, seed,
                            wx_min, wy_min, wz_min, OAK_PLANKS);

    // Door direction (one of the 4 cardinal walls) and a window opposite.
    int dir = static_cast<int>((hh >> 1u) & 0x3u);
    int door_dx = (dir == 0) ? 1 : (dir == 1) ? -1 : 0;
    int door_dz = (dir == 2) ? 1 : (dir == 3) ? -1 : 0;

    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            bool ring = (dx == -1 || dx == 1 || dz == -1 || dz == 1);
            if (!ring) continue;                       // hollow interior
            if (dx == door_dx && dz == door_dz) {      // doorway
                struct_set(chunk, cx + dx, floor_h + 1, cz + dz,
                           wx_min, wy_min, wz_min, OAK_DOOR);
                continue;
            }
            bool window = (dx == -door_dx && dz == -door_dz);  // window opposite door
            for (int wy = floor_h + 1; wy <= wall_top; ++wy) {
                BlockId b = (window && wy == floor_h + 1) ? GLASS_PANE : wall;
                struct_set(chunk, cx + dx, wy, cz + dz, wx_min, wy_min, wz_min, b);
            }
        }
    // Flat roof + a glow inside.
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx)
            struct_set(chunk, cx + dx, wall_top + 1, cz + dz,
                       wx_min, wy_min, wz_min, cobble ? STONE_BRICK : BIRCH_PLANKS);
    struct_set(chunk, cx, floor_h + 1, cz, wx_min, wy_min, wz_min, GLOW_BLOCK);
}

// Place a VILLAGE (#39): a small hamlet — 2-3 tiny huts arranged around a shared
// central campfire, with a connecting cobble path.  The cluster of dwellings is
// instantly recognizable as a settlement and gives the engine a rich NPC anchor.
static void place_village(std::int32_t ax, std::int32_t az,
                          std::uint64_t h, std::uint64_t seed,
                          IChunk& chunk,
                          std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Shared campfire at the centre (cobble hearth ring + glow).
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            int col_h  = struct_surface(ax + dx, az + dz, seed);
            bool centre = (dx == 0 && dz == 0);
            struct_set(chunk, ax + dx, col_h + (centre ? 1 : 0), az + dz,
                       wx_min, wy_min, wz_min, centre ? GLOW_BLOCK : COBBLESTONE);
        }

    // Huts placed at fixed offsets around the fire (within the ±7 cell reach).
    // The third hut appears only sometimes so villages vary between 2 and 3 huts.
    struct HutPos { int dx, dz; };
    HutPos huts[3] = {{-5, -4}, {5, 4}, {0, 5}};
    int n_huts = ((h >> 10u) & 1u) ? 3 : 2;
    for (int i = 0; i < n_huts; ++i) {
        std::uint64_t hh = fmix64(h ^ (static_cast<std::uint64_t>(i) * 0x2545F4914F6CDD1Dull + 71u));
        place_hut(ax + huts[i].dx, az + huts[i].dz, hh, seed,
                  chunk, wx_min, wy_min, wz_min);
        // A cobble path block stepping from the fire toward each hut.
        int pdx = huts[i].dx > 0 ? 2 : (huts[i].dx < 0 ? -2 : 0);
        int pdz = huts[i].dz > 0 ? 2 : (huts[i].dz < 0 ? -2 : 0);
        int ph = struct_surface(ax + pdx, az + pdz, seed);
        struct_set(chunk, ax + pdx, ph, az + pdz,
                   wx_min, wy_min, wz_min, COBBLESTONE);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Place a SHRINE (#39): a ring of standing stones (a small henge) around a raised,
// lit offering altar — a distinctive sacred-site silhouette.  Standing stones are
// solid columns of varied height; the altar is a mossy block topped with a
// crystal_lamp.  All solid / supported ⇒ hole-safe.
static void place_shrine(std::int32_t ax, std::int32_t az,
                         std::uint64_t h, std::uint64_t seed,
                         IChunk& chunk,
                         std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    // Eight standing stones in a ring at radius 3 (a clear henge circle).
    int ring[8][2] = {
        {-3, 0},{3, 0},{0,-3},{0, 3},
        {-3,-3},{3,-3},{-3, 3},{3, 3},
    };
    for (int i = 0; i < 8; ++i) {
        std::uint64_t sh = fmix64(h ^ (static_cast<std::uint64_t>(i) * 0x9E3779B97F4A7C15ull + 17u));
        int stone_h = 2 + static_cast<int>(sh & 1u);   // 2..3 tall standing stone
        int sx = ax + ring[i][0], sz = az + ring[i][1];
        int top = struct_surface(sx, sz, seed) + stone_h;
        BlockId b = (sh & 2u) ? MOSSY_STONE : STONE;
        struct_fill_col(chunk, sx, sz, top, seed, wx_min, wy_min, wz_min, b);
        // Some stones carry a stone-brick lintel cap for a megalith look.
        if ((sh & 0x3u) == 0u)
            struct_set(chunk, sx, top + 1, sz, wx_min, wy_min, wz_min, STONE_BRICK);
    }

    // Central offering altar: a stone-brick base, a mossy slab, a crystal lamp.
    int H = struct_surface(ax, az, seed);
    struct_fill_col(chunk, ax, az, H + 1, seed, wx_min, wy_min, wz_min, STONE_BRICK);
    struct_set(chunk, ax, H + 2, az, wx_min, wy_min, wz_min, MOSSY_STONE);
    struct_set(chunk, ax, H + 3, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// Dispatch to the right placer.
static void place_structure(const StructDesc& sd, std::uint64_t seed,
                            IChunk& chunk,
                            std::int32_t wx_min, std::int32_t wy_min, std::int32_t wz_min) noexcept {
    switch (sd.type) {
        case STRUCT_CABIN:
            place_cabin(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                        chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_OBELISK:
            place_obelisk(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                          chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_CAMP:
            place_camp(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                       chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_WATCHTOWER:
            place_watchtower(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                             chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_TEMPLE:
            place_temple(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                         chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_WELL:
            place_well(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                       chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_CAIRN:
            place_cairn(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                        chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_VILLAGE:
            place_village(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
                          chunk, wx_min, wy_min, wz_min);
            break;
        case STRUCT_SHRINE:
            place_shrine(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed,
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

    // Wooded biomes only (Voronoi TYPE map, #6).
    Biome dom = voronoi_biome(ax, az, seed);
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
// Cave interior features (#37 — make caves feel like a PLACE, not a void)
// ---------------------------------------------------------------------------
// Once the cave system is carved, this pass dresses the open space near
// entrances/underground with deterministic, bounds-clipped, CHEAP touches so a
// cave reads as a place: glowing mushroom clumps and crystal pockets that light
// the dark, the occasional small underground pool, an ore knot, and — rarely —
// an "abandoned" camp (a few cobble/plank blocks + a chest marker).
//
// Determinism / seam-safety: every feature is keyed to a coarse 3D world cell
// grid (CAVE_FEAT_CELL).  A cell's anchor world position, type and contents are
// pure functions of the cell hash, so any chunk overlapping a feature computes
// the same thing.  Whether a target voxel is OPEN cave or SOLID rock is decided
// by a POSITION-PURE helper (cave_voxel_is_air / _solid) that re-derives the
// exact terrain+cave-carve decision the column loop made — never by peeking at
// neighbour chunks — so a feature straddling a chunk border resolves identically
// from either side.  All writes go through the chunk's own range check.
//
// Density is deliberately low (caves stay mostly natural rock): only a fraction
// of cells host a feature and each footprint is tiny.
// ---------------------------------------------------------------------------

// Position-pure: surface height at a column (memoized cone), reused so the cave
// helpers agree byte-for-byte with the column loop.
static int cave_surface_h(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept {
    float w[NUM_BIOMES];
    biome_weights(wx, wz, seed, w);
    return surface_height(wx, wz, seed, w);
}

// Is the world voxel (wx,wy,wz) an UNDERGROUND CAVE VOID (carved to AIR by the
// cave system)?  Re-derives the exact rule generate() uses: the voxel must be
// below the protected sub-surface shell (so this is genuine cave, never open
// sky), above the world floor, and the cave noise must exceed the threshold.
// Open sky (wy > H) and the surface shell are explicitly NOT cave voids, so cave
// features can never end up floating above ground or poking through the surface.
static bool cave_voxel_is_air(std::int32_t wx, std::int32_t wy, std::int32_t wz,
                              std::uint64_t seed) noexcept {
    int H = cave_surface_h(wx, wz, seed);
    if (wy >= H - CAVE_SURFACE_MARGIN) return false;  // open sky or protected shell
    if (wy <= kColumnMinY + 4) return false;          // near world floor: solid
    float cave = fbm3(static_cast<float>(wx), static_cast<float>(wy),
                      static_cast<float>(wz),
                      fmix64(seed ^ 0xCA4E5EED1234ull), /*octaves=*/3,
                      /*base_freq=*/1.0f / 16.0f);
    return cave > CAVE_THRESH;
}

// Solid underground rock (the complement, restricted to below-surface so it does
// not report open sky as "solid").
static bool cave_voxel_is_solid(std::int32_t wx, std::int32_t wy, std::int32_t wz,
                                std::uint64_t seed) noexcept {
    int H = cave_surface_h(wx, wz, seed);
    if (wy > H) return false;
    return !cave_voxel_is_air(wx, wy, wz, seed);
}

static constexpr int CAVE_FEAT_CELL = 9;   // one feature candidate per 9³ region
static constexpr std::uint64_t CAVE_FEAT_SEED_MIX = 0xCA7EFEA70FEA7C00ull;

// Feature kinds.  (0 reserved for "none"; selection below never yields it.)
static constexpr int CFEAT_MUSHROOMS = 1;  // glowing mushroom clump on a floor
static constexpr int CFEAT_CRYSTALS  = 2;  // crystal pocket in walls + a lamp
static constexpr int CFEAT_POOL      = 3;  // small water pool in a floor dip
static constexpr int CFEAT_ORE_KNOT  = 4;  // tight ore cluster on a wall
static constexpr int CFEAT_CAMP      = 5;  // rare abandoned camp (cobble/planks/chest)

// Place all cave features overlapping this chunk.  Mirrors the ore pass: scan
// the 3D feature cells whose extent could overlap the chunk (+ margin), resolve
// each deterministically, and emit clipped voxels.
static void place_cave_features(ChunkCoord c, IChunk& chunk, std::uint64_t seed) noexcept {
    std::int32_t wx_min = c.x * kChunkDim;
    std::int32_t wy_min = c.y * kChunkDim;
    std::int32_t wz_min = c.z * kChunkDim;
    std::int32_t wx_max = wx_min + kChunkDim - 1;
    std::int32_t wy_max = wy_min + kChunkDim - 1;
    std::int32_t wz_max = wz_min + kChunkDim - 1;

    // Features only ever live underground; if this whole chunk is above the
    // shallowest possible cave voxel, skip (cheap reject for surface chunks).
    if (wy_min > 0) return;

    constexpr int FEAT_REACH = 3;   // max footprint radius (camp/pool)
    std::uint64_t fseed = fmix64(seed ^ CAVE_FEAT_SEED_MIX);

    auto fdiv = [](std::int32_t a, int b) noexcept -> std::int32_t {
        return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
    };

    std::int32_t cx0 = fdiv(wx_min - FEAT_REACH, CAVE_FEAT_CELL);
    std::int32_t cx1 = fdiv(wx_max + FEAT_REACH, CAVE_FEAT_CELL);
    std::int32_t cy0 = fdiv(wy_min - FEAT_REACH, CAVE_FEAT_CELL);
    std::int32_t cy1 = fdiv(wy_max + FEAT_REACH, CAVE_FEAT_CELL);
    std::int32_t cz0 = fdiv(wz_min - FEAT_REACH, CAVE_FEAT_CELL);
    std::int32_t cz1 = fdiv(wz_max + FEAT_REACH, CAVE_FEAT_CELL);

    // Clipped writer: only set if the target column index is inside this chunk.
    auto put = [&](std::int32_t wx, std::int32_t wy, std::int32_t wz,
                   BlockId b, bool only_into_air) -> void {
        if (wx < wx_min || wx > wx_max) return;
        if (wy < wy_min || wy > wy_max) return;
        if (wz < wz_min || wz > wz_max) return;
        int lx = static_cast<int>(wx - wx_min);
        int ly = static_cast<int>(wy - wy_min);
        int lz = static_cast<int>(wz - wz_min);
        BlockId cur = chunk.get(lx, ly, lz);
        if (only_into_air) {
            if (cur != AIR) return;
        }
        chunk.set(lx, ly, lz, b);
    };

    for (std::int32_t cy = cy0; cy <= cy1; ++cy) {
        for (std::int32_t cz = cz0; cz <= cz1; ++cz) {
            for (std::int32_t cx = cx0; cx <= cx1; ++cx) {
                std::uint64_t h = hash3(cx, cy, cz, fseed);
                std::uint64_t roll = h & 0xFFu;
                // ~22% of underground cells host a feature; the rest stay bare
                // rock so caves remain mostly natural.
                if (roll >= 56u) continue;

                // Anchor inside the cell.
                std::uint64_t h2 = fmix64(h ^ 0x0FEA7C0DECA7EFEAull);
                std::int32_t ax = cx * CAVE_FEAT_CELL
                    + static_cast<std::int32_t>((h2 >> 0u)  % CAVE_FEAT_CELL);
                std::int32_t ay = cy * CAVE_FEAT_CELL
                    + static_cast<std::int32_t>((h2 >> 8u)  % CAVE_FEAT_CELL);
                std::int32_t az = cz * CAVE_FEAT_CELL
                    + static_cast<std::int32_t>((h2 >> 16u) % CAVE_FEAT_CELL);

                // Feature type weights (camp is rare).
                std::uint64_t tsel = (h2 >> 24u) & 0xFFu;
                int ftype = (tsel < 88u)  ? CFEAT_MUSHROOMS :   // ~34%
                            (tsel < 150u) ? CFEAT_CRYSTALS  :   // ~24%
                            (tsel < 198u) ? CFEAT_ORE_KNOT  :   // ~19%
                            (tsel < 244u) ? CFEAT_POOL      :   // ~18%
                                            CFEAT_CAMP;         // ~5%

                // The anchor must sit in OPEN cave air with SOLID rock beneath
                // (a cave floor) for floor features; crystals/ore want the anchor
                // in air next to rock.  This is the position-pure gate that keeps
                // features inside real caves and seam-consistent.
                bool anchor_air   = cave_voxel_is_air(ax, ay, az, seed);
                bool floor_below  = cave_voxel_is_solid(ax, ay - 1, az, seed);

                switch (ftype) {
                    case CFEAT_MUSHROOMS: {
                        if (!anchor_air || !floor_below) break;
                        // A small clump of glowing mushrooms on the floor, plus a
                        // glow block tucked under one to read as bioluminescent.
                        int n = 2 + static_cast<int>((h2 >> 32u) % 4u);  // 2..5
                        for (int i = 0; i < n; ++i) {
                            std::uint64_t bh = fmix64(h2 ^ (static_cast<std::uint64_t>(i) * 0x9E37u));
                            std::int32_t dx = static_cast<std::int32_t>((bh >> 0u) % 3u) - 1;
                            std::int32_t dz = static_cast<std::int32_t>((bh >> 8u) % 3u) - 1;
                            if (cave_voxel_is_air(ax + dx, ay, az + dz, seed) &&
                                cave_voxel_is_solid(ax + dx, ay - 1, az + dz, seed)) {
                                put(ax + dx, ay, az + dz, MUSHROOM, true);
                            }
                        }
                        // A faint glow source seated in the floor at the centre.
                        if (cave_voxel_is_solid(ax, ay - 1, az, seed))
                            put(ax, ay - 1, az, GLOW_BLOCK, false);
                        break;
                    }
                    case CFEAT_CRYSTALS: {
                        if (!anchor_air) break;
                        // Crystal pocket: embed a few glowing COLOR crystals in the
                        // surrounding rock walls + a crystal lamp glowing in air. Mining
                        // a color crystal drops color_dust — the "Collect the Colors"
                        // quest's source (it was unreachable: color_dust was craft-only
                        // and color_crystal didn't generate). (#41)
                        put(ax, ay, az, CRYSTAL_LAMP, true);
                        int n = 3 + static_cast<int>((h2 >> 32u) % 4u);  // 3..6
                        for (int i = 0; i < n; ++i) {
                            std::uint64_t bh = fmix64(h2 ^ (static_cast<std::uint64_t>(i) * 0xC713u));
                            std::int32_t dx = static_cast<std::int32_t>((bh >> 0u)  % 3u) - 1;
                            std::int32_t dy = static_cast<std::int32_t>((bh >> 8u)  % 3u) - 1;
                            std::int32_t dz = static_cast<std::int32_t>((bh >> 16u) % 3u) - 1;
                            if (dx == 0 && dy == 0 && dz == 0) continue;
                            // Only convert solid rock into crystal (wall pocket).
                            if (cave_voxel_is_solid(ax + dx, ay + dy, az + dz, seed)) {
                                put(ax + dx, ay + dy, az + dz, COLOR_CRYSTAL, false);
                            }
                        }
                        break;
                    }
                    case CFEAT_ORE_KNOT: {
                        if (!anchor_air) break;
                        // A tight knot of ore on a cave wall — coal or iron.
                        BlockId ore = ((h2 >> 40u) & 1u) ? IRON_ORE : COAL_ORE;
                        int n = 3 + static_cast<int>((h2 >> 32u) % 4u);  // 3..6
                        for (int i = 0; i < n; ++i) {
                            std::uint64_t bh = fmix64(h2 ^ (static_cast<std::uint64_t>(i) * 0xA113u));
                            std::int32_t dx = static_cast<std::int32_t>((bh >> 0u)  % 3u) - 1;
                            std::int32_t dy = static_cast<std::int32_t>((bh >> 8u)  % 3u) - 1;
                            std::int32_t dz = static_cast<std::int32_t>((bh >> 16u) % 3u) - 1;
                            if (cave_voxel_is_solid(ax + dx, ay + dy, az + dz, seed)) {
                                put(ax + dx, ay + dy, az + dz, ore, false);
                            }
                        }
                        break;
                    }
                    case CFEAT_POOL: {
                        if (!anchor_air || !floor_below) break;
                        // A shallow water pool: fill the floor voxel and any open
                        // floor voxels immediately around it with water.
                        for (std::int32_t dz = -1; dz <= 1; ++dz) {
                            for (std::int32_t dx = -1; dx <= 1; ++dx) {
                                if (cave_voxel_is_air(ax + dx, ay, az + dz, seed) &&
                                    cave_voxel_is_solid(ax + dx, ay - 1, az + dz, seed)) {
                                    put(ax + dx, ay, az + dz, WATER, true);
                                }
                            }
                        }
                        break;
                    }
                    default: {  // CFEAT_CAMP — rare abandoned touch.
                        if (!anchor_air || !floor_below) break;
                        // A couple of cobble/plank blocks forming a low remnant and
                        // a chest marker — a hint someone was here.
                        put(ax, ay, az, CHEST, true);            // the find
                        put(ax + 1, ay, az, COBBLESTONE, true);  // toppled wall
                        put(ax - 1, ay, az, OAK_PLANKS, true);   // broken plank
                        // A torch-ish glow so the camp is noticeable in the dark.
                        if (cave_voxel_is_air(ax, ay + 1, az, seed))
                            put(ax, ay + 1, az, GLOW_BLOCK, true);
                        break;
                    }
                }
            }
        }
    }
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

                // Biome TYPE at the tree root from the Voronoi map (#6).
                Biome dom = voronoi_biome(td.root_wx, td.root_wz, seed);

                // Tree-bearing biomes only (desert/beach have no trees).
                if (dom == Biome::Desert || dom == Biome::Beach) continue;

                int H = surface_height_cached(td.root_wx, td.root_wz, anchor_cache);
                if (H <= SEA_LEVEL) continue;  // don't grow trees underwater

                // Trunk: H+1 .. H+trunk_height
                int trunk_base_wy = H + 1;
                int trunk_top_wy  = H + td.trunk_height;
                int dy_max_v      = canopy_dy_max(td.canopy_shape);
                int dy_min_v      = canopy_dy_min(td.canopy_shape) - td.extra_skirt;  // #22 elder skirt
                int canopy_wy_max = trunk_top_wy + dy_max_v;

                // Branch arms can rise a couple blocks above the canopy top and
                // their tip clusters add one more; widen the vertical overlap test
                // so a chunk that contains ONLY a branch tip still draws it.
                int feature_wy_max = canopy_wy_max;
                if (td.branch_count > 0) {
                    int branch_top = trunk_top_wy + 2 /*rise*/ + 1 /*tip cluster*/;
                    if (branch_top > feature_wy_max) feature_wy_max = branch_top;
                }

                // #75 floating-trees fix: only skip when the tree's FULL vertical extent
                // (trunk base up to the top feature) misses this chunk. The old extra
                // `canopy_wy_min > wy_max` skip dropped the tree in chunks that hold the
                // TRUNK but not the canopy, so tall trees whose trunk and canopy span two
                // chunks lost their trunk and the canopy floated.
                if (feature_wy_max < wy_min || trunk_base_wy > wy_max) continue;

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
                        // #22: a leaned upper trunk can tip into an adjacent
                        // desert/beach column — never leave a log on the sand.  The
                        // root column is already non-desert, so only the leaned half
                        // (where the position differs from the root) needs the check.
                        if ((wx_log != td.root_wx || wz_log != td.root_wz)) {
                            Biome lb = voronoi_biome(wx_log, wz_log, seed);
                            if (lb == Biome::Desert || lb == Biome::Beach) continue;
                        }
                        int lx = wx_log - wx_min;
                        int ly = wy - wy_min;
                        int lz = wz_log - wz_min;
                        chunk.set(lx, ly, lz, td.log_id);

                        // Thick trunk (#22): 2×2 logs — also fill the (+1,0), (0,+1),
                        // (+1,+1) offsets.  An offset column can have HIGHER terrain
                        // than the root (the root's trunk base is root_H+1); placing a
                        // log there at a y BELOW that column's own surface would bury
                        // it in the ground and overwrite the column's grass/dirt top.
                        // Because logs are excluded from the "top solid" surface scan,
                        // that dropped the measured surface and exposed a sub-surface
                        // cave within 5 blocks → a false "surface hole".  Guard each
                        // offset so a thick log is only placed AT/ABOVE that column's
                        // own surface (and only into AIR), keeping the trunk visible
                        // above ground and never carving the no-surface-holes rule.
                        if (td.thick_trunk) {
                            for (int tx = 0; tx <= 1; ++tx) {
                                for (int tz = 0; tz <= 1; ++tz) {
                                    if (tx == 0 && tz == 0) continue;  // already placed above
                                    int wx2 = wx_log + tx;
                                    int wz2 = wz_log + tz;
                                    if (wx2 < wx_min || wx2 > wx_max) continue;
                                    if (wz2 < wz_min || wz2 > wz_max) continue;
                                    // #22: never drop a log onto a desert/beach column
                                    // (a thick-trunk offset can cross a biome border
                                    // into the sand; logs there read as misplaced
                                    // tree trunks).  Cheap: voronoi_biome is memoised.
                                    Biome ob = voronoi_biome(wx2, wz2, seed);
                                    if (ob == Biome::Desert || ob == Biome::Beach) continue;
                                    int off_H = surface_height_cached(wx2, wz2, anchor_cache);
                                    if (wy <= off_H) continue;  // don't bury below this column's surface
                                    int olx = wx2 - wx_min, oly = ly, olz = wz2 - wz_min;
                                    if (chunk.get(olx, oly, olz) == AIR)
                                        chunk.set(olx, oly, olz, td.log_id);
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
                // Lowest dy that the shape itself fills (excludes the elder skirt,
                // which we synthesise below at dy = shape_min-1).
                int shape_dy_min = canopy_dy_min(td.canopy_shape);
                for (int dz = -reach; dz <= reach; ++dz) {
                    for (int dx = -reach; dx <= reach; ++dx) {
                        for (int dy = dy_min_v; dy <= dy_max_v; ++dy) {
                            bool fill;
                            if (dy >= shape_dy_min) {
                                fill = in_canopy(dx, dy, dz, td.canopy_shape);
                            } else {
                                // #22 ELDER skirt: a wide lower ring (radius 2..3,
                                // corners clipped) hanging one tier below a GIANT
                                // crown — gives elders a broad, drooping base.
                                int ax = (dx < 0 ? -dx : dx);
                                int az = (dz < 0 ? -dz : dz);
                                bool inring = (ax <= 3 && az <= 3) && (ax >= 2 || az >= 2)
                                              && !(ax == 3 && az == 3);
                                fill = inring;
                            }
                            if (!fill) continue;

                            std::int32_t wlx = canopy_wx + dx;
                            std::int32_t wly = trunk_top_wy + dy;
                            std::int32_t wlz = canopy_wz + dz;

                            if (wlx < wx_min || wlx > wx_max) continue;
                            if (wly < wy_min || wly > wy_max) continue;
                            if (wlz < wz_min || wlz > wz_max) continue;

                            // #22 IRREGULAR EDGES: drop a deterministic fraction of
                            // OUTER leaf voxels so the crown is ragged, not a blob.
                            if (!keep_leaf_voxel(td.leaf_hash, td.sparse, wlx, wly, wlz, dx, dz))
                                continue;

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
                            // #22: a branch arm can reach across a biome border into
                            // desert/beach sand — never leave a log there (reads as a
                            // misplaced tree trunk).  Leaf clusters are fine (foliage).
                            Biome ab = voronoi_biome(cx, cz, seed);
                            if (ab != Biome::Desert && ab != Biome::Beach) {
                                int lx = cx - wx_min, ly = cy - wy_min, lz = cz - wz_min;
                                if (chunk.get(lx, ly, lz) == AIR) chunk.set(lx, ly, lz, td.log_id);
                            }
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
                        // #22: a fallen-log run can stretch from its non-desert
                        // anchor across a biome border onto desert/beach sand —
                        // never leave a log there (it reads as a stray tree trunk).
                        Biome sb = voronoi_biome(cwx, cwz, seed);
                        if (sb == Biome::Desert || sb == Biome::Beach) continue;
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
                if (dom == Biome::Snowy) continue;   // desert/beach now scatter cactus/shells (#58)

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
                std::uint64_t roll3 = (ph >> 16u) & 0xFFu; // 0..255, pebble scatter

                BlockId plant = AIR;

                if (dom == Biome::Forest) {
                    // Undergrowth: tall_grass scattered tufts under the canopy.
                    // TRIMMED ~25%: thresholds multiplied by 0.75 vs prior version.
                    if (surf == GRASS) {
                        if      (roll <  45u) plant = TALL_GRASS;   // ~18% (was ~24%)
                        else if (roll <  60u) plant = FLOWER_RED;   // ~6%  (was ~8%)
                        else if (roll <  75u) plant = FLOWER_YELLOW;// ~6%  (was ~7%)
                        else if (roll <  85u) plant = MUSHROOM;     // ~4%  (was ~5%)
                        else if (roll <  91u) plant = BERRY_BUSH;   // ~2%  forest berries
                        else if (roll <  97u) plant = FALLEN_STICK; // ~2%  forest-floor twigs (#58)
                    } else if (surf == DIRT) {
                        // Shaded dirt: mushrooms more likely, sparse tall grass.
                        // TRIMMED ~25%.
                        if      (roll2 < 55u) plant = MUSHROOM;     // ~22%
                        else if (roll2 < 70u) plant = TALL_GRASS;   // ~6%
                        else if (roll2 < 82u) plant = FALLEN_STICK; // ~5%  twigs on bare dirt
                    }
                } else if (dom == Biome::Swamp) {
                    // Marsh: reeds prominent at the wet edges, plus mushrooms + grass.
                    if (surf == GRASS || surf == DIRT) {
                        if      (roll <  32u) plant = REED;         // ~12% cattail reeds (#58)
                        else if (roll <  60u) plant = MUSHROOM;     // ~11%
                        else if (roll <  74u) plant = TALL_GRASS;   // ~5%
                        else if (roll <  86u) plant = FLOWER_RED;   // ~5%
                    }
                } else if (dom == Biome::Desert) {
                    if (surf == SAND && roll < 10u) plant = CACTUS_PLANT;  // ~4% cacti (#58)
                } else if (dom == Biome::Beach) {
                    if (surf == SAND && roll < 14u) plant = SEASHELL;      // ~5.5% shells (#58)
                } else if (dom == Biome::Plains) {
                    // Plains: scattered grass tufts, flowers prominent.
                    // TRIMMED ~25%.
                    if (surf == GRASS) {
                        if      (roll <  38u) plant = TALL_GRASS;   // ~15% (was ~20%)
                        else if (roll <  57u) plant = FLOWER_RED;   // ~7%  (was ~7%)
                        else if (roll <  75u) plant = FLOWER_YELLOW;// ~7%  (was ~7%)
                        else if (roll <  81u) plant = MUSHROOM;     // ~2%  (was ~2%)
                        else if (roll <  86u) plant = BERRY_BUSH;   // ~2%  meadow berries
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

                // Small rocks/pebbles scattered on bare ground across all biomes
                // (#51 m2): ~2.7% on grass/dirt/stone/sand where nothing else grew.
                if (plant == AIR && roll3 >= 249u &&
                    (surf == GRASS || surf == DIRT || surf == STONE || surf == SAND)) {
                    plant = PEBBLE;
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

                int water_depth = SEA_LEVEL - H;       // blocks of water above the floor

                // Surface life on shallow water, so the new rivers, lakes, and ponds feel
                // alive in any green biome (#58/#60). Correct by construction: the column
                // IS shallow water, so these never land on dry ground. Kept as sparse
                // accents (not carpets). Reeds take the shallowest edge band; lily pads
                // the calmer middle band.
                bool freshwater = (dom != Biome::Desert && dom != Biome::Beach);  // not ocean/dunes
                // These sit IN the surface water cell as WATERLOGGED blocks: the cell still
                // renders as water (the mesher treats REED/LILY as water for geometry), so
                // the water is not removed, while their prop models root on the bottom and
                // rise out. Reeds want exactly one-deep water so they root in the sand with
                // the lower half submerged and the cattail poof above the surface.
                if (freshwater && water_depth == 1 &&
                    ((kh >> 16u) & 0xFFu) < 18u) {                 // ~7% emergent reeds
                    std::int32_t wy = SEA_LEVEL;
                    if (wy >= wy_min && wy <= wy_max) {
                        int ly = static_cast<int>(wy - wy_min);
                        if (chunk.get(lx, ly, lz) == WATER) chunk.set(lx, ly, lz, REED);
                    }
                } else if (freshwater && water_depth >= 2 && water_depth <= 4 &&
                           ((kh >> 24u) & 0xFFu) < 26u) {          // ~10% lily pads
                    std::int32_t wy = SEA_LEVEL;
                    if (wy >= wy_min && wy <= wy_max) {
                        int ly = static_cast<int>(wy - wy_min);
                        if (chunk.get(lx, ly, lz) == WATER) chunk.set(lx, ly, lz, LILY_PAD);
                    }
                }

                // Density ~22% of submerged columns carry a strand.
                if ((kh & 0xFFu) >= 56u) continue;

                // Strand height 1..3, never reaching the water surface (leave the
                // top water block clear so it reads as submerged). water_depth above.
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
    // 2c. DESERT DECORATION (#18/#22 — sparser, and NO oak logs).
    //     Player feedback: the old "cactus" was an OAK_LOG column, which read as
    //     a tree trunk in the sand (wrong), and the desert was over-decorated
    //     (~58% of columns) so it felt cluttered rather than sparse.
    //
    //     New scheme — desert reads as a dry desert using ONLY existing blocks:
    //       * DEAD BUSH  — MUSHROOM (id 39) cross-billboard as a dry shrub.  This
    //                      is the closest existing cross-plant to a desert dead
    //                      bush (the plant family is ids 36-39).  Seam-safe: a
    //                      decoration id excluded from the seam test, sits at H+1.
    //       * ROCK SPIRE — a STONE/GRAVEL/SANDSTONE-look speckle EMBEDDED at the
    //                      sand surface (replaces the top sand at H).  STONE/GRAVEL
    //                      are counted as solid terrain by the seam test, so a
    //                      STACKED rock would bump the measured "top solid" up by 1
    //                      only on the desert side of a border (a fake >1 seam) —
    //                      embedding it at H keeps top-solid identical to bare sand.
    //
    //     NO OAK LOGS are ever placed in the desert (the old cactus stand-in is
    //     gone).  WISH: a real `cactus` / green vertical block id would let us
    //     ship an actual standing cactus; that needs content+shader work this pass
    //     does not own, so we ship the no-oak-log dead-bush + rock-spire version.
    //
    //     DENSITY: reduced ~50% (was ~58% of desert columns decorated → now
    //     ~27%).  Deserts still have character (dead bushes + rocky speckle) but
    //     read as noticeably sparser/emptier.  Decor gate: rolls 0..69 / 256 ≈
    //     27%, split dead-bush (~16%) and rock-spire (~11%).
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

                if (roll < 42u) {
                    // Dead bush: MUSHROOM cross-billboard as a dry desert shrub.
                    // ~16% of desert sand columns.  Decoration id (seam-excluded).
                    chunk.set(lx, ly_above, lz, MUSHROOM);
                } else if (roll < 70u) {
                    // Rock spire: embed a STONE/GRAVEL speckle AT the sand surface
                    // (replace the top sand) — seam-safe (no added height).  Reads
                    // as a small sandstone/stone outcrop, not an oak log.
                    // ~11% of desert sand columns.
                    BlockId rb = ((dh >> 8u) & 1u) ? GRAVEL : STONE;
                    chunk.set(lx, ly_surf, lz, rb);
                }
                // else: bare sand (no oak logs, ever).
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
    // Voronoi TYPE map (#6) — the contiguous, clean-edged biome a column belongs
    // to.  Matches exactly what generate() uses for surface blocks/features.
    return static_cast<int>(voronoi_biome(wx, wz, seed));
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
// #17 engine hook: structure marker query.
// ---------------------------------------------------------------------------
// Returns true if (wx,wz) is the anchor (centre) column of a structure for this
// seed, writing the structure's surface world-y into out_y.  This is the cheap,
// voxel-free way for the engine to find structures (e.g. to spawn an NPC at one):
// it reuses the same deterministic struct_for_cell() the generator uses, so the
// answer always matches the built world.  A BEACON_BLOCK is ALSO buried at
// (wx, out_y-1) in the generated chunk, so the engine may detect markers either
// way (query here, or scan voxels for BEACON_BLOCK id 34).
bool worldgen_structure_marker_at(std::int32_t wx, std::int32_t wz,
                                  std::uint64_t seed, int& out_y) noexcept {
    std::int32_t scx = struct_floordiv(wx, STRUCT_CELL_SIZE);
    std::int32_t scz = struct_floordiv(wz, STRUCT_CELL_SIZE);
    // The anchor lies in this cell or — if the column is near a cell border — a
    // neighbouring one.  Check the 3×3 neighbourhood.
    for (std::int32_t dz = -1; dz <= 1; ++dz)
        for (std::int32_t dx = -1; dx <= 1; ++dx) {
            StructDesc sd = struct_for_cell(scx + dx, scz + dz, seed);
            if (sd.present && sd.anchor_wx == wx && sd.anchor_wz == wz) {
                out_y = struct_surface(wx, wz, seed);
                return true;
            }
        }
    return false;
}

// ---------------------------------------------------------------------------
// #39 engine hook: which structure cell CONTAINS this column (for NPC spawning).
// ---------------------------------------------------------------------------
// Returns the STRUCT_* type of the structure occupying the 64×64 cell that holds
// (wx,wz), writing the anchor column + anchor surface Y into the out-params.  See
// the header for the full int->name table.  Pure / deterministic — reuses the
// same struct_for_cell() the generator uses, so the answer matches the world.
int worldgen_structure_near(std::int32_t wx, std::int32_t wz, std::uint64_t seed,
                            std::int32_t* out_ax, std::int32_t* out_az,
                            int* out_y) noexcept {
    std::int32_t scx = struct_floordiv(wx, STRUCT_CELL_SIZE);
    std::int32_t scz = struct_floordiv(wz, STRUCT_CELL_SIZE);
    StructDesc sd = struct_for_cell(scx, scz, seed);
    if (!sd.present || sd.type == STRUCT_NONE) return STRUCT_NONE;
    if (out_ax) *out_ax = sd.anchor_wx;
    if (out_az) *out_az = sd.anchor_wz;
    if (out_y)  *out_y  = struct_surface(sd.anchor_wx, sd.anchor_wz, seed);
    return sd.type;
}

// Returns true if (wx,wz) lies within the footprint of any structure for this
// seed.  Used to EXEMPT structure columns from the no-surface-holes test, exactly
// as cave entrances are exempted: a roofed/hollow build legitimately has interior
// air below its topmost solid.  Conservative — uses STRUCT_MAX_REACH_XZ so the
// whole build (incl. roof overhang) is covered; only relaxes the hole check, so
// natural terrain outside footprints is unaffected.
bool worldgen_structure_footprint(std::int32_t wx, std::int32_t wz,
                                  std::uint64_t seed) noexcept {
    std::int32_t scx_min = struct_floordiv(wx - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    std::int32_t scx_max = struct_floordiv(wx + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    std::int32_t scz_min = struct_floordiv(wz - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    std::int32_t scz_max = struct_floordiv(wz + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    for (std::int32_t scz = scz_min; scz <= scz_max; ++scz)
        for (std::int32_t scx = scx_min; scx <= scx_max; ++scx) {
            StructDesc sd = struct_for_cell(scx, scz, seed);
            if (!sd.present) continue;
            std::int32_t ddx = wx - sd.anchor_wx; if (ddx < 0) ddx = -ddx;
            std::int32_t ddz = wz - sd.anchor_wz; if (ddz < 0) ddz = -ddz;
            if (ddx <= STRUCT_MAX_REACH_XZ && ddz <= STRUCT_MAX_REACH_XZ) return true;
        }
    return false;
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
            // #65: keep big surface pits/ravines OUT of swamps. A hole in a marsh
            // would naturally be a water sinkhole, not a dry shaft, so the simplest
            // fix is to just not carve cave entrances in swamp biome. dom is a pure
            // per-column value, so this stays seam-consistent and the entrance columns
            // remain test-exempt either way.
            bool is_entrance_col = (shaft_depth > 0 && H > SEA_LEVEL && dom != Biome::Swamp);

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
                    // #60: a beach only belongs right at the shoreline. A column that
                    // blends beach + mountain climate can land high up, which used to
                    // put sand on a mountainside with no water. Gate the sand to near
                    // sea level; higher/inland "beach" columns read as normal grassy
                    // land instead.
                    if (H <= SEA_LEVEL + 2) {
                        surface_block = SAND;
                        fill_block    = SAND;
                    } else {
                        surface_block = GRASS;
                        fill_block    = DIRT;
                    }
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
                    // SEAM-SAFE SNOW (#6): the snowy surface used to BE snow_layer,
                    // but snow_layer is excluded from the "top solid" seam check, so
                    // a snowy column reported its solid top one block lower than a
                    // neighbouring biome's — a fake >1 seam wherever snowy meets
                    // another biome (rare before, common once biomes shrank for #6).
                    // Fix: the solid surface is now DIRT at H (counted by the seam
                    // test, equal to neighbours), with the white snow_layer placed
                    // ON TOP at H+1 (same pattern as mountain snow caps) — so snowy
                    // still reads as snow-covered but is seam-consistent.
                    surface_block = DIRT;   // frozen ground (snow cap added above)
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

            // Snow layer on top of mountain peaks AND across the snowy biome
            // (placed after the column loop).  We place SNOW_LAYER one block ABOVE
            // the (solid) terrain surface if it is AIR.  This creates a visible
            // white snow cap without changing the height function — and because the
            // SOLID surface block at H is a normal counted block (stone for peaks,
            // dirt for snowy), the seam test sees consistent solid tops across
            // biome borders (snow_layer is intentionally excluded from that test).
            bool wants_snow_cap = (dom == Biome::Mountains && H >= SNOW_LINE)
                               || (dom == Biome::Snowy);
            if (wants_snow_cap && H > SEA_LEVEL) {
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

    // Cave interior features (#37): dress the carved cave space with mushrooms,
    // crystals, pools, ore knots and the rare abandoned camp.  Runs after the
    // terrain/cave carve (so cave AIR exists) and is position-pure + clipped, so
    // it stays seam-safe and never touches the surface shell.
    place_cave_features(c, chunk, seed_);

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
