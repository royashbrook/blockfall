use super::*;

const ROAD_GRAVEL: BlockId = 11;
const ROAD_COBBLE: BlockId = 10;
const ROAD_BOARDWALK: BlockId = 4;
const SETTLEMENT_CORE_R: i32 = 8;
const SETTLEMENT_GATE_R: i32 = 9;
const SETTLEMENT_ROUTE_ZONE_R: i32 = 56;
const CARAVAN_FP: u32 = 256;
const CARAVAN_SPEED_FP: u64 = 384; // 1.5 road cells / second
const CARAVAN_TIME_HZ: u64 = 1_000_000;
const CARAVAN_ACTIVE_RADIUS: f32 = 128.0;
const CARAVAN_STOCK_BATCH: u8 = 3;
const CARAVAN_STOCK_MAX: u8 = 12;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct RoadRoute {
    settlement_from: Option<(i32, i32)>,
    settlement_to: Option<(i32, i32)>,
    from: (i32, i32),
    via: (i32, i32),
    to: (i32, i32),
    tier: u8,
    profile: Vec<i32>,
    caravan_progress: u32,
    caravan_time_remainder: u32,
    caravan_forward: bool,
    stock_from: u8,
    stock_to: u8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct CaravanRouteState {
    pub(super) from: (i32, i32),
    pub(super) to: (i32, i32),
    pub(super) progress: u32,
    pub(super) time_remainder: u32,
    pub(super) forward: bool,
    pub(super) stock_from: u8,
    pub(super) stock_to: u8,
}

fn round_div(n: i64, d: i64) -> i32 {
    debug_assert!(d > 0);
    if n >= 0 {
        ((n + d / 2) / d) as i32
    } else {
        ((n - d / 2) / d) as i32
    }
}

fn nearest_delta(d: i32) -> i32 {
    let w = worldgen::WORLD_PERIOD;
    (d + w / 2).rem_euclid(w) - w / 2
}

fn endpoint_distance(wx: i32, wz: i32, endpoint: (i32, i32)) -> i32 {
    nearest_delta(wx - endpoint.0)
        .abs()
        .max(nearest_delta(wz - endpoint.1).abs())
}

fn protected_structure_for_route(wx: i32, wz: i32, endpoints: [(i32, i32); 2], seed: u64) -> bool {
    let endpoint_d =
        endpoint_distance(wx, wz, endpoints[0]).min(endpoint_distance(wx, wz, endpoints[1]));
    if endpoint_d <= SETTLEMENT_CORE_R {
        return true;
    }
    // The legacy footprint query reserves a 51-block square for every structure.
    // Exempt each route's own endpoint settlement zone so its gate connection is not
    // erased; conservative block checks still protect actual buildings in that zone.
    endpoint_d > SETTLEMENT_ROUTE_ZONE_R && worldgen::worldgen_structure_footprint(wx, wz, seed)
}

fn raster_point(a: (i32, i32), b: (i32, i32), i: i32) -> (i32, i32) {
    let dx = b.0 - a.0;
    let dz = b.1 - a.1;
    let steps = dx.abs().max(dz.abs()).max(1);
    (
        a.0 + round_div(dx as i64 * i as i64, steps as i64),
        a.1 + round_div(dz as i64 * i as i64, steps as i64),
    )
}

fn visit_segment(mut f: impl FnMut(i32, i32), a: (i32, i32), b: (i32, i32)) {
    let steps = (b.0 - a.0).abs().max((b.1 - a.1).abs());
    for i in 0..=steps {
        let (x, z) = raster_point(a, b, i);
        f(x, z);
    }
}

fn centerline_index(p: (i32, i32), a: (i32, i32), b: (i32, i32)) -> Option<usize> {
    let dx = b.0 - a.0;
    let dz = b.1 - a.1;
    let steps = dx.abs().max(dz.abs());
    if steps == 0 {
        return (p == a).then_some(0);
    }
    let i = if dx.abs() >= dz.abs() {
        (p.0 - a.0) * dx.signum()
    } else {
        (p.1 - a.1) * dz.signum()
    };
    (i >= 0 && i <= steps && raster_point(a, b, i) == p).then_some(i as usize)
}

fn segment_score(a: (i32, i32), b: (i32, i32), endpoints: [(i32, i32); 2], seed: u64) -> i64 {
    const SAMPLES: i32 = 24;
    let mut score = 0i64;
    let mut previous = worldgen::worldgen_road_surface(a.0, a.1, seed).0;
    for i in 1..=SAMPLES {
        let x = a.0 + round_div((b.0 - a.0) as i64 * i as i64, SAMPLES as i64);
        let z = a.1 + round_div((b.1 - a.1) as i64 * i as i64, SAMPLES as i64);
        let (y, wet) = worldgen::worldgen_road_surface(x, z, seed);
        let climb = (y - previous).abs() as i64;
        score += climb * climb * 12 + climb.saturating_sub(2) * 40;
        if wet {
            score += 20;
        }
        previous = y;
    }
    // Structures are protected during application. Make paths strongly prefer a
    // candidate that does not run through one. Eight-block sampling cannot jump the
    // deliberately broad procedural footprint reserve.
    let steps = (b.0 - a.0).abs().max((b.1 - a.1).abs());
    for i in (0..=steps).step_by(8) {
        let (x, z) = raster_point(a, b, i);
        if protected_structure_for_route(x, z, endpoints, seed) {
            score += 1_000_000;
        }
    }
    if steps % 8 != 0 && protected_structure_for_route(b.0, b.1, endpoints, seed) {
        score += 1_000_000;
    }
    score
}

impl RoadRoute {
    fn new(from: (i32, i32), target: (i32, i32), tier: u8, seed: u64) -> Self {
        let settlement_to = (
            from.0 + nearest_delta(target.0 - from.0),
            from.1 + nearest_delta(target.1 - from.1),
        );
        let settlement_dx = settlement_to.0 - from.0;
        let settlement_dz = settlement_to.1 - from.1;
        let (start, to) = if settlement_dx.abs() >= settlement_dz.abs() {
            let direction = settlement_dx.signum();
            (
                (from.0 + direction * SETTLEMENT_GATE_R, from.1),
                (
                    settlement_to.0 - direction * SETTLEMENT_GATE_R,
                    settlement_to.1,
                ),
            )
        } else {
            let direction = settlement_dz.signum();
            (
                (from.0, from.1 + direction * SETTLEMENT_GATE_R),
                (
                    settlement_to.0,
                    settlement_to.1 - direction * SETTLEMENT_GATE_R,
                ),
            )
        };
        let endpoints = [from, settlement_to];
        let dx = to.0 - start.0;
        let dz = to.1 - start.1;
        let span = dx.abs().max(dz.abs()).max(1);
        let midpoint = (start.0 + dx / 2, start.1 + dz / 2);
        let bend = (span / 8).clamp(16, 64);
        let mut best = midpoint;
        let mut best_score = i64::MAX;

        // Five fixed candidates keep routing deterministic and bounded while still
        // allowing a road to bend around steep or wet terrain. No A* frontier and no
        // offscreen terrain edits are needed.
        for multiple in [0i32, -1, 1, -2, 2] {
            let offset = bend * multiple;
            let via = (
                midpoint.0 + round_div(-(dz as i64) * offset as i64, span as i64),
                midpoint.1 + round_div(dx as i64 * offset as i64, span as i64),
            );
            let score = segment_score(start, via, endpoints, seed)
                + segment_score(via, to, endpoints, seed)
                + (offset.abs() as i64) * 4;
            if score < best_score {
                best_score = score;
                best = via;
            }
        }

        Self::from_geometry_anchored(start, best, to, tier, seed, Some(endpoints))
    }

    #[cfg(test)]
    fn from_geometry(
        from: (i32, i32),
        via: (i32, i32),
        to: (i32, i32),
        tier: u8,
        seed: u64,
    ) -> Self {
        Self::from_geometry_anchored(from, via, to, tier, seed, None)
    }

    fn from_geometry_anchored(
        from: (i32, i32),
        via: (i32, i32),
        to: (i32, i32),
        tier: u8,
        seed: u64,
        settlements: Option<[(i32, i32); 2]>,
    ) -> Self {
        let first_steps = (via.0 - from.0).abs().max((via.1 - from.1).abs());
        let second_steps = (to.0 - via.0).abs().max((to.1 - via.1).abs());
        let mut profile = Vec::with_capacity((first_steps + second_steps + 1) as usize);
        for i in 0..=first_steps {
            let (x, z) = raster_point(from, via, i);
            profile.push(worldgen::worldgen_road_surface(x, z, seed).0);
        }
        for i in 1..=second_steps {
            let (x, z) = raster_point(via, to, i);
            profile.push(worldgen::worldgen_road_surface(x, z, seed).0);
        }

        // Pin both settlement gates, cut only peaks that cannot be approached at a
        // one-block grade, then raise valleys just enough to make the whole profile
        // 1-Lipschitz. This is the smallest deterministic cut/fill profile that keeps
        // both road ends visibly attached to their local gate streets.
        if profile.len() > 1 {
            let start_y = profile[0];
            let end_y = *profile.last().unwrap();
            let last = profile.len() - 1;
            for (i, y) in profile.iter_mut().enumerate() {
                *y = (*y).min(start_y + i as i32).min(end_y + (last - i) as i32);
            }
        }
        for i in 1..profile.len() {
            profile[i] = profile[i].max(profile[i - 1] - 1);
        }
        for i in (0..profile.len().saturating_sub(1)).rev() {
            profile[i] = profile[i].max(profile[i + 1] - 1);
        }

        Self {
            settlement_from: settlements.map(|s| s[0]),
            settlement_to: settlements.map(|s| s[1]),
            from,
            via,
            to,
            tier: tier.clamp(2, 3),
            profile,
            caravan_progress: 0,
            caravan_time_remainder: 0,
            caravan_forward: true,
            stock_from: CARAVAN_STOCK_BATCH,
            stock_to: CARAVAN_STOCK_BATCH,
        }
    }

    fn route_key(&self) -> Option<((i32, i32), (i32, i32))> {
        let a = self.settlement_from?;
        let b = self.settlement_to?;
        let a = (
            a.0.rem_euclid(worldgen::WORLD_PERIOD),
            a.1.rem_euclid(worldgen::WORLD_PERIOD),
        );
        let b = (
            b.0.rem_euclid(worldgen::WORLD_PERIOD),
            b.1.rem_euclid(worldgen::WORLD_PERIOD),
        );
        Some(if a <= b { (a, b) } else { (b, a) })
    }

    fn caravan_max_progress(&self) -> u32 {
        self.profile.len().saturating_sub(1) as u32 * CARAVAN_FP
    }

    fn caravan_state(&self) -> Option<CaravanRouteState> {
        let (from, to) = self.route_key()?;
        Some(CaravanRouteState {
            from,
            to,
            progress: self.caravan_progress.min(self.caravan_max_progress()),
            time_remainder: self.caravan_time_remainder.min(CARAVAN_TIME_HZ as u32 - 1),
            forward: self.caravan_forward,
            stock_from: self.stock_from.min(CARAVAN_STOCK_MAX),
            stock_to: self.stock_to.min(CARAVAN_STOCK_MAX),
        })
    }

    fn restore_caravan_state(&mut self, state: CaravanRouteState) -> bool {
        if self.route_key() != Some((state.from, state.to)) {
            return false;
        }
        self.caravan_progress = state.progress.min(self.caravan_max_progress());
        self.caravan_time_remainder = state.time_remainder.min(CARAVAN_TIME_HZ as u32 - 1);
        self.caravan_forward = state.forward;
        self.stock_from = state.stock_from.min(CARAVAN_STOCK_MAX);
        self.stock_to = state.stock_to.min(CARAVAN_STOCK_MAX);
        true
    }

    fn advance_caravan(&mut self, dt: f32) {
        let max = self.caravan_max_progress();
        if max == 0 || !dt.is_finite() || dt <= 0.0 {
            return;
        }
        let ticks = (dt.min(0.1) as f64 * CARAVAN_TIME_HZ as f64).round() as u64;
        let scaled = ticks * CARAVAN_SPEED_FP + self.caravan_time_remainder as u64;
        let mut step = (scaled / CARAVAN_TIME_HZ) as u32;
        self.caravan_time_remainder = (scaled % CARAVAN_TIME_HZ) as u32;
        while step > 0 {
            if self.caravan_forward {
                let room = max.saturating_sub(self.caravan_progress);
                if step < room {
                    self.caravan_progress += step;
                    break;
                }
                self.caravan_progress = max;
                step -= room;
                self.caravan_forward = false;
                self.stock_to = self
                    .stock_to
                    .saturating_add(CARAVAN_STOCK_BATCH)
                    .min(CARAVAN_STOCK_MAX);
            } else {
                let room = self.caravan_progress;
                if step < room {
                    self.caravan_progress -= step;
                    break;
                }
                self.caravan_progress = 0;
                step -= room;
                self.caravan_forward = true;
                self.stock_from = self
                    .stock_from
                    .saturating_add(CARAVAN_STOCK_BATCH)
                    .min(CARAVAN_STOCK_MAX);
            }
        }
    }

    /// Interpolated feet position/yaw plus the discrete road cell that must be
    /// resident and intact before the physical caravan may be shown.
    fn caravan_pose(&self) -> Option<(f32, f32, f32, f32, IVec3)> {
        if self.profile.len() < 2 {
            return None;
        }
        let progress = self.caravan_progress.min(self.caravan_max_progress());
        let i = (progress / CARAVAN_FP) as usize;
        let next = (i + 1).min(self.profile.len() - 1);
        let t = (progress % CARAVAN_FP) as f32 / CARAVAN_FP as f32;
        let a = self.profile_point(i)?;
        let b = self.profile_point(next)?;
        let x = a.0 as f32 + 0.5 + (b.0 - a.0) as f32 * t;
        let y = a.2 as f32 + (b.2 - a.2) as f32 * t + 1.0;
        let z = a.1 as f32 + 0.5 + (b.1 - a.1) as f32 * t;
        let heading_i = if self.caravan_forward {
            (i + 1).min(self.profile.len() - 1)
        } else if t > 0.0 {
            i
        } else {
            i.saturating_sub(1)
        };
        let heading = self.profile_point(heading_i)?;
        let mut dx = heading.0 as f32 + 0.5 - x;
        let mut dz = heading.1 as f32 + 0.5 - z;
        if dx.abs() + dz.abs() < 0.001 {
            dx = if self.caravan_forward {
                b.0 - a.0
            } else {
                a.0 - b.0
            } as f32;
            dz = if self.caravan_forward {
                b.1 - a.1
            } else {
                a.1 - b.1
            } as f32;
        }
        let road = if t < 0.5 { a } else { b };
        Some((
            x.rem_euclid(worldgen::WORLD_PERIOD as f32),
            y,
            z.rem_euclid(worldgen::WORLD_PERIOD as f32),
            dx.atan2(dz),
            IVec3 {
                x: road.0.rem_euclid(worldgen::WORLD_PERIOD),
                y: road.2,
                z: road.1.rem_euclid(worldgen::WORLD_PERIOD),
            },
        ))
    }

    fn distance_squared_to(&self, px: f32, pz: f32) -> f32 {
        fn segment_distance_squared(p: (f32, f32), a: (i32, i32), b: (i32, i32)) -> f32 {
            let ax = a.0 as f32;
            let az = a.1 as f32;
            let vx = (b.0 - a.0) as f32;
            let vz = (b.1 - a.1) as f32;
            let len2 = vx * vx + vz * vz;
            let t = if len2 > 0.0 {
                (((p.0 - ax) * vx + (p.1 - az) * vz) / len2).clamp(0.0, 1.0)
            } else {
                0.0
            };
            let dx = p.0 - (ax + vx * t);
            let dz = p.1 - (az + vz * t);
            dx * dx + dz * dz
        }

        let w = worldgen::WORLD_PERIOD as f32;
        let p = (
            self.from.0 as f32 + (px - self.from.0 as f32 + w * 0.5).rem_euclid(w) - w * 0.5,
            self.from.1 as f32 + (pz - self.from.1 as f32 + w * 0.5).rem_euclid(w) - w * 0.5,
        );
        segment_distance_squared(p, self.from, self.via)
            .min(segment_distance_squared(p, self.via, self.to))
    }

    fn centerline_index(&self, p: (i32, i32)) -> Option<usize> {
        let first_steps = (self.via.0 - self.from.0)
            .abs()
            .max((self.via.1 - self.from.1).abs()) as usize;
        centerline_index(p, self.from, self.via)
            .or_else(|| centerline_index(p, self.via, self.to).map(|i| first_steps + i))
    }

    fn profile_point(&self, index: usize) -> Option<(i32, i32, i32)> {
        let first_steps = (self.via.0 - self.from.0)
            .abs()
            .max((self.via.1 - self.from.1).abs()) as usize;
        let (x, z) = if index <= first_steps {
            raster_point(self.from, self.via, index as i32)
        } else {
            raster_point(self.via, self.to, (index - first_steps) as i32)
        };
        Some((x, z, *self.profile.get(index)?))
    }

    fn profile_match_at(&self, wx: i32, wz: i32) -> Option<(i32, i32)> {
        let p = (
            self.from.0 + nearest_delta(wx - self.from.0),
            self.from.1 + nearest_delta(wz - self.from.1),
        );
        let radius = if self.tier >= 3 { 1 } else { 0 };
        let mut best: Option<(i32, usize)> = None;
        for oz in -radius..=radius {
            for ox in -radius..=radius {
                let q = (p.0 + ox, p.1 + oz);
                if let Some(index) = self.centerline_index(q) {
                    let key = (ox * ox + oz * oz, index);
                    if best.map(|old| key < old).unwrap_or(true) {
                        best = Some(key);
                    }
                }
            }
        }
        best.and_then(|(distance, index)| self.profile.get(index).copied().map(|y| (y, distance)))
    }

    fn profile_at(&self, wx: i32, wz: i32) -> Option<i32> {
        self.profile_match_at(wx, wz).map(|(y, _)| y)
    }

    #[cfg(test)]
    fn contains(&self, wx: i32, wz: i32) -> bool {
        self.profile_at(wx, wz).is_some()
    }

    fn protected_at(&self, wx: i32, wz: i32, seed: u64) -> bool {
        match (self.settlement_from, self.settlement_to) {
            (Some(from), Some(to)) => protected_structure_for_route(wx, wz, [from, to], seed),
            _ => worldgen::worldgen_structure_footprint(wx, wz, seed),
        }
    }

    fn may_touch_chunk(&self, cc: ChunkCoord) -> bool {
        let x0_canonical = cc.x * KCHUNK_DIM;
        let z0_canonical = cc.z * KCHUNK_DIM;
        let x0 = self.from.0 + nearest_delta(x0_canonical - self.from.0);
        let z0 = self.from.1 + nearest_delta(z0_canonical - self.from.1);
        let pad = if self.tier >= 3 { 1 } else { 0 };
        let min_x = self.from.0.min(self.via.0).min(self.to.0) - pad;
        let max_x = self.from.0.max(self.via.0).max(self.to.0) + pad;
        let min_z = self.from.1.min(self.via.1).min(self.to.1) - pad;
        let max_z = self.from.1.max(self.via.1).max(self.to.1) + pad;
        x0 <= max_x && x0 + KCHUNK_DIM - 1 >= min_x && z0 <= max_z && z0 + KCHUNK_DIM - 1 >= min_z
    }

    fn affected_chunk_columns(&self, out: &mut HashSet<(i32, i32)>) {
        let radius = if self.tier >= 3 { 1 } else { 0 };
        let mut visit = |x: i32, z: i32| {
            for oz in -radius..=radius {
                for ox in -radius..=radius {
                    out.insert((
                        (x + ox).rem_euclid(worldgen::WORLD_PERIOD) / KCHUNK_DIM,
                        (z + oz).rem_euclid(worldgen::WORLD_PERIOD) / KCHUNK_DIM,
                    ));
                }
            }
        };
        visit_segment(&mut visit, self.from, self.via);
        visit_segment(&mut visit, self.via, self.to);
    }
}

impl<'c> World<'c> {
    pub(super) fn rebuild_road_routes(&mut self) {
        let old_states: Vec<CaravanRouteState> = self
            .road_routes
            .iter()
            .filter_map(RoadRoute::caravan_state)
            .collect();
        let mut developed = std::collections::BTreeMap::<(i32, i32), u8>::new();
        for &anchor in self.villages.keys() {
            let tier = self.effective_village_tier(anchor.0, anchor.1);
            if tier >= 2 {
                developed.insert(anchor, tier);
            }
        }
        // #248 HOME is always a procedural city and therefore complete even
        // though its raw village tier is intentionally not persisted.
        if let Some((_typ, ax, az)) = worldgen::worldgen_city_near(0, 0, 2048, self.seed) {
            developed.insert((ax, az), 3);
        }
        // A discovered procedural city joins the road network without adding a
        // save field: visited anchors already live in map.dat and class is derived.
        for &(ax, az) in &self.visited_villages {
            let tier = self.effective_village_tier(ax, az);
            if tier >= 2 {
                developed.insert((ax, az), tier);
            }
        }

        let mut links = std::collections::BTreeMap::<((i32, i32), (i32, i32)), u8>::new();
        for (from, tier) in developed {
            let Some((_typ, px, pz)) =
                worldgen::worldgen_settlement_partner(from.0, from.1, self.seed)
            else {
                continue;
            };
            let partner = (px, pz);
            let key = if from <= partner {
                (from, partner)
            } else {
                (partner, from)
            };
            links
                .entry(key)
                .and_modify(|old| *old = (*old).max(tier))
                .or_insert(tier);
        }
        let mut routes: Vec<RoadRoute> = links
            .into_iter()
            .map(|((from, to), tier)| RoadRoute::new(from, to, tier, self.seed))
            .collect();
        for route in &mut routes {
            if let Some(key) = route.route_key() {
                if let Some(state) = old_states
                    .iter()
                    .copied()
                    .find(|state| (state.from, state.to) == key)
                {
                    route.restore_caravan_state(state);
                }
            }
        }
        self.road_routes = routes;
    }

    pub(super) fn caravan_route_states(&self) -> Vec<CaravanRouteState> {
        self.road_routes
            .iter()
            .filter_map(RoadRoute::caravan_state)
            .collect()
    }

    pub(super) fn restore_caravan_route_state(&mut self, state: CaravanRouteState) {
        if let Some(route) = self
            .road_routes
            .iter_mut()
            .find(|route| route.route_key() == Some((state.from, state.to)))
        {
            route.restore_caravan_state(state);
        }
    }

    fn caravan_road_intact(&self, route: &RoadRoute, road: IVec3) -> bool {
        let cc = Self::to_chunk(road);
        if !self.store.is_resident(cc) {
            return false;
        }
        // Crossings use the strongest overlapping route, matching chunk
        // generation. A tier-2 caravan must accept tier-3 cobble under its wheels.
        let expected = self.debug_road_material_at(road.x, road.z);
        let actual = self.block_at(road);
        let endpoint_gate = [0, route.profile.len().saturating_sub(1)]
            .into_iter()
            .filter_map(|index| route.profile_point(index))
            .any(|(x, z, y)| {
                x.rem_euclid(worldgen::WORLD_PERIOD) == road.x
                    && z.rem_euclid(worldgen::WORLD_PERIOD) == road.z
                    && y == road.y
            });
        (expected != AIR && actual == expected)
            // Finished settlement gates use stone brick beneath the road
            // centerline. The exact gate cell remains valid when an unrelated
            // edit makes its containing chunk persistent.
            || (endpoint_gate && actual == BRICK)
    }

    fn nearby_route_index(&self) -> Option<usize> {
        let mut best: Option<(f32, usize)> = None;
        for (index, route) in self.road_routes.iter().enumerate() {
            let d2 = route.distance_squared_to(self.pos.x, self.pos.z);
            if d2 > CARAVAN_ACTIVE_RADIUS * CARAVAN_ACTIVE_RADIUS {
                continue;
            }
            if best
                .map(|old| d2.total_cmp(&old.0).then(index.cmp(&old.1)).is_lt())
                .unwrap_or(true)
            {
                best = Some((d2, index));
            }
        }
        best.map(|(_, index)| index)
    }

    fn visible_caravan_index(&self) -> Option<usize> {
        let index = self.nearby_route_index()?;
        let route = &self.road_routes[index];
        let (x, _y, z, _yaw, road) = route.caravan_pose()?;
        let dx = Self::wrap_signed_f(x - self.pos.x);
        let dz = Self::wrap_signed_f(z - self.pos.z);
        let d2 = dx * dx + dz * dz;
        (d2 <= CARAVAN_ACTIVE_RADIUS * CARAVAN_ACTIVE_RADIUS
            && self.caravan_road_intact(route, road))
        .then_some(index)
    }

    pub(super) fn update_route_caravan(&mut self, dt: f32) {
        if let Some(index) = self.nearby_route_index() {
            self.road_routes[index].advance_caravan(dt);
        }
    }

    pub(super) fn caravan_draw(&self, cam_pos: V3) -> Option<bf_entity_draw> {
        let route = self.road_routes.get(self.visible_caravan_index()?)?;
        let (x, y, z, yaw, road) = route.caravan_pose()?;
        Some(bf_entity_draw {
            position: bf_vec3 {
                x: cam_pos.x + Self::wrap_signed_f(x - cam_pos.x),
                y,
                z: cam_pos.z + Self::wrap_signed_f(z - cam_pos.z),
            },
            yaw,
            color: bf_vec3 {
                x: 0.82,
                y: 0.64,
                z: 0.42,
            },
            scale: 1.0,
            kind: 27,
            sat: self.region_sat(Self::to_chunk(road)),
            _pad: 0,
        })
    }

    fn caravan_stock_endpoint_near_player(&self) -> Option<(i32, i32)> {
        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);
        let mut best: Option<(i64, i32, i32)> = None;
        for route in &self.road_routes {
            let Some(state) = route.caravan_state() else {
                continue;
            };
            for endpoint in [state.from, state.to] {
                let dx = Self::wrap_signed_block(endpoint.0 - px) as i64;
                let dz = Self::wrap_signed_block(endpoint.1 - pz) as i64;
                let d2 = dx * dx + dz * dz;
                if d2 > 64 * 64 {
                    continue;
                }
                let key = (d2, endpoint.0, endpoint.1);
                if best.map(|old| key < old).unwrap_or(true) {
                    best = Some(key);
                }
            }
        }
        best.map(|(_, x, z)| (x, z))
    }

    pub(super) fn caravan_coin_stock_available(&self) -> Option<bool> {
        let endpoint = self.caravan_stock_endpoint_near_player()?;
        Some(self.road_routes.iter().any(|route| {
            route
                .route_key()
                .map(|(from, to)| {
                    (from == endpoint && route.stock_from > 0)
                        || (to == endpoint && route.stock_to > 0)
                })
                .unwrap_or(false)
        }))
    }

    pub(super) fn consume_caravan_coin_stock(&mut self) -> bool {
        let Some(endpoint) = self.caravan_stock_endpoint_near_player() else {
            return true;
        };
        for route in &mut self.road_routes {
            let Some((from, to)) = route.route_key() else {
                continue;
            };
            let stock = if from == endpoint {
                &mut route.stock_from
            } else if to == endpoint {
                &mut route.stock_to
            } else {
                continue;
            };
            if *stock > 0 {
                *stock -= 1;
                return true;
            }
        }
        false
    }

    pub fn debug_caravan_state(&self, route: usize) -> Option<(u32, bool, u8, u8)> {
        let route = self.road_routes.get(route)?;
        Some((
            route.caravan_progress,
            route.caravan_forward,
            route.stock_from,
            route.stock_to,
        ))
    }

    pub fn debug_caravan_endpoints(&self, route: usize) -> Option<(i32, i32, i32, i32)> {
        let state = self.road_routes.get(route)?.caravan_state()?;
        Some((state.from.0, state.from.1, state.to.0, state.to.1))
    }

    pub fn debug_set_caravan_state(
        &mut self,
        route: usize,
        progress: u32,
        forward: bool,
        stock_from: u8,
        stock_to: u8,
    ) -> bool {
        let Some(route) = self.road_routes.get_mut(route) else {
            return false;
        };
        route.caravan_progress = progress.min(route.caravan_max_progress());
        route.caravan_time_remainder = 0;
        route.caravan_forward = forward;
        route.stock_from = stock_from.min(CARAVAN_STOCK_MAX);
        route.stock_to = stock_to.min(CARAVAN_STOCK_MAX);
        true
    }

    pub fn debug_caravan_tick(&mut self, dt: f32) {
        self.update_route_caravan(dt);
    }

    pub fn debug_caravan_visible(&self) -> bool {
        self.visible_caravan_index().is_some()
    }

    fn natural_road_surface(block: BlockId) -> bool {
        matches!(block, GRASS | DIRT | STONE | SAND | ROAD_GRAVEL | 13..=16)
    }

    fn natural_road_cut(block: BlockId) -> bool {
        matches!(
            block,
            GRASS | DIRT | STONE | SAND | ROAD_COBBLE | ROAD_GRAVEL | 13..=16
        )
    }

    fn replaceable_road_air(block: BlockId) -> bool {
        block == AIR
            || block == WATER
            || Self::is_plant(block)
            || Self::is_snow_overlay(block)
            || Self::is_tree_block(block)
    }

    pub(super) fn apply_roads_to_chunk(&self, cc: ChunkCoord, chunk: &mut PaletteChunk) -> bool {
        let relevant: Vec<&RoadRoute> = self
            .road_routes
            .iter()
            .filter(|route| route.may_touch_chunk(cc))
            .collect();
        if relevant.is_empty() {
            return false;
        }

        let mut changed = false;
        let wx0 = cc.x * KCHUNK_DIM;
        let wz0 = cc.z * KCHUNK_DIM;
        let wy0 = cc.y * KCHUNK_DIM;
        for lz in 0..KCHUNK_DIM {
            for lx in 0..KCHUNK_DIM {
                let wx = wx0 + lx;
                let wz = wz0 + lz;
                let Some((tier, profile_y, center_distance)) = relevant
                    .iter()
                    .filter(|route| !route.protected_at(wx, wz, self.seed))
                    .filter_map(|route| {
                        route
                            .profile_match_at(wx, wz)
                            .map(|(y, distance)| (route.tier, y, distance))
                    })
                    .max_by(|a, b| a.0.cmp(&b.0).then_with(|| b.2.cmp(&a.2)))
                else {
                    continue;
                };
                let (surface_y, wet) = worldgen::worldgen_road_surface(wx, wz, self.seed);
                // The centerline follows the graded cut/fill profile. Side cells on a
                // 3-wide road stay conservative and never cut below their own surface.
                let road_y = if center_distance == 0 {
                    profile_y
                } else {
                    profile_y.max(surface_y)
                };
                let material = if wet {
                    ROAD_BOARDWALK
                } else if tier >= 3 {
                    ROAD_COBBLE
                } else {
                    ROAD_GRAVEL
                };

                // Build upward from the natural surface, or cut only the target road
                // cell when the grade passes through a hill. Arbitrary solids are never
                // overwritten; the two-cell headroom below clears natural terrain only.
                let support_from = surface_y.min(road_y);
                for y in support_from..=road_y {
                    if y < wy0 || y >= wy0 + KCHUNK_DIM {
                        continue;
                    }
                    let ly = (y - wy0) as usize;
                    let old = chunk.get(lx as usize, ly, lz as usize);
                    let allowed = old == material
                        || (material == ROAD_COBBLE && old == ROAD_GRAVEL)
                        || if y <= surface_y && !wet {
                            if y < surface_y {
                                Self::natural_road_cut(old)
                            } else {
                                Self::natural_road_surface(old)
                            }
                        } else {
                            Self::replaceable_road_air(old)
                        };
                    if allowed && old != material {
                        chunk.set(lx as usize, ly, lz as usize, material);
                        changed = true;
                    }
                }

                // Expose a cut through recognized procedural terrain, then leave two
                // blocks of headroom. Buildings and arbitrary solids are never erased.
                for y in (road_y + 1)..=(surface_y.max(road_y) + 2) {
                    if y < wy0 || y >= wy0 + KCHUNK_DIM {
                        continue;
                    }
                    let ly = (y - wy0) as usize;
                    let block = chunk.get(lx as usize, ly, lz as usize);
                    let clear = Self::is_plant(block)
                        || Self::is_snow_overlay(block)
                        || Self::is_tree_block(block)
                        || (road_y < surface_y && Self::natural_road_cut(block));
                    if clear {
                        chunk.set(lx as usize, ly, lz as usize, AIR);
                        changed = true;
                    }
                }
            }
        }
        changed
    }

    pub(super) fn refresh_resident_roads(&mut self) {
        let mut columns = HashSet::new();
        for route in &self.road_routes {
            route.affected_chunk_columns(&mut columns);
        }
        for (cx, cz) in columns {
            // One player edit protects the entire vertical column. Otherwise a road
            // fill generated in an adjacent Y chunk could bridge over that saved edit.
            if (CY_MIN..=CY_MAX).any(|cy| {
                self.edited.contains(&ChunkCoord {
                    x: cx,
                    y: cy,
                    z: cz,
                })
            }) {
                continue;
            }
            for cy in CY_MIN..=CY_MAX {
                let cc = ChunkCoord {
                    x: cx,
                    y: cy,
                    z: cz,
                };
                let Some(mut chunk) = self.store.get(cc).cloned() else {
                    continue;
                };
                if self.apply_roads_to_chunk(cc, &mut chunk) {
                    self.store.insert(chunk);
                    self.dirty_chunk_and_resident_neighbours(cc);
                    self.shadow.refill_cols.insert((cc.x, cc.z));
                }
            }
        }
    }

    pub fn debug_set_village_tier(&mut self, ax: i32, az: i32, tier: u8) {
        self.promote_village(ax, az, tier);
    }

    pub fn debug_road_route_count(&self) -> usize {
        self.road_routes.len()
    }

    pub fn debug_road_route(&self, index: usize) -> Option<(i32, i32, i32, i32, i32, i32, u8)> {
        let route = self.road_routes.get(index)?;
        Some((
            route.from.0,
            route.from.1,
            route.via.0,
            route.via.1,
            route.to.0,
            route.to.1,
            route.tier,
        ))
    }

    pub fn debug_road_sample_count(&self, route: usize) -> usize {
        self.road_routes
            .get(route)
            .map(|r| r.profile.len())
            .unwrap_or(0)
    }

    pub fn debug_road_sample(&self, route: usize, sample: usize) -> Option<(i32, i32, i32)> {
        self.road_routes.get(route)?.profile_point(sample)
    }

    pub fn debug_road_material_at(&self, wx: i32, wz: i32) -> BlockId {
        let Some((tier, _)) = self
            .road_routes
            .iter()
            .filter(|route| !route.protected_at(wx, wz, self.seed))
            .filter_map(|route| route.profile_at(wx, wz).map(|y| (route.tier, y)))
            .max()
        else {
            return AIR;
        };
        let (_, wet) = worldgen::worldgen_road_surface(wx, wz, self.seed);
        if wet {
            ROAD_BOARDWALK
        } else if tier >= 3 {
            ROAD_COBBLE
        } else {
            ROAD_GRAVEL
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn install_caravan_cell(world: &mut World<'_>, route: usize) -> ChunkCoord {
        let road = world.road_routes[route].caravan_pose().unwrap().4;
        let tier = world.road_routes[route].tier;
        let (_, wet) = worldgen::worldgen_road_surface(road.x, road.z, world.seed);
        let block = if wet {
            ROAD_BOARDWALK
        } else if tier >= 3 {
            ROAD_COBBLE
        } else {
            ROAD_GRAVEL
        };
        let cc = World::to_chunk(road);
        world.store.get_or_create(cc).set(
            World::mod16(road.x) as usize,
            World::mod16(road.y) as usize,
            World::mod16(road.z) as usize,
            block,
        );
        cc
    }

    #[test]
    fn caravan_progress_reverses_and_delivers_deterministically() {
        let mut a = RoadRoute::from_geometry((0, 0), (8, 0), (16, 0), 3, 1);
        a.caravan_progress = a.caravan_max_progress() - 10;
        a.stock_to = CARAVAN_STOCK_MAX - 1;
        let mut b = a.clone();
        a.advance_caravan(0.1);
        b.advance_caravan(0.1);
        assert_eq!(a, b);
        assert!(!a.caravan_forward);
        assert_eq!(
            a.stock_to, CARAVAN_STOCK_MAX,
            "delivery stock stays bounded"
        );
        assert!(a.caravan_progress < a.caravan_max_progress());
    }

    #[test]
    fn caravan_progress_is_frame_partition_independent() {
        let mut coarse = RoadRoute::from_geometry((0, 0), (64, 0), (128, 0), 2, 1);
        let mut fine = coarse.clone();
        for _ in 0..10 {
            coarse.advance_caravan(0.1);
        }
        for _ in 0..100 {
            fine.advance_caravan(0.01);
        }
        assert_eq!(
            coarse, fine,
            "one elapsed second has one fixed-point result"
        );
    }

    #[test]
    fn reverse_fractional_heading_targets_the_current_sample() {
        let mut route = RoadRoute::from_geometry((0, 0), (8, 0), (8, 8), 2, 1);
        route.caravan_progress = 8 * CARAVAN_FP + CARAVAN_FP / 2;
        route.caravan_forward = false;
        let yaw = route.caravan_pose().unwrap().3;
        assert!((yaw.abs() - std::f32::consts::PI).abs() < 0.001);
    }

    #[test]
    fn rebuild_preserves_caravan_progress_direction_and_stock() {
        let mut world = World::new(Some(TerrainGen::new()));
        world.seed = 11;
        world.rebuild_road_routes();
        assert!(world.debug_set_caravan_state(0, 777, false, 1, 9));
        let before = world.debug_caravan_state(0).unwrap();
        let endpoints = world.debug_caravan_endpoints(0).unwrap();
        world.rebuild_road_routes();
        let route = (0..world.debug_road_route_count())
            .find(|&i| world.debug_caravan_endpoints(i) == Some(endpoints))
            .unwrap();
        assert_eq!(world.debug_caravan_state(route), Some(before));
    }

    #[test]
    fn exactly_one_nearby_intact_route_runs_and_bad_road_hides() {
        let mut world = World::new(None);
        world.seed = 77;
        world.road_routes.push(RoadRoute::from_geometry(
            (200, 200),
            (208, 200),
            (216, 200),
            2,
            world.seed,
        ));
        world.road_routes.push(RoadRoute::from_geometry(
            (200, 232),
            (208, 232),
            (216, 232),
            2,
            world.seed,
        ));
        let first_cc = install_caravan_cell(&mut world, 0);
        install_caravan_cell(&mut world, 1);
        let first = world.road_routes[0].caravan_pose().unwrap();
        world.pos = V3::new(first.0, first.1 + 2.0, first.2);
        world.debug_caravan_tick(0.1);
        assert!(world.road_routes[0].caravan_progress > 0);
        assert_eq!(world.road_routes[1].caravan_progress, 0);

        world.store.evict(first_cc);
        assert_eq!(world.nearby_route_index(), Some(0));
        assert!(
            !world.debug_caravan_visible(),
            "a loaded cart on the frozen second route is not drawn"
        );
        install_caravan_cell(&mut world, 0);

        world.road_routes.truncate(1);
        world.store.evict(first_cc);
        assert!(!world.debug_caravan_visible(), "unloaded road hides");
        install_caravan_cell(&mut world, 0);
        let road = world.road_routes[0].caravan_pose().unwrap().4;
        world.debug_edit(road.x, road.y, road.z, GLOW);
        assert!(!world.debug_caravan_visible(), "edited road hides");
        world.debug_edit(road.x, road.y, road.z, AIR);
        assert!(!world.debug_caravan_visible(), "missing road hides");
    }

    #[test]
    fn nearby_route_runs_with_its_cart_far_offscreen() {
        let mut world = World::new(None);
        world.road_routes.push(RoadRoute::from_geometry(
            (200, 200),
            (400, 200),
            (600, 200),
            2,
            1,
        ));
        world.pos = V3::new(500.5, 40.0, 200.5);
        assert!(!world.debug_caravan_visible());
        world.debug_caravan_tick(0.1);
        assert!(world.road_routes[0].caravan_progress > 0);
    }

    #[test]
    fn shared_endpoint_uses_stock_from_any_arriving_route() {
        let mut world = World::new(None);
        world
            .road_routes
            .push(RoadRoute::new((100, 100), (200, 100), 2, 7));
        world
            .road_routes
            .push(RoadRoute::new((100, 100), (100, 200), 2, 7));
        for route in &mut world.road_routes {
            route.stock_from = 0;
            route.stock_to = 0;
        }
        world.road_routes[1].stock_from = 2;
        world.pos = V3::new(100.5, 40.0, 100.5);
        assert_eq!(world.caravan_coin_stock_available(), Some(true));
        assert!(world.consume_caravan_coin_stock());
        assert_eq!(world.road_routes[0].stock_from, 0);
        assert_eq!(world.road_routes[1].stock_from, 1);
    }

    #[test]
    fn caravan_accepts_stronger_crossing_but_not_protected_brick() {
        let seed = 77;
        let (low, high) = (0..128)
            .flat_map(|z| (0..128).map(move |x| (x * 16 + 8, z * 16 + 8)))
            .filter(|&(x, z)| !worldgen::worldgen_structure_footprint(x, z, seed))
            .find_map(|(x, z)| {
                let low = RoadRoute::from_geometry((x - 8, z), (x, z), (x + 8, z), 2, seed);
                let high = RoadRoute::from_geometry((x, z - 8), (x, z), (x, z + 8), 3, seed);
                (low.profile[8] == high.profile[8]).then_some((low, high))
            })
            .expect("a clear level route crossing");
        let mut world = World::new(None);
        world.seed = seed;
        world.road_routes = vec![low, high];
        world.road_routes[0].caravan_progress = 8 * CARAVAN_FP;
        let road = world.road_routes[0].caravan_pose().unwrap().4;
        let cc = World::to_chunk(road);
        world.store.get_or_create(cc).set(
            World::mod16(road.x) as usize,
            World::mod16(road.y) as usize,
            World::mod16(road.z) as usize,
            ROAD_COBBLE,
        );
        assert_eq!(world.debug_road_material_at(road.x, road.z), ROAD_COBBLE);
        assert!(world.caravan_road_intact(&world.road_routes[0], road));

        let (x, z) = (0..128)
            .flat_map(|z| (0..128).map(move |x| (x * 16 + 8, z * 16 + 8)))
            .find(|&(x, z)| worldgen::worldgen_structure_footprint(x, z, seed))
            .expect("a protected structure footprint");
        let mut blocked = World::new(None);
        blocked.seed = seed;
        blocked.road_routes.push(RoadRoute::from_geometry(
            (x - 8, z),
            (x, z),
            (x + 8, z),
            2,
            seed,
        ));
        blocked.road_routes[0].caravan_progress = 8 * CARAVAN_FP;
        let road = blocked.road_routes[0].caravan_pose().unwrap().4;
        let cc = World::to_chunk(road);
        blocked.store.get_or_create(cc).set(
            World::mod16(road.x) as usize,
            World::mod16(road.y) as usize,
            World::mod16(road.z) as usize,
            BRICK,
        );
        assert_eq!(blocked.debug_road_material_at(road.x, road.z), AIR);
        assert!(!blocked.caravan_road_intact(&blocked.road_routes[0], road));
    }

    #[test]
    fn raster_widths_are_one_then_three_blocks() {
        let narrow = RoadRoute::from_geometry((0, 0), (8, 0), (16, 0), 2, 1);
        let wide = RoadRoute::from_geometry((0, 0), (8, 0), (16, 0), 3, 1);
        assert!(narrow.contains(7, 0));
        assert!(!narrow.contains(7, 1));
        assert!(wide.contains(7, -1));
        assert!(wide.contains(7, 1));
        assert!(!wide.contains(7, 2));
    }

    #[test]
    fn route_uses_the_short_torus_image_deterministically() {
        let w = worldgen::WORLD_PERIOD;
        let a = RoadRoute::new((40, 10), (w - 40, 10), 2, 77);
        let b = RoadRoute::new((40, 10), (w - 40, 10), 2, 77);
        assert_eq!(a, b);
        assert_eq!(a.settlement_to, Some((-40, 10)));
        assert_eq!(a.from, (31, 10));
        assert_eq!(a.to, (-31, 10));
        assert!(a.contains(31, 10));
        assert!(a.contains(w - 31, 10));
        assert!(!a.contains(40, 10), "settlement core stays off the overlay");
        let mut chunks = HashSet::new();
        a.affected_chunk_columns(&mut chunks);
        assert!(chunks.iter().any(|(cx, _)| *cx == 0));
        assert!(chunks
            .iter()
            .any(|(cx, _)| *cx == worldgen::WORLD_PERIOD_CHUNKS - 1));
        assert!(!a.contains(w / 2, 10));
    }

    #[test]
    fn generated_settlements_have_a_stable_partner() {
        for seed in [11, 42, 99, 2026] {
            let (_, ax, az) = worldgen::worldgen_city_near(0, 0, 2048, seed)
                .expect("spawn search seeds have a city");
            let a = worldgen::worldgen_settlement_partner(ax, az, seed)
                .expect("a generated settlement has another settlement on the torus");
            let b = worldgen::worldgen_settlement_partner(ax, az, seed)
                .expect("partner lookup is repeatable");
            assert_eq!(a, b);
            assert_ne!((a.1, a.2), (ax, az));
        }
    }

    #[test]
    fn representative_real_routes_have_walkable_deterministic_grades() {
        for seed in [11, 42, 99, 2026] {
            let (_, ax, az) = worldgen::worldgen_city_near(0, 0, 2048, seed)
                .expect("spawn search seeds have a city");
            let (_, bx, bz) = worldgen::worldgen_settlement_partner(ax, az, seed)
                .expect("city has a route partner");
            let a = RoadRoute::new((ax, az), (bx, bz), 3, seed);
            let b = RoadRoute::new((ax, az), (bx, bz), 3, seed);
            assert_eq!(a, b, "seed {seed}: route and grade are deterministic");
            assert!(a.profile.len() > 2);
            for pair in a.profile.windows(2) {
                assert!(
                    (pair[1] - pair[0]).abs() <= 1,
                    "seed {seed}: adjacent road grade jumped from {} to {}",
                    pair[0],
                    pair[1]
                );
            }
            let (sx, sz, sy) = a.profile_point(0).unwrap();
            let (ex, ez, ey) = a.profile_point(a.profile.len() - 1).unwrap();
            assert_eq!(sy, worldgen::worldgen_road_surface(sx, sz, seed).0);
            assert_eq!(ey, worldgen::worldgen_road_surface(ex, ez, seed).0);
        }
    }

    #[test]
    fn effective_home_and_visited_cities_join_routes_without_raw_tiers() {
        let seed = 11;
        let (_, hx, hz) = worldgen::worldgen_city_near(0, 0, 2048, seed).unwrap();
        let mut world = World::new(Some(TerrainGen::new()));
        world.seed = seed;
        world.rebuild_road_routes();
        assert_eq!(world.raw_village_tier(hx, hz), 0);
        assert!(world.road_routes.iter().any(|route| {
            route.tier == 3
                && [route.settlement_from, route.settlement_to]
                    .into_iter()
                    .flatten()
                    .any(|p| (World::wrap_block(p.0), World::wrap_block(p.1)) == (hx, hz))
        }));

        let mut visited = None;
        'scan: for z in (-4096..4096).step_by(64) {
            for x in (-4096..4096).step_by(64) {
                let (typ, ax, az, _) = worldgen::worldgen_structure_near(x, z, seed);
                if worldgen::worldgen_is_city(typ) && (ax, az) != (hx, hz) {
                    visited = Some((ax, az));
                    break 'scan;
                }
            }
        }
        let visited = visited.expect("second city");
        world.visited_villages.push(visited);
        world.rebuild_road_routes();
        assert!(world.road_routes.iter().any(|route| {
            [route.settlement_from, route.settlement_to]
                .into_iter()
                .flatten()
                .any(|p| {
                    (World::wrap_block(p.0), World::wrap_block(p.1)) == visited
                })
        }));
        let once = world.road_routes.clone();
        world.rebuild_road_routes();
        assert_eq!(world.road_routes, once, "derived city routes are deterministic");
    }

    #[test]
    fn wet_road_cells_become_boardwalk() {
        let seed = 11;
        let mut wet = None;
        'scan: for z in (0..1024).step_by(8) {
            for x in (0..1024).step_by(8) {
                if worldgen::worldgen_road_surface(x, z, seed).1 {
                    wet = Some((x, z));
                    break 'scan;
                }
            }
        }
        let (x, z) = wet.expect("test region contains water");
        let mut world = World::new(Some(TerrainGen::new()));
        world.seed = seed;
        world.road_routes.push(RoadRoute::from_geometry(
            (x - 2, z),
            (x, z),
            (x + 2, z),
            2,
            seed,
        ));
        let cc = World::to_chunk(IVec3 { x, y: 7, z });
        let mut chunk = PaletteChunk::new(cc, AIR);
        assert!(world.apply_roads_to_chunk(cc, &mut chunk));
        assert_eq!(
            chunk.get(
                World::mod16(x) as usize,
                World::mod16(7) as usize,
                World::mod16(z) as usize,
            ),
            ROAD_BOARDWALK
        );
    }

    #[test]
    fn road_replaces_natural_surface_but_not_arbitrary_solid() {
        let seed = 42;
        let mut dry = None;
        'scan: for z in (0..1024).step_by(8) {
            for x in (0..1024).step_by(8) {
                if !worldgen::worldgen_road_surface(x, z, seed).1
                    && !worldgen::worldgen_structure_footprint(x, z, seed)
                {
                    dry = Some((x, z));
                    break 'scan;
                }
            }
        }
        let (x, z) = dry.expect("test region contains unprotected dry terrain");
        let surface = worldgen::worldgen_road_surface(x, z, seed).0;
        let mut route = RoadRoute::from_geometry((x - 2, z), (x, z), (x + 2, z), 2, seed);
        route.profile.fill(surface);
        let mut world = World::new(Some(TerrainGen::new()));
        world.seed = seed;
        world.road_routes.push(route);
        let cc = World::to_chunk(IVec3 { x, y: surface, z });

        for natural_id in [GRASS, DIRT, STONE, SAND, ROAD_GRAVEL, 13, 14, 15, 16] {
            let mut natural = PaletteChunk::new(cc, AIR);
            natural.set(
                World::mod16(x) as usize,
                World::mod16(surface) as usize,
                World::mod16(z) as usize,
                natural_id,
            );
            world.apply_roads_to_chunk(cc, &mut natural);
            assert_eq!(
                natural.get(
                    World::mod16(x) as usize,
                    World::mod16(surface) as usize,
                    World::mod16(z) as usize,
                ),
                ROAD_GRAVEL,
                "natural surface id {natural_id} did not become road"
            );
        }

        let mut built = PaletteChunk::new(cc, AIR);
        built.set(
            World::mod16(x) as usize,
            World::mod16(surface) as usize,
            World::mod16(z) as usize,
            BRICK,
        );
        world.apply_roads_to_chunk(cc, &mut built);
        assert_eq!(
            built.get(
                World::mod16(x) as usize,
                World::mod16(surface) as usize,
                World::mod16(z) as usize,
            ),
            BRICK,
            "an arbitrary procedural/player solid is never replaced"
        );
    }

    #[test]
    fn deep_cut_exposes_road_and_full_headroom_across_y_chunks() {
        let seed = 99;
        let mut site = None;
        'scan: for z in (0..1024).step_by(8) {
            for x in (0..1024).step_by(8) {
                let (surface, wet) = worldgen::worldgen_road_surface(x, z, seed);
                if !wet && surface >= 10 && !worldgen::worldgen_structure_footprint(x, z, seed) {
                    site = Some((x, z, surface));
                    break 'scan;
                }
            }
        }
        let (x, z, surface) = site.expect("test region contains deep dry terrain");
        let road_y = surface - 40;
        let mut route = RoadRoute::from_geometry((x - 2, z), (x, z), (x + 2, z), 2, seed);
        route.profile.fill(road_y);
        let mut world = World::new(Some(TerrainGen::new()));
        world.seed = seed;
        world.road_routes.push(route);

        for cy in road_y.div_euclid(KCHUNK_DIM)..=(surface + 2).div_euclid(KCHUNK_DIM) {
            let cc = ChunkCoord {
                x: x.div_euclid(KCHUNK_DIM),
                y: cy,
                z: z.div_euclid(KCHUNK_DIM),
            };
            let mut chunk = PaletteChunk::new(cc, AIR);
            for ly in 0..KCHUNK_DIM {
                let y = cy * KCHUNK_DIM + ly;
                if y <= surface {
                    chunk.set(
                        World::mod16(x) as usize,
                        ly as usize,
                        World::mod16(z) as usize,
                        STONE,
                    );
                }
            }
            world.apply_roads_to_chunk(cc, &mut chunk);
            if road_y >= cy * KCHUNK_DIM && road_y < (cy + 1) * KCHUNK_DIM {
                assert_eq!(
                    chunk.get(
                        World::mod16(x) as usize,
                        World::mod16(road_y) as usize,
                        World::mod16(z) as usize,
                    ),
                    ROAD_GRAVEL
                );
            }
            for y in (road_y + 1)..=(surface + 2) {
                if y >= cy * KCHUNK_DIM && y < (cy + 1) * KCHUNK_DIM {
                    assert_eq!(
                        chunk.get(
                            World::mod16(x) as usize,
                            World::mod16(y) as usize,
                            World::mod16(z) as usize,
                        ),
                        AIR,
                        "deep cut left terrain at y={y}"
                    );
                }
            }
        }
    }
}
