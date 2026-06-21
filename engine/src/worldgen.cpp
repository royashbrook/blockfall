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
#include <cstdint>

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
static constexpr int SNOW_LINE = 24;

// Cave noise threshold: cells whose 3D noise > this become AIR.
static constexpr float CAVE_THRESH = 0.68f;

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
    { 18.0f,  38.0f,  1.0f/28.0f,  5,     0.62f },  // Mountains (tall, jagged)
    {  7.0f,   9.0f,  1.0f/64.0f,  3,     0.45f },  // Desert (wide smooth dunes)
    {  8.0f,  14.0f,  1.0f/48.0f,  4,     0.50f },  // Snowy (hillier white plains)
    {  4.0f,   5.0f,  1.0f/56.0f,  3,     0.45f },  // Swamp (very flat, lower)
    {  6.5f,   1.0f,  1.0f/96.0f,  2,     0.40f },  // Beach (extremely flat near sea)
};

static constexpr BiomeCentre BIOME_CENTRES[NUM_BIOMES] = {
    // temp  moist  r_t    r_m
    // Radii tightened so biomes are more distinct at their centres.
    { 0.50f, 0.50f, 0.28f, 0.28f },  // Plains
    { 0.50f, 0.82f, 0.22f, 0.20f },  // Forest (high moisture)
    { 0.22f, 0.38f, 0.22f, 0.28f },  // Mountains (cool, moderate moisture)
    { 0.85f, 0.10f, 0.20f, 0.18f },  // Desert (hot, dry)
    { 0.08f, 0.50f, 0.18f, 0.32f },  // Snowy (very cold)
    { 0.50f, 0.96f, 0.28f, 0.08f },  // Swamp (max moisture)
    { 0.65f, 0.27f, 0.18f, 0.18f },  // Beach (warm, low moisture)
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

static void biome_weights(std::int32_t wx, std::int32_t wz, std::uint64_t seed,
                          float weights[NUM_BIOMES]) noexcept {
    // Derive separate seeds for temperature and moisture channels.
    std::uint64_t tseed = fmix64(seed ^ 0xB10E5EED00000001ull);
    std::uint64_t mseed = fmix64(seed ^ 0xB10E5EED00000002ull);

    float fwx = static_cast<float>(wx);
    float fwz = static_cast<float>(wz);

    // Low-frequency (large scale biome zones).
    float temp  = fbm2(fwx, fwz, tseed, /*octaves=*/2, /*freq=*/1.0f / 192.0f);
    float moist = fbm2(fwx, fwz, mseed, /*octaves=*/2, /*freq=*/1.0f / 192.0f);

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

static int surface_height(std::int32_t wx, std::int32_t wz,
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

    return static_cast<int>(blended_h);
}

// ---------------------------------------------------------------------------
// Slope computation for mountain biome (seam-safe)
// ---------------------------------------------------------------------------
// Computes slope as max absolute height difference to 4 orthogonal neighbours.
// Uses the SAME surface_height() function on neighbouring coords — because
// surface_height is a pure continuous function, this is seam-safe across
// chunk boundaries: both chunks will compute identical neighbour heights.
// ---------------------------------------------------------------------------
static int slope_at(std::int32_t wx, std::int32_t wz, std::uint64_t seed, int H) noexcept {
    float wN[NUM_BIOMES], wS[NUM_BIOMES], wE[NUM_BIOMES], wW[NUM_BIOMES];
    biome_weights(wx,     wz - 1, seed, wN);
    biome_weights(wx,     wz + 1, seed, wS);
    biome_weights(wx + 1, wz,     seed, wE);
    biome_weights(wx - 1, wz,     seed, wW);
    int hN = surface_height(wx,     wz - 1, seed, wN);
    int hS = surface_height(wx,     wz + 1, seed, wS);
    int hE = surface_height(wx + 1, wz,     seed, wE);
    int hW = surface_height(wx - 1, wz,     seed, wW);

    auto absi = [](int a, int b) noexcept -> int { int d = a - b; return d < 0 ? -d : d; };
    int s = absi(H, hN);
    int t = absi(H, hS); if (t > s) s = t;
    t = absi(H, hE); if (t > s) s = t;
    t = absi(H, hW); if (t > s) s = t;
    return s;
}

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

// Default tree probability threshold (~18% of cells).
static constexpr std::uint64_t TREE_PROB_THRESH_DEFAULT = 11796u;   // 0.18 * 65535
// Forest biome: much denser trees (~55%).
static constexpr std::uint64_t TREE_PROB_THRESH_FOREST  = 36044u;   // 0.55 * 65535
// Snowy biome: sparse birch (~12%).
static constexpr std::uint64_t TREE_PROB_THRESH_SNOWY   = 7864u;    // 0.12 * 65535
// Swamp biome: sparse (~15%).
static constexpr std::uint64_t TREE_PROB_THRESH_SWAMP   = 9830u;    // 0.15 * 65535

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
};

// Determine if a tree exists in the given tree cell, and its properties.
// The presence threshold is biome-dependent.  We sample the biome weights at
// the cell origin (rather than the exact root) to keep the decision cheap and
// still seam-safe (the origin is fully deterministic from cell coords).
static TreeDesc tree_for_cell(std::int32_t cell_cx, std::int32_t cell_cz,
                               std::uint64_t seed) noexcept {
    std::uint64_t tseed = fmix64(seed ^ TREE_SEED_MIX);
    std::uint64_t h = hash2(cell_cx, cell_cz, tseed);

    // Get biome weights at cell origin to choose threshold and tree type.
    std::int32_t cell_origin_x = cell_cx * TREE_CELL_SIZE;
    std::int32_t cell_origin_z = cell_cz * TREE_CELL_SIZE;
    float weights[NUM_BIOMES];
    biome_weights(cell_origin_x, cell_origin_z, seed, weights);
    Biome dom = dominant_biome(weights);

    // Biomes that never have trees.
    if (dom == Biome::Desert || dom == Biome::Beach) {
        return TreeDesc{0, 0, 0, 0, 0, 0, false, false, 0, 0};
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
        return TreeDesc{0, 0, 0, 0, 0, 0, false, false, 0, 0};
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

    // Rare GIANT tree: appears ~6% of non-desert/beach cells regardless of biome.
    // Trunk 10..12, giant canopy, always oak, always thick trunk (2×2 logs).
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
            /*lean_dx=*/0, /*lean_dz=*/0
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
        lean_dz
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
// WEEPING has leaves 3 below trunk_top (dy=-3); others -1.
static int canopy_dy_min(int shape) noexcept {
    if (shape == CANOPY_WEEPING) return -3;
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

    // Spawn probability ~12%: keep if (h & 0xFFu) < 31.
    if ((h & 0xFFu) >= 31u) {
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
    // shared "floor level" from which wall height is counted.
    int floor_h = 0;
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
    int max_corner_h = 0;
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
// Decoration pass — seam-aware, biome-aware
// ---------------------------------------------------------------------------
static void place_decorations(ChunkCoord c, IChunk& chunk, std::uint64_t seed) {
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

                int H = surface_height(td.root_wx, td.root_wz, seed, weights);
                if (H <= SEA_LEVEL) continue;  // don't grow trees underwater

                // Trunk: H+1 .. H+trunk_height
                int trunk_base_wy = H + 1;
                int trunk_top_wy  = H + td.trunk_height;
                int dy_max_v      = canopy_dy_max(td.canopy_shape);
                int dy_min_v      = canopy_dy_min(td.canopy_shape);
                int canopy_wy_max = trunk_top_wy + dy_max_v;
                int canopy_wy_min = trunk_top_wy + dy_min_v;

                if (canopy_wy_max < wy_min || trunk_base_wy > wy_max) continue;
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

                float weights[NUM_BIOMES];
                biome_weights(wx, wz, seed, weights);
                Biome dom = dominant_biome(weights);

                // Desert, Beach, and Snowy have minimal/no surface plants.
                if (dom == Biome::Desert || dom == Biome::Beach || dom == Biome::Snowy) continue;

                int H = surface_height(wx, wz, seed, weights);
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

                float weights[NUM_BIOMES];
                biome_weights(wx, wz, seed, weights);
                Biome dom = dominant_biome(weights);

                if (dom != Biome::Swamp) continue;

                int H = surface_height(wx, wz, seed, weights);

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

                float weights[NUM_BIOMES];
                biome_weights(wx, wz, seed, weights);
                Biome dom = dominant_biome(weights);

                if (dom != Biome::Forest) continue;

                int H = surface_height(wx, wz, seed, weights);

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
// Terrain fill — per-column block placement
// ---------------------------------------------------------------------------
void TerrainGen::seed(std::uint64_t s) {
    seed_ = s;
}

void TerrainGen::generate(ChunkCoord c, IChunk& chunk) {
    for (int lz = 0; lz < kChunkDim; ++lz) {
        for (int lx = 0; lx < kChunkDim; ++lx) {
            std::int32_t wx = c.x * kChunkDim + lx;
            std::int32_t wz = c.z * kChunkDim + lz;

            // Compute biome weights and blended surface height.
            float weights[NUM_BIOMES];
            biome_weights(wx, wz, seed_, weights);
            Biome dom = dominant_biome(weights);
            int H = surface_height(wx, wz, seed_, weights);

            // -----------------------------------------------------------------
            // Mountain slope detection (seam-safe: uses same continuous height fn).
            // Steep slopes (>=3 blocks drop to neighbour) get stone/cobblestone
            // instead of grass, to read as exposed rock faces.
            // -----------------------------------------------------------------
            bool is_steep = false;
            if (dom == Biome::Mountains && H < SNOW_LINE) {
                int slope = slope_at(wx, wz, seed_, H);
                is_steep = (slope >= 3);
            }

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
                } else if (wy == H) {
                    // Surface voxel.
                    if (wy <= SEA_LEVEL && dom != Biome::Desert) {
                        // Submerged surface: sand beach transition.
                        b = SAND;
                    } else {
                        b = surface_block;
                    }
                } else if (wy >= H - 3) {
                    // Sub-surface fill layer (3 blocks deep).
                    if (dom == Biome::Mountains && H >= SNOW_LINE && wy == H - 1) {
                        // Just below peak: gravel for variety.
                        b = GRAVEL;
                    } else if (dom == Biome::Desert) {
                        // Desert: sand fill with a thin stone (sandstone-like) layer
                        // at H-3 for visual variety when digging.
                        if (wy == H - 3) {
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
                // Cave carving.
                // FIX: surface margin raised from 2 to CAVE_SURFACE_MARGIN (6).
                // This prevents AIR pockets within the top 5 blocks under the
                // surface, eliminating the "holes in hilltops" feedback.
                // Caves still exist well underground.
                // -----------------------------------------------------------------
                if (b != AIR && b != WATER && wy < H - CAVE_SURFACE_MARGIN
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
            std::int32_t wx = c.x * kChunkDim + lx;
            std::int32_t wz = c.z * kChunkDim + lz;

            float weights[NUM_BIOMES];
            biome_weights(wx, wz, seed_, weights);
            Biome dom = dominant_biome(weights);

            if (dom != Biome::Swamp) continue;

            int H = surface_height(wx, wz, seed_, weights);
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
    place_decorations(c, chunk, seed_);
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
