use super::*;

impl<'c> World<'c> {
    pub(super) fn craftable_recipes(&self) -> Vec<u32> {
        let mut out = Vec::new();
        let content = match self.content {
            Some(c) => c,
            None => return out,
        };
        let inv = match self.inv.as_ref() {
            Some(i) => i,
            None => return out,
        };
        let has_table = {
            let ct = self.item_id_by_name("crafting_table");
            ct != 0 && inv.count_item(ct) > 0
        };
        let mut i = 0u32;
        while i < content.recipe_count() && out.len() < 24 {
            let r = content.recipe(i);
            if r.pattern.is_empty() || r.result_item == 0 {
                i += 1;
                continue;
            }
            if r.grid_size >= 3 && !has_table {
                i += 1;
                continue;
            }
            let pat = &r.pattern;
            let mut ok = true;
            let mut a = 0usize;
            while a < pat.len() && ok {
                let it = pat[a];
                if it == 0 {
                    a += 1;
                    continue;
                }
                let mut first_occ = true;
                let mut need = 0i32;
                for s in 0..pat.len() {
                    if pat[s] == it {
                        need += 1;
                        if s < a {
                            first_occ = false;
                        }
                    }
                }
                if !first_occ {
                    a += 1;
                    continue;
                }
                if (inv.count_item(it) as i32) < need {
                    ok = false;
                }
                a += 1;
            }
            if ok {
                out.push(i);
            }
            i += 1;
        }
        out
    }

    pub(super) fn craft_index(&mut self, idx: i32) {
        let content = match self.content {
            Some(c) => c,
            None => return,
        };
        let cr = self.craftable_recipes();
        let mut idx = idx;
        if idx < 0 {
            if !cr.is_empty() {
                idx = 0;
            } else {
                return;
            }
        }
        if idx as usize >= cr.len() {
            return;
        }
        let r = content.recipe(cr[idx as usize]);
        let pattern: Vec<ItemId> = r.pattern.clone();
        let grid_size = r.grid_size;
        let result_item = r.result_item;
        let result_count = r.result_count;
        if self.craft_commit(&pattern, grid_size) {
            let pv = self.player_voxel();
            self.fx(4, pv, 0);
            let made = if result_count > 0 {
                result_count as i32
            } else {
                1
            };
            let rname = self.item_name(result_item);
            for _ in 0..made {
                self.notify_quest("craft_item", &rname);
            }
        }
    }

    fn craft_commit(&mut self, grid: &[ItemId], dim: i32) -> bool {
        let content = match self.content {
            Some(c) => c,
            None => return false,
        };
        let m = match content.recipe_match(grid, dim) {
            Some(m) => m,
            None => return false,
        };
        let mut required: HashMap<ItemId, u16> = HashMap::new();
        for &id in grid {
            if id == 0 {
                continue;
            }
            *required.entry(id).or_insert(0) += 1;
        }
        let inv = match self.inv.as_mut() {
            Some(i) => i,
            None => return false,
        };
        for (&item, &need) in &required {
            if inv.count_item(item) < need {
                return false;
            }
        }
        let before = inv.clone();
        for (&item, &need) in &required {
            inv.remove_item(item, need);
        }
        let result = ItemStack {
            item: m.result,
            count: m.count,
            durability: 0xFFFF,
        };
        if !inv.add(result) {
            *inv = before;
            return false;
        }
        true
    }
}
