use super::*;

const ROAD_GRAVEL: BlockId = 11;
const ROAD_COBBLE: BlockId = 10;
const ROAD_BOARDWALK: BlockId = 4;
const SETTLEMENT_CORE_R: i32 = 8;
const SETTLEMENT_GATE_R: i32 = 9;
const SETTLEMENT_ROUTE_ZONE_R: i32 = 56;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct RoadRoute {
    settlement_from: Option<(i32, i32)>,
    settlement_to: Option<(i32, i32)>,
    from: (i32, i32),
    via: (i32, i32),
    to: (i32, i32),
    tier: u8,
    profile: Vec<i32>,
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
        }
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
        let mut links = std::collections::BTreeMap::<((i32, i32), (i32, i32)), u8>::new();
        for (&from, state) in &self.villages {
            if state.tier < 2 {
                continue;
            }
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
                .and_modify(|tier| *tier = (*tier).max(state.tier.min(3)))
                .or_insert(state.tier.min(3));
        }
        self.road_routes = links
            .into_iter()
            .map(|((from, to), tier)| RoadRoute::new(from, to, tier, self.seed))
            .collect();
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
        self.villages
            .entry((Self::wrap_block(ax), Self::wrap_block(az)))
            .or_default()
            .tier = tier.min(3);
        self.rebuild_road_routes();
        self.refresh_resident_roads();
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
