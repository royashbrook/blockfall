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
#![allow(clippy::too_many_arguments)]
#![allow(clippy::needless_range_loop)]

// ---------------------------------------------------------------------------
// Inlined shared types (swap for bfcore::types on integration)
// ---------------------------------------------------------------------------
pub type BlockId = u16;

pub const K_CHUNK_DIM: i32 = 16; // bfcore::types::CHUNK_DIM
pub const K_COLUMN_MIN_Y: i32 = -512; // contract/blockcore_interfaces.hpp kColumnMinY

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
        DenseChunk { blocks: vec![fill; n] }
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
// 2D value noise: bilinearly interpolated hash lattice
// ---------------------------------------------------------------------------
fn value_noise2(fx: f32, fz: f32, seed: u64) -> f32 {
    let x0 = ifloor(fx);
    let z0 = ifloor(fz);
    let x1 = x0 + 1;
    let z1 = z0 + 1;

    let tx = smoothstep(fx - x0 as f32);
    let tz = smoothstep(fz - z0 as f32);

    let v00 = h2f(hash2(x0, z0, seed));
    let v10 = h2f(hash2(x1, z0, seed));
    let v01 = h2f(hash2(x0, z1, seed));
    let v11 = h2f(hash2(x1, z1, seed));

    let top = v00 + tx * (v10 - v00);
    let bot = v01 + tx * (v11 - v01);
    top + tz * (bot - top)
}

// 3D value noise: trilinearly interpolated
fn value_noise3(fx: f32, fy: f32, fz: f32, seed: u64) -> f32 {
    let x0 = ifloor(fx);
    let x1 = x0 + 1;
    let y0 = ifloor(fy);
    let y1 = y0 + 1;
    let z0 = ifloor(fz);
    let z1 = z0 + 1;

    let tx = smoothstep(fx - x0 as f32);
    let ty = smoothstep(fy - y0 as f32);
    let tz = smoothstep(fz - z0 as f32);

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
// Fractal Brownian Motion (fBm) — 2D
// ---------------------------------------------------------------------------
fn fbm2(wx: f32, wz: f32, seed: u64, octaves: i32, base_freq: f32, lacunarity: f32, persistence: f32) -> f32 {
    let mut val = 0.0f32;
    let mut amp = 1.0f32;
    let mut freq = base_freq;
    let mut max_val = 0.0f32;

    for o in 0..octaves {
        let oseed = fmix64(seed ^ (o as u64).wrapping_mul(0xABCDEF01234567));
        val += amp * value_noise2(wx * freq, wz * freq, oseed);
        max_val += amp;
        amp *= persistence;
        freq *= lacunarity;
    }
    val / max_val
}

// 3D fBm for caves.
fn fbm3(wx: f32, wy: f32, wz: f32, seed: u64, octaves: i32, base_freq: f32) -> f32 {
    let mut val = 0.0f32;
    let mut amp = 1.0f32;
    let mut freq = base_freq;
    let mut max_val = 0.0f32;
    let lacunarity = 2.0f32;
    let persistence = 0.5f32;

    for o in 0..octaves {
        let oseed = fmix64(seed ^ ((o + 7) as u64).wrapping_mul(0xFEDCBA9876543211));
        val += amp * value_noise3(wx * freq, wy * freq, wz * freq, oseed);
        max_val += amp;
        amp *= persistence;
        freq *= lacunarity;
    }
    val / max_val
}

// ---------------------------------------------------------------------------
// Cave entrance system (#11 / #37)
// ---------------------------------------------------------------------------
const ENTRANCE_CELL_SIZE: i32 = 24;
const ENTRANCE_SEED_MIX: u64 = 0xCA4E5EE7E57A4CE5;
const ENTRANCE_PROB_THRESH: u64 = 115;

const ENTR_POTHOLE: i32 = 0;
const ENTR_SINKHOLE: i32 = 1;
const ENTR_RAVINE: i32 = 2;

const ENTRANCE_FLOOR_MIN: i32 = 12;
const ENTRANCE_FLOOR_MAX: i32 = 18;
const SINKHOLE_R_MIN: i32 = 3;
const SINKHOLE_R_MAX: i32 = 5;
const RAVINE_HALF_W: i32 = 1;
const RAVINE_LEN_MIN: i32 = 8;
const RAVINE_LEN_MAX: i32 = 14;

const ENTRANCE_MAX_REACH: i32 = if SINKHOLE_R_MAX > (RAVINE_LEN_MAX / 2 + RAVINE_HALF_W) {
    SINKHOLE_R_MAX
} else {
    RAVINE_LEN_MAX / 2 + RAVINE_HALF_W
};

#[derive(Clone, Copy)]
struct EntranceDesc {
    wx: i32,
    wz: i32,
    shape: i32,
    floor: i32,
    radius: i32,
    half_len: i32,
    ravine_x: bool,
    present: bool,
}

#[inline]
fn entrance_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

fn entrance_for_cell(ecx: i32, ecz: i32, seed: u64) -> EntranceDesc {
    let eseed = fmix64(seed ^ ENTRANCE_SEED_MIX);
    let h = hash2(ecx, ecz, eseed);

    if (h & 0xFF) >= ENTRANCE_PROB_THRESH {
        return EntranceDesc { wx: 0, wz: 0, shape: 0, floor: 0, radius: 0, half_len: 0, ravine_x: false, present: false };
    }

    let h2 = fmix64(h ^ 0xE57A4CE5CA4EF00D);

    let mut span = ENTRANCE_CELL_SIZE - 2 * ENTRANCE_MAX_REACH;
    if span < 1 {
        span = 1;
    }
    let off_x = ENTRANCE_MAX_REACH + ((h2 >> 0) % (span as u64)) as i32;
    let off_z = ENTRANCE_MAX_REACH + ((h2 >> 16) % (span as u64)) as i32;

    let shape_roll = (h2 >> 32) & 0xFF;
    let shape = if shape_roll < 102 {
        ENTR_SINKHOLE
    } else if shape_roll < 191 {
        ENTR_RAVINE
    } else {
        ENTR_POTHOLE
    };

    let floor = ENTRANCE_FLOOR_MIN + ((h2 >> 40) % ((ENTRANCE_FLOOR_MAX - ENTRANCE_FLOOR_MIN + 1) as u64)) as i32;
    let radius = SINKHOLE_R_MIN + ((h2 >> 44) % ((SINKHOLE_R_MAX - SINKHOLE_R_MIN + 1) as u64)) as i32;
    let half_len = (RAVINE_LEN_MIN + ((h2 >> 48) % ((RAVINE_LEN_MAX - RAVINE_LEN_MIN + 1) as u64)) as i32) / 2;
    let ravine_x = ((h2 >> 52) & 1) != 0;

    EntranceDesc {
        wx: ecx * ENTRANCE_CELL_SIZE + off_x,
        wz: ecz * ENTRANCE_CELL_SIZE + off_z,
        shape,
        floor,
        radius,
        half_len,
        ravine_x,
        present: true,
    }
}

fn entrance_depth_in(ed: &EntranceDesc, wx: i32, wz: i32) -> i32 {
    let dx = wx - ed.wx;
    let dz = wz - ed.wz;
    match ed.shape {
        x if x == ENTR_SINKHOLE => {
            let r2 = (dx * dx + dz * dz) as i32;
            let rad = ed.radius;
            if r2 > rad * rad {
                return 0;
            }
            let dist = (r2 as f64).sqrt();
            let t = dist / (rad as f64);
            let mut depth = ((ed.floor as f64) * (1.0 - 0.55 * t)) as i32;
            if depth < 4 {
                depth = 4;
            }
            depth
        }
        x if x == ENTR_RAVINE => {
            let along = if ed.ravine_x { dx } else { dz };
            let across = if ed.ravine_x { dz } else { dx };
            if along < -ed.half_len || along > ed.half_len {
                return 0;
            }
            let aa = if across < 0 { -across } else { across };
            let half_w = RAVINE_HALF_W + 5;
            if aa > half_w {
                return 0;
            }
            let cap = if ed.floor < 9 { ed.floor } else { 9 };
            let mut depth = (cap * (half_w - aa)) / half_w;
            let a = if along < 0 { -along } else { along };
            depth -= a / 6;
            let jh = hash2(wx, wz, 0x9E3779B97F4A7C15);
            depth += (jh % 3) as i32 - 1;
            if depth < 1 {
                return 0;
            }
            depth
        }
        _ => {
            // ENTR_POTHOLE
            let r2 = (dx * dx + dz * dz) as i32;
            if r2 > 1 {
                return 0;
            }
            let pf = if ed.floor < 6 { ed.floor } else { 6 };
            if r2 == 0 {
                return pf;
            }
            pf - 2
        }
    }
}

fn cave_entrance_depth(wx: i32, wz: i32, seed: u64) -> i32 {
    let ecx = entrance_floordiv(wx, ENTRANCE_CELL_SIZE);
    let ecz = entrance_floordiv(wz, ENTRANCE_CELL_SIZE);
    let mut best = 0;
    for dce in -1..=1 {
        for dcf in -1..=1 {
            let ed = entrance_for_cell(ecx + dce, ecz + dcf, seed);
            if !ed.present {
                continue;
            }
            let d = entrance_depth_in(&ed, wx, wz);
            if d > best {
                best = d;
            }
        }
    }
    best
}

fn is_cave_entrance(wx: i32, wz: i32, seed: u64) -> bool {
    cave_entrance_depth(wx, wz, seed) > 0
}

// ---------------------------------------------------------------------------
// Ocean depth (#12) — always 0 (artificial basin carve disabled, seam safety)
// ---------------------------------------------------------------------------
fn ocean_basin_extra(_wx: i32, _wz: i32, _h: i32, _seed: u64) -> i32 {
    0
}

// ---------------------------------------------------------------------------
// Biome definitions
// ---------------------------------------------------------------------------
const NUM_BIOMES: usize = 7;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Biome {
    Plains = 0,
    Forest = 1,
    Mountains = 2,
    Desert = 3,
    Snowy = 4,
    Swamp = 5,
    Beach = 6,
}

impl Biome {
    #[inline]
    fn from_index(i: i32) -> Biome {
        match i {
            0 => Biome::Plains,
            1 => Biome::Forest,
            2 => Biome::Mountains,
            3 => Biome::Desert,
            4 => Biome::Snowy,
            5 => Biome::Swamp,
            _ => Biome::Beach,
        }
    }
}

struct BiomeParams {
    base_y: f32,
    amp: f32,
    freq: f32,
    octaves: i32,
    persistence: f32,
}

struct BiomeCentre {
    temp: f32,
    moist: f32,
    radius_t: f32,
    radius_m: f32,
}

const BIOME_PARAMS: [BiomeParams; NUM_BIOMES] = [
    BiomeParams { base_y: 8.0, amp: 2.0, freq: 1.0 / 128.0, octaves: 2, persistence: 0.40 }, // Plains
    BiomeParams { base_y: 10.0, amp: 18.0, freq: 1.0 / 40.0, octaves: 4, persistence: 0.55 }, // Forest
    BiomeParams { base_y: 28.0, amp: 56.0, freq: 1.0 / 40.0, octaves: 5, persistence: 0.62 }, // Mountains
    BiomeParams { base_y: 7.0, amp: 9.0, freq: 1.0 / 64.0, octaves: 3, persistence: 0.45 }, // Desert
    BiomeParams { base_y: 8.0, amp: 14.0, freq: 1.0 / 48.0, octaves: 4, persistence: 0.50 }, // Snowy
    BiomeParams { base_y: 5.0, amp: 1.2, freq: 1.0 / 56.0, octaves: 3, persistence: 0.45 }, // Swamp
    BiomeParams { base_y: 6.5, amp: 1.0, freq: 1.0 / 96.0, octaves: 2, persistence: 0.40 }, // Beach
];

const BIOME_CENTRES: [BiomeCentre; NUM_BIOMES] = [
    BiomeCentre { temp: 0.50, moist: 0.50, radius_t: 0.24, radius_m: 0.24 }, // Plains
    BiomeCentre { temp: 0.58, moist: 0.78, radius_t: 0.20, radius_m: 0.18 }, // Forest
    BiomeCentre { temp: 0.20, moist: 0.35, radius_t: 0.27, radius_m: 0.32 }, // Mountains
    BiomeCentre { temp: 0.85, moist: 0.18, radius_t: 0.28, radius_m: 0.28 }, // Desert
    BiomeCentre { temp: 0.15, moist: 0.55, radius_t: 0.26, radius_m: 0.34 }, // Snowy
    BiomeCentre { temp: 0.45, moist: 0.92, radius_t: 0.34, radius_m: 0.26 }, // Swamp
    BiomeCentre { temp: 0.78, moist: 0.55, radius_t: 0.16, radius_m: 0.20 }, // Beach
];

// ---------------------------------------------------------------------------
// Regional elevation swell
// ---------------------------------------------------------------------------
const SWELL_AMP: f32 = 5.0;
const SWELL_FREQ: f32 = 1.0 / 512.0;
const SWELL_SEED_MIX: u64 = 0x5E11B1057E119A11;

fn regional_swell(fwx: f32, fwz: f32, seed: u64) -> f32 {
    let sseed = fmix64(seed ^ SWELL_SEED_MIX);
    let n = fbm2(fwx, fwz, sseed, 2, SWELL_FREQ, 2.0, 0.5);
    (n * 2.0 - 1.0) * SWELL_AMP
}

// ---------------------------------------------------------------------------
// Climate spread + sampling
// ---------------------------------------------------------------------------
fn climate_spread(v: f32) -> f32 {
    let c = (v - 0.5) * 2.0;
    let s = if c < 0.0 { -1.0 } else { 1.0 };
    let ac = if c < 0.0 { -c } else { c };
    let a = ac.sqrt() * 0.85 + ac * 0.15;
    0.5 + s * a * 0.5
}

fn sample_climate(wx: i32, wz: i32, seed: u64) -> (f32, f32) {
    let tseed = fmix64(seed ^ 0xB10E5EED00000001);
    let mseed = fmix64(seed ^ 0xB10E5EED00000002);
    let fwx = wx as f32;
    let fwz = wz as f32;
    const BIOME_NOISE_FREQ: f32 = 1.0 / 72.0;
    let temp = climate_spread(fbm2(fwx, fwz, tseed, 3, BIOME_NOISE_FREQ, 2.0, 0.5));
    let moist = climate_spread(fbm2(fwx, fwz, mseed, 3, BIOME_NOISE_FREQ, 2.0, 0.5));
    (temp, moist)
}

fn classify_climate(temp: f32, moist: f32) -> i32 {
    let mut best_i = 0i32;
    let mut best_d = 1e30f32;
    for i in 0..NUM_BIOMES {
        let bc = &BIOME_CENTRES[i];
        let dt = (temp - bc.temp) / bc.radius_t;
        let dm = (moist - bc.moist) / bc.radius_m;
        let d2 = dt * dt + dm * dm;
        if d2 < best_d {
            best_d = d2;
            best_i = i as i32;
        }
    }
    best_i
}

fn biome_weights(wx: i32, wz: i32, seed: u64) -> [f32; NUM_BIOMES] {
    let (temp, moist) = sample_climate(wx, wz, seed);

    let mut raw = [0.0f32; NUM_BIOMES];
    for i in 0..NUM_BIOMES {
        let bc = &BIOME_CENTRES[i];
        let dt = (temp - bc.temp) / bc.radius_t;
        let dm = (moist - bc.moist) / bc.radius_m;
        let d2 = dt * dt + dm * dm;
        let mut w = 1.0 - d2;
        if w < 0.0 {
            w = 0.0;
        }
        w = w * w;
        raw[i] = w;
    }

    let mut dom_idx = 0usize;
    for i in 1..NUM_BIOMES {
        if raw[i] > raw[dom_idx] {
            dom_idx = i;
        }
    }

    let mut weights = [0.0f32; NUM_BIOMES];
    let mut total2 = 0.0f32;
    for i in 0..NUM_BIOMES {
        let w0 = raw[i];
        let w = if i == dom_idx { w0 * w0 * w0 } else { w0 * w0 };
        weights[i] = w;
        total2 += w;
    }

    if total2 < 1e-6 {
        for i in 0..NUM_BIOMES {
            weights[i] = if i == 0 { 1.0 } else { 0.0 };
        }
    } else {
        let inv = 1.0 / total2;
        for i in 0..NUM_BIOMES {
            weights[i] *= inv;
        }
    }
    weights
}

// ---------------------------------------------------------------------------
// Voronoi biome map (#6)
// ---------------------------------------------------------------------------
const BIOME_CELL: i32 = 44;
const VORONOI_SEED_MIX: u64 = 0x901A0701B10E5EED;

#[inline]
fn voronoi_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

struct VoronoiCell {
    sx: f32,
    sz: f32,
    biome: i32,
}

fn voronoi_cell_compute(cx: i32, cz: i32, vseed: u64, seed: u64) -> VoronoiCell {
    let h = hash2(cx, cz, vseed);
    let jx = ((((h >> 0) & 0xFFFF) as f32) / 65535.0 - 0.5) * 0.66;
    let jz = ((((h >> 16) & 0xFFFF) as f32) / 65535.0 - 0.5) * 0.66;
    let sx = (cx as f32 + 0.5 + jx) * (BIOME_CELL as f32);
    let sz = (cz as f32 + 0.5 + jz) * (BIOME_CELL as f32);
    let (temp, moist) = sample_climate((sx + 0.5) as i32, (sz + 0.5) as i32, seed);
    VoronoiCell { sx, sz, biome: classify_climate(temp, moist) }
}

fn voronoi_biome(wx: i32, wz: i32, seed: u64) -> Biome {
    let vseed = fmix64(seed ^ VORONOI_SEED_MIX);
    let cx = voronoi_floordiv(wx, BIOME_CELL);
    let cz = voronoi_floordiv(wz, BIOME_CELL);

    let fwx = wx as f32;
    let fwz = wz as f32;

    let mut best_d2 = 1e30f32;
    let mut best_biome = 0i32;
    for dz in -1..=1 {
        for dx in -1..=1 {
            let vc = voronoi_cell_compute(cx + dx, cz + dz, vseed, seed);
            let ex = fwx - vc.sx;
            let ez = fwz - vc.sz;
            let d2 = ex * ex + ez * ez;
            if d2 < best_d2 {
                best_d2 = d2;
                best_biome = vc.biome;
            }
        }
    }
    Biome::from_index(best_biome)
}

// ---------------------------------------------------------------------------
// Blended surface height
// ---------------------------------------------------------------------------
const BIOME_SEED_OFFSETS: [u64; NUM_BIOMES] = [
    0x0000000000000001,
    0x1111111111111111,
    0x2222222222222222,
    0x3333333333333333,
    0x4444444444444444,
    0x5555555555555555,
    0x6666666666666666,
];

// Rivers
const RIVER_FREQ: f32 = 1.0 / 130.0;
const RIVER_HALFW: f32 = 0.040;
const RIVER_DEPTH: f32 = 9.0;
fn river_lower(fwx: f32, fwz: f32, seed: u64) -> f32 {
    let rseed = fmix64(seed ^ 0x515E12D32C0DE011);
    let n = fbm2(fwx, fwz, rseed, 2, RIVER_FREQ, 2.0, 0.5);
    let mut d = n - 0.5;
    if d < 0.0 {
        d = -d;
    }
    if d >= RIVER_HALFW {
        return 0.0;
    }
    let mut t = 1.0 - d / RIVER_HALFW;
    t = t * t * (3.0 - 2.0 * t);
    RIVER_DEPTH * t
}

// Continentalness
const CONTINENT_FREQ: f32 = 1.0 / 640.0;
const CONTINENT_AMP: f32 = 6.0;
fn continental_lift(fwx: f32, fwz: f32, seed: u64) -> f32 {
    let cseed = fmix64(seed ^ 0xC0117E17A15C0DE1);
    let c = fbm2(fwx, fwz, cseed, 2, CONTINENT_FREQ, 2.0, 0.5);
    let mut t = (c - 0.46) / 0.18;
    if t < 0.0 {
        t = 0.0;
    }
    if t > 1.0 {
        t = 1.0;
    }
    t * CONTINENT_AMP
}

fn surface_height_raw(wx: i32, wz: i32, seed: u64, weights: &[f32; NUM_BIOMES]) -> f32 {
    let fwx = wx as f32;
    let fwz = wz as f32;

    let swell = regional_swell(fwx, fwz, seed);

    let mut blended_h = 0.0f32;

    for i in 0..NUM_BIOMES {
        if weights[i] < 1e-4 {
            continue;
        }

        let p = &BIOME_PARAMS[i];
        let bseed = fmix64(seed ^ BIOME_SEED_OFFSETS[i]);

        let mut n = fbm2(fwx, fwz, bseed, p.octaves, p.freq, 2.0, p.persistence);

        if Biome::from_index(i as i32) == Biome::Desert {
            let ripple_seed = fmix64(seed ^ 0xDEA0D5A0D5A0D5A0);
            let ripple = value_noise2(fwx * (1.0 / 12.0), fwz * (1.0 / 12.0), ripple_seed);
            n += ripple * 2.0 / (p.amp * 2.0 + 0.001);
            if n > 1.0 {
                n = 1.0;
            }
        }

        let biome_is = Biome::from_index(i as i32);
        let biome_swell = if biome_is != Biome::Plains && biome_is != Biome::Swamp { swell } else { 0.0 };
        let h = p.base_y + (n * 2.0 - 1.0) * p.amp + biome_swell;
        blended_h += weights[i] * h;
    }

    let swamp_w = weights[Biome::Swamp as usize];
    blended_h += continental_lift(fwx, fwz, seed) * (1.0 - 0.6 * swamp_w);

    let desert_w = weights[Biome::Desert as usize];
    blended_h -= river_lower(fwx, fwz, seed) * (1.0 - desert_w);

    blended_h
}

fn surface_height_raw_at(wx: i32, wz: i32, seed: u64) -> f32 {
    let w = biome_weights(wx, wz, seed);
    surface_height_raw(wx, wz, seed, &w)
}

// ---------------------------------------------------------------------------
// Lipschitz-1 height limiter
// ---------------------------------------------------------------------------
const SEAM_ANCHOR_STEP: i32 = 12;
const SEAM_ANCHOR_RADIUS: i32 = 5;

#[inline]
fn seam_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

// Core cone evaluation given an anchor-fetch closure.
fn seam_cone_eval<F: Fn(i32, i32) -> f32>(wx: i32, wz: i32, fetch: F) -> i32 {
    let acx = seam_floordiv(wx, SEAM_ANCHOR_STEP);
    let acz = seam_floordiv(wz, SEAM_ANCHOR_STEP);

    let mut upper = 1e30f32;
    let mut lower = -1e30f32;

    for dz in -SEAM_ANCHOR_RADIUS..=SEAM_ANCHOR_RADIUS {
        for dx in -SEAM_ANCHOR_RADIUS..=SEAM_ANCHOR_RADIUS {
            let gx = acx + dx;
            let gz = acz + dz;
            let hraw = fetch(gx, gz);

            let ex = (wx - gx * SEAM_ANCHOR_STEP) as f32;
            let ez = (wz - gz * SEAM_ANCHOR_STEP) as f32;
            let dist = (ex * ex + ez * ez).sqrt();

            let up = hraw + dist;
            let lo = hraw - dist;
            if up < upper {
                upper = up;
            }
            if lo > lower {
                lower = lo;
            }
        }
    }
    (0.5 * (upper + lower)).floor() as i32
}

// Slow on-demand path: raw anchor height computed directly (the C++ memo is a
// pure cache, so this matches its result exactly).
fn surface_height(wx: i32, wz: i32, seed: u64) -> i32 {
    seam_cone_eval(wx, wz, |gx, gz| {
        surface_height_raw_at(gx * SEAM_ANCHOR_STEP, gz * SEAM_ANCHOR_STEP, seed)
    })
}

// ---------------------------------------------------------------------------
// Chunk-local anchor cache
// ---------------------------------------------------------------------------
struct SeamAnchorCache {
    gx0: i32,
    gz0: i32,
    nx: i32,
    nz: i32,
    h: Vec<f32>,
}

impl SeamAnchorCache {
    fn at(&self, gx: i32, gz: i32) -> f32 {
        let mut ix = gx - self.gx0;
        let mut iz = gz - self.gz0;
        if ix < 0 {
            ix = 0;
        } else if ix >= self.nx {
            ix = self.nx - 1;
        }
        if iz < 0 {
            iz = 0;
        } else if iz >= self.nz {
            iz = self.nz - 1;
        }
        self.h[(iz * self.nx + ix) as usize]
    }
}

fn build_anchor_cache(wx_min: i32, wz_min: i32, seed: u64) -> SeamAnchorCache {
    let wx_max = wx_min + K_CHUNK_DIM - 1;
    let wz_max = wz_min + K_CHUNK_DIM - 1;
    let gxlo = seam_floordiv(wx_min, SEAM_ANCHOR_STEP) - SEAM_ANCHOR_RADIUS;
    let gxhi = seam_floordiv(wx_max, SEAM_ANCHOR_STEP) + SEAM_ANCHOR_RADIUS;
    let gzlo = seam_floordiv(wz_min, SEAM_ANCHOR_STEP) - SEAM_ANCHOR_RADIUS;
    let gzhi = seam_floordiv(wz_max, SEAM_ANCHOR_STEP) + SEAM_ANCHOR_RADIUS;

    let nx = gxhi - gxlo + 1;
    let nz = gzhi - gzlo + 1;
    let mut h = vec![0.0f32; (nx * nz) as usize];
    for iz in 0..nz {
        for ix in 0..nx {
            h[(iz * nx + ix) as usize] = surface_height_raw_at((gxlo + ix) * SEAM_ANCHOR_STEP, (gzlo + iz) * SEAM_ANCHOR_STEP, seed);
        }
    }
    SeamAnchorCache { gx0: gxlo, gz0: gzlo, nx, nz, h }
}

fn surface_height_cached(wx: i32, wz: i32, cache: &SeamAnchorCache) -> i32 {
    seam_cone_eval(wx, wz, |gx, gz| cache.at(gx, gz))
}

// ---------------------------------------------------------------------------
// Per-chunk column cache
// ---------------------------------------------------------------------------
struct ChunkColumnCache {
    h: [i32; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
    dom: [Biome; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
    weights: [[f32; NUM_BIOMES]; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
}

impl ChunkColumnCache {
    #[inline]
    fn idx(lx: i32, lz: i32) -> usize {
        (lz * K_CHUNK_DIM + lx) as usize
    }
}

fn build_column_cache(wx_min: i32, wz_min: i32, seed: u64, anchor_cache: &SeamAnchorCache) -> ChunkColumnCache {
    let mut out = ChunkColumnCache {
        h: [0; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
        dom: [Biome::Plains; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
        weights: [[0.0; NUM_BIOMES]; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
    };
    for lz in 0..K_CHUNK_DIM {
        for lx in 0..K_CHUNK_DIM {
            let wx = wx_min + lx;
            let wz = wz_min + lz;
            let i = ChunkColumnCache::idx(lx, lz);
            out.weights[i] = biome_weights(wx, wz, seed);
            out.dom[i] = voronoi_biome(wx, wz, seed);
            out.h[i] = surface_height_cached(wx, wz, anchor_cache);
        }
    }
    out
}

// ===========================================================================
// (continued in part 2 below: trees, canopies, structures, deadwood, caves,
//  decorations, generate, public API)
// ===========================================================================
include!("worldgen_part2.rs");
