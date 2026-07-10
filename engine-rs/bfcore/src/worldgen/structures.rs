// ===========================================================================
// Structure selection, settlement layout, and structure stamping.
// ===========================================================================

// ---------------------------------------------------------------------------
// Structure system
// ---------------------------------------------------------------------------
const STRUCT_CELL_SIZE: i32 = 64; // divides WORLD_PERIOD (512 cells across the torus)
const STRUCT_CELL_COUNT: i32 = WORLD_PERIOD / STRUCT_CELL_SIZE; // 512
const STRUCT_SEED_MIX: u64 = 0x57AC7EDEDBEF5717;
const MARKER_BLOCK: BlockId = 34;
const STRUCT_PROB_THRESH: u64 = 128;
const STRUCT_ANCHOR_MIN_OFFSET: i32 = 7;
const STRUCT_ANCHOR_OFFSET_CHOICES: i32 = 50;
const STRUCT_ANCHOR_OFFSET_SPAN: i32 = STRUCT_ANCHOR_OFFSET_CHOICES - 1;

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

// #222: settlement thinning. Structure cells are 64 blocks wide, so a 500-block
// spacing rule is roughly eight structure cells. Cities get a wider city-vs-city
// exclusion zone so they do not cluster into the same nearby biome patch.
const SETTLEMENT_MIN_SPACING_BLOCKS: i32 = 500;
const CITY_MIN_SPACING_BLOCKS: i32 = 768;
const SETTLEMENT_SPACING_SCAN_CELLS: i32 = CITY_MIN_SPACING_BLOCKS / STRUCT_CELL_SIZE + 2;

const SETTLEMENT_SITE_JITTER: i32 = 3;
const SETTLEMENT_BUILDING_REACH: i32 = 4;
const SETTLEMENT_MAX_SITES: usize = 15;
const VILLAGE_MIN_BUILDINGS: usize = 5;
const VILLAGE_MAX_BUILDINGS: usize = 7;
const VILLAGE_SITE_MIN_RADIUS: i32 = 20;
const VILLAGE_SITE_RADIUS_SPAN: i32 = 18;
const VILLAGE_LAYOUT_REACH: i32 =
    VILLAGE_SITE_MIN_RADIUS + VILLAGE_SITE_RADIUS_SPAN + SETTLEMENT_SITE_JITTER + SETTLEMENT_BUILDING_REACH;
const CITY_MIN_BUILDINGS: usize = 12;
const CITY_MAX_BUILDINGS: usize = SETTLEMENT_MAX_SITES;
const CITY_SITE_MIN_RADIUS: i32 = 16;
const CITY_SITE_RADIUS_SPAN: i32 = 28;
const CITY_LAYOUT_REACH: i32 =
    CITY_SITE_MIN_RADIUS + CITY_SITE_RADIUS_SPAN + SETTLEMENT_SITE_JITTER + SETTLEMENT_BUILDING_REACH;

// Largest structure footprint reaches out from its anchor by this many blocks in
// X and Z. The placement loop scans every structure cell within this reach of a
// chunk so a structure spanning a chunk border is stamped identically into both
// chunks (seam safe). Must be >= the biggest structure half-extent below: the city
// and the procedural city layout are the widest. Keep this tied to layout constants
// so chunk-border stamping follows future settlement-size tweaks.
const STRUCT_MAX_REACH_XZ: i32 = CITY_LAYOUT_REACH;

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

#[inline]
fn struct_is_settlement(typ: i32) -> bool {
    typ == STRUCT_VILLAGE || typ == STRUCT_CITY
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
        x if x == STRUCT_VILLAGE => VILLAGE_LAYOUT_REACH,
        x if x == STRUCT_SHRINE => 3,
        x if x == STRUCT_TALL_TOWER => 2,
        x if x == STRUCT_KEEP => 4,        // curtain wall + turrets at +/-4
        x if x == STRUCT_RUIN => 4,
        x if x == STRUCT_CITY => CITY_LAYOUT_REACH,
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

#[inline]
fn struct_none() -> StructDesc {
    StructDesc { anchor_wx: 0, anchor_wz: 0, typ: STRUCT_NONE, cell_hash: 0, present: false }
}

fn raw_struct_for_cell(scx: i32, scz: i32, seed: u64) -> StructDesc {
    let sseed = fmix64(seed ^ STRUCT_SEED_MIX);
    // #179: canonical cell hash (periodic grid); anchor geometry stays in the
    // caller's frame so seam-adjacent placement works on raw coordinates.
    let h = hash2(wrap_cell(scx, STRUCT_CELL_COUNT), wrap_cell(scz, STRUCT_CELL_COUNT), sseed);

    if (h & 0xFF) >= STRUCT_PROB_THRESH {
        return struct_none();
    }

    let h2s = fmix64(h ^ 0xFACEBEEF0BAB);
    let off_x = STRUCT_ANCHOR_MIN_OFFSET + ((h2s >> 0) % (STRUCT_ANCHOR_OFFSET_CHOICES as u64)) as i32;
    let off_z = STRUCT_ANCHOR_MIN_OFFSET + ((h2s >> 16) % (STRUCT_ANCHOR_OFFSET_CHOICES as u64)) as i32;

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
        return struct_none();
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

// Fast mirror of raw_struct_for_cell for spacing scans. It returns only cells that
// the full raw picker would classify as VILLAGE or CITY, avoiding full structure
// classification for every neighbour in the spacing radius.
fn raw_settlement_for_cell(scx: i32, scz: i32, seed: u64) -> StructDesc {
    let sseed = fmix64(seed ^ STRUCT_SEED_MIX);
    let h = hash2(wrap_cell(scx, STRUCT_CELL_COUNT), wrap_cell(scz, STRUCT_CELL_COUNT), sseed);
    if (h & 0xFF) >= STRUCT_PROB_THRESH {
        return struct_none();
    }

    let h2s = fmix64(h ^ 0xFACEBEEF0BAB);
    if ((h2s >> 48) & 0xFF) < 36 {
        return struct_none();
    }

    let type_bits = (h2s >> 32) & 0x7;
    if type_bits != 0 && type_bits != 1 && type_bits != 5 {
        return struct_none();
    }

    let off_x = STRUCT_ANCHOR_MIN_OFFSET + ((h2s >> 0) % (STRUCT_ANCHOR_OFFSET_CHOICES as u64)) as i32;
    let off_z = STRUCT_ANCHOR_MIN_OFFSET + ((h2s >> 16) % (STRUCT_ANCHOR_OFFSET_CHOICES as u64)) as i32;
    let ax = scx * STRUCT_CELL_SIZE + off_x;
    let az = scz * STRUCT_CELL_SIZE + off_z;

    let dom = voronoi_biome(ax, az, seed);
    let is_village_candidate =
        (dom == Biome::Forest && type_bits == 5) || (dom == Biome::Plains && type_bits <= 1);
    if !is_village_candidate {
        return struct_none();
    }

    let h = struct_surface(ax, az, seed);
    if h <= SEA_LEVEL + 1
        || is_ocean_column(ax as f32, az as f32, seed)
        || river_channel_t(ax as f32, az as f32, seed) > 0.4
    {
        return struct_none();
    }

    let typ = if ((h2s >> 56) & 0xFF) < STRUCT_CITY_UPGRADE_THRESH {
        STRUCT_CITY
    } else {
        STRUCT_VILLAGE
    };
    StructDesc { anchor_wx: ax, anchor_wz: az, typ, cell_hash: h2s, present: true }
}

#[inline]
fn settlement_priority(sd: &StructDesc) -> (u64, u64) {
    // Cities are rarer and gameplay-significant, so when a village and a city fight
    // over the same 500-block pocket, keep the city. Ties fall back to the hash mark.
    (if sd.typ == STRUCT_CITY { 0 } else { 1 }, sd.cell_hash)
}

fn settlement_rejected_by_spacing(sd: &StructDesc, scx: i32, scz: i32, seed: u64) -> bool {
    let priority = settlement_priority(sd);
    let max_radius = if sd.typ == STRUCT_CITY {
        CITY_MIN_SPACING_BLOCKS
    } else {
        SETTLEMENT_MIN_SPACING_BLOCKS
    };
    let max_radius2 = (max_radius as i64) * (max_radius as i64);
    for dcz in -SETTLEMENT_SPACING_SCAN_CELLS..=SETTLEMENT_SPACING_SCAN_CELLS {
        for dcx in -SETTLEMENT_SPACING_SCAN_CELLS..=SETTLEMENT_SPACING_SCAN_CELLS {
            if dcx == 0 && dcz == 0 {
                continue;
            }

            let min_dx = (dcx.abs() * STRUCT_CELL_SIZE - STRUCT_ANCHOR_OFFSET_SPAN).max(0) as i64;
            let min_dz = (dcz.abs() * STRUCT_CELL_SIZE - STRUCT_ANCHOR_OFFSET_SPAN).max(0) as i64;
            if min_dx * min_dx + min_dz * min_dz >= max_radius2 {
                continue;
            }

            let nscx = scx + dcx;
            let nscz = scz + dcz;
            let other = raw_settlement_for_cell(nscx, nscz, seed);
            if !other.present {
                continue;
            }

            let radius = if sd.typ == STRUCT_CITY && other.typ == STRUCT_CITY {
                CITY_MIN_SPACING_BLOCKS
            } else {
                SETTLEMENT_MIN_SPACING_BLOCKS
            };
            let dx = (sd.anchor_wx - other.anchor_wx) as i64;
            let dz = (sd.anchor_wz - other.anchor_wz) as i64;
            if dx * dx + dz * dz >= (radius as i64) * (radius as i64) {
                continue;
            }

            let other_priority = settlement_priority(&other);
            if other_priority < priority || (other_priority == priority && (nscz, nscx) < (scz, scx)) {
                return true;
            }
        }
    }
    false
}

fn struct_for_cell(scx: i32, scz: i32, seed: u64) -> StructDesc {
    let sd = raw_struct_for_cell(scx, scz, seed);
    if !sd.present || !struct_is_settlement(sd.typ) {
        return sd;
    }
    if settlement_rejected_by_spacing(&sd, scx, scz, seed) {
        return struct_none();
    }
    sd
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
    // #228: waterside cabins ride a stilted deck too.
    let floor_h = floor_h.max(SEA_LEVEL + 1);

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

            let window = !corner && (((dx + dz) & 1) == 0);
            for wy in (floor_h + 1)..=wall_top {
                // Single 2-tall door opening: the bottom two cells (floor + 1, floor + 2)
                // are door blocks, and the cell above (floor + 3 = wall_top) stays solid
                // wall as a lintel so there is no gap over the doorway (#148, #149).
                if is_door {
                    if wy <= floor_h + 2 {
                        struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, OAK_DOOR);
                    } else {
                        struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, wall);
                    }
                    continue;
                }
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
    // doorway. The door column is now a solid lintel above floor + 2, so we keep the
    // torch off the door cells themselves and put it in the interior air cell one
    // block in from the wall, next to the door, with the solid wall block at (door
    // wall plane, that dz) directly behind it. The flanking wall cell stays solid
    // (no hole punched), so the torch reads as wall mounted inside the cabin.
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
    // #228: never sink a home into the sea. A waterside footprint raises the
    // floor to just above sea level; the per-column fill below then builds plank
    // stilts from the sea floor up, so the house stands on a deck.
    floor_h = floor_h.max(SEA_LEVEL + 1);

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

const SETTLEMENT_BUILDING_HUT: i32 = 0;
const SETTLEMENT_BUILDING_CABIN: i32 = 1;
const SETTLEMENT_BUILDING_WELL: i32 = 2;

#[derive(Clone, Copy)]
struct SettlementSite {
    dx: i32,
    dz: i32,
    kind: i32,
}

const SETTLEMENT_EMPTY_SITE: SettlementSite = SettlementSite {
    dx: 0,
    dz: 0,
    kind: SETTLEMENT_BUILDING_HUT,
};

const SETTLEMENT_DIRS: [[i32; 2]; 16] = [
    [4, 0],
    [4, 2],
    [3, 3],
    [2, 4],
    [0, 4],
    [-2, 4],
    [-3, 3],
    [-4, 2],
    [-4, 0],
    [-4, -2],
    [-3, -3],
    [-2, -4],
    [0, -4],
    [2, -4],
    [3, -3],
    [4, -2],
];

fn settlement_building_kind(h: u64, i: usize, wanted: usize, city: bool) -> i32 {
    let well_a = ((h >> 7) as usize) % wanted;
    if i == well_a {
        return SETTLEMENT_BUILDING_WELL;
    }
    if city {
        let well_b = (well_a + wanted / 2) % wanted;
        if i == well_b {
            return SETTLEMENT_BUILDING_WELL;
        }
        if (i + ((h >> 12) as usize)) % 3 == 0 {
            SETTLEMENT_BUILDING_CABIN
        } else {
            SETTLEMENT_BUILDING_HUT
        }
    } else if i == (well_a + 2 + ((h >> 11) as usize & 1)) % wanted {
        SETTLEMENT_BUILDING_CABIN
    } else {
        SETTLEMENT_BUILDING_HUT
    }
}

fn settlement_site_is_clear(sites: &[SettlementSite; SETTLEMENT_MAX_SITES], n: usize, dx: i32, dz: i32, min_sep: i32) -> bool {
    for s in sites.iter().take(n) {
        let ddx = dx - s.dx;
        let ddz = dz - s.dz;
        if ddx * ddx + ddz * ddz < min_sep * min_sep {
            return false;
        }
    }
    true
}

fn settlement_sites(h: u64, wanted: usize, city: bool) -> ([SettlementSite; SETTLEMENT_MAX_SITES], usize) {
    let wanted = wanted.min(SETTLEMENT_MAX_SITES).max(1);
    let (min_r, span, min_sep) = if city {
        (CITY_SITE_MIN_RADIUS, CITY_SITE_RADIUS_SPAN, 10)
    } else {
        (VILLAGE_SITE_MIN_RADIUS, VILLAGE_SITE_RADIUS_SPAN, 13)
    };
    let mut sites = [SETTLEMENT_EMPTY_SITE; SETTLEMENT_MAX_SITES];
    let mut n = 0usize;
    let rot = ((h >> 21) & 0xF) as usize;
    let attempts = wanted * 5 + 8;
    for attempt in 0..attempts {
        if n >= wanted {
            break;
        }
        let hh = fmix64(h ^ ((attempt as u64).wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(0xA53)));
        let dir = SETTLEMENT_DIRS[(rot + attempt * 5 + ((hh >> 4) as usize & 1)) & 15];
        let r = min_r + ((hh >> 9) % ((span + 1) as u64)) as i32;
        let jitter = (SETTLEMENT_SITE_JITTER * 2 + 1) as u64;
        let dx = dir[0] * r / 4 + ((hh >> 18) % jitter) as i32 - SETTLEMENT_SITE_JITTER;
        let dz = dir[1] * r / 4 + ((hh >> 25) % jitter) as i32 - SETTLEMENT_SITE_JITTER;
        if settlement_site_is_clear(&sites, n, dx, dz, min_sep) {
            sites[n] = SettlementSite {
                dx,
                dz,
                kind: settlement_building_kind(h, n, wanted, city),
            };
            n += 1;
        }
    }

    let fallback_r = min_r + span / 2;
    for i in 0..SETTLEMENT_DIRS.len() {
        if n >= wanted {
            break;
        }
        let dir = SETTLEMENT_DIRS[(rot + i * 5) & 15];
        let dx = dir[0] * fallback_r / 4;
        let dz = dir[1] * fallback_r / 4;
        if settlement_site_is_clear(&sites, n, dx, dz, min_sep) {
            sites[n] = SettlementSite {
                dx,
                dz,
                kind: settlement_building_kind(h, n, wanted, city),
            };
            n += 1;
        }
    }
    (sites, n)
}

fn settlement_pave<C: Chunk>(chunk: &mut C, wx: i32, wz: i32, seed: u64, wx_min: i32, wy_min: i32, wz_min: i32, b: BlockId) {
    let h = struct_surface(wx, wz, seed);
    if h < SEA_LEVEL + 1 {
        // #228: the road crosses water: lay a plank BOARDWALK at deck height (the
        // same level waterside homes ride at) instead of paving the sea floor.
        struct_set(chunk, wx, SEA_LEVEL + 1, wz, wx_min, wy_min, wz_min, OAK_PLANKS);
    } else {
        struct_set(chunk, wx, h, wz, wx_min, wy_min, wz_min, b);
    }
}

fn place_settlement_road<C: Chunk>(
    ax: i32,
    az: i32,
    dx: i32,
    dz: i32,
    h: u64,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
    b: BlockId,
) {
    let x_first = h & 1 == 0;
    if x_first {
        let mut px = 0;
        while px != dx {
            px += dx.signum();
            settlement_pave(chunk, ax + px, az, seed, wx_min, wy_min, wz_min, b);
        }
        let mut pz = 0;
        while pz != dz {
            pz += dz.signum();
            settlement_pave(chunk, ax + dx, az + pz, seed, wx_min, wy_min, wz_min, b);
        }
    } else {
        let mut pz = 0;
        while pz != dz {
            pz += dz.signum();
            settlement_pave(chunk, ax, az + pz, seed, wx_min, wy_min, wz_min, b);
        }
        let mut px = 0;
        while px != dx {
            px += dx.signum();
            settlement_pave(chunk, ax + px, az + dz, seed, wx_min, wy_min, wz_min, b);
        }
    }
}

fn place_settlement_building<C: Chunk>(
    ax: i32,
    az: i32,
    site: SettlementSite,
    h: u64,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    let bx = ax + site.dx;
    let bz = az + site.dz;
    match site.kind {
        SETTLEMENT_BUILDING_CABIN => place_cabin(bx, bz, h, seed, chunk, wx_min, wy_min, wz_min),
        SETTLEMENT_BUILDING_WELL => place_well(bx, bz, h, seed, chunk, wx_min, wy_min, wz_min),
        _ => place_hut(bx, bz, h, seed, chunk, wx_min, wy_min, wz_min),
    }
}

fn place_village<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    for dz in -1..=1 {
        for dx in -1..=1 {
            let col_h = struct_surface(ax + dx, az + dz, seed);
            let centre = dx == 0 && dz == 0;
            struct_set(chunk, ax + dx, col_h + if centre { 1 } else { 0 }, az + dz, wx_min, wy_min, wz_min, if centre { GLOW_BLOCK } else { COBBLESTONE });
        }
    }

    let wanted = VILLAGE_MIN_BUILDINGS + ((h >> 10) as usize % (VILLAGE_MAX_BUILDINGS - VILLAGE_MIN_BUILDINGS + 1));
    let (sites, n_sites) = settlement_sites(h, wanted, false);
    for (i, site) in sites.iter().take(n_sites).enumerate() {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x2545F4914F6CDD1D).wrapping_add(71)));
        place_settlement_road(ax, az, site.dx, site.dz, hh, seed, chunk, wx_min, wy_min, wz_min, COBBLESTONE);
    }
    for (i, site) in sites.iter().take(n_sites).enumerate() {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x2545F4914F6CDD1D).wrapping_add(71)));
        place_settlement_building(ax, az, *site, hh, seed, chunk, wx_min, wy_min, wz_min);
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

// A city: a larger procedural settlement around a paved plaza. Buildings are chosen
// from the same small kit as villages, but with more sites and a larger radius so two
// cities do not read as the same fixed ring.
fn place_city<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    // Paved central plaza, 7x7, with a marker / lamp core.
    for dz in -3..=3 {
        for dx in -3..=3 {
            let col_h = struct_surface(ax + dx, az + dz, seed);
            let centre = dx == 0 && dz == 0;
            let b = if centre { GLOW_BLOCK } else { STONE_BRICK };
            struct_set(chunk, ax + dx, col_h + if centre { 1 } else { 0 }, az + dz, wx_min, wy_min, wz_min, b);
        }
    }

    let wanted = CITY_MIN_BUILDINGS + ((h >> 10) as usize % (CITY_MAX_BUILDINGS - CITY_MIN_BUILDINGS + 1));
    let (sites, n_sites) = settlement_sites(h ^ 0xC17A, wanted, true);
    for (i, site) in sites.iter().take(n_sites).enumerate() {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(131)));
        place_settlement_road(ax, az, site.dx, site.dz, hh, seed, chunk, wx_min, wy_min, wz_min, STONE_BRICK);
    }
    for (i, site) in sites.iter().take(n_sites).enumerate() {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(131)));
        place_settlement_building(ax, az, *site, hh, seed, chunk, wx_min, wy_min, wz_min);
    }

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
