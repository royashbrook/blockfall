// ---------------------------------------------------------------------------
// TerrainGen — public API
// ---------------------------------------------------------------------------
#[derive(Default)]
pub struct TerrainGen {
    seed: u64,
}

impl TerrainGen {
    pub fn new() -> Self {
        TerrainGen { seed: 0 }
    }

    pub fn seed(&mut self, s: u64) {
        self.seed = s;
    }

    pub fn generate<C: Chunk>(&self, c: ChunkCoord, chunk: &mut C) {
        // #179 looping world: canonicalize the chunk coordinate. A chunk and
        // its torus twin (x or z shifted by WORLD_PERIOD_CHUNKS) then run the
        // byte-identical code path, which is the wrap guarantee.
        let c = ChunkCoord {
            x: c.x.rem_euclid(WORLD_PERIOD_CHUNKS),
            y: c.y,
            z: c.z.rem_euclid(WORLD_PERIOD_CHUNKS),
        };
        let seed_ = self.seed;
        let wx_min0 = c.x * K_CHUNK_DIM;
        let wz_min0 = c.z * K_CHUNK_DIM;
        // One shared build per (seed, x, z) column, reused by all Y chunks and workers.
        let shared = shared_column_data(wx_min0, wz_min0, seed_);
        let anchor_cache = &shared.anchors;
        let col_cache = &shared.cols;

        let height_at = |wx: i32, wz: i32| -> i32 {
            let lx = wx - wx_min0;
            let lz = wz - wz_min0;
            if lx >= 0 && lx < K_CHUNK_DIM && lz >= 0 && lz < K_CHUNK_DIM {
                col_cache.h[ChunkColumnCache::idx(lx, lz)]
            } else {
                surface_height_cached(wx, wz, &anchor_cache)
            }
        };

        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let wx = c.x * K_CHUNK_DIM + lx;
                let wz = c.z * K_CHUNK_DIM + lz;

                let ci = ChunkColumnCache::idx(lx, lz);
                let dom = col_cache.dom[ci];
                let h = col_cache.h[ci];

                let mut is_steep = false;
                if dom == Biome::Mountains && h < SNOW_LINE {
                    let h_n = height_at(wx, wz - 1);
                    let h_s = height_at(wx, wz + 1);
                    let h_e = height_at(wx + 1, wz);
                    let h_w = height_at(wx - 1, wz);
                    let ad = |a: i32, b: i32| {
                        let d = a - b;
                        if d < 0 {
                            -d
                        } else {
                            d
                        }
                    };
                    let mut slope = ad(h, h_n);
                    let t = ad(h, h_s);
                    if t > slope {
                        slope = t;
                    }
                    let t = ad(h, h_e);
                    if t > slope {
                        slope = t;
                    }
                    let t = ad(h, h_w);
                    if t > slope {
                        slope = t;
                    }
                    is_steep = slope >= 3;
                }

                let mut basin_extra = 0;
                if h < SEA_LEVEL {
                    basin_extra = ocean_basin_extra(wx, wz, h, seed_);
                }
                let h_floor = h - basin_extra;

                let shaft_depth = cave_entrance_depth(wx, wz, seed_);
                let is_entrance_col = shaft_depth > 0 && h > SEA_LEVEL && dom != Biome::Swamp;

                let surface_block: BlockId;
                let fill_block: BlockId;
                let has_snow = (dom == Biome::Mountains && h >= SNOW_LINE) || dom == Biome::Snowy;

                match dom {
                    Biome::Desert => {
                        surface_block = SAND;
                        fill_block = SAND;
                    }
                    Biome::Beach => {
                        if h <= SEA_LEVEL + 2 {
                            surface_block = SAND;
                            fill_block = SAND;
                        } else {
                            surface_block = GRASS;
                            fill_block = DIRT;
                        }
                    }
                    Biome::Mountains => {
                        if h >= SNOW_LINE {
                            surface_block = STONE;
                            fill_block = STONE;
                        } else if is_steep {
                            surface_block = COBBLESTONE;
                            fill_block = STONE;
                        } else if h >= ROCK_LINE {
                            let rh = hash2(wx, wz, fmix64(seed_ ^ 0x70CC1A4E70CC1A4E));
                            let roll = rh & 0xFF;
                            let above = h - ROCK_LINE;
                            let mut rock_thresh = 115u64 + (above * 9) as u64;
                            if rock_thresh > 255 {
                                rock_thresh = 255;
                            }
                            if roll < rock_thresh {
                                surface_block = if ((rh >> 8) & 0x3) == 0 { GRAVEL } else { STONE };
                                fill_block = STONE;
                            } else {
                                surface_block = GRASS;
                                fill_block = DIRT;
                            }
                        } else {
                            surface_block = GRASS;
                            fill_block = DIRT;
                        }
                    }
                    Biome::Snowy => {
                        surface_block = DIRT;
                        fill_block = DIRT;
                    }
                    Biome::Swamp => {
                        surface_block = DIRT;
                        fill_block = DIRT;
                    }
                    // Forest, Plains, default
                    _ => {
                        surface_block = GRASS;
                        fill_block = DIRT;
                    }
                }

                for ly in 0..K_CHUNK_DIM {
                    let wy = c.y * K_CHUNK_DIM + ly;

                    let mut b;
                    if wy > h {
                        if wy <= SEA_LEVEL {
                            if has_snow && wy == SEA_LEVEL {
                                b = ICE;
                            } else {
                                b = WATER;
                            }
                        } else {
                            b = AIR;
                        }
                    } else if wy > h_floor && wy <= h {
                        b = WATER;
                    } else if wy == h_floor {
                        if wy <= SEA_LEVEL && dom != Biome::Desert {
                            b = SAND;
                        } else {
                            b = surface_block;
                        }
                    } else if wy >= h_floor - 3 {
                        if dom == Biome::Mountains && h >= SNOW_LINE && wy == h_floor - 1 {
                            b = GRAVEL;
                        } else if dom == Biome::Desert {
                            if wy == h_floor - 3 {
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

                    if is_entrance_col && b != WATER {
                        if wy <= h && wy > h - shaft_depth {
                            b = AIR;
                        }
                    }

                    let cave_surface_ref = h_floor;
                    if b != AIR && b != WATER && wy < cave_surface_ref - CAVE_SURFACE_MARGIN && wy > K_COLUMN_MIN_Y + 4 {
                        let cseed = fmix64(seed_ ^ 0xCA4E5EED1234);
                        let cave = fbm3(wx as f32, wy as f32, wz as f32, cseed, 3, CAVE_NOISE_PERIOD);
                        if cave > CAVE_THRESH {
                            b = AIR;
                        }
                    }

                    chunk.set(lx, ly, lz, b);
                }

                let wants_snow_cap = (dom == Biome::Mountains && h >= SNOW_LINE) || dom == Biome::Snowy;
                if wants_snow_cap && h > SEA_LEVEL {
                    let snow_wy = h + 1;
                    let snow_ly = snow_wy - c.y * K_CHUNK_DIM;
                    if snow_ly >= 0 && snow_ly < K_CHUNK_DIM {
                        if chunk.get(lx, snow_ly, lz) == AIR {
                            chunk.set(lx, snow_ly, lz, SNOW_LAYER);
                        }
                    }
                }
            }
        }

        // Swamp water pools.
        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let ci = ChunkColumnCache::idx(lx, lz);
                let dom = col_cache.dom[ci];

                if dom != Biome::Swamp {
                    continue;
                }

                let h = col_cache.h[ci];
                if h <= SEA_LEVEL + 1 {
                    for ly in 0..K_CHUNK_DIM {
                        let wy = c.y * K_CHUNK_DIM + ly;
                        if wy > h && wy <= SEA_LEVEL {
                            if chunk.get(lx, ly, lz) == AIR {
                                chunk.set(lx, ly, lz, WATER);
                            }
                        }
                    }
                }
            }
        }

        place_cave_features(c, chunk, seed_);
        place_decorations(c, chunk, seed_, &anchor_cache, &col_cache);
    }

    pub fn content_hash(&self, c: ChunkCoord) -> u64 {
        let mut tmp = DenseChunk::new(AIR);
        self.generate(c, &mut tmp);

        const FNV_OFFSET: u64 = 14695981039346656037;
        const FNV_PRIME: u64 = 1099511628211;

        let mut h = FNV_OFFSET;
        for lz in 0..K_CHUNK_DIM {
            for ly in 0..K_CHUNK_DIM {
                for lx in 0..K_CHUNK_DIM {
                    let b = tmp.get(lx, ly, lz);
                    h ^= (b & 0xFF) as u64;
                    h = h.wrapping_mul(FNV_PRIME);
                    h ^= ((b >> 8) & 0xFF) as u64;
                    h = h.wrapping_mul(FNV_PRIME);
                }
            }
        }
        h
    }
}

// ---------------------------------------------------------------------------
// Public worldgen query helpers (pure functions)
// ---------------------------------------------------------------------------
pub fn worldgen_is_cave_entrance(wx: i32, wz: i32, seed: u64) -> bool {
    is_cave_entrance(wx, wz, seed)
}

pub fn worldgen_dominant_biome(wx: i32, wz: i32, seed: u64) -> i32 {
    voronoi_biome(wx, wz, seed) as i32
}

pub fn worldgen_surface_height(wx: i32, wz: i32, seed: u64) -> i32 {
    surface_height(wx, wz, seed)
}

/// True when this column is open ocean (pulled below sea level by the continent
/// field). Exposed for diagnostics and any future ocean-aware game logic.
pub fn worldgen_is_ocean_col(wx: i32, wz: i32, seed: u64) -> bool {
    is_ocean_column(wx as f32, wz as f32, seed)
}

/// 0..1 river-channel intensity at this column (1 at the centre line). Exposed
/// for diagnostics. Note: a column with intensity > 0 is only wet if it also sits
/// at/below sea level after the carve.
pub fn worldgen_river_t(wx: i32, wz: i32, seed: u64) -> f32 {
    river_channel_t(wx as f32, wz as f32, seed)
}

pub fn worldgen_count_structures(wx0: i32, wz0: i32, span: i32, seed: u64) -> i32 {
    let scx_min = struct_floordiv(wx0, STRUCT_CELL_SIZE);
    let scx_max = struct_floordiv(wx0 + span - 1, STRUCT_CELL_SIZE);
    let scz_min = struct_floordiv(wz0, STRUCT_CELL_SIZE);
    let scz_max = struct_floordiv(wz0 + span - 1, STRUCT_CELL_SIZE);

    let mut count = 0;
    for scz in scz_min..=scz_max {
        for scx in scx_min..=scx_max {
            let sd = struct_for_cell(scx, scz, seed);
            if sd.present {
                count += 1;
            }
        }
    }
    count
}

/// Returns Some(out_y) if (wx,wz) is the anchor column of a structure.
pub fn worldgen_structure_marker_at(wx: i32, wz: i32, seed: u64) -> Option<i32> {
    let scx = struct_floordiv(wx, STRUCT_CELL_SIZE);
    let scz = struct_floordiv(wz, STRUCT_CELL_SIZE);
    for dz in -1..=1 {
        for dx in -1..=1 {
            let sd = struct_for_cell(scx + dx, scz + dz, seed);
            if sd.present && sd.anchor_wx == wx && sd.anchor_wz == wz {
                return Some(struct_surface(wx, wz, seed));
            }
        }
    }
    None
}

/// True if a structure type id is a city (the only settlement that hosts the full
/// villager profession chain). The settlement vs profession coupling lives here so the
/// worldgen city upgrade is the single source of truth: world.rs asks this instead of
/// hardcoding the STRUCT_CITY id.
pub fn worldgen_is_city(typ: i32) -> bool {
    typ == STRUCT_CITY
}

/// #201: dominant biome index at a world column (0 Plains, 1 Forest, 2 Mountains,
/// 3 Desert, 4 Snowy, 5 Swamp, 6 Beach), for biome-culture villager looks.
pub fn worldgen_biome_at(wx: i32, wz: i32, seed: u64) -> u8 {
    voronoi_biome(wx, wz, seed) as u8
}

/// #214: nearest VILLAGE or CITY anchor within `radius` blocks of (wx,wz), scanning
/// the neighbouring structure cells. worldgen_structure_near only checks the caller's
/// own 64-block cell, so a settlement just across a cell boundary was invisible to map
/// discovery. Returns (type, anchor_x, anchor_z) canonical, or None. Distances use the
/// caller's local frame (the scanned cells are the neighbourhood of wx/wz), so no
/// seam wrap is needed here.
fn worldgen_settlement_near_kind(
    wx: i32,
    wz: i32,
    radius: i32,
    seed: u64,
    city_only: bool,
) -> Option<(i32, i32, i32)> {
    let scx_min = struct_floordiv(wx - radius, STRUCT_CELL_SIZE);
    let scx_max = struct_floordiv(wx + radius, STRUCT_CELL_SIZE);
    let scz_min = struct_floordiv(wz - radius, STRUCT_CELL_SIZE);
    let scz_max = struct_floordiv(wz + radius, STRUCT_CELL_SIZE);
    let mut best: Option<(i32, i32, i32)> = None;
    let mut best_d2 = i64::MAX;
    for scz in scz_min..=scz_max {
        for scx in scx_min..=scx_max {
            let sd = struct_for_cell(scx, scz, seed);
            if !sd.present
                || (sd.typ != STRUCT_VILLAGE && sd.typ != STRUCT_CITY)
                || (city_only && sd.typ != STRUCT_CITY)
            {
                continue;
            }
            let ddx = (sd.anchor_wx - wx) as i64;
            let ddz = (sd.anchor_wz - wz) as i64;
            let d2 = ddx * ddx + ddz * ddz;
            if d2 <= (radius as i64) * (radius as i64) && d2 < best_d2 {
                best_d2 = d2;
                best = Some((sd.typ, wrap_world(sd.anchor_wx), wrap_world(sd.anchor_wz)));
            }
        }
    }
    best
}

pub fn worldgen_settlement_near(
    wx: i32,
    wz: i32,
    radius: i32,
    seed: u64,
) -> Option<(i32, i32, i32)> {
    worldgen_settlement_near_kind(wx, wz, radius, seed, false)
}

/// Nearest generated CITY anchor within `radius`. Fresh worlds use this so HOME
/// starts at the civic settlement promised by #204, while callers that want any
/// village or city keep using worldgen_settlement_near.
pub fn worldgen_city_near(
    wx: i32,
    wz: i32,
    radius: i32,
    seed: u64,
) -> Option<(i32, i32, i32)> {
    worldgen_settlement_near_kind(wx, wz, radius, seed, true)
}

/// Returns (type, anchor_x, anchor_z, anchor_y). type==0 (STRUCT_NONE) leaves the
/// other fields unspecified (caller should ignore them), matching the C++ contract
/// where the out-params are untouched.
pub fn worldgen_structure_near(wx: i32, wz: i32, seed: u64) -> (i32, i32, i32, i32) {
    let scx = struct_floordiv(wx, STRUCT_CELL_SIZE);
    let scz = struct_floordiv(wz, STRUCT_CELL_SIZE);
    let sd = struct_for_cell(scx, scz, seed);
    if !sd.present || sd.typ == STRUCT_NONE {
        return (STRUCT_NONE, 0, 0, 0);
    }
    let y = struct_surface(sd.anchor_wx, sd.anchor_wz, seed);
    // #179: canonical anchor so callers can key per-settlement state on it
    // (the same settlement seen from either side of the seam gets one key).
    (sd.typ, wrap_world(sd.anchor_wx), wrap_world(sd.anchor_wz), y)
}

/// Danger site lookup for the creature system. Scans structure cells overlapping a
/// square of half-size `radius` blocks around (wx,wz) and returns the anchor of the
/// nearest ruined structure as (anchor_x, anchor_y, anchor_z), or None if there is
/// no ruin in range. Deterministic for a given seed: the result depends only on the
/// structure cells, not on call order. The creature system uses this to spawn a
/// hostile or two at the ruin regardless of the night/quest gate.
pub fn worldgen_dangerous_site_near(wx: i32, wz: i32, radius: i32, seed: u64) -> Option<(i32, i32, i32)> {
    let scx_min = struct_floordiv(wx - radius, STRUCT_CELL_SIZE);
    let scx_max = struct_floordiv(wx + radius, STRUCT_CELL_SIZE);
    let scz_min = struct_floordiv(wz - radius, STRUCT_CELL_SIZE);
    let scz_max = struct_floordiv(wz + radius, STRUCT_CELL_SIZE);

    let mut best: Option<(i32, i32, i32)> = None;
    let mut best_d2 = i64::MAX;
    for scz in scz_min..=scz_max {
        for scx in scx_min..=scx_max {
            let sd = struct_for_cell(scx, scz, seed);
            if !sd.present || !struct_is_ruin(sd.typ) {
                continue;
            }
            let ddx = (sd.anchor_wx - wx) as i64;
            let ddz = (sd.anchor_wz - wz) as i64;
            let d2 = ddx * ddx + ddz * ddz;
            if d2 <= (radius as i64) * (radius as i64) && d2 < best_d2 {
                best_d2 = d2;
                let y = struct_surface(sd.anchor_wx, sd.anchor_wz, seed);
                // #179: canonical anchor so per-ruin state keys are unique.
                best = Some((wrap_world(sd.anchor_wx), y, wrap_world(sd.anchor_wz)));
            }
        }
    }
    best
}

pub fn worldgen_structure_footprint(wx: i32, wz: i32, seed: u64) -> bool {
    let scx_min = struct_floordiv(wx - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    let scx_max = struct_floordiv(wx + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    let scz_min = struct_floordiv(wz - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    let scz_max = struct_floordiv(wz + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    for scz in scz_min..=scz_max {
        for scx in scx_min..=scx_max {
            let sd = struct_for_cell(scx, scz, seed);
            if !sd.present {
                continue;
            }
            let mut ddx = wx - sd.anchor_wx;
            if ddx < 0 {
                ddx = -ddx;
            }
            let mut ddz = wz - sd.anchor_wz;
            if ddz < 0 {
                ddz = -ddz;
            }
            if ddx <= STRUCT_MAX_REACH_XZ && ddz <= STRUCT_MAX_REACH_XZ {
                return true;
            }
        }
    }
    false
}

/// Facts about a single stamped villager home, for tests / tooling. All counts are
/// over the home's footprint as actually written into the world (terrain not
/// generated, so every non-AIR cell is a home block).
#[derive(Clone, Copy, Debug)]
pub struct VillagerHomeScan {
    /// Footprint width and depth in blocks (the wall-to-wall extent in X and Z).
    pub width: i32,
    pub depth: i32,
    /// Number of shaped timber cells used for posts and door/window trim.
    pub beam_blocks: i32,
    /// Number of occupied Y levels above the wall top. A pitched roof has several;
    /// the old flat lid had one.
    pub roof_levels: i32,
    /// True when the roof reaches exactly one block beyond every wall edge.
    pub roof_overhang: bool,
    /// Number of door blocks in the walls (a 1 wide door is 2 tall = 2 blocks).
    pub door_blocks: i32,
    /// Number of window (glass pane) blocks in the walls.
    pub window_blocks: i32,
    /// Number of bed blocks placed inside.
    pub bed_blocks: i32,
    /// Largest count of contiguous interior air cells on the floor level (standable
    /// space). At least 9 (a 3x3 cavity) for a 5x5 home.
    pub interior_air: i32,
    /// True if the lowest block in every occupied column rests on (or fills down to)
    /// the terrain, i.e. the home does not float.
    pub on_ground: bool,
}

/// Stamps one villager home (place_hut) at a deterministic on-land anchor for the
/// given seed and returns a scan of its footprint. Pure: depends only on the seed.
/// Used by tests to assert the home is a real building (>= 5x5, has a door opening,
/// windows, an interior air cavity, and a bed) without reaching into chunk internals.
pub fn worldgen_villager_home_scan(seed: u64) -> VillagerHomeScan {
    // Pick an on-land anchor: scan a bounded grid of widely spaced columns once and
    // take the first that sits well above sea level (not in water). Deterministic and
    // bounded; the wide step finds dry land quickly even when the origin is ocean.
    let mut ax = 0;
    let mut az = 0;
    'find: for d in 0..96i32 {
        // d is a Chebyshev ring index over a grid stepped by 16 blocks; check the
        // ring perimeter only so each column is visited once.
        for dz in -d..=d {
            for dx in -d..=d {
                if dx.abs() != d && dz.abs() != d {
                    continue; // interior of the ring already checked at smaller d
                }
                let cx = dx * 16;
                let cz = dz * 16;
                if surface_height(cx, cz, seed) > SEA_LEVEL + 4
                    && !is_ocean_column(cx as f32, cz as f32, seed)
                {
                    ax = cx;
                    az = cz;
                    break 'find;
                }
            }
        }
    }

    let hh = fmix64((seed ^ 0x484F4D4501u64).wrapping_mul(0x2545F4914F6CDD1D));
    let wall_rx = 2 + ((hh >> 5) & 1) as i32;
    let wall_rz = 2 + ((hh >> 6) & 1) as i32;
    let (wall_min_x, wall_max_x) = (ax - wall_rx, ax + wall_rx);
    let (wall_min_z, wall_max_z) = (az - wall_rz, az + wall_rz);

    // Unbounded grid that satisfies Chunk for one chunk window at a time; replay the
    // stamp over every window the home reaches so we capture the whole footprint.
    struct ScanGrid {
        wx_min: i32,
        wy_min: i32,
        wz_min: i32,
        cells: std::collections::HashMap<(i32, i32, i32), BlockId>,
    }
    impl Chunk for ScanGrid {
        fn get(&self, lx: i32, ly: i32, lz: i32) -> BlockId {
            *self
                .cells
                .get(&(self.wx_min + lx, self.wy_min + ly, self.wz_min + lz))
                .unwrap_or(&AIR)
        }
        fn set(&mut self, lx: i32, ly: i32, lz: i32, b: BlockId) {
            self.cells
                .insert((self.wx_min + lx, self.wy_min + ly, self.wz_min + lz), b);
        }
    }

    let floordiv = |a: i32, b: i32| a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 };
    let reach = 4; // homes reach at most 3 from centre; 4 gives a margin
    let base = surface_height(ax, az, seed);
    let cx0 = floordiv(ax - reach, K_CHUNK_DIM);
    let cx1 = floordiv(ax + reach, K_CHUNK_DIM);
    let cz0 = floordiv(az - reach, K_CHUNK_DIM);
    let cz1 = floordiv(az + reach, K_CHUNK_DIM);
    let cy0 = floordiv(base - 16, K_CHUNK_DIM);
    let cy1 = floordiv(base + 16, K_CHUNK_DIM);

    let mut cells: std::collections::HashMap<(i32, i32, i32), BlockId> =
        std::collections::HashMap::new();
    for cy in cy0..=cy1 {
        for cz in cz0..=cz1 {
            for cx in cx0..=cx1 {
                let (wx_min, wy_min, wz_min) =
                    (cx * K_CHUNK_DIM, cy * K_CHUNK_DIM, cz * K_CHUNK_DIM);
                let mut g = ScanGrid {
                    wx_min,
                    wy_min,
                    wz_min,
                    cells: std::mem::take(&mut cells),
                };
                place_hut(ax, az, hh, seed, &mut g, wx_min, wy_min, wz_min);
                cells = g.cells;
            }
        }
    }

    // Footprint extent.
    let mut occupied_min_x = i32::MAX;
    let mut occupied_max_x = i32::MIN;
    let mut occupied_min_z = i32::MAX;
    let mut occupied_max_z = i32::MIN;
    let mut door_blocks = 0;
    let mut window_blocks = 0;
    let mut bed_blocks = 0;
    let mut beam_blocks = 0;
    for (&(wx, _wy, wz), &b) in cells.iter() {
        if b == AIR {
            continue;
        }
        occupied_min_x = occupied_min_x.min(wx);
        occupied_max_x = occupied_max_x.max(wx);
        occupied_min_z = occupied_min_z.min(wz);
        occupied_max_z = occupied_max_z.max(wz);
        if b == OAK_DOOR {
            door_blocks += 1;
        } else if b == GLASS_PANE {
            window_blocks += 1;
        } else if b == BED {
            bed_blocks += 1;
        } else if b == WOOD_BEAM {
            beam_blocks += 1;
        }
    }
    let width = wall_max_x - wall_min_x + 1;
    let depth = wall_max_z - wall_min_z + 1;
    let roof_overhang = occupied_min_x == wall_min_x - 1
        && occupied_max_x == wall_max_x + 1
        && occupied_min_z == wall_min_z - 1
        && occupied_max_z == wall_max_z + 1;

    // Interior cavity (standable space): the cells one block above the floor, strictly
    // inside the wall ring (min/max bounds). The floor surface level is read off the
    // door, whose lowest block sits at floor + 1, so the floor level is (lowest door
    // y) - 1 and the standable layer is floor + 1. A cell counts as cavity when it is
    // open (AIR or furniture such as a bed) rather than wall, i.e. it is part of the
    // room you can stand in. We deliberately count the bed cells too: they are part of
    // the open interior footprint (the bed is removable furniture, not structure). The
    // separate on_ground check guarantees something solid rests beneath each column,
    // so we do not require a floor block in this terrain-free scan.
    let mut door_low_y = i32::MAX;
    for (&(_wx, wy, _wz), &b) in cells.iter() {
        if b == OAK_DOOR && wy < door_low_y {
            door_low_y = wy;
        }
    }
    let wall_top = door_low_y.saturating_add(2);
    let roof_levels = cells
        .iter()
        .filter_map(|(&(_wx, wy, _wz), &b)| (b != AIR && wy > wall_top).then_some(wy))
        .collect::<std::collections::HashSet<_>>()
        .len() as i32;
    let mut interior_air = 0;
    if door_low_y != i32::MAX {
        let floor_y = door_low_y; // standable layer = door bottom level
        for wz in (wall_min_z + 1)..wall_max_z {
            for wx in (wall_min_x + 1)..wall_max_x {
                let here = *cells.get(&(wx, floor_y, wz)).unwrap_or(&AIR);
                // Open interior: air or furniture (bed). Anything else here would be a
                // wall block, which should not appear in the interior.
                if here == AIR || here == BED {
                    interior_air += 1;
                }
            }
        }
    }

    // On-ground: a column "floats" only if it is a real wall / foundation stack
    // (2+ blocks) whose base hangs well above the terrain with clear air beneath.
    // This mirrors the established big_structures_sit_on_ground floater rule: a lone
    // decorative block (a ceiling lamp over the open interior) is not a floater, and
    // the surf+4 tolerance allows a door lintel that opens over the ground. Terrain
    // is not generated in this scan, so the wall / foundation columns are what matter.
    let mut low: std::collections::HashMap<(i32, i32), (i32, i32)> = std::collections::HashMap::new();
    for (&(wx, wy, wz), &b) in cells.iter() {
        if b == AIR {
            continue;
        }
        let e = low.entry((wx, wz)).or_insert((i32::MAX, 0));
        if wy < e.0 {
            e.0 = wy;
        }
        e.1 += 1;
    }
    let mut on_ground = true;
    for (&(wx, wz), &(y_low, count)) in low.iter() {
        let surf = surface_height(wx, wz, seed);
        if y_low > surf + 4 && count >= 2 {
            on_ground = false;
            break;
        }
    }

    VillagerHomeScan {
        width,
        depth,
        beam_blocks,
        roof_levels,
        roof_overhang,
        door_blocks,
        window_blocks,
        bed_blocks,
        interior_air,
        on_ground,
    }
}
