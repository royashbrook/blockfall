//! #170 the core "blockfall" mechanic: breaking a block bursts it into physical
//! debris fragments that pop outward, arc under gravity, bounce with decreasing
//! energy, roll a beat, settle, and then magnet to the player to be collected.
//!
//! Design notes:
//! * Deterministic: spawn velocities, sizes and tumble seeds are a pure function
//!   of (world seed, block pos) via a small local LCG (same constants as
//!   World::rand01). The tick integrates with the caller's fixed dt. Debris is
//!   transient render/sim state; it is never persisted and never hashed.
//! * Cheap: a plain Vec pool with swap_remove, no per-tick allocation. A few
//!   hundred fragments are ~a dozen float ops each per tick.
//! * Rendered as bf_entity_draw kind 22 (see render_frame.rs); the yaw field
//!   carries the spin phase and color carries the block colour, exactly like
//!   the falling-block kind 6 convention. No ABI change.

use super::*;

// Hard cap on live debris. Spawning beyond it collapses the oldest settled
// fragment straight to inventory-or-despawn so the pool never grows past this.
const DEBRIS_CAP: usize = 256;
// Physics.
const DEBRIS_GRAVITY: f32 = 26.0; // matches FallingBlock gravity
const DEBRIS_RESTITUTION: f32 = 0.35; // vertical bounce energy kept
const DEBRIS_FRICTION: f32 = 0.8; // tangential velocity kept per bounce
const DEBRIS_RADIUS: f32 = 0.12; // collision half-extent of a fragment
const DEBRIS_BOUNCE_MIN: f32 = 1.2; // below this impact speed, stop bouncing
const DEBRIS_SETTLE_SPEED: f32 = 0.35; // grounded + slower than this = settled
                                       // Collection.
const DEBRIS_ARM_DELAY: f32 = 0.5; // burst reads before the magnet kicks in
const DEBRIS_MAGNET_R: f32 = 2.5; // blocks from player centre
const DEBRIS_COLLECT_R: f32 = 0.9; // contact: item enters the inventory
const DEBRIS_MAGNET_ACCEL: f32 = 34.0; // accelerating pull toward the player
const DEBRIS_AUTO_COLLECT_AGE: f32 = 60.0; // settled + old = quietly collected

#[derive(Clone)]
pub(super) struct Debris {
    pub(super) pos: V3,
    pub(super) vel: V3,
    /// Visual tumble phase, packed into the entity yaw field.
    pub(super) spin: f32,
    /// Sign/base of the tumble; the live rate follows horizontal speed.
    pub(super) spin_dir: f32,
    /// The item this fragment yields on collection (0 = purely visual).
    pub(super) item: ItemId,
    pub(super) color: V3,
    /// Fragment size (entity scale). Seeded slight variety around 0.25.
    pub(super) scale: f32,
    pub(super) age: f32,
    pub(super) settled: bool,
    pub(super) grounded: bool,
}

/// Tiny deterministic LCG seeded purely from (world seed, block pos). Same
/// multiplier/increment as World::rand01 so the "house style" of randomness
/// matches, but with no dependence on the world's shared rng stream.
struct DebrisRng(u32);
impl DebrisRng {
    fn new(seed: u64, p: IVec3) -> DebrisRng {
        let s = (seed as u32)
            ^ (seed >> 32) as u32
            ^ (p.x as u32).wrapping_mul(73856093)
            ^ (p.y as u32).wrapping_mul(19349663)
            ^ (p.z as u32).wrapping_mul(83492791);
        DebrisRng(s | 1)
    }
    fn next01(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223);
        (self.0 >> 8) as f32 / 16777216.0
    }
}

impl<'c> World<'c> {
    /// Block colour for a debris fragment. Mirrors the terrain shader's
    /// materialColor table (RendererShaders.swift) for the common blocks so a
    /// grass fragment looks like grass; falls back to neutral grey.
    fn debris_color(b: BlockId) -> V3 {
        match b {
            1 => V3::new(0.34, 0.72, 0.26),       // grass
            2 => V3::new(0.52, 0.35, 0.20),       // dirt
            3 => V3::new(0.50, 0.51, 0.56),       // stone
            4 => V3::new(0.74, 0.53, 0.28),       // oak planks
            5 => V3::new(0.26, 0.58, 0.22),       // oak leaves
            6 => V3::new(0.88, 0.76, 0.44),       // sand
            7 => V3::new(1.00, 0.92, 0.42),       // glow block
            8 => V3::new(0.56, 0.57, 0.62),       // stone brick
            10 => V3::new(0.42, 0.43, 0.46),      // cobblestone
            11 => V3::new(0.52, 0.50, 0.47),      // gravel
            12 | 54 => V3::new(0.90, 0.93, 0.98), // snow
            13 => V3::new(0.66, 0.84, 1.00),      // ice
            14 => V3::new(0.58, 0.66, 0.74),      // clay
            15 => V3::new(0.26, 0.23, 0.34),      // dim stone
            16 => V3::new(0.30, 0.21, 0.16),      // dim dirt
            17 => V3::new(0.32, 0.33, 0.37),      // coal ore
            18 => V3::new(0.78, 0.46, 0.26),      // copper ore
            19 => V3::new(0.62, 0.60, 0.55),      // iron ore
            20 => V3::new(0.55, 0.40, 0.82),      // crystal ore
            21 | 51 => V3::new(0.47, 0.31, 0.16), // oak log / shaped timber
            22 => V3::new(0.83, 0.80, 0.68),      // birch log
            23 => V3::new(0.84, 0.74, 0.52),      // birch planks
            24 => V3::new(0.78, 0.36, 0.26),      // clay brick
            25 => V3::new(0.74, 0.92, 1.00),      // glass
            26 => V3::new(0.24, 0.82, 0.74),      // coloured glass
            27 => V3::new(0.52, 0.78, 0.30),      // birch leaves
            28 => V3::new(0.95, 0.93, 0.88),      // wool
            29 => V3::new(0.40, 0.54, 0.34),      // mossy stone
            30 => V3::new(0.62, 0.42, 0.20),      // crafting table
            31 => V3::new(0.78, 0.58, 0.26),      // chest
            33 | 50 => V3::new(0.66, 0.46, 0.24), // door
            48 => V3::new(0.18, 0.42, 0.24),      // pine needles
            49 => V3::new(0.40, 0.25, 0.15),      // pine log
            56 => V3::new(0.47, 0.31, 0.16),      // chopping block: oak stump
            _ => V3::new(0.60, 0.60, 0.60),
        }
    }

    /// Burst a broken block into 4..6 physical fragments. `item` is what one
    /// collected fragment yields; only the FIRST fragment carries it (one block
    /// = one drop, same as the old direct-to-inventory path), the rest are
    /// visual chips. Velocities are a pure function of (world seed, block pos).
    pub(super) fn spawn_debris_burst(&mut self, t: IVec3, block: BlockId, item: ItemId) {
        let mut r = DebrisRng::new(self.seed, t);
        let n = 6 + (r.next01() * 4.0) as usize % 4; // #176: 6..9, richer burst
        let color = Self::debris_color(block);
        let ctr = V3::new(t.x as f32 + 0.5, t.y as f32 + 0.5, t.z as f32 + 0.5);
        for i in 0..n {
            // Room in the pool first: collapse the oldest settled fragment.
            while self.debris.len() >= DEBRIS_CAP {
                self.collapse_oldest_debris();
            }
            // Outward + up-biased pop: fragments fan around the block with
            // seeded jitter. Initial speed ~4-7 blocks/s reads punchy.
            let ang = (i as f32 / n as f32) * 6.2831853 + r.next01() * 1.2;
            let hspd = 1.6 + r.next01() * 1.8;
            let vy = 3.6 + r.next01() * 2.6;
            self.debris.push(Debris {
                pos: ctr,
                vel: V3::new(ang.cos() * hspd, vy, ang.sin() * hspd),
                spin: r.next01() * 6.2831853,
                spin_dir: if r.next01() < 0.5 { -1.0 } else { 1.0 },
                item: if i == 0 { item } else { 0 },
                color,
                // #176: wider spread (0.12..0.30) plus an occasional CHUNK (~0.42)
                // so bursts read as varied rubble, not uniform pebbles. The item
                // carrier (i == 0) stays mid-size so the collectible reads.
                scale: if i == 0 {
                    0.24
                } else if r.next01() < 0.18 {
                    0.38 + r.next01() * 0.08
                } else {
                    0.12 + r.next01() * 0.18
                },
                age: 0.0,
                settled: false,
                grounded: false,
            });
        }
    }

    /// Cap policy: fold the oldest settled fragment (or the oldest at all if
    /// nothing settled yet) into the inventory if it fits, then drop it.
    fn collapse_oldest_debris(&mut self) {
        if self.debris.is_empty() {
            return;
        }
        let mut best = 0usize;
        let mut best_key = (false, -1.0f32);
        for (i, d) in self.debris.iter().enumerate() {
            let key = (d.settled, d.age);
            if (key.0 as i32, key.1) > (best_key.0 as i32, best_key.1) {
                best_key = key;
                best = i;
            }
        }
        let item = self.debris[best].item;
        if item != 0 {
            if let Some(inv) = self.inv.as_mut() {
                inv.add(ItemStack {
                    item,
                    count: 1,
                    durability: 0xFFFF,
                });
            }
        }
        self.debris.swap_remove(best);
    }

    /// Collect one fragment into the inventory. Returns false only when the
    /// fragment carries an item and the inventory is full (fragment stays).
    fn collect_debris(&mut self, i: usize) -> bool {
        let item = self.debris[i].item;
        if item != 0 {
            let added = match self.inv.as_mut() {
                Some(inv) => inv.add(ItemStack {
                    item,
                    count: 1,
                    durability: 0xFFFF,
                }),
                None => true,
            };
            if !added {
                return false;
            }
            let at = self.debris[i].pos;
            let land = IVec3 {
                x: Self::ifloor(at.x),
                y: Self::ifloor(at.y),
                z: Self::ifloor(at.z),
            };
            self.fx(7, land, 0);
            let nm = self.item_name(item);
            self.notify_quest("collect_item", &nm);
        }
        self.debris.swap_remove(i);
        true
    }

    fn debris_solid(&self, x: f32, y: f32, z: f32) -> bool {
        self.collide_solid(Self::ifloor(x), Self::ifloor(y), Self::ifloor(z))
    }

    /// Per-frame debris tick: gravity, terrain bounce/roll, settle, magnet
    /// collect, timed auto-collect. Called from World::update alongside the
    /// creature/falling ticks. No allocation; swap_remove keeps the pool dense.
    pub(super) fn update_debris(&mut self, dt: f32) {
        if self.debris.is_empty() {
            return;
        }
        // Player body centre (pos is the eye; the body reaches ~1.6 below).
        let player = V3::new(self.pos.x, self.pos.y - 0.8, self.pos.z);
        // #177: a Magnet Charm anywhere in the inventory triples the pull radius.
        // One name lookup + one 36-slot scan per tick, not per fragment.
        let magnet_r = {
            let charm = self.item_id_by_name("magnet_charm");
            let has = charm != 0
                && self.inv.as_ref().map_or(false, |inv| {
                    (0..BF_INVENTORY_SLOTS).any(|i| {
                        let s = inv.get(i);
                        s.item == charm && s.count > 0
                    })
                });
            if has { DEBRIS_MAGNET_R * 3.0 } else { DEBRIS_MAGNET_R }
        };
        let mut i = 0;
        while i < self.debris.len() {
            let mut d = self.debris[i].clone();
            d.age += dt;

            // Magnet + contact collect, once the burst has had time to read.
            // #179: nearest-image so fragments across the seam still magnet.
            let to = V3::new(
                Self::wrap_signed_f(player.x - d.pos.x),
                player.y - d.pos.y,
                Self::wrap_signed_f(player.z - d.pos.z),
            );
            let dist = dot(to, to).sqrt();
            if d.age >= DEBRIS_ARM_DELAY && dist < magnet_r {
                if dist < DEBRIS_COLLECT_R {
                    self.debris[i] = d;
                    if self.collect_debris(i) {
                        continue; // swap_remove: re-run this index
                    }
                    i += 1; // inventory full: fragment stays, retry later
                    continue;
                }
                // Accelerating pull; wake a settled fragment so it zips over.
                d.settled = false;
                let dir = to * (1.0 / dist.max(1e-4));
                d.vel = d.vel + dir * (DEBRIS_MAGNET_ACCEL * dt);
            }

            // Timed auto-collect: an old settled fragment quietly enters the
            // inventory if there is room; otherwise it just keeps resting
            // (the hard cap handles true overflow).
            if d.settled && d.age > DEBRIS_AUTO_COLLECT_AGE {
                self.debris[i] = d;
                if self.collect_debris(i) {
                    continue;
                }
                i += 1;
                continue;
            }

            if !d.settled {
                d.vel.y -= DEBRIS_GRAVITY * dt;

                // Axis-separated point-vs-voxel sweep with a small radius.
                // Horizontal hits reflect with restitution; the vertical hit
                // bounces with restitution + tangential friction, and below
                // the bounce threshold the fragment rolls (keeps tangential
                // velocity, bleeding it off) until slow enough to settle.
                let sx = if d.vel.x >= 0.0 {
                    DEBRIS_RADIUS
                } else {
                    -DEBRIS_RADIUS
                };
                let nx = d.pos.x + d.vel.x * dt;
                if self.debris_solid(nx + sx, d.pos.y, d.pos.z) {
                    d.vel.x = -d.vel.x * DEBRIS_RESTITUTION;
                } else {
                    d.pos.x = nx;
                }
                let sz = if d.vel.z >= 0.0 {
                    DEBRIS_RADIUS
                } else {
                    -DEBRIS_RADIUS
                };
                let nz = d.pos.z + d.vel.z * dt;
                if self.debris_solid(d.pos.x, d.pos.y, nz + sz) {
                    d.vel.z = -d.vel.z * DEBRIS_RESTITUTION;
                } else {
                    d.pos.z = nz;
                }
                let ny = d.pos.y + d.vel.y * dt;
                let sy = if d.vel.y >= 0.0 {
                    DEBRIS_RADIUS
                } else {
                    -DEBRIS_RADIUS
                };
                if self.debris_solid(d.pos.x, ny + sy, d.pos.z) {
                    if d.vel.y < 0.0 {
                        d.grounded = true;
                        // Rest exactly on the voxel top so a settled fragment
                        // never clips into the ground.
                        d.pos.y = (ny - DEBRIS_RADIUS).floor() + 1.0 + DEBRIS_RADIUS;
                        if -d.vel.y > DEBRIS_BOUNCE_MIN {
                            d.vel.y = -d.vel.y * DEBRIS_RESTITUTION;
                            d.vel.x *= DEBRIS_FRICTION;
                            d.vel.z *= DEBRIS_FRICTION;
                        } else {
                            // Kill the tiny bounce; roll with ground friction.
                            d.vel.y = 0.0;
                            let f = (1.0 - 3.0 * dt).max(0.0);
                            d.vel.x *= f;
                            d.vel.z *= f;
                        }
                    } else {
                        d.vel.y = 0.0; // bonked a ceiling
                    }
                } else {
                    d.pos.y = ny;
                    d.grounded = false;
                }

                // Tumble follows horizontal speed, frozen when settled.
                let hspd = (d.vel.x * d.vel.x + d.vel.z * d.vel.z).sqrt();
                let rate = d.spin_dir * (2.0 + hspd * 3.0);
                d.spin += rate * dt;

                let spd = dot(d.vel, d.vel).sqrt();
                if d.grounded && spd < DEBRIS_SETTLE_SPEED && d.age > DEBRIS_ARM_DELAY {
                    d.settled = true;
                    d.vel = V3::default();
                }

                // Safety: a fragment that fell out of the world despawns.
                if d.pos.y < -80.0 {
                    self.debris.swap_remove(i);
                    continue;
                }
            }

            d.pos = Self::wrap_v3_xz(d.pos);
            self.debris[i] = d;
            i += 1;
        }
    }

    // ---- test/debug seams --------------------------------------------------
    pub fn debug_debris_count(&self) -> usize {
        self.debris.len()
    }
    pub fn debug_debris_settled_count(&self) -> usize {
        self.debris.iter().filter(|d| d.settled).count()
    }
    pub fn debug_debris_pos(&self, i: usize) -> (f32, f32, f32) {
        let d = &self.debris[i];
        (d.pos.x, d.pos.y, d.pos.z)
    }
    pub fn debug_debris_vel(&self, i: usize) -> (f32, f32, f32) {
        let d = &self.debris[i];
        (d.vel.x, d.vel.y, d.vel.z)
    }
    /// Break a block through the REAL break path (tests + shot staging).
    pub fn debug_break_block(&mut self, x: i32, y: i32, z: i32) {
        self.break_block(IVec3 { x, y, z });
    }
    /// Stage a raw debris fragment (harness stills of fragments mid-air).
    pub fn debug_spawn_debris(&mut self, x: f32, y: f32, z: f32, block: BlockId) {
        let t = IVec3 {
            x: Self::ifloor(x),
            y: Self::ifloor(y),
            z: Self::ifloor(z),
        };
        let item = self.item_that_places(block);
        self.spawn_debris_burst(t, block, item);
        // Re-anchor the fresh burst (age 0) on the exact requested point.
        for d in self.debris.iter_mut() {
            if d.age == 0.0 {
                d.pos = V3::new(x, y, z);
            }
        }
    }
}
