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
