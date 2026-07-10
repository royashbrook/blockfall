// ---------------------------------------------------------------------------
// Ocean depth (#12) — always 0 (artificial basin carve disabled, seam safety)
// ---------------------------------------------------------------------------
fn ocean_basin_extra(_wx: i32, _wz: i32, _h: i32, _seed: u64) -> i32 {
    0
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
