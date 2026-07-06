//! Creature locomotion + AI (epic #131).
//!
//! This module is intentionally self contained. It does NOT depend on the World
//! struct or the private V3 type in world.rs. Instead it works on plain f32/i32
//! data and asks the world about terrain through the small `WorldQuery` trait. The
//! point is to keep the world.rs diff tiny (a mod line plus a few delegating calls
//! inside update_creatures) while another agent edits world.rs in parallel.
//!
//! What lives here:
//!   1. Bounded A* pathfinding over the walkable (x,z) grid, with a hard expansion
//!      cap and a small fixed search radius so dozens of creatures stay cheap.
//!   2. Smooth locomotion: acceleration/deceleration toward a target speed and
//!      smooth heading rotation (no instant velocity snaps or heading flips), with
//!      the climb step left to the caller exactly as before.
//!   3. A small per type behaviour state machine (Idle, Wander, Flee, Seek).
//!
//! Determinism: every "random" choice is drawn from a caller supplied LCG seed
//! (the world's existing rng pattern), never from wall clock. Given the same
//! creature state + seed the result is identical, so the determinism tests stay
//! stable.

/// Terrain queries the AI needs. Implemented by the world at the call site so this
/// module never touches the world's internals.
pub trait WorldQuery {
    /// True if the block at (x,y,z) is a solid the creature cannot pass through.
    fn is_solid(&self, x: i32, y: i32, z: i32) -> bool;
    /// Top standable Y (the Y a creature's feet rest at) scanning DOWN from y_top,
    /// or None if there is no floor within reach. Mirrors world.floor_below but
    /// returns Option for clarity.
    fn floor(&self, x: i32, y_top: i32, z: i32) -> Option<i32>;
}

/// Behaviour states. A creature is in exactly one at a time. Kept deliberately
/// small: Idle (stand and breathe), Wander (amble to a nearby point), Flee (move
/// directly away from a threat), Seek (path toward a goal, e.g. the player).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AiState {
    Idle,
    Wander,
    Flee,
    Seek,
}

impl Default for AiState {
    fn default() -> AiState {
        AiState::Idle
    }
}

/// Disposition feeding the state machine, derived from the existing creature flags
/// (hostile / friendly / skittish). Passive = grazes and flees; Hunter = seeks the
/// player; Villager = idles and roams; Aquatic is handled by the caller already.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Temperament {
    Passive,
    Hunter,
    Villager,
    /// Befriended pet: follows the player at a comfortable distance, pathing around
    /// obstacles, but stops short instead of crowding onto the player.
    Pet,
    /// Walk the seeded heading at full speed, ignoring the player. Used for the
    /// deterministic locomotion/climb tests (a creature placed against a known step
    /// that must walk straight into it), and any spawn that wants scripted motion.
    Scripted,
}

/// Per creature AI + locomotion state. One of these rides alongside each Creature.
/// All fields advance deterministically from creature state + the seeded rng.
#[derive(Clone)]
pub struct CreatureAi {
    pub state: AiState,
    /// Current ground speed in blocks/sec (magnitude of horizontal velocity). The
    /// renderer reads this to match the walk cycle so feet do not slide.
    pub speed: f32,
    /// Current facing heading in radians (yaw). Rotated smoothly toward the desired
    /// heading; never snapped.
    pub heading: f32,
    /// Time left in the current state before the machine re evaluates (seconds).
    pub state_timer: f32,
    /// Ticks until the next allowed repath. Throttles A* so it is not run every
    /// frame for every creature.
    pub repath_cd: i32,
    /// Active path as (x,z) block waypoints, and the index of the next one to reach.
    pub path: Vec<(i32, i32)>,
    pub path_idx: usize,
    /// Goal the current path was built toward, so we can tell when the goal moved
    /// far enough to justify a fresh path.
    pub goal: (i32, i32),
    /// #213: ticks left committed to a just-chosen turn-away heading after being
    /// blocked, so a creature grinding a wall does not re-roll (and spin/vibrate)
    /// every single tick. Decremented in tick_repath.
    pub blocked_cd: i32,
}

impl Default for CreatureAi {
    fn default() -> CreatureAi {
        CreatureAi {
            state: AiState::Idle,
            speed: 0.0,
            heading: 0.0,
            state_timer: 0.0,
            repath_cd: 0,
            path: Vec::new(),
            path_idx: 0,
            goal: (i32::MIN, i32::MIN),
            blocked_cd: 0,
        }
    }
}

// ---- tuning ----------------------------------------------------------------

/// Horizontal acceleration toward target speed (blocks/sec^2). Big enough to feel
/// responsive, small enough that there is a visible ramp instead of a snap.
const ACCEL: f32 = 8.0;
/// Deceleration when the target speed is below the current speed (blocks/sec^2).
const DECEL: f32 = 12.0;
/// Max heading turn rate (radians/sec). Creatures rotate toward their movement
/// direction over time rather than flipping instantly.
const TURN_RATE: f32 = 6.0;
/// How close (blocks) a creature must get to a waypoint before advancing to the
/// next one.
const WAYPOINT_REACH: f32 = 0.6;
/// Ticks between repaths while seeking (at the usual ~20Hz fixed step this is a few
/// times a second, plenty responsive and very cheap).
const REPATH_TICKS: i32 = 8;
/// Goal must move at least this many blocks (squared) from the path's goal to force
/// an early repath.
const GOAL_MOVE2: i32 = 9;

// ---- pathfinding -----------------------------------------------------------

/// Hard cap on A* node expansions per call. Bounds worst case cost so dozens of
/// creatures repathing stay cheap; if the cap is hit we return the best partial
/// route toward the goal rather than spinning.
pub const MAX_EXPANSIONS: usize = 256;
/// Half width (blocks) of the square search window centered on the start. The
/// pathfinder only considers cells within this radius of the start, which both
/// bounds the grid and keeps creatures from planning across the whole world.
pub const SEARCH_RADIUS: i32 = 12;

#[derive(Clone, Copy)]
struct Node {
    x: i32,
    z: i32,
    g: i32,      // cost so far (in 10x units, diag = 14)
    f: i32,      // g + heuristic
    parent: i32, // index into the closed list, -1 for the start
}

#[inline]
fn heuristic(x: i32, z: i32, gx: i32, gz: i32) -> i32 {
    // Octile distance scaled by 10 (straight) / 14 (diagonal) to match step costs.
    let dx = (x - gx).abs();
    let dz = (z - gz).abs();
    let (lo, hi) = if dx < dz { (dx, dz) } else { (dz, dx) };
    14 * lo + 10 * (hi - lo)
}

/// Can a creature stand at (x,z) near reference height y_ref? Walkable means there
/// is a floor within a small vertical band (so it can climb a step or drop a little)
/// and head room above it. Diagonal moves additionally require the two orthogonal
/// neighbours not both be walls so creatures do not cut through corners.
fn standable<Q: WorldQuery>(q: &Q, x: i32, z: i32, y_ref: i32) -> Option<i32> {
    // Look for a floor from a little above the reference down to a little below, so
    // a one or two block step up and a small drop are both walkable.
    let f = q.floor(x, y_ref + 2, z)?;
    if (f - y_ref).abs() > 2 {
        return None;
    }
    // Head room: the two cells above the floor must be clear.
    if q.is_solid(x, f, z) || q.is_solid(x, f + 1, z) {
        return None;
    }
    Some(f)
}

/// Bounded A* over the (x,z) grid. Returns a list of (x,z) waypoints from just
/// after the start to the goal (start excluded), or an empty vec if no usable route
/// was found. The route is post simplified to drop collinear points so following it
/// produces long smooth straights instead of a stair step wobble.
pub fn find_path<Q: WorldQuery>(q: &Q, sx: i32, sz: i32, sy: i32, gx: i32, gz: i32) -> Vec<(i32, i32)> {
    if sx == gx && sz == gz {
        return Vec::new();
    }
    // Clamp the goal into the search window so a far goal still yields a route that
    // heads the right way (the caller repaths as the creature advances).
    let cgx = gx.clamp(sx - SEARCH_RADIUS, sx + SEARCH_RADIUS);
    let cgz = gz.clamp(sz - SEARCH_RADIUS, sz + SEARCH_RADIUS);

    let mut open: Vec<Node> = Vec::with_capacity(MAX_EXPANSIONS);
    let mut closed: Vec<Node> = Vec::with_capacity(MAX_EXPANSIONS);
    // Visited cells -> best g, so we do not re expand worse routes. The search window
    // is bounded so this stays tiny.
    let mut best: std::collections::HashMap<(i32, i32), i32> = std::collections::HashMap::new();

    open.push(Node { x: sx, z: sz, g: 0, f: heuristic(sx, sz, cgx, cgz), parent: -1 });
    best.insert((sx, sz), 0);

    let mut best_goal_node: i32 = -1;
    let mut best_goal_h: i32 = i32::MAX;
    let mut expansions = 0usize;

    while !open.is_empty() && expansions < MAX_EXPANSIONS {
        // Pop the lowest f. Linear scan: open stays small under the expansion cap.
        let mut bi = 0usize;
        for i in 1..open.len() {
            if open[i].f < open[bi].f {
                bi = i;
            }
        }
        let cur = open.swap_remove(bi);
        let cur_idx = closed.len() as i32;
        closed.push(cur);
        expansions += 1;

        // Track the closed node closest to the goal so a capped/partial search can
        // still return a sensible heading.
        let h = heuristic(cur.x, cur.z, cgx, cgz);
        if h < best_goal_h {
            best_goal_h = h;
            best_goal_node = cur_idx;
        }
        if cur.x == cgx && cur.z == cgz {
            return reconstruct(&closed, cur_idx);
        }

        // 8 neighbours. Step cost 10 orthogonal, 14 diagonal.
        const NB: [(i32, i32, i32); 8] = [
            (1, 0, 10),
            (-1, 0, 10),
            (0, 1, 10),
            (0, -1, 10),
            (1, 1, 14),
            (1, -1, 14),
            (-1, 1, 14),
            (-1, -1, 14),
        ];
        // The current node's floor is the vertical reference so steps chain.
        let cy = standable(q, cur.x, cur.z, sy).unwrap_or(sy);
        for (dx, dz, cost) in NB {
            let nx = cur.x + dx;
            let nz = cur.z + dz;
            if (nx - sx).abs() > SEARCH_RADIUS || (nz - sz).abs() > SEARCH_RADIUS {
                continue;
            }
            if standable(q, nx, nz, cy).is_none() {
                continue;
            }
            // No corner cutting on diagonals: both orthogonal neighbours must be
            // walkable, else the creature would clip a wall corner.
            if dx != 0 && dz != 0 {
                if standable(q, cur.x + dx, cur.z, cy).is_none() || standable(q, cur.x, cur.z + dz, cy).is_none() {
                    continue;
                }
            }
            let ng = cur.g + cost;
            let key = (nx, nz);
            if let Some(&pg) = best.get(&key) {
                if ng >= pg {
                    continue;
                }
            }
            best.insert(key, ng);
            open.push(Node { x: nx, z: nz, g: ng, f: ng + heuristic(nx, nz, cgx, cgz), parent: cur_idx });
        }
    }

    // No exact route within the cap: return a path toward the closest reached cell so
    // the creature still makes progress (and will repath from there).
    if best_goal_node > 0 {
        return reconstruct(&closed, best_goal_node);
    }
    Vec::new()
}

fn reconstruct(closed: &[Node], mut idx: i32) -> Vec<(i32, i32)> {
    let mut rev: Vec<(i32, i32)> = Vec::new();
    while idx >= 0 {
        let n = closed[idx as usize];
        rev.push((n.x, n.z));
        idx = n.parent;
    }
    rev.reverse();
    // Drop the start cell (index 0) so the path is the sequence of cells to move TO.
    if !rev.is_empty() {
        rev.remove(0);
    }
    simplify(&rev)
}

/// Drop interior waypoints that lie on the same straight line as their neighbours so
/// the follower walks long straights, not a per cell stair step.
fn simplify(pts: &[(i32, i32)]) -> Vec<(i32, i32)> {
    if pts.len() <= 2 {
        return pts.to_vec();
    }
    let mut out: Vec<(i32, i32)> = Vec::with_capacity(pts.len());
    out.push(pts[0]);
    for i in 1..pts.len() - 1 {
        let (ax, az) = out[out.len() - 1];
        let (bx, bz) = pts[i];
        let (cx, cz) = pts[i + 1];
        // Same direction if the two segment vectors are parallel (cross == 0).
        let cross = (bx - ax) * (cz - bz) - (bz - az) * (cx - bx);
        if cross != 0 {
            out.push(pts[i]);
        }
    }
    out.push(pts[pts.len() - 1]);
    out
}

// ---- locomotion ------------------------------------------------------------

/// Wrap an angle delta into (-pi, pi] so smooth turning takes the short way around
/// and never spins the long way.
#[inline]
pub fn wrap_angle(mut a: f32) -> f32 {
    use std::f32::consts::PI;
    while a > PI {
        a -= 2.0 * PI;
    }
    while a < -PI {
        a += 2.0 * PI;
    }
    a
}

/// Rotate `heading` toward `desired` by at most TURN_RATE*dt, the short way around.
/// Returns the new heading. No snapping: a 180 degree about face takes ~half a
/// second instead of flipping in one tick.
#[inline]
pub fn turn_toward(heading: f32, desired: f32, dt: f32) -> f32 {
    let diff = wrap_angle(desired - heading);
    let step = TURN_RATE * dt;
    if diff.abs() <= step {
        wrap_angle(desired)
    } else {
        wrap_angle(heading + step * diff.signum())
    }
}

/// Accelerate or decelerate `speed` toward `target` using ACCEL/DECEL. Returns the
/// new speed. Velocity never jumps; it ramps, so the renderer's speed matched gait
/// also ramps and feet do not pop.
#[inline]
pub fn approach_speed(speed: f32, target: f32, dt: f32) -> f32 {
    if target > speed {
        (speed + ACCEL * dt).min(target)
    } else {
        (speed - DECEL * dt).max(target).max(0.0)
    }
}

/// One locomotion step. Given the desired heading and desired speed (chosen by the
/// behaviour layer), smoothly turn and ramp toward them, then return the horizontal
/// displacement (dx, dz) to apply this tick plus the updated (heading, speed). The
/// caller still owns collision, climb, gravity and writing the result back, so the
/// existing climb step keeps working untouched.
pub fn step_locomotion(ai: &CreatureAi, desired_heading: f32, desired_speed: f32, dt: f32) -> (f32, f32, f32, f32) {
    let heading = turn_toward(ai.heading, desired_heading, dt);
    let speed = approach_speed(ai.speed, desired_speed, dt);
    // Move along the *current* (smoothed) heading, not the desired one, so a turning
    // creature curves through its arc instead of strafing sideways.
    let dx = heading.sin() * speed * dt;
    let dz = heading.cos() * speed * dt;
    (dx, dz, heading, speed)
}

// ---- behaviour state machine ----------------------------------------------

/// A simple deterministic LCG step matching the world's rng (1664525 / 1013904223),
/// returning 0..1. Threading the seed in keeps the AI deterministic without reaching
/// into the World.
#[inline]
pub fn rng01(seed: &mut u32) -> f32 {
    *seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
    (*seed >> 8) as f32 / 16777216.0
}

/// Result of a behaviour decision for one tick: where to face, how fast to move, and
/// whether to (re)compute a path toward `path_goal`.
pub struct Decision {
    pub desired_heading: f32,
    /// Target speed as a fraction (0..1) of the creature's base speed.
    pub speed_frac: f32,
    /// If Some, the behaviour wants to path toward this (x,z) goal this tick.
    pub path_goal: Option<(i32, i32)>,
}

/// Distance (blocks) at which a passive creature notices and flees the player.
pub const FLEE_RADIUS: f32 = 6.0;
/// Distance at which a hunter starts seeking the player.
pub const SEEK_RADIUS: f32 = 16.0;
/// Distance at which a hunter is "on top of" the player and stops pathing (the
/// existing melee code takes over).
pub const SEEK_STOP: f32 = 1.3;
/// A pet that is farther than this follows the player; closer than this it idles so
/// it keeps a comfortable spacing instead of crowding onto the player.
pub const PET_FOLLOW: f32 = 2.2;

/// Decide behaviour for one tick. Pure given its inputs + the rng seed, so tests are
/// stable. `cx,cz` is the creature position, `px,pz` the player, `to_player_d` the
/// horizontal distance to the player. `temper` selects the per type behaviour.
pub fn decide(
    ai: &mut CreatureAi,
    temper: Temperament,
    cx: f32,
    cz: f32,
    px: f32,
    pz: f32,
    to_player_d: f32,
    dt: f32,
    seed: &mut u32,
) -> Decision {
    // Scripted creatures just keep their seeded straight heading at full speed; they
    // never re-roll, flee, or path. Keeps the locomotion tests deterministic.
    if temper == Temperament::Scripted {
        ai.state = AiState::Wander;
        return Decision { desired_heading: ai.goal_heading(), speed_frac: 1.0, path_goal: None };
    }

    ai.state_timer -= dt;

    // ---- pick the state ----
    let new_state = match temper {
        Temperament::Passive => {
            if to_player_d < FLEE_RADIUS {
                AiState::Flee
            } else if ai.state == AiState::Flee {
                // Just escaped: settle into a wander rather than freezing.
                AiState::Wander
            } else if ai.state_timer <= 0.0 {
                // Alternate idle/graze and ambling wander.
                if rng01(seed) < 0.5 {
                    AiState::Idle
                } else {
                    AiState::Wander
                }
            } else {
                ai.state
            }
        }
        Temperament::Hunter => {
            if to_player_d < SEEK_RADIUS {
                AiState::Seek
            } else if ai.state_timer <= 0.0 {
                AiState::Wander
            } else {
                ai.state
            }
        }
        Temperament::Villager => {
            if ai.state_timer <= 0.0 {
                if rng01(seed) < 0.55 {
                    AiState::Idle
                } else {
                    AiState::Wander
                }
            } else {
                ai.state
            }
        }
        Temperament::Pet => {
            // Follow when far; idle (settle) when close enough.
            if to_player_d > PET_FOLLOW {
                AiState::Seek
            } else {
                AiState::Idle
            }
        }
        // Handled by the early return above; kept for match exhaustiveness.
        Temperament::Scripted => AiState::Wander,
    };

    // On a state change, (re)arm the timer and clear any stale wander heading.
    if new_state != ai.state {
        ai.state = new_state;
        ai.state_timer = match new_state {
            AiState::Idle => 1.0 + rng01(seed) * 2.0,
            AiState::Wander => 1.5 + rng01(seed) * 2.5,
            AiState::Flee => 0.6,
            AiState::Seek => 0.5,
        };
        if new_state == AiState::Wander {
            // Pick a fresh amble heading once per wander, not every tick.
            ai.heading_target_set(rng01(seed) * std::f32::consts::TAU);
        }
    }

    match ai.state {
        AiState::Idle => Decision { desired_heading: ai.heading, speed_frac: 0.0, path_goal: None },
        AiState::Wander => {
            // Re-roll a heading occasionally so the amble meanders.
            if ai.state_timer <= 0.0 {
                ai.state_timer = 1.5 + rng01(seed) * 2.0;
                ai.heading_target_set(rng01(seed) * std::f32::consts::TAU);
            }
            Decision { desired_heading: ai.goal_heading(), speed_frac: 0.45, path_goal: None }
        }
        AiState::Flee => {
            // Head directly away from the player, fast.
            let away = (cx - px).atan2(cz - pz);
            Decision { desired_heading: away, speed_frac: 1.0, path_goal: None }
        }
        AiState::Seek => {
            if to_player_d < SEEK_STOP {
                // Close enough: face the player, let melee take over, stop pathing.
                let toward = (px - cx).atan2(pz - cz);
                Decision { desired_heading: toward, speed_frac: 0.0, path_goal: None }
            } else {
                Decision {
                    desired_heading: ai.heading,
                    speed_frac: 0.9,
                    path_goal: Some((px.floor() as i32, pz.floor() as i32)),
                }
            }
        }
    }
}

impl CreatureAi {
    // The wander heading is stashed in `goal` (reused as a packed angle) to avoid a
    // new field; encode/decode the chosen amble heading there.
    fn heading_target_set(&mut self, angle: f32) {
        // Store the angle in milliradians in goal.0 so it survives between ticks.
        self.goal = ((angle * 1000.0) as i32, i32::MIN);
    }
    fn goal_heading(&self) -> f32 {
        self.goal.0 as f32 / 1000.0
    }

    /// Should we (re)compute a path toward `goal` this tick? True if we have no path,
    /// OR the cooldown has elapsed, OR the goal moved well away from the path's goal.
    pub fn needs_repath(&self, goal: (i32, i32)) -> bool {
        if self.path.is_empty() {
            return true;
        }
        if self.repath_cd <= 0 {
            return true;
        }
        let lg = self.last_path_goal();
        let dx = goal.0 - lg.0;
        let dz = goal.1 - lg.1;
        dx * dx + dz * dz >= GOAL_MOVE2
    }

    fn last_path_goal(&self) -> (i32, i32) {
        *self.path.last().unwrap_or(&(i32::MIN, i32::MIN))
    }

    /// Install a freshly computed path and arm the repath cooldown.
    pub fn set_path(&mut self, path: Vec<(i32, i32)>) {
        self.path = path;
        self.path_idx = 0;
        self.repath_cd = REPATH_TICKS;
    }

    /// Seed a fixed straight-line amble in `angle` radians that persists for the
    /// test window: heading is set, the wander target matches, and the state is
    /// locked to Wander with a long timer so the creature walks that way without
    /// turning away or re-rolling. Used by the locomotion tests (and spawns that
    /// want a known initial heading).
    pub fn seed_straight(&mut self, angle: f32) {
        self.heading = angle;
        self.state = AiState::Wander;
        self.state_timer = 1.0e6;
        self.heading_target_set(angle);
    }

    /// Reaction to bumping an impassable wall: drop the stale path (so a seeker
    /// repaths next chance) and swing the wander amble heading by `turn` radians so
    /// a non-pathing creature turns away from the wall smoothly next ticks.
    pub fn on_blocked(&mut self, turn: f32) {
        self.path.clear();
        self.path_idx = 0;
        self.repath_cd = 0;
        // #213: while still committed to a recent turn-away, do NOT re-roll the
        // heading every tick (that spun the body and made a wall-grinding creature
        // vibrate). Just keep easing toward the already-chosen heading.
        if self.blocked_cd > 0 {
            self.speed *= 0.5; // bleed momentum so it stops shoving into the wall
            return;
        }
        // Rotate the stored wander heading; turn_toward then eases the body around.
        let h = self.goal_heading() + turn;
        self.heading_target_set(h);
        self.blocked_cd = 16; // ~0.8s: commit to the turn before re-rolling
        self.speed *= 0.2; // drop the momentum that drove it into the wall
    }

    /// Advance the repath cooldown one tick (call once per creature per update).
    pub fn tick_repath(&mut self) {
        if self.repath_cd > 0 {
            self.repath_cd -= 1;
        }
        if self.blocked_cd > 0 {
            self.blocked_cd -= 1;
        }
    }

    /// Heading toward the next waypoint, advancing past ones we have reached. Returns
    /// None when the path is exhausted. `cx,cz` is the creature position.
    pub fn follow_heading(&mut self, cx: f32, cz: f32) -> Option<f32> {
        while self.path_idx < self.path.len() {
            let (wx, wz) = self.path[self.path_idx];
            // Aim at the block center.
            let tx = wx as f32 + 0.5;
            let tz = wz as f32 + 0.5;
            let dx = tx - cx;
            let dz = tz - cz;
            if dx * dx + dz * dz <= WAYPOINT_REACH * WAYPOINT_REACH {
                self.path_idx += 1;
                continue;
            }
            return Some(dx.atan2(dz));
        }
        None
    }
}

// ===========================================================================
// Tests
// ===========================================================================
#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny flat-world stub with optional wall columns, for pathfinding/AI tests.
    struct FlatWorld {
        /// Solid wall columns at (x,z): the column above the floor is solid.
        walls: std::collections::HashSet<(i32, i32)>,
        floor_y: i32,
    }
    impl FlatWorld {
        fn new(floor_y: i32) -> FlatWorld {
            FlatWorld { walls: std::collections::HashSet::new(), floor_y }
        }
        fn wall(&mut self, x: i32, z: i32) {
            self.walls.insert((x, z));
        }
    }
    impl WorldQuery for FlatWorld {
        fn is_solid(&self, x: i32, y: i32, z: i32) -> bool {
            if y <= self.floor_y {
                return true; // ground + below
            }
            // A wall column rises a few blocks above the floor.
            self.walls.contains(&(x, z)) && y <= self.floor_y + 3
        }
        fn floor(&self, x: i32, y_top: i32, z: i32) -> Option<i32> {
            let mut y = y_top;
            while y > y_top - 80 {
                if self.is_solid(x, y, z) {
                    return Some(y + 1);
                }
                y -= 1;
            }
            None
        }
    }

    #[test]
    fn path_straight_line_on_open_ground() {
        let w = FlatWorld::new(0);
        let p = find_path(&w, 0, 0, 1, 5, 0);
        assert!(!p.is_empty(), "should find a route on open ground");
        // Last waypoint is the goal.
        assert_eq!(*p.last().unwrap(), (5, 0));
    }

    #[test]
    fn path_routes_around_a_wall() {
        // A wall blocking the straight x-line from (0,0) to (4,0): a vertical bar at
        // x=2 across z=-1..1. The route must detour around it (visit some z != 0).
        let mut w = FlatWorld::new(0);
        w.wall(2, -1);
        w.wall(2, 0);
        w.wall(2, 1);
        let p = find_path(&w, 0, 0, 1, 4, 0);
        assert!(!p.is_empty(), "should find a route around the wall");
        assert_eq!(*p.last().unwrap(), (4, 0), "route must reach the goal");
        // It must NOT pass through the wall cells.
        for &(x, z) in &p {
            assert!(!w.walls.contains(&(x, z)), "route stepped through a wall at {:?}", (x, z));
        }
        // And it must leave the z=0 corridor at least once to get around.
        assert!(p.iter().any(|&(_, z)| z != 0), "route should detour off the blocked line");
    }

    #[test]
    fn path_bounded_when_goal_unreachable() {
        // Box the start in completely: no route exists. Must return without blowing
        // the expansion cap and without panicking.
        let mut w = FlatWorld::new(0);
        for d in -1..=1 {
            w.wall(1, d);
            w.wall(-1, d);
            w.wall(d, 1);
            w.wall(d, -1);
        }
        let p = find_path(&w, 0, 0, 1, 8, 0);
        // Penned in: every neighbour is a wall, so no progress is possible.
        assert!(p.is_empty(), "no route should be found when fully walled in");
    }

    #[test]
    fn turn_is_smooth_not_instant() {
        // Facing +Z (0), desired about-face to -Z (pi). One short tick must NOT snap.
        let h0 = 0.0f32;
        let h1 = turn_toward(h0, std::f32::consts::PI, 0.05);
        assert!(h1.abs() > 0.0, "should have begun turning");
        assert!((h1 - std::f32::consts::PI).abs() > 0.5, "must not snap to the target in one tick (got {h1})");
        // After enough ticks it converges.
        let mut h = h0;
        for _ in 0..40 {
            h = turn_toward(h, std::f32::consts::PI, 0.05);
        }
        assert!((wrap_angle(h - std::f32::consts::PI)).abs() < 0.05, "should converge to target");
    }

    #[test]
    fn speed_ramps_no_teleport() {
        // From a standstill, speed must ramp up over ticks, not jump to target.
        let s1 = approach_speed(0.0, 4.0, 0.05);
        assert!(s1 > 0.0 && s1 < 4.0, "speed should ramp, not jump (got {s1})");
        let mut s = 0.0;
        for _ in 0..30 {
            s = approach_speed(s, 4.0, 0.05);
        }
        assert!((s - 4.0).abs() < 0.01, "should reach target speed");
        // Decel back down is also gradual.
        let d1 = approach_speed(4.0, 0.0, 0.05);
        assert!(d1 > 0.0 && d1 < 4.0, "decel should be gradual (got {d1})");
    }

    #[test]
    fn step_locomotion_curves_through_heading() {
        let ai = CreatureAi { heading: 0.0, speed: 2.0, ..Default::default() };
        // Desired hard turn; one step should move mostly forward along current
        // heading, not teleport sideways toward the desired heading.
        let (dx, dz, nh, _ns) = step_locomotion(&ai, std::f32::consts::FRAC_PI_2, 2.0, 0.05);
        assert!(dz.abs() > dx.abs(), "should still move mostly along current +Z heading");
        assert!(nh > 0.0, "heading should have rotated toward the desired");
    }

    #[test]
    fn passive_flees_when_player_near() {
        let mut ai = CreatureAi::default();
        let mut seed = 0x1234567u32;
        // Player right next to a passive creature: it must enter Flee and head away.
        let cx = 5.0f32;
        let cz = 5.0f32;
        let px = 6.0f32; // 1 block east
        let pz = 5.0f32;
        let d = ((px - cx).powi(2) + (pz - cz).powi(2)).sqrt();
        let dec = decide(&mut ai, Temperament::Passive, cx, cz, px, pz, d, 0.05, &mut seed);
        assert_eq!(ai.state, AiState::Flee);
        assert!(dec.speed_frac > 0.5, "should flee at speed");
        // Desired heading points away from the player (toward -X here, sin<0).
        assert!(dec.desired_heading.sin() < 0.0, "should head away from the player");
        assert!(dec.path_goal.is_none(), "flee does not path");
    }

    #[test]
    fn passive_grazes_when_player_far() {
        let mut ai = CreatureAi::default();
        let mut seed = 0xBEEF1u32;
        // Player far away: never Flee; settles into Idle or Wander.
        let dec = decide(&mut ai, Temperament::Passive, 0.0, 0.0, 100.0, 100.0, 141.0, 0.05, &mut seed);
        assert_ne!(ai.state, AiState::Flee);
        assert!(dec.speed_frac < 1.0);
    }

    #[test]
    fn hunter_seeks_and_paths_to_player() {
        let mut ai = CreatureAi::default();
        let mut seed = 7u32;
        // Player within seek radius but not melee range.
        let dec = decide(&mut ai, Temperament::Hunter, 0.0, 0.0, 8.0, 0.0, 8.0, 0.05, &mut seed);
        assert_eq!(ai.state, AiState::Seek);
        assert!(dec.path_goal.is_some(), "hunter should request a path to the player");
        assert_eq!(dec.path_goal.unwrap(), (8, 0));
    }

    #[test]
    fn decide_is_deterministic_for_same_seed() {
        // Two runs with identical state + seed must produce identical results.
        let run = || {
            let mut ai = CreatureAi::default();
            let mut seed = 99u32;
            let mut states = Vec::new();
            for _ in 0..50 {
                decide(&mut ai, Temperament::Villager, 0.0, 0.0, 100.0, 100.0, 141.0, 0.1, &mut seed);
                states.push(ai.state);
            }
            (states, seed)
        };
        assert_eq!(run().0, run().0, "state sequence must be deterministic");
        assert_eq!(run().1, run().1, "rng seed evolution must be deterministic");
    }

    #[test]
    fn follow_heading_advances_through_waypoints() {
        let mut ai = CreatureAi::default();
        ai.set_path(vec![(1, 0), (2, 0)]);
        // Standing right on the first waypoint center: it should advance to the next.
        let h = ai.follow_heading(1.5, 0.5);
        assert!(h.is_some());
        assert_eq!(ai.path_idx, 1, "should have consumed the reached first waypoint");
    }
}
