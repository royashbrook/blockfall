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
// Tree variety (M5 addition)
// ---------------------------
// Trees now vary in: trunk height (4..8), canopy shape (round/tall/broad),
// and wood type (oak/birch).  Shape is encoded as a 2-bit value derived
// deterministically from the cell hash.  Per-biome rules:
//   Forest:    tall or broad shapes, trunk 6..8, denser
//   Plains:    round, short trunk 4..5, sparse
//   Snowy:     tall thin (shape=tall), trunk 5..7
//   Swamp:     round, short 4..5
//   Mountains: round or tall, 5..7
// All canopy writing is seam-safe: trees hash on trunk world position and
// write into any chunk their canopy overlaps.
//
// Undergrowth (M5 addition)
// --------------------------
// The plants pass now places:
//   - BUSH blocks (OAK_LEAVES id=5 or BIRCH_LEAVES id=27) at ground level —
//     single-block shrubs and 1-block-high leaf tufts that read visually as
//     low bushes.  Density is biome-specific: lush in forest/plains/swamp,
//     absent in desert/snowy/beach.
//   - Increased TALL_GRASS and FLOWER density in forest/plains/swamp.
//   - MUSHROOM scatter under forest canopy and in swamp.
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
static constexpr BlockId OAK_LEAVES    = 5;
static constexpr BlockId SAND          = 6;
static constexpr BlockId WATER         = 9;
static constexpr BlockId COBBLESTONE   = 10;
static constexpr BlockId GRAVEL        = 11;
static constexpr BlockId SNOW_LAYER    = 12;
static constexpr BlockId ICE           = 13;
static constexpr BlockId CLAY          = 14;
static constexpr BlockId OAK_LOG       = 21;
static constexpr BlockId BIRCH_LOG     = 22;
static constexpr BlockId BIRCH_LEAVES  = 27;
static constexpr BlockId MOSSY_STONE   = 29;
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

// Canopy shape codes (2 bits):
//   ROUND — classic sphere-ish 5x3x5 blob with rounded corners (original shape)
//   TALL  — narrower, taller: 3x5x3 column-ish with top cap (spruce-like)
//   BROAD — wide flat top: 7x3x7 at trunk top, 5x3x5 one below, with crown
//   COMPACT — dense squat: 5x3x5 fully filled (used for swamp/plains short trees)
static constexpr int CANOPY_ROUND   = 0;
static constexpr int CANOPY_TALL    = 1;
static constexpr int CANOPY_BROAD   = 2;
static constexpr int CANOPY_COMPACT = 3;

// Trunk height range (now 4..8 for more variety).
static constexpr int TRUNK_MIN = 4;
static constexpr int TRUNK_MAX = 8;

// Max canopy reach for seam-safe cell scanning.
// Broad canopy extends ±3 XZ, tall extends ±1 XZ but 2 Y above trunk top.
// We use 3 as the conservative upper bound for cell scan margin.
static constexpr int CANOPY_MAX_REACH_XZ = 3;

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
    int          canopy_shape;   // CANOPY_ROUND / TALL / BROAD / COMPACT
    BlockId      log_id;
    BlockId      leaf_id;
    bool         present;
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
        return TreeDesc{0, 0, 0, 0, 0, 0, false};
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
        return TreeDesc{0, 0, 0, 0, 0, 0, false};
    }

    // Root offset within cell (1..TREE_CELL_SIZE-2).
    std::uint64_t h2 = fmix64(h ^ 0x1234567890ABCDEFull);
    std::int32_t off_x = 1 + static_cast<std::int32_t>((h2 >> 0u) & 0x5u);
    std::int32_t off_z = 1 + static_cast<std::int32_t>((h2 >> 8u) & 0x5u);

    // --- Per-biome trunk height, canopy shape, and wood type ---
    //
    // Bits used from h2:
    //   bits 16..19 (4 bits)  -> trunk length variation
    //   bits 20..21 (2 bits)  -> canopy shape selector (biome-gated)
    //   bits 24..25 (2 bits)  -> birch vs oak selector
    //
    int trunk_h;
    int canopy_shape;
    bool is_birch;

    std::uint64_t trunk_bits  = (h2 >> 16u) & 0xFu;  // 0..15
    std::uint64_t shape_bits  = (h2 >> 20u) & 0x3u;  // 0..3
    std::uint64_t birch_bits  = (h2 >> 24u) & 0x3u;  // 0..3

    switch (dom) {
        case Biome::Forest:
            // Forest: taller trees, mixed shapes, mixed oak/birch.
            // Trunk 6..8: base 6 + (bits % 3) -> 6, 7, 8
            trunk_h      = 6 + static_cast<int>(trunk_bits % 3u);
            // Shapes: round (0), broad (1), tall (2), broad again (3) — weighted toward tall/broad
            canopy_shape = (shape_bits == 0u) ? CANOPY_ROUND :
                           (shape_bits == 1u) ? CANOPY_BROAD :
                           (shape_bits == 2u) ? CANOPY_TALL  : CANOPY_BROAD;
            is_birch     = (birch_bits <= 1u);  // 50% birch
            break;

        case Biome::Mountains:
            // Mountains: medium trunks, round or tall shapes, mostly oak.
            trunk_h      = 5 + static_cast<int>(trunk_bits % 3u);   // 5..7
            canopy_shape = (shape_bits & 0x1u) ? CANOPY_TALL : CANOPY_ROUND;
            is_birch     = (birch_bits == 0u);  // 25% birch
            break;

        case Biome::Snowy:
            // Snowy: tall thin spruce-ish trees, birch-heavy.
            trunk_h      = 5 + static_cast<int>(trunk_bits % 3u);   // 5..7
            canopy_shape = CANOPY_TALL;   // always tall/narrow for snowy
            is_birch     = (birch_bits != 0u);  // 75% birch
            break;

        case Biome::Swamp:
            // Swamp: short squat trees.
            trunk_h      = 4 + static_cast<int>(trunk_bits % 2u);   // 4..5
            canopy_shape = CANOPY_COMPACT;
            is_birch     = (birch_bits <= 1u);  // 50% birch
            break;

        case Biome::Plains:
            // Plains: sparse short trees, round canopy.
            trunk_h      = 4 + static_cast<int>(trunk_bits % 2u);   // 4..5
            canopy_shape = CANOPY_ROUND;
            is_birch     = (birch_bits == 0u);  // 25% birch
            break;

        default:
            // Other (generic): medium, round, mostly oak.
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
        true
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

static bool in_canopy(int dx, int dy, int dz, int shape) noexcept {
    switch (shape) {
        case CANOPY_TALL:    return in_canopy_tall(dx, dy, dz);
        case CANOPY_BROAD:   return in_canopy_broad(dx, dy, dz);
        case CANOPY_COMPACT: return in_canopy_compact(dx, dy, dz);
        default:             return in_canopy_round(dx, dy, dz);
    }
}

// Maximum dy above trunk_top for each shape (needed for chunk scan range).
static int canopy_dy_max(int shape) noexcept {
    return (shape == CANOPY_TALL) ? 2 : 1;
}

// Minimum dy relative to trunk_top (always -1 for all shapes).
static constexpr int CANOPY_DY_MIN = -1;

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
                int dy_max        = canopy_dy_max(td.canopy_shape);
                int canopy_wy_max = trunk_top_wy + dy_max;

                if (canopy_wy_max < wy_min || trunk_base_wy > wy_max) continue;

                // Place trunk logs.
                for (int wy = trunk_base_wy; wy <= trunk_top_wy; ++wy) {
                    if (wy < wy_min || wy > wy_max) continue;
                    if (td.root_wx < wx_min || td.root_wx > wx_max) continue;
                    if (td.root_wz < wz_min || td.root_wz > wz_max) continue;
                    int lx = td.root_wx - wx_min;
                    int ly = wy - wy_min;
                    int lz = td.root_wz - wz_min;
                    chunk.set(lx, ly, lz, td.log_id);
                }

                // Place canopy leaves.
                int reach = (td.canopy_shape == CANOPY_BROAD) ? 3 : 2;
                for (int dz = -reach; dz <= reach; ++dz) {
                    for (int dx = -reach; dx <= reach; ++dx) {
                        for (int dy = CANOPY_DY_MIN; dy <= dy_max; ++dy) {
                            if (!in_canopy(dx, dy, dz, td.canopy_shape)) continue;

                            std::int32_t wlx = td.root_wx + dx;
                            std::int32_t wly = trunk_top_wy + dy;
                            std::int32_t wlz = td.root_wz + dz;

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
    // 2. PLANTS + BUSHES — biome-specific single-block surface decorations.
    //
    //    Bushes are placed as leaf blocks (OAK_LEAVES/BIRCH_LEAVES) directly
    //    at H+1 — they read visually as low shrubs sitting on the ground.
    //    Density varies strongly by biome:
    //      Forest: dense tall_grass, flowers, some mushrooms, many bushes
    //      Plains: moderate tall_grass, flowers, some bushes
    //      Swamp:  tall_grass, many mushrooms, scattered bushes
    //      Snowy:  bare (no plants)
    //      Desert: bare
    //      Beach:  bare
    //      Mountains: sparse grass, no bushes above snow line
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
                    // Dense undergrowth: tall_grass most common, flowers, mushrooms,
                    // and fairly frequent leaf bushes.
                    if (surf == GRASS) {
                        if      (roll < 120u) plant = TALL_GRASS;
                        else if (roll < 140u) plant = FLOWER_RED;
                        else if (roll < 158u) plant = FLOWER_YELLOW;
                        else if (roll < 172u) plant = MUSHROOM;
                        // Bushes: leaf blocks at ground level (20% of columns)
                        else if (roll < 204u) plant = OAK_LEAVES;
                    } else if (surf == DIRT) {
                        // Shaded dirt: mushrooms more likely
                        if      (roll2 < 80u) plant = MUSHROOM;
                        else if (roll2 < 120u) plant = TALL_GRASS;
                    }
                } else if (dom == Biome::Swamp) {
                    // Swamp: lots of mushrooms + tall grass, scattered bushes on high spots.
                    if (surf == GRASS || surf == DIRT) {
                        if      (roll < 100u) plant = TALL_GRASS;
                        else if (roll < 150u) plant = MUSHROOM;
                        else if (roll < 170u) plant = FLOWER_RED;
                        // Bush (birch leaves for variety in swamp)
                        else if (roll < 195u) plant = BIRCH_LEAVES;
                    }
                } else if (dom == Biome::Plains) {
                    // Plains: lots of tall grass, flowers, occasional bushes.
                    if (surf == GRASS) {
                        if      (roll < 100u) plant = TALL_GRASS;
                        else if (roll < 118u) plant = FLOWER_RED;
                        else if (roll < 136u) plant = FLOWER_YELLOW;
                        // Occasional mushroom
                        else if (roll < 142u) plant = MUSHROOM;
                        // Scattered bushes (oak leaves, ~8% of grass columns)
                        else if (roll < 162u) plant = OAK_LEAVES;
                    }
                } else if (dom == Biome::Mountains) {
                    // Mountains: sparse grass on lower slopes, no plants above snow line.
                    if (H >= SNOW_LINE) {
                        plant = AIR;
                    } else if (surf == GRASS) {
                        if (roll < 45u) plant = TALL_GRASS;
                    }
                } else {
                    // Default fallback: plains-like.
                    if (surf == GRASS) {
                        if      (roll < 100u) plant = TALL_GRASS;
                        else if (roll < 118u) plant = FLOWER_RED;
                        else if (roll < 136u) plant = FLOWER_YELLOW;
                        else if (roll < 142u) plant = MUSHROOM;
                        else if (roll < 162u) plant = OAK_LEAVES;
                    }
                }

                if (plant != AIR) {
                    chunk.set(lx, ly_plant, lz, plant);
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // 3. SWAMP CLAY PATCHES — scatter clay blocks in swamp surface.
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
    // 4. FOREST MOSSY STONE PATCHES — replace some surface stone with mossy stone.
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
