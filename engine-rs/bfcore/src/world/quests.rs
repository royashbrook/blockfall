use super::*;
use crate::content::QuestDefX;

struct Achievement {
    trig: &'static str,
    target: &'static str,
    count: i32,
    title: &'static str,
}

const K_ACHIEVEMENTS: &[Achievement] = &[
    Achievement {
        trig: "collect_item",
        target: "oak_log",
        count: 1,
        title: "Knock On Wood",
    },
    Achievement {
        trig: "mine_block",
        target: "oak_log",
        count: 3,
        title: "Timberrr!",
    },
    Achievement {
        trig: "collect_item",
        target: "dirt",
        count: 16,
        title: "Dirt Rich",
    },
    Achievement {
        trig: "mine_block",
        target: "stone",
        count: 1,
        title: "Between a Rock",
    },
    Achievement {
        trig: "craft_item",
        target: "",
        count: 1,
        title: "Arts & Crafts",
    },
    Achievement {
        trig: "mine_block",
        target: "coal_ore",
        count: 1,
        title: "Coal Digger",
    },
    Achievement {
        trig: "mine_block",
        target: "iron_ore",
        count: 1,
        title: "Pumping Iron",
    },
    Achievement {
        trig: "place_block",
        target: "",
        count: 10,
        title: "Block Party",
    },
    Achievement {
        trig: "collect_item",
        target: "mushroom",
        count: 1,
        title: "Fun Guy",
    },
    Achievement {
        trig: "place_block",
        target: "crafting_table",
        count: 1,
        title: "Table Manners",
    },
    Achievement {
        trig: "befriend_creature",
        target: "",
        count: 1,
        title: "Best Friends Furever",
    },
    Achievement {
        trig: "defeat_animal",
        target: "",
        count: 1,
        title: "Circle of Life",
    },
    Achievement {
        trig: "defeat_monster",
        target: "",
        count: 1,
        title: "Who's Scared Now?",
    },
    Achievement {
        trig: "mine_block",
        target: "iron_ore",
        count: 5,
        title: "Iron Will",
    },
    Achievement {
        trig: "collect_item",
        target: "color_dust",
        count: 4,
        title: "Tickled Pink",
    },
    Achievement {
        trig: "reach_location",
        target: "dim_barrens",
        count: 1,
        title: "Into the Grey",
    },
    Achievement {
        trig: "calm_boss",
        target: "",
        count: 1,
        title: "Big Softie",
    },
    Achievement {
        trig: "light_beacon",
        target: "",
        count: 1,
        title: "Guiding Light",
    },
    Achievement {
        trig: "restore_region",
        target: "dim_barrens",
        count: 1,
        title: "True Colors",
    },
    Achievement {
        trig: "befriend_creature",
        target: "platypus",
        count: 1,
        title: "Perry the Platypus",
    },
];

pub(super) const K_ACHIEVEMENT_COUNT: usize = K_ACHIEVEMENTS.len();

impl<'c> World<'c> {
    pub(super) fn start_quest(&mut self, i: usize) {
        self.active_quest = i;
        self.obj_progress.clear();
        if let Some(x) = self.extra {
            if i < x.quests().len() {
                self.obj_progress = vec![0u32; x.quests()[i].objectives.len()];
            }
        }
    }

    fn quest_done(q: &QuestDefX, prog: &[u32]) -> bool {
        if prog.len() != q.objectives.len() {
            return false;
        }
        for (i, o) in q.objectives.iter().enumerate() {
            if prog[i] < o.count {
                return false;
            }
        }
        true
    }

    fn check_achievements(&mut self, trig: &str, target: &str) {
        for i in 0..K_ACHIEVEMENT_COUNT {
            let a = &K_ACHIEVEMENTS[i];
            if self.ach_done[i] || trig != a.trig {
                continue;
            }
            if !a.target.is_empty() && target != a.target {
                continue;
            }
            self.ach_progress[i] += 1;
            if self.ach_progress[i] >= a.count {
                self.ach_done[i] = true;
                self.ach_done_count += 1;
                self.ach_toast = format!("Achievement: {}", a.title);
                self.ach_toast_timer = 4.0;
                let pv = self.player_voxel();
                self.fx(6, pv, 0);
            }
        }
    }

    pub(super) fn notify_quest(&mut self, trig: &str, target: &str) {
        self.check_achievements(trig, target);
        let extra = match self.extra {
            Some(x) => x,
            None => return,
        };
        if !self.all_quests_done && self.active_quest < extra.quests().len() {
            let q = &extra.quests()[self.active_quest];
            let mut changed = false;
            if q.arc != "side" && self.obj_progress.len() == q.objectives.len() {
                for (i, o) in q.objectives.iter().enumerate() {
                    if o.trigger == trig
                        && (o.target.is_empty() || o.target == target)
                        && self.obj_progress[i] < o.count
                    {
                        self.obj_progress[i] += 1;
                        changed = true;
                    }
                }
            }
            if changed && Self::quest_done(q, &self.obj_progress) {
                let rewards: Vec<(String, u32)> = q.rewards.clone();
                let next = extra
                    .quests()
                    .iter()
                    .enumerate()
                    .skip(self.active_quest + 1)
                    .find(|(_, candidate)| candidate.arc != "side")
                    .map(|(i, _)| i);
                for (item, cnt) in rewards {
                    let id = self.item_id_by_name(&item);
                    if id != 0 {
                        if let Some(inv) = self.inv.as_mut() {
                            inv.add(ItemStack {
                                item: id,
                                count: cnt as u16,
                                durability: 0xFFFF,
                            });
                        }
                    }
                }
                self.quests_completed += 1;
                let pv = self.player_voxel();
                self.fx(6, pv, 0);
                if let Some(next) = next {
                    self.start_quest(next);
                } else {
                    self.all_quests_done = true;
                }
            }
        }

        // A side quest becomes ready here, but its villager owns completion and
        // rewards: the player must return and choose the quest response again.
        if let Some(i) = self.active_side_quest {
            let q = &extra.quests()[i];
            if self.side_obj_progress.len() == q.objectives.len()
                && !Self::quest_done(q, &self.side_obj_progress)
            {
                for (k, o) in q.objectives.iter().enumerate() {
                    if o.trigger == trig
                        && (o.target.is_empty() || o.target == target)
                        && self.side_obj_progress[k] < o.count
                    {
                        self.side_obj_progress[k] += 1;
                    }
                }
                if Self::quest_done(q, &self.side_obj_progress) {
                    self.toast("Side quest ready — return to the villager.");
                }
            }
        }
    }

    /// Accept, inspect, or turn in a side quest through the villager currently
    /// held by the dialogue. Main-arc IDs intentionally do nothing here.
    pub fn side_quest_talk(&mut self, quest_id: u32) -> bool {
        let extra = match self.extra {
            Some(x) => x,
            None => return false,
        };
        let quest_i = match extra
            .quests()
            .iter()
            .position(|q| q.id == quest_id && q.arc == "side")
        {
            Some(i) => i,
            None => return false,
        };
        let giver = match self
            .creatures
            .iter()
            .find(|c| c.model == 20 && c.dialogue_held)
            .map(|c| (c.npc_id, c.home_x, c.home_z))
        {
            Some(giver) => giver,
            None => return false,
        };
        if self.side_quests_done.contains(&quest_id) {
            self.toast("You already completed that side quest.");
            return true;
        }
        if self.active_side_quest == Some(quest_i) {
            let q = &extra.quests()[quest_i];
            if !Self::quest_done(q, &self.side_obj_progress) {
                self.toast("That side quest is still in progress.");
                return true;
            }
            let rewards = q.rewards.clone();
            let title = q.title.clone();
            for (item, count) in rewards {
                let id = self.item_id_by_name(&item);
                if id != 0 {
                    if let Some(inv) = self.inv.as_mut() {
                        inv.add(ItemStack {
                            item: id,
                            count: count as u16,
                            durability: 0xFFFF,
                        });
                    }
                }
            }
            self.side_quests_done.insert(quest_id);
            self.active_side_quest = None;
            self.side_obj_progress.clear();
            self.quests_completed += 1;
            self.toast(&format!("Side quest complete: {title}"));
            let pv = self.player_voxel();
            self.fx(6, pv, 0);
            return true;
        }
        if self.active_side_quest.is_some() {
            self.toast("Finish your current side quest first.");
            return true;
        }
        self.active_side_quest = Some(quest_i);
        self.side_obj_progress = vec![0; extra.quests()[quest_i].objectives.len()];
        self.side_quest_giver_npc = giver.0;
        self.side_quest_home_x = giver.1;
        self.side_quest_home_z = giver.2;
        self.toast(&format!(
            "Side quest accepted: {}",
            extra.quests()[quest_i].title
        ));
        true
    }

    pub fn fill_quest_list(&self, out: &mut [bf_quest_entry]) -> u32 {
        let x = match self.extra {
            Some(x) => x,
            None => return 0,
        };
        let qs = x.quests();
        let n = qs.len() as u32;
        let cap = out.len();
        for i in 0..(n as usize).min(cap) {
            let q = &qs[i];
            let e = &mut out[i];
            *e = bf_quest_entry {
                title: [0; 64],
                objective: [0; 96],
                state: 0,
                progress: 0.0,
            };
            Self::cstr_copy(&mut e.title, &q.title);
            let (done, active, progress) = if q.arc == "side" {
                (
                    self.side_quests_done.contains(&q.id),
                    self.active_side_quest == Some(i),
                    &self.side_obj_progress,
                )
            } else {
                (
                    self.all_quests_done || i < self.active_quest,
                    !self.all_quests_done && i == self.active_quest,
                    &self.obj_progress,
                )
            };
            e.state = if done {
                bf_quest_state::BF_QUEST_DONE as u8
            } else if active {
                bf_quest_state::BF_QUEST_ACTIVE as u8
            } else {
                bf_quest_state::BF_QUEST_UPCOMING as u8
            };
            if active && progress.len() == q.objectives.len() {
                let mut cdone = 0u32;
                let mut total = 0u32;
                let mut objtext = "";
                for (k, o) in q.objectives.iter().enumerate() {
                    total += o.count;
                    cdone += progress[k].min(o.count);
                    if progress[k] < o.count && objtext.is_empty() {
                        objtext = &o.text;
                    }
                }
                Self::cstr_copy(
                    &mut e.objective,
                    if !objtext.is_empty() {
                        objtext
                    } else if q.arc == "side" {
                        "Return to the quest giver."
                    } else {
                        "..."
                    },
                );
                e.progress = if total != 0 {
                    cdone as f32 / total as f32
                } else {
                    0.0
                };
            } else {
                e.progress = if done { 1.0 } else { 0.0 };
                if !q.objectives.is_empty() {
                    Self::cstr_copy(&mut e.objective, &q.objectives[0].text);
                }
            }
        }
        n
    }

    pub fn fill_quest_target(&self, out: &mut bf_quest_target) -> bool {
        *out = bf_quest_target {
            active: 0,
            is_boss: 0,
            position: bf_vec3 {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            distance: 0.0,
            label: [0; 48],
        };
        self.fill_creature_quest_target(out)
            || self.fill_side_quest_giver_target(out)
            || self.fill_growth_artisan_target(out)
    }

    fn fill_side_quest_giver_target(&self, out: &mut bf_quest_target) -> bool {
        let i = match self.active_side_quest {
            Some(i) => i,
            None => return false,
        };
        let q = match self.extra.and_then(|x| x.quests().get(i)) {
            Some(q) if Self::quest_done(q, &self.side_obj_progress) => q,
            _ => return false,
        };
        let hdx = Self::wrap_signed_f(self.pos.x - self.side_quest_home_x as f32);
        let hdz = Self::wrap_signed_f(self.pos.z - self.side_quest_home_z as f32);
        if hdx * hdx + hdz * hdz > 64.0 * 64.0 {
            return false;
        }
        let giver = match self.creatures.iter().find(|c| {
            c.model == 20
                && c.npc_id == self.side_quest_giver_npc
                && c.home_x == self.side_quest_home_x
                && c.home_z == self.side_quest_home_z
        }) {
            Some(c) => c,
            None => return false,
        };
        let dx = Self::wrap_signed_f(giver.pos.x - self.pos.x);
        let dy = giver.pos.y - self.pos.y;
        let dz = Self::wrap_signed_f(giver.pos.z - self.pos.z);
        out.active = 1;
        out.position = bf_vec3 {
            x: self.pos.x + dx,
            y: giver.pos.y,
            z: self.pos.z + dz,
        };
        out.distance = (dx * dx + dy * dy + dz * dz).sqrt();
        Self::cstr_copy(&mut out.label, &format!("Return: {}", q.title));
        true
    }

    fn fill_creature_quest_target(&self, out: &mut bf_quest_target) -> bool {
        let x = match self.extra {
            Some(x) => x,
            None => return false,
        };
        if self.all_quests_done || self.active_quest >= x.quests().len() {
            return false;
        }
        let q = &x.quests()[self.active_quest];
        if self.obj_progress.len() != q.objectives.len() {
            return false;
        }
        let mut obj = None;
        for (i, o) in q.objectives.iter().enumerate() {
            if self.obj_progress[i] >= o.count {
                continue;
            }
            if o.trigger == "befriend_creature" || o.trigger == "calm_boss" {
                obj = Some(o);
                break;
            }
        }
        let obj = match obj {
            Some(o) if !o.target.is_empty() => o,
            _ => return false,
        };
        let mut best: Option<&Creature> = None;
        let mut bestd2 = 1e30f32;
        for c in &self.creatures {
            if c.name != obj.target {
                continue;
            }
            let dx = Self::wrap_signed_f(c.pos.x - self.pos.x);
            let dy = c.pos.y - self.pos.y;
            let dz = Self::wrap_signed_f(c.pos.z - self.pos.z);
            let d2 = dx * dx + dy * dy + dz * dz;
            if d2 < bestd2 {
                bestd2 = d2;
                best = Some(c);
            }
        }
        let best = match best {
            Some(b) => b,
            None => return false,
        };
        out.active = 1;
        out.is_boss = if obj.trigger == "calm_boss" { 1 } else { 0 };
        // #179: emit the target at its nearest image so the HUD compass (which
        // does worldPos - camPos raw) points the short way and reads the true
        // ~distance, not ~32000m the wrong way across the seam. out.distance is
        // already nearest-image (bestd2 used wrap_signed_f above).
        out.position = bf_vec3 {
            x: self.pos.x + Self::wrap_signed_f(best.pos.x - self.pos.x),
            y: best.pos.y,
            z: self.pos.z + Self::wrap_signed_f(best.pos.z - self.pos.z),
        };
        out.distance = bestd2.sqrt();
        let mut lbl = String::new();
        let mut up = true;
        for ch in best.name.chars() {
            if ch == '_' {
                lbl.push(' ');
                up = true;
            } else if up && ch.is_ascii_lowercase() {
                lbl.push(ch.to_ascii_uppercase());
                up = false;
            } else {
                lbl.push(ch);
                up = false;
            }
        }
        Self::cstr_copy(&mut out.label, &lbl);
        true
    }

    fn fill_growth_artisan_target(&self, out: &mut bf_quest_target) -> bool {
        let artisan = match self.local_growth_artisan() {
            Some(c) => c,
            None => return false,
        };
        let dx = Self::wrap_signed_f(artisan.pos.x - self.pos.x);
        let dy = artisan.pos.y - self.pos.y;
        let dz = Self::wrap_signed_f(artisan.pos.z - self.pos.z);
        out.active = 1;
        out.position = bf_vec3 {
            x: self.pos.x + dx,
            y: artisan.pos.y,
            z: self.pos.z + dz,
        };
        out.distance = (dx * dx + dy * dy + dz * dz).sqrt();
        Self::cstr_copy(
            &mut out.label,
            match artisan.npc_id {
                4 => "Woodcutter - donate logs",
                5 => "Stone Mason - donate stone",
                6 if self.effective_village_tier(artisan.home_x, artisan.home_z) >= 3 => {
                    "Blacksmith - fortify the City"
                }
                6 => "Blacksmith - donate iron",
                _ => return false,
            },
        );
        true
    }

    pub fn debug_quests_completed(&self) -> i32 {
        self.quests_completed
    }

    pub fn debug_all_quests_done(&self) -> bool {
        self.all_quests_done
    }

    pub fn debug_active_quest(&self) -> u32 {
        match self.extra {
            Some(x) if self.active_quest < x.quests().len() && !self.all_quests_done => {
                x.quests()[self.active_quest].id
            }
            _ => 0,
        }
    }

    pub fn debug_notify(&mut self, trig: &str, target: &str) {
        self.notify_quest(trig, target);
    }

    pub fn debug_ach_toast(&self) -> &str {
        &self.ach_toast
    }

    pub fn debug_force_quest_done(&mut self) {
        self.quests_completed = 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../content");

    #[test]
    fn side_quest_is_villager_owned_persistent_and_not_part_of_main_arc() {
        let mut content = ContentRegistry::new();
        assert!(content.load(CONTENT));
        let mut extra = ContentExtra::new();
        assert!(extra.load(CONTENT));

        let path = std::env::temp_dir().join(format!(
            "blockfall-side-quest-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&path);

        let mut world = World::new(None);
        world.set_content(&content);
        world.set_extra(&extra);
        world.start_quest(0);
        world.inv = Some(Inventory::new(BF_INVENTORY_SLOTS, Some(&content)));
        let mut lena = Creature::default();
        lena.model = 20;
        lena.npc_id = 3;
        lena.home_x = 100;
        lena.home_z = 200;
        lena.dialogue_held = true;
        world.creatures.push(lena);

        assert!(world.side_quest_talk(102));
        assert_eq!(world.debug_active_quest(), 1, "main arc remains untouched");
        for _ in 0..8 {
            world.debug_notify("collect_item", "mushroom");
        }
        assert!(World::quest_done(
            &extra.quests()[world.active_side_quest.unwrap()],
            &world.side_obj_progress
        ));
        assert!(world.save(path.to_str().unwrap()));

        let mut loaded = World::new(None);
        loaded.set_content(&content);
        loaded.set_extra(&extra);
        loaded.inv = Some(Inventory::new(BF_INVENTORY_SLOTS, Some(&content)));
        assert!(loaded.load(path.to_str().unwrap()));
        assert_eq!(
            loaded.active_side_quest.map(|i| extra.quests()[i].id),
            Some(102)
        );
        assert_eq!(loaded.side_obj_progress, vec![8]);
        let mut loaded_lena = Creature::default();
        loaded_lena.model = 20;
        loaded_lena.npc_id = 3;
        loaded_lena.home_x = 100;
        loaded_lena.home_z = 200;
        loaded_lena.dialogue_held = true;
        loaded.creatures.push(loaded_lena);
        assert!(loaded.side_quest_talk(102));
        assert!(loaded.side_quests_done.contains(&102));
        assert!(loaded.active_side_quest.is_none());
        assert_eq!(loaded.debug_active_quest(), 1);

        let _ = std::fs::remove_dir_all(path);
    }
}
