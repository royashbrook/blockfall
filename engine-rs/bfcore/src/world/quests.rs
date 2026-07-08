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
        if self.active_quest >= extra.quests().len() {
            return;
        }
        let q = &extra.quests()[self.active_quest];
        if self.obj_progress.len() != q.objectives.len() {
            return;
        }
        let mut changed = false;
        for (i, o) in q.objectives.iter().enumerate() {
            if o.trigger == trig
                && (o.target.is_empty() || o.target == target)
                && self.obj_progress[i] < o.count
            {
                self.obj_progress[i] += 1;
                changed = true;
            }
        }
        if changed && Self::quest_done(q, &self.obj_progress) {
            let rewards: Vec<(String, u32)> = q.rewards.clone();
            let next = self.active_quest + 1;
            let total = extra.quests().len();
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
            if next < total {
                self.start_quest(next);
            } else {
                self.all_quests_done = true;
            }
        }
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
            let done = self.all_quests_done || (i as u32) < self.active_quest as u32;
            let active = !self.all_quests_done && i == self.active_quest;
            e.state = if done {
                bf_quest_state::BF_QUEST_DONE as u8
            } else if active {
                bf_quest_state::BF_QUEST_ACTIVE as u8
            } else {
                bf_quest_state::BF_QUEST_UPCOMING as u8
            };
            if active && self.obj_progress.len() == q.objectives.len() {
                let mut cdone = 0u32;
                let mut total = 0u32;
                let mut objtext = "";
                for (k, o) in q.objectives.iter().enumerate() {
                    total += o.count;
                    cdone += self.obj_progress[k].min(o.count);
                    if self.obj_progress[k] < o.count && objtext.is_empty() {
                        objtext = &o.text;
                    }
                }
                Self::cstr_copy(
                    &mut e.objective,
                    if !objtext.is_empty() { objtext } else { "..." },
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
