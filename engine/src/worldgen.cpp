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
// Terrain
// -------
//   surface height H = BASE_Y + int(fbm2 * AMP)
//   BASE_Y=8, AMP=24  =>  H roughly in [8-24 .. 8+24] = [-16..32]
//
// Biomes (low-frequency 2D noise)
//   < 0.4 -> plains  (GRASS surface, DIRT fill)
//   0.4..0.7 -> hills (GRASS surface, STONE fill at depth, more amplitude)
//   > 0.7 -> desert  (SAND surface, SAND fill)
//
// Caves (3D fbm > threshold, only underground, above kColumnMinY+4)
//
// Decoration (seam-aware scatter)
// ---------------------------------
// Trees are placed on a virtual 8x8 world-block grid of "tree cells".  Each
// cell either has a tree or not (probability ~18%, plains/hills only).  The
// tree's exact (wx, wz) root is offset within the cell by hash.  Trunk height
// (4..6) and type (oak/birch) are also hash-derived from the root column.
// Canopy is a 5x5x3 leaf blob centred on the top of the trunk (clipped by
// rounded corners).
//
// When generating chunk C, we scan every tree cell whose influence bounding-box
// (root ± CANOPY_RADIUS_XZ, root.y .. root.y + trunk + CANOPY_HEIGHT) might
// overlap chunk C.  For each such tree we place only the voxels that actually
// fall inside C.  Because all decisions derive from (wx,wz,seed) alone, the
// same tree voxels appear correctly in every adjacent chunk that covers them.
//
// Plants (tall grass, flowers, mushrooms) are single-block decorations placed
// directly on each column's surface — they need no cross-chunk margin because
// they are exactly 1 block tall.
// ============================================================================
#include "blockcore/worldgen.hpp"
#include "blockcore/chunk.hpp"

#include <cmath>
#include <cstdint>

namespace bf {

// ---------------------------------------------------------------------------
// Block id constants
// ---------------------------------------------------------------------------
static constexpr BlockId AIR          = 0;
static constexpr BlockId GRASS        = 1;
static constexpr BlockId DIRT         = 2;
static constexpr BlockId STONE        = 3;
static constexpr BlockId OAK_LEAVES   = 5;
static constexpr BlockId SAND         = 6;
static constexpr BlockId WATER        = 9;
static constexpr BlockId OAK_LOG      = 21;
static constexpr BlockId BIRCH_LOG    = 22;
static constexpr BlockId BIRCH_LEAVES = 27;
static constexpr BlockId FLOWER_RED   = 36;
static constexpr BlockId FLOWER_YELLOW= 37;
static constexpr BlockId TALL_GRASS   = 38;
static constexpr BlockId MUSHROOM     = 39;

static constexpr int SEA_LEVEL  = 6;
static constexpr int BASE_Y     = 8;
static constexpr int AMP_PLAINS = 12;
static constexpr int AMP_HILLS  = 24;
static constexpr int AMP_DESERT = 10;

// Cave noise threshold: cells whose 3D noise > this become AIR.
static constexpr float CAVE_THRESH = 0.68f;

// ---------------------------------------------------------------------------
// Hash primitives — Wang/murmur-inspired 64-bit mixes
// ---------------------------------------------------------------------------

// Mix a single 64-bit value (finalizer from MurmurHash3 / fmix64).
static constexpr std::uint64_t fmix64(std::uint64_t h) noexcept {
    h ^= h >> 33u;
    h *= 0xFF51AFD7ED558CCDull;
    h ^= h >> 33u;
    h *= 0xC4CEB9FE1A85EC53ull;
    h ^= h >> 33u;
    return h;
}

// Hash two signed 32-bit coords + seed into a 64-bit value.
static std::uint64_t hash2(std::int32_t ix, std::int32_t iz, std::uint64_t seed) noexcept {
    std::uint64_t h = seed;
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(ix)));
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(iz)) * 0x9E3779B97F4A7C15ull);
    return fmix64(h);
}

// Hash three signed 32-bit coords + seed.
static std::uint64_t hash3(std::int32_t ix, std::int32_t iy, std::int32_t iz,
                            std::uint64_t seed) noexcept {
    std::uint64_t h = seed;
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(ix)));
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(iy)) * 0x517CC1B727220A95ull);
    h ^= fmix64(static_cast<std::uint64_t>(static_cast<std::uint32_t>(iz)) * 0x9E3779B97F4A7C15ull);
    return fmix64(h);
}

// Map a 64-bit hash to [0, 1].
static float h2f(std::uint64_t h) noexcept {
    // Use top 24 bits for float precision.
    return static_cast<float>(h >> 40u) / static_cast<float>(1u << 24u);
}

// ---------------------------------------------------------------------------
// Smoothstep (3rd-order, C1 continuous)
// ---------------------------------------------------------------------------
static constexpr float smoothstep(float t) noexcept {
    return t * t * (3.0f - 2.0f * t);
}

// ---------------------------------------------------------------------------
// 2D value noise: bilinearly interpolated hash lattice
// Coordinate space: (fx, fz) are in [0, inf); lattice step = 1 unit
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

    // Interpolate along x first, then y, then z
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
// Fractal Brownian Motion (fBm) — 2D, seeded per octave
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
        // Perturb seed per octave to avoid octave correlation.
        std::uint64_t oseed = fmix64(seed ^ static_cast<std::uint64_t>(o) * 0xABCDEF01234567ull);
        val     += amp * value_noise2(wx * freq, wz * freq, oseed);
        max_val += amp;
        amp     *= persistence;
        freq    *= lacunarity;
    }
    return val / max_val;   // normalize to [0, 1]
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
// Biome helpers
// ---------------------------------------------------------------------------
enum class Biome : std::uint8_t { Plains, Hills, Desert };

// Low-frequency biome noise — continuous, no per-chunk discontinuity.
static Biome biome_at(std::int32_t wx, std::int32_t wz, std::uint64_t seed) noexcept {
    // Use a seed derived from base seed to separate biome from terrain.
    std::uint64_t bseed = fmix64(seed ^ 0xB10E5EED5ull);
    float b = fbm2(static_cast<float>(wx), static_cast<float>(wz), bseed,
                   /*octaves=*/2, /*base_freq=*/1.0f / 128.0f);
    if (b < 0.4f)  return Biome::Plains;
    if (b < 0.7f)  return Biome::Hills;
    return Biome::Desert;
}

// Surface height as a continuous function of world (wx, wz).
static int surface_height(std::int32_t wx, std::int32_t wz,
                          std::uint64_t seed, Biome biome) noexcept {
    float fwx = static_cast<float>(wx);
    float fwz = static_cast<float>(wz);

    int amp;
    switch (biome) {
        case Biome::Plains: amp = AMP_PLAINS; break;
        case Biome::Hills:  amp = AMP_HILLS;  break;
        case Biome::Desert: amp = AMP_DESERT; break;
        default:            amp = AMP_PLAINS; break;
    }

    float n = fbm2(fwx, fwz, seed, /*octaves=*/4, /*base_freq=*/1.0f / 48.0f);
    // n in [0,1], map to [BASE_Y - amp, BASE_Y + amp]
    int H = BASE_Y + static_cast<int>(n * static_cast<float>(2 * amp)) - amp;
    return H;
}

// ---------------------------------------------------------------------------
// Decoration constants
// ---------------------------------------------------------------------------

// Trees are scattered on a world-aligned grid of TREE_CELL_SIZE x TREE_CELL_SIZE
// blocks.  At most one tree origin exists per cell; the exact (wx,wz) offset
// within the cell is hash-derived so trees don't line up on a lattice.
static constexpr int TREE_CELL_SIZE   = 8;   // blocks — min spacing (approx)
// Canopy is a 5×5×3 blob centred on (trunk_top_wx, trunk_top_wy, trunk_top_wz).
static constexpr int CANOPY_RADIUS_XZ = 2;   // extends ±2 in X and Z
static constexpr int CANOPY_RADIUS_Y  = 1;   // extends ±1 in Y
static constexpr int TRUNK_MIN        = 4;
static constexpr int TRUNK_MAX        = 6;
// Probability threshold: a cell spawns a tree when hash < TREE_PROB_THRESH/0xFFFF.
// 0.18 * 65535 ≈ 11796
static constexpr std::uint64_t TREE_PROB_THRESH = 11796u;

// ---------------------------------------------------------------------------
// Decoration seeds — derive from base seed to avoid correlation with terrain
// ---------------------------------------------------------------------------
// We use two distinct derived seeds so that the tree scatter hash and plant
// scatter hash each feel independent.
static constexpr std::uint64_t TREE_SEED_MIX  = 0xD7C0DECAF00D1234ull;
static constexpr std::uint64_t PLANT_SEED_MIX = 0xB16B00B5CAFE5EEDull;

// ---------------------------------------------------------------------------
// Tree queries — pure functions of world (wx, wz) and seed
// ---------------------------------------------------------------------------

// Given a world column (wx, wz), return the "tree cell" coordinates.
static void tree_cell(std::int32_t wx, std::int32_t wz,
                      std::int32_t& cx, std::int32_t& cz) noexcept {
    // Floor division towards -inf.
    auto floordiv = [](std::int32_t a, int b) noexcept -> std::int32_t {
        return a / b - (a % b != 0 && (a ^ b) < 0 ? 1 : 0);
    };
    cx = floordiv(wx, TREE_CELL_SIZE);
    cz = floordiv(wz, TREE_CELL_SIZE);
}

struct TreeDesc {
    std::int32_t root_wx;    // world x of trunk base
    std::int32_t root_wz;    // world z of trunk base
    int          trunk_height; // 4..6
    BlockId      log_id;     // OAK_LOG or BIRCH_LOG
    BlockId      leaf_id;    // OAK_LEAVES or BIRCH_LEAVES
    bool         present;    // false => no tree in this cell
};

// Deterministically determine if a tree exists in a given tree cell, and
// if so, what its properties are.  Pure function of (cell_cx, cell_cz, seed).
static TreeDesc tree_for_cell(std::int32_t cell_cx, std::int32_t cell_cz,
                               std::uint64_t seed) noexcept {
    std::uint64_t tseed = fmix64(seed ^ TREE_SEED_MIX);

    // Primary hash for the cell.
    std::uint64_t h = hash2(cell_cx, cell_cz, tseed);

    // Decide presence.
    std::uint64_t prob = h & 0xFFFFu;
    if (prob >= TREE_PROB_THRESH) {
        return TreeDesc{0, 0, 0, 0, 0, false};
    }

    // Root offset within the cell (1..TREE_CELL_SIZE-2 to avoid edge collisions).
    std::int32_t cell_origin_x = cell_cx * TREE_CELL_SIZE;
    std::int32_t cell_origin_z = cell_cz * TREE_CELL_SIZE;
    std::uint64_t h2 = fmix64(h ^ 0x1234567890ABCDEFull);
    std::int32_t off_x = 1 + static_cast<std::int32_t>((h2 >> 0u) & 0x5u);  // 1..5
    std::int32_t off_z = 1 + static_cast<std::int32_t>((h2 >> 8u) & 0x5u);  // 1..5

    // Trunk height: 4..6
    int trunk_h = TRUNK_MIN + static_cast<int>((h2 >> 16u) % static_cast<std::uint64_t>(TRUNK_MAX - TRUNK_MIN + 1));

    // Tree type: oak (lower bits) or birch.
    bool is_birch = ((h2 >> 24u) & 0x3u) == 0u;  // ~25% birch

    return TreeDesc{
        cell_origin_x + off_x,
        cell_origin_z + off_z,
        trunk_h,
        is_birch ? BIRCH_LOG    : OAK_LOG,
        is_birch ? BIRCH_LEAVES : OAK_LEAVES,
        true
    };
}

// Returns true if (leaf_dx, leaf_dy, leaf_dz) is inside the rounded canopy blob.
// Canopy is a 5x5x3 cluster centred at the trunk top.  Corner voxels of the
// outer ring on the top/bottom slabs are cut to give a rounder shape.
static bool in_canopy(int dx, int dy, int dz) noexcept {
    // dx, dz relative to trunk top (horizontal centre); dy relative to trunk top.
    // Canopy occupies dy in [-1, 0, +1] and dx/dz in [-2, -1, 0, +1, +2].
    if (dy < -1 || dy > 1)              return false;
    if (dx < -CANOPY_RADIUS_XZ || dx > CANOPY_RADIUS_XZ) return false;
    if (dz < -CANOPY_RADIUS_XZ || dz > CANOPY_RADIUS_XZ) return false;
    // Cut corners: on the outer ring (|dx|==2 or |dz|==2), disallow corners
    // only on the top and bottom slabs (dy != 0).
    bool outer_x = (dx == -2 || dx == 2);
    bool outer_z = (dz == -2 || dz == 2);
    if (outer_x && outer_z && dy != 0) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Decoration pass — called from generate() after terrain+cave fill
// ---------------------------------------------------------------------------
// This function places trees and plants into `chunk`.  It is seam-aware:
//   - Plants: only affect the column (wx, wz) that belongs to this chunk.
//   - Trees : scan a margin of tree cells whose canopy might overlap this chunk,
//             place only voxels that land inside local coords [0..15].
//
// All decisions are pure functions of world coords + seed_ — no mutable state.
static void place_decorations(ChunkCoord c, IChunk& chunk, std::uint64_t seed) {
    // World-space bounds of this chunk (inclusive).
    std::int32_t wx_min = c.x * kChunkDim;
    std::int32_t wy_min = c.y * kChunkDim;
    std::int32_t wz_min = c.z * kChunkDim;
    std::int32_t wx_max = wx_min + kChunkDim - 1;
    std::int32_t wy_max = wy_min + kChunkDim - 1;
    std::int32_t wz_max = wz_min + kChunkDim - 1;

    // -------------------------------------------------------------------
    // 1. TREES
    //    Determine which tree cells could influence this chunk.
    //    A tree's canopy extends ±CANOPY_RADIUS_XZ in x/z from its root and
    //    the trunk can be up to TRUNK_MAX+CANOPY_RADIUS_Y blocks above the surface.
    //    Surface height is at most BASE_Y + AMP_HILLS = 8 + 24 = 32.
    //    We conservatively expand the search area by CANOPY_RADIUS_XZ blocks on
    //    each side in X/Z.
    // -------------------------------------------------------------------
    {
        // Cell indices covering the potentially-influencing range in X and Z.
        std::int32_t cell_xmin, cell_xmax, cell_zmin, cell_zmax, dummy;
        tree_cell(wx_min - CANOPY_RADIUS_XZ, wz_min - CANOPY_RADIUS_XZ, cell_xmin, cell_zmin);
        tree_cell(wx_max + CANOPY_RADIUS_XZ, wz_max + CANOPY_RADIUS_XZ, cell_xmax, dummy);
        tree_cell(wx_min, wz_max + CANOPY_RADIUS_XZ, dummy, cell_zmax);
        (void)dummy;

        for (std::int32_t ccz = cell_zmin; ccz <= cell_zmax; ++ccz) {
            for (std::int32_t ccx = cell_xmin; ccx <= cell_xmax; ++ccx) {
                TreeDesc td = tree_for_cell(ccx, ccz, seed);
                if (!td.present) continue;

                // Determine tree's biome and surface height.
                Biome bio = biome_at(td.root_wx, td.root_wz, seed);
                // Trees only in grassy biomes above sea level.
                if (bio == Biome::Desert) continue;

                int H = surface_height(td.root_wx, td.root_wz, seed, bio);
                if (H <= SEA_LEVEL) continue;  // don't grow trees underwater

                // Check that the surface block is GRASS (not sand/water beach).
                // Surface is SAND if wy==H && wy<=SEA_LEVEL — already excluded above.
                // So if H > SEA_LEVEL the surface is GRASS.

                // Trunk voxels: from H+1 to H+trunk_height (inclusive).
                int trunk_base_wy = H + 1;
                int trunk_top_wy  = H + td.trunk_height;
                // Canopy is centred at trunk_top_wy, extends ±CANOPY_RADIUS_Y.
                int canopy_wy_max = trunk_top_wy + CANOPY_RADIUS_Y;

                // Quick y-range rejection: does any part of this tree overlap chunk?
                if (canopy_wy_max < wy_min || trunk_base_wy > wy_max) continue;

                // Trunk: place oak/birch log blocks.
                for (int wy = trunk_base_wy; wy <= trunk_top_wy; ++wy) {
                    if (wy < wy_min || wy > wy_max) continue;
                    // World x/z of trunk matches root.
                    if (td.root_wx < wx_min || td.root_wx > wx_max) continue;
                    if (td.root_wz < wz_min || td.root_wz > wz_max) continue;
                    int lx = td.root_wx - wx_min;
                    int ly = wy - wy_min;
                    int lz = td.root_wz - wz_min;
                    // Don't overwrite solid terrain blocks with logs
                    // (the trunk base sits on the grass surface; H+1 is air).
                    chunk.set(lx, ly, lz, td.log_id);
                }

                // Canopy: place leaf blocks in blob around trunk top.
                for (int dz = -CANOPY_RADIUS_XZ; dz <= CANOPY_RADIUS_XZ; ++dz) {
                    for (int dx = -CANOPY_RADIUS_XZ; dx <= CANOPY_RADIUS_XZ; ++dx) {
                        for (int dy = -CANOPY_RADIUS_Y; dy <= CANOPY_RADIUS_Y; ++dy) {
                            if (!in_canopy(dx, dy, dz)) continue;

                            std::int32_t wlx = td.root_wx + dx;
                            std::int32_t wly = trunk_top_wy + dy;
                            std::int32_t wlz = td.root_wz + dz;

                            if (wlx < wx_min || wlx > wx_max) continue;
                            if (wly < wy_min || wly > wy_max) continue;
                            if (wlz < wz_min || wlz > wz_max) continue;

                            int lx = wlx - wx_min;
                            int ly = wly - wy_min;
                            int lz = wlz - wz_min;
                            // Only place leaves in air — don't overwrite logs or terrain.
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
    // 2. PLANTS — tall grass, flowers, mushrooms
    //    These are single-block, placed directly on the grass surface of
    //    each column belonging to this chunk only (no margin needed).
    // -------------------------------------------------------------------
    {
        std::uint64_t pseed = fmix64(seed ^ PLANT_SEED_MIX);

        for (int lz = 0; lz < kChunkDim; ++lz) {
            for (int lx = 0; lx < kChunkDim; ++lx) {
                std::int32_t wx = wx_min + lx;
                std::int32_t wz = wz_min + lz;

                Biome bio = biome_at(wx, wz, seed);
                if (bio == Biome::Desert) continue;  // desert stays bare

                int H = surface_height(wx, wz, seed, bio);
                if (H <= SEA_LEVEL) continue;        // underwater column

                // The surface block world-y = H; plant goes at H+1.
                std::int32_t plant_wy = H + 1;
                if (plant_wy < wy_min || plant_wy > wy_max) continue;

                int ly_surface = H - wy_min;
                int ly_plant   = ly_surface + 1;
                if (ly_surface < 0 || ly_surface >= kChunkDim) continue;
                if (ly_plant   < 0 || ly_plant   >= kChunkDim) continue;

                // The spot must be AIR (a tree trunk or canopy may already occupy it).
                if (chunk.get(lx, ly_plant, lz) != AIR) continue;
                // The surface block must be GRASS.
                if (chunk.get(lx, ly_surface, lz) != GRASS) continue;

                // Plant scatter hash.
                std::uint64_t ph = hash2(wx, wz, pseed);
                // Use different bit ranges for independence.
                std::uint64_t roll = ph & 0xFFu;  // 0..255

                // ~35% probability of any plant (distributed among types).
                // roll 0..14  => tall grass  (~5.9%)
                // roll 15..29 => tall grass  (total ~11.8% tall grass)
                // roll 30..89 => tall grass  (total tall grass ~35%)
                // Use explicit thresholds:
                //   0..88  (89/256 ≈ 34.8%) tall grass
                //   89..100 (12/256 ≈ 4.7%) flower_red
                //   101..112 (12/256 ≈ 4.7%) flower_yellow
                //   113..117 (5/256  ≈ 2.0%) mushroom
                //   118..255 nothing
                BlockId plant = AIR;
                if      (roll < 89u)  plant = TALL_GRASS;
                else if (roll < 101u) plant = FLOWER_RED;
                else if (roll < 113u) plant = FLOWER_YELLOW;
                else if (roll < 118u) plant = MUSHROOM;

                if (plant != AIR) {
                    chunk.set(lx, ly_plant, lz, plant);
                }
            }
        }
    }
}

void TerrainGen::seed(std::uint64_t s) {
    seed_ = s;
}

void TerrainGen::generate(ChunkCoord c, IChunk& chunk) {
    // For each horizontal column in this chunk
    for (int lz = 0; lz < kChunkDim; ++lz) {
        for (int lx = 0; lx < kChunkDim; ++lx) {
            std::int32_t wx = c.x * kChunkDim + lx;
            std::int32_t wz = c.z * kChunkDim + lz;

            Biome biome = biome_at(wx, wz, seed_);
            int H = surface_height(wx, wz, seed_, biome);

            BlockId surface_block = GRASS;
            BlockId fill_block    = DIRT;
            if (biome == Biome::Desert) {
                surface_block = SAND;
                fill_block    = SAND;
            }

            for (int ly = 0; ly < kChunkDim; ++ly) {
                std::int32_t wy = c.y * kChunkDim + ly;

                BlockId b;
                if (wy > H) {
                    if (wy <= SEA_LEVEL) {
                        b = WATER;
                    } else {
                        b = AIR;
                    }
                } else if (wy == H) {
                    if (wy <= SEA_LEVEL && biome != Biome::Desert) {
                        b = SAND;
                    } else {
                        b = surface_block;
                    }
                } else if (wy >= H - 3) {
                    b = fill_block;
                } else {
                    b = STONE;
                }

                // Cave carving
                if (b != AIR && b != WATER && wy < H - 2 && wy > kColumnMinY + 4) {
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
    // Cast away const for generate (we mutate a local temp, not this).
    const_cast<TerrainGen*>(this)->generate(c, tmp);

    // FNV-1a 64-bit over all block ids in voxel order.
    constexpr std::uint64_t FNV_OFFSET = 14695981039346656037ull;
    constexpr std::uint64_t FNV_PRIME  = 1099511628211ull;

    std::uint64_t h = FNV_OFFSET;
    for (int lz = 0; lz < kChunkDim; ++lz) {
        for (int ly = 0; ly < kChunkDim; ++ly) {
            for (int lx = 0; lx < kChunkDim; ++lx) {
                BlockId b = tmp.get(lx, ly, lz);
                // Feed both bytes of the uint16_t.
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
