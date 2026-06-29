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
// New bigger / varied structures (#variety work).
const STRUCT_TALL_TOWER: i32 = 10; // a tall intact tower (mage-tower style)
const STRUCT_KEEP: i32 = 11; // a small keep / castle (walls + a few rooms)
const STRUCT_RUIN: i32 = 12; // a ruined keep / tower, broken walls, holds baddies
const STRUCT_CITY: i32 = 13; // a larger settlement cluster (town / city)

// Share of would-be villages (low byte 0..256) that grow into a city. Cities are the
// only settlement that hosts the full profession chain, so they need to be findable in
// normal exploration; settlements are already a small slice of all structures, so this
// only lifts cities to "reliably encountered", not "everywhere".
const STRUCT_CITY_UPGRADE_THRESH: u64 = 150;

// Largest structure footprint reaches out from its anchor by this many blocks in
// X and Z. The placement loop scans every structure cell within this reach of a
// chunk so a structure spanning a chunk border is stamped identically into both
// chunks (seam safe). Must be >= the biggest structure half-extent below: the city
// is the widest (huts on a ring out to +/-18 plus a villager-home radius of up to 3,
// so ~21; the bare cross-road cobble runs to 22 but those are single blocks). 26
// leaves headroom over the 21 footprint reach so a home is never clipped at a border.
const STRUCT_MAX_REACH_XZ: i32 = 26;

#[derive(Clone, Copy)]
struct StructDesc {
    anchor_wx: i32,
    anchor_wz: i32,
    typ: i32,
    cell_hash: u64,
    present: bool,
}

// True for the ruined structure type, which the creature system treats as a
// localized "danger site" (spawns a hostile or two regardless of the night/quest
// gate). Kept here so the rule lives in one place.
#[inline]
fn struct_is_ruin(typ: i32) -> bool {
    typ == STRUCT_RUIN
}

// Half extent (in blocks, from the anchor) of a structure type's solid footprint.
// Used to carve a no-tree clearance zone around placed structures so trunks and
// canopies do not punch through walls or roofs (#143). Values track the widest
// block each place_* builder stamps from its anchor (roof eaves / outer hut rings
// / cross roads included), so the clearance fully covers the building.
#[inline]
fn struct_footprint_reach(typ: i32) -> i32 {
    match typ {
        x if x == STRUCT_CABIN => 4,       // hx up to 3, roof eaves reach hx + 1
        x if x == STRUCT_OBELISK => 2,
        x if x == STRUCT_CAMP => 1,
        x if x == STRUCT_WATCHTOWER => 2,  // body 1, stairs reach +2
        x if x == STRUCT_TEMPLE => 3,
        x if x == STRUCT_CAIRN => 1,
        x if x == STRUCT_WELL => 1,
        x if x == STRUCT_VILLAGE => 9,     // huts on a +/-6 ring + hut radius 3
        x if x == STRUCT_SHRINE => 3,
        x if x == STRUCT_TALL_TOWER => 2,
        x if x == STRUCT_KEEP => 4,        // curtain wall + turrets at +/-4
        x if x == STRUCT_RUIN => 4,
        x if x == STRUCT_CITY => 22,       // outer hut ring +/-18 + radius, cross roads to 22
        _ => 0,
    }
}

// Extra clearance, beyond the structure footprint, that must stay tree free. Chosen
// to clear a typical canopy (CANOPY_MAX_REACH_XZ = 4) plus a block of breathing room
// so leaves never brush a wall or roof. A tree is excluded when its root falls within
// (footprint reach + this margin) of a structure anchor on either axis.
const STRUCT_TREE_CLEARANCE: i32 = CANOPY_MAX_REACH_XZ + 2;

// True if a tree rooted at (root_wx, root_wz) would fall inside the no-tree clearance
// zone of any nearby structure. Structures live on a STRUCT_CELL_SIZE grid with at
// most one per cell; the largest footprint + clearance is far under one cell, so it
// is enough to test the structure cell containing the root and its 8 neighbours. Pure
// function of (root, seed): determinism is preserved.
fn tree_blocked_by_structure(root_wx: i32, root_wz: i32, seed: u64) -> bool {
    let base_cx = struct_floordiv(root_wx, STRUCT_CELL_SIZE);
    let base_cz = struct_floordiv(root_wz, STRUCT_CELL_SIZE);
    for dcz in -1..=1 {
        for dcx in -1..=1 {
            let sd = struct_for_cell(base_cx + dcx, base_cz + dcz, seed);
            if !sd.present {
                continue;
            }
            let clear = struct_footprint_reach(sd.typ) + STRUCT_TREE_CLEARANCE;
            let dx = (root_wx - sd.anchor_wx).abs();
            let dz = (root_wz - sd.anchor_wz).abs();
            if dx <= clear && dz <= clear {
                return true;
            }
        }
    }
    false
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
    // Keep structures out of open water. Require the anchor column to sit clearly on
    // land: a margin above sea level (not at the waterline), and not on an ocean or
    // river column (continentalness / river-channel fields). Oceans + rivers were
    // added after the original structure system, so this gate is what keeps the new
    // bigger structures (and the old ones) from spawning in the sea.
    if h <= SEA_LEVEL + 1
        || is_ocean_column(ax as f32, az as f32, seed)
        || river_channel_t(ax as f32, az as f32, seed) > 0.4
    {
        return StructDesc { anchor_wx: 0, anchor_wz: 0, typ: STRUCT_NONE, cell_hash: 0, present: false };
    }

    // Big / rare structures. A minority of present cells become a large structure
    // (a tall tower, a small keep, or a ruin) instead of the usual biome pick. They
    // are rarer than the small buildings: only when this byte is low. The split
    // among the three big types is driven by a separate slice of the hash so the
    // choice is stable per cell and deterministic.
    // Big structures (9x9 footprint, half extent 4). Each one levels its footprint
    // with a per-column foundation that fills the slope gap down to every column's
    // own terrain (see place_tall_tower / place_keep / place_ruin), so they sit flush
    // on the ground on a slope instead of floating (#108). We deliberately do NOT
    // reject sloped sites here: the foundation fill makes any site safe, and gating
    // on slope would change which cells become big structures (breaking the
    // structure-placement contract other systems / tests rely on).
    let big_roll = (h2s >> 48) & 0xFF;
    if big_roll < 36 {
        let big_pick = (h2s >> 40) & 0x3;
        let stype = match big_pick {
            0 => STRUCT_TALL_TOWER,
            1 => STRUCT_KEEP,
            // Two of four buckets are ruins so danger sites are reasonably common
            // among the big structures (about half of them).
            _ => STRUCT_RUIN,
        };
        return StructDesc { anchor_wx: ax, anchor_wz: az, typ: stype, cell_hash: h2s, present: true };
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

    // City clustering: a good share of would-be villages grow into a larger town /
    // city (more buildings, a denser layout with a center and simple paths). The roll
    // is a stable per-cell hash slice so the same cell is always a city or always a
    // village for a given seed. The city's buildings (huts / cabins) each carry their
    // own foundation fill, so a city also conforms to sloped ground without floating.
    //
    // Settlements (village + city) are themselves a small slice of all structures, so
    // a low upgrade rate left cities far too rare to stumble onto in normal play (the
    // player found plenty of structures but no city). Raising the cutoff to 150/256
    // (~59% of would-be villages) roughly triples the city count without carpeting the
    // world: cities still trail behind the many big structures and the remaining
    // villages, so finding one stays a moment. See STRUCT_CITY_UPGRADE_THRESH.
    let stype = if stype == STRUCT_VILLAGE && ((h2s >> 56) & 0xFF) < STRUCT_CITY_UPGRADE_THRESH {
        STRUCT_CITY
    } else {
        stype
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

    // Door torch: mount it on the interior face of the door wall, just beside the
    // doorway, instead of floating in the open lintel gap above the door (the door
    // column is left open from floor + 3 up, so a torch placed there would hang on
    // nothing). We put it in the interior air cell one block in from the wall, next
    // to the door, with the solid wall block at (door wall plane, that dz) directly
    // behind it. The flanking wall cell stays solid (no hole punched), so the torch
    // reads as wall mounted inside the cabin.
    //
    // A flanking wall cell is glass at floor + 2 only when it is a window slot
    // ((dx + dz) even). We choose a dz whose flanking wall is solid at the torch
    // height: prefer dz = -1, fall back to +1, and if both flanking cells are window
    // slots at eye height drop the torch to floor + 1 where the wall is always solid.
    let door_solid_at = |dz: i32, wy: i32| -> bool {
        let is_window = ((door_dx + dz) & 1) == 0;
        !(is_window && wy == floor_h + 2)
    };
    let (torch_dz, torch_wy) = if door_solid_at(-1, floor_h + 2) {
        (-1, floor_h + 2)
    } else if door_solid_at(1, floor_h + 2) {
        (1, floor_h + 2)
    } else {
        (-1, floor_h + 1)
    };
    struct_set(chunk, ax + door_dx - door_dx.signum(), torch_wy, az + torch_dz, wx_min, wy_min, wz_min, TORCH);
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

// A villager home: a real little building with an interior you can stand in, not
// the old empty 3x3 box. The footprint is at least 5x5 (half extent 2) and may be
// 5x6 or 6x6 for variety, which always leaves an interior cavity of at least 3x3 of
// air. Each home has a 1 wide door, at least two windows, a flat roof, and basic
// furniture (a bed plus a light), with the centre floor left open for future chests
// / crafting tables.
//
// All blocks go through struct_set / struct_fill_col so a home spanning a chunk
// border stamps identically into every chunk it touches (seam safe), and every
// column's foundation fills down to its own terrain so the home sits flush on a
// slope (no floaters). Everything is derived from (cx, cz, hh) so generation is
// deterministic per cell. Max XZ half extent is 3 (rx / rz <= 3), well within
// STRUCT_MAX_REACH_XZ.
fn place_hut<C: Chunk>(cx: i32, cz: i32, hh: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    // Footprint half extents: 2 (5 wide) or 3 (6 wide) on each axis, varied per home.
    let rx = 2 + ((hh >> 5) & 1) as i32; // 2 or 3 -> 5 or 6 wide in X
    let rz = 2 + ((hh >> 6) & 1) as i32; // 2 or 3 -> 5 or 6 wide in Z

    // Foundation reference: the highest terrain column under the footprint so the
    // floor is level; per column we still fill the gap down to that column's own
    // terrain so the home conforms to a slope without floating.
    let mut floor_h = -1000000;
    for dz in -rz..=rz {
        for dx in -rx..=rx {
            let sh = struct_surface(cx + dx, cz + dz, seed);
            if sh > floor_h {
                floor_h = sh;
            }
        }
    }

    // Material palette varies per home so a village does not look stamped from one
    // mould: timber, cobble, stone, or birch shells, each with a matching roof.
    let palette = (hh >> 2) & 0x3;
    let (wall, roof) = match palette {
        0 => (OAK_PLANKS, BIRCH_PLANKS),
        1 => (COBBLESTONE, STONE_BRICK),
        2 => (STONE_BRICK, COBBLESTONE),
        _ => (BIRCH_PLANKS, OAK_PLANKS),
    };

    // Walls are 3 tall so the interior is a genuine 2 high standable cavity with a
    // block of headroom above the door.
    let wall_h = 3;
    let wall_top = floor_h + wall_h;

    // Plank floor: fill each column from its terrain up to the floor level.
    for dz in -rz..=rz {
        for dx in -rx..=rx {
            struct_fill_col(chunk, cx + dx, cz + dz, floor_h, seed, wx_min, wy_min, wz_min, OAK_PLANKS);
        }
    }

    // Door wall: 0 = +X, 1 = -X, 2 = +Z, 3 = -Z. The door sits in the middle of
    // that wall (offset 0 along the wall), so the opening is always flanked by wall.
    let dir = ((hh >> 1) & 0x3) as i32;

    // Build the four walls. A wall cell is on the perimeter ring of the footprint.
    for dz in -rz..=rz {
        for dx in -rx..=rx {
            let on_x_edge = dx == -rx || dx == rx;
            let on_z_edge = dz == -rz || dz == rz;
            if !on_x_edge && !on_z_edge {
                continue; // interior column, leave as air above the floor
            }

            // Is this the single door cell? The door is centred on the chosen wall.
            let is_door = match dir {
                0 => dx == rx && dz == 0,
                1 => dx == -rx && dz == 0,
                2 => dz == rz && dx == 0,
                _ => dz == -rz && dx == 0,
            };

            // Windows: the centre cell of each non door wall gets a glass pane at
            // eye height. This yields at least two windows on every home (the three
            // walls without the door), more on the longer walls of a rectangular
            // home where a second centre-ish cell also qualifies.
            let is_window_center = !is_door
                && ((on_x_edge && dz == 0 && !on_z_edge) || (on_z_edge && dx == 0 && !on_x_edge));
            // Extra windows on longer walls so a 6 wide wall is not blank.
            let is_window_side = !is_door
                && ((on_x_edge && !on_z_edge && (dz == -1 || dz == 1) && rz == 3)
                    || (on_z_edge && !on_x_edge && (dx == -1 || dx == 1) && rx == 3));

            for wy in (floor_h + 1)..=wall_top {
                let local = wy - floor_h; // 1 at the base, wall_h at the top
                if is_door && local <= 2 {
                    // Two tall door opening; the cell above (local 3) stays wall as a lintel.
                    struct_set(chunk, cx + dx, wy, cz + dz, wx_min, wy_min, wz_min, OAK_DOOR);
                    continue;
                }
                let is_glass = (is_window_center || is_window_side) && local == 2;
                let b = if is_glass { GLASS_PANE } else { wall };
                struct_set(chunk, cx + dx, wy, cz + dz, wx_min, wy_min, wz_min, b);
            }
        }
    }

    // Flat roof one block above the wall top covering the whole footprint.
    for dz in -rz..=rz {
        for dx in -rx..=rx {
            struct_set(chunk, cx + dx, wall_top + 1, cz + dz, wx_min, wy_min, wz_min, roof);
        }
    }

    // ---- Interior furnishing -------------------------------------------------
    // Place a bed in a back corner (the corner diagonally opposite the door) so it
    // never blocks the doorway, and leave the centre of the floor open for future
    // chests / crafting tables. The bed is two cells (head + foot) laid along a
    // wall, both sitting on the floor (local y = floor_h + 1).
    let bed_y = floor_h + 1;
    // Back corner interior cell coordinates (one block in from the walls).
    let ix = rx - 1; // interior extent in X
    let iz = rz - 1; // interior extent in Z
    // Pick the corner away from the door wall.
    let (bcx, bcz) = match dir {
        0 => (-ix, -iz), // door +X -> bed at -X,-Z
        1 => (ix, iz),   // door -X -> bed at +X,+Z
        2 => (-ix, -iz), // door +Z -> bed at -X,-Z
        _ => (ix, iz),   // door -Z -> bed at +X,+Z
    };
    // Lay the bed along the longer interior axis so the two cells stay inside.
    let (bed_dx, bed_dz) = if ix >= iz { (if bcx >= 0 { -1 } else { 1 }, 0) } else { (0, if bcz >= 0 { -1 } else { 1 }) };
    struct_set(chunk, cx + bcx, bed_y, cz + bcz, wx_min, wy_min, wz_min, BED);
    struct_set(chunk, cx + bcx + bed_dx, bed_y, cz + bcz + bed_dz, wx_min, wy_min, wz_min, BED);

    // A light source: a glow block at the centre of the ceiling (top interior layer)
    // so it lights the whole room and stays clear of the open floor and the bed.
    struct_set(chunk, cx, wall_top, cz, wx_min, wy_min, wz_min, GLOW_BLOCK);
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

// A tall intact tower: a 5x5 stone-brick keep base topped by a slimmer 3x3 shaft
// that climbs ~13 to 19 blocks, with a battlemented crown and a lamp at the top.
// Bigger and clearly taller than the watchtower. Max XZ half-extent is 2 (well
// within STRUCT_MAX_REACH_XZ).
fn place_tall_tower<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    // Foundation: take the highest column under the 5x5 footprint so the tower sits
    // on the ground no matter the slope (then we fill any gap below each column).
    let mut base_h = -1000000;
    for dz in -2..=2 {
        for dx in -2..=2 {
            let sh = struct_surface(ax + dx, az + dz, seed);
            if sh > base_h {
                base_h = sh;
            }
        }
    }

    let shaft_h = 13 + ((h >> 4) % 7) as i32; // 13..19 tall
    let top_y = base_h + shaft_h;

    // Solid 5x5 plinth one block tall, filling any slope gap below.
    for dz in -2..=2 {
        for dx in -2..=2 {
            struct_fill_col(chunk, ax + dx, az + dz, base_h, seed, wx_min, wy_min, wz_min, STONE);
            struct_set(chunk, ax + dx, base_h + 1, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
        }
    }

    // 3x3 hollow shaft of stone brick from base+2 up to top_y.
    for wy in (base_h + 2)..=top_y {
        for dz in -1..=1 {
            for dx in -1..=1 {
                let wall = dx == -1 || dx == 1 || dz == -1 || dz == 1;
                if wall {
                    struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
                } else {
                    // Hollow interior; carve to air so the tower is enterable.
                    struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, AIR);
                }
            }
        }
    }

    // Doorway on the south face at the base of the shaft.
    struct_set(chunk, ax, base_h + 2, az - 1, wx_min, wy_min, wz_min, OAK_DOOR);
    struct_set(chunk, ax, base_h + 3, az - 1, wx_min, wy_min, wz_min, OAK_DOOR);

    // Slit windows partway up.
    let mid = base_h + 2 + shaft_h / 2;
    struct_set(chunk, ax + 1, mid, az, wx_min, wy_min, wz_min, GLASS_PANE);
    struct_set(chunk, ax - 1, mid, az, wx_min, wy_min, wz_min, GLASS_PANE);

    // Crenellated crown: a ring of cobble one above the top, alternating merlons.
    for dz in -1..=1 {
        for dx in -1..=1 {
            let rim = dx == -1 || dx == 1 || dz == -1 || dz == 1;
            if !rim {
                continue;
            }
            struct_set(chunk, ax + dx, top_y + 1, az + dz, wx_min, wy_min, wz_min, COBBLESTONE);
            let corner = dx != 0 && dz != 0;
            if corner {
                struct_set(chunk, ax + dx, top_y + 2, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
            }
        }
    }
    // Beacon at the very top so the tower reads from a distance.
    struct_set(chunk, ax, top_y + 1, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    struct_set(chunk, ax, base_h + 2, az, wx_min, wy_min, wz_min, GLOW_BLOCK);

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// A small keep / castle: a square stone-brick curtain wall (9x9 footprint, half
// extent 4) with a corner turret on each corner, a gated south wall, and a small
// inner hall. Max XZ half-extent is 4.
fn place_keep<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let mut base_h = -1000000;
    for dz in -4..=4 {
        for dx in -4..=4 {
            let sh = struct_surface(ax + dx, az + dz, seed);
            if sh > base_h {
                base_h = sh;
            }
        }
    }

    let r = 4;
    let wall_h = 4 + ((h >> 4) & 1) as i32; // 4 or 5 tall, varied per cell
    let wall_top = base_h + wall_h;

    // Levelled courtyard floor.
    for dz in -r..=r {
        for dx in -r..=r {
            struct_fill_col(chunk, ax + dx, az + dz, base_h, seed, wx_min, wy_min, wz_min, COBBLESTONE);
        }
    }

    // Curtain wall around the perimeter with a south gate (2 wide) at dz = -r.
    for dz in -r..=r {
        for dx in -r..=r {
            let on_x = dx == -r || dx == r;
            let on_z = dz == -r || dz == r;
            if !(on_x || on_z) {
                continue;
            }
            let corner = on_x && on_z;
            let gate = dz == -r && (dx == 0 || dx == -1);
            for wy in (base_h + 1)..=wall_top {
                if gate && wy <= base_h + 2 {
                    continue; // gate opening
                }
                struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
            }
            // Crenellation row on the wall top (skip every other cell).
            if !corner && ((dx + dz) & 1) == 0 {
                struct_set(chunk, ax + dx, wall_top + 1, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
            }
        }
    }

    // Corner turrets, two blocks taller than the wall.
    let turret = [[-r, -r], [r, -r], [-r, r], [r, r]];
    for t in turret.iter() {
        for wy in (base_h + 1)..=(wall_top + 2) {
            struct_set(chunk, ax + t[0], wy, az + t[1], wx_min, wy_min, wz_min, STONE_BRICK);
        }
        struct_set(chunk, ax + t[0], wall_top + 3, az + t[1], wx_min, wy_min, wz_min, COBBLESTONE);
    }

    // Inner hall: a 3x3 room at the keep center with a door and a roof.
    let hall = 1;
    let hall_top = base_h + 4;
    for dz in -hall..=hall {
        for dx in -hall..=hall {
            let on_x = dx == -hall || dx == hall;
            let on_z = dz == -hall || dz == hall;
            let is_door = dz == -hall && dx == 0;
            if on_x || on_z {
                for wy in (base_h + 1)..=hall_top {
                    if is_door && wy <= base_h + 2 {
                        struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, OAK_DOOR);
                    } else {
                        struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
                    }
                }
            }
            // Flat roof over the hall.
            struct_set(chunk, ax + dx, hall_top + 1, az + dz, wx_min, wy_min, wz_min, OAK_PLANKS);
        }
    }
    struct_set(chunk, ax, base_h + 1, az, wx_min, wy_min, wz_min, CHEST);
    struct_set(chunk, ax, base_h + 2, az, wx_min, wy_min, wz_min, GLOW_BLOCK);
    // Gate torches: mount them on the interior face of the gate wall, one cell in
    // from the wall row (dz = -r + 1), against the solid wall sections that flank
    // the 2 wide gate opening (which spans dx = 0 and dx = -1). Placing them at
    // dx = +1 and dx = -2 puts each torch in courtyard air with a solid curtain
    // wall block directly behind it at dz = -r, so the wall stays intact (no hole
    // punched behind a torch) and the torch reads as wall mounted.
    struct_set(chunk, ax + 1, base_h + 3, az - r + 1, wx_min, wy_min, wz_min, TORCH);
    struct_set(chunk, ax - 2, base_h + 3, az - r + 1, wx_min, wy_min, wz_min, TORCH);

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// A ruined keep / tower: like the keep but broken. Walls are partial (random gaps),
// some blocks are missing, mossy stone and rubble replace clean brick, and a bit of
// overgrowth (mushrooms / mossy rubble) sits inside. This type is marked as a danger
// site so the creature system spawns a hostile or two near it. Half extent 4.
fn place_ruin<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let mut base_h = -1000000;
    for dz in -4..=4 {
        for dx in -4..=4 {
            let sh = struct_surface(ax + dx, az + dz, seed);
            if sh > base_h {
                base_h = sh;
            }
        }
    }

    let r = 4;
    // Per-column rubble floor at the LEVELLED base height, with a foundation that
    // fills the slope gap down to each column's own terrain so nothing floats on a
    // hillside (#108). The floor still has random holes for the ruined look, but a
    // hole only removes the top floor block: the foundation underneath stays so the
    // wall/pillar columns above it always rest on solid ground.
    for dz in -r..=r {
        for dx in -r..=r {
            // Fill from this column's terrain up to just below the levelled floor.
            struct_fill_col(chunk, ax + dx, az + dz, base_h - 1, seed, wx_min, wy_min, wz_min, COBBLESTONE);
            let fh = fmix64(h ^ (((dx + 9) * 131 + (dz + 9) * 17) as u64));
            if (fh & 0x7) == 0 {
                continue; // a hole in the floor surface (foundation below remains)
            }
            let b = if fh & 0x10 != 0 { MOSSY_STONE } else { COBBLESTONE };
            struct_set(chunk, ax + dx, base_h, az + dz, wx_min, wy_min, wz_min, b);
        }
    }

    // Broken curtain wall: each perimeter column rises to a random ragged height
    // (0..wall_h) on top of the levelled base, so the wall is full of gaps and
    // looks collapsed but is anchored to the filled foundation (never floats).
    let wall_h = 4;
    for dz in -r..=r {
        for dx in -r..=r {
            let on_x = dx == -r || dx == r;
            let on_z = dz == -r || dz == r;
            if !(on_x || on_z) {
                continue;
            }
            let wh = fmix64(h ^ (((dx + 20) * 73 + (dz + 20) * 911) as u64));
            let rise = (wh % (wall_h as u64 + 1)) as i32; // 0..wall_h
            let corner = on_x && on_z;
            // Corners stand a touch taller (broken turret stubs).
            let rise = if corner { (rise + 2).min(wall_h + 2) } else { rise };
            for wy in 1..=rise {
                let b = if (wh >> (wy as u32 + 4)) & 1 != 0 { MOSSY_STONE } else { STONE_BRICK };
                struct_set(chunk, ax + dx, base_h + wy, az + dz, wx_min, wy_min, wz_min, b);
            }
        }
    }

    // A broken inner stub: a couple of standing pillars and toppled rubble.
    let pillars = [[-2, 2], [2, -2], [1, 1]];
    for (i, p) in pillars.iter().enumerate() {
        let ph = fmix64(h ^ ((i as u64).wrapping_mul(0x9E37).wrapping_add(5)));
        let ph_top = base_h + 1 + (ph % 4) as i32;
        for wy in (base_h + 1)..=ph_top {
            let b = if (ph >> (wy as u32)) & 1 != 0 { MOSSY_STONE } else { STONE_BRICK };
            struct_set(chunk, ax + p[0], wy, az + p[1], wx_min, wy_min, wz_min, b);
        }
    }

    // Overgrowth + a hint of treasure inside the ruin.
    struct_set(chunk, ax, base_h + 1, az, wx_min, wy_min, wz_min, MUSHROOM);
    struct_set(chunk, ax - 1, base_h + 1, az, wx_min, wy_min, wz_min, MOSSY_STONE);
    if (h >> 33) & 1 != 0 {
        struct_set(chunk, ax + 1, base_h + 1, az - 1, wx_min, wy_min, wz_min, CHEST);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// A city: a scaled-up village. A central plaza (paved, lamp-lit well at its core)
// with simple cross roads, ringed by many huts on two rings plus a couple of bigger
// cabins. Reuses place_hut / place_cabin for the buildings. Widest hut ring is at
// +/-18 and a villager home reaches up to 3 from its centre, so the home footprint
// extent is ~21, under STRUCT_MAX_REACH_XZ (26).
fn place_city<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    // Paved central plaza, 5x5, with a marker / lamp core.
    for dz in -2..=2 {
        for dx in -2..=2 {
            let col_h = struct_surface(ax + dx, az + dz, seed);
            let centre = dx == 0 && dz == 0;
            let b = if centre { GLOW_BLOCK } else { STONE_BRICK };
            struct_set(chunk, ax + dx, col_h + if centre { 1 } else { 0 }, az + dz, wx_min, wy_min, wz_min, b);
        }
    }

    // Simple cross roads of cobblestone radiating from the plaza out to the rings.
    for d in 3..=22 {
        for &(sx, sz) in &[(d, 0), (-d, 0), (0, d), (0, -d)] {
            let col_h = struct_surface(ax + sx, az + sz, seed);
            struct_set(chunk, ax + sx, col_h, az + sz, wx_min, wy_min, wz_min, COBBLESTONE);
        }
    }

    // Inner ring of huts.
    let inner = [[-8, -6], [8, 6], [0, 9], [9, -6], [-9, 6], [-8, 0], [8, -1]];
    for (i, hpos) in inner.iter().enumerate() {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x2545F4914F6CDD1D).wrapping_add(71)));
        place_hut(ax + hpos[0], az + hpos[1], hh, seed, chunk, wx_min, wy_min, wz_min);
    }

    // Outer ring: more huts plus two bigger cabins as "town hall" style anchors.
    let outer = [[-16, -12], [16, 12], [-16, 12], [16, -12], [0, 18], [0, -18], [18, 0], [-18, 0]];
    for (i, hpos) in outer.iter().enumerate() {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(131)));
        if i < 2 {
            place_cabin(ax + hpos[0], az + hpos[1], hh, seed, chunk, wx_min, wy_min, wz_min);
        } else {
            place_hut(ax + hpos[0], az + hpos[1], hh, seed, chunk, wx_min, wy_min, wz_min);
        }
    }

    // A well at the plaza edge for flavour.
    place_well(ax + 3, az + 3, h, seed, chunk, wx_min, wy_min, wz_min);

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
        x if x == STRUCT_TALL_TOWER => place_tall_tower(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_KEEP => place_keep(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_RUIN => place_ruin(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_CITY => place_city(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
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
