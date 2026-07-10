use super::*;

impl<'c> World<'c> {
    pub(super) fn spawn_ring_creature(&mut self, boss: bool, rmin: f32, rmax: f32) -> bool {
        let ang = self.rand01() * 6.2831853;
        let r = rmin + self.rand01() * (rmax - rmin);
        let cx = Self::wrap_pos_f(self.pos.x + ang.cos() * r);
        let cz = Self::wrap_pos_f(self.pos.z + ang.sin() * r);
        let gy = self.floor_below(Self::ifloor(cx), self.pos.y as i32 + 30, Self::ifloor(cz));
        if gy == NO_FLOOR {
            return false;
        }
        if self.block_at(IVec3 {
            x: Self::ifloor(cx),
            y: gy + 1,
            z: Self::ifloor(cz),
        }) == WATER
        {
            return false;
        }
        // #232: never spawn a body inside blocks (a hut interior, a wall line) —
        // a big animal placed there can only stand trapped. The maintain tick
        // simply retries somewhere else next round.
        let scale = if boss { 2.0 } else { 0.8 };
        if self.creature_body_blocked(cx, gy, cz, scale) {
            return false;
        }
        let mut c = Creature::default();
        c.pos = V3::new(cx, gy as f32, cz);
        c.yaw = self.rand01() * 6.2831853;
        c.wander = 1.0 + self.rand01() * 2.0;
        c.is_boss = boss;
        let have_extra = self
            .extra
            .map(|x| !x.creatures().is_empty())
            .unwrap_or(false);
        if have_extra {
            let bk = self.biome_key();
            // Build the pool (immutable borrow of extra) collecting cloned defs.
            let pool: Vec<CreatureDefX> = {
                let x = self.extra.unwrap();
                let mut p: Vec<CreatureDefX> = Vec::new();
                for d in x.creatures() {
                    if (d.disposition == "boss") != boss {
                        continue;
                    }
                    if d.model == 20 {
                        continue;
                    }
                    if !boss && (d.disposition == "hostile" || d.disposition == "aquatic") {
                        continue;
                    }
                    if !(d.biome.is_empty() || d.biome == "any" || d.biome == bk) {
                        continue;
                    }
                    p.push(d.clone());
                }
                if p.is_empty() {
                    for d in x.creatures() {
                        if (d.disposition == "boss") != boss {
                            continue;
                        }
                        if d.model == 20 {
                            continue;
                        }
                        if !boss && (d.disposition == "hostile" || d.disposition == "aquatic") {
                            continue;
                        }
                        p.push(d.clone());
                    }
                }
                p
            };
            if !pool.is_empty() {
                let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
                let d = &pool[pick];
                c.name = d.name.clone();
                c.color = Self::color_for(if boss { "boss" } else { &d.disposition }, d.id);
                c.speed = if boss {
                    d.move_speed * 0.7
                } else {
                    d.move_speed
                };
                c.shape = (d.id % 8) as i32;
                c.model = d.model;
                c.skittish = d.disposition == "skittish";
                c.hp = if d.max_health > 0 {
                    d.max_health as i32
                } else if boss {
                    10
                } else {
                    5
                };
            } else {
                c.hp = if boss { 10 } else { 5 };
            }
        } else {
            c.color = Self::color_for(
                if boss { "boss" } else { "passive" },
                (self.creatures.len() + 1) as u16,
            );
            c.speed = if boss { 1.2 } else { 1.6 };
            c.name = if boss {
                "guardian".into()
            } else {
                "critter".into()
            };
            c.shape = (self.creatures.len() % 8) as i32;
            c.hp = if boss { 10 } else { 5 };
        }
        c.scale = scale;
        self.creatures.push(c);
        true
    }

    pub(super) fn spawn_hostile(&mut self, rmin: f32, rmax: f32) -> bool {
        let ang = self.rand01() * 6.2831853;
        let r = rmin + self.rand01() * (rmax - rmin);
        let cx = Self::wrap_pos_f(self.pos.x + ang.cos() * r);
        let cz = Self::wrap_pos_f(self.pos.z + ang.sin() * r);
        // #232: find a floor the BODY actually fits on. The old first-floor scan
        // happily returned a cell inside solid rock underground (the hostile
        // spawned embedded in the cave wall), so descend through solid runs to
        // an actual air pocket near the player's level before giving up.
        let sx = Self::ifloor(cx);
        let sz = Self::ifloor(cz);
        let top = self.pos.y as i32 + 3;
        let mut gy = NO_FLOOR;
        let mut y = top;
        while y > top - 30 {
            if !self.collide_solid(sx, y, sz) && !self.collide_solid(sx, y + 1, sz) {
                let f = self.floor_below(sx, y, sz);
                if f == NO_FLOOR {
                    break;
                }
                if !self.creature_body_blocked(cx, f, cz, 1.0) {
                    gy = f;
                    break;
                }
                y = f - 2; // below this pocket's floor: keep descending
            } else {
                y -= 1;
            }
        }
        if gy == NO_FLOOR {
            return false;
        }
        // Never spawn in lit areas (torches make a safe zone).
        {
            let lc = Self::to_chunk(IVec3 {
                x: Self::ifloor(cx),
                y: gy,
                z: Self::ifloor(cz),
            });
            if let Some(lch) = self.store.get(lc) {
                let bl = lch.block_light(
                    Self::mod16(Self::ifloor(cx)) as usize,
                    Self::mod16(gy) as usize,
                    Self::mod16(Self::ifloor(cz)) as usize,
                );
                if bl >= 7 {
                    return false;
                }
            }
        }
        // #95 walls keep monsters out: never spawn a hostile inside a walled village's
        // protected interior.
        if self
            .village_protects(Self::ifloor(cx), Self::ifloor(cz))
            .is_some()
        {
            return false;
        }
        let mut c = Creature::default();
        c.pos = V3::new(cx, gy as f32, cz);
        c.yaw = self.rand01() * 6.2831853;
        c.hostile = true;
        c.scale = 1.0;
        // #200: hostiles are per-biome now, same filter rule as the passive pool
        // (empty or "any" spawns everywhere; otherwise the biome key must match).
        let bk = self.biome_key();
        let pool: Vec<CreatureDefX> = self
            .extra
            .map(|x| {
                x.creatures()
                    .iter()
                    .filter(|d| d.disposition == "hostile")
                    .filter(|d| d.biome.is_empty() || d.biome == "any" || d.biome == bk)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        if !pool.is_empty() {
            let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
            let d = &pool[pick];
            c.name = d.name.clone();
            c.model = d.model;
            c.speed = if d.move_speed > 0.0 {
                d.move_speed
            } else {
                2.6
            };
            c.hp = if d.max_health > 0 {
                d.max_health as i32
            } else {
                6
            };
            c.color = Self::color_for("hostile", d.id);
        } else {
            c.speed = 2.6;
            c.hp = 6;
            c.shape = if self.rand01() < 0.5 { 1 } else { 0 };
            c.color = if c.shape == 1 {
                V3::new(0.16, 0.13, 0.20)
            } else {
                V3::new(0.12, 0.10, 0.16)
            };
            c.name = if c.shape == 1 {
                "lurker".into()
            } else {
                "monster".into()
            };
        }
        self.creatures.push(c);
        true
    }

    pub(super) fn spawn_fish(&mut self, rmin: f32, rmax: f32) -> bool {
        let pool: Vec<CreatureDefX> = match self.extra {
            Some(x) => x
                .creatures()
                .iter()
                .filter(|d| d.disposition == "aquatic")
                .cloned()
                .collect(),
            None => return false,
        };
        if pool.is_empty() {
            return false;
        }
        let ang = self.rand01() * 6.2831853;
        let r = rmin + self.rand01() * (rmax - rmin);
        let wx = Self::wrap_block(Self::ifloor(self.pos.x + ang.cos() * r));
        let wz = Self::wrap_block(Self::ifloor(self.pos.z + ang.sin() * r));
        let mut wy = NO_FLOOR;
        let mut y = Self::ifloor(self.pos.y) + 4;
        while y > Self::ifloor(self.pos.y) - 20 {
            if self.block_at(IVec3 { x: wx, y, z: wz }) == WATER {
                wy = y;
                break;
            }
            y -= 1;
        }
        if wy == NO_FLOOR {
            return false;
        }
        let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
        let d = &pool[pick];
        let mut c = Creature::default();
        c.pos = V3::new(wx as f32 + 0.5, wy as f32, wz as f32 + 0.5);
        c.yaw = self.rand01() * 6.2831853;
        c.aquatic = true;
        c.model = d.model;
        c.name = d.name.clone();
        c.speed = if d.move_speed > 0.0 {
            d.move_speed
        } else {
            2.0
        };
        c.hp = if d.max_health > 0 {
            d.max_health as i32
        } else {
            3
        };
        c.scale = 0.55;
        c.color = Self::color_for("aquatic", d.id);
        self.creatures.push(c);
        true
    }

    /// #238 (v27): 0 easy, 1 normal, 2 hard. Out-of-range clamps to normal.
    pub fn set_difficulty(&mut self, d: i32) {
        self.difficulty = if (0..=2).contains(&d) { d } else { 1 };
    }

    pub(super) fn maintain_creatures(&mut self, dt: f32) {
        if self.gen.is_none() || self.store.resident_count() < 20 {
            return;
        }
        self.creature_timer -= dt;
        if self.creature_timer > 0.0 {
            return;
        }
        let kdespawn2 = 90.0f32 * 90.0;
        let px = self.pos.x;
        let pz = self.pos.z;
        self.creatures.retain(|c| {
            let dx = Self::wrap_signed_f(c.pos.x - px);
            let dz = Self::wrap_signed_f(c.pos.z - pz);
            (dx * dx + dz * dz) <= kdespawn2
        });
        let t = Self::day_time(self.world_clock);
        let surv = self.mode == bf_game_mode::BF_MODE_SURVIVAL;
        let night = surv && Self::is_night_phase(t);
        let dark_cave = surv
            && (worldgen::worldgen_surface_height(
                Self::ifloor(self.pos.x),
                Self::ifloor(self.pos.z),
                self.seed,
            ) - Self::ifloor(self.pos.y))
                > 6;
        // #238 difficulty: 0 easy = no bad guys at all, 1 normal = the tuning
        // below, 2 hard = more monsters, faster. Easy wins over every gate and
        // also removes ruin hostiles, which are otherwise active around the clock.
        let easy = self.difficulty == 0;
        let hard = self.difficulty == 2;
        let monsters_active =
            !easy && (night || dark_cave) && self.quests_completed > 0;
        if easy {
            self.creatures.retain(|c| !c.hostile);
        } else if !monsters_active {
            // Cull gated (night/cave) hostiles when the gate is closed, but keep the
            // ruin "danger site" hostiles, which are dangerous around the clock.
            self.creatures.retain(|c| !c.hostile || c.from_ruin);
        }
        let mut ambient = 0;
        let mut bosses = 0;
        let mut hostiles = 0;
        for c in &self.creatures {
            if c.hostile {
                // Ruin hostiles are managed by the danger-site pass, not the night
                // cap, so they do not block normal night spawns.
                if !c.from_ruin {
                    hostiles += 1;
                }
            } else if c.is_boss {
                bosses += 1;
            } else if c.model != 20 {
                ambient += 1;
            }
        }
        self.creature_timer = 1.0;
        if monsters_active {
            // Hard: twice the cap, checked more than twice as often.
            self.creature_timer = if hard { 1.0 } else { 2.5 };
            if hostiles < if hard { 8 } else { 4 } {
                self.spawn_hostile(10.0, 22.0);
            }
        } else if ambient < 9 {
            self.creature_timer = if ambient < 6 { 0.1 } else { 0.5 };
            self.spawn_ring_creature(false, 8.0, 26.0);
        } else if bosses < 2 {
            self.creature_timer = 1.0;
            self.spawn_ring_creature(true, 18.0, 40.0);
        }
        let fish = self.creatures.iter().filter(|c| c.aquatic).count();
        if fish < 4 && self.rand01() < 0.5 {
            self.spawn_fish(6.0, 22.0);
        }
    }
}
