// ---------------------------------------------------------------------------
// Deadwood (#22)
// ---------------------------------------------------------------------------
// #179: 12 -> 16 so the deadwood grid divides WORLD_PERIOD; probability below
// rescaled 40 -> 71 (x 16^2/12^2) to keep deadwood-per-area unchanged.
const DEADWOOD_CELL: i32 = 16;
const DEADWOOD_CELL_COUNT: i32 = WORLD_PERIOD / DEADWOOD_CELL; // 2048
const DEADWOOD_REACH_XZ: i32 = 5;
const DEADWOOD_SEED_MIX: u64 = 0xDEAD0F00DDEAD066;

const DEADWOOD_NONE: i32 = 0;
const DEADWOOD_STUMP: i32 = 1;
const DEADWOOD_LOG: i32 = 2;

#[derive(Clone, Copy)]
struct DeadwoodDesc {
    wx: i32,
    wz: i32,
    kind: i32,
    length: i32,
    dir: i32,
    log_id: BlockId,
    leaf_nub: bool,
    present: bool,
}

#[inline]
fn deadwood_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

fn deadwood_for_cell(dcx: i32, dcz: i32, seed: u64) -> DeadwoodDesc {
    let dseed = fmix64(seed ^ DEADWOOD_SEED_MIX);
    let h = hash2(wrap_cell(dcx, DEADWOOD_CELL_COUNT), wrap_cell(dcz, DEADWOOD_CELL_COUNT), dseed);

    if (h & 0xFF) >= 71 {
        return DeadwoodDesc { wx: 0, wz: 0, kind: DEADWOOD_NONE, length: 0, dir: 0, log_id: 0, leaf_nub: false, present: false };
    }

    let h2 = fmix64(h ^ 0xF0FFEEDDEADBEEF1);
    let off_x = 2 + ((h2 >> 0) % ((DEADWOOD_CELL - 4) as u64)) as i32;
    let off_z = 2 + ((h2 >> 8) % ((DEADWOOD_CELL - 4) as u64)) as i32;
    let ax = dcx * DEADWOOD_CELL + off_x;
    let az = dcz * DEADWOOD_CELL + off_z;

    let dom = voronoi_biome(ax, az, seed);
    if dom == Biome::Desert || dom == Biome::Beach || dom == Biome::Snowy {
        return DeadwoodDesc { wx: 0, wz: 0, kind: DEADWOOD_NONE, length: 0, dir: 0, log_id: 0, leaf_nub: false, present: false };
    }

    let is_log_kind = ((h2 >> 16) & 0x1) == 0;
    let kind = if is_log_kind { DEADWOOD_LOG } else { DEADWOOD_STUMP };
    let length = if is_log_kind {
        3 + ((h2 >> 20) % 3) as i32
    } else {
        1 + ((h2 >> 20) & 1) as i32
    };
    let dir = ((h2 >> 24) & 0x3) as i32;
    let birch = ((h2 >> 26) & 0x3) == 0;
    let leaf_nub = !is_log_kind && (((h2 >> 28) & 0x3) == 0);

    DeadwoodDesc {
        wx: ax,
        wz: az,
        kind,
        length,
        dir,
        log_id: if birch { BIRCH_LOG } else { OAK_LOG },
        leaf_nub,
        present: true,
    }
}

// ---------------------------------------------------------------------------
// Cave interior features (#37)
// ---------------------------------------------------------------------------
fn cave_surface_h(wx: i32, wz: i32, seed: u64) -> i32 {
    surface_height(wx, wz, seed)
}

fn cave_voxel_is_air(wx: i32, wy: i32, wz: i32, seed: u64) -> bool {
    let h = cave_surface_h(wx, wz, seed);
    if wy >= h - CAVE_SURFACE_MARGIN {
        return false;
    }
    if wy <= K_COLUMN_MIN_Y + 4 {
        return false;
    }
    // #179: canonical coords + integer cave lattice period (2048 = 1/16).
    let wx = wrap_world(wx);
    let wz = wrap_world(wz);
    let cave = fbm3(wx as f32, wy as f32, wz as f32, fmix64(seed ^ 0xCA4E5EED1234), 3, CAVE_NOISE_PERIOD);
    cave > CAVE_THRESH
}

fn cave_voxel_is_solid(wx: i32, wy: i32, wz: i32, seed: u64) -> bool {
    let h = cave_surface_h(wx, wz, seed);
    if wy > h {
        return false;
    }
    !cave_voxel_is_air(wx, wy, wz, seed)
}

// #179: 9 -> 8 so the cave-feature grid divides WORLD_PERIOD (4096 cells);
// per-cell roll rescaled 56 -> 39 (x 8^3/9^3) to keep features-per-volume.
const CAVE_FEAT_CELL: i32 = 8;
const CAVE_FEAT_CELL_COUNT: i32 = WORLD_PERIOD / CAVE_FEAT_CELL; // 4096
const CAVE_FEAT_SEED_MIX: u64 = 0xCA7EFEA70FEA7C00;

const CFEAT_MUSHROOMS: i32 = 1;
const CFEAT_CRYSTALS: i32 = 2;
const CFEAT_POOL: i32 = 3;
const CFEAT_ORE_KNOT: i32 = 4;
const CFEAT_CAMP: i32 = 5;

fn place_cave_features<C: Chunk>(c: ChunkCoord, chunk: &mut C, seed: u64) {
    let wx_min = c.x * K_CHUNK_DIM;
    let wy_min = c.y * K_CHUNK_DIM;
    let wz_min = c.z * K_CHUNK_DIM;
    let wx_max = wx_min + K_CHUNK_DIM - 1;
    let wy_max = wy_min + K_CHUNK_DIM - 1;
    let wz_max = wz_min + K_CHUNK_DIM - 1;

    if wy_min > 0 {
        return;
    }

    let feat_reach = 3;
    let fseed = fmix64(seed ^ CAVE_FEAT_SEED_MIX);

    let fdiv = |a: i32, b: i32| a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 };

    let cx0 = fdiv(wx_min - feat_reach, CAVE_FEAT_CELL);
    let cx1 = fdiv(wx_max + feat_reach, CAVE_FEAT_CELL);
    let cy0 = fdiv(wy_min - feat_reach, CAVE_FEAT_CELL);
    let cy1 = fdiv(wy_max + feat_reach, CAVE_FEAT_CELL);
    let cz0 = fdiv(wz_min - feat_reach, CAVE_FEAT_CELL);
    let cz1 = fdiv(wz_max + feat_reach, CAVE_FEAT_CELL);

    // Clipped writer.
    macro_rules! put {
        ($chunk:expr, $wx:expr, $wy:expr, $wz:expr, $b:expr, $only_into_air:expr) => {{
            let wx = $wx;
            let wy = $wy;
            let wz = $wz;
            if !(wx < wx_min || wx > wx_max || wy < wy_min || wy > wy_max || wz < wz_min || wz > wz_max) {
                let lx = wx - wx_min;
                let ly = wy - wy_min;
                let lz = wz - wz_min;
                let cur = $chunk.get(lx, ly, lz);
                if !($only_into_air && cur != AIR) {
                    $chunk.set(lx, ly, lz, $b);
                }
            }
        }};
    }

    for cy in cy0..=cy1 {
        for cz in cz0..=cz1 {
            for cx in cx0..=cx1 {
                let h = hash3(wrap_cell(cx, CAVE_FEAT_CELL_COUNT), cy, wrap_cell(cz, CAVE_FEAT_CELL_COUNT), fseed);
                let roll = h & 0xFF;
                if roll >= 39 {
                    continue;
                }

                let h2 = fmix64(h ^ 0x0FEA7C0DECA7EFEA);
                let ax = cx * CAVE_FEAT_CELL + ((h2 >> 0) % (CAVE_FEAT_CELL as u64)) as i32;
                let ay = cy * CAVE_FEAT_CELL + ((h2 >> 8) % (CAVE_FEAT_CELL as u64)) as i32;
                let az = cz * CAVE_FEAT_CELL + ((h2 >> 16) % (CAVE_FEAT_CELL as u64)) as i32;

                let tsel = (h2 >> 24) & 0xFF;
                let ftype = if tsel < 88 {
                    CFEAT_MUSHROOMS
                } else if tsel < 150 {
                    CFEAT_CRYSTALS
                } else if tsel < 198 {
                    CFEAT_ORE_KNOT
                } else if tsel < 244 {
                    CFEAT_POOL
                } else {
                    CFEAT_CAMP
                };

                let anchor_air = cave_voxel_is_air(ax, ay, az, seed);
                let floor_below = cave_voxel_is_solid(ax, ay - 1, az, seed);

                match ftype {
                    x if x == CFEAT_MUSHROOMS => {
                        let surface_y = cave_surface_h(ax, az, seed);
                        let surface_biome = voronoi_biome(ax, az, seed);
                        if surface_biome == Biome::Desert || surface_biome == Biome::Beach || ay >= surface_y - 4 {
                            continue;
                        }
                        if !anchor_air || !floor_below {
                            continue;
                        }
                        let n = 2 + ((h2 >> 32) % 4) as i32;
                        for i in 0..n {
                            let bh = fmix64(h2 ^ ((i as u64).wrapping_mul(0x9E37)));
                            let dx = ((bh >> 0) % 3) as i32 - 1;
                            let dz = ((bh >> 8) % 3) as i32 - 1;
                            if cave_voxel_is_air(ax + dx, ay, az + dz, seed) && cave_voxel_is_solid(ax + dx, ay - 1, az + dz, seed) {
                                put!(chunk, ax + dx, ay, az + dz, MUSHROOM, true);
                            }
                        }
                        if cave_voxel_is_solid(ax, ay - 1, az, seed) {
                            put!(chunk, ax, ay - 1, az, GLOW_BLOCK, false);
                        }
                    }
                    x if x == CFEAT_CRYSTALS => {
                        if !anchor_air {
                            continue;
                        }
                        put!(chunk, ax, ay, az, CRYSTAL_LAMP, true);
                        let n = 3 + ((h2 >> 32) % 4) as i32;
                        for i in 0..n {
                            let bh = fmix64(h2 ^ ((i as u64).wrapping_mul(0xC713)));
                            let dx = ((bh >> 0) % 3) as i32 - 1;
                            let dy = ((bh >> 8) % 3) as i32 - 1;
                            let dz = ((bh >> 16) % 3) as i32 - 1;
                            if dx == 0 && dy == 0 && dz == 0 {
                                continue;
                            }
                            if cave_voxel_is_solid(ax + dx, ay + dy, az + dz, seed) {
                                put!(chunk, ax + dx, ay + dy, az + dz, COLOR_CRYSTAL, false);
                            }
                        }
                    }
                    x if x == CFEAT_ORE_KNOT => {
                        if !anchor_air {
                            continue;
                        }
                        let ore = if (h2 >> 40) & 1 != 0 { IRON_ORE } else { COAL_ORE };
                        let n = 3 + ((h2 >> 32) % 4) as i32;
                        for i in 0..n {
                            let bh = fmix64(h2 ^ ((i as u64).wrapping_mul(0xA113)));
                            let dx = ((bh >> 0) % 3) as i32 - 1;
                            let dy = ((bh >> 8) % 3) as i32 - 1;
                            let dz = ((bh >> 16) % 3) as i32 - 1;
                            if cave_voxel_is_solid(ax + dx, ay + dy, az + dz, seed) {
                                put!(chunk, ax + dx, ay + dy, az + dz, ore, false);
                            }
                        }
                    }
                    x if x == CFEAT_POOL => {
                        if !anchor_air || !floor_below {
                            continue;
                        }
                        for dz in -1..=1 {
                            for dx in -1..=1 {
                                if cave_voxel_is_air(ax + dx, ay, az + dz, seed) && cave_voxel_is_solid(ax + dx, ay - 1, az + dz, seed) {
                                    put!(chunk, ax + dx, ay, az + dz, WATER, true);
                                }
                            }
                        }
                    }
                    _ => {
                        // CFEAT_CAMP
                        if !anchor_air || !floor_below {
                            continue;
                        }
                        put!(chunk, ax, ay, az, CHEST, true);
                        put!(chunk, ax + 1, ay, az, COBBLESTONE, true);
                        put!(chunk, ax - 1, ay, az, OAK_PLANKS, true);
                        if cave_voxel_is_air(ax, ay + 1, az, seed) {
                            put!(chunk, ax, ay + 1, az, GLOW_BLOCK, true);
                        }
                    }
                }
            }
        }
    }
}

