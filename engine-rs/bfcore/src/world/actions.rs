use super::*;

impl<'c> World<'c> {
    // ---- discrete actions ------------------------------------------------
    pub fn action(&mut self, a: &bf_action) {
        use bf_action_kind::*;
        if matches!(a.kind, BF_ACT_MINE_START | BF_ACT_PLACE | BF_ACT_ATTACK) {
            self.player_action_timer = 0.35;
        }
        match a.kind {
            BF_ACT_MINE_START => {
                let idx = self.creature_in_view();
                if idx >= 0 {
                    self.attack_creature(idx);
                } else {
                    self.mining = true;
                }
            }
            BF_ACT_MINE_STOP => {
                self.mining = false;
                self.mine_progress = 0.0;
            }
            BF_ACT_PLACE => self.perform_place(),
            BF_ACT_CRAFT => self.craft_index(a.arg_i),
            BF_ACT_INV_OPEN => self.inv_open = true,
            BF_ACT_INV_CLOSE => self.inv_open = false,
            BF_ACT_INV_MOVE => {
                if let Some(inv) = self.inv.as_mut() {
                    let cnt = if a.arg_k > 0 { a.arg_k as u16 } else { 64 };
                    inv.move_item(a.arg_i as usize, a.arg_j as usize, cnt);
                }
            }
            BF_ACT_ATTACK => {
                let idx = self.creature_in_view();
                if idx >= 0 {
                    self.attack_creature(idx);
                }
            }
            BF_ACT_INTERACT => {
                // #305 dialogue-owned interaction variants bypass the block under
                // the crosshair and stay bound to the villager who opened the UI.
                if a.arg_i == 2 {
                    self.end_villager_dialogue();
                    return;
                }
                if a.arg_i == 1 {
                    let idx = self
                        .creatures
                        .iter()
                        .position(|c| c.model == 20 && c.dialogue_held)
                        .or_else(|| {
                            let looked = self.creature_in_view();
                            (looked >= 0).then_some(looked as usize)
                        });
                    if let Some(idx) = idx.filter(|&i| {
                        self.creatures[i].model == 20 && self.creatures[i].npc_id != 7
                    }) {
                        let _ = self.try_village_donation(idx);
                    }
                    return;
                }
                // #69 doors: open/close a targeted door (takes priority).
                if self.has_target {
                    let tb = self.block_at(self.target);
                    if self.toggle_fortress_gate(self.target) {
                        return;
                    }
                    if tb == 33 || tb == 50 {
                        let target = self.target;
                        let mut low_y = target.y;
                        while {
                            let b = self.block_at(IVec3 {
                                x: target.x,
                                y: low_y - 1,
                                z: target.z,
                            });
                            b == 33 || b == 50
                        } {
                            low_y -= 1;
                        }
                        let mut high_y = target.y;
                        while {
                            let b = self.block_at(IVec3 {
                                x: target.x,
                                y: high_y + 1,
                                z: target.z,
                            });
                            b == 33 || b == 50
                        } {
                            high_y += 1;
                        }
                        let base = self.block_at(IVec3 {
                            x: target.x,
                            y: low_y,
                            z: target.z,
                        });
                        let nb = if base == 33 { 50 } else { 33 };
                        for y in low_y..=high_y {
                            self.set_block_internal(
                                IVec3 {
                                    x: target.x,
                                    y,
                                    z: target.z,
                                },
                                nb,
                            );
                        }
                        self.fx(1, target, 0);
                        return;
                    }
                    // #109 chests: open the container panel (right-click on a chest).
                    // Takes priority over place/befriend so a chest is always openable.
                    // Toggle: interacting the same open chest again closes it.
                    if tb == CHEST {
                        self.toggle_chest_open(self.target);
                        return;
                    }
                }
                let idx = self.creature_in_view();
                if idx >= 0
                    && self.creatures[idx as usize].model == 20
                    && self.creatures[idx as usize].npc_id != 7
                {
                    self.begin_villager_dialogue(idx as usize);
                    let pv = self.player_voxel();
                    let npc = self.creatures[idx as usize].npc_id;
                    self.fx(20, pv, npc);
                } else if idx >= 0
                    && !self.creatures[idx as usize].hostile
                    && !self.creatures[idx as usize].provoked
                {
                    self.creatures[idx as usize].friendly = true;
                    self.creatures_befriended += 1;
                    // Feed the held berry (consume one).
                    if let Some(inv) = self.inv.as_ref() {
                        let held = inv.get(self.selected as usize);
                        if held.item != 0 && self.item_name(held.item) == "berry_cluster" {
                            self.inv.as_mut().unwrap().remove_item(held.item, 1);
                        }
                    }
                    let pv = self.player_voxel();
                    self.fx(5, pv, 0);
                    let nm = self.creatures[idx as usize].name.clone();
                    self.notify_quest("befriend_creature", &nm);
                } else {
                    self.perform_place();
                }
            }
            BF_ACT_GIVE_ITEM => {
                if self.mode == bf_game_mode::BF_MODE_CREATIVE && self.inv.is_some() && a.arg_i > 0
                {
                    let mut qty = 64u16;
                    if let Some(content) = self.content {
                        if let Some(d) = content.item_by_id(a.arg_i as ItemId) {
                            qty = (64).min(if d.max_stack > 0 { d.max_stack } else { 64 });
                        }
                    }
                    self.inv.as_mut().unwrap().add(ItemStack {
                        item: a.arg_i as ItemId,
                        count: qty,
                        durability: 0xFFFF,
                    });
                }
            }
            BF_ACT_DROP_ITEM => {
                if let Some(inv) = self.inv.as_mut() {
                    if a.arg_i >= 0 && (a.arg_i as usize) < BF_INVENTORY_SLOTS {
                        inv.set(a.arg_i as usize, ItemStack::default());
                    }
                }
            }
            BF_ACT_HOTBAR_SELECT => {
                if a.arg_i >= 0 && (a.arg_i as usize) < BF_HOTBAR_SLOTS {
                    self.selected = a.arg_i as u8;
                }
            }
            BF_ACT_HOTBAR_SCROLL => {
                let s = (self.selected as i32
                    + (if a.arg_i >= 0 { 1 } else { -1 })
                    + BF_HOTBAR_SLOTS as i32)
                    % BF_HOTBAR_SLOTS as i32;
                self.selected = s as u8;
            }
            BF_ACT_MODE_TOGGLE => {
                self.mode = if self.mode == bf_game_mode::BF_MODE_CREATIVE {
                    bf_game_mode::BF_MODE_SURVIVAL
                } else {
                    bf_game_mode::BF_MODE_CREATIVE
                };
            }
            BF_ACT_SET_TIME_MODE => self.set_time_mode(a.arg_i),
            // #184: creative-only testing toggle; ignored in survival so it can
            // never become a movement cheat there.
            BF_ACT_SET_HYPERSPEED => self.hyperspeed = a.arg_i != 0,
            BF_ACT_EQUIP => {
                if a.arg_i >= 0 {
                    self.equip_from_inventory(a.arg_i as usize);
                } else if a.arg_j >= 0 {
                    self.unequip(a.arg_j as usize);
                }
            }
        }
    }

    pub(super) fn begin_villager_dialogue(&mut self, idx: usize) {
        self.end_villager_dialogue();
        if let Some(c) = self
            .creatures
            .get_mut(idx)
            .filter(|c| c.model == 20 && c.npc_id != 7)
        {
            c.dialogue_held = true;
        }
    }

    pub(super) fn end_villager_dialogue(&mut self) {
        for c in &mut self.creatures {
            c.dialogue_held = false;
        }
    }
}
