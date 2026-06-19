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
// ============================================================================
#include "blockcore/worldgen.hpp"
#include "blockcore/chunk.hpp"

#include <cmath>
#include <cstdint>

namespace bf {

// ---------------------------------------------------------------------------
// Block id constants
// ---------------------------------------------------------------------------
static constexpr BlockId AIR   = 0;
static constexpr BlockId GRASS = 1;
static constexpr BlockId DIRT  = 2;
static constexpr BlockId STONE = 3;
static constexpr BlockId SAND  = 6;
static constexpr BlockId WATER = 9;

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
// TerrainGen implementation
// ---------------------------------------------------------------------------

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
