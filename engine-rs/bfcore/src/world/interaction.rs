use super::*;

impl<'c> World<'c> {
    // ---- mine/place + tool wear ------------------------------------------
    pub(super) fn break_time(&self, b: BlockId) -> f32 {
        if b == AIR {
            return 1e9;
        }
        let bd = self.content.and_then(|c| c.block_by_id(b));
        let hardness = bd.map(|d| d.hardness as f32).unwrap_or(6.0);
        let req = bd.map(|d| d.required_tier).unwrap_or(0);
        let mut t = 0.15 + hardness * 0.05;
        if let (Some(inv), Some(content)) = (self.inv.as_ref(), self.content) {
            let it = content.item_by_id(inv.get(self.selected as usize).item);
            let tier = it.map(|d| d.tool_tier).unwrap_or(0);
            if tier > 0 && tier >= req {
                t *= 0.35;
            } else if req > 0 && tier < req {
                t *= 4.0;
            }
        }
        t
    }

    // Sound class for break audio.
    pub(super) fn sound_class_for(b: BlockId) -> i32 {
        match b {
            3 | 8 | 10 | 15 | 29 => 1,
            21 | 22 | 4 | 23 | 30 | 31 | 33 | 56 => 2,
            1 | 2 | 14 | 16 | 12 | 54 => 3,
            6 | 11 => 4,
            25 | 26 | 13 => 5,
            5 | 27 | 36 | 37 | 38 | 39 => 6,
            17 | 18 | 19 | 20 => 7,
            _ => 0,
        }
    }

    pub(super) fn footstep_class(b: BlockId) -> i32 {
        match b {
            3 | 8 | 10 | 29 => 1,
            6 => 2,
            12 | 13 | 54 => 3,
            4 | 23 | 21 | 22 | 49 | 51 | 33 | 56 => 4,
            _ => 0,
        }
    }

    // #117 footprint stamp: a walker stepping on FRESH snow compresses it into a trodden
    // print (TRODDEN_SNOW). Only fresh snow converts, so a cell is stamped at most once
    // and a trail does not keep re-dirtying the same cells. set_block_internal handles the
    // remesh + co-op replication, so the print shows for everyone and persists with the
    // edited chunk. Cheap and bounded: O(1) per step, no separate print list to cap.
    pub(super) fn stamp_footprint(&mut self, cell: IVec3) {
        if self.block_at(cell) == SNOW_LAYER {
            self.set_block_internal(cell, TRODDEN_SNOW);
        }
    }

    pub(super) fn item_that_places(&self, b: BlockId) -> ItemId {
        let content = match self.content {
            Some(c) => c,
            None => return 0,
        };
        if b == 0 {
            return 0;
        }
        for id in 1u16..400 {
            if let Some(d) = content.item_by_id(id) {
                if d.places_block == b {
                    return d.id;
                }
            }
        }
        0
    }

    pub(super) fn damage_held_tool(&mut self) {
        let content = match self.content {
            Some(c) => c,
            None => return,
        };
        let sel = match self.inv.as_ref() {
            Some(i) => i.get(self.selected as usize),
            None => return,
        };
        if sel.item == 0 {
            return;
        }
        let it = match content.item_by_id(sel.item) {
            Some(it) if it.tool_durability != 0 => it,
            _ => return,
        };
        let mut dur = if sel.durability == 0xFFFF {
            it.tool_durability
        } else {
            sel.durability
        };
        if dur > 0 {
            dur -= 1;
        }
        let target = self.target;
        if dur == 0 {
            let mut newsel = sel;
            newsel.count = if newsel.count > 0 {
                newsel.count - 1
            } else {
                0
            };
            let replacement = if newsel.count == 0 {
                ItemStack::default()
            } else {
                ItemStack {
                    item: newsel.item,
                    count: newsel.count,
                    durability: 0xFFFF,
                }
            };
            if let Some(inv) = self.inv.as_mut() {
                inv.set(self.selected as usize, replacement);
            }
            self.fx(0, target, 0);
        } else {
            let mut s = sel;
            s.durability = dur;
            if let Some(inv) = self.inv.as_mut() {
                inv.set(self.selected as usize, s);
            }
        }
    }

    pub(super) fn perform_place(&mut self) {
        if !self.has_target || self.inv.is_none() {
            return;
        }
        let sel = self.inv.as_ref().unwrap().get(self.selected as usize);
        if sel.item == 0 {
            return;
        }
        let pb = self
            .content
            .and_then(|c| c.item_by_id(sel.item))
            .map(|d| d.places_block)
            .unwrap_or(0);
        if pb == 0 {
            return;
        }
        // #182 warp totems are capped so the map marker array stays fixed-size.
        // Refuse the placement BEFORE consuming the item (kid-friendly toast).
        if pb == crate::world::WARP_TOTEM && !self.totem_cap_free() {
            self.toast("You already have 16 totems! Break one to place another.");
            return;
        }
        let solid = !(pb == AIR || pb == WATER || (36..=47).contains(&pb));
        if self.mode == bf_game_mode::BF_MODE_SURVIVAL
            && solid
            && self.voxel_in_player_box(self.place)
        {
            return;
        }
        if self.mode == bf_game_mode::BF_MODE_SURVIVAL {
            let removed = self.inv.as_mut().unwrap().remove_item(sel.item, 1);
            if !removed {
                return;
            }
        }
        let place = self.place;
        self.set_block_internal(place, pb);
        // #182 placing a warp totem registers a named map marker.
        if pb == crate::world::WARP_TOTEM {
            self.note_totem_placed(place);
        }
        if pb == 33 {
            let up = IVec3 {
                x: place.x,
                y: place.y + 1,
                z: place.z,
            };
            if self.block_at(up) == AIR {
                self.set_block_internal(up, 33);
            }
        }
        self.fx(1, place, 0);
        let pbname = self.block_name(pb);
        self.notify_quest("place_block", &pbname);
        if pb == self.glow_id || (self.beacon_id != 0 && pb == self.beacon_id) {
            self.notify_quest("light_beacon", &pbname);
            let rc = Self::to_chunk(place);
            if self.region_sat(rc) < 0.99 {
                self.regions_restored += 1;
                self.notify_quest("restore_region", "dim_barrens");
            }
            self.restore_region(rc);
        }
    }

    pub(super) fn break_block(&mut self, t: IVec3) {
        let broken = self.block_at(t);
        if broken == AIR {
            return;
        }
        // #109 breaking a chest spills its contents into the player inventory (never
        // destroy items) and removes the container entry. Whatever does not fit stays
        // keyed at the position so it is not lost (the block becomes air, but a freshly
        // placed chest at the same spot would re-expose it; acceptable + safe).
        if broken == CHEST {
            self.spill_chest_on_break(t);
        }
        // #182 breaking a warp totem unregisters its map marker; the item
        // refund rides the normal debris drop path below.
        if broken == crate::world::WARP_TOTEM {
            self.note_totem_broken(t);
        }
        self.fx(0, t, ((broken as i32) << 4) | Self::sound_class_for(broken));
        let bn = self.block_name(broken);
        self.notify_quest("mine_block", &bn);
        if Self::is_log(broken) {
            let place_item = self.item_that_places(broken);
            let in_name = self.item_name(place_item);
            self.notify_quest("collect_item", &in_name);
            self.fell_tree(t);
        } else {
            // Drop the item (or the open-door / wood-beam special cases).
            let mut drop = self
                .content
                .and_then(|c| c.block_by_id(broken))
                .map(|d| d.drop_item)
                .unwrap_or(0);
            if drop == 0 {
                drop = self.item_that_places(broken);
            }
            if broken == 50 {
                drop = self.item_id_by_name("oak_door");
            }
            if broken == 51 {
                drop = self.item_id_by_name("oak_log");
            }
            // #170 blockfall: the block bursts into physical debris that falls,
            // bounces, and magnets to the player. The drop item rides on the
            // debris and enters the inventory on collection (debris.rs), which
            // is also where fx(7) + the collect_item quest notify now fire.
            self.spawn_debris_burst(t, broken, drop);
            self.set_block_internal(t, AIR);
            // Doors are one logical object even though the world stores vertical cells.
            // Clear the whole contiguous run so old odd states cannot leave a lone half.
            if broken == 33 || broken == 50 {
                let mut low_y = t.y;
                while {
                    let b = self.block_at(IVec3 {
                        x: t.x,
                        y: low_y - 1,
                        z: t.z,
                    });
                    b == 33 || b == 50
                } {
                    low_y -= 1;
                }
                let mut high_y = t.y;
                while {
                    let b = self.block_at(IVec3 {
                        x: t.x,
                        y: high_y + 1,
                        z: t.z,
                    });
                    b == 33 || b == 50
                } {
                    high_y += 1;
                }
                for y in low_y..=high_y {
                    self.set_block_internal(IVec3 { x: t.x, y, z: t.z }, AIR);
                }
            }
            // A prop resting on this block loses support: break it too.
            let above = IVec3 {
                x: t.x,
                y: t.y + 1,
                z: t.z,
            };
            let ab = self.block_at(above);
            if Self::is_prop_block(ab) {
                let adrop = self
                    .content
                    .and_then(|c| c.block_by_id(ab))
                    .map(|d| d.drop_item)
                    .unwrap_or(0);
                // #170 a popped prop bursts too; its drop rides the debris.
                self.spawn_debris_burst(above, ab, adrop);
                self.set_block_internal(above, AIR);
            }
            self.apply_gravity_above(t);
            self.flow_water(t);
        }
    }

    // ---- raycast ---------------------------------------------------------
    pub(super) fn raycast_target(&mut self) {
        self.has_target = false;
        let o = self.pos;
        let d = self.forward_dir();
        let mut v = IVec3 {
            x: Self::ifloor(o.x),
            y: Self::ifloor(o.y),
            z: Self::ifloor(o.z),
        };
        let step = IVec3 {
            x: if d.x > 0.0 { 1 } else { -1 },
            y: if d.y > 0.0 { 1 } else { -1 },
            z: if d.z > 0.0 { 1 } else { -1 },
        };
        let td = V3::new(
            if d.x != 0.0 { (1.0 / d.x).abs() } else { 1e30 },
            if d.y != 0.0 { (1.0 / d.y).abs() } else { 1e30 },
            if d.z != 0.0 { (1.0 / d.z).abs() } else { 1e30 },
        );
        let frac = |f: f32, s: i32| -> f32 {
            let fl = f.floor();
            if s > 0 {
                fl + 1.0 - f
            } else {
                f - fl
            }
        };
        let mut tmax = V3::new(
            td.x * frac(o.x, step.x),
            td.y * frac(o.y, step.y),
            td.z * frac(o.z, step.z),
        );
        let mut prev = v;
        for _ in 0..128 {
            if self.block_at(v) != AIR {
                self.has_target = true;
                // #179: canonical voxels so chest keys / edits keyed off the
                // target are unique when the ray crosses the world seam.
                self.target = Self::canon_block(v);
                self.place = Self::canon_block(prev);
                return;
            }
            prev = v;
            if tmax.x < tmax.y && tmax.x < tmax.z {
                v.x += step.x;
                tmax.x += td.x;
            } else if tmax.y < tmax.z {
                v.y += step.y;
                tmax.y += td.y;
            } else {
                v.z += step.z;
                tmax.z += td.z;
            }
        }
    }
}
