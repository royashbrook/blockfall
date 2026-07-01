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

    fn build_palisade_segment(&mut self, cx: i32, cz: i32, cells_to_build: i32, wall: BlockId) -> i32 {
        let mut built = 0;
        for (dx, dz) in Self::palisade_ring_cells() {
            if built >= cells_to_build {
                break;
            }
            let wx = cx + dx;
            let wz = cz + dz;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            if self.block_at(IVec3 { x: wx, y: surf + 1, z: wz }) == wall {
                continue;
            }
            self.set_block_internal(IVec3 { x: wx, y: surf + 1, z: wz }, wall);
            self.set_block_internal(IVec3 { x: wx, y: surf + 2, z: wz }, wall);
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
            if self.block_at(IVec3 { x: wx, y: surf + 1, z: wz }) == wall {
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
            let here = self.block_at(IVec3 { x: wx, y: surf + 1, z: wz });
            if here == Self::WALL_WOOD || here == Self::WALL_STONE {
                if here != wall {
                    self.set_block_internal(IVec3 { x: wx, y: surf + 1, z: wz }, wall);
                    self.set_block_internal(IVec3 { x: wx, y: surf + 2, z: wz }, wall);
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
            let p = IVec3 { x: wx, y: surf + 3, z: wz };
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
                let p = IVec3 { x: wx, y: surf + dy, z: wz };
                if self.block_at(p) == AIR || self.block_at(p) == Self::WALL_STONE || self.block_at(p) == Self::WALL_WOOD {
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
            self.set_block_internal(IVec3 { x: wx, y: surf + 1, z: wz }, Self::IRON_GATE);
            self.set_block_internal(IVec3 { x: wx, y: surf + 2, z: wz }, Self::IRON_GATE);
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
            let p = IVec3 { x: wx, y: surf + 3, z: wz };
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
        if self.block_at(IVec3 { x: cx, y: surf, z: cz }) == FLOOR
            && self.block_at(IVec3 { x: cx, y: surf + 1, z: cz }) == GLOW
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
                        self.set_block_internal(IVec3 { x: wx, y: s + 1, z: wz }, DOOR);
                        self.set_block_internal(IVec3 { x: wx, y: s + 2, z: wz }, DOOR);
                        continue;
                    }
                    let win = (dx == 0 || dz == 0) && !(dz == 2 && dx == 0);
                    for dy in 1..=3 {
                        let b = if win && dy == 2 { GLASS } else { wall };
                        self.set_block_internal(IVec3 { x: wx, y: s + dy, z: wz }, b);
                    }
                    self.set_block_internal(IVec3 { x: wx, y: s + 4, z: wz }, wall);
                }
            }
        }
        for dz in -2..=2 {
            for dx in -2..=2 {
                let wx = cx + dx;
                let wz = cz + dz;
                let s = worldgen::worldgen_surface_height(wx, wz, self.seed);
                self.set_block_internal(IVec3 { x: wx, y: s + 4, z: wz }, wall);
            }
        }
        self.set_block_internal(IVec3 { x: cx, y: surf + 1, z: cz }, GLOW);
    }

    fn village_state_mut(&mut self, ax: i32, az: i32) -> &mut VillageState {
        self.villages.entry((ax, az)).or_default()
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
                let is_log = in_name == "oak_log" || in_name == "birch_log" || in_name == "pine_log";
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
                let is_stone = in_name == "stone_brick" || in_name == "cobblestone" || in_name == "stone";
                if !is_stone {
                    return false;
                }
                let tier = self.villages.get(&(ax, az)).map(|v| v.tier).unwrap_or(0);
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
                    self.toast("Mason: cut stone and proud towers! Now Dov can forge the iron gate.");
                } else {
                    self.toast(&format!("Mason: good stone. ({}/{} for the upgrade)", progress, STONE_NEEDED));
                }
                true
            }
            6 => {
                let is_iron = in_name == "iron_ingot" || in_name == "raw_iron";
                if !is_iron {
                    return false;
                }
                let tier = self.villages.get(&(ax, az)).map(|v| v.tier).unwrap_or(0);
                if tier < 2 {
                    self.toast("Blacksmith: get Bria to finish the stonework, then bring me iron.");
                    return true;
                }
                if tier >= 3 {
                    self.toast("Blacksmith: the gate is hung and the lamps are lit. Our town is safe!");
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
                    self.toast(&format!("Blacksmith: fine iron. ({}/{} for the gate)", progress, IRON_NEEDED));
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
            let dx = wx - ax;
            let dz = wz - az;
            if dx > -R && dx < R && dz > -R && dz < R {
                return Some((ax, az));
            }
        }
        None
    }

    fn village_status_near(&self, wx: i32, wz: i32, radius: i32) -> Option<(i32, i32, u8, i32, i32, i32, i32)> {
        let mut best: Option<(i32, i32)> = None;
        let mut best_d2 = (radius as i64) * (radius as i64);
        for &(ax, az) in self.villages.keys() {
            let d2 = ((ax - wx) as i64).pow(2) + ((az - wz) as i64).pow(2);
            if d2 <= best_d2 {
                best_d2 = d2;
                best = Some((ax, az));
            }
        }
        let (styp, sax, saz, _sy) = worldgen::worldgen_structure_near(wx, wz, self.seed);
        if styp == 8 || worldgen::worldgen_is_city(styp) {
            let d2 = ((sax - wx) as i64).pow(2) + ((saz - wz) as i64).pow(2);
            if d2 <= best_d2 {
                best = Some((sax, saz));
            }
        }
        let (ax, az) = best?;
        let vs = self.villages.get(&(ax, az)).cloned().unwrap_or_default();
        let (progress_needed, progress) = match vs.tier {
            1 => (16, vs.progress),
            2 => (8, vs.progress),
            _ => (0, 0),
        };
        Some((ax, az, vs.tier, vs.wood_cells, Self::PALISADE_CELLS, progress, progress_needed))
    }

    pub fn debug_build_palisade(&mut self, cx: i32, cz: i32, cells: i32) -> i32 {
        self.build_palisade_segment(cx, cz, cells, Self::WALL_WOOD)
    }

    pub fn debug_village_tier(&self, ax: i32, az: i32) -> i32 {
        self.villages.get(&(ax, az)).map(|v| v.tier as i32).unwrap_or(0)
    }

    pub fn debug_village_progress(&self, ax: i32, az: i32) -> i32 {
        self.villages.get(&(ax, az)).map(|v| v.progress).unwrap_or(0)
    }

    pub fn debug_village_wood_cells(&self, ax: i32, az: i32) -> i32 {
        self.villages.get(&(ax, az)).map(|v| v.wood_cells).unwrap_or(0)
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
}
