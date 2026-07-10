use super::*;

// Living-villages (#95): per-settlement upgrade progress, keyed by settlement
// anchor. Blocks stay procedural/edited; this table is player progress.
#[derive(Clone, Default)]
pub(super) struct VillageState {
    pub(super) tier: u8,
    pub(super) wood_cells: i32,
    pub(super) progress: i32,
}

impl<'c> World<'c> {
    // The palisade / wall ring is an R-radius square centred on the settlement anchor.
    const PALISADE_R: i32 = 8;
    const PALISADE_CELLS: i32 = 8 * Self::PALISADE_R - 2;
    const WALL_WOOD: BlockId = 21; // oak_log
    const WALL_STONE: BlockId = 8; // stone_brick
    const IRON_GATE: BlockId = 53; // iron_bars
    const LAMP: BlockId = 35; // crystal_lamp

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

    fn stamp_town_expansion(&mut self, cx: i32, cz: i32, tier: u8) {
        let plots: &[(i32, i32)] = match tier {
            2 => &[(-13, -11), (13, 11)],
            3 => &[(13, -11), (-13, 11)],
            _ => &[],
        };
        for &(dx, dz) in plots {
            self.place_player_hut(cx + dx, cz + dz, tier);
        }
    }

    fn place_player_hut(&mut self, cx: i32, cz: i32, tier: u8) {
        let wall: BlockId = if tier >= 2 { Self::WALL_STONE } else { 4 };
        const FLOOR: BlockId = 4;
        const GLASS: BlockId = 25;
        const DOOR: BlockId = 33;
        const GLOW: BlockId = 7;
        let surf = worldgen::worldgen_surface_height(cx, cz, self.seed);
        if self.block_at(IVec3 {
            x: cx,
            y: surf,
            z: cz,
        }) == FLOOR
            && self.block_at(IVec3 {
                x: cx,
                y: surf + 1,
                z: cz,
            }) == GLOW
        {
            return;
        }
        for dz in -2..=2 {
            for dx in -2..=2 {
                let wx = cx + dx;
                let wz = cz + dz;
                let s = worldgen::worldgen_surface_height(wx, wz, self.seed);
                self.set_block_internal(IVec3 { x: wx, y: s, z: wz }, FLOOR);
                let edge = dx == -2 || dx == 2 || dz == -2 || dz == 2;
                if edge {
                    if dz == 2 && dx == 0 {
                        self.set_block_internal(
                            IVec3 {
                                x: wx,
                                y: s + 1,
                                z: wz,
                            },
                            DOOR,
                        );
                        self.set_block_internal(
                            IVec3 {
                                x: wx,
                                y: s + 2,
                                z: wz,
                            },
                            DOOR,
                        );
                        continue;
                    }
                    let win = (dx == 0 || dz == 0) && !(dz == 2 && dx == 0);
                    for dy in 1..=3 {
                        let b = if win && dy == 2 { GLASS } else { wall };
                        self.set_block_internal(
                            IVec3 {
                                x: wx,
                                y: s + dy,
                                z: wz,
                            },
                            b,
                        );
                    }
                    self.set_block_internal(
                        IVec3 {
                            x: wx,
                            y: s + 4,
                            z: wz,
                        },
                        wall,
                    );
                }
            }
        }
        for dz in -2..=2 {
            for dx in -2..=2 {
                let wx = cx + dx;
                let wz = cz + dz;
                let s = worldgen::worldgen_surface_height(wx, wz, self.seed);
                self.set_block_internal(
                    IVec3 {
                        x: wx,
                        y: s + 4,
                        z: wz,
                    },
                    wall,
                );
            }
        }
        self.set_block_internal(
            IVec3 {
                x: cx,
                y: surf + 1,
                z: cz,
            },
            GLOW,
        );
    }

    fn village_state_mut(&mut self, ax: i32, az: i32) -> &mut VillageState {
        // #179: canonical settlement key on the torus.
        self.villages
            .entry((Self::wrap_block(ax), Self::wrap_block(az)))
            .or_default()
    }

    pub(super) fn try_village_donation(&mut self, idx: usize) -> bool {
        let held = match self.inv.as_ref() {
            Some(i) => i.get(self.selected as usize),
            None => return false,
        };
        if held.item == 0 {
            return false;
        }
        let in_name = self.item_name(held.item);
        let npc_id = self.creatures[idx].npc_id;
        let (ax, az) = (self.creatures[idx].home_x, self.creatures[idx].home_z);
        match npc_id {
            4 => {
                let is_log =
                    in_name == "oak_log" || in_name == "birch_log" || in_name == "pine_log";
                if !is_log {
                    return false;
                }
                if held.count < 2 {
                    self.toast("Woodcutter: bring me more logs for the wall.");
                    return true;
                }
                let cells = (held.count.min(8) as i32) / 2;
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
                    if total >= Self::PALISADE_CELLS && vs.tier < 1 {
                        vs.tier = 1;
                        self.toast("Woodcutter: our wall is complete! Ask Bria the mason to make it stone.");
                    } else {
                        self.toast("Woodcutter: the village wall grows!");
                    }
                } else {
                    let total = self.count_palisade_cells(ax, az, Self::WALL_WOOD)
                        + self.count_palisade_cells(ax, az, Self::WALL_STONE);
                    let vs = self.village_state_mut(ax, az);
                    if total >= Self::PALISADE_CELLS && vs.tier < 1 {
                        vs.tier = 1;
                    }
                    self.toast("Woodcutter: our palisade is complete!");
                }
                true
            }
            5 => {
                let is_stone =
                    in_name == "stone_brick" || in_name == "cobblestone" || in_name == "stone";
                if !is_stone {
                    return false;
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
                let take = (held.count as i32).min(STONE_NEEDED);
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
                    self.stamp_town_expansion(ax, az, 2);
                    let vs = self.village_state_mut(ax, az);
                    vs.tier = 2;
                    vs.progress = 0;
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
                    return false;
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
                let take = (held.count as i32).min(IRON_NEEDED);
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
                    self.stamp_town_expansion(ax, az, 3);
                    let vs = self.village_state_mut(ax, az);
                    vs.tier = 3;
                    vs.progress = 0;
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
        let (styp, sax, saz, _sy) = worldgen::worldgen_structure_near(wx, wz, self.seed);
        if styp == 8 || worldgen::worldgen_is_city(styp) {
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
        let (progress_needed, progress) = match vs.tier {
            1 => (16, vs.progress),
            2 => (8, vs.progress),
            _ => (0, 0),
        };
        Some((
            ax,
            az,
            vs.tier,
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
        self.villages
            .get(&(Self::wrap_block(ax), Self::wrap_block(az)))
            .map(|v| v.tier as i32)
            .unwrap_or(0)
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
        const KVCAP: i32 = 6;
        let mut have = self.creatures.iter().filter(|c| c.model == 20).count() as i32;
        if have >= KVCAP {
            return;
        }
        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);
        let mut dz = -128;
        while dz <= 128 {
            let mut dx = -128;
            while dx <= 128 {
                if have >= KVCAP {
                    return;
                }
                let (typ, ax, az, ay) =
                    worldgen::worldgen_structure_near(px + dx, pz + dz, self.seed);
                if typ == 0 {
                    dx += 64;
                    continue;
                }
                let ddx = Self::wrap_signed_f(ax as f32 - self.pos.x);
                let ddz = Self::wrap_signed_f(az as f32 - self.pos.z);
                if ddx * ddx + ddz * ddz > 80.0 * 80.0 {
                    dx += 64;
                    continue;
                }
                if !self.store.is_resident(Self::to_chunk(IVec3 {
                    x: ax,
                    y: ay,
                    z: az,
                })) {
                    dx += 64;
                    continue;
                }
                let present = self.creatures.iter().any(|c| {
                    c.model == 20
                        && Self::wrap_signed_f(c.pos.x - ax as f32).abs() < 10.0
                        && Self::wrap_signed_f(c.pos.z - az as f32).abs() < 10.0
                });
                if present {
                    dx += 64;
                    continue;
                }
                have += self.spawn_villager_at(ax, ay, az, KVCAP - have);
                dx += 64;
            }
            dz += 64;
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
        // Is this settlement a city? Cities host the full profession chain; villages get
        // an ordered chain prefix. The structure type comes straight from worldgen so the
        // worldgen city upgrade and the profession assignment stay in sync (one source of
        // truth for "city vs village").
        let (styp, _sx, _sz, _sy) = worldgen::worldgen_structure_near(ax, az, self.seed);
        let is_city = worldgen::worldgen_is_city(styp);
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
            idx_in_settlement += 1;
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
            c.color = self.villager_clothing_color(ax, az, vh);
            c.wander = 1.0 + self.rand01() * 2.0;
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
