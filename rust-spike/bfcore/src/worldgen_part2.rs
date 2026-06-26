// ===========================================================================
// Part 2 of the worldgen port (included from lib.rs).
// ===========================================================================

// ---------------------------------------------------------------------------
// Decoration constants
// ---------------------------------------------------------------------------
const TREE_CELL_SIZE: i32 = 6;

const CANOPY_ROUND: i32 = 0;
const CANOPY_TALL: i32 = 1;
const CANOPY_BROAD: i32 = 2;
const CANOPY_COMPACT: i32 = 3;
const CANOPY_PINE: i32 = 4;
const CANOPY_GIANT: i32 = 5;
const CANOPY_WEEPING: i32 = 6;
const CANOPY_FORKED: i32 = 7;

const TRUNK_MIN: i32 = 4;
const TRUNK_MAX: i32 = 12;

const CANOPY_MAX_REACH_XZ: i32 = 4;

const TREE_PROB_THRESH_DEFAULT: u64 = 12910;
const TREE_PROB_THRESH_FOREST: u64 = 51773;
const TREE_PROB_THRESH_SNOWY: u64 = 5530;
const TREE_PROB_THRESH_SWAMP: u64 = 7373;

const TREE_SEED_MIX: u64 = 0xD7C0DECAF00D1234;
const PLANT_SEED_MIX: u64 = 0xB16B00B5CAFE5EED;

#[inline]
fn tree_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

fn tree_cell(wx: i32, wz: i32) -> (i32, i32) {
    (tree_floordiv(wx, TREE_CELL_SIZE), tree_floordiv(wz, TREE_CELL_SIZE))
}

#[derive(Clone, Copy)]
struct TreeDesc {
    root_wx: i32,
    root_wz: i32,
    trunk_height: i32,
    canopy_shape: i32,
    log_id: BlockId,
    leaf_id: BlockId,
    present: bool,
    thick_trunk: bool,
    lean_dx: i32,
    lean_dz: i32,
    branch_count: i32,
    branch_hash: u64,
    leaf_hash: u64,
    sparse: i32,
    extra_skirt: i32,
}

const NO_TREE: TreeDesc = TreeDesc {
    root_wx: 0,
    root_wz: 0,
    trunk_height: 0,
    canopy_shape: 0,
    log_id: 0,
    leaf_id: 0,
    present: false,
    thick_trunk: false,
    lean_dx: 0,
    lean_dz: 0,
    branch_count: 0,
    branch_hash: 0,
    leaf_hash: 0,
    sparse: 0,
    extra_skirt: 0,
};

const MAX_BRANCHES: i32 = 3;
const BRANCH_LEN_MIN: i32 = 2;
const BRANCH_LEN_MAX: i32 = 3;
const BRANCH_DIRS: [[i32; 2]; 8] = [
    [1, 0],
    [-1, 0],
    [0, 1],
    [0, -1],
    [1, 1],
    [1, -1],
    [-1, 1],
    [-1, -1],
];

fn tree_for_cell(cell_cx: i32, cell_cz: i32, seed: u64) -> TreeDesc {
    let tseed = fmix64(seed ^ TREE_SEED_MIX);
    let h = hash2(cell_cx, cell_cz, tseed);

    let cell_origin_x = cell_cx * TREE_CELL_SIZE;
    let cell_origin_z = cell_cz * TREE_CELL_SIZE;
    let cell_centre_x = cell_origin_x + TREE_CELL_SIZE / 2;
    let cell_centre_z = cell_origin_z + TREE_CELL_SIZE / 2;
    let dom = voronoi_biome(cell_centre_x, cell_centre_z, seed);

    if dom == Biome::Desert || dom == Biome::Beach {
        return NO_TREE;
    }

    let thresh = match dom {
        Biome::Forest => TREE_PROB_THRESH_FOREST,
        Biome::Snowy => TREE_PROB_THRESH_SNOWY,
        Biome::Swamp => TREE_PROB_THRESH_SWAMP,
        _ => TREE_PROB_THRESH_DEFAULT,
    };

    let prob = h & 0xFFFF;
    if prob >= thresh {
        return NO_TREE;
    }

    let h2 = fmix64(h ^ 0x1234567890ABCDEF);
    let off_x = 1 + ((h2 >> 0) & 0x5) as i32;
    let off_z = 1 + ((h2 >> 8) & 0x5) as i32;

    let trunk_h: i32;
    let canopy_shape: i32;
    let is_birch: bool;
    let mut thick_trunk = false;
    let mut lean_dx = 0i32;
    let mut lean_dz = 0i32;

    let trunk_bits = (h2 >> 16) & 0xF;
    let shape_bits = (h2 >> 20) & 0x7;
    let birch_bits = (h2 >> 24) & 0x3;
    let giant_bits = (h2 >> 28) & 0xF;
    let lean_dir = (h2 >> 32) & 0x3;
    let lean_gate = (h2 >> 34) & 0x7;
    let thick_bit = (h2 >> 37) & 0x1;
    let branch_hash = fmix64(h2 ^ 0xB7A11C4E5B7A11C4);
    let leaf_hash = fmix64(h2 ^ 0x1EAF5EED1EAF5EED);
    let mut sparse = if ((leaf_hash >> 40) & 0x7) <= 1 { 1 } else { 0 };
    let extra_skirt = 0;

    let elder = (giant_bits == 0) && (((leaf_hash >> 8) & 0x3) == 0);

    if giant_bits == 0 && dom != Biome::Desert && dom != Biome::Beach {
        let trunk_h = if elder {
            13 + (trunk_bits % 4) as i32
        } else {
            10 + (trunk_bits % 3) as i32
        };
        return TreeDesc {
            root_wx: cell_origin_x + off_x,
            root_wz: cell_origin_z + off_z,
            trunk_height: trunk_h,
            canopy_shape: CANOPY_GIANT,
            log_id: OAK_LOG,
            leaf_id: OAK_LEAVES,
            present: true,
            thick_trunk: false,
            lean_dx: 0,
            lean_dz: 0,
            branch_count: MAX_BRANCHES,
            branch_hash,
            leaf_hash,
            sparse: 0,
            extra_skirt: if elder { 1 } else { 0 },
        };
    }

    let sapling = ((leaf_hash >> 16) & 0x7) == 0;
    if sapling {
        let strunk = 2 + (trunk_bits % 2) as i32;
        let sbirch = birch_bits == 0;
        if lean_gate <= 1 {
            match lean_dir {
                1 => lean_dx = 1,
                2 => lean_dx = -1,
                3 => lean_dz = 1,
                _ => lean_dz = -1,
            }
        }
        return TreeDesc {
            root_wx: cell_origin_x + off_x,
            root_wz: cell_origin_z + off_z,
            trunk_height: strunk,
            canopy_shape: CANOPY_COMPACT,
            log_id: if sbirch { BIRCH_LOG } else { OAK_LOG },
            leaf_id: if sbirch { BIRCH_LEAVES } else { OAK_LEAVES },
            present: true,
            thick_trunk: false,
            lean_dx,
            lean_dz,
            branch_count: 0,
            branch_hash,
            leaf_hash,
            sparse: 1,
            extra_skirt: 0,
        };
    }

    if lean_gate <= 1 {
        match lean_dir {
            1 => lean_dx = 1,
            2 => lean_dx = -1,
            3 => lean_dz = 1,
            _ => lean_dz = -1,
        }
        if ((leaf_hash >> 24) & 0x3) == 0 {
            if lean_dx != 0 {
                lean_dz = if ((leaf_hash >> 26) & 1) != 0 { 1 } else { -1 };
            } else {
                lean_dx = if ((leaf_hash >> 26) & 1) != 0 { 1 } else { -1 };
            }
        }
    }

    match dom {
        Biome::Forest => {
            let mut th = 6 + (trunk_bits % 5) as i32;
            let mut cs = if shape_bits == 0 {
                CANOPY_ROUND
            } else if shape_bits == 1 {
                CANOPY_BROAD
            } else if shape_bits == 2 {
                CANOPY_WEEPING
            } else if shape_bits == 3 {
                CANOPY_TALL
            } else if shape_bits == 4 {
                CANOPY_FORKED
            } else if shape_bits == 5 {
                CANOPY_ROUND
            } else if shape_bits == 6 {
                CANOPY_PINE
            } else {
                CANOPY_BROAD
            };
            let ib = birch_bits <= 1;
            if ib {
                th = 7 + (trunk_bits % 4) as i32;
                cs = CANOPY_TALL;
            }
            if !ib && thick_bit == 1 && th >= 7 {
                thick_trunk = false;
            }
            trunk_h = th;
            canopy_shape = cs;
            is_birch = ib;
        }
        Biome::Mountains => {
            let th = 7 + (trunk_bits % 5) as i32;
            let cs = if shape_bits <= 3 {
                CANOPY_PINE
            } else if shape_bits <= 5 {
                CANOPY_TALL
            } else {
                CANOPY_ROUND
            };
            let ib = birch_bits == 0;
            if !ib && thick_bit == 1 && th >= 7 {
                thick_trunk = false;
            }
            trunk_h = th;
            canopy_shape = cs;
            is_birch = ib;
        }
        Biome::Snowy => {
            let th = 9 + (trunk_bits % 7) as i32;
            if thick_bit == 1 && th >= 8 {
                thick_trunk = false;
            }
            trunk_h = th;
            canopy_shape = CANOPY_PINE;
            is_birch = false;
        }
        Biome::Swamp => {
            let th = 4 + (trunk_bits % 3) as i32;
            let cs = if shape_bits <= 2 {
                CANOPY_COMPACT
            } else if shape_bits <= 5 {
                CANOPY_BROAD
            } else {
                CANOPY_WEEPING
            };
            let ib = birch_bits <= 1;
            if !ib && thick_bit == 1 && th >= 5 && (cs == CANOPY_BROAD || cs == CANOPY_COMPACT || cs == CANOPY_WEEPING) {
                thick_trunk = false;
            }
            trunk_h = th;
            canopy_shape = cs;
            is_birch = ib;
        }
        Biome::Plains => {
            let th = 4 + (trunk_bits % 3) as i32;
            let cs = if shape_bits <= 2 {
                CANOPY_ROUND
            } else if shape_bits <= 5 {
                CANOPY_COMPACT
            } else {
                CANOPY_FORKED
            };
            trunk_h = th;
            canopy_shape = cs;
            is_birch = birch_bits == 0;
        }
        _ => {
            trunk_h = TRUNK_MIN + (trunk_bits % ((TRUNK_MAX - TRUNK_MIN + 1) as u64)) as i32;
            canopy_shape = CANOPY_ROUND;
            is_birch = birch_bits == 0;
        }
    }

    let mut branch_count = 0i32;
    let slender_birch = is_birch && canopy_shape == CANOPY_TALL;
    if canopy_shape != CANOPY_PINE && !slender_birch && trunk_h >= 6 {
        let bgate = branch_hash & 0x3;
        let leafy = canopy_shape == CANOPY_BROAD
            || canopy_shape == CANOPY_ROUND
            || canopy_shape == CANOPY_WEEPING
            || canopy_shape == CANOPY_GIANT;
        if leafy {
            branch_count = if bgate == 0 { 2 } else { 3 };
            if trunk_h < 8 && branch_count > 2 {
                branch_count = 2;
            }
        } else if bgate >= 2 {
            branch_count = if bgate == 3 { 2 } else { 1 };
        }
        if branch_count > MAX_BRANCHES {
            branch_count = MAX_BRANCHES;
        }
    }

    if canopy_shape == CANOPY_PINE {
        sparse = 0;
    }

    TreeDesc {
        root_wx: cell_origin_x + off_x,
        root_wz: cell_origin_z + off_z,
        trunk_height: trunk_h,
        canopy_shape,
        log_id: if canopy_shape == CANOPY_PINE {
            PINE_LOG
        } else if is_birch {
            BIRCH_LOG
        } else {
            OAK_LOG
        },
        leaf_id: if canopy_shape == CANOPY_PINE {
            PINE_LEAVES
        } else if is_birch {
            BIRCH_LEAVES
        } else {
            OAK_LEAVES
        },
        present: true,
        thick_trunk,
        lean_dx,
        lean_dz,
        branch_count,
        branch_hash,
        leaf_hash,
        sparse,
        extra_skirt,
    }
}

// ---------------------------------------------------------------------------
// Canopy voxel queries
// ---------------------------------------------------------------------------
#[inline]
fn in_ellipsoid(dx: i32, dy: i32, dz: i32, hr: f32, vr: f32) -> bool {
    let rx = dx as f32 / hr;
    let ry = dy as f32 / vr;
    let rz = dz as f32 / hr;
    rx * rx + ry * ry + rz * rz <= 1.0
}

fn in_canopy_round(dx: i32, dy: i32, dz: i32) -> bool {
    if dy < -2 || dy > 2 {
        return false;
    }
    in_ellipsoid(dx, dy, dz, 3.0, 2.6)
}

fn in_canopy_tall(dx: i32, dy: i32, dz: i32) -> bool {
    if dy < -1 || dy > 2 {
        return false;
    }
    if dy == 2 {
        return dx == 0 && dz == 0;
    }
    if dy == 1 {
        return dx == 0 && dz == 0;
    }
    if dy == 0 {
        if dx < -1 || dx > 1 || dz < -1 || dz > 1 {
            return false;
        }
        return true;
    }
    if dx < -2 || dx > 2 || dz < -2 || dz > 2 {
        return false;
    }
    let outer_x = dx == -2 || dx == 2;
    let outer_z = dz == -2 || dz == 2;
    if outer_x && outer_z {
        return false;
    }
    true
}

fn in_canopy_broad(dx: i32, dy: i32, dz: i32) -> bool {
    if dy < -2 || dy > 2 {
        return false;
    }
    in_ellipsoid(dx, dy, dz, 3.4, 2.1)
}

fn in_canopy_compact(dx: i32, dy: i32, dz: i32) -> bool {
    if dy < -2 || dy > 1 {
        return false;
    }
    in_ellipsoid(dx, dy, dz, 2.5, 2.0)
}

fn in_canopy_pine(dx: i32, dy: i32, dz: i32) -> bool {
    if dy < -2 || dy > 3 {
        return false;
    }
    if dy == 3 {
        return dx == 0 && dz == 0;
    }
    if dy == 2 {
        return dx == 0 && dz == 0;
    }
    if dy == 1 {
        return dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1;
    }
    if dy == 0 {
        return dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1;
    }
    if dy == -1 {
        if dx < -2 || dx > 2 || dz < -2 || dz > 2 {
            return false;
        }
        let ox = dx == -2 || dx == 2;
        let oz = dz == -2 || dz == 2;
        if ox && oz {
            return false;
        }
        return true;
    }
    // dy == -2
    if dx < -3 || dx > 3 || dz < -3 || dz > 3 {
        return false;
    }
    let ox = dx <= -3 || dx >= 3;
    let oz = dz <= -3 || dz >= 3;
    if ox && oz {
        return false;
    }
    if dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1 {
        return false;
    }
    true
}

fn in_canopy_giant(dx: i32, dy: i32, dz: i32) -> bool {
    if dy < -2 || dy > 3 {
        return false;
    }
    in_ellipsoid(dx, dy, dz, 4.0, 3.0)
}

fn in_canopy_weeping(dx: i32, dy: i32, dz: i32) -> bool {
    if dy < -3 || dy > 1 {
        return false;
    }
    if dy == 1 {
        return dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1;
    }
    if dy == 0 {
        if dx < -2 || dx > 2 || dz < -2 || dz > 2 {
            return false;
        }
        return !((dx == -2 || dx == 2) && (dz == -2 || dz == 2));
    }
    if dy == -1 {
        if dx < -3 || dx > 3 || dz < -3 || dz > 3 {
            return false;
        }
        let ox = dx <= -3 || dx >= 3;
        let oz = dz <= -3 || dz >= 3;
        if ox && oz {
            return false;
        }
        return true;
    }
    if dy == -2 {
        if dx < -2 || dx > 2 || dz < -2 || dz > 2 {
            return false;
        }
        let inner = dx >= -1 && dx <= 1 && dz >= -1 && dz <= 1;
        if inner {
            return false;
        }
        return true;
    }
    // dy == -3
    if !(dx == 0 || dz == 0) {
        return false;
    }
    let r = if dx == 0 {
        if dz < 0 {
            -dz
        } else {
            dz
        }
    } else if dx < 0 {
        -dx
    } else {
        dx
    };
    r == 2
}

fn in_canopy_forked(dx: i32, dy: i32, dz: i32) -> bool {
    if dy < -1 || dy > 2 {
        return false;
    }
    if dy == -1 || dy == 0 {
        if dx < -2 || dx > 2 || dz < -2 || dz > 2 {
            return false;
        }
        let ox = dx == -2 || dx == 2;
        let oz = dz == -2 || dz == 2;
        if ox && oz {
            return false;
        }
        return true;
    }
    let mut left_fork = dx >= -2 && dx <= 0 && dz >= -1 && dz <= 1;
    let mut right_fork = dx >= 0 && dx <= 2 && dz >= -1 && dz <= 1;
    if dy == 2 {
        left_fork = dx >= -2 && dx <= 0 && dz == 0;
        right_fork = dx >= 0 && dx <= 2 && dz == 0;
    }
    left_fork || right_fork
}

fn keep_leaf_voxel(leaf_hash: u64, sparse: i32, wlx: i32, wly: i32, wlz: i32, dx: i32, dz: i32) -> bool {
    let mut rxz = if dx < 0 { -dx } else { dx };
    let az = if dz < 0 { -dz } else { dz };
    if az > rxz {
        rxz = az;
    }
    if rxz <= 1 {
        return true;
    }
    let vh = hash3(wlx, wly, wlz, leaf_hash);
    let r = vh & 0xFF;
    let thr: u64 = if sparse != 0 { 98 } else { 46 };
    r >= thr
}

fn in_canopy(dx: i32, dy: i32, dz: i32, shape: i32) -> bool {
    match shape {
        x if x == CANOPY_TALL => in_canopy_tall(dx, dy, dz),
        x if x == CANOPY_BROAD => in_canopy_broad(dx, dy, dz),
        x if x == CANOPY_COMPACT => in_canopy_compact(dx, dy, dz),
        x if x == CANOPY_PINE => in_canopy_pine(dx, dy, dz),
        x if x == CANOPY_GIANT => in_canopy_giant(dx, dy, dz),
        x if x == CANOPY_WEEPING => in_canopy_weeping(dx, dy, dz),
        x if x == CANOPY_FORKED => in_canopy_forked(dx, dy, dz),
        _ => in_canopy_round(dx, dy, dz),
    }
}

// Maximum dy relative to trunk_top that the shape actually fills. This must
// cover the highest dy any in_canopy_* returns, or that top leaf layer is
// never iterated in the emission loop and the crown is silently capped short,
// leaving a bald trunk tip poking out (worst on GIANT and ROUND/BROAD, whose
// domes reach dy=3 and dy=2 but were clamped to dy=1). It also feeds
// worldgen_trunk_fit_to_ceiling, so an under-count let the dome clip the world
// ceiling on high ground.
fn canopy_dy_max(shape: i32) -> i32 {
    if shape == CANOPY_PINE {
        return 3;
    }
    if shape == CANOPY_GIANT {
        return 3;
    }
    if shape == CANOPY_TALL {
        return 2;
    }
    if shape == CANOPY_BROAD {
        return 2;
    }
    if shape == CANOPY_FORKED {
        return 2;
    }
    if shape == CANOPY_ROUND {
        return 2;
    }
    // COMPACT, WEEPING: top at dy=1.
    1
}

fn canopy_dy_min(shape: i32) -> i32 {
    if shape == CANOPY_WEEPING {
        return -3;
    }
    if shape == CANOPY_PINE {
        return -2;
    }
    -1
}

/// Pure helper exposed for the test (worldgen_trunk_fit_to_ceiling).
pub fn worldgen_trunk_fit_to_ceiling(surface_h: i32, canopy_dy_max: i32, desired_trunk: i32) -> i32 {
    let world_top_y = 4 * K_CHUNK_DIM - 1; // y 63
    let max_trunk = world_top_y - surface_h - canopy_dy_max;
    if max_trunk < 3 {
        return 0;
    }
    if desired_trunk > max_trunk {
        max_trunk
    } else {
        desired_trunk
    }
}

include!("worldgen_part3.rs");
