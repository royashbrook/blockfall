use super::*;

impl<'c> World<'c> {
    // The AI pathfinder asks the world about terrain through this thin shim; it never
    // touches World internals directly (epic #131, creature_ai.rs).
    pub(super) fn ai_is_solid(&self, x: i32, y: i32, z: i32) -> bool {
        self.collide_solid(x, y, z)
    }

    // A creature ran into an impassable wall or a water edge: turn it away. Uses the
    // world rng so the turn stays deterministic. Delegates the heading swing to the
    // AI so the body eases around rather than snapping (epic #131).
    pub(super) fn creature_blocked(&mut self, c: &mut Creature, _dt: f32) {
        let turn = 2.0 + self.rand01() * 2.2;
        c.ai.on_blocked(turn);
    }

    pub(super) fn update_creatures(&mut self, dt: f32) {
        // Smooth step-up tuning. A creature blocked by a ledge it can stand on climbs
        // its Y up at CLIMB_SPEED blocks/sec (a clamber that reads over a few ticks at
        // the usual ~0.05s dt) instead of teleporting up a whole block. MAX_CLIMB caps
        // how tall a step it will attempt; anything taller stays blocked so the AI
        // turns and goes around, exactly as before this change.
        const CLIMB_SPEED: f32 = 3.0;
        const MAX_CLIMB: i32 = 2;
        let n = self.creatures.len();
        for i in 0..n {
            // Snapshot the fields we need for read-only logic, then write back.
            let mut c = self.creatures[i].clone();
            c.wander -= dt;
            if c.hit_flash > 0.0 {
                c.hit_flash -= dt;
            }
            let to_player = self.pos - c.pos;
            if c.aquatic {
                if c.wander <= 0.0 {
                    c.yaw = self.rand01() * 6.2831853;
                    c.wander = 1.0 + self.rand01() * 2.0;
                }
                let d2 = V3::new(c.yaw.sin(), 0.0, c.yaw.cos());
                let nx = c.pos + d2 * (c.speed * dt);
                if self.block_at(IVec3 {
                    x: Self::ifloor(nx.x),
                    y: Self::ifloor(nx.y),
                    z: Self::ifloor(nx.z),
                }) == WATER
                {
                    c.pos.x = nx.x;
                    c.pos.z = nx.z;
                } else if c.wander <= 0.0 {
                    c.yaw += 2.0 + self.rand01() * 2.2;
                    c.wander = 0.6 + self.rand01() * 0.6;
                }
                c.pos.y += (self.world_clock as f32 * 2.0 + c.pos.x).sin() * 0.4 * dt;
                if self.block_at(IVec3 {
                    x: Self::ifloor(c.pos.x),
                    y: Self::ifloor(c.pos.y),
                    z: Self::ifloor(c.pos.z),
                }) != WATER
                    && self.block_at(IVec3 {
                        x: Self::ifloor(c.pos.x),
                        y: Self::ifloor(c.pos.y) - 1,
                        z: Self::ifloor(c.pos.z),
                    }) == WATER
                {
                    c.pos.y -= 0.5 * dt * 4.0;
                }
                self.creatures[i] = c;
                continue;
            }
            // ---- AI + smooth locomotion (epic #131, creature_ai.rs) -----------
            // Decision (which state, where to face, how fast) and the path follow
            // + smooth turn/accel all live in creature_ai; here we only classify
            // the creature into a temperament, run melee, and apply the resulting
            // smoothed displacement through the EXISTING collision/climb code below.
            use crate::creature_ai as cai;
            let xzd = (to_player.x * to_player.x + to_player.z * to_player.z).sqrt();
            let temper = if c.wander > 900.0 {
                // Scripted straight-walker (set by debug_spawn_creature_at for the
                // deterministic locomotion/climb tests): ignore the player, walk on.
                cai::Temperament::Scripted
            } else if c.hostile {
                cai::Temperament::Hunter
            } else if c.friendly {
                // Befriended pet: follows the player, keeps comfortable spacing.
                cai::Temperament::Pet
            } else if c.model == 20 {
                // Villagers idle and roam their settlement.
                cai::Temperament::Villager
            } else {
                // Animals (incl. skittish ones) graze + flee the player.
                cai::Temperament::Passive
            };
            // Hostiles only seek/attack in survival; outside survival they amble.
            let hunting = c.hostile && self.mode == bf_game_mode::BF_MODE_SURVIVAL;
            let eff_temper = if c.hostile && !hunting {
                cai::Temperament::Passive
            } else {
                temper
            };
            // Melee: unchanged behaviour, fires when a hunting hostile is in range.
            if hunting {
                if c.atk_cd > 0.0 {
                    c.atk_cd -= dt;
                }
                let yd = ((c.pos.y + c.scale * 0.5) - (self.pos.y - 1.6)).abs();
                if xzd < 1.3 && yd < 1.6 && c.atk_cd <= 0.0 {
                    self.hurt_player(2.5);
                    c.atk_cd = 1.1;
                }
            }
            // Drive the behaviour state machine from the world rng so it stays
            // deterministic with the rest of the sim. The world's rng is the seed.
            c.ai.tick_repath();
            let mut seed = self.rng;
            let dec = cai::decide(
                &mut c.ai, eff_temper, c.pos.x, c.pos.z, self.pos.x, self.pos.z, xzd, dt, &mut seed,
            );
            self.rng = seed;
            // Seeking hostiles path around obstacles with throttled, bounded A*.
            let mut desired_heading = dec.desired_heading;
            if let Some(goal) = dec.path_goal {
                if c.ai.needs_repath(goal) {
                    let sy = Self::ifloor(c.pos.y);
                    let path = cai::find_path(
                        self,
                        Self::ifloor(c.pos.x),
                        Self::ifloor(c.pos.z),
                        sy,
                        goal.0,
                        goal.1,
                    );
                    c.ai.set_path(path);
                }
                if let Some(h) = c.ai.follow_heading(c.pos.x, c.pos.z) {
                    desired_heading = h;
                } else {
                    // Path exhausted but not yet in melee range: steer straight in.
                    desired_heading = (self.pos.x - c.pos.x).atan2(self.pos.z - c.pos.z);
                }
            } else {
                c.ai.path.clear();
            }
            // Smooth turn + accel toward the decision, then apply the displacement
            // through the existing collision/climb code. step_locomotion never snaps
            // heading or velocity, so creatures rotate and ramp instead of flipping.
            let target_speed = c.speed * dec.speed_frac;
            let (mdx, mdz, new_heading, new_speed) =
                cai::step_locomotion(&c.ai, desired_heading, target_speed, dt);
            c.ai.heading = new_heading;
            c.ai.speed = new_speed;
            c.yaw = new_heading;
            let next = V3::new(c.pos.x + mdx, c.pos.y, c.pos.z + mdz);
            let nv = IVec3 {
                x: Self::ifloor(next.x),
                y: Self::ifloor(next.y),
                z: Self::ifloor(next.z),
            };
            let into_water = !c.aquatic
                && (self.block_at(IVec3 {
                    x: nv.x,
                    y: nv.y,
                    z: nv.z,
                }) == WATER
                    || self.block_at(IVec3 {
                        x: nv.x,
                        y: nv.y - 1,
                        z: nv.z,
                    }) == WATER);
            // #95 walls keep monsters out: a hostile may not cross into a walled village's
            // protected interior. (The wall blocks itself stop a creature that bumps the
            // line; this is the belt-and-braces guard so a hostile can never slip through
            // the gate or a worldgen seam into a protected interior.) A hostile already
            // somehow inside is free to leave.
            let into_protected = c.hostile
                && self.village_protects(nv.x, nv.z).is_some()
                && self
                    .village_protects(Self::ifloor(c.pos.x), Self::ifloor(c.pos.z))
                    .is_none();
            if !into_water && !into_protected && !self.collide_solid(nv.x, nv.y, nv.z) {
                c.pos.x = next.x;
                c.pos.z = next.z;
            } else if !into_water && !into_protected {
                // Blocked horizontally by a step. Find the lowest height the creature
                // could stand on top of: scan up from the blocking block to the first
                // free cell, capped at MAX_CLIMB blocks. A step within reach starts a
                // smooth climb (raise Y over several ticks, see below) instead of the
                // old instant one block pop; a taller wall stays blocked so the AI
                // turns and paths around it just like before.
                let mut step_h = 0i32;
                let mut h = 1i32;
                while h <= MAX_CLIMB {
                    if !self.collide_solid(nv.x, nv.y + h, nv.z) {
                        step_h = h;
                        break;
                    }
                    h += 1;
                }
                if step_h > 0 {
                    // Take the horizontal step now and queue the remaining vertical
                    // rise; the climb advance below interpolates Y up smoothly.
                    c.pos.x = next.x;
                    c.pos.z = next.z;
                    c.climb = (step_h as f32 - (c.pos.y - c.pos.y.floor())).max(c.climb);
                } else {
                    // Wall too tall to step: nudge the AI to turn away. Pathing
                    // creatures repath next chance; wanderers pick a new amble dir.
                    self.creature_blocked(&mut c, dt);
                }
            } else if into_water {
                // Edge of water: turn away rather than wade in (non-aquatic).
                self.creature_blocked(&mut c, dt);
            } else if into_protected {
                // #95 turned back at a village wall: stay out and pick a new heading.
                self.creature_blocked(&mut c, dt);
            }
            if c.climb > 0.0 {
                // Smooth clamber: raise Y toward the ledge top at a fixed climb speed
                // (deterministic, fixed dt) rather than snapping a whole block. Gravity
                // is skipped this tick so it does not pull against the climb.
                let rise = (CLIMB_SPEED * dt).min(c.climb);
                c.pos.y += rise;
                c.climb -= rise;
                if c.climb < 1e-4 {
                    c.climb = 0.0;
                }
                c.vy = 0.0;
            } else {
                // gravity + land on floor below.
                c.vy -= 24.0 * dt;
                c.pos.y += c.vy * dt;
                let fy = self.floor_below(
                    Self::ifloor(c.pos.x),
                    c.pos.y.floor() as i32 + 1,
                    Self::ifloor(c.pos.z),
                );
                if fy != NO_FLOOR && c.pos.y <= fy as f32 {
                    c.pos.y = fy as f32;
                    c.vy = 0.0;
                } else if fy == NO_FLOOR {
                    c.vy = 0.0;
                }
            }
            let grounded_fy = if c.vy == 0.0 && !c.aquatic {
                let fy = self.floor_below(
                    Self::ifloor(c.pos.x),
                    c.pos.y.floor() as i32 + 1,
                    Self::ifloor(c.pos.z),
                );
                if fy != NO_FLOOR && (c.pos.y - fy as f32).abs() < 0.2 {
                    Some(fy)
                } else {
                    None
                }
            } else {
                None
            };
            let cell_xz = (Self::ifloor(c.pos.x), Self::ifloor(c.pos.z));
            self.creatures[i] = c;
            // #117 creatures leave prints too: a grounded land creature on fresh snow
            // compresses it. Same fresh-only, O(1) stamp as the player, so the cost is
            // bounded by the (small) creature count, not the trail length.
            if let Some(fy) = grounded_fy {
                self.stamp_footprint(IVec3 {
                    x: cell_xz.0,
                    y: fy,
                    z: cell_xz.1,
                });
            }
        }

        // ---- collision: creatures (animals + villagers) hold distinct space ----
        let nc = self.creatures.len();
        for i in 0..nc {
            if self.creatures[i].aquatic {
                continue;
            }
            for j in (i + 1)..nc {
                if self.creatures[j].aquatic {
                    continue;
                }
                let (ax0, az0, ay0, ascale) = {
                    let a = &self.creatures[i];
                    (a.pos.x, a.pos.z, a.pos.y, a.scale)
                };
                let (bx0, bz0, by0, bscale) = {
                    let b = &self.creatures[j];
                    (b.pos.x, b.pos.z, b.pos.y, b.scale)
                };
                let dx = bx0 - ax0;
                let dz = bz0 - az0;
                let d2 = dx * dx + dz * dz;
                let mut min_d = (ascale + bscale) * 0.45;
                if min_d < 0.7 {
                    min_d = 0.7;
                }
                if d2 >= min_d * min_d {
                    continue;
                }
                let deg = d2 <= 1e-6;
                let d = if deg { 0.001 } else { d2.sqrt() };
                let nx = if deg {
                    ((i + j) & 1) as f32 * 2.0 - 1.0
                } else {
                    dx / d
                };
                let nz = if deg { 0.0 } else { dz / d };
                let push = (min_d - d) * 0.5;
                let ax = ax0 - nx * push;
                let az = az0 - nz * push;
                let bx = bx0 + nx * push;
                let bz = bz0 + nz * push;
                if !self.collide_solid(Self::ifloor(ax), Self::ifloor(ay0), Self::ifloor(az)) {
                    self.creatures[i].pos.x = ax;
                    self.creatures[i].pos.z = az;
                }
                if !self.collide_solid(Self::ifloor(bx), Self::ifloor(by0), Self::ifloor(bz)) {
                    self.creatures[j].pos.x = bx;
                    self.creatures[j].pos.z = bz;
                }
            }
        }
        // ---- collision: keep non-hostile creatures out of the player's space ----
        let px = self.pos.x;
        let pz = self.pos.z;
        let survival = self.mode == bf_game_mode::BF_MODE_SURVIVAL;
        for i in 0..self.creatures.len() {
            let (cx0, cz0, cy0, cscale, aquatic, hostile) = {
                let c = &self.creatures[i];
                (c.pos.x, c.pos.z, c.pos.y, c.scale, c.aquatic, c.hostile)
            };
            if aquatic {
                continue;
            }
            if hostile && survival {
                continue;
            }
            let dx = cx0 - px;
            let dz = cz0 - pz;
            let d2 = dx * dx + dz * dz;
            let min_d = 0.85 + cscale * 0.45;
            if d2 >= min_d * min_d {
                continue;
            }
            let deg = d2 <= 1e-6;
            let d = if deg { 0.001 } else { d2.sqrt() };
            let nx = if deg { 1.0 } else { dx / d };
            let nz = if deg { 0.0 } else { dz / d };
            let push = min_d - d;
            let cx = cx0 + nx * push;
            let cz = cz0 + nz * push;
            if !self.collide_solid(Self::ifloor(cx), Self::ifloor(cy0), Self::ifloor(cz)) {
                self.creatures[i].pos.x = cx;
                self.creatures[i].pos.z = cz;
            }
        }
    }
}
