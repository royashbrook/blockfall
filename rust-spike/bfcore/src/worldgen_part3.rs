// ===========================================================================
// Part 3 of the worldgen port (included from worldgen_part2.rs).
// Structures, deadwood, cave features, decorations, generate, public API.
// ===========================================================================

// ---------------------------------------------------------------------------
// Structure system
// ---------------------------------------------------------------------------
const STRUCT_CELL_SIZE: i32 = 64;
const STRUCT_SEED_MIX: u64 = 0x57AC7EDEDBEF5717;
const MARKER_BLOCK: BlockId = 34;
const STRUCT_PROB_THRESH: u64 = 128;

const STRUCT_NONE: i32 = 0;
const STRUCT_CABIN: i32 = 1;
const STRUCT_OBELISK: i32 = 2;
const STRUCT_CAMP: i32 = 3;
const STRUCT_WATCHTOWER: i32 = 4;
const STRUCT_TEMPLE: i32 = 5;
const STRUCT_CAIRN: i32 = 6;
const STRUCT_WELL: i32 = 7;
const STRUCT_VILLAGE: i32 = 8;
const STRUCT_SHRINE: i32 = 9;

const STRUCT_MAX_REACH_XZ: i32 = 7;

#[derive(Clone, Copy)]
struct StructDesc {
    anchor_wx: i32,
    anchor_wz: i32,
    typ: i32,
    cell_hash: u64,
    present: bool,
}

#[inline]
fn struct_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

// Pure surface height at a column for structure placement (matches surface_height).
fn struct_surface(wx: i32, wz: i32, seed: u64) -> i32 {
    surface_height(wx, wz, seed)
}

fn struct_for_cell(scx: i32, scz: i32, seed: u64) -> StructDesc {
    let sseed = fmix64(seed ^ STRUCT_SEED_MIX);
    let h = hash2(scx, scz, sseed);

    if (h & 0xFF) >= STRUCT_PROB_THRESH {
        return StructDesc { anchor_wx: 0, anchor_wz: 0, typ: STRUCT_NONE, cell_hash: 0, present: false };
    }

    let h2s = fmix64(h ^ 0xFACEBEEF0BAB);
    let off_x = 7 + ((h2s >> 0) % 50) as i32;
    let off_z = 7 + ((h2s >> 16) % 50) as i32;

    let ax = scx * STRUCT_CELL_SIZE + off_x;
    let az = scz * STRUCT_CELL_SIZE + off_z;

    let dom = voronoi_biome(ax, az, seed);

    let h = struct_surface(ax, az, seed);
    if h <= SEA_LEVEL {
        return StructDesc { anchor_wx: 0, anchor_wz: 0, typ: STRUCT_NONE, cell_hash: 0, present: false };
    }

    let type_bits = (h2s >> 32) & 0x7;
    let stype = match dom {
        Biome::Mountains => {
            if type_bits <= 1 {
                STRUCT_CAIRN
            } else if type_bits <= 3 {
                STRUCT_OBELISK
            } else if type_bits <= 5 {
                STRUCT_SHRINE
            } else if type_bits == 6 {
                STRUCT_WATCHTOWER
            } else {
                STRUCT_TEMPLE
            }
        }
        Biome::Desert => {
            if type_bits <= 2 {
                STRUCT_TEMPLE
            } else if type_bits <= 4 {
                STRUCT_OBELISK
            } else if type_bits <= 6 {
                STRUCT_SHRINE
            } else {
                STRUCT_WELL
            }
        }
        Biome::Forest => {
            if type_bits <= 2 {
                STRUCT_CABIN
            } else if type_bits <= 4 {
                STRUCT_CAMP
            } else if type_bits <= 5 {
                STRUCT_VILLAGE
            } else if type_bits == 6 {
                STRUCT_TEMPLE
            } else {
                STRUCT_SHRINE
            }
        }
        Biome::Plains => {
            if type_bits <= 1 {
                STRUCT_VILLAGE
            } else if type_bits <= 3 {
                STRUCT_CABIN
            } else if type_bits == 4 {
                STRUCT_WELL
            } else if type_bits == 5 {
                STRUCT_CAMP
            } else if type_bits == 6 {
                STRUCT_WATCHTOWER
            } else {
                STRUCT_SHRINE
            }
        }
        Biome::Snowy => {
            if type_bits <= 2 {
                STRUCT_CABIN
            } else if type_bits <= 4 {
                STRUCT_CAIRN
            } else if type_bits <= 6 {
                STRUCT_OBELISK
            } else {
                STRUCT_SHRINE
            }
        }
        Biome::Swamp => {
            if type_bits <= 2 {
                STRUCT_WATCHTOWER
            } else if type_bits <= 4 {
                STRUCT_CAMP
            } else if type_bits <= 6 {
                STRUCT_WELL
            } else {
                STRUCT_SHRINE
            }
        }
        _ => STRUCT_CAIRN,
    };

    StructDesc { anchor_wx: ax, anchor_wz: az, typ: stype, cell_hash: h2s, present: true }
}

fn struct_set<C: Chunk>(chunk: &mut C, wx: i32, wy: i32, wz: i32, wx_min: i32, wy_min: i32, wz_min: i32, b: BlockId) -> bool {
    if wx < wx_min || wx > wx_min + K_CHUNK_DIM - 1 {
        return false;
    }
    if wy < wy_min || wy > wy_min + K_CHUNK_DIM - 1 {
        return false;
    }
    if wz < wz_min || wz > wz_min + K_CHUNK_DIM - 1 {
        return false;
    }
    let lx = wx - wx_min;
    let ly = wy - wy_min;
    let lz = wz - wz_min;
    if chunk.get(lx, ly, lz) == AIR {
        chunk.set(lx, ly, lz, b);
    } else if b != AIR {
        chunk.set(lx, ly, lz, b);
    }
    true
}

fn struct_fill_col<C: Chunk>(chunk: &mut C, wx: i32, wz: i32, top_wy: i32, seed: u64, wx_min: i32, wy_min: i32, wz_min: i32, b: BlockId) {
    let col_h = struct_surface(wx, wz, seed);
    let mut wy = col_h + 1;
    while wy <= top_wy {
        struct_set(chunk, wx, wy, wz, wx_min, wy_min, wz_min, b);
        wy += 1;
    }
}

fn struct_place_marker<C: Chunk>(ax: i32, az: i32, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let h = struct_surface(ax, az, seed);
    struct_set(chunk, ax, h - 1, az, wx_min, wy_min, wz_min, MARKER_BLOCK);
}

fn place_cabin<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let hx = if (h >> 2) & 1 != 0 { 3 } else { 2 };
    let hz = 2;

    let mut floor_h = -1000000;
    for dz in -hz..=hz {
        for dx in -hx..=hx {
            let sh = struct_surface(ax + dx, az + dz, seed);
            if sh > floor_h {
                floor_h = sh;
            }
        }
    }

    let cobble = ((h >> 5) & 1) != 0;
    let wall = if cobble { COBBLESTONE } else { OAK_PLANKS };
    let trim = if cobble { STONE_BRICK } else { WOOD_BEAM };
    let wall_h = 3;
    let wall_top = floor_h + wall_h;

    let door_east = ((h >> 6) & 1) != 0;
    let door_dx = if door_east { hx } else { -hx };

    for dz in -hz..=hz {
        for dx in -hx..=hx {
            struct_fill_col(chunk, ax + dx, az + dz, floor_h, seed, wx_min, wy_min, wz_min, OAK_PLANKS);
        }
    }

    for dz in -hz..=hz {
        for dx in -hx..=hx {
            let on_x = dx == -hx || dx == hx;
            let on_z = dz == -hz || dz == hz;
            if !(on_x || on_z) {
                continue;
            }
            let corner = on_x && on_z;

            let is_door = dx == door_dx && dz == 0;
            if is_door {
                struct_set(chunk, ax + dx, floor_h + 1, az + dz, wx_min, wy_min, wz_min, OAK_DOOR);
                struct_set(chunk, ax + dx, floor_h + 2, az + dz, wx_min, wy_min, wz_min, OAK_DOOR);
                continue;
            }

            let window = !corner && (((dx + dz) & 1) == 0);
            for wy in (floor_h + 1)..=wall_top {
                let mut b = if corner { trim } else { wall };
                if window && wy == floor_h + 2 {
                    b = GLASS_PANE;
                }
                struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, b);
            }
        }
    }

    if hx == 3 {
        for dz in -hz..=hz {
            if dz == 0 {
                continue;
            }
            for wy in (floor_h + 1)..=wall_top {
                struct_set(chunk, ax, wy, az + dz, wx_min, wy_min, wz_min, wall);
            }
        }
    }

    let roof = if cobble { STONE_BRICK } else { BIRCH_PLANKS };
    for dz in -(hz + 1)..=(hz + 1) {
        let adz = if dz < 0 { -dz } else { dz };
        let ridge_step = hz + 1 - adz;
        let roof_y = wall_top + 1 + ridge_step;
        for dx in -(hx + 1)..=(hx + 1) {
            struct_set(chunk, ax + dx, roof_y, az + dz, wx_min, wy_min, wz_min, roof);
        }
    }
    for dz in -hz..=hz {
        let adz = if dz < 0 { -dz } else { dz };
        let ridge_step = hz + 1 - adz;
        for dx in [-hx, hx] {
            for wy in (wall_top + 1)..(wall_top + 1 + ridge_step) {
                struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, wall);
            }
        }
    }

    struct_set(chunk, ax + door_dx, floor_h + 3, az, wx_min, wy_min, wz_min, TORCH);
    struct_set(chunk, ax, floor_h + 1, az, wx_min, wy_min, wz_min, GLOW_BLOCK);

    {
        let chim_dx = -door_dx;
        let chim_x = ax + chim_dx;
        let chim_z = az + if (h >> 7) & 1 != 0 { hz } else { -hz };
        let ridge_top = wall_top + 1 + (hz + 1);
        let chim_top = ridge_top + 2;
        struct_fill_col(chunk, chim_x, chim_z, chim_top, seed, wx_min, wy_min, wz_min, COBBLESTONE);
        struct_set(chunk, chim_x, floor_h + 1, chim_z, wx_min, wy_min, wz_min, GLOW_BLOCK);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_obelisk<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let big_h = struct_surface(ax, az, seed);
    let shaft = 7 + ((h >> 4) % 4) as i32;

    for dz in -1..=1 {
        for dx in -1..=1 {
            let top = struct_surface(ax + dx, az + dz, seed) + 1;
            struct_fill_col(chunk, ax + dx, az + dz, top, seed, wx_min, wy_min, wz_min, STONE_BRICK);
        }
    }
    struct_set(chunk, ax, big_h + 2, az, wx_min, wy_min, wz_min, STONE_BRICK);

    let marks = [[2, 2], [-2, 2], [2, -2], [-2, -2]];
    for m in marks.iter() {
        let mh = struct_surface(ax + m[0], az + m[1], seed) + 1;
        struct_fill_col(chunk, ax + m[0], az + m[1], mh, seed, wx_min, wy_min, wz_min, MOSSY_STONE);
    }

    for dy in 3..=(shaft + 2) {
        let b = if ((h >> (dy as u32)) & 1) != 0 { MOSSY_STONE } else { STONE };
        struct_set(chunk, ax, big_h + dy, az, wx_min, wy_min, wz_min, b);
    }
    struct_set(chunk, ax, big_h + shaft + 3, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_camp<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    for dz in -1..=1 {
        for dx in -1..=1 {
            let col_h = struct_surface(ax + dx, az + dz, seed);
            let centre = dx == 0 && dz == 0;
            struct_set(chunk, ax + dx, col_h + if centre { 1 } else { 0 }, az + dz, wx_min, wy_min, wz_min, if centre { GLOW_BLOCK } else { COBBLESTONE });
        }
    }

    let pitch_tent = |chunk: &mut C, tent_ax: i32| {
        for dz in -1..=1 {
            let base = struct_surface(tent_ax, az + dz, seed);
            struct_fill_col(chunk, tent_ax, az + dz, base + 2, seed, wx_min, wy_min, wz_min, WOOL_BLOCK);
            let fdx = if tent_ax > ax { 1 } else { -1 };
            let fbase = struct_surface(tent_ax + fdx, az + dz, seed);
            struct_fill_col(chunk, tent_ax + fdx, az + dz, fbase + 1, seed, wx_min, wy_min, wz_min, WOOL_BLOCK);
        }
    };
    pitch_tent(chunk, ax - 3);
    if (h >> 8) & 1 != 0 {
        pitch_tent(chunk, ax + 3);
    }

    {
        let r = 4;
        let gap_dz = if (h >> 9) & 1 != 0 { r } else { -r };
        for dx in -r..=r {
            for dz in -r..=r {
                let ring = dx == -r || dx == r || dz == -r || dz == r;
                if !ring {
                    continue;
                }
                if dx == 0 && dz == gap_dz {
                    continue;
                }
                let post_h = struct_surface(ax + dx, az + dz, seed) + 1;
                struct_fill_col(chunk, ax + dx, az + dz, post_h, seed, wx_min, wy_min, wz_min, WOOD_BEAM);
            }
        }
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_watchtower<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let mut base_h = -1000000;
    for dz in -1..=1 {
        for dx in -1..=1 {
            let sh = struct_surface(ax + dx, az + dz, seed);
            if sh > base_h {
                base_h = sh;
            }
        }
    }
    let tower_h = 6 + ((h >> 4) % 3) as i32;
    let top_y = base_h + tower_h;

    for dz in -1..=1 {
        for dx in -1..=1 {
            struct_fill_col(chunk, ax + dx, az + dz, top_y, seed, wx_min, wy_min, wz_min, COBBLESTONE);
        }
    }

    for dz in -1..=1 {
        for dx in -1..=1 {
            let rim = dx == -1 || dx == 1 || dz == -1 || dz == 1;
            if rim {
                struct_set(chunk, ax + dx, top_y + 1, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
                let corner = dx != 0 && dz != 0;
                if corner {
                    struct_set(chunk, ax + dx, top_y + 2, az + dz, wx_min, wy_min, wz_min, WOOD_BEAM);
                }
            }
        }
    }
    struct_set(chunk, ax, top_y + 1, az, wx_min, wy_min, wz_min, GLOW_BLOCK);

    let step_wx = ax + 2;
    let step_wz = az;
    let steps = top_y - base_h;
    for s in 1..=steps {
        let step_y = base_h + s;
        struct_fill_col(chunk, step_wx, step_wz, step_y, seed, wx_min, wy_min, wz_min, OAK_PLANKS);
        if s == steps {
            struct_set(chunk, ax + 1, top_y, az, wx_min, wy_min, wz_min, OAK_PLANKS);
        }
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_temple<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let mut plat = -1000000;
    for dz in -2..=2 {
        for dx in -2..=2 {
            let sh = struct_surface(ax + dx, az + dz, seed);
            if sh > plat {
                plat = sh;
            }
        }
    }

    for dz in -2..=2 {
        for dx in -2..=2 {
            struct_fill_col(chunk, ax + dx, az + dz, plat + 1, seed, wx_min, wy_min, wz_min, STONE_BRICK);
        }
    }

    let pil_h = 3 + ((h >> 4) & 1) as i32;
    let pillars = [
        [-2, -2],
        [2, -2],
        [-2, 2],
        [2, 2],
        [0, -2],
        [0, 2],
        [-2, 0],
        [2, 0],
    ];
    for (i, p) in pillars.iter().enumerate() {
        let px = ax + p[0];
        let pz = az + p[1];
        let ph = fmix64(h ^ ((i as u64).wrapping_mul(0x9E37).wrapping_add(11)));
        let this_h = if (ph & 0x3) == 0 { 1 + (ph & 1) as i32 } else { pil_h };
        for dy in 2..=(1 + this_h) {
            let b = if ((ph >> (dy as u32)) & 1) != 0 { MOSSY_STONE } else { STONE_BRICK };
            struct_set(chunk, px, plat + dy, pz, wx_min, wy_min, wz_min, b);
        }
    }

    for s in 1..=2 {
        let sz = az - 2 - s;
        let tread = plat + 1 - s;
        for dx in -1..=1 {
            struct_fill_col(chunk, ax + dx, sz, tread, seed, wx_min, wy_min, wz_min, STONE_BRICK);
        }
    }

    let roof_y = plat + 1 + pil_h;
    for dx in -2..=2 {
        if (fmix64(h ^ ((dx + 50) as u64)) & 0x3) != 0 {
            struct_set(chunk, ax + dx, roof_y, az - 2, wx_min, wy_min, wz_min, STONE_BRICK);
        }
    }

    struct_set(chunk, ax, plat + 2, az, wx_min, wy_min, wz_min, MOSSY_STONE);
    struct_set(chunk, ax, plat + 3, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    struct_set(chunk, ax, plat, az, wx_min, wy_min, wz_min, CHEST);

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_well<C: Chunk>(ax: i32, az: i32, _h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let big_h = struct_surface(ax, az, seed);

    for dz in -1..=1 {
        for dx in -1..=1 {
            if dx == 0 && dz == 0 {
                continue;
            }
            let col_h = struct_surface(ax + dx, az + dz, seed);
            struct_fill_col(chunk, ax + dx, az + dz, col_h + 1, seed, wx_min, wy_min, wz_min, STONE_BRICK);
        }
    }
    struct_set(chunk, ax, big_h, az, wx_min, wy_min, wz_min, WATER);

    let post_h = 3;
    let post_top = big_h + post_h;
    let corner = [[-1, -1], [1, -1], [-1, 1], [1, 1]];
    for c in corner.iter() {
        struct_fill_col(chunk, ax + c[0], az + c[1], post_top, seed, wx_min, wy_min, wz_min, WOOD_BEAM);
    }

    let roof_base = post_top + 1;
    for dz in -1..=1 {
        let ry = roof_base + if dz == 0 { 1 } else { 0 };
        for dx in -1..=1 {
            struct_set(chunk, ax + dx, ry, az + dz, wx_min, wy_min, wz_min, OAK_PLANKS);
        }
    }
    struct_set(chunk, ax, post_top, az, wx_min, wy_min, wz_min, WOOD_BEAM);
    struct_set(chunk, ax, big_h + 1, az, wx_min, wy_min, wz_min, WOOD_BEAM);
    struct_set(chunk, ax - 1, post_top, az - 1, wx_min, wy_min, wz_min, TORCH);
    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_cairn<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let big_h = struct_surface(ax, az, seed);
    let cairn_h = 3 + ((h >> 4) & 0x3) as i32;

    for dz in -1..=1 {
        for dx in -1..=1 {
            let bh = fmix64(h ^ (((dx + 2) * 7 + (dz + 2) * 31) as u64));
            let b = if bh & 1 != 0 { MOSSY_STONE } else { STONE };
            let base_top = struct_surface(ax + dx, az + dz, seed) + 1;
            struct_fill_col(chunk, ax + dx, az + dz, base_top, seed, wx_min, wy_min, wz_min, b);
        }
    }
    for dy in 2..=cairn_h {
        let b = if ((h >> ((dy as u32) + 8)) & 1) != 0 { MOSSY_STONE } else { STONE };
        struct_set(chunk, ax, big_h + dy, az, wx_min, wy_min, wz_min, b);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_hut<C: Chunk>(cx: i32, cz: i32, hh: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let mut floor_h = -1000000;
    for dz in -1..=1 {
        for dx in -1..=1 {
            let sh = struct_surface(cx + dx, cz + dz, seed);
            if sh > floor_h {
                floor_h = sh;
            }
        }
    }
    let cobble = (hh & 1) != 0;
    let wall = if cobble { COBBLESTONE } else { OAK_PLANKS };
    let wall_h = 2;
    let wall_top = floor_h + wall_h;

    for dz in -1..=1 {
        for dx in -1..=1 {
            struct_fill_col(chunk, cx + dx, cz + dz, floor_h, seed, wx_min, wy_min, wz_min, OAK_PLANKS);
        }
    }

    let dir = ((hh >> 1) & 0x3) as i32;
    let door_dx = if dir == 0 {
        1
    } else if dir == 1 {
        -1
    } else {
        0
    };
    let door_dz = if dir == 2 {
        1
    } else if dir == 3 {
        -1
    } else {
        0
    };

    for dz in -1..=1 {
        for dx in -1..=1 {
            let ring = dx == -1 || dx == 1 || dz == -1 || dz == 1;
            if !ring {
                continue;
            }
            if dx == door_dx && dz == door_dz {
                struct_set(chunk, cx + dx, floor_h + 1, cz + dz, wx_min, wy_min, wz_min, OAK_DOOR);
                continue;
            }
            let window = dx == -door_dx && dz == -door_dz;
            for wy in (floor_h + 1)..=wall_top {
                let b = if window && wy == floor_h + 1 { GLASS_PANE } else { wall };
                struct_set(chunk, cx + dx, wy, cz + dz, wx_min, wy_min, wz_min, b);
            }
        }
    }
    for dz in -1..=1 {
        for dx in -1..=1 {
            struct_set(chunk, cx + dx, wall_top + 1, cz + dz, wx_min, wy_min, wz_min, if cobble { STONE_BRICK } else { BIRCH_PLANKS });
        }
    }
    struct_set(chunk, cx, floor_h + 1, cz, wx_min, wy_min, wz_min, GLOW_BLOCK);
}

fn place_village<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    for dz in -1..=1 {
        for dx in -1..=1 {
            let col_h = struct_surface(ax + dx, az + dz, seed);
            let centre = dx == 0 && dz == 0;
            struct_set(chunk, ax + dx, col_h + if centre { 1 } else { 0 }, az + dz, wx_min, wy_min, wz_min, if centre { GLOW_BLOCK } else { COBBLESTONE });
        }
    }

    let huts = [[-6, -4], [6, 4], [0, 6], [-6, 4], [6, -4]];
    let n_huts = if (h >> 10) & 1 != 0 { 5 } else { 4 };
    for i in 0..n_huts {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x2545F4914F6CDD1D).wrapping_add(71)));
        place_hut(ax + huts[i][0], az + huts[i][1], hh, seed, chunk, wx_min, wy_min, wz_min);
        let pdx = if huts[i][0] > 0 {
            2
        } else if huts[i][0] < 0 {
            -2
        } else {
            0
        };
        let pdz = if huts[i][1] > 0 {
            2
        } else if huts[i][1] < 0 {
            -2
        } else {
            0
        };
        let ph = struct_surface(ax + pdx, az + pdz, seed);
        struct_set(chunk, ax + pdx, ph, az + pdz, wx_min, wy_min, wz_min, COBBLESTONE);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_shrine<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let ring = [
        [-3, 0],
        [3, 0],
        [0, -3],
        [0, 3],
        [-3, -3],
        [3, -3],
        [-3, 3],
        [3, 3],
    ];
    for (i, r) in ring.iter().enumerate() {
        let sh = fmix64(h ^ ((i as u64).wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(17)));
        let stone_h = 2 + (sh & 1) as i32;
        let sx = ax + r[0];
        let sz = az + r[1];
        let top = struct_surface(sx, sz, seed) + stone_h;
        let b = if sh & 2 != 0 { MOSSY_STONE } else { STONE };
        struct_fill_col(chunk, sx, sz, top, seed, wx_min, wy_min, wz_min, b);
        if (sh & 0x3) == 0 {
            struct_set(chunk, sx, top + 1, sz, wx_min, wy_min, wz_min, STONE_BRICK);
        }
    }

    let big_h = struct_surface(ax, az, seed);
    struct_fill_col(chunk, ax, az, big_h + 1, seed, wx_min, wy_min, wz_min, STONE_BRICK);
    struct_set(chunk, ax, big_h + 2, az, wx_min, wy_min, wz_min, MOSSY_STONE);
    struct_set(chunk, ax, big_h + 3, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_structure<C: Chunk>(sd: &StructDesc, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    match sd.typ {
        x if x == STRUCT_CABIN => place_cabin(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_OBELISK => place_obelisk(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_CAMP => place_camp(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_WATCHTOWER => place_watchtower(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_TEMPLE => place_temple(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_WELL => place_well(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_CAIRN => place_cairn(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_VILLAGE => place_village(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_SHRINE => place_shrine(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// Deadwood (#22)
// ---------------------------------------------------------------------------
const DEADWOOD_CELL: i32 = 12;
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
    let h = hash2(dcx, dcz, dseed);

    if (h & 0xFF) >= 40 {
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
    let cave = fbm3(wx as f32, wy as f32, wz as f32, fmix64(seed ^ 0xCA4E5EED1234), 3, 1.0 / 16.0);
    cave > CAVE_THRESH
}

fn cave_voxel_is_solid(wx: i32, wy: i32, wz: i32, seed: u64) -> bool {
    let h = cave_surface_h(wx, wz, seed);
    if wy > h {
        return false;
    }
    !cave_voxel_is_air(wx, wy, wz, seed)
}

const CAVE_FEAT_CELL: i32 = 9;
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
                let h = hash3(cx, cy, cz, fseed);
                let roll = h & 0xFF;
                if roll >= 56 {
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

include!("worldgen_part4.rs");
