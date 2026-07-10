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
