use super::*;

impl<'c> World<'c> {
    pub(super) fn creature_in_view(&self) -> i32 {
        let o = self.pos;
        let d = self.forward_dir();
        let mut best = -1i32;
        let mut best_t = 6.0f32;
        for (i, c) in self.creatures.iter().enumerate() {
            let cc = c.pos + V3::new(0.0, c.scale * 0.5, 0.0);
            // #179: nearest-image delta, or a creature one block away across the
            // seam reads as ~32767 blocks ahead and can never be looked at, hit,
            // befriended, or talked to (while it can still melee the player, whose
            // own AI already wraps). off is derived from the wrapped rel too.
            let mut rel = cc - o;
            rel.x = Self::wrap_signed_f(rel.x);
            rel.z = Self::wrap_signed_f(rel.z);
            let t = dot(rel, d);
            if t < 0.0 || t > best_t {
                continue;
            }
            let off = rel - d * t;
            let rad = 0.55 + c.scale * 0.7;
            if dot(off, off) < rad * rad {
                best_t = t;
                best = i as i32;
            }
        }
        best
    }

    pub(super) fn attack_creature(&mut self, idx: i32) {
        let idx = idx as usize;
        let (cx, cy, cz, is_boss) = {
            let cr = &self.creatures[idx];
            (cr.pos.x, cr.pos.y, cr.pos.z, cr.is_boss)
        };
        let cv = IVec3 {
            x: Self::ifloor(cx),
            y: Self::ifloor(cy),
            z: Self::ifloor(cz),
        };
        // Damage by held weapon.
        let mut dmg = 2;
        if let (Some(inv), Some(content)) = (self.inv.as_ref(), self.content) {
            if let Some(it) = content.item_by_id(inv.get(self.selected as usize).item) {
                if it.tool_kind == 4 {
                    dmg = 4 + it.tool_tier as i32 * 2;
                } else if it.tool_kind == 2 {
                    dmg = 3;
                }
            }
        }
        self.damage_held_tool();
        // Apply hit + knockback.
        let px = self.pos.x;
        let pz = self.pos.z;
        {
            let cr = &mut self.creatures[idx];
            cr.hp -= dmg;
            cr.hit_flash = 0.22;
            // #179: nearest-image so knockback pushes the right way at the seam.
            let ax = Self::wrap_signed_f(cr.pos.x - px);
            let az = Self::wrap_signed_f(cr.pos.z - pz);
            let ad = (ax * ax + az * az).sqrt();
            let kb = if cr.is_boss { 0.25 } else { 1.3 };
            if ad > 0.01 {
                cr.pos.x = Self::wrap_pos_f(cr.pos.x + ax / ad * kb);
                cr.pos.z = Self::wrap_pos_f(cr.pos.z + az / ad * kb);
            }
            cr.vy = if cr.is_boss { 0.8 } else { 3.0 };
        }
        self.fx(8, cv, 0);
        if self.creatures[idx].hp <= 0 {
            let (boss, hostile, nm) = {
                let cr = &self.creatures[idx];
                (cr.is_boss, cr.hostile, cr.name.clone())
            };
            let cr = self.creatures[idx].clone();
            self.drop_creature_loot(&cr);
            self.creatures.remove(idx);
            self.creatures_calmed += 1;
            let pv = self.player_voxel();
            self.fx(5, pv, 0);
            let trig = if boss {
                "calm_boss"
            } else if hostile {
                "defeat_monster"
            } else {
                "defeat_animal"
            };
            self.notify_quest(trig, &nm);
        }
        let _ = is_boss;
    }

    pub(super) fn drop_creature_loot(&mut self, cr: &Creature) {
        if self.inv.is_none() {
            return;
        }
        if cr.hostile {
            let n1 = 1 + (self.rand01() * 2.0) as i32;
            self.give_loot("color_dust", n1);
            let n2 = 1 + (self.rand01() * 2.0) as i32;
            self.give_loot("glow_dust", n2);
            if self.rand01() < 0.5 {
                self.give_loot("coal", 1);
            }
        } else if cr.is_boss {
            let n1 = 2 + (self.rand01() * 2.0) as i32;
            self.give_loot("crystal_shard", n1);
            self.give_loot("color_dust", 2);
        } else {
            let n1 = 1 + (self.rand01() * 2.0) as i32;
            self.give_loot("feather", n1);
            if self.rand01() < 0.4 {
                self.give_loot("berry_cluster", 1);
            }
        }
        let pv = self.player_voxel();
        self.fx(7, pv, 0);
    }

    // Reward for clearing a ruin "danger site": a small bundle of worthwhile items
    // granted once when the last defender falls. Reuses give_loot (the same path
    // creatures use to drop loot on death), so it respects the existing inventory
    // behavior. Item ids are sensible existing content (food + a material + a block).
    pub(super) fn drop_ruin_clear_reward(&mut self) {
        if self.inv.is_none() {
            return;
        }
        self.give_loot("honey_cake", 2); // food
        self.give_loot("iron_ingot", 2); // useful material
        self.give_loot("stone_brick", 4); // building block
        let pv = self.player_voxel();
        self.fx(7, pv, 0);
    }

    pub(super) fn give_loot(&mut self, nm: &str, n: i32) {
        let id = self.item_id_by_name(nm);
        if id != 0 {
            if let Some(inv) = self.inv.as_mut() {
                inv.add(ItemStack {
                    item: id,
                    count: n as u16,
                    durability: 0xFFFF,
                });
            }
            self.notify_quest("collect_item", nm);
        }
    }
}
