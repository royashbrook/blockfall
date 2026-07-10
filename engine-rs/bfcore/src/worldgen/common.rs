// ============================================================================
// Blockfall — Track C: deterministic procedural world generation
// Rust port of engine/src/worldgen.cpp (1:1 faithful).
//
// All noise and biome functions are pure functions of (x, y, z, seed).
// No mutable static state, no time(), no rand().
//
// This is a SELF-CONTAINED standalone crate: it inlines the small shared types
// (BlockId, ChunkCoord, a minimal IChunk sink, kChunkDim, kColumnMinY) so it
// compiles and tests on its own. When integrating, swap these for bfcore's
// equivalents (bfcore::types::{BlockId, ChunkCoord, CHUNK_DIM, ...}).
//
// Parity note: the C++ uses thread_local memo caches (AnchorMemo, VoronoiMemo)
// purely for performance. They are pure functions of their keys, so the cached
// value equals the freshly-computed value. The port computes those values
// directly (no caches), which yields identical results. The chunk hot path
// builds the SeamAnchorCache and ChunkColumnCache exactly as C++ does.
// ============================================================================

// ---------------------------------------------------------------------------
// Inlined shared types (swap for bfcore::types on integration)
// ---------------------------------------------------------------------------
pub type BlockId = u16;

pub const K_CHUNK_DIM: i32 = crate::types::CHUNK_DIM as i32;
pub const K_COLUMN_MIN_Y: i32 = -512; // contract/blockcore_interfaces.hpp kColumnMinY

// ---------------------------------------------------------------------------
// Looping world (#179, epic #173): the world is a TORUS in x/z with period
// WORLD_PERIOD blocks. Every pure function of a world column canonicalizes its
// x/z inputs (or its lattice cell indices) so that f(wx + WORLD_PERIOD) == f(wx)
// EXACTLY, byte for byte. The period is a power of two so wrapping is a bitmask
// and every noise/cell lattice can be made to close on itself: all noise base
// frequencies are expressed as an integer lattice period (cells per world
// revolution) and every cell size divides WORLD_PERIOD.
// ---------------------------------------------------------------------------
pub const WORLD_PERIOD: i32 = 32768; // 2^15 blocks around the torus (x and z)
pub const WORLD_PERIOD_CHUNKS: i32 = WORLD_PERIOD / K_CHUNK_DIM;

/// Canonicalize a world x/z coordinate into [0, WORLD_PERIOD). Bitmask: the
/// period is a power of two, so this is exact for negatives too.
#[inline]
pub const fn wrap_world(v: i32) -> i32 {
    v & (WORLD_PERIOD - 1)
}

/// Canonicalize a float world x/z coordinate into [0, WORLD_PERIOD).
#[inline]
fn wrap_world_f(v: f32) -> f32 {
    v.rem_euclid(WORLD_PERIOD as f32)
}

/// Canonicalize a lattice cell index into [0, count). Used to wrap the HASH
/// input of every cell system; cell geometry stays in the caller's frame so
/// placement math near the seam keeps working on raw (out-of-range) coords.
#[inline]
fn wrap_cell(c: i32, count: i32) -> i32 {
    // Fast path: canonical inputs are already in range (the hot generate()
    // path wraps its chunk up front), so skip the integer division.
    if c >= 0 && c < count {
        c
    } else {
        c.rem_euclid(count)
    }
}

pub use crate::types::ChunkCoord;

/// Minimal chunk sink. A real bfcore PaletteChunk satisfies the same get/set
/// contract (local coords 0..16). `IChunk` in C++; here a trait so tests can use
/// a simple dense-array chunk.
pub trait Chunk {
    fn get(&self, lx: i32, ly: i32, lz: i32) -> BlockId;
    fn set(&mut self, lx: i32, ly: i32, lz: i32, b: BlockId);
}

/// Simple dense chunk used by tests and the dumper. Mirrors PaletteChunk's
/// get/set semantics for the worldgen's purposes (init fill value, in-bounds
/// local coords). Layout is irrelevant to parity since worldgen only uses
/// get/set; content_hash iterates in (lz,ly,lx) order explicitly.
pub struct DenseChunk {
    pub blocks: Vec<BlockId>,
}

impl DenseChunk {
    pub fn new(fill: BlockId) -> Self {
        let n = (K_CHUNK_DIM * K_CHUNK_DIM * K_CHUNK_DIM) as usize;
        DenseChunk {
            blocks: vec![fill; n],
        }
    }
    #[inline]
    fn idx(lx: i32, ly: i32, lz: i32) -> usize {
        // (lx,ly,lz) -> flat. Order is internal-only; worldgen never relies on it.
        ((lz * K_CHUNK_DIM + ly) * K_CHUNK_DIM + lx) as usize
    }
    pub fn is_uniform(&self) -> bool {
        let first = self.blocks[0];
        self.blocks.iter().all(|&b| b == first)
    }
}

impl Chunk for DenseChunk {
    #[inline]
    fn get(&self, lx: i32, ly: i32, lz: i32) -> BlockId {
        self.blocks[Self::idx(lx, ly, lz)]
    }
    #[inline]
    fn set(&mut self, lx: i32, ly: i32, lz: i32, b: BlockId) {
        self.blocks[Self::idx(lx, ly, lz)] = b;
    }
}

// ---------------------------------------------------------------------------
// Block id constants (verified against content/blocks/*.json)
// ---------------------------------------------------------------------------
const AIR: BlockId = 0;
const GRASS: BlockId = 1;
const DIRT: BlockId = 2;
const STONE: BlockId = 3;
const OAK_PLANKS: BlockId = 4;
const OAK_LEAVES: BlockId = 5;
const SAND: BlockId = 6;
const GLOW_BLOCK: BlockId = 7;
const STONE_BRICK: BlockId = 8;
const WATER: BlockId = 9;
const COBBLESTONE: BlockId = 10;
const GRAVEL: BlockId = 11;
const SNOW_LAYER: BlockId = 12;
const ICE: BlockId = 13;
const CLAY: BlockId = 14;
const COAL_ORE: BlockId = 17;
const COPPER_ORE: BlockId = 18;
const IRON_ORE: BlockId = 19;
const CRYSTAL_ORE: BlockId = 20;
const OAK_LOG: BlockId = 21;
const WOOD_BEAM: BlockId = 51; // cube-rendered timber for buildings
const BIRCH_LOG: BlockId = 22;
const BIRCH_PLANKS: BlockId = 23;
const GLASS_PANE: BlockId = 25;
const BIRCH_LEAVES: BlockId = 27;
const PINE_LEAVES: BlockId = 48; // #62 conifer needles
const PINE_LOG: BlockId = 49; // #62 conifer trunk
const WOOL_BLOCK: BlockId = 28;
const MOSSY_STONE: BlockId = 29;
const CHEST: BlockId = 31;
const TORCH: BlockId = 32;
const OAK_DOOR: BlockId = 33;
const BED: BlockId = 52; // simple furniture bed (wool top, log frame); see content/blocks/functional.json
const CRYSTAL_LAMP: BlockId = 35;
const FLOWER_RED: BlockId = 36;
const FLOWER_YELLOW: BlockId = 37;
const TALL_GRASS: BlockId = 38;
const MUSHROOM: BlockId = 39;
const COLOR_CRYSTAL: BlockId = 40; // glowing cave crystal
const PEBBLE: BlockId = 41;
const BERRY_BUSH: BlockId = 42;
const REED: BlockId = 43;
const CACTUS_PLANT: BlockId = 44;
const SEASHELL: BlockId = 45;
const LILY_PAD: BlockId = 46;
const FALLEN_STICK: BlockId = 47;

const SEA_LEVEL: i32 = 6;
const SNOW_LINE: i32 = 32;
const ROCK_LINE: i32 = 16;
const CAVE_THRESH: f32 = 0.65;
const CAVE_SURFACE_MARGIN: i32 = 6;
// #179: cave fbm3 base lattice period (2048 cells = the old 1/16 frequency).
const CAVE_NOISE_PERIOD: i32 = 2048;

// ---------------------------------------------------------------------------
// Hash primitives — Wang/murmur-inspired 64-bit mixes
// ---------------------------------------------------------------------------
#[inline]
const fn fmix64(mut h: u64) -> u64 {
    h ^= h >> 33;
    h = h.wrapping_mul(0xFF51AFD7ED558CCD);
    h ^= h >> 33;
    h = h.wrapping_mul(0xC4CEB9FE1A85EC53);
    h ^= h >> 33;
    h
}

#[inline]
fn hash2(ix: i32, iz: i32, seed: u64) -> u64 {
    let mut h = seed;
    h ^= fmix64((ix as u32) as u64);
    h ^= fmix64(((iz as u32) as u64).wrapping_mul(0x9E3779B97F4A7C15));
    fmix64(h)
}

#[inline]
fn hash3(ix: i32, iy: i32, iz: i32, seed: u64) -> u64 {
    let mut h = seed;
    h ^= fmix64((ix as u32) as u64);
    h ^= fmix64(((iy as u32) as u64).wrapping_mul(0x517CC1B727220A95));
    h ^= fmix64(((iz as u32) as u64).wrapping_mul(0x9E3779B97F4A7C15));
    fmix64(h)
}

#[inline]
fn h2f(h: u64) -> f32 {
    // static_cast<float>(h >> 40u) / static_cast<float>(1u << 24u)
    (h >> 40) as f32 / ((1u32 << 24) as f32)
}

// ---------------------------------------------------------------------------
// Smoothstep
// ---------------------------------------------------------------------------
#[inline]
fn smoothstep(t: f32) -> f32 {
    t * t * (3.0 - 2.0 * t)
}

#[inline]
fn ifloor(v: f32) -> i32 {
    let i = v as i32; // truncates toward zero, matching static_cast<int>
    if v < i as f32 {
        i - 1
    } else {
        i
    }
}

// ---------------------------------------------------------------------------
// 2D value noise: bilinearly interpolated hash lattice.
//
// `period` is the number of lattice cells across one world revolution: the
// integer lattice index is wrapped mod `period` before hashing, so the noise
// closes on itself at exactly WORLD_PERIOD blocks. Callers must sample with
// fx = wx * (period / WORLD_PERIOD) so lattice space and world space agree.
// ---------------------------------------------------------------------------
fn value_noise2(fx: f32, fz: f32, seed: u64, period: i32) -> f32 {
    let x0 = ifloor(fx);
    let z0 = ifloor(fz);
    let x1 = x0 + 1;
    let z1 = z0 + 1;

    let tx = smoothstep(fx - x0 as f32);
    let tz = smoothstep(fz - z0 as f32);

    let x0w = wrap_cell(x0, period);
    let x1w = wrap_cell(x1, period);
    let z0w = wrap_cell(z0, period);
    let z1w = wrap_cell(z1, period);

    let v00 = h2f(hash2(x0w, z0w, seed));
    let v10 = h2f(hash2(x1w, z0w, seed));
    let v01 = h2f(hash2(x0w, z1w, seed));
    let v11 = h2f(hash2(x1w, z1w, seed));

    let top = v00 + tx * (v10 - v00);
    let bot = v01 + tx * (v11 - v01);
    top + tz * (bot - top)
}

// 3D value noise: trilinearly interpolated. x/z lattice wraps at `period`
// (torus axes); y is unbounded and never wraps.
fn value_noise3(fx: f32, fy: f32, fz: f32, seed: u64, period: i32) -> f32 {
    let x0 = ifloor(fx);
    let x1 = x0 + 1;
    let y0 = ifloor(fy);
    let y1 = y0 + 1;
    let z0 = ifloor(fz);
    let z1 = z0 + 1;

    let tx = smoothstep(fx - x0 as f32);
    let ty = smoothstep(fy - y0 as f32);
    let tz = smoothstep(fz - z0 as f32);

    let x0 = wrap_cell(x0, period);
    let x1 = wrap_cell(x1, period);
    let z0 = wrap_cell(z0, period);
    let z1 = wrap_cell(z1, period);

    let c000 = h2f(hash3(x0, y0, z0, seed));
    let c100 = h2f(hash3(x1, y0, z0, seed));
    let c010 = h2f(hash3(x0, y1, z0, seed));
    let c110 = h2f(hash3(x1, y1, z0, seed));
    let c001 = h2f(hash3(x0, y0, z1, seed));
    let c101 = h2f(hash3(x1, y0, z1, seed));
    let c011 = h2f(hash3(x0, y1, z1, seed));
    let c111 = h2f(hash3(x1, y1, z1, seed));

    let lerp = |a: f32, b: f32, t: f32| a + t * (b - a);

    let x00 = lerp(c000, c100, tx);
    let x10 = lerp(c010, c110, tx);
    let x01 = lerp(c001, c101, tx);
    let x11 = lerp(c011, c111, tx);

    let y0v = lerp(x00, x10, ty);
    let y1v = lerp(x01, x11, ty);
    lerp(y0v, y1v, tz)
}

// ---------------------------------------------------------------------------
// Fractal Brownian Motion (fBm) — 2D.
//
// Base frequency is expressed as an integer LATTICE PERIOD (cells per world
// revolution): freq = base_period / WORLD_PERIOD. Lacunarity is fixed at 2.0
// so every octave's period stays an integer (period doubles per octave) and
// the whole fractal closes on the torus exactly.
// ---------------------------------------------------------------------------
fn fbm2(wx: f32, wz: f32, seed: u64, octaves: i32, base_period: i32, persistence: f32) -> f32 {
    let mut val = 0.0f32;
    let mut amp = 1.0f32;
    let mut period = base_period;
    let mut freq = base_period as f32 / WORLD_PERIOD as f32;
    let mut max_val = 0.0f32;

    for o in 0..octaves {
        let oseed = fmix64(seed ^ (o as u64).wrapping_mul(0xABCDEF01234567));
        val += amp * value_noise2(wx * freq, wz * freq, oseed, period);
        max_val += amp;
        amp *= persistence;
        freq *= 2.0;
        period *= 2;
    }
    val / max_val
}

// 3D fBm for caves. Same integer-period convention on the x/z torus axes.
fn fbm3(wx: f32, wy: f32, wz: f32, seed: u64, octaves: i32, base_period: i32) -> f32 {
    let mut val = 0.0f32;
    let mut amp = 1.0f32;
    let mut period = base_period;
    let mut freq = base_period as f32 / WORLD_PERIOD as f32;
    let mut max_val = 0.0f32;
    let persistence = 0.5f32;

    for o in 0..octaves {
        let oseed = fmix64(seed ^ ((o + 7) as u64).wrapping_mul(0xFEDCBA9876543211));
        val += amp * value_noise3(wx * freq, wy * freq, wz * freq, oseed, period);
        max_val += amp;
        amp *= persistence;
        freq *= 2.0;
        period *= 2;
    }
    val / max_val
}
