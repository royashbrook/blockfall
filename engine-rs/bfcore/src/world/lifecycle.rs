use super::*;

impl<'c> World<'c> {
    /// Construct with a fresh mesher and an optional worldgen (the C++ ctor takes
    /// IMesher& and IWorldGen*; here both are owned). Pass `None` for the flat-test
    /// path that uses generate_test_world.
    pub fn new(gen: Option<TerrainGen>) -> World<'c> {
        World {
            mesher: GreedyMesher::new(),
            gen,
            store: ChunkStore::new(),
            alloc: bf_gpu_allocator {
                user: std::ptr::null_mut(),
                alloc: None,
                free_: None,
            },
            has_alloc: false,
            meshes: HashMap::new(),
            dirty: HashSet::new(),
            urgent_dirty: HashSet::new(),
            region_sat: HashMap::new(),
            edited: HashSet::new(),
            gen_queue: Vec::new(),
            last_center: ChunkCoord { x: 0, y: 0, z: 0 },
            first_stream: true,
            seed: 0,
            pos: V3::new(0.0, 12.0, 0.0),
            yaw: 0.0,
            pitch: 0.0,
            mode: bf_game_mode::BF_MODE_CREATIVE,
            health: 20.0,
            hunger: 20.0,
            selected: 0,
            mining: false,
            vy: 0.0,
            on_ground: false,
            bob_phase: 0.0,
            bob_amt: 0.0,
            world_clock: 0.0,
            time_mode: 0,
            weather: 0,
            spawn: V3::new(0.0, 12.0, 0.0),
            hurt_cd: 0.0,
            regen_cd: 0.0,
            oxygen: 1.0,
            drown_cd: 0.0,
            content: None,
            inv: None,
            glow_id: GLOW,
            beacon_id: 0,
            inv_open: false,
            creatures: Vec::new(),
            falling: Vec::new(),
            debris: Vec::new(),
            entities: Vec::new(),
            entity_role_actions: Vec::new(),
            entity_appearances: Vec::new(),
            creature_timer: 0.0,
            villager_timer: 0.0,
            danger_timer: 0.0,
            ruin_sites: HashMap::new(),
            chests: HashMap::new(),
            last_chest_open: None,
            villages: HashMap::new(),
            road_routes: Vec::new(),
            regrow_timer: 3.0,
            rng: 0x1234567,
            regions_restored: 0,
            creatures_befriended: 0,
            creatures_calmed: 0,
            extra: None,
            active_quest: 0,
            obj_progress: Vec::new(),
            all_quests_done: false,
            quests_completed: 0,
            difficulty: 1,
            ach_progress: [0; K_ACHIEVEMENT_COUNT],
            ach_done: [false; K_ACHIEVEMENT_COUNT],
            ach_done_count: 0,
            ach_toast: String::new(),
            ach_toast_timer: 0.0,
            edit_cb: None,
            fx_cb: None,
            step_timer: 0.0,
            remote_avatars: Vec::new(),
            remote_avatar_appearances: Vec::new(),
            mine_progress: 0.0,
            has_target: false,
            target: IVec3::default(),
            place: IVec3::default(),
            stream_r: render_units_to_chunk_radius(6),
            stream_active_r: 2,
            hyperspeed: false,
            surf_cy_cache: HashMap::new(),
            sync_stream: false,
            moving: false,
            pool: None,
            gen_tx: None,
            gen_rx: None,
            mesh_tx: None,
            mesh_rx: None,
            gen_inflight: HashSet::new(),
            mesh_inflight: HashSet::new(),
            pending_gen_results: Vec::new(),
            pending_mesh_results: Vec::new(),
            unlit_far_meshes: HashSet::new(),
            mesh_versions: HashMap::new(),
            mesh_next_version: 0,
            explored: vec![0u8; crate::world::MAP_EXPLORED_BYTES],
            totems: Vec::new(),
            totem_next: 0,
            visited_villages: Vec::new(),
            last_reveal_pos: None,
            shadow: ShadowVol::new(),
        }
    }

    // ---- configuration setters ------------------------------------------
    pub fn set_allocator(&mut self, a: bf_gpu_allocator) {
        self.alloc = a;
        self.has_alloc = true;
    }
    pub fn set_mode(&mut self, m: bf_game_mode) {
        self.mode = m;
    }
    pub fn set_render_distance(&mut self, chunks: i32) {
        self.stream_r = render_units_to_chunk_radius(chunks);
        self.stream_active_r = self.stream_active_r.clamp(2, self.stream_r);
    }
    pub fn apply_render_distance(&mut self, chunks: i32) {
        self.set_render_distance(chunks);
        self.recompute_stream_set();
    }
    pub fn set_edit_callback(&mut self, cb: EditCb) {
        self.edit_cb = Some(cb);
    }
    /// Remove the local-edit callback (co-op teardown: stop replicating edits).
    pub fn clear_edit_callback(&mut self) {
        self.edit_cb = None;
    }
    pub fn apply_remote_edit(&mut self, w: IVec3, b: BlockId) {
        self.set_block_remote(w, b, true);
    }
    pub fn set_extra(&mut self, x: &'c ContentExtra) {
        self.extra = Some(x);
    }
    pub fn set_fx_callback(&mut self, cb: FxCb) {
        self.fx_cb = Some(cb);
    }
    pub fn get_player(&self) -> (f32, f32, f32, f32) {
        (self.pos.x, self.pos.y, self.pos.z, self.yaw)
    }
    pub fn world_seed(&self) -> u64 {
        self.seed
    }
    pub fn set_remote_avatars(&mut self, a: Vec<bf_entity_draw>, appearances: Vec<bf_player_appearance>) {
        debug_assert_eq!(a.len(), appearances.len());
        self.remote_avatars = a;
        self.remote_avatar_appearances = appearances;
    }
    pub fn mode(&self) -> bf_game_mode {
        self.mode
    }

    pub(super) fn fx(&mut self, code: i32, p: IVec3, extra: i32) {
        if let Some(cb) = self.fx_cb.as_mut() {
            cb(code, p, extra);
        }
    }

    /// Wire the loaded content. Builds the inventory + resolves the gameplay block ids
    /// by name (so the engine never hard-codes content ids), then hands out the
    /// mode-appropriate starter items.
    pub fn set_content(&mut self, c: &'c ContentRegistry) {
        self.content = Some(c);
        self.inv = Some(Inventory::new(BF_INVENTORY_SLOTS, Some(c)));
        self.glow_id = self.block_id_by_name("glow_block");
        self.beacon_id = self.block_id_by_name("beacon_block");
        self.give_starter_items();
    }

    pub fn item_id_by_name(&self, n: &str) -> ItemId {
        self.content
            .and_then(|c| c.item_by_name(n))
            .map(|d| d.id)
            .unwrap_or(0)
    }
    pub fn block_id_by_name(&self, n: &str) -> BlockId {
        self.content
            .and_then(|c| c.block_by_name(n))
            .map(|d| d.id)
            .unwrap_or(0)
    }
    pub(super) fn item_name(&self, i: ItemId) -> String {
        self.content
            .and_then(|c| c.item_by_id(i))
            .map(|d| d.name.clone())
            .unwrap_or_default()
    }
    pub(super) fn block_name(&self, b: BlockId) -> String {
        self.content
            .and_then(|c| c.block_by_id(b))
            .map(|d| d.name.clone())
            .unwrap_or_default()
    }

    fn give_starter_items(&mut self) {
        // Resolve ids first (immutable content borrow) then write (mutable inv borrow).
        if self.mode == bf_game_mode::BF_MODE_CREATIVE {
            let hot: [&str; BF_HOTBAR_SLOTS] = [
                "glow_block",
                "stone",
                "oak_planks",
                "stone_brick",
                "sand",
                "oak_log",
                "torch",
                "chest",
                "crafting_table",
            ];
            for (i, name) in hot.iter().enumerate() {
                let id = self.item_id_by_name(name);
                if id != 0 {
                    if let Some(inv) = self.inv.as_mut() {
                        inv.set(
                            i,
                            ItemStack {
                                item: id,
                                count: 64,
                                durability: 0xFFFF,
                            },
                        );
                    }
                }
            }
        } else {
            let log = self.item_id_by_name("oak_log");
            let coal = self.item_id_by_name("coal");
            let stick = self.item_id_by_name("stick");
            if let Some(inv) = self.inv.as_mut() {
                if log != 0 {
                    inv.set(
                        0,
                        ItemStack {
                            item: log,
                            count: 3,
                            durability: 0xFFFF,
                        },
                    );
                }
                if coal != 0 {
                    inv.set(
                        9,
                        ItemStack {
                            item: coal,
                            count: 2,
                            durability: 0xFFFF,
                        },
                    );
                }
                if stick != 0 {
                    inv.set(
                        10,
                        ItemStack {
                            item: stick,
                            count: 2,
                            durability: 0xFFFF,
                        },
                    );
                }
            }
        }
    }

    // ---- M2: procedural spawn + streaming --------------------------------
    pub fn init_world(&mut self, seed: u64) {
        self.seed = seed;
        self.villages.clear();
        self.road_routes.clear();
        if self.gen.is_none() {
            self.generate_test_world();
            return;
        }
        if let Some(g) = self.gen.as_mut() {
            g.seed(seed);
        }
        // Pick a DRY-LAND spawn column near the origin (never wake up in water).
        // #: real oceans can put the origin in open water, and a whole coast can be
        // wider than the old 120-block search. Search outward in expanding rings far
        // enough to clear an ocean and reach the nearest shore (step 8, up to ~768
        // blocks). The scan is a one-time cheap height lookup per ring cell.
        const SEA_LEVEL: i32 = 6;
        const SPAWN_STEP: i32 = 8;
        const SPAWN_MAX_R: i32 = 96; // 96 * 8 = 768 blocks of reach
        let mut sx = 0i32;
        let mut sz = 0i32;
        // #248: HOME starts beside a CITY. Search cities first, then retain #190's
        // nearest-settlement fallback for defensive compatibility if generation ever
        // changes. Offset off the anchor so the player stands at the plaza edge, not
        // inside the civic marker.
        let mut found_home = false;
        if let Some((_typ, ax, az)) = worldgen::worldgen_city_near(0, 0, 2048, self.seed) {
            // Dry check: settlements sit on land, but verify so a shoreline
            // anchor can never put the bed in the water.
            if worldgen::worldgen_surface_height(ax, az, self.seed) >= SEA_LEVEL + 1 {
                sx = ax + 2;
                sz = az + 2;
                found_home = true;
            }
        }
        if !found_home {
            if let Some((_typ, ax, az)) =
                worldgen::worldgen_settlement_near(0, 0, 2048, self.seed)
            {
                if worldgen::worldgen_surface_height(ax, az, self.seed) >= SEA_LEVEL + 1 {
                    sx = ax + 2;
                    sz = az + 2;
                    found_home = true;
                }
            }
        }
        if !found_home && worldgen::worldgen_surface_height(0, 0, self.seed) < SEA_LEVEL + 1 {
            let mut dry = false;
            let mut r = 1;
            while r <= SPAWN_MAX_R && !dry {
                let mut dz = -r;
                while dz <= r && !dry {
                    let mut dx = -r;
                    while dx <= r && !dry {
                        let adx = if dx < 0 { -dx } else { dx };
                        let adz = if dz < 0 { -dz } else { dz };
                        if adx.max(adz) != r {
                            dx += 1;
                            continue;
                        }
                        let wx = dx * SPAWN_STEP;
                        let wz = dz * SPAWN_STEP;
                        if worldgen::worldgen_surface_height(wx, wz, self.seed) >= SEA_LEVEL + 1 {
                            sx = wx;
                            sz = wz;
                            dry = true;
                        }
                        dx += 1;
                    }
                    dz += 1;
                }
                r += 1;
            }
        }
        // #179: canonical spawn column (the ring search can land negative).
        let sx = Self::wrap_block(sx);
        let sz = Self::wrap_block(sz);
        // Engine handles can be reused for a fresh world. Drop old discoveries
        // before deriving the new seed's HOME road network.
        self.visited_villages.clear();
        // #256: the effective-complete HOME city owns a paved route from the
        // first generated frame; no synthetic raw tier is needed or persisted.
        self.rebuild_road_routes();
        // Find the surface at the chosen spawn column.
        let scol = Self::to_chunk(IVec3 { x: sx, y: 0, z: sz });
        let slx = Self::mod16(sx);
        let slz = Self::mod16(sz);
        let mut surface = 8;
        let mut found = false;
        for cy in (CY_MIN..=CY_MAX).rev() {
            let cc = ChunkCoord {
                x: scol.x,
                y: cy,
                z: scol.z,
            };
            let ch = match self.gen_chunk(cc) {
                Some(c) => c,
                None => continue,
            };
            if !found {
                for ly in (0..KCHUNK_DIM).rev() {
                    if ch.get(slx as usize, ly as usize, slz as usize) != AIR {
                        surface = cy * KCHUNK_DIM + ly;
                        found = true;
                        break;
                    }
                }
            }
            if !(ch.is_uniform() && ch.get(0, 0, 0) == AIR) {
                self.store.insert(ch);
                self.mark_dirty(cc);
            }
        }
        // Eye 3.2 above the surface so the feet clear the top block.
        self.pos = V3::new(sx as f32 + 0.5, surface as f32 + 3.2, sz as f32 + 0.5);
        self.spawn = self.pos;
        // #197: face NORTH on spawn (yaw pi => forward is -z; north is -z / map up),
        // so a fresh spawn reads "N" on the compass instead of the old 0.6 (SE).
        self.yaw = std::f32::consts::PI;
        self.pitch = -0.25;
        // Spawn homeland starts colourful out to a generous radius.
        {
            let sr = Self::region_key(ChunkCoord {
                x: scol.x,
                y: 0,
                z: scol.z,
            });
            // #179: wrap the ring onto the torus region grid so a spawn near
            // the seam still colours the regions on the other side.
            let region_count = WRAP_CHUNKS / KREGION_CHUNKS;
            for dz in -2..=2 {
                for dx in -2..=2 {
                    self.region_sat.insert(
                        RegionKey {
                            x: (sr.x + dx).rem_euclid(region_count),
                            z: (sr.z + dz).rem_euclid(region_count),
                        },
                        1.0,
                    );
                }
            }
        }
        self.last_center = Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        });
        self.stream_active_r = 2.min(self.stream_r);
        self.recompute_stream_set();
        self.creatures.clear();
        self.debris.clear();
        self.chests.clear();
        // #182 fresh world: reset map progress and reveal the spawn area.
        self.explored = vec![0u8; crate::world::MAP_EXPLORED_BYTES];
        self.totems.clear();
        self.totem_next = 0;
        self.last_reveal_pos = None;
        // #189: reveal a round clearing centred on spawn so HOME reads dead-centre
        // of the non-grey circle, not at the edge of the trail walked after landing.
        self.reveal_circle(sx, sz, crate::world::HOME_CLEARING_CELLS);
        // #233: anchor the movement sweep at spawn so even the first hop away
        // reveals its whole path.
        self.last_reveal_pos = Some((Self::wrap_block(sx), Self::wrap_block(sz)));
        self.creature_timer = 0.0;
        self.all_quests_done = false;
        self.quests_completed = 0;
        self.difficulty = 1; // #238: back to Normal until the app re-applies its saved pick
        self.regions_restored = 0;
        self.start_quest(0);
        self.ensure_clear_spawn();
    }

    pub(super) fn ensure_clear_spawn(&mut self) {
        if self.gen.is_none() {
            return;
        }
        let pc = Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        });
        for cy in (CY_MIN..=CY_MAX).rev() {
            let cc = ChunkCoord {
                x: pc.x,
                y: cy,
                z: pc.z,
            };
            if self.store.is_resident(cc) {
                continue;
            }
            if let Some(ch) = self.gen_chunk(cc) {
                if !(ch.is_uniform() && ch.get(0, 0, 0) == AIR) {
                    self.store.insert(ch);
                    self.mark_dirty(cc);
                }
            }
        }
        if self.box_collides(self.pos) {
            let mut i = 0;
            while i < 64 && self.box_collides(self.pos) {
                self.pos.y += 1.0;
                i += 1;
            }
            self.pos.y += 0.1;
            self.vy = 0.0;
            self.spawn = self.pos;
        }
    }

    // ---- flat world (deterministic mine/place test) ----------------------
    pub fn generate_test_world(&mut self) {
        let r = 2;
        for cx in -r..=r {
            for cz in -r..=r {
                let cc = ChunkCoord { x: cx, y: 0, z: cz };
                {
                    let ch = self.store.get_or_create(cc);
                    for lx in 0..KCHUNK_DIM {
                        for lz in 0..KCHUNK_DIM {
                            for ly in 0..8 {
                                let b = if ly == 7 {
                                    GRASS
                                } else if ly >= 4 {
                                    DIRT
                                } else {
                                    STONE
                                };
                                ch.set(lx as usize, ly as usize, lz as usize, b);
                            }
                        }
                    }
                }
                self.mark_dirty(cc);
                self.restore_region(cc);
            }
        }
        self.pos = V3::new(8.0, 12.0, 8.0);
        self.yaw = 3.14159;
        self.pitch = -0.5;
    }
}
