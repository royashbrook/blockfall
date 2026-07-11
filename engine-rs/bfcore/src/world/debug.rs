use super::*;

impl<'c> World<'c> {
    pub fn debug_set_camera(&mut self, px: f32, py: f32, pz: f32, yaw: f32, pitch: f32) {
        self.pos = V3::new(px, py, pz);
        self.yaw = yaw;
        self.pitch = pitch;
    }
    pub fn debug_block_at(&self, x: i32, y: i32, z: i32) -> BlockId {
        self.block_at(IVec3 { x, y, z })
    }
    pub fn debug_collide_solid(&self, x: i32, y: i32, z: i32) -> bool {
        self.collide_solid(x, y, z)
    }
    pub fn debug_sky_light(&self, x: i32, y: i32, z: i32) -> i32 {
        let cc = Self::to_chunk(IVec3 { x, y, z });
        match self.store.get(cc) {
            Some(ch) => ch.sky_light(
                Self::mod16(x) as usize,
                Self::mod16(y) as usize,
                Self::mod16(z) as usize,
            ) as i32,
            None => -1,
        }
    }
    pub fn debug_edit(&mut self, x: i32, y: i32, z: i32, b: BlockId) {
        self.set_block_internal(IVec3 { x, y, z }, b);
    }
    pub fn debug_set_sync_streaming(&mut self, s: bool) {
        self.sync_stream = s;
    }
    /// Generate and insert the chunk containing a voxel through the same synchronous
    /// path used by stream_tick. Returns false when it was already resident or empty.
    pub fn debug_generate_chunk_at(&mut self, x: i32, y: i32, z: i32) -> bool {
        let cc = Self::canon_chunk(Self::to_chunk(IVec3 { x, y, z }));
        if self.store.is_resident(cc) {
            return false;
        }
        let Some(chunk) = self.gen_chunk(cc) else {
            return false;
        };
        if chunk.is_uniform() && chunk.get(0, 0, 0) == AIR {
            return false;
        }
        self.store.insert(chunk);
        self.dirty_chunk_and_resident_neighbours(cc);
        self.shadow.refill_cols.insert((cc.x, cc.z));
        true
    }
    pub fn debug_stream_back_is_nearest(&mut self) -> bool {
        self.recompute_stream_set();
        if self.gen_queue.len() < 2 {
            return true;
        }
        let back = *self.gen_queue.last().unwrap();
        let front = self.gen_queue[0];
        Self::dist2(back, self.last_center) <= Self::dist2(front, self.last_center)
    }
    pub fn debug_stream_active_radius(&self) -> i32 {
        self.stream_active_r
    }
    pub fn debug_stream_target_radius(&self) -> i32 {
        self.stream_r
    }
    pub fn debug_stream_backlog(&self) -> usize {
        self.stream_backlog()
    }
    pub fn debug_has_target(&self) -> bool {
        self.has_target
    }
    pub fn debug_set_selected(&mut self, s: u8) {
        self.selected = s;
    }
    /// #224: world seed accessor for the FFI map-biome fill.
    pub fn debug_seed(&self) -> u64 {
        self.seed
    }
    pub fn debug_region_sat(&self, cx: i32, cz: i32) -> f32 {
        self.region_sat(ChunkCoord { x: cx, y: 0, z: cz })
    }
    pub fn debug_item_id(&self, n: &str) -> ItemId {
        self.item_id_by_name(n)
    }
    pub fn debug_item_count(&self, id: ItemId) -> i32 {
        self.inv
            .as_ref()
            .map(|i| i.count_item(id) as i32)
            .unwrap_or(0)
    }
    pub fn debug_give(&mut self, id: ItemId, n: u16) {
        if let Some(inv) = self.inv.as_mut() {
            inv.add(ItemStack {
                item: id,
                count: n,
                durability: 0xFFFF,
            });
        }
    }
    pub fn debug_clear_inventory(&mut self) {
        if let Some(inv) = self.inv.as_mut() {
            for i in 0..BF_INVENTORY_SLOTS {
                inv.set(i, ItemStack::default());
            }
        }
    }
    /// #109 test helper: fill EVERY player inventory slot with a stack of `id` so the
    /// inventory is genuinely full (no room for a different item). Used to verify
    /// chest_take leaves items in the chest when nothing fits.
    pub fn debug_fill_inventory(&mut self, id: ItemId, count: u16) {
        if let Some(inv) = self.inv.as_mut() {
            for i in 0..BF_INVENTORY_SLOTS {
                inv.set(
                    i,
                    ItemStack {
                        item: id,
                        count,
                        durability: 0xFFFF,
                    },
                );
            }
        }
    }
    /// #109 test helper: read chest slot `slot` at world `(x,y,z)` as (item, count).
    /// Rolls the chest's loot lazily, like chest_slots.
    pub fn debug_chest_slot(&mut self, x: i32, y: i32, z: i32, slot: usize) -> (ItemId, u16) {
        match self.chest_slots(IVec3 { x, y, z }) {
            Some(slots) if slot < CHEST_SLOTS => (slots[slot].item, slots[slot].count),
            _ => (0, 0),
        }
    }
    pub fn debug_creature_count(&self) -> i32 {
        self.creatures.len() as i32
    }
    pub fn debug_creature_pos(&self, i: i32) -> (f32, f32, f32) {
        if i < 0 || i >= self.creatures.len() as i32 {
            return (0.0, 0.0, 0.0);
        }
        let c = &self.creatures[i as usize];
        (c.pos.x, c.pos.y, c.pos.z)
    }
    pub fn debug_set_creature_pos(&mut self, i: i32, x: f32, y: f32, z: f32) {
        if i >= 0 && i < self.creatures.len() as i32 {
            self.creatures[i as usize].pos = Self::wrap_v3_xz(V3::new(x, y, z));
        }
    }
    // Spawn a plain wandering creature at a precise position + heading and return its
    // index. Used by the locomotion tests to place a creature against a known step.
    // The wander timer is set high so the creature keeps its given yaw (it walks
    // straight at the step instead of randomly turning away) for the test window.
    pub fn debug_spawn_creature_at(&mut self, x: f32, y: f32, z: f32, yaw: f32, speed: f32) -> i32 {
        let mut c = Creature::default();
        c.pos = V3::new(x, y, z);
        c.yaw = yaw;
        c.speed = speed;
        c.scale = 1.0;
        c.hp = 5;
        c.wander = 1000.0;
        // Seed the AI straight-walk heading so the creature walks in `yaw` (the
        // locomotion tests place it against a known step). wander > 900 marks it
        // Scripted in update_creatures so it ignores the player and never re-rolls.
        c.ai.seed_straight(yaw);
        self.creatures.push(c);
        (self.creatures.len() - 1) as i32
    }
    pub fn debug_set_friendly(&mut self, i: i32) {
        if i >= 0 && i < self.creatures.len() as i32 {
            self.creatures[i as usize].friendly = true;
        }
    }
    // #179 test seam: turn a spawned creature into a plain follower pet
    // (friendly, not hostile, not scripted) so seam-following tests can use
    // the real Pet AI without driving the whole befriend interaction flow.
    pub fn debug_make_pet(&mut self, i: i32) {
        if i >= 0 && i < self.creatures.len() as i32 {
            let c = &mut self.creatures[i as usize];
            c.friendly = true;
            c.hostile = false;
            c.wander = 0.0;
        }
    }
    // #95 test helper: a hostile that hunts the player (used to prove a village wall keeps
    // monsters out of its protected interior).
    pub fn debug_spawn_hostile_at(&mut self, x: f32, y: f32, z: f32) -> i32 {
        let mut c = Creature::default();
        c.pos = V3::new(x, y, z);
        c.hostile = true;
        c.scale = 1.0;
        c.hp = 5;
        c.speed = 1.6;
        self.creatures.push(c);
        (self.creatures.len() - 1) as i32
    }
    // Spawn a villager with a specific profession at a settlement anchor, for tier tests.
    pub fn debug_spawn_villager_role(&mut self, ax: i32, az: i32, npc_id: i32) -> i32 {
        let mut c = Creature::default();
        c.model = 20;
        c.npc_id = npc_id;
        c.home_x = Self::wrap_block(ax);
        c.home_z = Self::wrap_block(az);
        let surf = worldgen::worldgen_surface_height(ax, az, self.seed);
        c.pos = V3::new(ax as f32, surf as f32, az as f32);
        self.creatures.push(c);
        (self.creatures.len() - 1) as i32
    }
    pub fn debug_villager_routine_action(&self, i: i32) -> u32 {
        if i < 0 {
            return 0;
        }
        self.creatures
            .get(i as usize)
            .filter(|c| c.model == 20 && c.npc_id == 4)
            .map(|c| c.routine.state.action())
            .unwrap_or(0)
    }
    pub fn debug_creature_path_len(&self, i: i32) -> usize {
        if i < 0 {
            return 0;
        }
        self.creatures
            .get(i as usize)
            .map(|c| c.ai.path.len().saturating_sub(c.ai.path_idx))
            .unwrap_or(0)
    }
    pub fn debug_villager_nearest_goal(cx: f32, cz: f32, gx: i32, gz: i32) -> (i32, i32) {
        Self::villager_nearest_goal(cx, cz, gx, gz)
    }
    // Run a donation against a villager index (the player must hold the item already).
    pub fn debug_try_donation(&mut self, idx: i32) -> bool {
        self.try_village_donation(idx as usize)
    }
    pub fn debug_set_wall_block(&mut self, wx: i32, wy: i32, wz: i32, b: BlockId) {
        self.set_block_internal(
            IVec3 {
                x: wx,
                y: wy,
                z: wz,
            },
            b,
        );
    }
    pub fn debug_grow_tree(&mut self, wx: i32, wz: i32) -> bool {
        let surf = self.surface_top(wx, wz);
        if surf == NO_FLOOR {
            return false;
        }
        self.grow_small_tree(wx, surf, wz);
        true
    }
    pub fn debug_villager_count(&self) -> i32 {
        self.creatures.iter().filter(|c| c.model == 20).count() as i32
    }
    pub fn debug_spawn_villagers_at(&mut self, x: i32, y: i32, z: i32, budget: i32) -> i32 {
        self.spawn_villager_at(x, y, z, budget)
    }
    pub fn debug_villagers_body_clear(&self) -> bool {
        self.creatures.iter().filter(|c| c.model == 20).all(|c| {
            !self.creature_body_blocked(c.pos.x, Self::ifloor(c.pos.y + 0.01), c.pos.z, c.scale)
        })
    }
    // Exposes the pure profession-assignment policy so tests can verify the chain rules
    // (city = full chain, village = ordered prefix) without driving a full settlement
    // spawn. Returns the npc_id role for the villager at `idx` within the settlement.
    pub fn debug_villager_npc_for_index(is_city: bool, idx: i32) -> i32 {
        Self::villager_npc_for_index(is_city, idx)
    }
    pub fn debug_boss_count(&self) -> i32 {
        self.creatures.iter().filter(|c| c.is_boss).count() as i32
    }
    pub fn debug_count_named(&self, nm: &str) -> i32 {
        self.creatures.iter().filter(|c| c.name == nm).count() as i32
    }
    pub fn debug_resident_count(&self) -> i32 {
        self.store.resident_count() as i32
    }
    pub fn debug_hostile_count(&self) -> i32 {
        self.creatures.iter().filter(|c| c.hostile).count() as i32
    }
    // tests: count only the ruin "danger site" hostiles (spawned independent of the
    // night/quest gate).
    pub fn debug_ruin_hostile_count(&self) -> i32 {
        self.creatures
            .iter()
            .filter(|c| c.hostile && c.from_ruin)
            .count() as i32
    }
    // tests: simulate the player clearing a ruin by removing all of its defenders.
    // Returns how many were removed.
    pub fn debug_kill_ruin_hostiles(&mut self) -> i32 {
        let before = self.creatures.len();
        self.creatures.retain(|c| !(c.hostile && c.from_ruin));
        (before - self.creatures.len()) as i32
    }
    // tests: true once the ruin site at anchor (ax, az) has been recorded as cleared
    // (its defenders were all killed and it has not yet re-armed).
    pub fn debug_ruin_site_cleared(&self, ax: i32, az: i32) -> bool {
        self.ruin_sites
            .get(&(ax, az))
            .map(|s| s.cleared)
            .unwrap_or(false)
    }
    pub fn debug_health(&self) -> f32 {
        self.health
    }
    // tests: per-second sprint speed for the current game mode (creative sprint is a
    // fast fly/run ~5x the survival sprint).
    pub fn debug_sprint_speed(&self) -> f32 {
        if self.mode == bf_game_mode::BF_MODE_CREATIVE {
            42.5
        } else {
            8.5
        }
    }
    pub fn debug_day_time(&self) -> f32 {
        Self::day_time(self.world_clock)
    }
    // tests: jump the world clock to a chosen day_time phase (0..1) so a test can
    // put the world into night without pumping ~5 minutes of frames.
    pub fn debug_set_day_time(&mut self, phase: f32) {
        // invert day_time: phase = (clock * DAY_RATE + DAY_START_PHASE) % 1.0
        self.world_clock = Self::clock_for_phase(phase);
    }
    pub fn debug_regions_restored(&self) -> i32 {
        self.regions_restored
    }
    pub fn debug_spawn_named(&mut self, nm: &str) {
        let mut c = Creature::default();
        c.name = nm.to_string();
        c.pos = self.pos + V3::new(5.0, -1.0, 0.0);
        c.hp = 5;
        c.scale = 1.0;
        if let Some(x) = self.extra {
            for d in x.creatures() {
                if d.name == c.name {
                    c.is_boss = d.disposition == "boss";
                    c.model = d.model;
                    break;
                }
            }
        }
        self.creatures.push(c);
    }
    pub fn debug_aim_at_creature0(&mut self) -> bool {
        if self.creatures.is_empty() {
            return false;
        }
        let cp = self.creatures[0].pos + V3::new(0.0, 0.5, 0.0);
        self.pos = cp + V3::new(0.0, 1.0, 3.0);
        let d = normalize(cp - self.pos);
        self.pitch = d.y.clamp(-0.999, 0.999).asin();
        self.yaw = d.x.atan2(d.z);
        true
    }
}
