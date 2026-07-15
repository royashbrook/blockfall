use super::*;

impl<'c> World<'c> {
    /// Reconcile transient site state after non-combat culls (distance, mode change,
    /// or player respawn). Only actual combat/debug kills are allowed to clear a site.
    pub(super) fn reconcile_danger_sites_after_cull(&mut self, mut sites: Vec<(i32, i32)>) {
        sites.sort_unstable();
        sites.dedup();
        for key in sites {
            let alive = self
                .creatures
                .iter()
                .filter(|c| c.hostile && c.from_ruin && (c.home_x, c.home_z) == key)
                .count() as i32;
            if let Some(site) = self.ruin_sites.get_mut(&key) {
                if !site.cleared {
                    site.spawned = alive;
                }
            }
        }
    }

    // Procedural danger sites spawn a fixed encounter regardless of the night/quest
    // gate: ruins and grand towers get a defender band, while a boss castle gets one
    // anchored boss. A cleared site only re-arms after a long cooldown and once the
    // player has moved away. State is keyed on the deterministic structure anchor.
    pub(super) fn maintain_danger_sites(&mut self, dt: f32) {
        // Re-arm cooldown for a cleared ruin, and how far the player must be for the
        // cooldown to tick / a respawn to be allowed.
        const REARM_COOLDOWN: f32 = 300.0; // several minutes
        const AWAY_DIST: f32 = 64.0;
        if self.gen.is_none() || self.store.resident_count() < 20 {
            return;
        }
        // Hard Creative deliberately spawns harmless defenders for observation;
        // hostile hunting and damage remain survival-only.
        if !self.hostile_spawning_enabled() {
            return;
        }
        self.danger_timer -= dt;
        if self.danger_timer > 0.0 {
            return;
        }
        self.danger_timer = 3.0;

        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);

        // Advance re-arm cooldowns for cleared sites the player is away from, and re-arm
        // any whose cooldown has elapsed. We only re-arm far-away sites so a cleared
        // ruin cannot reload under the player's feet. One fixed danger tick of time.
        let tick = self.danger_timer;
        for (&(sx, sz), st) in self.ruin_sites.iter_mut() {
            if !st.cleared {
                continue;
            }
            let far = (Self::wrap_signed_block(sx - px) as f32).abs() >= AWAY_DIST
                || (Self::wrap_signed_block(sz - pz) as f32).abs() >= AWAY_DIST;
            if !far {
                continue;
            }
            st.rearm_cd -= tick;
            if st.rearm_cd <= 0.0 {
                st.cleared = false;
                st.spawned = 0;
                st.rearm_cd = 0.0;
            }
        }

        // Find the nearest ruin or epic landmark within a reasonable radius.
        let site = worldgen::worldgen_dangerous_site_typed_near(px, pz, 48, self.seed);
        let (site_type, ax, ay, az) = match site {
            Some(s) => s,
            None => return,
        };
        let boss_site = worldgen::worldgen_danger_site_is_boss(site_type);
        let encounter_size = if boss_site { 1 } else { 3 };
        // Only spawn once the ruin's chunk is actually resident (avoids spawning into
        // ungenerated space).
        if !self.store.is_resident(Self::to_chunk(IVec3 {
            x: ax,
            y: ay,
            z: az,
        })) {
            return;
        }

        let key = (ax, az);
        let st = self.ruin_sites.entry(key).or_default();
        // A cleared site stays cleared until it re-arms (handled above). Do not respawn.
        if st.cleared {
            return;
        }
        // This site has already spawned its full band of defenders for this cycle. If
        // they are all dead, mark it cleared (one-shot until re-arm); otherwise wait.
        if st.spawned >= encounter_size {
            let alive = self
                .creatures
                .iter()
                .any(|c| c.hostile && c.from_ruin && c.home_x == ax && c.home_z == az);
            if !alive {
                let already_rewarded = {
                    let st = self.ruin_sites.get_mut(&key).expect("site present");
                    st.cleared = true;
                    st.rearm_cd = REARM_COOLDOWN;
                    st.rewarded
                };
                // Reward the player for clearing the ruin, once per site (never on a
                // re-cleared site). Reuses the same loot path creatures use on death.
                if !already_rewarded {
                    self.drop_ruin_clear_reward();
                    let st = self.ruin_sites.get_mut(&key).expect("site present");
                    st.rewarded = true;
                }
            }
            return;
        }
        // Still arming: spawn one creature per tick. Ordinary defenders jitter around
        // the anchor; the scale-2 boss occupies the castle's deliberately clear arena.
        let spawned = if boss_site {
            self.spawn_boss_at(ax, ay, az)
        } else {
            self.spawn_hostile_at(ax, ay, az)
        };
        if spawned {
            let st = self.ruin_sites.get_mut(&key).expect("site present");
            st.spawned += 1;
        }
    }

    /// Spawn one content-defined boss at a rare castle anchor. It is hostile in
    /// Survival but remains a harmless wandering observation subject in Creative.
    fn spawn_boss_at(&mut self, ax: i32, ay: i32, az: i32) -> bool {
        let gy = self.floor_below(ax, ay + 4, az);
        if gy == NO_FLOOR || self.creature_body_blocked(ax as f32 + 0.5, gy, az as f32 + 0.5, 2.0) {
            return false;
        }
        let boss_count = self
            .extra
            .map(|x| x.creatures().iter().filter(|d| d.disposition == "boss").count())
            .unwrap_or(0);

        let mut c = Creature::default();
        c.pos = V3::new(ax as f32 + 0.5, gy as f32, az as f32 + 0.5);
        c.yaw = self.rand01() * std::f32::consts::TAU;
        c.hostile = true;
        c.is_boss = true;
        c.from_ruin = true;
        c.home_x = ax;
        c.home_z = az;
        c.scale = 2.0;
        if boss_count == 0 {
            c.name = "castle_guardian".into();
            c.speed = 1.2;
            c.hp = 20;
            c.color = Self::color_for("boss", 0);
        } else {
            let pick = (self.rand01() * boss_count as f32) as usize % boss_count;
            let d = self
                .extra
                .and_then(|x| x.creatures().iter().filter(|d| d.disposition == "boss").nth(pick))
                .expect("boss count came from the same content registry");
            c.name = d.name.clone();
            c.model = d.model;
            c.speed = d.move_speed.max(0.8) * 0.7;
            c.hp = (d.max_health as i32).max(20);
            c.color = Self::color_for("boss", d.id);
        }
        self.creatures.push(c);
        true
    }

    // Spawn a single ruin "danger site" hostile near (ax,ay,az). Mirrors the body of
    // spawn_hostile but anchors at the site and marks the creature from_ruin so the
    // night/quest gate does not cull it. The anchor is recorded in home_x/home_z so the
    // danger-site pass can tell which ruin a defender belongs to. Returns true on
    // success.
    pub(super) fn spawn_hostile_at(&mut self, ax: i32, ay: i32, az: i32) -> bool {
        let ox = Self::wrap_pos_f(ax as f32 + (self.rand01() * 6.0 - 3.0));
        let oz = Self::wrap_pos_f(az as f32 + (self.rand01() * 6.0 - 3.0));
        let gy = self.floor_below(Self::ifloor(ox), ay + 5, Self::ifloor(oz));
        if gy == NO_FLOOR {
            return false;
        }
        // #232: a defender jittered into ruin masonry would spawn embedded; the
        // 3s danger tick just tries a fresh jitter next round.
        if self.creature_body_blocked(ox, gy, oz, 1.0) {
            return false;
        }
        let mut c = Creature::default();
        c.pos = V3::new(ox, gy as f32, oz);
        c.yaw = self.rand01() * 6.2831853;
        c.hostile = true;
        c.from_ruin = true;
        // Record the ruin anchor so the danger-site pass can tell which site this
        // defender belongs to (used to detect a cleared ruin).
        c.home_x = ax;
        c.home_z = az;
        c.scale = 1.0;
        let pool: Vec<CreatureDefX> = self
            .extra
            .map(|x| {
                x.creatures()
                    .iter()
                    .filter(|d| d.disposition == "hostile")
                    .filter(|d| !matches!(d.name.as_str(), "smudgeling" | "hollow"))
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
}
