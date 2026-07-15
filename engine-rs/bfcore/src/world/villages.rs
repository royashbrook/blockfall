use super::*;

// Living-villages (#95): per-settlement upgrade progress, keyed by settlement
// anchor. Blocks stay procedural/edited; this table is player progress.
#[derive(Clone, Default)]
pub(super) struct VillageState {
    pub(super) tier: u8,
    pub(super) lights: u8,
    pub(super) wood_cells: i32,
    pub(super) progress: i32,
}

/// #256: player-facing settlement size is derived, never separately saved.
/// Procedural cities are complete from birth; upgraded villages keep their raw
/// tier and original role order while growing through the same three classes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SettlementClass {
    Village,
    Town,
    City,
}

impl SettlementClass {
    pub(super) fn map_kind(self) -> u32 {
        match self {
            Self::Village => 1,
            Self::Town => 4,
            Self::City => 3,
        }
    }

    pub(super) fn label(self) -> &'static str {
        match self {
            Self::Village => "Village",
            Self::Town => "Town",
            Self::City => "City",
        }
    }
}

impl<'c> World<'c> {
    // The palisade / wall ring is an R-radius square centred on the settlement anchor.
    const PALISADE_R: i32 = 8;
    const PALISADE_CELLS: i32 = 8 * Self::PALISADE_R - 2;
    const WALL_WOOD: BlockId = 21; // oak_log
    const WALL_STONE: BlockId = 8; // stone_brick
    const IRON_GATE: BlockId = 53; // iron_bars
    const LAMP: BlockId = 35; // crystal_lamp
    const WOOD_BEAM: BlockId = 51;
    const VILLAGER_GLOBAL_CAP: i32 = 6;
    const VILLAGE_VILLAGERS: i32 = 3;
    const TOWN_VILLAGERS: i32 = 5;
    const CITY_VILLAGERS: i32 = 6;
    const VILLAGE_WARD_LIGHTS: u8 = 8;

    pub fn village_view_nearest(&self) -> Option<(i32, i32, u8, i32, i32, i32, i32)> {
        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);
        self.village_status_near(px, pz, 64)
    }

    fn palisade_ring_cells() -> Vec<(i32, i32)> {
        const R: i32 = World::PALISADE_R;
        let mut order: Vec<(i32, i32)> = Vec::new();
        for dx in -R..=R {
            order.push((dx, -R));
        }
        for dz in (-R + 1)..=R {
            order.push((R, dz));
        }
        for dx in (-R..=(R - 1)).rev() {
            order.push((dx, R));
        }
        for dz in ((-R + 1)..=(R - 1)).rev() {
            order.push((-R, dz));
        }
        order.retain(|&(dx, dz)| !(dz == R && (dx == 0 || dx == 1)));
        order
    }

    fn build_palisade_segment(
        &mut self,
        cx: i32,
        cz: i32,
        cells_to_build: i32,
        wall: BlockId,
    ) -> i32 {
        let mut built = 0;
        for (dx, dz) in Self::palisade_ring_cells() {
            if built >= cells_to_build {
                break;
            }
            let wx = cx + dx;
            let wz = cz + dz;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            if self.block_at(IVec3 {
                x: wx,
                y: surf + 1,
                z: wz,
            }) == wall
            {
                continue;
            }
            self.set_block_internal(
                IVec3 {
                    x: wx,
                    y: surf + 1,
                    z: wz,
                },
                wall,
            );
            self.set_block_internal(
                IVec3 {
                    x: wx,
                    y: surf + 2,
                    z: wz,
                },
                wall,
            );
            built += 1;
        }
        built
    }

    fn count_palisade_cells(&self, cx: i32, cz: i32, wall: BlockId) -> i32 {
        let mut n = 0;
        for (dx, dz) in Self::palisade_ring_cells() {
            let wx = cx + dx;
            let wz = cz + dz;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            if self.block_at(IVec3 {
                x: wx,
                y: surf + 1,
                z: wz,
            }) == wall
            {
                n += 1;
            }
        }
        n
    }

    fn upgrade_palisade_material(&mut self, cx: i32, cz: i32, wall: BlockId) -> i32 {
        let mut n = 0;
        for (dx, dz) in Self::palisade_ring_cells() {
            let wx = cx + dx;
            let wz = cz + dz;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            let here = self.block_at(IVec3 {
                x: wx,
                y: surf + 1,
                z: wz,
            });
            if here == Self::WALL_WOOD || here == Self::WALL_STONE {
                if here != wall {
                    self.set_block_internal(
                        IVec3 {
                            x: wx,
                            y: surf + 1,
                            z: wz,
                        },
                        wall,
                    );
                    self.set_block_internal(
                        IVec3 {
                            x: wx,
                            y: surf + 2,
                            z: wz,
                        },
                        wall,
                    );
                    n += 1;
                }
            }
        }
        n
    }

    fn stamp_stone_accents(&mut self, cx: i32, cz: i32) {
        for (dx, dz) in Self::palisade_ring_cells() {
            let wx = cx + dx;
            let wz = cz + dz;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            let p = IVec3 {
                x: wx,
                y: surf + 3,
                z: wz,
            };
            if self.block_at(p) == AIR {
                self.set_block_internal(p, Self::WALL_STONE);
            }
        }
        const R: i32 = World::PALISADE_R;
        for &(dx, dz) in &[(-R, -R), (R, -R), (-R, R), (R, R)] {
            let wx = cx + dx;
            let wz = cz + dz;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            for dy in 1..=5 {
                let p = IVec3 {
                    x: wx,
                    y: surf + dy,
                    z: wz,
                };
                if self.block_at(p) == AIR
                    || self.block_at(p) == Self::WALL_STONE
                    || self.block_at(p) == Self::WALL_WOOD
                {
                    self.set_block_internal(p, Self::WALL_STONE);
                }
            }
        }
    }

    fn stamp_iron_gate_and_lamps(&mut self, cx: i32, cz: i32) {
        const R: i32 = World::PALISADE_R;
        for &dx in &[0, 1] {
            let wx = cx + dx;
            let wz = cz + R;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            self.set_block_internal(
                IVec3 {
                    x: wx,
                    y: surf + 1,
                    z: wz,
                },
                Self::IRON_GATE,
            );
            self.set_block_internal(
                IVec3 {
                    x: wx,
                    y: surf + 2,
                    z: wz,
                },
                Self::IRON_GATE,
            );
        }
        for &(dx, dz) in &[(-R, -R), (R, -R), (-R, R), (R, R)] {
            let wx = cx + dx;
            let wz = cz + dz;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            let mut y = surf + 1;
            while y < surf + 8 && self.block_at(IVec3 { x: wx, y, z: wz }) != AIR {
                y += 1;
            }
            self.set_block_internal(IVec3 { x: wx, y, z: wz }, Self::LAMP);
        }
        for &dx in &[-1, 2] {
            let wx = cx + dx;
            let wz = cz + R;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            let p = IVec3 {
                x: wx,
                y: surf + 3,
                z: wz,
            };
            if self.block_at(p) == AIR {
                self.set_block_internal(p, Self::LAMP);
            }
        }
    }

    pub(super) fn raw_village_tier(&self, ax: i32, az: i32) -> u8 {
        self.villages
            .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
            .map(|v| v.tier)
            .unwrap_or(0)
    }

    fn settlement_is_procedural_city(&self, ax: i32, az: i32) -> bool {
        let (typ, sx, sz, _) = worldgen::worldgen_structure_near(ax, az, self.seed);
        worldgen::worldgen_is_city(typ)
            && Self::wrap_block(sx) == Self::wrap_block(ax)
            && Self::wrap_block(sz) == Self::wrap_block(az)
    }

    pub(super) fn settlement_class_at(&self, ax: i32, az: i32) -> SettlementClass {
        if self.settlement_is_procedural_city(ax, az) || self.raw_village_tier(ax, az) >= 3 {
            SettlementClass::City
        } else if self.raw_village_tier(ax, az) == 2 {
            SettlementClass::Town
        } else {
            SettlementClass::Village
        }
    }

    pub(super) fn effective_village_tier(&self, ax: i32, az: i32) -> u8 {
        if self.settlement_is_procedural_city(ax, az) {
            3
        } else {
            self.raw_village_tier(ax, az).min(3)
        }
    }

    fn growth_cell(cc: ChunkCoord, wx: i32, wy: i32, wz: i32) -> Option<(usize, usize, usize)> {
        let w = Self::canon_block(IVec3 {
            x: wx,
            y: wy,
            z: wz,
        });
        if Self::canon_chunk(Self::to_chunk(w)) != Self::canon_chunk(cc) {
            return None;
        }
        Some((
            Self::mod16(w.x) as usize,
            Self::mod16(w.y) as usize,
            Self::mod16(w.z) as usize,
        ))
    }

    fn growth_replaceable(block: BlockId) -> bool {
        block == AIR
            || block == WATER
            || Self::is_plant(block)
            || Self::is_snow_overlay(block)
            || Self::is_tree_block(block)
    }

    fn growth_set(
        cc: ChunkCoord,
        chunk: &mut PaletteChunk,
        wx: i32,
        wy: i32,
        wz: i32,
        block: BlockId,
    ) -> bool {
        let Some((lx, ly, lz)) = Self::growth_cell(cc, wx, wy, wz) else {
            return false;
        };
        let old = chunk.get(lx, ly, lz);
        if Self::growth_replaceable(old) && old != block {
            chunk.set(lx, ly, lz, block);
            true
        } else {
            false
        }
    }

    fn growth_clear(cc: ChunkCoord, chunk: &mut PaletteChunk, wx: i32, wy: i32, wz: i32) -> bool {
        let Some((lx, ly, lz)) = Self::growth_cell(cc, wx, wy, wz) else {
            return false;
        };
        let old = chunk.get(lx, ly, lz);
        if old != AIR && Self::growth_replaceable(old) {
            chunk.set(lx, ly, lz, AIR);
            true
        } else {
            false
        }
    }

    /// Add a small, open-sided artisan shelter around one real workstation.
    /// The shaped beam frame and pitched material roof replace the old sealed
    /// 5x5 cube huts; the worker's west-side cell remains fully open.
    fn apply_artisan_shop(
        &self,
        cc: ChunkCoord,
        chunk: &mut PaletteChunk,
        ax: i32,
        az: i32,
        dx: i32,
        dz: i32,
        station: BlockId,
        roof: BlockId,
    ) -> bool {
        const SEA_LEVEL: i32 = 6;
        let sx = ax + dx;
        let sz = az + dz;
        let work_x = sx - 1;
        let floor_y = worldgen::worldgen_surface_height(sx, sz, self.seed)
            .max(worldgen::worldgen_surface_height(work_x, sz, self.seed))
            .max(SEA_LEVEL + 1);
        let mut changed = false;

        // Four slim posts, then a three-step pitched roof with a shaped ridge.
        for (px, pz) in [
            (sx - 2, sz - 1),
            (sx - 2, sz + 1),
            (sx + 1, sz - 1),
            (sx + 1, sz + 1),
        ] {
            for y in (worldgen::worldgen_surface_height(px, pz, self.seed) + 1)..=floor_y {
                changed |= Self::growth_set(cc, chunk, px, y, pz, Self::WALL_STONE);
            }
            for y in (floor_y + 1)..=(floor_y + 3) {
                changed |= Self::growth_set(cc, chunk, px, y, pz, Self::WOOD_BEAM);
            }
        }
        for x in (sx - 2)..=(sx + 1) {
            for z in [sz - 2, sz + 2] {
                changed |= Self::growth_set(cc, chunk, x, floor_y + 3, z, roof);
            }
            for z in [sz - 1, sz + 1] {
                changed |= Self::growth_set(cc, chunk, x, floor_y + 4, z, roof);
            }
            changed |= Self::growth_set(cc, chunk, x, floor_y + 5, sz, Self::WOOD_BEAM);
        }

        // Preserve the physical routine contract even if foliage crossed the plot.
        for y in (floor_y + 1)..=(floor_y + 2) {
            changed |= Self::growth_clear(cc, chunk, work_x, y, sz);
        }

        // Each trade reads differently at a glance without inventing more blocks.
        match station {
            58 => changed |= Self::growth_set(cc, chunk, sx + 1, floor_y + 1, sz, 57),
            59 => changed |= Self::growth_set(cc, chunk, sx + 1, floor_y + 1, sz, Self::IRON_GATE),
            60 => {
                changed |= Self::growth_set(cc, chunk, sx + 1, floor_y + 1, sz - 1, 36);
                changed |= Self::growth_set(cc, chunk, sx + 1, floor_y + 1, sz + 1, 37);
            }
            61 => changed |= Self::growth_set(cc, chunk, sx + 1, floor_y + 1, sz, Self::WOOD_BEAM),
            56 => changed |= Self::growth_set(cc, chunk, sx + 1, floor_y + 1, sz, Self::WALL_WOOD),
            _ => {}
        }
        changed
    }

    pub(super) fn apply_settlement_growth_to_chunk(
        &self,
        cc: ChunkCoord,
        chunk: &mut PaletteChunk,
    ) -> bool {
        let mut changed = false;
        let wx = cc.x * KCHUNK_DIM + KCHUNK_DIM / 2;
        let wz = cc.z * KCHUNK_DIM + KCHUNK_DIM / 2;
        // The procedural City already stamps its complete civic core, stations,
        // shops, and props in worldgen. This frame-thread overlay is only for
        // player-promoted villages recorded in `villages`; scanning procedural
        // structure cells for every streamed chunk added several milliseconds to
        // every frame around HOME while redundantly drawing the same City twice.
        let settlements: Vec<(i32, i32, u8)> = self
            .villages
            .iter()
            .filter_map(|(&(ax, az), state)| {
                let tier = state.tier.min(3);
                (tier >= 2
                    && Self::wrap_signed_block(ax - wx).abs() <= 28
                    && Self::wrap_signed_block(az - wz).abs() <= 28
                )
                    .then_some((ax, az, tier))
            })
            .collect();

        for (ax, az, tier) in settlements {
            match tier {
                2 => {
                    changed |= self.apply_artisan_shop(cc, chunk, ax, az, -4, 4, 58, 24);
                    changed |= self.apply_artisan_shop(cc, chunk, ax, az, -4, -4, 59, 8);
                    changed |= self.apply_artisan_shop(cc, chunk, ax, az, 6, 6, 61, 4);
                }
                _ => {
                    changed |= self.apply_artisan_shop(cc, chunk, ax, az, -4, 4, 58, 24);
                    changed |= self.apply_artisan_shop(cc, chunk, ax, az, -4, -4, 59, 8);
                    changed |= self.apply_artisan_shop(cc, chunk, ax, az, 6, 6, 61, 4);
                    changed |= self.apply_artisan_shop(cc, chunk, ax, az, 4, -4, 60, 24);
                    changed |= self.apply_artisan_shop(cc, chunk, ax, az, 4, 4, 56, 4);
                }
            }
        }
        changed
    }

    fn materialize_resident_settlement_growth(
        &mut self,
        ax: i32,
        az: i32,
        preserve_edited: bool,
    ) {
        let mut columns = HashSet::new();
        for dz in -12..=12 {
            for dx in -12..=12 {
                let cc = Self::to_chunk(IVec3 {
                    x: Self::wrap_block(ax + dx),
                    y: 0,
                    z: Self::wrap_block(az + dz),
                });
                columns.insert((cc.x, cc.z));
            }
        }
        for (cx, cz) in columns {
            if preserve_edited
                && (CY_MIN..=CY_MAX).any(|cy| {
                    self.edited.contains(&ChunkCoord {
                        x: cx,
                        y: cy,
                        z: cz,
                    })
                })
            {
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
                if self.apply_settlement_growth_to_chunk(cc, &mut chunk) {
                    self.store.insert(chunk);
                    self.dirty_chunk_and_resident_neighbours(cc);
                    self.shadow.refill_cols.insert((cc.x, cc.z));
                }
            }
        }
    }

    pub(super) fn refresh_resident_settlement_growth(&mut self, ax: i32, az: i32) {
        self.materialize_resident_settlement_growth(ax, az, true);
    }

    pub(super) fn refresh_all_resident_settlement_growth(&mut self) {
        let anchors: Vec<(i32, i32)> = self.villages.keys().copied().collect();
        for (ax, az) in anchors {
            self.refresh_resident_settlement_growth(ax, az);
        }
    }

    pub(super) fn promote_village(&mut self, ax: i32, az: i32, tier: u8) -> bool {
        let tier = tier.min(3);
        let changed = {
            let state = self.village_state_mut(ax, az);
            if tier <= state.tier {
                false
            } else {
                state.tier = tier;
                state.progress = 0;
                true
            }
        };
        if changed {
            self.rebuild_road_routes();
            self.refresh_resident_roads();
            // Promotion may share chunks with its own palisade edits. Materialize
            // there too, but the overlay only fills replaceable cells and therefore
            // never overwrites a player's solid blocks.
            self.materialize_resident_settlement_growth(ax, az, false);
        }
        changed
    }

    fn village_state_mut(&mut self, ax: i32, az: i32) -> &mut VillageState {
        // #179: canonical settlement key on the torus.
        self.villages
            .entry((Self::wrap_block(ax), Self::wrap_block(az)))
            .or_default()
    }

    pub(super) fn note_village_torch(&mut self, place: IVec3) -> bool {
        let Some((_typ, ax, az)) = worldgen::worldgen_settlement_near(
            place.x,
            place.z,
            32,
            self.seed,
        ) else {
            self.toast("This torch makes a safe pocket. A village ward needs eight torches around a settlement.");
            return false;
        };
        let (lights, completed_now) = {
            let state = self.village_state_mut(ax, az);
            let before = state.lights;
            state.lights = state.lights.saturating_add(1).min(Self::VILLAGE_WARD_LIGHTS);
            (state.lights, before < Self::VILLAGE_WARD_LIGHTS && state.lights == Self::VILLAGE_WARD_LIGHTS)
        };
        if completed_now {
            self.restore_village_ward(ax, az);
            self.toast("The village light ward flares to life — the Grey retreats and the music lifts!");
        } else if lights < Self::VILLAGE_WARD_LIGHTS {
            self.toast(&format!(
                "Village light ward: {}/{} torches.",
                lights,
                Self::VILLAGE_WARD_LIGHTS
            ));
        } else {
            self.toast("This village's light ward is already shining.");
        }
        true
    }

    pub(super) fn restore_village_ward(&mut self, ax: i32, az: i32) {
        let center = Self::to_chunk(IVec3 { x: ax, y: 0, z: az });
        // Terrain saturation blends four neighbouring region corners. Restoring the
        // surrounding 3x3 keeps an entire settlement colourful even on a boundary.
        for dz in -1..=1 {
            for dx in -1..=1 {
                self.restore_region(ChunkCoord {
                    x: center.x + dx * KREGION_CHUNKS,
                    y: 0,
                    z: center.z + dz * KREGION_CHUNKS,
                });
            }
        }
    }

    pub(super) fn try_village_donation(&mut self, idx: usize) -> bool {
        let npc_id = self.creatures[idx].npc_id;
        let held = match self.inv.as_ref() {
            Some(i) => i.get(self.selected as usize),
            None => return false,
        };
        if held.item == 0 {
            self.toast("Hold the material you want to donate, then ask again.");
            return true;
        }
        let in_name = self.item_name(held.item);
        let (ax, az) = (self.creatures[idx].home_x, self.creatures[idx].home_z);
        if self.settlement_is_procedural_city(ax, az) {
            self.toast("This city is already complete — trade with its artisans instead!");
            return true;
        }
        match npc_id {
            4 => {
                let is_log =
                    in_name == "oak_log" || in_name == "birch_log" || in_name == "pine_log";
                if !is_log {
                    self.toast("Woodcutter: I need oak, birch, or pine logs.");
                    return true;
                }
                if self.raw_village_tier(ax, az) >= 2 {
                    self.toast("Woodcutter: our stone walls need no more logs.");
                    return true;
                }
                if held.count < 2 {
                    self.toast("Woodcutter: bring me more logs for the wall.");
                    return true;
                }
                let cells = (held.count as i32) / 2;
                let built = self.build_palisade_segment(ax, az, cells, Self::WALL_WOOD);
                if built > 0 {
                    if let Some(inv) = self.inv.as_mut() {
                        inv.remove_item(held.item, (built * 2) as u16);
                    }
                    let pv = self.player_voxel();
                    self.fx(1, pv, 0);
                    let total = self.count_palisade_cells(ax, az, Self::WALL_WOOD);
                    let vs = self.village_state_mut(ax, az);
                    vs.wood_cells = total;
                    let complete = total >= Self::PALISADE_CELLS && vs.tier < 1;
                    if complete {
                        self.promote_village(ax, az, 1);
                        self.toast("Woodcutter: our wall is complete! Ask Bria the mason to make it stone.");
                    } else {
                        self.toast("Woodcutter: the village wall grows!");
                    }
                } else {
                    let total = self.count_palisade_cells(ax, az, Self::WALL_WOOD)
                        + self.count_palisade_cells(ax, az, Self::WALL_STONE);
                    if total >= Self::PALISADE_CELLS && self.raw_village_tier(ax, az) < 1 {
                        self.promote_village(ax, az, 1);
                    }
                    self.toast("Woodcutter: our palisade is complete!");
                }
                true
            }
            5 => {
                let is_stone =
                    in_name == "stone_brick" || in_name == "cobblestone" || in_name == "stone";
                if !is_stone {
                    self.toast("Stone Mason: I need stone, cobblestone, or stone bricks.");
                    return true;
                }
                let tier = self
                    .villages
                    .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
                    .map(|v| v.tier)
                    .unwrap_or(0);
                if tier < 1 {
                    self.toast("Mason: build Finn's wooden wall first, then I can make it stone.");
                    return true;
                }
                if tier >= 2 {
                    self.toast("Mason: the stonework is done. Speak to Dov the blacksmith next.");
                    return true;
                }
                const STONE_NEEDED: i32 = 16;
                let contributed = self
                    .villages
                    .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
                    .map(|v| v.progress)
                    .unwrap_or(0);
                let take = (held.count as i32).min((STONE_NEEDED - contributed).max(0));
                if let Some(inv) = self.inv.as_mut() {
                    inv.remove_item(held.item, take as u16);
                }
                let progress = {
                    let vs = self.village_state_mut(ax, az);
                    vs.progress += take;
                    vs.progress
                };
                let pv = self.player_voxel();
                self.fx(1, pv, 0);
                if progress >= STONE_NEEDED {
                    self.upgrade_palisade_material(ax, az, Self::WALL_STONE);
                    self.stamp_stone_accents(ax, az);
                    self.promote_village(ax, az, 2);
                    self.toast(
                        "Mason: cut stone and proud towers! Now Dov can forge the iron gate.",
                    );
                } else {
                    self.toast(&format!(
                        "Mason: good stone. ({}/{} for the upgrade)",
                        progress, STONE_NEEDED
                    ));
                }
                true
            }
            6 => {
                let is_iron = in_name == "iron_ingot" || in_name == "raw_iron";
                if !is_iron {
                    self.toast("Blacksmith: I need iron ingots or raw iron.");
                    return true;
                }
                let tier = self
                    .villages
                    .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
                    .map(|v| v.tier)
                    .unwrap_or(0);
                if tier < 2 {
                    self.toast("Blacksmith: get Bria to finish the stonework, then bring me iron.");
                    return true;
                }
                if tier >= 3 {
                    self.toast(
                        "Blacksmith: the gate is hung and the lamps are lit. Our town is safe!",
                    );
                    return true;
                }
                const IRON_NEEDED: i32 = 8;
                let contributed = self
                    .villages
                    .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
                    .map(|v| v.progress)
                    .unwrap_or(0);
                let take = (held.count as i32).min((IRON_NEEDED - contributed).max(0));
                if let Some(inv) = self.inv.as_mut() {
                    inv.remove_item(held.item, take as u16);
                }
                let progress = {
                    let vs = self.village_state_mut(ax, az);
                    vs.progress += take;
                    vs.progress
                };
                let pv = self.player_voxel();
                self.fx(1, pv, 0);
                if progress >= IRON_NEEDED {
                    self.stamp_iron_gate_and_lamps(ax, az);
                    self.promote_village(ax, az, 3);
                    self.toast("Blacksmith: iron gate hung, lamps lit! Our town will shine through the night.");
                } else {
                    self.toast(&format!(
                        "Blacksmith: fine iron. ({}/{} for the gate)",
                        progress, IRON_NEEDED
                    ));
                }
                true
            }
            _ => false,
        }
    }

    pub(super) fn village_protects(&self, wx: i32, wz: i32) -> Option<(i32, i32)> {
        const R: i32 = World::PALISADE_R;
        for (&(ax, az), vs) in self.villages.iter() {
            if vs.tier < 1 {
                continue;
            }
            let dx = Self::wrap_signed_block(wx - ax);
            let dz = Self::wrap_signed_block(wz - az);
            if dx > -R && dx < R && dz > -R && dz < R {
                return Some((ax, az));
            }
        }
        None
    }

    fn village_status_near(
        &self,
        wx: i32,
        wz: i32,
        radius: i32,
    ) -> Option<(i32, i32, u8, i32, i32, i32, i32)> {
        let mut best: Option<(i32, i32)> = None;
        let mut best_d2 = (radius as i64) * (radius as i64);
        for &(ax, az) in self.villages.keys() {
            let d2 = (Self::wrap_signed_block(ax - wx) as i64).pow(2)
                + (Self::wrap_signed_block(az - wz) as i64).pow(2);
            if d2 <= best_d2 {
                best_d2 = d2;
                best = Some((ax, az));
            }
        }
        if let Some((_styp, sax, saz)) =
            worldgen::worldgen_settlement_near(wx, wz, radius, self.seed)
        {
            let d2 = (Self::wrap_signed_block(sax - wx) as i64).pow(2)
                + (Self::wrap_signed_block(saz - wz) as i64).pow(2);
            if d2 <= best_d2 {
                best = Some((sax, saz));
            }
        }
        let (ax, az) = best?;
        let vs = self
            .villages
            .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
            .cloned()
            .unwrap_or_default();
        let tier = self.effective_village_tier(ax, az);
        let (progress_needed, progress) = match tier {
            1 => (16, vs.progress),
            2 => (8, vs.progress),
            _ => (0, 0),
        };
        Some((
            ax,
            az,
            tier,
            vs.wood_cells,
            Self::PALISADE_CELLS,
            progress,
            progress_needed,
        ))
    }

    pub fn debug_build_palisade(&mut self, cx: i32, cz: i32, cells: i32) -> i32 {
        self.build_palisade_segment(cx, cz, cells, Self::WALL_WOOD)
    }

    pub fn debug_village_tier(&self, ax: i32, az: i32) -> i32 {
        self.effective_village_tier(ax, az) as i32
    }

    pub fn debug_village_raw_tier(&self, ax: i32, az: i32) -> i32 {
        self.raw_village_tier(ax, az) as i32
    }

    pub fn debug_settlement_class(&self, ax: i32, az: i32) -> i32 {
        match self.settlement_class_at(ax, az) {
            SettlementClass::Village => 0,
            SettlementClass::Town => 1,
            SettlementClass::City => 2,
        }
    }

    pub fn debug_village_progress(&self, ax: i32, az: i32) -> i32 {
        self.villages
            .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
            .map(|v| v.progress)
            .unwrap_or(0)
    }

    pub fn debug_village_wood_cells(&self, ax: i32, az: i32) -> i32 {
        self.villages
            .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
            .map(|v| v.wood_cells)
            .unwrap_or(0)
    }

    pub fn debug_village_lights(&self, ax: i32, az: i32) -> u8 {
        self.villages
            .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
            .map(|v| v.lights)
            .unwrap_or(0)
    }

    pub fn debug_set_village_lights(&mut self, ax: i32, az: i32, lights: u8) {
        self.village_state_mut(ax, az).lights = lights.min(Self::VILLAGE_WARD_LIGHTS);
    }

    pub fn debug_note_village_torch(&mut self, x: i32, y: i32, z: i32) -> bool {
        self.note_village_torch(IVec3 { x, y, z })
    }

    pub fn debug_palisade_cells_total() -> i32 {
        Self::PALISADE_CELLS
    }

    pub fn debug_count_wall(&self, ax: i32, az: i32, wall: BlockId) -> i32 {
        self.count_palisade_cells(ax, az, wall)
    }

    pub fn debug_village_protects(&self, wx: i32, wz: i32) -> bool {
        self.village_protects(wx, wz).is_some()
    }

    pub(super) fn maintain_villagers(&mut self, dt: f32) {
        if self.gen.is_none() || self.extra.is_none() || self.store.resident_count() < 20 {
            return;
        }
        self.villager_timer -= dt;
        if self.villager_timer > 0.0 {
            return;
        }
        self.villager_timer = 2.0;
        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);
        let Some((_typ, ax, az)) =
            worldgen::worldgen_settlement_near(px, pz, 80, self.seed)
        else {
            return;
        };
        let ay = worldgen::worldgen_surface_height(ax, az, self.seed);
        if !self.store.is_resident(Self::to_chunk(IVec3 {
            x: ax,
            y: ay,
            z: az,
        })) {
            return;
        }

        let budget = self.villager_roster_budget(self.settlement_class_at(ax, az), ax, az);
        if budget > 0 {
            self.spawn_villager_at(ax, ay, az, budget);
        }
    }

    fn villager_roster_budget(&self, class: SettlementClass, ax: i32, az: i32) -> i32 {
        let ax = Self::wrap_block(ax);
        let az = Self::wrap_block(az);
        let have = self.creatures.iter().filter(|c| c.model == 20).count() as i32;
        let at_home = self
            .creatures
            .iter()
            .filter(|c| c.model == 20 && c.home_x == ax && c.home_z == az)
            .count() as i32;
        let target = match class {
            SettlementClass::Village => Self::VILLAGE_VILLAGERS,
            SettlementClass::Town => Self::TOWN_VILLAGERS,
            SettlementClass::City => Self::CITY_VILLAGERS,
        };
        (target - at_home)
            .min(Self::VILLAGER_GLOBAL_CAP - have)
            .max(0)
    }

    // #240: kid-friendly villager given names, indexed by the stable villager
    // hash. Order matters: changing it renames every villager in every world.
    const VILLAGER_NAMES: [&'static str; 20] = [
        "Pip", "Juno", "Milo", "Fern", "Tilly", "Otto", "Hazel", "Finn", "Poppy", "Gus",
        "Ivy", "Remy", "Sage", "Nell", "Bodi", "Lark", "Coco", "Ziggy", "Maple", "Rue",
    ];

    // #234: the kid-facing title for a profession. The look-at nameplate must say
    // what the person DOES (the trade sheet and dialogue key off npc_id), not
    // which creature kind the spawn pool happened to pick — a "Trader"-labelled
    // villager trading like a Woodcutter reads as a lie.
    pub(super) fn profession_title(npc_id: i32) -> &'static str {
        match npc_id {
            1 => "Elder",
            2 => "Builder",
            3 => "Herbalist",
            4 => "Woodcutter",
            5 => "Stone Mason",
            6 => "Blacksmith",
            _ => "",
        }
    }

    // Profession (npc_id) for the villager at `idx` within a single settlement.
    //
    // The trade roles form a tool chain: Woodcutter (4, wood) -> Stone Mason (5, stone)
    // -> Blacksmith (6, iron). A higher tier is useless without the ones below it, so a
    // small village must never hand the player a stranded high tier. Roles 1..=3 (Elder,
    // Builder, Herbalist) are social / quest givers and carry no chain requirement.
    //
    // Villages fill from the bottom of the chain up, interleaving social roles so a
    // higher trade tier only appears at a later index than every lower tier. The result
    // is always a chain prefix: a 1-villager hamlet has only a Woodcutter, and stone /
    // iron arrive only once the settlement is large enough to have the tiers below them.
    //
    // Cities are the place to complete progression, so they front-load the full chain
    // (wood, stone, iron in the first three slots); a city reliably reaches the cap, so
    // all three tiers are guaranteed present.
    //
    // Both orders are pure functions of (is_city, idx): deterministic, no RNG, so the
    // same villager index in the same settlement always gets the same role.
    pub(super) fn villager_npc_for_index(is_city: bool, idx: i32) -> i32 {
        // npc_id roster: 1 Elder, 2 Builder, 3 Herbalist, 4 Woodcutter (wood),
        // 5 Stone Mason (stone), 6 Blacksmith (iron).
        let city_order = [4, 5, 6, 1, 2, 3];
        let village_order = [4, 1, 5, 2, 6, 3];
        let order = if is_city { &city_order } else { &village_order };
        let i = if idx < 0 { 0 } else { idx as usize };
        // Beyond the roster (a settlement bigger than 6 villagers) we cycle, which only
        // ever repeats roles whose prerequisites are already present, so the prefix
        // property still holds.
        order[i % order.len()]
    }

    pub(super) fn spawn_villager_at(&mut self, ax: i32, ay: i32, az: i32, budget: i32) -> i32 {
        let pool: Vec<CreatureDefX> = match self.extra {
            Some(x) => x
                .creatures()
                .iter()
                .filter(|d| d.model == 20)
                .cloned()
                .collect(),
            None => return 0,
        };
        if pool.is_empty() || budget <= 0 {
            return 0;
        }
        // Only a procedural city uses the city-first role order. A promoted
        // village grows to six without renaming/reordering its existing people.
        let is_city = self.settlement_is_procedural_city(ax, az);
        // Index of the next villager within THIS settlement: count the ones already
        // anchored at this home. Spawning is incremental, so this keeps the per-settlement
        // role sequence stable as the village fills up over time.
        let mut idx_in_settlement = self
            .creatures
            .iter()
            .filter(|c| {
                c.model == 20
                    && c.home_x == Self::wrap_block(ax)
                    && c.home_z == Self::wrap_block(az)
            })
            .count() as i32;
        let n = budget.min(1 + if self.rand01() < 0.5 { 1 } else { 0 });
        let mut made = 0;
        for _ in 0..n {
            let ox = Self::wrap_pos_f(ax as f32 + (self.rand01() * 5.0 - 2.5));
            let oz = Self::wrap_pos_f(az as f32 + (self.rand01() * 5.0 - 2.5));
            let gy = self.floor_below(Self::ifloor(ox), ay + 4, Self::ifloor(oz));
            if gy == NO_FLOOR {
                continue;
            }
            if self.block_at(IVec3 {
                x: Self::ifloor(ox),
                y: gy + 1,
                z: Self::ifloor(oz),
            }) == WATER
            {
                continue;
            }
            let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
            let d = &pool[pick];
            let mut c = Creature::default();
            c.pos = V3::new(ox, gy as f32, oz);
            c.yaw = self.rand01() * 6.2831853;
            c.model = d.model;
            let vidx = idx_in_settlement;
            c.npc_id = Self::villager_npc_for_index(is_city, idx_in_settlement);
            c.home_x = Self::wrap_block(ax);
            c.home_z = Self::wrap_block(az);
            c.name = d.name.clone();
            // #212: villagers moved at half speed and read as slow-motion. Full def
            // speed (and a brisker fallback) so their walk looks like walking.
            c.speed = if d.move_speed > 0.0 {
                d.move_speed
            } else {
                1.5
            };
            c.hp = if d.max_health > 0 {
                d.max_health as i32
            } else {
                20
            };
            // #201: stable per-villager seed (home + settlement index + world seed)
            // so a villager's look never changes as it wanders. It drives a little
            // height variety and a biome-tinted, per-individual clothing color, so a
            // crowd reads as individuals and the village's culture (desert robes, snow
            // parkas, forest greens) shows. The renderer derives skin/hair from this
            // same colour, so those vary per villager too.
            let mut vh = (Self::wrap_block(ax) as u32 as u64).wrapping_mul(0x9E3779B97F4A7C15)
                ^ (Self::wrap_block(az) as u32 as u64).wrapping_mul(0xC2B2AE3D27D4EB4F)
                ^ (vidx as u64).wrapping_mul(0x165667B19E3779F9)
                ^ self.seed;
            vh ^= vh >> 30;
            vh = vh.wrapping_mul(0xBF58476D1CE4E5B9);
            vh ^= vh >> 27;
            vh = vh.wrapping_mul(0x94D049BB133111EB);
            vh ^= vh >> 31;
            // #212: wider height spread (0.80..1.16) so short and tall villagers read
            // clearly, not just a hair different.
            c.scale = 0.80 + ((vh >> 8) & 0xFF) as f32 / 255.0 * 0.36;
            // #240: a stable given name off the same hash, so the nameplate can
            // say "Pip the Woodcutter" and Pip stays Pip forever.
            c.given = Self::VILLAGER_NAMES[((vh >> 40) % Self::VILLAGER_NAMES.len() as u64) as usize]
                .to_string();
            c.color = self.villager_clothing_color(ax, az, vh);
            c.wander = 1.0 + self.rand01() * 2.0;
            // #243: natural villagers use the same full-body clearance as every other
            // creature. Keep the resident by relocating nearby when possible; a rejected
            // candidate must not consume its profession slot.
            if self.creature_body_blocked(c.pos.x, gy, c.pos.z, c.scale)
                && !self.creature_unstick(&mut c)
            {
                continue;
            }
            let feet = Self::ifloor(c.pos.y + 0.01);
            if self.block_at(IVec3 {
                x: Self::ifloor(c.pos.x),
                y: feet + 1,
                z: Self::ifloor(c.pos.z),
            }) == WATER
            {
                continue;
            }
            idx_in_settlement += 1;
            self.creatures.push(c);
            made += 1;
        }
        made
    }

    // #201: per-villager clothing colour, flavoured by the home biome (culture) and
    // varied per individual by the stable villager hash vh. Kid-friendly palettes.
    fn villager_clothing_color(&self, ax: i32, az: i32, vh: u64) -> V3 {
        let biome = worldgen::worldgen_biome_at(ax, az, self.seed);
        // (hue centre, hue spread, value, paleness-toward-white) per biome.
        let (hc, hspread, val, pale): (f32, f32, f32, f32) = match biome {
            3 | 6 => (0.09, 0.06, 0.85, 0.25), // desert / beach: warm tan, ochre robes
            4 => (0.58, 0.08, 0.95, 0.55),     // snowy: pale blue / white parkas
            1 | 0 => (0.30, 0.14, 0.70, 0.12), // forest / plains: greens
            5 => (0.42, 0.08, 0.60, 0.15),     // swamp: muted teal / olive
            2 => (0.07, 0.05, 0.60, 0.30),     // mountains: grey-brown wool
            _ => (0.10, 0.16, 0.78, 0.15),
        };
        // #225 SETTLEMENT SIGNATURE: every town shifts the biome hue by its own
        // stable amount (hashed from the anchor), so Giggle Grove's people dress
        // in one colour family and the next village over in another, while both
        // still read as their biome's culture. The signature also skews value so
        // some towns dress bright and some muted.
        let mut sh = (Self::wrap_block(ax) as u32 as u64).wrapping_mul(0x9E3779B97F4A7C15)
            ^ (Self::wrap_block(az) as u32 as u64).wrapping_mul(0x165667B19E3779F9)
            ^ self.seed.rotate_left(17);
        sh ^= sh >> 31;
        sh = sh.wrapping_mul(0xBF58476D1CE4E5B9);
        sh ^= sh >> 29;
        let sig_hue = ((sh & 0xFFFF) as f32 / 65535.0 - 0.5) * 0.22;      // +/-0.11 town hue shift
        let sig_val = (((sh >> 16) & 0xFF) as f32 / 255.0 - 0.5) * 0.18;  // bright vs muted town
        // #225 stronger INDIVIDUAL randomness: wider per-villager hue/value jitter
        // inside the town band (was 1.0x spread / 0.28 value swing).
        let r0 = (vh & 0xFFFF) as f32 / 65535.0;
        let r1 = ((vh >> 16) & 0xFFFF) as f32 / 65535.0;
        let h = (hc + sig_hue + (r0 - 0.5) * hspread * 1.5).rem_euclid(1.0);
        let v = (val + sig_val + (r1 - 0.5) * 0.36).clamp(0.30, 1.0);
        let base = Self::hue_rgb(h);
        // Mix the lit hue toward white by `pale` (snow parkas read pale, deserts warm).
        let lit = V3::new(base.x * v, base.y * v, base.z * v);
        V3::new(
            lit.x + (v - lit.x) * pale,
            lit.y + (v - lit.y) * pale,
            lit.z + (v - lit.z) * pale,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settlement(seed: u64, city: bool) -> (i32, i32) {
        for z in (-4096..4096).step_by(64) {
            for x in (-4096..4096).step_by(64) {
                let (typ, ax, az, _) = worldgen::worldgen_structure_near(x, z, seed);
                if (city && worldgen::worldgen_is_city(typ)) || (!city && typ == 8) {
                    return (ax, az);
                }
            }
        }
        panic!("seed {seed} has no requested settlement");
    }

    fn generated_block(w: &World<'_>, x: i32, y: i32, z: i32) -> BlockId {
        let cc = World::canon_chunk(World::to_chunk(IVec3 { x, y, z }));
        let chunk = w.gen_chunk(cc).expect("terrain generator");
        chunk.get(
            World::mod16(x) as usize,
            World::mod16(y) as usize,
            World::mod16(z) as usize,
        )
    }

    fn add_residents(w: &mut World<'_>, is_city: bool, ax: i32, az: i32, count: i32) {
        let start = w
            .creatures
            .iter()
            .filter(|c| {
                c.model == 20
                    && c.home_x == World::wrap_block(ax)
                    && c.home_z == World::wrap_block(az)
            })
            .count() as i32;
        for i in start..(start + count) {
            let mut c = Creature::default();
            c.model = 20;
            c.npc_id = World::villager_npc_for_index(is_city, i);
            c.home_x = World::wrap_block(ax);
            c.home_z = World::wrap_block(az);
            w.creatures.push(c);
        }
    }

    #[test]
    fn roster_budget_fills_city_and_village_once() {
        let mut city = World::new(None);
        let seam_home = (-9, -40);
        assert_eq!(
            city.villager_roster_budget(SettlementClass::City, seam_home.0, seam_home.1),
            6
        );
        add_residents(&mut city, true, seam_home.0, seam_home.1, 2);
        assert_eq!(
            city.villager_roster_budget(SettlementClass::City, seam_home.0, seam_home.1),
            4
        );
        add_residents(&mut city, true, seam_home.0, seam_home.1, 2);
        assert_eq!(
            city.villager_roster_budget(SettlementClass::City, seam_home.0, seam_home.1),
            2
        );
        add_residents(&mut city, true, seam_home.0, seam_home.1, 2);
        assert_eq!(
            city.villager_roster_budget(
                SettlementClass::City,
                World::wrap_block(seam_home.0),
                World::wrap_block(seam_home.1),
            ),
            0,
            "canonical and negative torus anchors are one roster"
        );
        assert_eq!(
            city.creatures.iter().map(|c| c.npc_id).collect::<Vec<_>>(),
            vec![4, 5, 6, 1, 2, 3],
            "city fills the complete deterministic profession chain"
        );

        city.creatures.clear(); // load clears transient residents
        assert_eq!(
            city.villager_roster_budget(SettlementClass::City, seam_home.0, seam_home.1),
            6,
            "a loaded city refills its roster"
        );

        let mut village = World::new(None);
        add_residents(&mut village, false, 200, 300, 2);
        assert_eq!(
            village.villager_roster_budget(SettlementClass::Village, 200, 300),
            1
        );
        add_residents(&mut village, false, 200, 300, 1);
        assert_eq!(
            village.villager_roster_budget(SettlementClass::Village, 200, 300),
            0
        );
        assert_eq!(
            village
                .creatures
                .iter()
                .map(|c| c.npc_id)
                .collect::<Vec<_>>(),
            vec![4, 1, 5],
            "village stops at its smaller deterministic prefix"
        );
    }

    #[test]
    fn class_population_and_promoted_role_order_are_derived() {
        let seed = 11;
        let (vx, vz) = settlement(seed, false);
        let (cx, cz) = settlement(seed, true);
        let mut world = World::new(None);
        world.seed = seed;

        assert_eq!(world.settlement_class_at(vx, vz), SettlementClass::Village);
        assert_eq!(world.settlement_class_at(cx, cz), SettlementClass::City);
        assert_eq!(world.raw_village_tier(cx, cz), 0);
        assert_eq!(world.effective_village_tier(cx, cz), 3);

        world.villages.insert(
            (World::wrap_block(vx), World::wrap_block(vz)),
            VillageState {
                tier: 2,
                ..VillageState::default()
            },
        );
        assert_eq!(world.settlement_class_at(vx, vz), SettlementClass::Town);
        assert_eq!(
            world.villager_roster_budget(SettlementClass::Town, vx, vz),
            5
        );
        add_residents(&mut world, false, vx, vz, 5);
        assert_eq!(
            world.creatures.iter().map(|c| c.npc_id).collect::<Vec<_>>(),
            vec![4, 1, 5, 2, 6],
            "town adds Builder and Blacksmith without reordering village roles"
        );
        assert!(world.promote_village(vx, vz, 3));
        assert_eq!(world.settlement_class_at(vx, vz), SettlementClass::City);
        assert_eq!(
            world.villager_roster_budget(SettlementClass::City, vx, vz),
            1
        );
        add_residents(&mut world, false, vx, vz, 1);
        assert_eq!(
            world.creatures.last().unwrap().npc_id,
            3,
            "city adds Herbalist"
        );
        assert!(
            !world.promote_village(vx, vz, 1),
            "promotion cannot regress"
        );
        assert_eq!(world.raw_village_tier(vx, vz), 3);
    }

    #[test]
    fn natural_city_status_survives_structure_cell_boundaries() {
        let seed = 11;
        let (cx, cz) = settlement(seed, true);
        let probe = (-64..=64)
            .flat_map(|dz| (-64..=64).map(move |dx| (cx + dx, cz + dz)))
            .find(|&(x, z)| {
                let dx = (x - cx) as i64;
                let dz = (z - cz) as i64;
                if dx * dx + dz * dz > 64 * 64 {
                    return false;
                }
                let (_, old_x, old_z, _) = worldgen::worldgen_structure_near(x, z, seed);
                (old_x, old_z) != (cx, cz)
                    && worldgen::worldgen_settlement_near(x, z, 64, seed)
                        .map(|(_, ax, az)| (ax, az))
                        == Some((cx, cz))
            })
            .expect("city has an in-range probe across a structure-cell boundary");

        let mut world = World::new(Some(TerrainGen::new()));
        world.seed = seed;
        let status = world
            .village_status_near(probe.0, probe.1, 64)
            .expect("natural city remains visible across the cell boundary");
        assert_eq!((status.0, status.1, status.2), (cx, cz, 3));
    }

    #[test]
    fn town_and_city_generate_open_shops_around_real_stations() {
        let seed = 11;
        let (ax, az) = settlement(seed, false);
        let mut town = World::new(Some(TerrainGen::new()));
        town.init_world(seed);
        town.villages.insert(
            (World::wrap_block(ax), World::wrap_block(az)),
            VillageState {
                tier: 2,
                ..VillageState::default()
            },
        );

        let forge = (ax - 4, az - 4);
        let forge_y = worldgen::worldgen_surface_height(forge.0, forge.1, seed)
            .max(worldgen::worldgen_surface_height(
                forge.0 - 1,
                forge.1,
                seed,
            ))
            .max(7);
        assert_eq!(generated_block(&town, forge.0, forge_y + 1, forge.1), 59);
        assert_eq!(generated_block(&town, forge.0, forge_y + 3, forge.1 + 2), 8);
        assert_eq!(
            generated_block(&town, forge.0 - 1, forge_y + 1, forge.1),
            AIR
        );

        let herb = (ax + 4, az - 4);
        let herb_y = worldgen::worldgen_surface_height(herb.0, herb.1, seed)
            .max(worldgen::worldgen_surface_height(herb.0 - 1, herb.1, seed))
            .max(7);
        assert_ne!(
            generated_block(&town, herb.0, herb_y + 3, herb.1 + 2),
            24,
            "Town does not receive the City herbalist canopy"
        );

        town.villages
            .get_mut(&(World::wrap_block(ax), World::wrap_block(az)))
            .unwrap()
            .tier = 3;
        assert_eq!(
            generated_block(&town, herb.0, herb_y + 3, herb.1 + 2),
            24,
            "City adds the pitched herbalist canopy"
        );
    }
}
