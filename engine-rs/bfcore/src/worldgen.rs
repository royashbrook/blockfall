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

// ---------------------------------------------------------------------------
// Cave entrance system (#11 / #37)
// ---------------------------------------------------------------------------
// #179: 24 -> 32 so the cell grid divides WORLD_PERIOD (1024 cells across the
// torus). Probability rescaled 115 -> 204 to keep entrances-per-area unchanged
// (115 * 32^2 / 24^2 ~= 204).
const ENTRANCE_CELL_SIZE: i32 = 32;
const ENTRANCE_CELL_COUNT: i32 = WORLD_PERIOD / ENTRANCE_CELL_SIZE; // 1024
const ENTRANCE_SEED_MIX: u64 = 0xCA4E5EE7E57A4CE5;
const ENTRANCE_PROB_THRESH: u64 = 204;

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
    // Hash on the canonical cell so the grid is periodic; geometry (wx/wz below)
    // stays in the caller's frame so seam-adjacent queries place correctly.
    let h = hash2(
        wrap_cell(ecx, ENTRANCE_CELL_COUNT),
        wrap_cell(ecz, ENTRANCE_CELL_COUNT),
        eseed,
    );

    if (h & 0xFF) >= ENTRANCE_PROB_THRESH {
        return EntranceDesc {
            wx: 0,
            wz: 0,
            shape: 0,
            floor: 0,
            radius: 0,
            half_len: 0,
            ravine_x: false,
            present: false,
        };
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

    let floor = ENTRANCE_FLOOR_MIN
        + ((h2 >> 40) % ((ENTRANCE_FLOOR_MAX - ENTRANCE_FLOOR_MIN + 1) as u64)) as i32;
    let radius =
        SINKHOLE_R_MIN + ((h2 >> 44) % ((SINKHOLE_R_MAX - SINKHOLE_R_MIN + 1) as u64)) as i32;
    let half_len =
        (RAVINE_LEN_MIN + ((h2 >> 48) % ((RAVINE_LEN_MAX - RAVINE_LEN_MIN + 1) as u64)) as i32) / 2;
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
            let jh = hash2(wrap_world(wx), wrap_world(wz), 0x9E3779B97F4A7C15);
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
    // #179: base lattice period (cells per world revolution) instead of a raw
    // frequency, so each biome's detail noise closes on the torus. The
    // effective frequency is period / WORLD_PERIOD; values were picked as the
    // nearest integer period to the old frequency (819/32768 ~= 1/40.01 etc),
    // so the look is unchanged to within a tenth of a percent.
    period: i32,
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
    BiomeParams {
        base_y: 8.0,
        amp: 2.0,
        period: 256,
        octaves: 2,
        persistence: 0.40,
    }, // Plains (1/128)
    BiomeParams {
        base_y: 10.0,
        amp: 18.0,
        period: 819,
        octaves: 4,
        persistence: 0.55,
    }, // Forest (~1/40)
    BiomeParams {
        base_y: 28.0,
        amp: 56.0,
        period: 819,
        octaves: 5,
        persistence: 0.62,
    }, // Mountains (~1/40)
    BiomeParams {
        base_y: 7.0,
        amp: 9.0,
        period: 512,
        octaves: 3,
        persistence: 0.45,
    }, // Desert (1/64)
    BiomeParams {
        base_y: 8.0,
        amp: 14.0,
        period: 683,
        octaves: 4,
        persistence: 0.50,
    }, // Snowy (~1/48)
    BiomeParams {
        base_y: 5.0,
        amp: 1.2,
        period: 585,
        octaves: 3,
        persistence: 0.45,
    }, // Swamp (~1/56)
    BiomeParams {
        base_y: 6.5,
        amp: 1.0,
        period: 341,
        octaves: 2,
        persistence: 0.40,
    }, // Beach (~1/96)
];

const BIOME_CENTRES: [BiomeCentre; NUM_BIOMES] = [
    BiomeCentre {
        temp: 0.50,
        moist: 0.50,
        radius_t: 0.24,
        radius_m: 0.24,
    }, // Plains
    BiomeCentre {
        temp: 0.58,
        moist: 0.78,
        radius_t: 0.20,
        radius_m: 0.18,
    }, // Forest
    BiomeCentre {
        temp: 0.20,
        moist: 0.35,
        radius_t: 0.27,
        radius_m: 0.32,
    }, // Mountains
    BiomeCentre {
        temp: 0.85,
        moist: 0.18,
        radius_t: 0.28,
        radius_m: 0.28,
    }, // Desert
    BiomeCentre {
        temp: 0.15,
        moist: 0.55,
        radius_t: 0.26,
        radius_m: 0.34,
    }, // Snowy
    BiomeCentre {
        temp: 0.45,
        moist: 0.92,
        radius_t: 0.34,
        radius_m: 0.26,
    }, // Swamp
    BiomeCentre {
        temp: 0.78,
        moist: 0.55,
        radius_t: 0.16,
        radius_m: 0.20,
    }, // Beach
];

// ---------------------------------------------------------------------------
// Regional elevation swell
// ---------------------------------------------------------------------------
const SWELL_AMP: f32 = 5.0;
const SWELL_PERIOD: i32 = 64; // 1/512, unchanged (512 divides WORLD_PERIOD)
const SWELL_SEED_MIX: u64 = 0x5E11B1057E119A11;

fn regional_swell(fwx: f32, fwz: f32, seed: u64) -> f32 {
    let sseed = fmix64(seed ^ SWELL_SEED_MIX);
    let n = fbm2(fwx, fwz, sseed, 2, SWELL_PERIOD, 0.5);
    (n * 2.0 - 1.0) * SWELL_AMP
}

// ---------------------------------------------------------------------------
// Biome domain warp (#: natural, eroded biome borders)
//
// Both the discrete Voronoi biome and the continuous climate field that drives
// height blending are functions of a world column (wx, wz). Sampled on the bare
// grid they produce straight, axis-aligned borders (Voronoi cell edges and grid
// aligned climate contours) that read from a mountaintop as someone having
// "cleared the land" in big rectangles.
//
// The fix is a domain warp: before a column is turned into a biome, we offset its
// sample point by a low-frequency fBm vector. Cell boundaries and climate contours
// then follow that wavy offset and come out organically eroded (irregular, finger
// like) instead of straight. The warp is a pure, seeded function of (wx, wz), so:
//   * it is deterministic (no global state, content_hash stays stable),
//   * it is single valued per column (every query of the biome at a column sees
//     the same offset, so terrain-height blending, the discrete biome, and
//     structure / tree / beach placement all agree; no chunk seams),
//   * it is smooth (low frequency fBm), so the warped climate field still flows
//     through the Lipschitz height limiter without making a cliff at the edge.
//
// Two octaves at WARP_FREQ bend the borders into irregular fingers; WARP_AMP (in
// blocks) is well under a biome cell (BIOME_CELL = 264) so borders wave and
// interlock without shredding biomes into noise or shrinking them back to tiny
// patches. Two distinct seeds (x vs z) keep the offset vector from collapsing onto
// the diagonal.
//
// WARP_FREQ is deliberately a fair bit finer than the biome cell. A very low warp
// frequency bent each biome band into one long tongue all pointing the same way,
// which clustered a bright biome (e.g. a desert band) into a single compass
// direction near a given spot; that read as a directional brightness swing (it
// tripped the render washout guard). A finer warp breaks each border into several
// shorter fingers that fan out in many directions, so the biome mix a viewer sees
// stays balanced across yaw while the borders are still clearly wavy.
//
// WARP_AMP is kept moderate: because sample_climate is warped too, the biome blend
// (and so the base terrain height) follows the warp. Too large an amplitude can
// shove a near-shore column's blend across the land/sea line, relocating a coast by
// many blocks. This amplitude bends the borders well (measured straightness ~0.20
// un-warped vs ~0.15 here, lower = more natural) while keeping coasts roughly put.
// ---------------------------------------------------------------------------
const WARP_PERIOD: i32 = 468; // ~1/70, finer than BIOME_CELL so fingers fan in many directions
                              // #172: scaled with BIOME_CELL (24 at cell 132). Bigger cells with the old
                              // amplitude read as bigger squares; doubling the displacement keeps the border
                              // waviness proportional to the cell size, and 48 is still well under
                              // BIOME_CELL 264 so the Voronoi 3x3 neighbour window stays valid.
const WARP_AMP: f32 = 48.0; // blocks of displacement; < BIOME_CELL so biomes stay large
const WARP_SEED_MIX_X: u64 = 0x57A6E11D03A11A57;
const WARP_SEED_MIX_Z: u64 = 0x11A57D03E11D57A6;

// Deterministic warp offset (in blocks) for a world column. Added to (fwx, fwz)
// before any biome / climate lookup so the boundaries become wavy and natural.
// #179: the offset is sampled at the CANONICAL coordinate (so twins across the
// seam get bit-identical offsets) but applied to the caller-frame coordinate,
// so downstream geometry (Voronoi distances etc) stays in the caller's frame.
#[inline]
fn domain_warp(fwx: f32, fwz: f32, seed: u64) -> (f32, f32) {
    let xseed = fmix64(seed ^ WARP_SEED_MIX_X);
    let zseed = fmix64(seed ^ WARP_SEED_MIX_Z);
    let cwx = wrap_world_f(fwx);
    let cwz = wrap_world_f(fwz);
    // fbm2 returns [0,1]; centre to [-1,1] so the offset is symmetric (no net drift).
    let nx = fbm2(cwx, cwz, xseed, 2, WARP_PERIOD, 0.5) * 2.0 - 1.0;
    let nz = fbm2(cwx, cwz, zseed, 2, WARP_PERIOD, 0.5) * 2.0 - 1.0;
    (fwx + nx * WARP_AMP, fwz + nz * WARP_AMP)
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

// ---------------------------------------------------------------------------
// Latitude climate (#181, phase 3 of #173)
//
// The torus gets a fake latitude: one full trip around the z axis crosses a warm
// equator band (centred on z = 0, wrapping across the seam) and a cold polar band
// (centred on z = WORLD_PERIOD / 2). The latitude factor is cos(2*pi*z / W), so
// it is periodic by construction and closes on the torus exactly like every
// other climate field. Walking north or south reads as equator, then pole, then
// around to the equator again.
//
// The factor becomes a temperature BIAS added to the sampled climate temperature
// (after the spread, clamped back to [0,1]). Moisture is untouched, so each band
// keeps internal variety: the cold band mixes snowy flats and cold mountains,
// the equator mixes desert, grass and forest. No new biomes; the existing set is
// re-weighted by where it sits on the planet.
//
// Because the bias lives inside sample_climate, every consumer agrees for free
// (the #171 lesson: the Voronoi site map must not paint a biome over columns
// whose climate disagrees). Voronoi sites classify from sample_climate at their
// OWN position, so a site inherits its own latitude's bias: desert sites cannot
// spawn in the cold band and snowy sites cannot spawn near the equator. The
// beach reclass and desert_region_t read the same biased site data.
//
// LAT_TEMP_AMP = 0.55 was tuned against the biome centres: in the deep cold band
// the biased temperature tops out near 0.45, which keeps Desert (temp 0.85,
// radius 0.28) unreachable and hands almost every column to Snowy or Mountains;
// at the equator the biased temperature bottoms out near 0.55, which keeps Snowy
// (temp 0.15, radius 0.26) unreachable at any moisture, so snow never falls at
// sea level there. Mid latitudes (|cos| small) keep today's temperate mix.
// ---------------------------------------------------------------------------
const LAT_TEMP_AMP: f32 = 0.55;

// Temperature bias for a canonical world z. Callers pass the WRAPPED coordinate
// so torus twins compute cos on bit-identical inputs.
#[inline]
fn latitude_temp_bias(wz_wrapped: i32) -> f32 {
    let phase = core::f32::consts::TAU * (wz_wrapped as f32) / (WORLD_PERIOD as f32);
    LAT_TEMP_AMP * phase.cos()
}

fn sample_climate(wx: i32, wz: i32, seed: u64) -> (f32, f32) {
    let tseed = fmix64(seed ^ 0xB10E5EED00000001);
    let mseed = fmix64(seed ^ 0xB10E5EED00000002);
    // #179: canonicalize first so twins across the seam are bit-identical.
    let wx = wrap_world(wx);
    let wz = wrap_world(wz);
    // Domain warp the sample point so the climate contours (and therefore the
    // biome-blend weights that drive terrain height) follow the same wavy
    // boundary as the discrete Voronoi biome. Height and biome stay in agreement.
    let (fwx, fwz) = domain_warp(wx as f32, wz as f32, seed);
    // #172: biomes ~4x the area. The climate field varies half as fast again
    // (1/216 before, 1/72 originally) so each biome covers a much larger
    // contiguous area and has its own identity. Pairs with the larger
    // BIOME_CELL below; keep the two in step or the Voronoi cells and the
    // climate contours drift apart. #179: period 76 ~= the old 1/432.
    const BIOME_NOISE_PERIOD: i32 = 76;
    let temp = climate_spread(fbm2(fwx, fwz, tseed, 3, BIOME_NOISE_PERIOD, 0.5));
    let moist = climate_spread(fbm2(fwx, fwz, mseed, 3, BIOME_NOISE_PERIOD, 0.5));
    // #181: latitude bias. Computed from the canonical (un-warped) wz so the
    // latitude bands are exactly periodic and twins stay bit-identical; the
    // domain warp already supplies plenty of local border waviness.
    let temp = (temp + latitude_temp_bias(wz)).clamp(0.0, 1.0);
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

// Like classify_climate but never returns the excluded biome. Used to keep beaches
// off high, dry ground (a beach belongs at the coast, not in the mountains).
fn classify_climate_excluding(temp: f32, moist: f32, exclude: i32) -> i32 {
    let mut best_i = 0i32;
    let mut best_d = 1e30f32;
    for i in 0..NUM_BIOMES {
        if i as i32 == exclude {
            continue;
        }
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
// #172: biomes ~4x the area (was 132, originally 44). #179: 264 -> 256 so the
// biome cell grid divides WORLD_PERIOD (128 cells across the torus).
const BIOME_CELL: i32 = 256;
const BIOME_CELL_COUNT: i32 = WORLD_PERIOD / BIOME_CELL; // 128
const VORONOI_SEED_MIX: u64 = 0x901A0701B10E5EED;

#[inline]
fn voronoi_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

// Per-cell Voronoi site data, memoized. The C++ original kept a thread_local
// VoronoiMemo for exactly this: the site position and climate classification
// are pure functions of (cell, seed), so caching them changes nothing about
// the output while removing the dominant repeated cost (9 site climate
// samples per column query, and 9 more per desert_region_t query). The memo
// is bounded and thread local (no locks, no cross-thread coupling).
#[derive(Clone, Copy)]
struct VoronoiSite {
    sx: f32,
    sz: f32,
    temp: f32,
    moist: f32,
    // classify_climate at the site, WITHOUT the coastal beach reclass (the
    // reclass queries terrain height; see voronoi_site_biome).
    raw_biome: i32,
}

fn voronoi_site(cx: i32, cz: i32, seed: u64) -> VoronoiSite {
    use std::cell::RefCell;
    use std::collections::HashMap;
    thread_local! {
        static MEMO: RefCell<HashMap<(i32, i32, u64), VoronoiSite>> = RefCell::new(HashMap::new());
    }
    // #179: the memo and the hash both key on the CANONICAL cell, so a cell and
    // its torus twin share one entry and identical site data. The stored site
    // position is in the canonical frame; translate it back into the caller's
    // frame below so nearest-site distance math keeps working across the seam.
    // The translation offset is a multiple of WORLD_PERIOD, exact in f32.
    let cxw = wrap_cell(cx, BIOME_CELL_COUNT);
    let czw = wrap_cell(cz, BIOME_CELL_COUNT);
    let key = (cxw, czw, seed);
    let dx = ((cx - cxw) * BIOME_CELL) as f32;
    let dz = ((cz - czw) * BIOME_CELL) as f32;
    if let Some(v) = MEMO.with(|m| m.borrow().get(&key).copied()) {
        return VoronoiSite {
            sx: v.sx + dx,
            sz: v.sz + dz,
            ..v
        };
    }
    let vseed = fmix64(seed ^ VORONOI_SEED_MIX);
    let h = hash2(cxw, czw, vseed);
    let jx = ((((h >> 0) & 0xFFFF) as f32) / 65535.0 - 0.5) * 0.66;
    let jz = ((((h >> 16) & 0xFFFF) as f32) / 65535.0 - 0.5) * 0.66;
    let sx = (cxw as f32 + 0.5 + jx) * (BIOME_CELL as f32);
    let sz = (czw as f32 + 0.5 + jz) * (BIOME_CELL as f32);
    let (temp, moist) = sample_climate((sx + 0.5) as i32, (sz + 0.5) as i32, seed);
    let raw_biome = classify_climate(temp, moist);
    let v = VoronoiSite {
        sx,
        sz,
        temp,
        moist,
        raw_biome,
    };
    MEMO.with(|m| {
        let mut mm = m.borrow_mut();
        if mm.len() >= 4096 {
            mm.clear();
        }
        mm.insert(key, v);
    });
    VoronoiSite {
        sx: v.sx + dx,
        sz: v.sz + dz,
        ..v
    }
}

// Final biome of a Voronoi cell, with the coastal beach reclass applied.
// #: beaches belong at the coast. A beach site sitting well above sea level (inland
// or in the mountains, no water) renders as dry grass, not sand, which reads as a
// bug. Reclassify such a site to its next-best climate biome so beaches only appear
// near the water. Memoized like the raw site (the height query is expensive).
fn voronoi_site_biome(cx: i32, cz: i32, seed: u64) -> i32 {
    use std::cell::RefCell;
    use std::collections::HashMap;
    thread_local! {
        static MEMO: RefCell<HashMap<(i32, i32, u64), i32>> = RefCell::new(HashMap::new());
    }
    // #179: canonical memo key; the biome value is frame-independent.
    let key = (
        wrap_cell(cx, BIOME_CELL_COUNT),
        wrap_cell(cz, BIOME_CELL_COUNT),
        seed,
    );
    if let Some(b) = MEMO.with(|m| m.borrow().get(&key).copied()) {
        return b;
    }
    let site = voronoi_site(key.0, key.1, seed);
    let mut biome = site.raw_biome;
    if biome == Biome::Beach as i32
        && surface_height_raw_at((site.sx + 0.5) as i32, (site.sz + 0.5) as i32, seed)
            > (SEA_LEVEL + 3) as f32
    {
        biome = classify_climate_excluding(site.temp, site.moist, Biome::Beach as i32);
    }
    MEMO.with(|m| {
        let mut mm = m.borrow_mut();
        if mm.len() >= 4096 {
            mm.clear();
        }
        mm.insert(key, biome);
    });
    biome
}

fn voronoi_biome(wx: i32, wz: i32, seed: u64) -> Biome {
    // Domain warp the query point before the nearest-site search. The cell sites
    // stay on their fixed lattice, but the point that gets matched to them moves
    // along the wavy warp field, so the Voronoi boundaries come out irregular and
    // eroded instead of straight. Derive the search cell from the WARPED point so
    // the 3x3 neighbour window stays centred on it (WARP_AMP is well under
    // BIOME_CELL, so the true nearest site is always inside the window).
    // #179: canonicalize first so twins are bit-identical.
    let wx = wrap_world(wx);
    let wz = wrap_world(wz);
    let (fwx, fwz) = domain_warp(wx as f32, wz as f32, seed);
    let cx = voronoi_floordiv(fwx.floor() as i32, BIOME_CELL);
    let cz = voronoi_floordiv(fwz.floor() as i32, BIOME_CELL);

    let mut best_d2 = 1e30f32;
    let mut best_cell = (cx, cz);
    for dz in -1..=1 {
        for dx in -1..=1 {
            let vc = voronoi_site(cx + dx, cz + dz, seed);
            let ex = fwx - vc.sx;
            let ez = fwz - vc.sz;
            let d2 = ex * ex + ez * ez;
            if d2 < best_d2 {
                best_d2 = d2;
                best_cell = (cx + dx, cz + dz);
            }
        }
    }
    // Only the WINNING cell's biome matters, so the (height-querying) beach
    // reclass runs for one cell, not nine. Identical result to reclassifying
    // all nine candidates, because the reclass never changes site positions.
    Biome::from_index(voronoi_site_biome(best_cell.0, best_cell.1, seed))
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

// ---------------------------------------------------------------------------
// Continentalness (#: real oceans)
//
// A single very-low-frequency field decides, at the continental scale, whether a
// region is ocean or land. Its period (~1/CONTINENT_FREQ blocks) is several times
// wider than a biome cell, so the ocean/land split is a large-scale coherent
// structure: oceans come out hundreds of blocks across, not ponds.
//
// continentalness() returns a SIGNED value centred on 0 (fBm is in [0,1], we map
// to [-1,1]). Negative => below the shore (ocean), positive => inland. It is a
// smooth function of position, so it flows through the Lipschitz limiter cleanly
// and never makes a seam cliff.
// ---------------------------------------------------------------------------
// #179: ~1/1100 -> 1/1024 (period 32) so the continent lattice divides the
// torus. Slightly bigger continents; visual impact is minor at this scale.
const CONTINENT_PERIOD: i32 = 32;
const CONTINENT_SEED_MIX: u64 = 0xC0117E17A15C0DE1;

// Shore bias: added to raw [-1,1] so land slightly outweighs ocean. Higher =>
// more land. Tuned for a healthy land fraction (see oceans_and_rivers test).
const CONTINENT_SHORE_BIAS: f32 = 0.10;

fn continentalness(fwx: f32, fwz: f32, seed: u64) -> f32 {
    let cseed = fmix64(seed ^ CONTINENT_SEED_MIX);
    // #179: canonicalize so all callers (some pass raw seam-adjacent coords)
    // get bit-identical values for torus twins.
    let fwx = wrap_world_f(fwx);
    let fwz = wrap_world_f(fwz);
    // 3 octaves so coastlines wiggle a little instead of being perfect blobs.
    let c = fbm2(fwx, fwz, cseed, 3, CONTINENT_PERIOD, 0.5);
    (c * 2.0 - 1.0) + CONTINENT_SHORE_BIAS
}

// How far this column is pushed by the continent field, in blocks (signed).
// Ocean side (cont < 0) is pulled WELL below sea level so the basin holds a deep,
// broad ocean; land side (cont > 0) is lifted gently. A smooth shoulder around
// the shore keeps a gradual beach gradient instead of a wall.
const OCEAN_DEPTH: f32 = 26.0; // max blocks below the land base out in deep ocean
const LAND_LIFT: f32 = 7.0; // max blocks lifted on solid land

// Continentalness thresholds for fading out the bumpy biome detail noise as a
// column goes from shore (no fade) to deep ocean (full fade). Both are negative
// (ocean side). The fade is smooth so the sea floor settles into a deep basin
// without a seam-violating step.
const OCEAN_SHORE_C: f32 = -0.04; // start fading detail just past the shoreline
const OCEAN_FLOOR_C: f32 = -0.45; // fully faded (smooth deep basin) out here
                                  // How much detail noise survives in the deepest ocean (a little floor texture so
                                  // the sea bed is not a perfect plane).
const OCEAN_DETAIL_FLOOR: f32 = 0.12;

fn continent_offset(fwx: f32, fwz: f32, seed: u64) -> f32 {
    let cont = continentalness(fwx, fwz, seed);
    if cont >= 0.0 {
        // Land: smootherstep up to LAND_LIFT.
        let t = (cont / 0.6).min(1.0);
        let s = t * t * (3.0 - 2.0 * t);
        s * LAND_LIFT
    } else {
        // Ocean: smooth descent. Near the shore it dips gently (beaches sit
        // here); farther out it drops toward full OCEAN_DEPTH.
        let a = -cont; // 0..~1
        let t = (a / 0.6).min(1.0);
        let s = t * t * (3.0 - 2.0 * t);
        -s * OCEAN_DEPTH
    }
}

// True when this column is open ocean (terrain pulled clearly below sea level by
// the continent field, not a transient noise dip). Used to gate ocean-only logic.
fn is_ocean_column(fwx: f32, fwz: f32, seed: u64) -> bool {
    continentalness(fwx, fwz, seed) < -0.04
}

// ---------------------------------------------------------------------------
// Rivers (#: visible meandering channels that reach the sea)
//
// A ridged-noise valley network. We take a low-frequency fBm field and fold it
// to a ridge at its mid value; the thin band around the ridge is the river. The
// carve is a few blocks wide with smooth banks. River depth is referenced to the
// surrounding land height so a channel cuts DOWN to about sea level: as a channel
// meanders into a coastal/ocean region (where the continent field already sits at
// or below the sea) it merges straight into the open water, so rivers connect to
// the ocean instead of dead-ending on a plateau. Inland, a channel that sits in a
// local low fills as a lake.
// ---------------------------------------------------------------------------
const RIVER_PERIOD: i32 = 126; // ~1/260: long, winding rivers
const RIVER_HALFW: f32 = 0.030; // half-width of the ridge band (river width)
const RIVER_SEED_MIX: u64 = 0x515E12D32C0DE011;

// 0..1 across the channel (1 at the centre line, 0 at/beyond the bank).
fn river_channel_t(fwx: f32, fwz: f32, seed: u64) -> f32 {
    let rseed = fmix64(seed ^ RIVER_SEED_MIX);
    let fwx = wrap_world_f(fwx);
    let fwz = wrap_world_f(fwz);
    let n = fbm2(fwx, fwz, rseed, 3, RIVER_PERIOD, 0.5);
    // Distance from the ridge (mid value 0.5); the river runs where this is small.
    let d = (n - 0.5).abs();
    if d >= RIVER_HALFW {
        return 0.0;
    }
    let t = 1.0 - d / RIVER_HALFW;
    t * t * (3.0 - 2.0 * t) // smooth banks
}

// River carve depth in blocks for this column, given the un-carved land height.
// We only ever LOWER terrain (max 0), and we cut toward a bed just below sea
// level so there is always visible water in the channel. The cut is capped so a
// river crossing high ground does not become a bottomless canyon.
fn river_carve(fwx: f32, fwz: f32, seed: u64, land_h: f32) -> f32 {
    let t = river_channel_t(fwx, fwz, seed);
    if t <= 0.0 {
        return 0.0;
    }
    let bed_target = (SEA_LEVEL as f32) - 1.5;
    let cut = (land_h - bed_target).max(0.0).min(12.0);
    cut * t
}

// #171: desert dune band. Deserts read as gentle dune fields, not mountains:
// where a column is desert the height is compressed toward a band a few blocks
// above sea level, re-textured by this slow dune noise (about a 6 block
// crest-to-trough swing at DESERT_DUNE_FREQ, plus the fine ripple noise and
// height_detail that already exist).
const DESERT_DUNE_SEED_MIX: u64 = 0xD0E5D0E5D0E5A0D1;
const DESERT_DUNE_PERIOD: i32 = 683; // ~1/48

// #171: smooth desert-region field. The desert LOOK (sand surface, cactus,
// desert decorations) follows the discrete Voronoi region, and the Voronoi
// site's climate can disagree hard with a column's own climate (the site is
// up to a cell away). Damping by the climate weights alone therefore leaves
// sand-covered mountains: columns painted Desert by the Voronoi map whose own
// climate weight for Desert is zero. This field is a smooth 0..1 indicator of
// "inside the warped Voronoi desert region": 1 well inside, 0 outside, fading
// across DESERT_EDGE_BAND blocks straddling the region border, so the dune
// compression follows exactly the region that renders as desert with no cliff
// at the edge. It uses the same warped query point and jittered site lattice
// as voronoi_biome, but classifies sites WITHOUT the coastal beach reclass:
// that reclass queries terrain height, which would recurse back into this
// function. (Consequence: the rare Beach site that reclassifies to Desert is
// not damped. It keeps its beach-flat terrain anyway.)
const DESERT_EDGE_BAND: f32 = 40.0;

fn desert_region_t(wx: i32, wz: i32, seed: u64) -> f32 {
    // #179: canonicalize so twins are bit-identical; the warped-frame site
    // search below stays consistent because voronoi_site translates sites
    // into whatever frame the query cell is in.
    let wx = wrap_world(wx);
    let wz = wrap_world(wz);
    let (fwx, fwz) = domain_warp(wx as f32, wz as f32, seed);
    let cx = voronoi_floordiv(fwx.floor() as i32, BIOME_CELL);
    let cz = voronoi_floordiv(fwz.floor() as i32, BIOME_CELL);

    let mut d_desert = f32::MAX; // distance to the nearest desert site
    let mut d_other = f32::MAX; // distance to the nearest non-desert site
    for dz in -1..=1 {
        for dx in -1..=1 {
            let vc = voronoi_site(cx + dx, cz + dz, seed);
            let d = ((fwx - vc.sx) * (fwx - vc.sx) + (fwz - vc.sz) * (fwz - vc.sz)).sqrt();
            if vc.raw_biome == Biome::Desert as i32 {
                d_desert = d_desert.min(d);
            } else {
                d_other = d_other.min(d);
            }
        }
    }
    if d_desert == f32::MAX {
        return 0.0; // no desert site in reach
    }
    if d_other == f32::MAX {
        return 1.0; // deserts all around
    }
    // Signed border margin in blocks: positive inside the desert region. The
    // margin is a continuous function of position (sites enter and leave the
    // 3x3 window only when they are too far to be nearest), so the smoothstep
    // over the band yields a smooth, seam-free blend factor.
    let margin = d_other - d_desert;
    let t = (margin / DESERT_EDGE_BAND + 0.5).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn surface_height_raw(wx: i32, wz: i32, seed: u64, weights: &[f32; NUM_BIOMES]) -> f32 {
    // #179: canonicalize once here; every noise field below then computes on
    // identical inputs for torus twins (bit-identical heights).
    let wx = wrap_world(wx);
    let wz = wrap_world(wz);
    let fwx = wx as f32;
    let fwz = wz as f32;

    let swell = regional_swell(fwx, fwz, seed);

    // Keep the smooth biome base floor apart from the bumpy per-biome detail noise.
    // In open ocean we fade out the detail (which carries the big mountain/forest
    // amplitude) so the sea floor is a smooth, deep basin driven by the low
    // frequency continent offset instead of a field of near surface ridges. The
    // continent field is smooth, so the faded floor flows through the Lipschitz
    // limiter cleanly and stays deep (the old jagged floor read as shallow lakes
    // because peaks poked up near sea level between the limiter's anchors).
    let mut base_blend = 0.0f32;
    let mut detail_blend = 0.0f32;

    for i in 0..NUM_BIOMES {
        if weights[i] < 1e-4 {
            continue;
        }

        let p = &BIOME_PARAMS[i];
        let bseed = fmix64(seed ^ BIOME_SEED_OFFSETS[i]);

        let mut n = fbm2(fwx, fwz, bseed, p.octaves, p.period, p.persistence);

        if Biome::from_index(i as i32) == Biome::Desert {
            // #179: ~1/12 as an integer lattice period so the ripple closes.
            const RIPPLE_PERIOD: i32 = 2731;
            const RIPPLE_FREQ: f32 = RIPPLE_PERIOD as f32 / WORLD_PERIOD as f32;
            let ripple_seed = fmix64(seed ^ 0xDEA0D5A0D5A0D5A0);
            let ripple = value_noise2(
                fwx * RIPPLE_FREQ,
                fwz * RIPPLE_FREQ,
                ripple_seed,
                RIPPLE_PERIOD,
            );
            n += ripple * 2.0 / (p.amp * 2.0 + 0.001);
            if n > 1.0 {
                n = 1.0;
            }
        }

        let biome_is = Biome::from_index(i as i32);
        let biome_swell = if biome_is != Biome::Plains && biome_is != Biome::Swamp {
            swell
        } else {
            0.0
        };
        base_blend += weights[i] * p.base_y;
        detail_blend += weights[i] * ((n * 2.0 - 1.0) * p.amp + biome_swell);
    }

    // Ocean factor: 0 on land and at the shore, ramping smoothly to 1 in deep
    // ocean. Drives how much of the bumpy detail noise we keep, so the transition
    // from a normal coastline into a smooth deep basin is gradual (no cliff).
    let cont_raw = continentalness(fwx, fwz, seed);
    let ocean_t = {
        // c in [OCEAN_FLOOR_C .. OCEAN_SHORE_C] maps to [1 .. 0].
        let t = ((OCEAN_SHORE_C - cont_raw) / (OCEAN_SHORE_C - OCEAN_FLOOR_C)).clamp(0.0, 1.0);
        t * t * (3.0 - 2.0 * t) // smootherstep
    };
    // Keep a little floor texture even in deep ocean so it is not glassy flat.
    let detail_keep = 1.0 - ocean_t * (1.0 - OCEAN_DETAIL_FLOOR);
    let mut blended_h = base_blend + detail_blend * detail_keep;

    // Continent offset: lifts land, sinks oceans. This is the field that creates
    // the large-scale ocean/land split. Swamps stay near sea level (they should
    // not be hoisted up onto continents), so we damp the lift for them.
    let swamp_w = weights[Biome::Swamp as usize];
    let cont = continent_offset(fwx, fwz, seed);
    let cont = if cont > 0.0 {
        cont * (1.0 - 0.6 * swamp_w)
    } else {
        cont
    };
    blended_h += cont;

    // #171: deserts are low relief. Two things pile mountain relief into a
    // desert: the climate weight blend lets neighbouring biome detail (the
    // mountain amplitude especially), regional swell and continent lift stack
    // up under a desert-heavy column, and the Voronoi region can paint Desert
    // over a column whose own climate weights are not desert at all (the
    // sand-covered-mountain case, see desert_region_t). Take the stronger of
    // the two desert indicators and compress the height toward a soft dune
    // band a little above the sea, re-textured by a slow low amplitude dune
    // noise so the band still undulates a few blocks instead of going flat.
    // Both indicators fade smoothly across the desert border (climate weights
    // by construction, the region field across DESERT_EDGE_BAND), so the
    // terrain shades into the neighbour biome with no cliff, and the whole
    // damp is scaled by (1 - ocean_t) so a desert region overlapping open
    // ocean never has its sea floor hoisted up into a sand island. Pure
    // function of (seed, wx, wz); it lives here in the one shared raw-height
    // path, so the anchor lattice, structures and decorations all see the
    // same heights.
    let desert_w = weights[Biome::Desert as usize];
    let desert_t = desert_w.max(desert_region_t(wx, wz, seed));
    if desert_t > 1e-4 {
        let dune_seed = fmix64(seed ^ DESERT_DUNE_SEED_MIX);
        let dune = fbm2(fwx, fwz, dune_seed, 2, DESERT_DUNE_PERIOD, 0.5);
        // Band: SEA_LEVEL+8 at the dune troughs up to SEA_LEVEL+14 on crests.
        let dune_target = (SEA_LEVEL as f32) + 8.0 + dune * 6.0;
        let damp = desert_t * (1.0 - ocean_t);
        blended_h += (dune_target - blended_h) * damp;
    }

    // Rivers carve into the (already continent-adjusted) land. Skip the carve in
    // open ocean (it is already underwater) and damp it in deserts (dry washes).
    if !is_ocean_column(fwx, fwz, seed) {
        blended_h -= river_carve(fwx, fwz, seed, blended_h) * (1.0 - desert_w);
    }

    blended_h
}

fn surface_height_raw_at(wx: i32, wz: i32, seed: u64) -> f32 {
    let w = biome_weights(wx, wz, seed);
    surface_height_raw(wx, wz, seed, &w)
}

// ---------------------------------------------------------------------------
// Smooth anchor-lattice surface
//
// The raw height field is expensive, so we sample it on a coarse anchor lattice
// (every SEAM_ANCHOR_STEP blocks) and reconstruct per-column heights from those
// anchors. The reconstruction must be a pure function of (seed, wx, wz) that any
// chunk evaluates identically, which holds because the anchors themselves are
// pure functions of their lattice coordinates and every column reads the same
// 4x4 anchor neighborhood regardless of which chunk asks.
//
// The old reconstruction was a Lipschitz-1 cone envelope midpoint. Its tent
// geometry plus integer truncation terraced the world into lattice-aligned
// square plateaus (very visible underwater). We now use bicubic Catmull-Rom,
// which is C1 continuous across cell boundaries (no creases), and add a small
// high-frequency detail octave so quantization to whole blocks follows the
// noise contours instead of locking onto the anchor grid.
// ---------------------------------------------------------------------------
// #179: 12 -> 16 so the anchor lattice divides WORLD_PERIOD (2048 anchors
// across the torus). A bonus: the bicubic parameter t = (wx mod 16)/16 is now
// exact in f32, so a column queried from either side of the seam reconstructs
// the identical height bit for bit.
const SEAM_ANCHOR_STEP: i32 = 16;
const SEAM_ANCHOR_RADIUS: i32 = 5;

#[inline]
fn seam_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

// Catmull-Rom spline through p1..p2 with tangents from p0/p3, t in [0,1].
#[inline]
fn catmull_rom(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) -> f32 {
    let a = 2.0 * p1;
    let b = p2 - p0;
    let c = 2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3;
    let d = 3.0 * (p1 - p2) + p3 - p0;
    0.5 * (a + (b + (c + d * t) * t) * t)
}

// Smooth bicubic evaluation over the anchor lattice given an anchor-fetch
// closure. Reads the 4x4 anchors around the cell containing (wx, wz).
fn seam_smooth_eval<F: Fn(i32, i32) -> f32>(wx: i32, wz: i32, fetch: F) -> f32 {
    let acx = seam_floordiv(wx, SEAM_ANCHOR_STEP);
    let acz = seam_floordiv(wz, SEAM_ANCHOR_STEP);
    let tx = (wx - acx * SEAM_ANCHOR_STEP) as f32 / SEAM_ANCHOR_STEP as f32;
    let tz = (wz - acz * SEAM_ANCHOR_STEP) as f32 / SEAM_ANCHOR_STEP as f32;

    let mut rows = [0.0f32; 4];
    for (j, row) in rows.iter_mut().enumerate() {
        let gz = acz + j as i32 - 1;
        *row = catmull_rom(
            fetch(acx - 1, gz),
            fetch(acx, gz),
            fetch(acx + 1, gz),
            fetch(acx + 2, gz),
            tx,
        );
    }
    catmull_rom(rows[0], rows[1], rows[2], rows[3], tz)
}

// Fine post-interpolation relief: low amplitude, higher frequency than the
// anchor lattice, pure function of (seed, wx, wz). Roughly +-1.5 blocks. This
// breaks the integer-quantization plates without changing the macro shape.
const HEIGHT_DETAIL_SEED_MIX: u64 = 0x5EAF_00D5_0F7C_0A57;

#[inline]
fn height_detail(wx: i32, wz: i32, seed: u64) -> f32 {
    let dseed = fmix64(seed ^ HEIGHT_DETAIL_SEED_MIX);
    // #179: ~1/13 as period 2521; lacunarity was 2.6 which cannot close on the
    // torus, so fbm2's fixed 2.0 applies (second octave ~1/6.5 instead of 1/5;
    // this is the +-1.5 block fine relief, visual impact is negligible).
    let wx = wrap_world(wx);
    let wz = wrap_world(wz);
    (fbm2(wx as f32, wz as f32, dseed, 2, 2521, 0.55) * 2.0 - 1.0) * 1.5
}

// Slow on-demand path: raw anchor heights computed directly. Matches the cached
// path exactly because both read identical anchors and detail noise.
fn surface_height(wx: i32, wz: i32, seed: u64) -> i32 {
    let base = seam_smooth_eval(wx, wz, |gx, gz| {
        surface_height_raw_at(gx * SEAM_ANCHOR_STEP, gz * SEAM_ANCHOR_STEP, seed)
    });
    (base + height_detail(wx, wz, seed)).floor() as i32
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
    seed: u64,
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
            h[(iz * nx + ix) as usize] = surface_height_raw_at(
                (gxlo + ix) * SEAM_ANCHOR_STEP,
                (gzlo + iz) * SEAM_ANCHOR_STEP,
                seed,
            );
        }
    }
    SeamAnchorCache {
        gx0: gxlo,
        gz0: gzlo,
        nx,
        nz,
        h,
        seed,
    }
}

// Fast path over the prebuilt anchor cache. The cache covers the chunk's cells
// plus SEAM_ANCHOR_RADIUS, and the bicubic kernel only reaches 2 cells out, so
// every in-chunk query (and queries up to 3 cells outside) reads true anchors
// and matches surface_height exactly.
fn surface_height_cached(wx: i32, wz: i32, cache: &SeamAnchorCache) -> i32 {
    let base = seam_smooth_eval(wx, wz, |gx, gz| cache.at(gx, gz));
    (base + height_detail(wx, wz, cache.seed)).floor() as i32
}

// ---------------------------------------------------------------------------
// Per-chunk column cache
// ---------------------------------------------------------------------------
struct ChunkColumnCache {
    h: Vec<i32>,
    dom: Vec<Biome>,
    weights: Vec<[f32; NUM_BIOMES]>,
}

impl ChunkColumnCache {
    #[inline]
    fn idx(lx: i32, lz: i32) -> usize {
        (lz * K_CHUNK_DIM + lx) as usize
    }
}

fn build_column_cache(
    wx_min: i32,
    wz_min: i32,
    seed: u64,
    anchor_cache: &SeamAnchorCache,
) -> ChunkColumnCache {
    let mut out = ChunkColumnCache {
        h: vec![0; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
        dom: vec![Biome::Plains; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
        weights: vec![[0.0; NUM_BIOMES]; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
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

// ---------------------------------------------------------------------------
// Shared per-column data, memoized across the Y stack and across worker threads.
//
// The anchor and column caches are pure functions of (seed, wx_min, wz_min), but a
// column of terrain spans several Y chunks (CY -1..3) and generate() used to rebuild
// both caches for every one of them: the same 256 columns of climate + voronoi +
// seam-cone height noise computed five times per column (about a third of total gen
// time, measured). This memo computes them once per column and shares the Arc.
//
// Determinism: the cached value is a pure function of the key, so a hit, a miss, a
// concurrent duplicate compute, or a cleared map all yield byte-identical chunks.
// The map is bounded (cleared at CAP) so long sessions cannot grow it unbounded.
// ---------------------------------------------------------------------------
struct SharedColumnData {
    anchors: SeamAnchorCache,
    cols: ChunkColumnCache,
}

fn shared_column_data(wx_min: i32, wz_min: i32, seed: u64) -> std::sync::Arc<SharedColumnData> {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock};
    const CAP: usize = 512;
    static MEMO: OnceLock<Mutex<HashMap<(u64, i32, i32), Arc<SharedColumnData>>>> = OnceLock::new();
    let memo = MEMO.get_or_init(|| Mutex::new(HashMap::new()));
    // #179: canonical key AND canonical build frame, so torus-twin chunks share
    // one entry and the cached lattice frames line up with generate()'s own
    // canonicalized chunk coordinate.
    let wx_min = wrap_world(wx_min);
    let wz_min = wrap_world(wz_min);
    let key = (seed, wx_min, wz_min);
    if let Some(hit) = memo.lock().unwrap().get(&key) {
        return hit.clone();
    }
    // Compute outside the lock; a racing thread may duplicate the work but the
    // value is identical either way.
    let anchors = build_anchor_cache(wx_min, wz_min, seed);
    let cols = build_column_cache(wx_min, wz_min, seed, &anchors);
    let data = Arc::new(SharedColumnData { anchors, cols });
    let mut m = memo.lock().unwrap();
    if m.len() >= CAP {
        m.clear();
    }
    m.insert(key, data.clone());
    data
}

// ===========================================================================
// (continued in part 2 below: trees, canopies, structures, deadwood, caves,
//  decorations, generate, public API)
// ===========================================================================
include!("worldgen_part2.rs");
