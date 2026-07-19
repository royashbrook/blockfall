use super::*;

const SOCIAL_LOOK: u32 = 5;
const SOCIAL_GESTURE: u32 = 6;
const SOCIAL_GREET: u32 = 7;
const SOCIAL_CHAT: u32 = 8;
pub(super) const SOCIAL_SIT: u32 = 9;
const SOCIAL_SWEEP: u32 = 10;
const SOCIAL_HOME_RADIUS: i32 = 12;
const SOCIAL_TRAVEL_SECONDS: f32 = 12.0;
const GUARD_RANGE: f32 = 11.0;

impl<'c> World<'c> {
    // The AI pathfinder asks the world about terrain through this thin shim; it never
    // touches World internals directly (epic #131, creature_ai.rs).
    pub(super) fn ai_is_solid(&self, x: i32, y: i32, z: i32) -> bool {
        self.collide_solid(x, y, z)
    }

    // A creature ran into an impassable wall or a water edge: turn it away. Uses the
    // world rng so the turn stays deterministic. Delegates the heading swing to the
    // AI so the body eases around rather than snapping (epic #131).
    // #226 body-aware creature collision: a creature occupies a scale-based XZ
    // footprint and up to two cells of height, so a wide animal cannot poke
    // through a trunk and a villager keeps a natural gap off walls. LEAVES are
    // passable for creatures (walking under a canopy is fine, per design);
    // everything else follows collide_solid (plants/snow/water passable).
    pub(super) fn creature_body_blocked(&self, x: f32, y_feet: i32, z: f32, scale: f32) -> bool {
        let hw = (scale * 0.30).clamp(0.20, 0.60);
        let x0 = Self::ifloor(x - hw);
        let x1 = Self::ifloor(x + hw);
        let z0 = Self::ifloor(z - hw);
        let z1 = Self::ifloor(z + hw);
        let head = if scale > 1.1 { 1 } else { 0 };
        for cy in y_feet..=(y_feet + head) {
            for cx in x0..=x1 {
                for cz in z0..=z1 {
                    if self.collide_solid(cx, cy, cz) {
                        let b = self.block_at(IVec3 { x: cx, y: cy, z: cz });
                        if !Self::is_leaf(b) {
                            return true;
                        }
                    }
                }
            }
        }
        false
    }

    // #231: relocate an embedded creature to the nearest clear standable cell.
    // Rings outward up to 3 blocks, keeps the landing within +-2 of the current
    // height so a hut-trapped villager pops out the door line, not onto the roof.
    // Returns false when no clear cell exists nearby (caller leaves it be).
    pub(super) fn creature_unstick(&mut self, c: &mut Creature) -> bool {
        let cx0 = Self::ifloor(c.pos.x);
        let cy = Self::ifloor(c.pos.y + 0.01);
        let cz0 = Self::ifloor(c.pos.z);
        for r in 1..=3i32 {
            for dx in -r..=r {
                for dz in -r..=r {
                    if dx.abs() != r && dz.abs() != r {
                        continue; // ring perimeter only; inner rings already scanned
                    }
                    let x = Self::wrap_block(cx0 + dx);
                    let z = Self::wrap_block(cz0 + dz);
                    let fy = self.floor_below(x, cy + 3, z);
                    if fy == NO_FLOOR || (fy - cy).abs() > 2 {
                        continue;
                    }
                    let fx = x as f32 + 0.5;
                    let fz = z as f32 + 0.5;
                    if !self.creature_body_blocked(fx, fy, fz, c.scale) {
                        c.pos = V3::new(fx, fy as f32, fz);
                        c.vy = 0.0;
                        c.climb = 0.0;
                        return true;
                    }
                }
            }
        }
        false
    }

    pub(super) fn creature_blocked(&mut self, c: &mut Creature, _dt: f32) {
        let turn = 2.0 + self.rand01() * 2.2;
        c.ai.on_blocked(turn);
    }

    // #253: every visible artisan routine uses the same physical contract: one
    // role-owned station at a canonical home offset and a clear work cell west.
    // The Y scan runs only when a shift starts; cached validation makes removed
    // blocks and old saves without stations fall back safely.
    fn profession_station_spec(npc_id: i32) -> Option<(i32, i32, BlockId)> {
        match npc_id {
            2 => Some((6, 6, 61)),   // builder sawbench
            3 => Some((4, -4, 60)),  // herbalist table
            4 => Some((4, 4, 56)),   // woodcutter chopping block
            5 => Some((-4, 4, 58)),  // mason bench
            6 => Some((-4, -4, 59)), // blacksmith forge
            _ => None,
        }
    }

    fn profession_station(&self, c: &Creature, scan: bool) -> Option<(i32, i32, i32, i32)> {
        let (dx, dz, station_block) = Self::profession_station_spec(c.npc_id)?;
        self.villager_feature(
            c,
            station_block,
            dx,
            dz,
            (!scan).then_some(c.routine.station_y),
        )
    }

    fn villager_feature(
        &self,
        c: &Creature,
        block: BlockId,
        dx: i32,
        dz: i32,
        cached_y: Option<i32>,
    ) -> Option<(i32, i32, i32, i32)> {
        let sx = Self::wrap_block(c.home_x + dx);
        let sz = Self::wrap_block(c.home_z + dz);
        let wx = Self::wrap_block(sx - 1);
        let sy = if let Some(y) = cached_y {
            y
        } else {
            (WORLD_Y_MIN_BLOCK..=WORLD_Y_MAX_BLOCK)
                .rev()
                .find(|&y| self.block_at(IVec3 { x: sx, y, z: sz }) == block)?
        };
        if sy == NO_FLOOR
            || self.block_at(IVec3 { x: sx, y: sy, z: sz }) != block
            || !self.collide_solid(wx, sy - 1, sz)
            || self.creature_body_blocked(wx as f32 + 0.5, sy, sz as f32 + 0.5, c.scale)
        {
            return None;
        }
        Some((sx, sy, wx, sz))
    }

    pub(super) fn villager_social_key(c: &Creature) -> u64 {
        let mut h = (c.home_x as u32 as u64).wrapping_mul(0x9E3779B185EBCA87)
            ^ (c.home_z as u32 as u64).wrapping_mul(0xC2B2AE3D27D4EB4F)
            ^ (c.npc_id as u32 as u64).wrapping_mul(0x165667B19E3779F9);
        h ^= h >> 30;
        h = h.wrapping_mul(0xBF58476D1CE4E5B9);
        h ^= h >> 27;
        h | 1
    }

    #[inline]
    fn villager_social_window(c: &Creature) -> bool {
        Self::profession_station_spec(c.npc_id).is_none()
            || (c.routine.state == VillagerRoutineState::Idle && c.routine.timer > 0.0)
    }

    fn villager_social_pair_index(&self, c: &Creature) -> Option<usize> {
        let mut group: Vec<(u64, usize)> = self
            .creatures
            .iter()
            .enumerate()
            .filter(|(_, other)| {
                other.model == 20
                    && other.hp > 0
                    && other.home_x == c.home_x
                    && other.home_z == c.home_z
                    && {
                        // Every resident computes the same roster from the shared
                        // home anchor. A caller-relative A-B-C chain can otherwise
                        // let both edge villagers claim the middle one.
                        let dx = Self::wrap_signed_f(other.pos.x - (c.home_x as f32 + 0.5));
                        let dz = Self::wrap_signed_f(other.pos.z - (c.home_z as f32 + 0.5));
                        dx * dx + dz * dz <= (SOCIAL_HOME_RADIUS * SOCIAL_HOME_RADIUS) as f32
                    }
            })
            .map(|(idx, other)| (Self::villager_social_key(other), idx))
            .collect();
        group.sort_unstable();
        let key = Self::villager_social_key(c);
        let at = group.iter().position(|&(candidate, _)| candidate == key)?;
        let partner = if at & 1 == 0 { at + 1 } else { at - 1 };
        group.get(partner).map(|&(_, idx)| idx)
    }

    fn set_villager_social(
        c: &mut Creature,
        action: u32,
        seconds: f32,
        target_y: i32,
        partner: u64,
        arrived: bool,
    ) {
        c.social.action = action;
        c.social.timer = if arrived { seconds } else { SOCIAL_TRAVEL_SECONDS };
        c.social.total = seconds;
        c.social.target_y = target_y;
        c.social.partner = partner;
        c.social.arrived = arrived;
        c.social.initialized = true;
        c.ai.path.clear();
        c.ai.path_idx = 0;
        c.ai.repath_cd = 0;
    }

    fn finish_villager_social(c: &mut Creature) {
        let key = Self::villager_social_key(c);
        c.social.action = 0;
        c.social.timer = 0.0;
        c.social.partner = 0;
        c.social.arrived = false;
        c.social.cooldown = 2.0 + ((key >> 17) % 5) as f32 * 0.45;
        c.ai.path.clear();
        c.ai.path_idx = 0;
        c.ai.repath_cd = 0;
    }

    #[inline]
    pub(super) fn villager_social_action(key: u64, sequence: u32) -> u32 {
        SOCIAL_LOOK + ((key.wrapping_add(sequence as u64)) % 6) as u32
    }

    fn start_villager_social(&mut self, c: &mut Creature) {
        let key = Self::villager_social_key(c);
        let mut action = Self::villager_social_action(key, c.social.sequence);
        c.social.sequence = c.social.sequence.wrapping_add(1);
        let partner = self.villager_social_pair_index(c);

        if action == SOCIAL_CHAT {
            if let Some(j) = partner.filter(|&j| {
                self.creatures[j].social.action == 0
                    && Self::villager_social_window(&self.creatures[j])
            }) {
                let partner_key = Self::villager_social_key(&self.creatures[j]);
                Self::set_villager_social(
                    &mut self.creatures[j], SOCIAL_CHAT, 3.2, NO_FLOOR, key, false,
                );
                Self::set_villager_social(c, SOCIAL_CHAT, 3.2, NO_FLOOR, partner_key, false);
                return;
            }
            action = SOCIAL_GREET;
        }

        if action == SOCIAL_GREET {
            if let Some(j) = partner {
                let p = &self.creatures[j];
                Self::set_villager_social(
                    c, action, 1.8, NO_FLOOR, Self::villager_social_key(p), true,
                );
                return;
            }
            action = SOCIAL_LOOK;
        }

        if matches!(action, SOCIAL_SIT | SOCIAL_SWEEP) {
            let (block, dz, seconds) = if action == SOCIAL_SIT {
                (62, 6, 3.0)
            } else {
                (63, -6, 3.4)
            };
            if let Some((_sx, sy, _wx, _wz)) =
                self.villager_feature(c, block, 0, dz, None)
            {
                Self::set_villager_social(c, action, seconds, sy, 0, false);
                return;
            }
            action = SOCIAL_LOOK;
        }

        let seconds = if action == SOCIAL_GESTURE { 1.7 } else { 1.5 };
        Self::set_villager_social(c, action, seconds, NO_FLOOR, 0, true);
    }

    fn villager_social_decision(
        &mut self,
        c: &mut Creature,
        dt: f32,
    ) -> Option<crate::creature_ai::Decision> {
        use crate::creature_ai::Decision;
        if c.social.action == 0 {
            if c.social.cooldown > 0.0 {
                return None;
            }
            self.start_villager_social(c);
        }
        let stop = |heading| Decision {
            desired_heading: heading,
            speed_frac: 0.0,
            path_goal: None,
        };
        match c.social.action {
            SOCIAL_LOOK | SOCIAL_GESTURE => {
                c.social.timer -= dt;
                let dir = ((Self::villager_social_key(c) >> 21)
                    .wrapping_add(c.social.sequence as u64)
                    & 3) as u32;
                let face = match dir {
                    0 => std::f32::consts::FRAC_PI_2,
                    1 => -std::f32::consts::FRAC_PI_2,
                    2 => 0.0,
                    _ => std::f32::consts::PI,
                };
                c.yaw = face;
                c.ai.heading = face;
                c.ai.speed = 0.0;
                if c.social.timer <= 0.0 {
                    Self::finish_villager_social(c);
                }
                Some(stop(face))
            }
            SOCIAL_GREET => {
                let Some(j) = self.villager_social_pair_index(c) else {
                    Self::finish_villager_social(c);
                    return Some(stop(c.ai.heading));
                };
                if Self::villager_social_key(&self.creatures[j]) != c.social.partner {
                    Self::finish_villager_social(c);
                    return Some(stop(c.ai.heading));
                }
                let p = self.creatures[j].pos;
                let face = Self::wrap_signed_f(p.x - c.pos.x)
                    .atan2(Self::wrap_signed_f(p.z - c.pos.z));
                c.yaw = face;
                c.ai.heading = face;
                c.ai.speed = 0.0;
                c.social.timer -= dt;
                if c.social.timer <= 0.0 {
                    Self::finish_villager_social(c);
                }
                Some(stop(face))
            }
            SOCIAL_CHAT => {
                let key = Self::villager_social_key(c);
                let Some(j) = self.villager_social_pair_index(c) else {
                    Self::finish_villager_social(c);
                    return Some(stop(c.ai.heading));
                };
                if Self::villager_social_key(&self.creatures[j]) != c.social.partner
                    || self.creatures[j].social.action != SOCIAL_CHAT
                    || self.creatures[j].social.partner != key
                {
                    Self::finish_villager_social(c);
                    return Some(stop(c.ai.heading));
                }
                let p = self.creatures[j].pos;
                let dx = Self::wrap_signed_f(p.x - c.pos.x);
                let dz = Self::wrap_signed_f(p.z - c.pos.z);
                let face = dx.atan2(dz);
                if dx * dx + dz * dz > 2.2 * 2.2 {
                    c.social.timer -= dt;
                    if c.social.timer <= 0.0 {
                        Self::finish_villager_social(c);
                        return Some(stop(face));
                    }
                    let goal = Self::villager_nearest_goal(
                        c.pos.x,
                        c.pos.z,
                        Self::ifloor(p.x),
                        Self::ifloor(p.z),
                    );
                    return Some(Decision {
                        desired_heading: face,
                        speed_frac: 0.65,
                        path_goal: Some(goal),
                    });
                }
                if !c.social.arrived {
                    c.social.arrived = true;
                    c.social.timer = c.social.total;
                    self.creatures[j].social.arrived = true;
                    self.creatures[j].social.timer = self.creatures[j].social.total;
                }
                c.social.timer -= dt;
                c.yaw = face;
                c.ai.heading = face;
                c.ai.speed = 0.0;
                if c.social.timer <= 0.0 {
                    if self.creatures[j].social.partner == key {
                        Self::finish_villager_social(&mut self.creatures[j]);
                    }
                    Self::finish_villager_social(c);
                }
                Some(stop(face))
            }
            SOCIAL_SIT | SOCIAL_SWEEP => {
                let (block, dz) = if c.social.action == SOCIAL_SIT { (62, 6) } else { (63, -6) };
                let Some((_sx, sy, wx, wz)) =
                    self.villager_feature(c, block, 0, dz, Some(c.social.target_y))
                else {
                    Self::finish_villager_social(c);
                    return Some(stop(c.ai.heading));
                };
                let dx = Self::wrap_signed_f(wx as f32 + 0.5 - c.pos.x);
                let dz = Self::wrap_signed_f(wz as f32 + 0.5 - c.pos.z);
                // villager_feature's approach cell is canonically one block west
                // of the prop. Face east once settled so work poses do not retain
                // an arbitrary diagonal from the last path step.
                let face = std::f32::consts::FRAC_PI_2;
                if dx * dx + dz * dz > 0.75 * 0.75 {
                    c.social.timer -= dt;
                    if c.social.timer <= 0.0 {
                        Self::finish_villager_social(c);
                        return Some(stop(face));
                    }
                    return Some(Decision {
                        desired_heading: dx.atan2(dz),
                        speed_frac: 0.7,
                        path_goal: Some(Self::villager_nearest_goal(c.pos.x, c.pos.z, wx, wz)),
                    });
                }
                c.pos.x = Self::wrap_pos_f(wx as f32 + 0.5);
                c.pos.y = sy as f32;
                c.pos.z = Self::wrap_pos_f(wz as f32 + 0.5);
                c.vy = 0.0;
                c.climb = 0.0;
                c.yaw = face;
                c.ai.heading = face;
                c.ai.speed = 0.0;
                if !c.social.arrived {
                    c.social.arrived = true;
                    c.social.timer = c.social.total;
                }
                c.social.timer -= dt;
                if c.social.timer <= 0.0 {
                    Self::finish_villager_social(c);
                }
                Some(stop(face))
            }
            _ => {
                Self::finish_villager_social(c);
                None
            }
        }
    }

    // Pick a real clear home cell, not the settlement marker block at the exact
    // anchor. Fixed candidate order keeps the result deterministic.
    fn villager_home_cell(&self, c: &Creature) -> Option<(i32, i32, i32)> {
        const CANDIDATES: [(i32, i32); 12] = [
            (2, 2),
            (2, -2),
            (-2, 2),
            (-2, -2),
            (-2, 0),
            (0, -2),
            (2, 0),
            (0, 2),
            (-3, 0),
            (0, -3),
            (3, 0),
            (0, 3),
        ];
        for (dx, dz) in CANDIDATES {
            let x = Self::wrap_block(c.home_x + dx);
            let z = Self::wrap_block(c.home_z + dz);
            // Search upward from terrain for the first supported body-clear cell.
            // A top-down floor query can mistake a civic lamp/awning roof for home.
            let base = if self.gen.is_some() {
                worldgen::worldgen_surface_height(x, z, self.seed)
            } else {
                self.floor_below(x, WORLD_Y_MAX_BLOCK + 1, z) - 1
            };
            for y in (base + 1)..=(base + 3) {
                if self.collide_solid(x, y - 1, z)
                    && !self.creature_body_blocked(
                        x as f32 + 0.5,
                        y,
                        z as f32 + 0.5,
                        c.scale,
                    )
                {
                    return Some((x, y, z));
                }
            }
        }
        None
    }

    fn villager_tether_decision(&self, c: &Creature) -> Option<crate::creature_ai::Decision> {
        use crate::creature_ai::Decision;
        let hx = Self::wrap_signed_f(c.home_x as f32 + 0.5 - c.pos.x);
        let hz = Self::wrap_signed_f(c.home_z as f32 + 0.5 - c.pos.z);
        if hx.abs().max(hz.abs()) <= SOCIAL_HOME_RADIUS as f32 {
            return None;
        }
        let Some((x, _y, z)) = self.villager_home_cell(c) else {
            return Some(Decision {
                desired_heading: c.ai.heading,
                speed_frac: 0.0,
                path_goal: None,
            });
        };
        let (gx, gz) = Self::villager_nearest_goal(c.pos.x, c.pos.z, x, z);
        Some(Decision {
            desired_heading: (gx as f32 + 0.5 - c.pos.x)
                .atan2(gz as f32 + 0.5 - c.pos.z),
            speed_frac: 0.75,
            path_goal: Some((gx, gz)),
        })
    }

    #[inline]
    pub(super) fn villager_nearest_goal(cx: f32, cz: f32, gx: i32, gz: i32) -> (i32, i32) {
        let bx = Self::ifloor(cx);
        let bz = Self::ifloor(cz);
        (
            bx + Self::wrap_signed_block(gx - bx),
            bz + Self::wrap_signed_block(gz - bz),
        )
    }

    fn set_villager_routine(c: &mut Creature, state: VillagerRoutineState, timer: f32) {
        c.routine.state = state;
        c.routine.timer = timer;
        c.ai.path.clear();
        c.ai.path_idx = 0;
        c.ai.repath_cd = 0;
    }

    fn villager_return_decision(&self, c: &mut Creature) -> crate::creature_ai::Decision {
        use crate::creature_ai::Decision;
        let Some((hx, hy, hz)) = self.villager_home_cell(c) else {
            Self::set_villager_routine(c, VillagerRoutineState::Idle, VILLAGER_IDLE_SECONDS);
            return Decision { desired_heading: c.ai.heading, speed_frac: 0.0, path_goal: None };
        };
        let dx = Self::wrap_signed_f(hx as f32 + 0.5 - c.pos.x);
        let dz = Self::wrap_signed_f(hz as f32 + 0.5 - c.pos.z);
        if dx * dx + dz * dz <= 0.45 * 0.45 || c.routine.timer <= 0.0 {
            if dx * dx + dz * dz <= 0.45 * 0.45 {
                c.pos.x = Self::wrap_pos_f(hx as f32 + 0.5);
                c.pos.y = hy as f32;
                c.pos.z = Self::wrap_pos_f(hz as f32 + 0.5);
            }
            Self::set_villager_routine(c, VillagerRoutineState::Idle, VILLAGER_IDLE_SECONDS);
            return Decision { desired_heading: c.ai.heading, speed_frac: 0.0, path_goal: None };
        }
        Decision {
            desired_heading: dx.atan2(dz),
            speed_frac: 0.85,
            path_goal: Some(Self::villager_nearest_goal(c.pos.x, c.pos.z, hx, hz)),
        }
    }

    fn profession_routine_decision(
        &self,
        c: &mut Creature,
        dt: f32,
    ) -> crate::creature_ai::Decision {
        use crate::creature_ai::Decision;
        c.routine.timer -= dt;
        match c.routine.state {
            VillagerRoutineState::Idle => {
                if c.routine.timer > 0.0 {
                    return Decision { desired_heading: c.ai.heading, speed_frac: 0.0, path_goal: None };
                }
                if let Some((_sx, sy, wx, wz)) = self.profession_station(c, true) {
                    c.routine.station_y = sy;
                    Self::set_villager_routine(
                        c,
                        VillagerRoutineState::TravelToStation,
                        VILLAGER_TRAVEL_SECONDS,
                    );
                    let (gx, gz) = Self::villager_nearest_goal(c.pos.x, c.pos.z, wx, wz);
                    let dx = gx as f32 + 0.5 - c.pos.x;
                    let dz = gz as f32 + 0.5 - c.pos.z;
                    Decision {
                        desired_heading: dx.atan2(dz),
                        speed_frac: 0.85,
                        path_goal: Some((gx, gz)),
                    }
                } else {
                    Self::set_villager_routine(
                        c,
                        VillagerRoutineState::ReturnHome,
                        VILLAGER_RETURN_SECONDS,
                    );
                    self.villager_return_decision(c)
                }
            }
            VillagerRoutineState::TravelToStation => {
                let Some((sx, sy, wx, wz)) = self.profession_station(c, false) else {
                    Self::set_villager_routine(
                        c,
                        VillagerRoutineState::ReturnHome,
                        VILLAGER_RETURN_SECONDS,
                    );
                    return self.villager_return_decision(c);
                };
                let dx = Self::wrap_signed_f(wx as f32 + 0.5 - c.pos.x);
                let dz = Self::wrap_signed_f(wz as f32 + 0.5 - c.pos.z);
                // The path ends beside a solid station. Accept the worker once its
                // body is within the clear work cell, then snap to the authored pose;
                // a tighter point threshold could time out while skirting the block.
                if dx * dx + dz * dz <= 0.75 * 0.75 {
                    c.pos.x = Self::wrap_pos_f(wx as f32 + 0.5);
                    c.pos.y = sy as f32;
                    c.pos.z = Self::wrap_pos_f(wz as f32 + 0.5);
                    c.vy = 0.0;
                    c.climb = 0.0;
                    let face = Self::wrap_signed_f(sx as f32 + 0.5 - c.pos.x)
                        .atan2(Self::wrap_signed_f(wz as f32 + 0.5 - c.pos.z));
                    c.ai.heading = face;
                    c.ai.speed = 0.0;
                    c.yaw = face;
                    Self::set_villager_routine(
                        c,
                        VillagerRoutineState::Work,
                        VILLAGER_WORK_SECONDS,
                    );
                    return Decision { desired_heading: face, speed_frac: 0.0, path_goal: None };
                }
                if c.routine.timer <= 0.0 {
                    Self::set_villager_routine(
                        c,
                        VillagerRoutineState::ReturnHome,
                        VILLAGER_RETURN_SECONDS,
                    );
                    return self.villager_return_decision(c);
                }
                let (gx, gz) = Self::villager_nearest_goal(c.pos.x, c.pos.z, wx, wz);
                Decision {
                    desired_heading: dx.atan2(dz),
                    speed_frac: 0.85,
                    path_goal: Some((gx, gz)),
                }
            }
            VillagerRoutineState::Work => {
                let Some((sx, sy, wx, wz)) = self.profession_station(c, false) else {
                    Self::set_villager_routine(
                        c,
                        VillagerRoutineState::ReturnHome,
                        VILLAGER_RETURN_SECONDS,
                    );
                    return self.villager_return_decision(c);
                };
                if c.routine.timer <= 0.0 {
                    Self::set_villager_routine(
                        c,
                        VillagerRoutineState::ReturnHome,
                        VILLAGER_RETURN_SECONDS,
                    );
                    return self.villager_return_decision(c);
                }
                c.pos.x = Self::wrap_pos_f(wx as f32 + 0.5);
                c.pos.y = sy as f32;
                c.pos.z = Self::wrap_pos_f(wz as f32 + 0.5);
                c.vy = 0.0;
                c.climb = 0.0;
                let face = Self::wrap_signed_f(sx as f32 + 0.5 - c.pos.x)
                    .atan2(Self::wrap_signed_f(wz as f32 + 0.5 - c.pos.z));
                c.ai.heading = face;
                c.ai.speed = 0.0;
                Decision { desired_heading: face, speed_frac: 0.0, path_goal: None }
            }
            VillagerRoutineState::ReturnHome => self.villager_return_decision(c),
        }
    }

    fn villager_routine_path_failed(c: &mut Creature) {
        match c.routine.state {
            VillagerRoutineState::TravelToStation => Self::set_villager_routine(
                c,
                VillagerRoutineState::ReturnHome,
                VILLAGER_RETURN_SECONDS,
            ),
            VillagerRoutineState::ReturnHome => Self::set_villager_routine(
                c,
                VillagerRoutineState::Idle,
                VILLAGER_IDLE_SECONDS,
            ),
            _ => {}
        }
    }

    pub(super) fn update_creatures(&mut self, dt: f32) {
        // A completed fortress is a hard sanctuary invariant, not merely a wall
        // the pathfinder is expected to respect. Cull any hostile introduced by
        // an old save, debug spawn, or streaming race before it can act inside.
        let fortresses: Vec<(i32, i32)> = self
            .villages
            .iter()
            .filter_map(|(&anchor, state)| state.fortified.then_some(anchor))
            .collect();
        self.creatures.retain(|c| {
            !c.hostile
                || !fortresses.iter().any(|&(ax, az)| {
                    let dx = Self::wrap_signed_block(Self::ifloor(c.pos.x) - ax);
                    let dz = Self::wrap_signed_block(Self::ifloor(c.pos.z) - az);
                    dx.abs() < Self::FORTRESS_R && dz.abs() < Self::FORTRESS_R
                })
        });
        // Smooth step-up tuning. A creature blocked by a ledge it can stand on climbs
        // its Y up at CLIMB_SPEED blocks/sec (a clamber that reads over a few ticks at
        // the usual ~0.05s dt) instead of teleporting up a whole block. MAX_CLIMB caps
        // how tall a step it will attempt; anything taller stays blocked so the AI
        // turns and goes around, exactly as before this change.
        const CLIMB_SPEED: f32 = 3.0;
        const MAX_CLIMB: i32 = 2;
        let n = self.creatures.len();
        // Damage is queued by index so guards can inspect the stable creature roster
        // during AI, then resolve hits after every creature has written its snapshot.
        let mut guard_damage = vec![0i32; n];
        for i in 0..n {
            // Snapshot the fields we need for read-only logic, then write back.
            let mut c = self.creatures[i].clone();
            c.wander -= dt;
            if c.hit_flash > 0.0 {
                c.hit_flash -= dt;
            }
            // #179: nearest-image delta so AI seeks/flees across the world seam.
            let to_player = V3::new(
                Self::wrap_signed_f(self.pos.x - c.pos.x),
                self.pos.y - c.pos.y,
                Self::wrap_signed_f(self.pos.z - c.pos.z),
            );
            // Player position expressed in the creature's frame (may be just
            // outside [0, WORLD_PERIOD) when the pair straddles the seam).
            let player_px = c.pos.x + to_player.x;
            let player_pz = c.pos.z + to_player.z;
            let is_smudgeling = c.from_assault && c.name == "smudgeling";
            let home_dx = Self::wrap_signed_f(c.pos.x - c.home_x as f32 - 0.5);
            let home_dz = Self::wrap_signed_f(c.pos.z - c.home_z as f32 - 0.5);
            let home_dist = (home_dx * home_dx + home_dz * home_dz).sqrt();
            let is_hollow = c.from_assault && c.name == "hollow";
            let is_herald = c.from_assault && c.name == "crooked_herald";
            let is_ramlord = c.from_assault && c.name == "dim_ramlord";
            let ward_active = self
                .villages
                .get(&(Self::wrap_block(c.home_x), Self::wrap_block(c.home_z)))
                .map(|v| v.lights >= Self::VILLAGE_WARD_LIGHTS)
                .unwrap_or(false);
            let ward_exposed = is_hollow && home_dist < 12.0 && ward_active;
            let herald_fearing = is_herald && home_dist < 14.0 && ward_active;
            let ramlord_warded = is_ramlord && home_dist < 14.0 && ward_active;
            c.uncanny_cycle = (c.uncanny_cycle + dt) % 2.4;
            let herald_aura = c.from_assault
                && !is_herald
                && self.creatures.iter().any(|herald| {
                    if herald.name != "crooked_herald"
                        || !herald.from_assault
                        || herald.home_x != c.home_x
                        || herald.home_z != c.home_z
                    {
                        return false;
                    }
                    let dx = Self::wrap_signed_f(herald.pos.x - c.pos.x);
                    let dz = Self::wrap_signed_f(herald.pos.z - c.pos.z);
                    dx * dx + dz * dz <= 10.0 * 10.0
                });
            let captain_aura = c.from_assault
                && !is_ramlord
                && self.creatures.iter().any(|captain| {
                    if captain.name != "dim_ramlord"
                        || !captain.from_assault
                        || captain.home_x != c.home_x
                        || captain.home_z != c.home_z
                    {
                        return false;
                    }
                    let dx = Self::wrap_signed_f(captain.pos.x - c.pos.x);
                    let dz = Self::wrap_signed_f(captain.pos.z - c.pos.z);
                    dx * dx + dz * dz <= 14.0 * 14.0
                });
            if ward_exposed {
                c.light_exposure += dt;
                if c.light_exposure >= 2.0 {
                    c.light_exposure -= 2.0;
                    c.hp -= 1;
                    c.hit_flash = 0.22;
                    self.fx(
                        8,
                        IVec3 {
                            x: Self::ifloor(c.pos.x),
                            y: Self::ifloor(c.pos.y + c.scale * 0.5),
                            z: Self::ifloor(c.pos.z),
                        },
                        0,
                    );
                }
            } else {
                c.light_exposure = 0.0;
            }
            if is_herald {
                c.light_exposure = if herald_fearing {
                    (c.light_exposure + dt).min(1.0)
                } else {
                    0.0
                };
            }
            if ramlord_warded {
                c.light_exposure += dt;
                if c.light_exposure >= 2.0 {
                    c.light_exposure -= 2.0;
                    c.hp -= 2;
                    c.hit_flash = 0.22;
                }
            } else if is_ramlord {
                c.light_exposure = 0.0;
            }

            // Smudgelings hesitate at a live perimeter light, snatch one ward
            // charge, then bolt away with it. The authored pause/recoil makes light
            // visibly matter without allowing an AI creature to grief placed blocks.
            if is_smudgeling && c.assault_goal_is_light && !c.carrying_light {
                let gx = c.pos.x
                    + Self::wrap_signed_f(c.assault_goal.x as f32 + 0.5 - c.pos.x);
                let gz = c.pos.z
                    + Self::wrap_signed_f(c.assault_goal.z as f32 + 0.5 - c.pos.z);
                let dx = gx - c.pos.x;
                let dz = gz - c.pos.z;
                let dist = (dx * dx + dz * dz).sqrt();
                if dist < 4.0 {
                    c.atk_cd = (c.atk_cd - dt).max(0.0);
                }
                if dist < 2.2 && c.atk_cd <= 0.0 {
                    let key = (Self::wrap_block(c.home_x), Self::wrap_block(c.home_z));
                    if let Some(state) = self.villages.get_mut(&key) {
                        if state.lights > 0 {
                            state.lights -= 1;
                            let stolen_at = c.assault_goal;
                            c.carrying_light = true;
                            c.assault_goal.y = NO_FLOOR;
                            self.fx(8, stolen_at, 0);
                            self.toast("A Smudgeling stole a village ward-light — catch it!");
                        }
                    }
                }
            }
            if is_smudgeling
                && !c.assault_goal_is_light
                && c.assault_goal.y != NO_FLOOR
            {
                let gx = c.pos.x
                    + Self::wrap_signed_f(c.assault_goal.x as f32 + 0.5 - c.pos.x);
                let gz = c.pos.z
                    + Self::wrap_signed_f(c.assault_goal.z as f32 + 0.5 - c.pos.z);
                let dist = ((gx - c.pos.x).powi(2) + (gz - c.pos.z).powi(2)).sqrt();
                if dist < 2.2 {
                    c.atk_cd = (c.atk_cd - dt).max(0.0);
                    if c.atk_cd <= 0.0 {
                        self.fx(8, c.assault_goal, 0);
                        c.atk_cd = 0.75;
                    }
                }
            }
            if is_ramlord && c.assault_goal.y != NO_FLOOR {
                let gx = c.pos.x
                    + Self::wrap_signed_f(c.assault_goal.x as f32 + 0.5 - c.pos.x);
                let gz = c.pos.z
                    + Self::wrap_signed_f(c.assault_goal.z as f32 + 0.5 - c.pos.z);
                let dist = ((gx - c.pos.x).powi(2) + (gz - c.pos.z).powi(2)).sqrt();
                if dist < 3.5 {
                    c.siege_charge += dt;
                    if c.siege_charge >= 3.0 {
                        c.siege_charge = 0.0;
                        let key = (Self::wrap_block(c.home_x), Self::wrap_block(c.home_z));
                        let drained = self.villages.get_mut(&key).map(|state| {
                            let before = state.lights;
                            state.lights = state.lights.saturating_sub(2);
                            before - state.lights
                        });
                        self.fx(8, c.assault_goal, 0);
                        if drained.unwrap_or(0) > 0 {
                            self.toast("The Dim Ramlord cracks two charges from the village ward!");
                        }
                    }
                } else {
                    c.siege_charge = 0.0;
                }
            }
            // Assault creatures press toward the settlement, not wherever the player
            // happens to stand inside it. This also makes Hard Creative a useful,
            // harmless observation mode for the complete approach behavior.
            let (ppx, ppz) = if herald_fearing {
                let len = home_dist.max(0.001);
                (c.pos.x + home_dx / len * 10.0, c.pos.z + home_dz / len * 10.0)
            } else if is_smudgeling && c.carrying_light {
                let len = home_dist.max(0.001);
                (c.pos.x + home_dx / len * 12.0, c.pos.z + home_dz / len * 12.0)
            } else if is_smudgeling && c.assault_goal.y != NO_FLOOR {
                let gx = c.pos.x
                    + Self::wrap_signed_f(c.assault_goal.x as f32 + 0.5 - c.pos.x);
                let gz = c.pos.z
                    + Self::wrap_signed_f(c.assault_goal.z as f32 + 0.5 - c.pos.z);
                let dx = gx - c.pos.x;
                let dz = gz - c.pos.z;
                let dist = (dx * dx + dz * dz).sqrt().max(0.001);
                if c.assault_goal_is_light && dist < 4.0 && c.atk_cd > 0.0 {
                    (c.pos.x - dx / dist * 3.0, c.pos.z - dz / dist * 3.0)
                } else {
                    (gx, gz)
                }
            } else if (is_hollow || is_herald || is_ramlord)
                && c.assault_goal.y != NO_FLOOR
            {
                (
                    c.pos.x
                        + Self::wrap_signed_f(c.assault_goal.x as f32 + 0.5 - c.pos.x),
                    c.pos.z
                        + Self::wrap_signed_f(c.assault_goal.z as f32 + 0.5 - c.pos.z),
                )
            } else if c.from_assault {
                (
                    c.pos.x + Self::wrap_signed_f(c.home_x as f32 + 0.5 - c.pos.x),
                    c.pos.z + Self::wrap_signed_f(c.home_z as f32 + 0.5 - c.pos.z),
                )
            } else {
                (player_px, player_pz)
            };
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
                c.pos = Self::wrap_v3_xz(c.pos);
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
            let pursuit_xzd = ((ppx - c.pos.x).powi(2) + (ppz - c.pos.z).powi(2)).sqrt();
            let aggressive = c.hostile || c.provoked;
            let temper = if c.wander > 900.0 {
                // Scripted straight-walker (set by debug_spawn_creature_at for the
                // deterministic locomotion/climb tests): ignore the player, walk on.
                cai::Temperament::Scripted
            } else if aggressive {
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
            // Aggressive creatures only seek/attack in survival; outside it they amble.
            let hunting = aggressive && self.mode == bf_game_mode::BF_MODE_SURVIVAL;
            let observing_assault = c.from_assault
                && self.mode == bf_game_mode::BF_MODE_CREATIVE
                && self.difficulty == 2;
            let pursuing = hunting || observing_assault;
            let eff_temper = if aggressive && !pursuing {
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
                    let damage = if is_ramlord {
                        8.0
                    } else if is_herald {
                        5.0
                    } else if is_hollow {
                        1.0 + self.effective_village_tier(c.home_x, c.home_z) as f32
                            + f32::from(herald_aura)
                            + 2.0 * f32::from(captain_aura)
                    } else {
                        2.5 + f32::from(herald_aura) + 2.0 * f32::from(captain_aura)
                    };
                    self.hurt_player(damage);
                    c.atk_cd = 1.1;
                }
            }
            c.guarding = false;
            c.guard_progress = 0.0;
            // Drive the behaviour state machine from the world rng so it stays
            // deterministic with the rest of the sim. The world's rng is the seed.
            c.ai.tick_repath();
            if c.model == 20 {
                if !c.social.initialized {
                    let key = Self::villager_social_key(&c);
                    c.social.cooldown = 0.5 + ((key >> 12) % 6) as f32 * 0.45;
                    c.social.initialized = true;
                } else {
                    c.social.cooldown = (c.social.cooldown - dt).max(0.0);
                }
            }
            let mut seed = self.rng;
            let artisan = c.model == 20 && Self::profession_station_spec(c.npc_id).is_some();
            let dialogue_held = c.model == 20 && c.dialogue_held;
            let tier = if c.model == 20 {
                self.effective_village_tier(c.home_x, c.home_z)
            } else {
                0
            };
            let fortified = c.model == 20 && self.city_is_fortified(c.home_x, c.home_z);
            let assault_target = if c.model == 20 {
                self.creatures
                    .iter()
                    .enumerate()
                    .filter(|(_, target)| {
                        if !target.hostile {
                            return false;
                        }
                        let assigned = target.from_assault
                            && target.home_x == c.home_x
                            && target.home_z == c.home_z;
                        let hdx = Self::wrap_signed_f(target.pos.x - c.home_x as f32);
                        let hdz = Self::wrap_signed_f(target.pos.z - c.home_z as f32);
                        assigned
                            || (fortified
                                && hdx * hdx + hdz * hdz
                                    <= (Self::FORTRESS_R as f32 + 16.0).powi(2))
                    })
                    .min_by(|(_, a), (_, b)| {
                        let adx = Self::wrap_signed_f(a.pos.x - c.pos.x);
                        let adz = Self::wrap_signed_f(a.pos.z - c.pos.z);
                        let bdx = Self::wrap_signed_f(b.pos.x - c.pos.x);
                        let bdz = Self::wrap_signed_f(b.pos.z - c.pos.z);
                        (adx * adx + adz * adz).total_cmp(&(bdx * bdx + bdz * bdz))
                    })
                    .map(|(idx, target)| (idx, target.pos))
            } else {
                None
            };
            let settlement_under_attack = assault_target.is_some();
            let dedicated_guard = c.npc_id == 7;
            let guard_role = dedicated_guard || match tier {
                3.. if fortified => matches!(c.npc_id, 2 | 4 | 5 | 6),
                3.. => matches!(c.npc_id, 2 | 4 | 6),
                2 => matches!(c.npc_id, 2 | 4),
                1 => c.npc_id == 4,
                _ => false,
            };
            let assault_decision = if !dialogue_held {
                assault_target.map(|(target_idx, target_pos)| {
                    let dx = Self::wrap_signed_f(target_pos.x - c.pos.x);
                    let dz = Self::wrap_signed_f(target_pos.z - c.pos.z);
                    let dist = (dx * dx + dz * dz).sqrt();
                    if guard_role && dist <= GUARD_RANGE {
                        let ward_lit = self
                            .villages
                            .get(&(c.home_x, c.home_z))
                            .map(|v| v.lights >= 8)
                            .unwrap_or(false);
                        let cooldown = if fortified {
                            0.8
                        } else {
                            match tier {
                            3.. => 1.2,
                            2 => 1.7,
                            _ => 3.0,
                            }
                        };
                        c.atk_cd = (c.atk_cd - dt).max(0.0);
                        c.guarding = true;
                        c.guard_progress = (1.0 - c.atk_cd / cooldown).clamp(0.0, 1.0);
                        if c.atk_cd <= 0.0 {
                            let damage = tier as i32 + i32::from(ward_lit) + 2 * i32::from(fortified);
                            guard_damage[target_idx] += damage.max(1);
                            c.atk_cd = cooldown;
                            c.guard_progress = 1.0;
                        }
                        cai::Decision {
                            desired_heading: dx.atan2(dz),
                            speed_frac: 0.0,
                            path_goal: None,
                        }
                    } else if guard_role {
                        // Walk to the inside of the threatened wall, then hold it.
                        let adx = Self::wrap_signed_f(target_pos.x - c.home_x as f32);
                        let adz = Self::wrap_signed_f(target_pos.z - c.home_z as f32);
                        let len = (adx * adx + adz * adz).sqrt().max(0.001);
                        let post_r = if fortified {
                            (Self::FORTRESS_R - 3) as f32
                        } else {
                            6.0
                        };
                        cai::Decision {
                            desired_heading: dx.atan2(dz),
                            speed_frac: 0.9,
                            path_goal: Some((
                                Self::wrap_block(c.home_x + (adx / len * post_r).round() as i32),
                                Self::wrap_block(c.home_z + (adz / len * post_r).round() as i32),
                            )),
                        }
                    } else {
                        // Civilians leave work/social time and seek the safe center.
                        let hdx = Self::wrap_signed_f(c.home_x as f32 + 0.5 - c.pos.x);
                        let hdz = Self::wrap_signed_f(c.home_z as f32 + 0.5 - c.pos.z);
                        let home_dist = (hdx * hdx + hdz * hdz).sqrt();
                        cai::Decision {
                            desired_heading: hdx.atan2(hdz),
                            speed_frac: if home_dist > 2.5 { 0.8 } else { 0.0 },
                            path_goal: if home_dist > 2.5 {
                                Some((c.home_x, c.home_z))
                            } else {
                                None
                            },
                        }
                    }
                })
            } else {
                None
            };
            let night_watch = !dialogue_held
                && assault_target.is_none()
                && fortified
                && guard_role
                && (dedicated_guard || Self::is_night_phase(Self::day_time(self.world_clock)));
            let watch_decision = night_watch.then(|| {
                let r = Self::FORTRESS_R - 3;
                let (ox, oz) = if dedicated_guard {
                    match c.guard_post % 4 {
                        0 => (0, -r),
                        1 => (r, 0),
                        2 => (0, r),
                        _ => (-r, 0),
                    }
                } else {
                    match c.npc_id {
                        4 => (0, -r),
                        5 => (r, 0),
                        6 => (0, r),
                        _ => (-r, 0),
                    }
                };
                let gx = Self::wrap_block(c.home_x + ox);
                let gz = Self::wrap_block(c.home_z + oz);
                let dx = Self::wrap_signed_f(gx as f32 + 0.5 - c.pos.x);
                let dz = Self::wrap_signed_f(gz as f32 + 0.5 - c.pos.z);
                let dist = (dx * dx + dz * dz).sqrt();
                cai::Decision {
                    desired_heading: dx.atan2(dz),
                    speed_frac: if dist > 2.0 { 0.75 } else { 0.0 },
                    path_goal: (dist > 2.0).then_some((gx, gz)),
                }
            });
            let settlement_defense_active = settlement_under_attack || night_watch;
            let tether_decision = if !dialogue_held
                && !settlement_defense_active
                && c.model == 20
                && (!artisan || c.routine.state == VillagerRoutineState::Idle)
            {
                self.villager_tether_decision(&c)
            } else {
                None
            };
            let social_allowed = !dialogue_held
                && !settlement_defense_active
                && c.model == 20
                && tether_decision.is_none()
                && Self::villager_social_window(&c);
            if !social_allowed && c.social.action != 0 {
                Self::finish_villager_social(&mut c);
            }
            let social_decision = if social_allowed {
                self.villager_social_decision(&mut c, dt)
            } else {
                None
            };
            if artisan && social_decision.is_some() {
                c.routine.timer -= dt;
            }
            let social_driven = social_decision.is_some();
            let tether_driven = tether_decision.is_some() && !social_driven;
            let routine_driven = artisan
                && !dialogue_held
                && !settlement_defense_active
                && !social_driven
                && !tether_driven;
            let dec = if dialogue_held {
                c.ai.path.clear();
                c.ai.speed = 0.0;
                cai::Decision {
                    desired_heading: (player_px - c.pos.x).atan2(player_pz - c.pos.z),
                    speed_frac: 0.0,
                    path_goal: None,
                }
            } else if let Some(dec) = assault_decision {
                dec
            } else if let Some(dec) = watch_decision {
                dec
            } else if let Some(dec) = social_decision {
                dec
            } else if let Some(dec) = tether_decision {
                dec
            } else if routine_driven {
                self.profession_routine_decision(&mut c, dt)
            } else {
                cai::decide(
                    &mut c.ai,
                    eff_temper,
                    c.pos.x,
                    c.pos.z,
                    ppx,
                    ppz,
                    pursuit_xzd,
                    dt,
                    &mut seed,
                )
            };
            self.rng = seed;
            // Seeking hostiles path around obstacles with throttled, bounded A*.
            let mut desired_heading = dec.desired_heading;
            let mut routine_path_failed = false;
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
                    let dx = goal.0 as f32 + 0.5 - c.pos.x;
                    let dz = goal.1 as f32 + 0.5 - c.pos.z;
                    routine_path_failed = (routine_driven || social_driven || tether_driven)
                        && path.is_empty()
                        && dx * dx + dz * dz > 0.55 * 0.55;
                    c.ai.set_path(path);
                }
                if routine_path_failed {
                    if social_driven {
                        Self::finish_villager_social(&mut c);
                    } else if routine_driven {
                        Self::villager_routine_path_failed(&mut c);
                    } else {
                        c.ai.path.clear();
                    }
                } else if let Some(h) = c.ai.follow_heading(c.pos.x, c.pos.z) {
                    desired_heading = h;
                } else {
                    // Path exhausted but not yet at the goal: steer straight in.
                    desired_heading = (goal.0 as f32 + 0.5 - c.pos.x)
                        .atan2(goal.1 as f32 + 0.5 - c.pos.z);
                }
            } else {
                c.ai.path.clear();
            }
            // Smooth turn + accel toward the decision, then apply the displacement
            // through the existing collision/climb code. step_locomotion never snaps
            // heading or velocity, so creatures rotate and ramp instead of flipping.
            let light_slow = if ramlord_warded {
                0.65
            } else if ward_exposed {
                0.72
            } else {
                1.0
            };
            let aura_speed = if captain_aura {
                1.30
            } else if herald_aura {
                1.18
            } else {
                1.0
            };
            let uncanny_speed = if herald_fearing {
                1.2
            } else if is_herald {
                let phase = c.uncanny_cycle / 2.4;
                if phase < 0.24 {
                    0.0
                } else if phase < 0.46 {
                    1.8
                } else {
                    0.68
                }
            } else {
                1.0
            };
            let target_speed = if routine_path_failed || (is_ramlord && c.siege_charge > 0.0) {
                0.0
            } else {
                c.speed * dec.speed_frac * light_slow * aura_speed * uncanny_speed
            };
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
            // #95 walls keep monsters out: an aggressive creature may not cross into a walled village's
            // protected interior. (The wall blocks itself stop a creature that bumps the
            // line; this is the belt-and-braces guard so it cannot slip through the gate
            // or a worldgen seam into a protected interior.) A creature already
            // somehow inside is free to leave.
            let into_protected = aggressive
                && self.village_protects(nv.x, nv.z).is_some()
                && self
                    .village_protects(Self::ifloor(c.pos.x), Self::ifloor(c.pos.z))
                    .is_none();
            let body_blocked = self.creature_body_blocked(next.x, nv.y, next.z, c.scale);
            if !into_water && !into_protected && !body_blocked {
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
                    // #226: the climb landing must be clear for the whole body too.
                    if !self.creature_body_blocked(next.x, nv.y + h, next.z, c.scale) {
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
                } else if self.creature_body_blocked(
                    c.pos.x,
                    Self::ifloor(c.pos.y + 0.01),
                    c.pos.z,
                    c.scale,
                ) {
                    // #231: the body is embedded where it already STANDS (spawned or
                    // pushed into a wall), so every heading is blocked forever and the
                    // creature freezes/vibrates. Relocate to the nearest clear cell.
                    let _ = self.creature_unstick(&mut c);
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
            // #179: keep the stored position canonical on the torus.
            c.pos = Self::wrap_v3_xz(c.pos);
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

        // Resolve guard ward-strikes after the snapshot loop. AI kills intentionally
        // grant no player loot/quest credit; the settlement defended itself.
        let mut guard_fx = Vec::new();
        let mut recovered_lights = Vec::new();
        for (i, damage) in guard_damage.into_iter().enumerate() {
            if damage <= 0 || i >= self.creatures.len() || !self.creatures[i].from_assault {
                continue;
            }
            let target = &mut self.creatures[i];
            target.hp -= damage;
            target.hit_flash = 0.22;
            if target.hp <= 0 && target.carrying_light {
                recovered_lights.push((target.home_x, target.home_z));
            }
            guard_fx.push(IVec3 {
                x: Self::ifloor(target.pos.x),
                y: Self::ifloor(target.pos.y + target.scale * 0.5),
                z: Self::ifloor(target.pos.z),
            });
        }
        self.creatures.retain(|c| c.hp > 0);
        let mut recovered = false;
        for (ax, az) in recovered_lights {
            recovered |= self.return_stolen_village_light(ax, az);
        }
        if recovered {
            self.toast("The guards recovered a stolen village ward-light.");
        }
        for p in guard_fx {
            self.fx(8, p, 0);
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
                let dx = Self::wrap_signed_f(bx0 - ax0);
                let dz = Self::wrap_signed_f(bz0 - az0);
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
                    self.creatures[i].pos.x = Self::wrap_pos_f(ax);
                    self.creatures[i].pos.z = Self::wrap_pos_f(az);
                }
                if !self.collide_solid(Self::ifloor(bx), Self::ifloor(by0), Self::ifloor(bz)) {
                    self.creatures[j].pos.x = Self::wrap_pos_f(bx);
                    self.creatures[j].pos.z = Self::wrap_pos_f(bz);
                }
            }
        }
        // ---- collision: keep non-aggressive creatures out of the player's space ----
        let px = self.pos.x;
        let pz = self.pos.z;
        let survival = self.mode == bf_game_mode::BF_MODE_SURVIVAL;
        for i in 0..self.creatures.len() {
            let (cx0, cz0, cy0, cscale, aquatic, aggressive) = {
                let c = &self.creatures[i];
                (
                    c.pos.x,
                    c.pos.z,
                    c.pos.y,
                    c.scale,
                    c.aquatic,
                    c.hostile || c.provoked,
                )
            };
            if aquatic {
                continue;
            }
            if aggressive && survival {
                continue;
            }
            let dx = Self::wrap_signed_f(cx0 - px);
            let dz = Self::wrap_signed_f(cz0 - pz);
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
                self.creatures[i].pos.x = Self::wrap_pos_f(cx);
                self.creatures[i].pos.z = Self::wrap_pos_f(cz);
            }
        }
    }
}

#[cfg(test)]
mod profession_station_tests {
    use super::*;

    fn villager(role: i32, x: f32, z: f32, home: (i32, i32)) -> Creature {
        let mut c = Creature::default();
        c.model = 20;
        c.npc_id = role;
        c.home_x = home.0;
        c.home_z = home.1;
        c.pos = V3::new(x, 8.0, z);
        c
    }

    #[test]
    fn artisan_roles_select_their_canonical_physical_station() {
        assert_eq!(World::<'static>::profession_station_spec(2), Some((6, 6, 61)));
        assert_eq!(World::<'static>::profession_station_spec(3), Some((4, -4, 60)));
        assert_eq!(World::<'static>::profession_station_spec(4), Some((4, 4, 56)));
        assert_eq!(World::<'static>::profession_station_spec(5), Some((-4, 4, 58)));
        assert_eq!(World::<'static>::profession_station_spec(6), Some((-4, -4, 59)));
        assert_eq!(World::<'static>::profession_station_spec(1), None);
        assert_eq!(World::<'static>::profession_station_spec(7), None);
    }

    #[test]
    fn social_identity_pairing_is_stable_mutual_home_and_radius_bounded() {
        let mut world = World::new(None);
        world.creatures = vec![
            villager(1, 8.5, 8.5, (8, 8)),
            villager(2, 9.5, 8.5, (8, 8)),
            villager(3, 10.5, 8.5, (8, 8)),
            villager(4, 11.5, 8.5, (8, 8)),
            villager(5, 40.5, 40.5, (8, 8)),
            villager(6, 9.5, 9.5, (9, 9)),
        ];
        let keys: std::collections::HashSet<_> = world.creatures[..4]
            .iter()
            .map(World::villager_social_key)
            .collect();
        assert_eq!(keys.len(), 4);
        for i in 0..4 {
            let partner = world.villager_social_pair_index(&world.creatures[i]).unwrap();
            assert!(partner < 4 && partner != i);
            assert_eq!(
                world.villager_social_pair_index(&world.creatures[partner]),
                Some(i)
            );
        }
        assert!(world.villager_social_pair_index(&world.creatures[4]).is_none());
        assert!(world.villager_social_pair_index(&world.creatures[5]).is_none());

        // Caller-relative filtering made both ends of this A-B-C chain claim B.
        // All three are inside the shared home radius but the ends are not inside
        // each other's radius, so only a home-derived roster pairs them mutually.
        world.creatures = vec![
            villager(1, -3.0, 8.5, (8, 8)),
            villager(2, 8.5, 8.5, (8, 8)),
            villager(3, 20.0, 8.5, (8, 8)),
        ];
        for i in 0..world.creatures.len() {
            if let Some(partner) = world.villager_social_pair_index(&world.creatures[i]) {
                assert_eq!(
                    world.villager_social_pair_index(&world.creatures[partner]),
                    Some(i),
                    "chain member {i} selected a non-mutual partner"
                );
            }
        }
    }

    #[test]
    fn social_sequence_covers_every_additive_pose_deterministically() {
        let c = villager(1, 8.5, 8.5, (8, 8));
        let key = World::villager_social_key(&c);
        let actions: std::collections::HashSet<_> = (0..6)
            .map(|seq| World::villager_social_action(key, seq))
            .collect();
        assert_eq!(actions, (5..=10).collect());
    }

    #[test]
    fn pair_chat_faces_and_pauses_then_breaks_when_partner_disappears() {
        let mut world = World::new(None);
        let mut a = villager(1, 8.5, 8.5, (8, 8));
        let mut b = villager(2, 10.0, 8.5, (8, 8));
        let ak = World::villager_social_key(&a);
        let bk = World::villager_social_key(&b);
        World::set_villager_social(&mut a, SOCIAL_CHAT, 3.0, NO_FLOOR, bk, false);
        World::set_villager_social(&mut b, SOCIAL_CHAT, 3.0, NO_FLOOR, ak, false);
        world.creatures = vec![a.clone(), b];
        let dec = world.villager_social_decision(&mut a, 0.1).unwrap();
        assert!(a.social.arrived && world.creatures[1].social.arrived);
        assert_eq!(dec.speed_frac, 0.0);
        assert!(dec.path_goal.is_none() && a.social.timer < 3.0);
        world.creatures[1].pos.x = 40.5;
        let _ = world.villager_social_decision(&mut a, 0.1);
        assert_eq!(a.social.action, 0, "moving outside home range cancels chat safely");

        World::set_villager_social(&mut a, SOCIAL_CHAT, 3.0, NO_FLOOR, bk, false);
        world.creatures.pop();
        let _ = world.villager_social_decision(&mut a, 0.1);
        assert_eq!(a.social.action, 0, "despawn cancels pair chat safely");
    }

    #[test]
    fn social_idle_window_hands_an_artisan_back_to_their_shift() {
        let mut world = World::new(None);
        world.generate_test_world();
        world.pos = V3::new(0.5, 12.0, 0.5);
        world.set_block_internal(IVec3 { x: 12, y: 8, z: 12 }, 56);
        let mut c = villager(4, 8.5, 8.5, (8, 8));
        c.routine.timer = 0.01;
        c.social.initialized = true;
        World::set_villager_social(&mut c, SOCIAL_LOOK, 5.0, NO_FLOOR, 0, true);
        world.creatures.push(c);
        world.update_creatures(0.05);
        assert_eq!(world.creatures[0].routine.state, VillagerRoutineState::Idle);
        world.update_creatures(0.05);
        assert_eq!(world.creatures[0].social.action, 0, "due shift cancels social time");
        assert_eq!(
            world.creatures[0].routine.state,
            VillagerRoutineState::TravelToStation
        );
    }
}
