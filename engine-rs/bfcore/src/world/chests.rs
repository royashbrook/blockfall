use super::*;

// #109 per-chest container state, keyed in the world by the chest block's world
// position. Contents roll lazily from seed+position, then persist through chests.dat.
#[derive(Clone)]
pub(super) struct ChestData {
    pub(super) slots: [ItemStack; CHEST_SLOTS],
    pub(super) filled: bool,
}

impl Default for ChestData {
    fn default() -> ChestData {
        ChestData {
            slots: [ItemStack::default(); CHEST_SLOTS],
            filled: false,
        }
    }
}

impl ChestData {
    fn has_contents(&self) -> bool {
        self.slots.iter().any(|slot| !slot.is_empty())
    }
}

impl<'c> World<'c> {
    // splitmix64 finaliser: a stable, seed+position-derived hash for deterministic
    // loot. Self-contained so it does not perturb self.rng.
    fn chest_hash(seed: u64, w: IVec3, salt: u64) -> u64 {
        let mut z = seed
            ^ (w.x as i64 as u64).wrapping_mul(0x9E3779B97F4A7C15)
            ^ (w.y as i64 as u64).wrapping_mul(0xC2B2AE3D27D4EB4F)
            ^ (w.z as i64 as u64).wrapping_mul(0x165667B19E3779F9)
            ^ salt.wrapping_mul(0xD6E8FEB86659FD93);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    fn roll_chest_loot(&self, w: IVec3) -> [ItemStack; CHEST_SLOTS] {
        let mut out = [ItemStack::default(); CHEST_SLOTS];
        let is_epic = worldgen::worldgen_epic_landmark_near(w.x, w.z, 16, self.seed)
            .map(|(_, ax, _ay, az)| {
                Self::wrap_signed_block(ax - w.x).abs() <= 12
                    && Self::wrap_signed_block(az - w.z).abs() <= 12
            })
            .unwrap_or(false);
        let is_ruin = worldgen::worldgen_dangerous_site_near(w.x, w.z, 8, self.seed)
            // #179: nearest-image so a ruin whose footprint straddles the seam is
            // still recognized (raw ax - w.x would be ~32764 and the chest would
            // roll common village loot instead of ruin loot).
            .map(|(ax, _ay, az)| {
                Self::wrap_signed_block(ax - w.x).abs() <= 6
                    && Self::wrap_signed_block(az - w.z).abs() <= 6
            })
            .unwrap_or(false);
        let table: &[(&str, u16, u16)] = if is_epic {
            &[
                ("iron_sword", 1, 1),
                ("iron_pickaxe", 1, 1),
                ("iron_ingot", 2, 5),
                ("crystal_shard", 2, 5),
                ("color_dust", 4, 8),
                ("glow_dust", 3, 6),
                ("honey_cake", 2, 4),
                ("crystal_lamp", 1, 2),
            ]
        } else if is_ruin {
            &[
                ("iron_ingot", 1, 2),
                ("crystal_shard", 1, 3),
                ("color_dust", 2, 5),
                ("glow_dust", 1, 3),
                ("honey_cake", 1, 2),
                ("torch", 4, 8),
                ("coal", 1, 3),
            ]
        } else {
            &[
                ("oak_planks", 4, 8),
                ("torch", 2, 6),
                ("berry_cluster", 2, 4),
                ("stick", 4, 8),
                ("coal", 1, 3),
                ("mushroom", 1, 2),
            ]
        };
        for slot in 0..CHEST_SLOTS {
            let h = Self::chest_hash(self.seed, w, slot as u64 + 1);
            if h % 3 == 0 {
                continue;
            }
            let (name, lo, hi) = table[(h >> 8) as usize % table.len()];
            let id = self.item_id_by_name(name);
            if id == 0 {
                continue;
            }
            let span = (hi - lo + 1) as u64;
            let count = lo + ((h >> 24) % span) as u16;
            out[slot] = ItemStack {
                item: id,
                count,
                durability: 0xFFFF,
            };
        }
        out
    }

    pub(super) fn ensure_chest(&mut self, w: IVec3) {
        let key = (w.x, w.y, w.z);
        let needs_fill = match self.chests.get(&key) {
            Some(c) => !c.filled,
            None => true,
        };
        if needs_fill {
            let slots = self.roll_chest_loot(w);
            self.chests.insert(
                key,
                ChestData {
                    slots,
                    filled: true,
                },
            );
        }
    }

    // Meshing can answer this without materializing unopened chest state: untouched
    // barrels use the same deterministic roll they will receive on first open.
    pub(super) fn chest_has_contents(&self, w: IVec3) -> bool {
        let w = Self::canon_block(w);
        self.chests
            .get(&(w.x, w.y, w.z))
            .filter(|data| data.filled)
            .map(ChestData::has_contents)
            .unwrap_or_else(|| self.roll_chest_loot(w).iter().any(|slot| !slot.is_empty()))
    }

    fn dirty_chest_if_occupancy_changed(&mut self, w: IVec3, was_nonempty: bool) {
        let w = Self::canon_block(w);
        if self.chest_has_contents(w) == was_nonempty {
            return;
        }
        let cc = Self::canon_chunk(Self::to_chunk(w));
        self.mark_dirty(cc);
        self.urgent_dirty.insert(cc);
    }

    pub(super) fn spill_chest_on_break(&mut self, t: IVec3) {
        if self.last_chest_open == Some(t) {
            self.last_chest_open = None;
        }
        self.ensure_chest(t);
        if let Some(data) = self.chests.get(&(t.x, t.y, t.z)).cloned() {
            let mut leftover = ChestData::default();
            leftover.filled = true;
            let mut any_left = false;
            for (i, s) in data.slots.iter().enumerate() {
                if s.is_empty() {
                    continue;
                }
                let mut remaining = s.count;
                while remaining > 0 {
                    let one = ItemStack {
                        item: s.item,
                        count: 1,
                        durability: s.durability,
                    };
                    let placed = self.inv.as_mut().map(|inv| inv.add(one)).unwrap_or(false);
                    if !placed {
                        break;
                    }
                    remaining -= 1;
                }
                if remaining > 0 {
                    leftover.slots[i] = ItemStack {
                        item: s.item,
                        count: remaining,
                        durability: s.durability,
                    };
                    any_left = true;
                }
            }
            if any_left {
                self.chests.insert((t.x, t.y, t.z), leftover);
            } else {
                self.chests.remove(&(t.x, t.y, t.z));
            }
        }
    }

    pub(super) fn toggle_chest_open(&mut self, target: IVec3) {
        if self.last_chest_open == Some(target) {
            self.last_chest_open = None;
        } else {
            self.ensure_chest(target);
            self.last_chest_open = Some(target);
            self.fx(1, target, 0);
        }
    }

    pub fn chest_slots(&mut self, w: IVec3) -> Option<[ItemStack; CHEST_SLOTS]> {
        if self.block_at(w) != CHEST {
            return None;
        }
        self.ensure_chest(w);
        self.chests.get(&(w.x, w.y, w.z)).map(|c| c.slots)
    }

    pub fn chest_take(&mut self, w: IVec3, slot: usize) -> bool {
        if slot >= CHEST_SLOTS || self.block_at(w) != CHEST {
            return false;
        }
        self.ensure_chest(w);
        let key = (w.x, w.y, w.z);
        let was_nonempty = self.chest_has_contents(w);
        let src = match self.chests.get(&key) {
            Some(c) => c.slots[slot],
            None => return false,
        };
        if src.is_empty() {
            return false;
        }
        let inv = match self.inv.as_mut() {
            Some(i) => i,
            None => return false,
        };
        let mut remaining = src.count;
        while remaining > 0 {
            let one = ItemStack {
                item: src.item,
                count: 1,
                durability: src.durability,
            };
            if !inv.add(one) {
                break;
            }
            remaining -= 1;
        }
        let moved = remaining != src.count;
        if moved {
            let c = self.chests.get_mut(&key).expect("chest present");
            if remaining == 0 {
                c.slots[slot] = ItemStack::default();
            } else {
                c.slots[slot].count = remaining;
            }
            let nm = self.item_name(src.item);
            self.notify_quest("collect_item", &nm);
            self.dirty_chest_if_occupancy_changed(w, was_nonempty);
        }
        moved
    }

    pub fn chest_deposit(&mut self, w: IVec3, inv_slot: usize) -> bool {
        if inv_slot >= BF_INVENTORY_SLOTS || self.block_at(w) != CHEST {
            return false;
        }
        self.ensure_chest(w);
        let key = (w.x, w.y, w.z);
        let was_nonempty = self.chest_has_contents(w);
        let held = match self.inv.as_ref() {
            Some(i) => i.get(inv_slot),
            None => return false,
        };
        if held.is_empty() {
            return false;
        }
        let max_s = self
            .content
            .map(|c| c.item_max_stack(held.item))
            .filter(|&m| m > 0)
            .unwrap_or(64);
        let mut remaining = held.count;
        {
            let c = self.chests.get_mut(&key).expect("chest present");
            for s in c.slots.iter_mut() {
                if remaining == 0 {
                    break;
                }
                if !s.is_empty() && s.item == held.item && s.count < max_s {
                    let take = remaining.min(max_s - s.count);
                    s.count += take;
                    remaining -= take;
                }
            }
            for s in c.slots.iter_mut() {
                if remaining == 0 {
                    break;
                }
                if s.is_empty() {
                    let take = remaining.min(max_s);
                    *s = ItemStack {
                        item: held.item,
                        count: take,
                        durability: held.durability,
                    };
                    remaining -= take;
                }
            }
        }
        let moved = remaining != held.count;
        if moved {
            if let Some(inv) = self.inv.as_mut() {
                if remaining == 0 {
                    inv.set(inv_slot, ItemStack::default());
                } else {
                    let mut s = held;
                    s.count = remaining;
                    inv.set(inv_slot, s);
                }
            }
            self.dirty_chest_if_occupancy_changed(w, was_nonempty);
        }
        moved
    }

    pub fn chest_open_pos(&mut self) -> Option<IVec3> {
        if let Some(p) = self.last_chest_open {
            if self.block_at(p) != CHEST {
                self.last_chest_open = None;
            }
        }
        self.last_chest_open
    }

    pub fn close_chest(&mut self) {
        self.last_chest_open = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../content");

    #[test]
    fn chest_mesh_dirties_only_when_empty_state_changes() {
        let mut content = ContentRegistry::new();
        assert!(content.load(CONTENT));
        let mut world = World::new(None);
        world.set_content(&content);
        let pos = IVec3 { x: 8, y: 8, z: 8 };
        world.set_block_internal(pos, CHEST);
        let item = world.item_id_by_name("dirt");
        assert_ne!(item, 0);

        let mut data = ChestData {
            slots: [ItemStack::default(); CHEST_SLOTS],
            filled: true,
        };
        data.slots[0] = ItemStack {
            item,
            count: 1,
            durability: 0xFFFF,
        };
        data.slots[1] = data.slots[0];
        world.chests.insert((pos.x, pos.y, pos.z), data);
        let cc = World::to_chunk(pos);

        world.dirty.clear();
        world.urgent_dirty.clear();
        assert!(world.chest_take(pos, 0));
        assert!(!world.dirty.contains(&cc), "still-filled barrel does not remesh");

        assert!(world.chest_take(pos, 1));
        assert!(world.dirty.contains(&cc));
        assert!(world.urgent_dirty.contains(&cc));

        world.dirty.clear();
        world.urgent_dirty.clear();
        let inv_slot = (0..BF_INVENTORY_SLOTS)
            .find(|&slot| world.inv.as_ref().unwrap().get(slot).item == item)
            .expect("taken item is in inventory");
        assert!(world.chest_deposit(pos, inv_slot));
        assert!(world.dirty.contains(&cc), "first deposit lights an empty barrel");

        world.dirty.clear();
        world.urgent_dirty.clear();
        world.debug_give(item, 1);
        let inv_slot = (0..BF_INVENTORY_SLOTS)
            .find(|&slot| world.inv.as_ref().unwrap().get(slot).item == item)
            .expect("given item is in inventory");
        assert!(world.chest_deposit(pos, inv_slot));
        assert!(!world.dirty.contains(&cc), "filled-to-filled deposit does not remesh");
    }

    #[test]
    fn unopened_seed11_boss_barrel_reports_contents_before_materializing() {
        let mut content = ContentRegistry::new();
        assert!(content.load(CONTENT));
        let mut world = World::new(None);
        world.set_content(&content);
        world.seed = 11;
        let pos = IVec3 {
            x: 6621,
            y: 18,
            z: 30886,
        };
        assert!(world.chest_has_contents(pos));
        assert!(!world.chests.contains_key(&(pos.x, pos.y, pos.z)));
        world.ensure_chest(pos);
        assert!(world.chest_has_contents(pos));
    }
}
