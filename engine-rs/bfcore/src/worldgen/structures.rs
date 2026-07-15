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
// Keep the existing broad candidate set for landmarks and settlements, but thin the
// small biome props that made every skyline feel occupied. This preserves every
// prior tall-tower / keep / ruin / village / city candidate while retaining only 3/8 of
// cabins, camps, wells, shrines, and similar common sites.
const STRUCT_CANDIDATE_THRESH: u64 = 128;
const STRUCT_COMMON_THRESH: u64 = 48;
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
const STRUCT_BOSS_CASTLE: i32 = 14; // rare multi-room fortress with a boss encounter
const STRUCT_GRAND_TOWER: i32 = 15; // rare enterable tower with an internal climb

// Epic landmarks replace selected existing big structures rather than adding more
// candidates. Each 4096-block macro cell has eight deterministic target cells in its
// central half; the first target that is already a tower/keep/ruin upgrades. Adjacent
// macro targets are therefore at least 33 structure cells (2112 blocks) apart.
const EPIC_MACRO_SIZE_CELLS: i32 = 64;
const EPIC_MACRO_COUNT: i32 = STRUCT_CELL_COUNT / EPIC_MACRO_SIZE_CELLS;
const EPIC_TARGET_COUNT: usize = 8;
const EPIC_TARGET_MIN_OFFSET: i32 = 16;
const EPIC_TARGET_OFFSET_CHOICES: u64 = 32;

// Share of would-be villages (low byte 0..256) that grow into a city. Cities are the
// only settlement that hosts the full profession chain, so they need to be findable in
// normal exploration; settlements are already a small slice of all structures, so this
// only lifts cities to "reliably encountered", not "everywhere".
// Most settlements should have room to grow. Cities remain occasional authored
// destinations, while HOME explicitly searches for the nearest one at spawn.
const STRUCT_CITY_UPGRADE_THRESH: u64 = 48;

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
// #248: leave a deliberate civic core between the plaza and the first buildings.
// The total outer reach stays unchanged (28 + 16 == the old 16 + 28), so chunk
// stamping cost and STRUCT_MAX_REACH_XZ do not grow.
const CITY_SITE_MIN_RADIUS: i32 = 28;
const CITY_SITE_RADIUS_SPAN: i32 = 16;
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
fn struct_is_danger_site(typ: i32) -> bool {
    struct_is_ruin(typ) || struct_is_epic_landmark(typ)
}

#[inline]
fn struct_is_epic_landmark(typ: i32) -> bool {
    typ == STRUCT_BOSS_CASTLE || typ == STRUCT_GRAND_TOWER
}

#[inline]
fn epic_landmark_height(typ: i32) -> i32 {
    if typ == STRUCT_GRAND_TOWER { 28 } else { 13 }
}

#[inline]
fn struct_is_settlement(typ: i32) -> bool {
    typ == STRUCT_VILLAGE || typ == STRUCT_CITY
}

#[inline]
fn struct_is_landmark(typ: i32) -> bool {
    typ == STRUCT_TALL_TOWER
        || typ == STRUCT_KEEP
        || typ == STRUCT_RUIN
        || struct_is_epic_landmark(typ)
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
        x if x == STRUCT_BOSS_CASTLE => 11,
        x if x == STRUCT_GRAND_TOWER => 6,
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

fn struct_levelled_floor(ax: i32, az: i32, reach: i32, seed: u64) -> i32 {
    let mut floor = i32::MIN;
    for dz in -reach..=reach {
        for dx in -reach..=reach {
            floor = floor.max(struct_surface(ax + dx, az + dz, seed));
        }
    }
    floor
}

fn struct_danger_floor(typ: i32, ax: i32, az: i32, seed: u64) -> i32 {
    if typ == STRUCT_BOSS_CASTLE {
        struct_levelled_floor(ax, az, 11, seed)
    } else if typ == STRUCT_GRAND_TOWER {
        struct_levelled_floor(ax, az, 6, seed)
    } else if typ == STRUCT_RUIN {
        struct_levelled_floor(ax, az, 4, seed)
    } else {
        struct_surface(ax, az, seed)
    }
}

#[inline]
fn struct_none() -> StructDesc {
    StructDesc { anchor_wx: 0, anchor_wz: 0, typ: STRUCT_NONE, cell_hash: 0, present: false }
}

fn raw_struct_for_cell(scx: i32, scz: i32, seed: u64) -> StructDesc {
    let sseed = fmix64(seed ^ STRUCT_SEED_MIX);
    // #179: canonical cell hash (periodic grid); anchor geometry stays in the
    // caller's frame so seam-adjacent placement works on raw coordinates.
    let cell_hash = hash2(wrap_cell(scx, STRUCT_CELL_COUNT), wrap_cell(scz, STRUCT_CELL_COUNT), sseed);

    if (cell_hash & 0xFF) >= STRUCT_CANDIDATE_THRESH {
        return struct_none();
    }

    let h2s = fmix64(cell_hash ^ 0xFACEBEEF0BAB);
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

    // City clustering: an occasional would-be village grows into a larger town /
    // city (more buildings, a denser layout with a center and simple paths). The roll
    // is a stable per-cell hash slice so the same cell is always a city or always a
    // village for a given seed. The city's buildings (huts / cabins) each carry their
    // own foundation fill, so a city also conforms to sloped ground without floating.
    //
    // Cities retain spacing priority because they are gameplay-significant, so the
    // raw 48/256 upgrade chance stays well below their desired final share. This
    // leaves villages as the majority while HOME still searches explicitly for a city.
    let stype = if stype == STRUCT_VILLAGE && ((h2s >> 56) & 0xFF) < STRUCT_CITY_UPGRADE_THRESH {
        STRUCT_CITY
    } else {
        stype
    };

    if !struct_is_landmark(stype)
        && !struct_is_settlement(stype)
        && (cell_hash & 0xFF) >= STRUCT_COMMON_THRESH
    {
        return struct_none();
    }

    StructDesc { anchor_wx: ax, anchor_wz: az, typ: stype, cell_hash: h2s, present: true }
}

// Fast mirror of raw_struct_for_cell for spacing scans. It returns only cells that
// the full raw picker would classify as VILLAGE or CITY, avoiding full structure
// classification for every neighbour in the spacing radius.
fn raw_settlement_for_cell(scx: i32, scz: i32, seed: u64) -> StructDesc {
    let sseed = fmix64(seed ^ STRUCT_SEED_MIX);
    let h = hash2(wrap_cell(scx, STRUCT_CELL_COUNT), wrap_cell(scz, STRUCT_CELL_COUNT), sseed);
    if (h & 0xFF) >= STRUCT_CANDIDATE_THRESH {
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

#[inline]
fn struct_is_legacy_big(typ: i32) -> bool {
    typ == STRUCT_TALL_TOWER || typ == STRUCT_KEEP || typ == STRUCT_RUIN
}

#[inline]
fn epic_target_cell(origin_x: i32, origin_z: i32, macro_hash: u64, index: usize) -> (i32, i32) {
    let roll = fmix64(macro_hash ^ (index as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15));
    (
        origin_x + EPIC_TARGET_MIN_OFFSET + (roll % EPIC_TARGET_OFFSET_CHOICES) as i32,
        origin_z + EPIC_TARGET_MIN_OFFSET + ((roll >> 16) % EPIC_TARGET_OFFSET_CHOICES) as i32,
    )
}

fn epic_upgrade_for_cell(scx: i32, scz: i32, seed: u64) -> Option<i32> {
    let macro_x = struct_floordiv(scx, EPIC_MACRO_SIZE_CELLS);
    let macro_z = struct_floordiv(scz, EPIC_MACRO_SIZE_CELLS);
    let origin_x = macro_x * EPIC_MACRO_SIZE_CELLS;
    let origin_z = macro_z * EPIC_MACRO_SIZE_CELLS;
    let macro_hash = hash2(
        wrap_cell(macro_x, EPIC_MACRO_COUNT),
        wrap_cell(macro_z, EPIC_MACRO_COUNT),
        fmix64(seed ^ 0xE91C_1A4D_5EED),
    );

    let mut target_index = None;
    for i in 0..EPIC_TARGET_COUNT {
        let (tx, tz) = epic_target_cell(origin_x, origin_z, macro_hash, i);
        if (tx, tz) == (scx, scz) {
            target_index = Some(i);
            break;
        }
    }
    let target_index = target_index?;

    // Check only the small fixed target list up to this cell. The first target that
    // was already a legacy big structure wins; all other old structures are unchanged.
    for i in 0..=target_index {
        let (tx, tz) = epic_target_cell(origin_x, origin_z, macro_hash, i);
        let candidate = raw_struct_for_cell(tx, tz, seed);
        if candidate.present && struct_is_legacy_big(candidate.typ) {
            let epic_type = if (macro_x + macro_z).rem_euclid(2) == 0 {
                STRUCT_BOSS_CASTLE
            } else {
                STRUCT_GRAND_TOWER
            };
            let floor = struct_danger_floor(epic_type, candidate.anchor_wx, candidate.anchor_wz, seed);
            if floor + epic_landmark_height(epic_type) > WORLD_TOP_Y {
                continue;
            }
            return if (tx, tz) == (scx, scz) {
                Some(epic_type)
            } else {
                None
            };
        }
    }
    None
}

fn struct_for_cell(scx: i32, scz: i32, seed: u64) -> StructDesc {
    let sd = raw_struct_for_cell(scx, scz, seed);
    if !sd.present {
        return sd;
    }
    if struct_is_legacy_big(sd.typ) {
        if let Some(typ) = epic_upgrade_for_cell(scx, scz, seed) {
            return StructDesc { typ, ..sd };
        }
        return sd;
    }
    if !struct_is_settlement(sd.typ) {
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

// Structure writes deliberately do not clear existing solids when passed AIR.
// This scoped companion is only for guaranteed body-clear spaces such as the
// chopping block's work cell and overhead silhouette.
fn struct_clear<C: Chunk>(
    chunk: &mut C,
    wx: i32,
    wy: i32,
    wz: i32,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) -> bool {
    if wx < wx_min || wx > wx_min + K_CHUNK_DIM - 1 {
        return false;
    }
    if wy < wy_min || wy > wy_min + K_CHUNK_DIM - 1 {
        return false;
    }
    if wz < wz_min || wz > wz_min + K_CHUNK_DIM - 1 {
        return false;
    }
    chunk.set(wx - wx_min, wy - wy_min, wz - wz_min, AIR);
    true
}

fn struct_fill_col<C: Chunk>(chunk: &mut C, wx: i32, wz: i32, top_wy: i32, seed: u64, wx_min: i32, wy_min: i32, wz_min: i32, b: BlockId) {
    if wx < wx_min
        || wx > wx_min + K_CHUNK_DIM - 1
        || wz < wz_min
        || wz > wz_min + K_CHUNK_DIM - 1
    {
        return;
    }
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

// Stepped pitched roof shared by cabins and villager homes. A one-block eave wraps
// every side; full wall material closes the two gable ends below the roof skin.
#[allow(clippy::too_many_arguments)]
fn place_pitched_roof<C: Chunk>(
    ax: i32,
    az: i32,
    rx: i32,
    rz: i32,
    wall_top: i32,
    ridge_along_x: bool,
    wall: BlockId,
    roof: BlockId,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    if ridge_along_x {
        for dz in -(rz + 1)..=(rz + 1) {
            let ridge_step = rz + 1 - dz.abs();
            let roof_y = wall_top + 1 + ridge_step;
            for dx in -(rx + 1)..=(rx + 1) {
                struct_set(chunk, ax + dx, roof_y, az + dz, wx_min, wy_min, wz_min, roof);
            }
        }
        for dz in -rz..=rz {
            let ridge_step = rz + 1 - dz.abs();
            for dx in [-rx, rx] {
                for wy in (wall_top + 1)..(wall_top + 1 + ridge_step) {
                    struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, wall);
                }
            }
        }
    } else {
        for dx in -(rx + 1)..=(rx + 1) {
            let ridge_step = rx + 1 - dx.abs();
            let roof_y = wall_top + 1 + ridge_step;
            for dz in -(rz + 1)..=(rz + 1) {
                struct_set(chunk, ax + dx, roof_y, az + dz, wx_min, wy_min, wz_min, roof);
            }
        }
        for dx in -rx..=rx {
            let ridge_step = rx + 1 - dx.abs();
            for dz in [-rz, rz] {
                for wy in (wall_top + 1)..(wall_top + 1 + ridge_step) {
                    struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, wall);
                }
            }
        }
    }
}

fn settlement_home_half_extents(kind: i32, h: u64) -> Option<(i32, i32)> {
    match kind {
        SETTLEMENT_BUILDING_CABIN => Some((if (h >> 2) & 1 != 0 { 3 } else { 2 }, 2)),
        SETTLEMENT_BUILDING_HUT => Some((
            2 + ((h >> 5) & 1) as i32,
            2 + ((h >> 6) & 1) as i32,
        )),
        _ => None,
    }
}

fn settlement_home_floor(cx: i32, cz: i32, rx: i32, rz: i32, seed: u64) -> i32 {
    let mut floor = i32::MIN;
    for dz in -rz..=rz {
        for dx in -rx..=rx {
            floor = floor.max(struct_surface(cx + dx, cz + dz, seed));
        }
    }
    floor.max(SEA_LEVEL + 1)
}

fn place_cabin<C: Chunk>(
    ax: i32,
    az: i32,
    h: u64,
    door_dir: i32,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    let (hx, hz) = settlement_home_half_extents(SETTLEMENT_BUILDING_CABIN, h).unwrap();
    // #228: waterside cabins ride a stilted deck too.
    let floor_h = settlement_home_floor(ax, az, hx, hz, seed);
    place_cabin_at_floor(
        ax, az, h, door_dir, seed, hx, hz, floor_h, false, chunk, wx_min, wy_min, wz_min,
    );
}

#[allow(clippy::too_many_arguments)]
fn place_cabin_at_floor<C: Chunk>(
    ax: i32,
    az: i32,
    h: u64,
    door_dir: i32,
    seed: u64,
    hx: i32,
    hz: i32,
    floor_h: i32,
    terraced: bool,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    let cobble = ((h >> 5) & 1) != 0;
    let wall = if cobble { COBBLESTONE } else { OAK_PLANKS };
    let trim = if cobble { STONE_BRICK } else { WOOD_BEAM };
    let wall_h = 3;
    let wall_top = floor_h + wall_h;

    let (door_dx, door_dz) = match door_dir {
        0 => (hx, 0),
        1 => (-hx, 0),
        2 => (0, hz),
        _ => (0, -hz),
    };

    for dz in -hz..=hz {
        for dx in -hx..=hx {
            struct_fill_col(chunk, ax + dx, az + dz, floor_h, seed, wx_min, wy_min, wz_min, OAK_PLANKS);
            if terraced {
                struct_set(
                    chunk,
                    ax + dx,
                    floor_h,
                    az + dz,
                    wx_min,
                    wy_min,
                    wz_min,
                    OAK_PLANKS,
                );
            }
        }
    }

    // #301: decorations run before structures. Clear the enclosed room so a
    // surface flower, grass tuft, or bush cannot survive inside the finished home.
    for dz in (-hz + 1)..hz {
        for dx in (-hx + 1)..hx {
            for wy in (floor_h + 1)..=wall_top {
                struct_clear(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min);
            }
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

            let is_door = dx == door_dx && dz == door_dz;

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
        if door_dx != 0 {
            for dz in -hz..=hz {
                if dz == 0 {
                    continue;
                }
                for wy in (floor_h + 1)..=wall_top {
                    struct_set(chunk, ax, wy, az + dz, wx_min, wy_min, wz_min, wall);
                }
            }
        } else {
            // Keep the same two-room cabin when the entrance rotates to a Z wall,
            // but rotate its open centre aisle with the doorway.
            for dx in -hx..=hx {
                if dx == 0 {
                    continue;
                }
                for wy in (floor_h + 1)..=wall_top {
                    struct_set(chunk, ax + dx, wy, az, wx_min, wy_min, wz_min, wall);
                }
            }
        }
    }

    let roof = if cobble { STONE_BRICK } else { BIRCH_PLANKS };
    place_pitched_roof(
        ax, az, hx, hz, wall_top, true, wall, roof, chunk, wx_min, wy_min, wz_min,
    );

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
    let door_solid_at = |tangent: i32, wy: i32| -> bool {
        let (wall_dx, wall_dz) = if door_dx != 0 {
            (door_dx, tangent)
        } else {
            (tangent, door_dz)
        };
        let is_window = ((wall_dx + wall_dz) & 1) == 0;
        !(is_window && wy == floor_h + 2)
    };
    let (torch_tangent, torch_wy) = if door_solid_at(-1, floor_h + 2) {
        (-1, floor_h + 2)
    } else if door_solid_at(1, floor_h + 2) {
        (1, floor_h + 2)
    } else {
        (-1, floor_h + 1)
    };
    let (torch_dx, torch_dz) = if door_dx != 0 {
        (door_dx - door_dx.signum(), torch_tangent)
    } else {
        (torch_tangent, door_dz - door_dz.signum())
    };
    struct_set(
        chunk,
        ax + torch_dx,
        torch_wy,
        az + torch_dz,
        wx_min,
        wy_min,
        wz_min,
        TORCH,
    );
    struct_set(chunk, ax, floor_h + 1, az, wx_min, wy_min, wz_min, GLOW_BLOCK);

    {
        let chim_side = if (h >> 7) & 1 != 0 { 1 } else { -1 };
        let (chim_dx, chim_dz) = if door_dx != 0 {
            (-door_dx, chim_side * hz)
        } else {
            (chim_side * hx, -door_dz)
        };
        let chim_x = ax + chim_dx;
        let chim_z = az + chim_dz;
        let ridge_top = wall_top + 1 + (hz + 1);
        let chim_top = ridge_top + 2;
        if terraced {
            for wy in floor_h..=chim_top {
                struct_set(
                    chunk, chim_x, wy, chim_z, wx_min, wy_min, wz_min, COBBLESTONE,
                );
            }
        } else {
            struct_fill_col(
                chunk, chim_x, chim_z, chim_top, seed, wx_min, wy_min, wz_min, COBBLESTONE,
            );
        }
        struct_set(chunk, chim_x, floor_h + 1, chim_z, wx_min, wy_min, wz_min, GLOW_BLOCK);
    }

    if terraced {
        struct_set(chunk, ax, floor_h - 1, az, wx_min, wy_min, wz_min, MARKER_BLOCK);
    } else {
        struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
    }
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
    place_well_at_floor(
        ax, az, seed, big_h, false, chunk, wx_min, wy_min, wz_min,
    );
}

#[allow(clippy::too_many_arguments)]
fn place_well_at_floor<C: Chunk>(
    ax: i32,
    az: i32,
    seed: u64,
    big_h: i32,
    terraced: bool,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    for dz in -1..=1 {
        for dx in -1..=1 {
            if dx == 0 && dz == 0 {
                continue;
            }
            if terraced {
                struct_set(
                    chunk,
                    ax + dx,
                    big_h + 1,
                    az + dz,
                    wx_min,
                    wy_min,
                    wz_min,
                    STONE_BRICK,
                );
            } else {
                let ring_h = struct_surface(ax + dx, az + dz, seed) + 1;
                struct_fill_col(
                    chunk, ax + dx, az + dz, ring_h, seed, wx_min, wy_min, wz_min,
                    STONE_BRICK,
                );
            }
        }
    }
    struct_set(chunk, ax, big_h, az, wx_min, wy_min, wz_min, WATER);

    let post_h = 3;
    let post_top = big_h + post_h;
    let corner = [[-1, -1], [1, -1], [-1, 1], [1, 1]];
    for c in corner.iter() {
        if terraced {
            for wy in (big_h + 1)..=post_top {
                struct_set(
                    chunk,
                    ax + c[0],
                    wy,
                    az + c[1],
                    wx_min,
                    wy_min,
                    wz_min,
                    WOOD_BEAM,
                );
            }
        } else {
            struct_fill_col(
                chunk, ax + c[0], az + c[1], post_top, seed, wx_min, wy_min, wz_min,
                WOOD_BEAM,
            );
        }
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
    if terraced {
        struct_set(chunk, ax, big_h - 1, az, wx_min, wy_min, wz_min, MARKER_BLOCK);
    } else {
        struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
    }
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
// air. Each home has a 1 wide door, at least two windows, shaped timber trim, a
// deterministic pitched roof with eaves, and basic furniture (a bed plus a light),
// with the centre floor left open for future chests / crafting tables.
//
// All blocks go through struct_set / struct_fill_col so a home spanning a chunk
// border stamps identically into every chunk it touches (seam safe), and every
// column's foundation fills down to its own terrain so the home sits flush on a
// slope (no floaters). Everything is derived from (cx, cz, hh) so generation is
// deterministic per cell. Roof eaves reach at most 4 blocks from the anchor, matching
// SETTLEMENT_BUILDING_REACH and staying well within STRUCT_MAX_REACH_XZ.
fn place_hut<C: Chunk>(
    cx: i32,
    cz: i32,
    hh: u64,
    dir: i32,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    // Footprint half extents: 2 (5 wide) or 3 (6 wide) on each axis, varied per home.
    let (rx, rz) = settlement_home_half_extents(SETTLEMENT_BUILDING_HUT, hh).unwrap();

    // Foundation reference: the highest terrain column under the footprint so the
    // floor is level; per column we still fill the gap down to that column's own
    // terrain so the home conforms to a slope without floating.
    // #228: never sink a home into the sea. A waterside footprint raises the
    // floor to just above sea level; the per-column fill below then builds plank
    // stilts from the sea floor up, so the house stands on a deck.
    let floor_h = settlement_home_floor(cx, cz, rx, rz, seed);
    place_hut_at_floor(
        cx, cz, hh, dir, seed, rx, rz, floor_h, false, chunk, wx_min, wy_min, wz_min,
    );
}

#[allow(clippy::too_many_arguments)]
fn place_hut_at_floor<C: Chunk>(
    cx: i32,
    cz: i32,
    hh: u64,
    dir: i32,
    seed: u64,
    rx: i32,
    rz: i32,
    floor_h: i32,
    terraced: bool,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
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
            if terraced {
                struct_set(
                    chunk,
                    cx + dx,
                    floor_h,
                    cz + dz,
                    wx_min,
                    wy_min,
                    wz_min,
                    OAK_PLANKS,
                );
            }
        }
    }

    // #301: this volume is authored interior air, not untouched terrain. Clearing
    // it here preserves village landscaping while removing pre-structure plants.
    for dz in (-rz + 1)..rz {
        for dx in (-rx + 1)..rx {
            for wy in (floor_h + 1)..=wall_top {
                struct_clear(chunk, cx + dx, wy, cz + dz, wx_min, wy_min, wz_min);
            }
        }
    }

    // Door wall: 0 = +X, 1 = -X, 2 = +Z, 3 = -Z. The door sits in the middle of
    // that wall (offset 0 along the wall), so the opening is always flanked by wall.

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

    // Finished timber frame. Shaped beams are inset and therefore decorative, not
    // weather-tight wall material. Keep them only at corners where two solid wall
    // planes meet; doorway and window jambs remain the selected solid wall block.
    for &(dx, dz) in &[(-rx, -rz), (rx, -rz), (-rx, rz), (rx, rz)] {
        for wy in (floor_h + 1)..=wall_top {
            struct_set(chunk, cx + dx, wy, cz + dz, wx_min, wy_min, wz_min, WOOD_BEAM);
        }
    }

    // Ridge follows the longer wall; square homes use one stable hash bit for variety.
    let ridge_along_x = if rx == rz { (hh >> 8) & 1 == 0 } else { rx > rz };
    place_pitched_roof(
        cx,
        cz,
        rx,
        rz,
        wall_top,
        ridge_along_x,
        wall,
        roof,
        chunk,
        wx_min,
        wy_min,
        wz_min,
    );

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

#[derive(Clone, Copy)]
struct SettlementEntrance {
    door_dir: i32,
    approach_dx: i32,
    approach_dz: i32,
    floor_y: i32,
}

fn settlement_hashed_door_dir(kind: i32, h: u64) -> i32 {
    if kind == SETTLEMENT_BUILDING_CABIN {
        if (h >> 6) & 1 != 0 { 0 } else { 1 }
    } else {
        ((h >> 1) & 0x3) as i32
    }
}

fn settlement_inward_door_dir(site: SettlementSite) -> i32 {
    if site.dx.abs() >= site.dz.abs() {
        if site.dx >= 0 { 1 } else { 0 }
    } else if site.dz >= 0 {
        3
    } else {
        2
    }
}

fn settlement_home_entrance_for_dir(
    ax: i32,
    az: i32,
    site: SettlementSite,
    h: u64,
    door_dir: i32,
    seed: u64,
) -> Option<SettlementEntrance> {
    let (rx, rz) = settlement_home_half_extents(site.kind, h)?;
    let (approach_x, approach_z) = match door_dir {
        0 => (rx + 1, 0),
        1 => (-rx - 1, 0),
        2 => (0, rz + 1),
        _ => (0, -rz - 1),
    };
    Some(SettlementEntrance {
        door_dir,
        approach_dx: site.dx + approach_x,
        approach_dz: site.dz + approach_z,
        floor_y: settlement_home_floor(ax + site.dx, az + site.dz, rx, rz, seed),
    })
}

fn settlement_home_entrance(
    ax: i32,
    az: i32,
    site: SettlementSite,
    h: u64,
    seed: u64,
) -> Option<SettlementEntrance> {
    settlement_home_entrance_for_dir(
        ax, az, site, h, settlement_inward_door_dir(site), seed,
    )
}

fn city_arterial_door_dir(site: SettlementSite) -> i32 {
    if city_arterial_dir(site).0 != 0 {
        if site.dz >= 0 { 3 } else { 2 }
    } else if site.dx >= 0 {
        1
    } else {
        0
    }
}

fn city_site_road_target(
    ax: i32,
    az: i32,
    site: SettlementSite,
    h: u64,
    seed: u64,
) -> (SettlementEntrance, i32, (i32, i32, i32, i32)) {
    let home_extents = settlement_home_half_extents(site.kind, h);
    let door_dir = city_arterial_door_dir(site);
    if let Some((rx, rz)) = home_extents {
        let entrance = settlement_home_entrance_for_dir(
            ax, az, site, h, door_dir, seed,
        )
        .unwrap();
        return (
            entrance,
            4,
            (site.dx - rx, site.dx + rx, site.dz - rz, site.dz + rz),
        );
    }
    let (rx, rz) = (1, 1);
    let (approach_x, approach_z) = match door_dir {
        0 => (rx + 1, 0),
        1 => (-rx - 1, 0),
        2 => (0, rz + 1),
        _ => (0, -rz - 1),
    };
    let approach_dx = site.dx + approach_x;
    let approach_dz = site.dz + approach_z;
    let floor_y = struct_surface(ax + approach_dx, az + approach_dz, seed).max(SEA_LEVEL + 1);
    (
        SettlementEntrance {
            door_dir,
            approach_dx,
            approach_dz,
            floor_y,
        },
        1,
        (site.dx - rx, site.dx + rx, site.dz - rz, site.dz + rz),
    )
}

fn city_lot_pad_half_extents(site: SettlementSite, h: u64) -> (i32, i32) {
    settlement_home_half_extents(site.kind, h)
        .map(|(rx, rz)| (rx + 1, rz + 1))
        .unwrap_or((2, 2))
}

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

fn city_sites(
    city_hash: u64,
    wanted: usize,
) -> ([SettlementSite; SETTLEMENT_MAX_SITES], usize) {
    let wanted = wanted.min(SETTLEMENT_MAX_SITES).max(1);
    let layout_hash = city_hash ^ 0xC17A;
    let arms = [(1, 0), (0, 1), (-1, 0), (0, -1)];
    let rotation = ((layout_hash >> 21) & 3) as usize;
    let flip = if layout_hash & 1 == 0 { -1 } else { 1 };
    let mut sites = [SETTLEMENT_EMPTY_SITE; SETTLEMENT_MAX_SITES];
    let mut n = 0;
    for i in 0..wanted {
        let tier = i / 4;
        let arm_index = (i % 4 + rotation) & 3;
        let dir = arms[arm_index];
        let lateral_sign = if tier & 1 == 0 { flip } else { -flip };
        let lateral = lateral_sign * CITY_LOT_OFFSETS[tier];
        let dx = dir.0 * CITY_LOT_RADII[tier] - dir.1 * lateral;
        let dz = dir.1 * CITY_LOT_RADII[tier] + dir.0 * lateral;
        debug_assert!(settlement_site_is_clear(&sites, n, dx, dz, 10));
        sites[n] = SettlementSite {
            dx,
            dz,
            kind: settlement_building_kind(layout_hash, i, wanted, true),
        };
        n += 1;
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

fn settlement_grade_road_profile(
    ax: i32,
    az: i32,
    points: Vec<(i32, i32)>,
    start_y: i32,
    end_y: i32,
    seed: u64,
) -> Vec<(i32, i32, i32)> {
    let mut profile: Vec<_> = points
        .into_iter()
        .map(|(dx, dz)| {
            (
                dx,
                dz,
                struct_surface(ax + dx, az + dz, seed).max(SEA_LEVEL + 1),
            )
        })
        .collect();
    let last = profile.len() - 1;
    profile[0].2 = start_y;
    profile[last].2 = end_y;

    // Pin both ends, cut only unavoidable peaks, then raise valleys just enough
    // to keep every horizontal step walkable.
    for (i, point) in profile.iter_mut().enumerate().take(last).skip(1) {
        point.2 = point
            .2
            .min(start_y + i as i32)
            .min(end_y + (last - i) as i32);
    }
    for i in 1..profile.len() {
        profile[i].2 = profile[i].2.max(profile[i - 1].2 - 1);
    }
    // The real junction is already stamped and is not restamped by this helper,
    // so never let the theoretical back-pass raise profile[0].
    for i in (1..last).rev() {
        profile[i].2 = profile[i].2.max(profile[i + 1].2 - 1);
    }
    profile
}

fn settlement_home_road_profile(
    ax: i32,
    az: i32,
    entrance: SettlementEntrance,
    seed: u64,
) -> Vec<(i32, i32, i32)> {
    let mut points = vec![(0, 0)];
    let doorway_run = 4;
    let (branch_x, branch_z) = match entrance.door_dir {
        0 | 1 => (
            entrance.approach_dx - entrance.approach_dx.signum() * doorway_run,
            entrance.approach_dz,
        ),
        _ => (
            entrance.approach_dx,
            entrance.approach_dz - entrance.approach_dz.signum() * doorway_run,
        ),
    };
    let mut x: i32 = 0;
    let mut z: i32 = 0;
    if entrance.door_dir >= 2 {
        // The communal bench and broom occupy the north/south centreline. Fan a
        // Z-facing home's path around them before aiming toward its own branch.
        let lane_x = if branch_x < 0 { -2 } else { 1 };
        while x != lane_x {
            x += (lane_x - x).signum();
            points.push((x, z));
        }
        let bypass_z = entrance.approach_dz.signum() * 7;
        while z != bypass_z {
            z += entrance.approach_dz.signum();
            points.push((x, z));
        }
    }

    // A balanced Manhattan line fans paths toward their homes instead of laying
    // every route over the same two village axes. The last four cells remain a
    // straight, head-on doorway approach.
    let (fan_x, fan_z) = (x, z);
    let (fan_dx, fan_dz) = (branch_x - fan_x, branch_z - fan_z);
    while x != branch_x || z != branch_z {
        if x == branch_x {
            z += (branch_z - z).signum();
        } else if z == branch_z {
            x += (branch_x - x).signum();
        } else {
            let next_x = x + (branch_x - x).signum();
            let next_z = z + (branch_z - z).signum();
            let x_error = ((next_x - fan_x) as i64 * fan_dz as i64
                - (z - fan_z) as i64 * fan_dx as i64)
                .abs();
            let z_error = ((x - fan_x) as i64 * fan_dz as i64
                - (next_z - fan_z) as i64 * fan_dx as i64)
                .abs();
            if x_error <= z_error {
                x = next_x;
            } else {
                z = next_z;
            }
        }
        points.push((x, z));
    }
    while x != entrance.approach_dx {
        x += (entrance.approach_dx - x).signum();
        points.push((x, z));
    }
    while z != entrance.approach_dz {
        z += (entrance.approach_dz - z).signum();
        points.push((x, z));
    }

    let start_y = struct_surface(ax, az, seed).max(SEA_LEVEL + 1);
    settlement_grade_road_profile(ax, az, points, start_y, entrance.floor_y, seed)
}

#[allow(clippy::too_many_arguments)]
fn settlement_pave_profiled<C: Chunk>(
    chunk: &mut C,
    wx: i32,
    road_y: i32,
    wz: i32,
    seed: u64,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
    b: BlockId,
) {
    if wx < wx_min
        || wx > wx_min + K_CHUNK_DIM - 1
        || wz < wz_min
        || wz > wz_min + K_CHUNK_DIM - 1
    {
        return;
    }
    let natural = struct_surface(wx, wz, seed);
    let wet = natural < SEA_LEVEL + 1;
    let road_block = if wet { OAK_PLANKS } else { b };
    if wet {
        for wy in (SEA_LEVEL + 1)..=road_y {
            struct_set(chunk, wx, wy, wz, wx_min, wy_min, wz_min, road_block);
        }
    } else {
        struct_fill_col(
            chunk, wx, wz, road_y, seed, wx_min, wy_min, wz_min, road_block,
        );
        struct_set(chunk, wx, road_y, wz, wx_min, wy_min, wz_min, road_block);
    }
    for wy in (road_y + 1)..=(natural.max(road_y) + 2) {
        struct_clear(chunk, wx, wy, wz, wx_min, wy_min, wz_min);
    }
}

#[allow(clippy::too_many_arguments)]
fn place_settlement_home_road<C: Chunk>(
    ax: i32,
    az: i32,
    entrance: SettlementEntrance,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
    b: BlockId,
) {
    for &(dx, dz, road_y) in settlement_home_road_profile(ax, az, entrance, seed).iter().skip(1) {
        settlement_pave_profiled(
            chunk,
            ax + dx,
            road_y,
            az + dz,
            seed,
            wx_min,
            wy_min,
            wz_min,
            b,
        );
    }
}

fn place_settlement_building<C: Chunk>(
    ax: i32,
    az: i32,
    site: SettlementSite,
    h: u64,
    door_dir: i32,
    floor_override: Option<i32>,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    let bx = ax + site.dx;
    let bz = az + site.dz;
    match site.kind {
        SETTLEMENT_BUILDING_CABIN => {
            if let Some(floor_h) = floor_override {
                let (hx, hz) = settlement_home_half_extents(site.kind, h).unwrap();
                place_cabin_at_floor(
                    bx, bz, h, door_dir, seed, hx, hz, floor_h, true, chunk, wx_min, wy_min,
                    wz_min,
                );
            } else {
                place_cabin(bx, bz, h, door_dir, seed, chunk, wx_min, wy_min, wz_min);
            }
        }
        SETTLEMENT_BUILDING_WELL => {
            if let Some(floor_h) = floor_override {
                place_well_at_floor(
                    bx, bz, seed, floor_h, true, chunk, wx_min, wy_min, wz_min,
                );
            } else {
                place_well(bx, bz, h, seed, chunk, wx_min, wy_min, wz_min);
            }
        }
        _ => {
            if let Some(floor_h) = floor_override {
                let (rx, rz) = settlement_home_half_extents(site.kind, h).unwrap();
                place_hut_at_floor(
                    bx, bz, h, door_dir, seed, rx, rz, floor_h, true, chunk, wx_min,
                    wy_min, wz_min,
                );
            } else {
                place_hut(bx, bz, h, door_dir, seed, chunk, wx_min, wy_min, wz_min);
            }
        }
    }
}

// Finished artisan stations ring the central yard. Every authored mesh faces a
// level, supported, two-block-clear work cell immediately west of its block.
const SETTLEMENT_WORKSTATIONS: [(i32, i32, BlockId); 5] = [
    (-4, 4, MASON_BENCH),
    (-4, -4, BLACKSMITH_FORGE),
    (4, -4, HERBALIST_TABLE),
    (6, 6, BUILDER_SAWBENCH),
    (4, 4, CHOPPING_BLOCK),
];
const SETTLEMENT_SOCIAL_PROPS: [(i32, i32, BlockId); 2] = [
    (0, 6, COMMUNAL_BENCH),
    (0, -6, BROOM_STAND),
];
const CITY_SOCIAL_PROPS: [(i32, i32, BlockId); 2] = [
    (3, 6, COMMUNAL_BENCH),
    (-2, -6, BROOM_STAND),
];

fn place_settlement_workstation<C: Chunk>(
    ax: i32,
    az: i32,
    dx: i32,
    dz: i32,
    station_block: BlockId,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
    foundation: BlockId,
    floor_override: Option<i32>,
) {
    let (station_x, station_z) = (ax + dx, az + dz);
    let (work_x, work_z) = (station_x - 1, station_z);
    let floor_y = floor_override.unwrap_or_else(|| {
        struct_surface(station_x, station_z, seed)
            .max(struct_surface(work_x, work_z, seed))
            .max(SEA_LEVEL + 1)
    });

    for (wx, wz) in [(station_x, station_z), (work_x, work_z)] {
        struct_fill_col(
            chunk, wx, wz, floor_y, seed, wx_min, wy_min, wz_min, foundation,
        );
        struct_set(chunk, wx, floor_y, wz, wx_min, wy_min, wz_min, foundation);
    }
    struct_set(
        chunk,
        station_x,
        floor_y + 1,
        station_z,
        wx_min,
        wy_min,
        wz_min,
        station_block,
    );
    struct_clear(
        chunk,
        station_x,
        floor_y + 2,
        station_z,
        wx_min,
        wy_min,
        wz_min,
    );
    struct_clear(chunk, work_x, floor_y + 1, work_z, wx_min, wy_min, wz_min);
    struct_clear(chunk, work_x, floor_y + 2, work_z, wx_min, wy_min, wz_min);
}

fn place_settlement_workstations<C: Chunk>(
    ax: i32,
    az: i32,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
    foundation: BlockId,
    floor_override: Option<i32>,
) {
    for (dx, dz, block) in SETTLEMENT_WORKSTATIONS {
        place_settlement_workstation(
            ax, az, dx, dz, block, seed, chunk, wx_min, wy_min, wz_min, foundation,
            floor_override,
        );
    }
}

fn place_settlement_social_props<C: Chunk>(
    ax: i32,
    az: i32,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
    foundation: BlockId,
    floor_override: Option<i32>,
) {
    for (dx, dz, block) in SETTLEMENT_SOCIAL_PROPS {
        place_settlement_workstation(
            ax, az, dx, dz, block, seed, chunk, wx_min, wy_min, wz_min, foundation,
            floor_override,
        );
    }
}

fn place_city_social_props<C: Chunk>(
    ax: i32,
    az: i32,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
    floor_y: i32,
) {
    for (dx, dz, block) in CITY_SOCIAL_PROPS {
        place_settlement_workstation(
            ax, az, dx, dz, block, seed, chunk, wx_min, wy_min, wz_min, STONE_BRICK,
            Some(floor_y),
        );
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
        if let Some(entrance) = settlement_home_entrance(ax, az, *site, hh, seed) {
            place_settlement_home_road(
                ax,
                az,
                entrance,
                seed,
                chunk,
                wx_min,
                wy_min,
                wz_min,
                COBBLESTONE,
            );
        } else {
            place_settlement_road(
                ax,
                az,
                site.dx,
                site.dz,
                hh,
                seed,
                chunk,
                wx_min,
                wy_min,
                wz_min,
                COBBLESTONE,
            );
        }
    }
    for (i, site) in sites.iter().take(n_sites).enumerate() {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x2545F4914F6CDD1D).wrapping_add(71)));
        let door_dir = settlement_home_entrance(ax, az, *site, hh, seed)
            .map(|entrance| entrance.door_dir)
            .unwrap_or_else(|| settlement_hashed_door_dir(site.kind, hh));
        place_settlement_building(
            ax, az, *site, hh, door_dir, None, seed, chunk, wx_min, wy_min, wz_min,
        );
    }
    place_settlement_workstations(
        ax, az, seed, chunk, wx_min, wy_min, wz_min, COBBLESTONE, None,
    );
    place_settlement_social_props(
        ax, az, seed, chunk, wx_min, wy_min, wz_min, COBBLESTONE, None,
    );

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
        let level = wy - base_h;
        let accent_i = level / 5;
        let accent_corner = (accent_i + ((h >> 12) & 3) as i32) & 3;
        for dz in -1..=1 {
            for dx in -1..=1 {
                let wall = dx == -1 || dx == 1 || dz == -1 || dz == 1;
                if wall {
                    // One corner accent every five levels breaks the blank shaft
                    // without turning the intact tower into a ruin.
                    let corner = match accent_corner {
                        0 => (-1, -1),
                        1 => (1, -1),
                        2 => (1, 1),
                        _ => (-1, 1),
                    };
                    let b = if level % 5 == 0 && (dx, dz) == corner {
                        if accent_i & 1 == 0 { MOSSY_STONE } else { STONE_RUBBLE }
                    } else {
                        STONE_BRICK
                    };
                    struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, b);
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

    // Four tapered buttresses give the lower tower a grounded, non-box silhouette.
    // Their rubble caps use the custom broken-stone mesh, so the transition back to
    // the narrow shaft is visibly shaped instead of another stack of full cubes.
    for (dx, dz) in [(-2, 0), (2, 0), (0, -2), (0, 2)] {
        struct_set(chunk, ax + dx, base_h + 2, az + dz, wx_min, wy_min, wz_min, COBBLESTONE);
        struct_set(chunk, ax + dx, base_h + 3, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
        struct_set(chunk, ax + dx, base_h + 4, az + dz, wx_min, wy_min, wz_min, STONE_RUBBLE);
    }

    // Small rubble corbels repeat up the shaft without turning the intact tower
    // into a bulky solid column or a noisy ruin.
    let mut band_y = base_h + 7;
    while band_y <= top_y - 2 {
        for (dx, dz) in [(-2, 0), (2, 0), (0, -2), (0, 2)] {
            struct_set(chunk, ax + dx, band_y, az + dz, wx_min, wy_min, wz_min, STONE_RUBBLE);
        }
        band_y += 6;
    }

    // Staggered slit windows break all four faces rather than leaving two long,
    // uninterrupted stone slabs.
    let low = base_h + 2 + shaft_h / 3;
    let mid = base_h + 2 + shaft_h / 2;
    let high = base_h + 2 + (shaft_h * 2) / 3;
    struct_set(chunk, ax, low, az - 1, wx_min, wy_min, wz_min, GLASS_PANE);
    struct_set(chunk, ax, high, az + 1, wx_min, wy_min, wz_min, GLASS_PANE);
    struct_set(chunk, ax + 1, mid, az, wx_min, wy_min, wz_min, GLASS_PANE);
    struct_set(chunk, ax - 1, mid, az, wx_min, wy_min, wz_min, GLASS_PANE);

    // Crenellated crown: a wider 5x5 cobble rim overhangs the shaft, with an
    // irregular mix of full and shaped merlons. The one-block projection makes the
    // top read from the ground instead of continuing the same rectangular shaft.
    for dz in -2..=2 {
        for dx in -2..=2 {
            let rim = dx == -2 || dx == 2 || dz == -2 || dz == 2;
            if !rim {
                continue;
            }
            struct_set(chunk, ax + dx, top_y + 1, az + dz, wx_min, wy_min, wz_min, COBBLESTONE);
            let corner = dx.abs() == 2 && dz.abs() == 2;
            let cardinal = (dx == 0 && dz.abs() == 2) || (dz == 0 && dx.abs() == 2);
            if corner || cardinal {
                struct_set(chunk, ax + dx, top_y + 2, az + dz, wx_min, wy_min, wz_min, STONE_RUBBLE);
            }
        }
    }
    // Beacon at the very top so the tower reads from a distance.
    struct_set(chunk, ax, top_y + 1, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    struct_set(chunk, ax, base_h + 2, az, wx_min, wy_min, wz_min, GLOW_BLOCK);

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

#[inline]
fn weathered_keep_stone(h: u64, dx: i32, dz: i32, level: i32) -> BlockId {
    let salt = (dx as u32 as u64)
        ^ ((dz as u32 as u64) << 21)
        ^ ((level as u32 as u64) << 42);
    match fmix64(h ^ salt) % 13 {
        0 => MOSSY_STONE,
        1 | 2 => COBBLESTONE,
        _ => STONE_BRICK,
    }
}

// A small keep / castle: a square weathered-stone curtain wall (9x9 footprint, half
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
                let b = weathered_keep_stone(h, dx, dz, wy - base_h);
                struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, b);
            }
            // Shaped, chipped crenellations break the full-cube skyline while keeping
            // the broad solid collision cell expected of a defensive wall.
            if !corner && ((dx + dz) & 1) == 0 {
                struct_set(chunk, ax + dx, wall_top + 1, az + dz, wx_min, wy_min, wz_min, STONE_RUBBLE);
            }
        }
    }

    // Corner turrets, two blocks taller than the wall.
    let turret = [[-r, -r], [r, -r], [-r, r], [r, r]];
    for t in turret.iter() {
        for wy in (base_h + 1)..=(wall_top + 2) {
            let b = weathered_keep_stone(h, t[0], t[1], wy - base_h);
            struct_set(chunk, ax + t[0], wy, az + t[1], wx_min, wy_min, wz_min, b);
        }
        struct_set(chunk, ax + t[0], wall_top + 3, az + t[1], wx_min, wy_min, wz_min, STONE_RUBBLE);
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
                        let b = weathered_keep_stone(h ^ 0x48414C4C, dx, dz, wy - base_h);
                        struct_set(chunk, ax + dx, wy, az + dz, wx_min, wy_min, wz_min, b);
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
            let supports_structure = dx.abs() == r
                || dz.abs() == r
                || matches!((dx, dz), (-2, 2) | (2, -2) | (1, 1) | (-3, -2) | (3, 1) | (-1, 3));
            if (fh & 0x7) == 0 && !supports_structure {
                continue; // a hole in the floor surface (foundation below remains)
            }
            let b = match (fh >> 4) % 7 {
                0 => STONE_BRICK,
                1 | 2 => MOSSY_STONE,
                _ => COBBLESTONE,
            };
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
                let b = if wy == rise {
                    STONE_RUBBLE
                } else {
                    match (wh >> (wy as u32 + 4)) % 5 {
                        0 => MOSSY_STONE,
                        1 => COBBLESTONE,
                        _ => STONE_BRICK,
                    }
                };
                struct_set(chunk, ax + dx, base_h + wy, az + dz, wx_min, wy_min, wz_min, b);
            }
        }
    }

    // A guaranteed readable south entrance: two clear floor-to-head cells under a
    // chipped two-piece lintel, with taller flanking buttresses. Clear everything
    // above the lintel so the random wall pass cannot bury this silhouette.
    for dx in [-1, 0] {
        for wy in 1..=2 {
            struct_clear(chunk, ax + dx, base_h + wy, az - r, wx_min, wy_min, wz_min);
        }
        struct_set(chunk, ax + dx, base_h + 3, az - r, wx_min, wy_min, wz_min, STONE_RUBBLE);
        for wy in 4..=(wall_h + 2) {
            struct_clear(chunk, ax + dx, base_h + wy, az - r, wx_min, wy_min, wz_min);
        }
    }
    for (dx, lower) in [(-2, COBBLESTONE), (1, MOSSY_STONE)] {
        for wy in 1..=3 {
            let b = if wy == 2 { STONE_BRICK } else { lower };
            struct_set(chunk, ax + dx, base_h + wy, az - r, wx_min, wy_min, wz_min, b);
        }
        struct_set(chunk, ax + dx, base_h + 4, az - r, wx_min, wy_min, wz_min, STONE_RUBBLE);
    }

    // A broken inner stub: a couple of standing pillars and toppled rubble.
    let pillars = [[-2, 2], [2, -2], [1, 1]];
    for (i, p) in pillars.iter().enumerate() {
        let ph = fmix64(h ^ ((i as u64).wrapping_mul(0x9E37).wrapping_add(5)));
        let ph_top = base_h + 1 + (ph % 4) as i32;
        for wy in (base_h + 1)..=ph_top {
            let b = if wy == ph_top {
                STONE_RUBBLE
            } else if (ph >> ((wy - base_h) as u32)) & 1 != 0 {
                MOSSY_STONE
            } else {
                STONE_BRICK
            };
            struct_set(chunk, ax + p[0], wy, az + p[1], wx_min, wy_min, wz_min, b);
        }
    }

    // Three substantial collapsed piles interrupt the square footprint without
    // filling the courtyard. They sit on guaranteed floor cells and use persistent
    // shaped chunk geometry, not distance-culled pebble props.
    for p in [[-3, -2], [3, 1], [-1, 3]] {
        struct_set(chunk, ax + p[0], base_h + 1, az + p[1], wx_min, wy_min, wz_min, STONE_RUBBLE);
    }

    // Overgrowth + a hint of treasure inside the ruin.
    struct_set(chunk, ax, base_h + 1, az, wx_min, wy_min, wz_min, MUSHROOM);
    struct_set(chunk, ax - 1, base_h + 1, az, wx_min, wy_min, wz_min, MOSSY_STONE);
    if (h >> 33) & 1 != 0 {
        struct_set(chunk, ax + 1, base_h + 1, az - 1, wx_min, wy_min, wz_min, CHEST);
    }

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

#[allow(clippy::too_many_arguments)]
fn place_castle_room<C: Chunk>(
    cx: i32,
    cz: i32,
    rx: i32,
    rz: i32,
    height: i32,
    h: u64,
    floor_y: i32,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    for dz in -rz..=rz {
        for dx in -rx..=rx {
            let edge = dx.abs() == rx || dz.abs() == rz;
            let door = dz == -rz && dx == 0;
            if edge {
                for dy in 1..=height {
                    if door && dy <= 2 {
                        continue;
                    }
                    let window = dy == 3
                        && ((dx == -rx || dx == rx) && dz == 0
                            || dz == rz && dx.abs() == rx.saturating_sub(1));
                    let b = if window {
                        GLASS_PANE
                    } else {
                        weathered_keep_stone(h, cx + dx, cz + dz, dy)
                    };
                    struct_set(chunk, cx + dx, floor_y + dy, cz + dz, wx_min, wy_min, wz_min, b);
                }
            }
        }
    }
    struct_set(chunk, cx, floor_y + 1, cz - rz, wx_min, wy_min, wz_min, OAK_DOOR);
    struct_set(chunk, cx, floor_y + 2, cz - rz, wx_min, wy_min, wz_min, OAK_DOOR);
    place_pitched_roof(
        cx,
        cz,
        rx,
        rz,
        floor_y + height,
        rx >= rz,
        STONE_BRICK,
        OAK_PLANKS,
        chunk,
        wx_min,
        wy_min,
        wz_min,
    );
}

// A destination-scale fortress: broad curtain walls, four tall corner towers, a
// gatehouse, and three separately enterable rooms around an open boss courtyard.
// The footprint replaces an old big landmark candidate, so it adds spectacle without
// increasing total structure density.
fn place_boss_castle<C: Chunk>(
    ax: i32,
    az: i32,
    h: u64,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    const R: i32 = 10;
    let base_h = struct_levelled_floor(ax, az, 11, seed);

    // Level and pave the enclosure. Clearing above the paving gives the boss arena
    // and every room deterministic headroom even on a rugged former keep site.
    for dz in -R..=R {
        for dx in -R..=R {
            let b = if dx.abs() <= 3 && dz.abs() <= 3 {
                STONE_BRICK
            } else {
                COBBLESTONE
            };
            struct_fill_col(chunk, ax + dx, az + dz, base_h, seed, wx_min, wy_min, wz_min, b);
            struct_set(chunk, ax + dx, base_h, az + dz, wx_min, wy_min, wz_min, b);
            for dy in 1..=13 {
                struct_clear(chunk, ax + dx, base_h + dy, az + dz, wx_min, wy_min, wz_min);
            }
        }
    }

    // Curtain wall and a three-wide south gate beneath a high, readable arch.
    for dz in -R..=R {
        for dx in -R..=R {
            if dx.abs() != R && dz.abs() != R {
                continue;
            }
            let gate = dz == -R && dx.abs() <= 1;
            for dy in 1..=6 {
                if gate && dy <= 3 {
                    continue;
                }
                let b = weathered_keep_stone(h ^ 0x00CA_571E, dx, dz, dy);
                struct_set(chunk, ax + dx, base_h + dy, az + dz, wx_min, wy_min, wz_min, b);
            }
            if !gate && (dx + dz).rem_euclid(2) == 0 {
                struct_set(chunk, ax + dx, base_h + 7, az + dz, wx_min, wy_min, wz_min, STONE_RUBBLE);
            }
        }
    }
    for dx in -1..=1 {
        struct_set(chunk, ax + dx, base_h + 4, az - R, wx_min, wy_min, wz_min, STONE_BRICK);
    }
    for dx in [-3, 3] {
        for dy in 1..=9 {
            struct_set(chunk, ax + dx, base_h + dy, az - R, wx_min, wy_min, wz_min, STONE_BRICK);
        }
        struct_set(chunk, ax + dx, base_h + 10, az - R, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    }

    // Four hollow 5x5 corner towers rise well above the wall and carry bright crowns.
    for (sx, sz) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
        let (cx, cz) = (ax + sx * 9, az + sz * 9);
        for dz in -2i32..=2 {
            for dx in -2i32..=2 {
                let edge = dx.abs() == 2 || dz.abs() == 2;
                if edge {
                    struct_fill_col(chunk, cx + dx, cz + dz, base_h, seed, wx_min, wy_min, wz_min, STONE_BRICK);
                    for dy in 1..=11 {
                        let b = weathered_keep_stone(h ^ 0x705E, cx + dx, cz + dz, dy);
                        struct_set(chunk, cx + dx, base_h + dy, cz + dz, wx_min, wy_min, wz_min, b);
                    }
                    if (dx + dz).rem_euclid(2) == 0 {
                        struct_set(chunk, cx + dx, base_h + 12, cz + dz, wx_min, wy_min, wz_min, STONE_RUBBLE);
                    }
                }
                struct_set(chunk, cx + dx, base_h + 8, cz + dz, wx_min, wy_min, wz_min, OAK_PLANKS);
            }
        }
        for dy in 9..=12 {
            struct_set(chunk, cx, base_h + dy, cz, wx_min, wy_min, wz_min, WOOD_BEAM);
        }
        struct_set(chunk, cx, base_h + 13, cz, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    }

    // Three true rooms: a high treasure hall and two lower side chambers. Their
    // doors all open into the courtyard, leaving a wide clear arena at the anchor.
    place_castle_room(ax, az + 6, 4, 3, 7, h ^ 0x4841_4C4C, base_h, chunk, wx_min, wy_min, wz_min);
    place_castle_room(ax - 7, az + 1, 2, 3, 5, h ^ 0x1EF7, base_h, chunk, wx_min, wy_min, wz_min);
    place_castle_room(ax + 7, az + 1, 2, 3, 5, h ^ 0x2197, base_h, chunk, wx_min, wy_min, wz_min);

    // Supported stairs reach the east curtain walk; each tread rises one block and
    // remains horizontally adjacent to the next, making traversal possible by jumps.
    for step in 1..=5 {
        for dy in 1..=step {
            struct_set(
                chunk,
                ax + 8,
                base_h + dy,
                az - 9 + step,
                wx_min,
                wy_min,
                wz_min,
                STONE_BRICK,
            );
        }
    }
    for dz in -9..=9 {
        struct_set(chunk, ax + 9, base_h + 6, az + dz, wx_min, wy_min, wz_min, COBBLESTONE);
    }

    // Guarded high-tier rewards: the final hall chest is six blocks from the boss
    // anchor so the existing proximity-based loot system can classify it exactly.
    struct_set(chunk, ax, base_h + 1, az + 6, wx_min, wy_min, wz_min, CHEST);
    struct_set(chunk, ax - 7, base_h + 1, az + 1, wx_min, wy_min, wz_min, CHEST);
    struct_set(chunk, ax - 3, base_h + 4, az + 3, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    struct_set(chunk, ax + 3, base_h + 4, az + 3, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

// A taller, wider successor to the old mage tower. The hollow shaft contains a
// continuous supported spiral climb, two landings, and a reward chamber at the top.
fn place_grand_tower<C: Chunk>(
    ax: i32,
    az: i32,
    h: u64,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    const R: i32 = 4;
    const TOP: i32 = 23;
    let base_h = struct_levelled_floor(ax, az, 6, seed);

    for dz in -5..=5 {
        for dx in -5..=5 {
            struct_fill_col(chunk, ax + dx, az + dz, base_h, seed, wx_min, wy_min, wz_min, COBBLESTONE);
            struct_set(chunk, ax + dx, base_h, az + dz, wx_min, wy_min, wz_min, COBBLESTONE);
        }
    }
    for dy in 1..=TOP {
        let r = R;
        for dz in -r..=r {
            for dx in -r..=r {
                let edge = dx.abs() == r || dz.abs() == r;
                if edge {
                    let window = (dy % 6 == 3 || dy % 6 == 4)
                        && ((dx == 0 && dz.abs() == r) || (dz == 0 && dx.abs() == r));
                    let b = if window {
                        GLASS_PANE
                    } else {
                        weathered_keep_stone(h ^ 0x0007_0AE2, dx, dz, dy)
                    };
                    struct_set(chunk, ax + dx, base_h + dy, az + dz, wx_min, wy_min, wz_min, b);
                } else {
                    struct_clear(chunk, ax + dx, base_h + dy, az + dz, wx_min, wy_min, wz_min);
                }
            }
        }
    }

    // Enterable south doorway with a solid lintel.
    struct_set(chunk, ax, base_h + 1, az - R, wx_min, wy_min, wz_min, OAK_DOOR);
    struct_set(chunk, ax, base_h + 2, az - R, wx_min, wy_min, wz_min, OAK_DOOR);
    struct_set(chunk, ax, base_h + 3, az - R, wx_min, wy_min, wz_min, STONE_BRICK);

    // Tapered exterior buttresses and lamps make the silhouette legible at distance.
    for (dx, dz) in [(-5, 0), (5, 0), (0, 5)] {
        for dy in 1..=5 {
            let inward = (dy - 1) / 3;
            let bx = ax + dx - dx.signum() * inward;
            let bz = az + dz - dz.signum() * inward;
            struct_set(chunk, bx, base_h + dy, bz, wx_min, wy_min, wz_min, STONE_BRICK);
        }
        struct_set(chunk, ax + dx, base_h + 2, az + dz, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    }

    // Flank the entrance instead of blocking its centreline with a south buttress.
    for dx in [-2, 2] {
        for dy in 1..=3 {
            struct_set(chunk, ax + dx, base_h + dy, az - 5, wx_min, wy_min, wz_min, STONE_BRICK);
        }
        struct_set(chunk, ax + dx, base_h + 4, az - 5, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    }

    // Projecting balcony bands divide the tall shaft into readable stages.
    for band in [8, 16] {
        for dz in -5i32..=5 {
            for dx in -5i32..=5 {
                let edge = dx.abs().max(dz.abs());
                if edge == 4 || edge == 5 {
                    struct_set(chunk, ax + dx, base_h + band, az + dz, wx_min, wy_min, wz_min, COBBLESTONE);
                }
            }
        }
        for (dx, dz) in [(-5, -5), (5, -5), (-5, 5), (5, 5), (0, -5), (0, 5), (-5, 0), (5, 0)] {
            struct_set(chunk, ax + dx, base_h + band + 1, az + dz, wx_min, wy_min, wz_min, STONE_RUBBLE);
        }
    }

    // A 24-step loop around the inner 7x7 perimeter. Each tread is attached to the
    // surrounding shaft instead of becoming a floor-to-ceiling wooden pylon.
    let loop_cells = [
        (0, -3), (1, -3), (2, -3), (3, -3), (3, -2), (3, -1),
        (3, 0), (3, 1), (3, 2), (3, 3), (2, 3), (1, 3),
        (0, 3), (-1, 3), (-2, 3), (-3, 3), (-3, 2), (-3, 1),
        (-3, 0), (-3, -1), (-3, -2), (-3, -3), (-2, -3), (-1, -3),
    ];
    for (i, &(dx, dz)) in loop_cells.iter().enumerate() {
        let step = i as i32 + 1;
        struct_set(chunk, ax + dx, base_h + step, az + dz, wx_min, wy_min, wz_min, OAK_PLANKS);
    }

    // Compact side landings connect to steps 8 and 16 without roofing over lower
    // treads. The crown deck connects one cell inward from the final step.
    for dz in 0..=2 {
        for dx in 0..=2 {
            let b = if dx == 0 && dz == 0 { GLOW_BLOCK } else { OAK_PLANKS };
            struct_set(chunk, ax + dx, base_h + 8, az + dz, wx_min, wy_min, wz_min, b);
        }
    }
    for dz in 1..=2 {
        for dx in -2..=0 {
            let b = if dx == 0 && dz == 1 { GLOW_BLOCK } else { OAK_PLANKS };
            struct_set(chunk, ax + dx, base_h + 15, az + dz, wx_min, wy_min, wz_min, b);
        }
    }
    struct_set(chunk, ax - 2, base_h + 15, az + 3, wx_min, wy_min, wz_min, OAK_PLANKS);
    for dz in -2..=2 {
        for dx in -2..=2 {
            struct_set(chunk, ax + dx, base_h + TOP + 1, az + dz, wx_min, wy_min, wz_min, OAK_PLANKS);
        }
    }
    for dz in -4i32..=4 {
        for dx in -4i32..=4 {
            if dx.abs() == 4 || dz.abs() == 4 {
                struct_set(chunk, ax + dx, base_h + TOP + 1, az + dz, wx_min, wy_min, wz_min, STONE_BRICK);
                if (dx + dz).rem_euclid(2) == 0 {
                    struct_set(chunk, ax + dx, base_h + TOP + 2, az + dz, wx_min, wy_min, wz_min, STONE_RUBBLE);
                }
            }
        }
    }
    for (dx, dz) in [(-4, -4), (4, -4), (-4, 4), (4, 4)] {
        for dy in (TOP + 2)..=(TOP + 4) {
            struct_set(chunk, ax + dx, base_h + dy, az + dz, wx_min, wy_min, wz_min, WOOD_BEAM);
        }
        struct_set(chunk, ax + dx, base_h + TOP + 5, az + dz, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    }
    struct_set(chunk, ax, base_h + TOP + 2, az, wx_min, wy_min, wz_min, CHEST);
    struct_set(chunk, ax, base_h + TOP + 3, az, wx_min, wy_min, wz_min, CRYSTAL_LAMP);
    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

const CITY_WALL_R: i32 = 9;
const CITY_LOT_RADII: [i32; 4] = [19, 27, 35, 43];
const CITY_LOT_OFFSETS: [i32; 4] = [16, 17, 18, 19];
const CITY_ARTERIAL_R: i32 = CITY_LOT_RADII[3] + 4;
const CITY_CARDINALS: [(i32, i32); 4] = [(1, 0), (-1, 0), (0, 1), (0, -1)];

struct CityRoadBranch {
    floor_y: i32,
    profile: Vec<(i32, i32, i32)>,
}

struct CityRoadPlan {
    floor_y: i32,
    arteries: [Vec<(i32, i32, i32)>; 4],
    branches: Vec<CityRoadBranch>,
}

#[inline]
fn city_floor_height(ax: i32, az: i32, seed: u64) -> i32 {
    // HOME spawns at +2,+2. Keeping the authored civic floor at that exact
    // surface preserves safe spawn height while the rest of the enclosure is
    // filled or cut to match it.
    struct_surface(ax + 2, az + 2, seed).max(SEA_LEVEL + 1)
}

#[inline]
fn city_wall_material(h: u64, dx: i32, dz: i32) -> BlockId {
    let salt = (dx as u32 as u64) | ((dz as u32 as u64) << 32);
    match fmix64(h ^ salt) % 7 {
        0 => MOSSY_STONE,
        1 => COBBLESTONE,
        _ => STONE_BRICK,
    }
}

fn city_arterial_dir(site: SettlementSite) -> (i32, i32) {
    if site.dx.abs() >= site.dz.abs() {
        (site.dx.signum(), 0)
    } else {
        (0, site.dz.signum())
    }
}

fn city_arterial_profile(
    ax: i32,
    az: i32,
    dir: (i32, i32),
    floor_y: i32,
    seed: u64,
) -> Vec<(i32, i32, i32)> {
    let mut profile = Vec::with_capacity((CITY_ARTERIAL_R - CITY_WALL_R + 1) as usize);
    let mut road_y = floor_y;
    for radius in CITY_WALL_R..=CITY_ARTERIAL_R {
        let (dx, dz) = (dir.0 * radius, dir.1 * radius);
        if radius > CITY_WALL_R {
            let natural = struct_surface(ax + dx, az + dz, seed).max(SEA_LEVEL + 1);
            road_y = natural.clamp(road_y - 1, road_y + 1);
        }
        profile.push((dx, dz, road_y));
    }
    profile
}

#[cfg(test)]
fn city_point_on_artery(point: (i32, i32)) -> bool {
    (point.0.abs() > CITY_WALL_R
        && point.0.abs() <= CITY_ARTERIAL_R
        && point.1.abs() <= 1)
        || (point.1.abs() > CITY_WALL_R
            && point.1.abs() <= CITY_ARTERIAL_R
            && point.0.abs() <= 1)
}

fn build_city_road_plan(
    ax: i32,
    az: i32,
    city_hash: u64,
    seed: u64,
    sites: &[SettlementSite],
) -> CityRoadPlan {
    let floor_y = city_floor_height(ax, az, seed);
    let arteries = CITY_CARDINALS.map(|dir| city_arterial_profile(ax, az, dir, floor_y, seed));
    let mut branches = Vec::with_capacity(sites.len());
    for (i, &site) in sites.iter().enumerate() {
        let h = fmix64(
            city_hash
                ^ ((i as u64)
                    .wrapping_mul(0x9E3779B97F4A7C15)
                .wrapping_add(131)),
        );
        let (mut entrance, _, _) = city_site_road_target(ax, az, site, h, seed);
        let dir = city_arterial_dir(site);
        let artery_index = CITY_CARDINALS.iter().position(|&artery| artery == dir).unwrap();
        let radius = if dir.0 != 0 { site.dx.abs() } else { site.dz.abs() };
        let &(center_x, center_z, start_y) =
            &arteries[artery_index][(radius - CITY_WALL_R) as usize];
        let lane = if dir.0 != 0 { site.dz.signum() } else { site.dx.signum() };
        let (mut dx, mut dz) = if dir.0 != 0 {
            (center_x, lane)
        } else {
            (lane, center_z)
        };
        let mut points = vec![(dx, dz)];
        if dir.0 != 0 {
            while dz != entrance.approach_dz {
                dz += (entrance.approach_dz - dz).signum();
                points.push((dx, dz));
            }
        } else {
            while dx != entrance.approach_dx {
                dx += (entrance.approach_dx - dx).signum();
                points.push((dx, dz));
            }
        }
        let steps = points.len() as i32 - 1;
        entrance.floor_y = entrance.floor_y.clamp(start_y - steps, start_y + steps);
        let profile = settlement_grade_road_profile(
            ax, az, points, start_y, entrance.floor_y, seed,
        );
        branches.push(CityRoadBranch { floor_y: entrance.floor_y, profile });
    }
    CityRoadPlan { floor_y, arteries, branches }
}

fn shared_city_road_plan(
    ax: i32,
    az: i32,
    city_hash: u64,
    seed: u64,
    sites: &[SettlementSite],
) -> std::sync::Arc<CityRoadPlan> {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock};
    const CAP: usize = 128;
    type PlanCell = Arc<OnceLock<Arc<CityRoadPlan>>>;
    static MEMO: OnceLock<Mutex<HashMap<(u64, u64, i32, i32), PlanCell>>> = OnceLock::new();
    let ax = wrap_world(ax);
    let az = wrap_world(az);
    let key = (seed, city_hash, ax, az);
    let memo = MEMO.get_or_init(|| Mutex::new(HashMap::new()));
    let cell = {
        let mut map = memo.lock().unwrap();
        if let Some(hit) = map.get(&key) {
            hit.clone()
        } else {
            if map.len() >= CAP {
                map.clear();
            }
            let cell = Arc::new(OnceLock::new());
            map.insert(key, cell.clone());
            cell
        }
    };
    cell.get_or_init(|| Arc::new(build_city_road_plan(ax, az, city_hash, seed, sites)))
        .clone()
}

#[allow(clippy::too_many_arguments)]
fn place_city_lot_pad<C: Chunk>(
    ax: i32,
    az: i32,
    site: SettlementSite,
    h: u64,
    floor_y: i32,
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    let (rx, rz) = city_lot_pad_half_extents(site, h);
    let (cx, cz) = (ax + site.dx, az + site.dz);
    if cx + rx < wx_min
        || cx - rx > wx_min + K_CHUNK_DIM - 1
        || cz + rz < wz_min
        || cz - rz > wz_min + K_CHUNK_DIM - 1
    {
        return;
    }

    for dz in -rz..=rz {
        let wz = cz + dz;
        if wz < wz_min || wz > wz_min + K_CHUNK_DIM - 1 {
            continue;
        }
        for dx in -rx..=rx {
            let wx = cx + dx;
            if wx < wx_min || wx > wx_min + K_CHUNK_DIM - 1 {
                continue;
            }
            let natural = struct_surface(wx, wz, seed);
            if natural < floor_y {
                for wy in (natural + 1)..floor_y {
                    struct_set(
                        chunk, wx, wy, wz, wx_min, wy_min, wz_min, COBBLESTONE,
                    );
                }
            }
            struct_set(
                chunk, wx, floor_y, wz, wx_min, wy_min, wz_min, COBBLESTONE,
            );
            if natural > floor_y {
                for wy in (floor_y + 1)..=(natural + 1) {
                    struct_clear(chunk, wx, wy, wz, wx_min, wy_min, wz_min);
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn place_city_arterial<C: Chunk>(
    ax: i32,
    az: i32,
    dir: (i32, i32),
    profile: &[(i32, i32, i32)],
    seed: u64,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    for &(dx, dz, road_y) in profile.iter().skip(1) {
        for lane in -1..=1 {
            let (lane_x, lane_z) = if dir.0 != 0 { (0, lane) } else { (lane, 0) };
            settlement_pave_profiled(
                chunk,
                ax + dx + lane_x,
                road_y,
                az + dz + lane_z,
                seed,
                wx_min,
                wy_min,
                wz_min,
                STONE_BRICK,
            );
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn place_city_gate_x<C: Chunk>(
    ax: i32,
    az: i32,
    side: i32,
    floor_y: i32,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    let gate_x = ax + side * CITY_WALL_R;
    let lintel_y = floor_y + 4;
    for dz in [-2, 2] {
        let wz = az + dz;
        for wy in (floor_y + 1)..=lintel_y {
            struct_set(chunk, gate_x, wy, wz, wx_min, wy_min, wz_min, WOOD_BEAM);
        }
        struct_set(
            chunk,
            gate_x,
            lintel_y + 1,
            wz,
            wx_min,
            wy_min,
            wz_min,
            CRYSTAL_LAMP,
        );
    }
    for dz in -2..=2 {
        struct_set(
            chunk,
            gate_x,
            lintel_y,
            az + dz,
            wx_min,
            wy_min,
            wz_min,
            WOOD_BEAM,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn place_city_gate_z<C: Chunk>(
    ax: i32,
    az: i32,
    side: i32,
    floor_y: i32,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    let gate_z = az + side * CITY_WALL_R;
    let lintel_y = floor_y + 4;
    for dx in [-2, 2] {
        let wx = ax + dx;
        for wy in (floor_y + 1)..=lintel_y {
            struct_set(chunk, wx, wy, gate_z, wx_min, wy_min, wz_min, WOOD_BEAM);
        }
        struct_set(
            chunk,
            wx,
            lintel_y + 1,
            gate_z,
            wx_min,
            wy_min,
            wz_min,
            CRYSTAL_LAMP,
        );
    }
    for dx in -2..=2 {
        struct_set(
            chunk,
            ax + dx,
            lintel_y,
            gate_z,
            wx_min,
            wy_min,
            wz_min,
            WOOD_BEAM,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn place_city_corner_tower<C: Chunk>(
    ax: i32,
    az: i32,
    sx: i32,
    sz: i32,
    h: u64,
    seed: u64,
    floor_y: i32,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    let cx = ax + sx * CITY_WALL_R;
    let cz = az + sz * CITY_WALL_R;
    let deck_y = floor_y + 1;

    // A compact stone plinth follows the slope; the upper tower stays open and
    // uses the shaped timber vocabulary instead of becoming another solid cube.
    for dz in -1..=1 {
        for dx in -1..=1 {
            let b = city_wall_material(h ^ 0x70A3, sx * 16 + dx, sz * 16 + dz);
            struct_fill_col(
                chunk,
                cx + dx,
                cz + dz,
                deck_y,
                seed,
                wx_min,
                wy_min,
                wz_min,
                b,
            );
        }
    }
    for (dx, dz) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
        for wy in (deck_y + 1)..=(deck_y + 4) {
            struct_set(chunk, cx + dx, wy, cz + dz, wx_min, wy_min, wz_min, WOOD_BEAM);
        }
    }
    for dz in -1i32..=1 {
        for dx in -1i32..=1 {
            if dx.abs() == 1 || dz.abs() == 1 {
                struct_set(
                    chunk,
                    cx + dx,
                    deck_y + 2,
                    cz + dz,
                    wx_min,
                    wy_min,
                    wz_min,
                    WOOD_BEAM,
                );
            }
        }
    }
    place_pitched_roof(
        cx,
        cz,
        1,
        1,
        deck_y + 4,
        sx == sz,
        WOOD_BEAM,
        BIRCH_PLANKS,
        chunk,
        wx_min,
        wy_min,
        wz_min,
    );
    struct_set(
        chunk,
        cx,
        deck_y + 4,
        cz,
        wx_min,
        wy_min,
        wz_min,
        CRYSTAL_LAMP,
    );
    for wy in (deck_y + 5)..=(deck_y + 6) {
        struct_set(chunk, cx, wy, cz, wx_min, wy_min, wz_min, WOOD_BEAM);
    }
}

#[allow(clippy::too_many_arguments)]
fn place_city_civic_landmark<C: Chunk>(
    ax: i32,
    az: i32,
    base_y: i32,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    for (dx, dz, b) in [
        (0, 0, MOSSY_STONE),
        (-1, 0, COBBLESTONE),
        (1, 0, COBBLESTONE),
        (0, -1, COBBLESTONE),
        (0, 1, COBBLESTONE),
    ] {
        struct_set(chunk, ax + dx, base_y, az + dz, wx_min, wy_min, wz_min, b);
    }
    for wy in (base_y + 1)..=(base_y + 5) {
        struct_set(chunk, ax, wy, az, wx_min, wy_min, wz_min, WOOD_BEAM);
    }
    for d in -1..=1 {
        struct_set(chunk, ax + d, base_y + 5, az, wx_min, wy_min, wz_min, WOOD_BEAM);
        struct_set(chunk, ax, base_y + 5, az + d, wx_min, wy_min, wz_min, WOOD_BEAM);
    }
    for (dx, dz) in [(-2, 0), (2, 0), (0, -2), (0, 2)] {
        struct_set(
            chunk,
            ax + dx,
            base_y + 5,
            az + dz,
            wx_min,
            wy_min,
            wz_min,
            CRYSTAL_LAMP,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn place_city_core<C: Chunk>(
    ax: i32,
    az: i32,
    h: u64,
    seed: u64,
    floor_y: i32,
    chunk: &mut C,
    wx_min: i32,
    wy_min: i32,
    wz_min: i32,
) {
    // A city core is deliberately developed land, not untouched biome inside a
    // wall. Level every enclosed column, clear its old plant cell, and pave it.
    for dz in -CITY_WALL_R..=CITY_WALL_R {
        for dx in -CITY_WALL_R..=CITY_WALL_R {
            let wx = ax + dx;
            let wz = az + dz;
            if wx < wx_min
                || wx > wx_min + K_CHUNK_DIM - 1
                || wz < wz_min
                || wz > wz_min + K_CHUNK_DIM - 1
            {
                continue;
            }
            let natural = struct_surface(wx, wz, seed);
            struct_fill_col(
                chunk, wx, wz, floor_y, seed, wx_min, wy_min, wz_min, COBBLESTONE,
            );
            if natural > floor_y {
                for wy in (floor_y + 1)..=(natural + 1) {
                    struct_clear(chunk, wx, wy, wz, wx_min, wy_min, wz_min);
                }
            } else {
                struct_clear(chunk, wx, floor_y + 1, wz, wx_min, wy_min, wz_min);
            }
            let plaza = dx.abs() <= 3 && dz.abs() <= 3;
            let avenue = dx.abs() <= 1 || dz.abs() <= 1;
            let paving = if plaza || avenue { STONE_BRICK } else { COBBLESTONE };
            struct_set(chunk, wx, floor_y, wz, wx_min, wy_min, wz_min, paving);
        }
    }

    for dz in -CITY_WALL_R..=CITY_WALL_R {
        for dx in -CITY_WALL_R..=CITY_WALL_R {
            if dx.abs() != CITY_WALL_R && dz.abs() != CITY_WALL_R {
                continue;
            }
            let gate = (dx.abs() == CITY_WALL_R && dz.abs() <= 2)
                || (dz.abs() == CITY_WALL_R && dx.abs() <= 2);
            let tower = dx.abs() >= CITY_WALL_R - 1 && dz.abs() >= CITY_WALL_R - 1;
            if gate || tower {
                continue;
            }
            let wx = ax + dx;
            let wz = az + dz;
            let edge_pos = if dx.abs() == CITY_WALL_R { dz } else { dx };
            let b = city_wall_material(h, dx, dz);
            if (edge_pos + CITY_WALL_R).rem_euclid(3) == 0 {
                // Timber is trim, not the wall plane: keep two solid courses
                // beneath a shaped cap so the fortification never turns into a
                // three-log-high see-through fence (#268).
                struct_set(chunk, wx, floor_y + 1, wz, wx_min, wy_min, wz_min, b);
                struct_set(chunk, wx, floor_y + 2, wz, wx_min, wy_min, wz_min, b);
                struct_set(chunk, wx, floor_y + 3, wz, wx_min, wy_min, wz_min, WOOD_BEAM);
            } else {
                struct_set(chunk, wx, floor_y + 1, wz, wx_min, wy_min, wz_min, b);
                struct_set(chunk, wx, floor_y + 2, wz, wx_min, wy_min, wz_min, b);
                if edge_pos.rem_euclid(2) == 0 {
                    struct_set(
                        chunk,
                        wx,
                        floor_y + 3,
                        wz,
                        wx_min,
                        wy_min,
                        wz_min,
                        STONE_BRICK,
                    );
                }
            }
        }
    }

    for side in [-1, 1] {
        place_city_gate_x(ax, az, side, floor_y, chunk, wx_min, wy_min, wz_min);
        place_city_gate_z(ax, az, side, floor_y, chunk, wx_min, wy_min, wz_min);
    }
    for (sx, sz) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
        place_city_corner_tower(
            ax, az, sx, sz, h, seed, floor_y, chunk, wx_min, wy_min, wz_min,
        );
    }
    place_city_civic_landmark(ax, az, floor_y, chunk, wx_min, wy_min, wz_min);
}

// A city: a finished walled civic core surrounded by a larger procedural settlement.
// Buildings still come from the village kit, but sit beyond the perimeter so gates,
// watchtowers, plaza, and landmark always remain readable and walkable.
fn place_city<C: Chunk>(ax: i32, az: i32, h: u64, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    let wanted = CITY_MIN_BUILDINGS + ((h >> 10) as usize % (CITY_MAX_BUILDINGS - CITY_MIN_BUILDINGS + 1));
    let (sites, n_sites) = city_sites(h, wanted);
    let road_plan = shared_city_road_plan(ax, az, h, seed, &sites[..n_sites]);
    let city_floor = road_plan.floor_y;
    for (i, site) in sites.iter().take(n_sites).enumerate() {
        let hh = fmix64(
            h ^ ((i as u64)
                .wrapping_mul(0x9E3779B97F4A7C15)
                .wrapping_add(131)),
        );
        place_city_lot_pad(
            ax,
            az,
            *site,
            hh,
            road_plan.branches[i].floor_y,
            seed,
            chunk,
            wx_min,
            wy_min,
            wz_min,
        );
    }
    for (dir, profile) in CITY_CARDINALS.into_iter().zip(&road_plan.arteries) {
        place_city_arterial(
            ax, az, dir, profile, seed, chunk, wx_min, wy_min, wz_min,
        );
    }
    for branch in &road_plan.branches {
        for &(dx, dz, road_y) in branch.profile.iter().skip(1) {
            settlement_pave_profiled(
                chunk,
                ax + dx,
                road_y,
                az + dz,
                seed,
                wx_min,
                wy_min,
                wz_min,
                STONE_BRICK,
            );
        }
    }
    for (i, site) in sites.iter().take(n_sites).enumerate() {
        let hh = fmix64(h ^ ((i as u64).wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(131)));
        let door_dir = settlement_home_half_extents(site.kind, hh)
            .map(|_| city_arterial_door_dir(*site))
            .unwrap_or_else(|| settlement_hashed_door_dir(site.kind, hh));
        place_settlement_building(
            ax,
            az,
            *site,
            hh,
            door_dir,
            Some(road_plan.branches[i].floor_y),
            seed,
            chunk,
            wx_min,
            wy_min,
            wz_min,
        );
    }
    place_city_core(ax, az, h, seed, city_floor, chunk, wx_min, wy_min, wz_min);
    place_settlement_workstations(
        ax, az, seed, chunk, wx_min, wy_min, wz_min, STONE_BRICK, Some(city_floor),
    );
    place_city_social_props(
        ax, az, seed, chunk, wx_min, wy_min, wz_min, city_floor,
    );

    struct_place_marker(ax, az, seed, chunk, wx_min, wy_min, wz_min);
}

fn place_structure<C: Chunk>(sd: &StructDesc, seed: u64, chunk: &mut C, wx_min: i32, wy_min: i32, wz_min: i32) {
    match sd.typ {
        x if x == STRUCT_CABIN => place_cabin(
            sd.anchor_wx,
            sd.anchor_wz,
            sd.cell_hash,
            settlement_hashed_door_dir(SETTLEMENT_BUILDING_CABIN, sd.cell_hash),
            seed,
            chunk,
            wx_min,
            wy_min,
            wz_min,
        ),
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
        x if x == STRUCT_BOSS_CASTLE => place_boss_castle(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        x if x == STRUCT_GRAND_TOWER => place_grand_tower(sd.anchor_wx, sd.anchor_wz, sd.cell_hash, seed, chunk, wx_min, wy_min, wz_min),
        _ => {}
    }
}
