use super::*;

impl<'c> World<'c> {
    // Only player-EDITED chunks are persisted; pure-procedural chunks regen from seed.
    pub fn save(&self, dir: &str) -> bool {
        use std::io::Write;
        if std::fs::create_dir_all(dir).is_err() {
            return false;
        }
        {
            let path = format!("{}/world.meta", dir);
            let mut f = match std::fs::File::create(&path) {
                Ok(f) => f,
                Err(_) => return false,
            };
            let mut buf: Vec<u8> = Vec::new();
            buf.extend_from_slice(b"BFWM");
            buf.extend_from_slice(&self.seed.to_le_bytes());
            let rc = self.region_sat.len() as u32;
            buf.extend_from_slice(&rc.to_le_bytes());
            for (k, v) in self.region_sat.iter() {
                buf.extend_from_slice(&k.x.to_le_bytes());
                buf.extend_from_slice(&k.z.to_le_bytes());
                buf.extend_from_slice(&v.to_le_bytes());
            }
            // #263: append instead of changing the legacy BFWM prefix/layout, so
            // old saves still load and new saves resume at the exact world time.
            buf.extend_from_slice(b"BFTM");
            buf.extend_from_slice(&self.world_clock.to_le_bytes());
            if f.write_all(&buf).is_err() {
                return false;
            }
        }
        {
            let path = format!("{}/player.dat", dir);
            let mut buf: Vec<u8> = Vec::new();
            buf.extend_from_slice(b"BFPL");
            buf.extend_from_slice(&self.pos.x.to_le_bytes());
            buf.extend_from_slice(&self.pos.y.to_le_bytes());
            buf.extend_from_slice(&self.pos.z.to_le_bytes());
            buf.extend_from_slice(&self.yaw.to_le_bytes());
            buf.extend_from_slice(&self.pitch.to_le_bytes());
            buf.push(self.mode as i32 as u8);
            buf.extend_from_slice(&self.health.to_le_bytes());
            buf.extend_from_slice(&self.hunger.to_le_bytes());
            buf.push(self.selected);
            for i in 0..BF_INVENTORY_SLOTS {
                let s = self.inv.as_ref().map(|inv| inv.get(i)).unwrap_or_default();
                buf.extend_from_slice(&s.item.to_le_bytes());
                buf.extend_from_slice(&s.count.to_le_bytes());
                buf.extend_from_slice(&s.durability.to_le_bytes());
            }
            buf.extend_from_slice(b"BFQ1");
            buf.extend_from_slice(&(self.active_quest as u32).to_le_bytes());
            buf.extend_from_slice(&(self.quests_completed as u32).to_le_bytes());
            buf.push(if self.all_quests_done { 1 } else { 0 });
            buf.extend_from_slice(&(self.obj_progress.len() as u32).to_le_bytes());
            for &v in &self.obj_progress {
                buf.extend_from_slice(&v.to_le_bytes());
            }
            buf.extend_from_slice(&(K_ACHIEVEMENT_COUNT as u32).to_le_bytes());
            for i in 0..K_ACHIEVEMENT_COUNT {
                buf.push(if self.ach_done[i] { 1 } else { 0 });
                buf.extend_from_slice(&self.ach_progress[i].to_le_bytes());
            }
            let mut f = match std::fs::File::create(&path) {
                Ok(f) => f,
                Err(_) => return false,
            };
            if f.write_all(&buf).is_err() {
                return false;
            }
        }
        for &cc in &self.edited {
            let ch = match self.store.get(cc) {
                Some(c) => c,
                None => continue,
            };
            let bytes = ch.serialize();
            if bytes.is_empty() {
                continue;
            }
            let name = format!("{}/c_{}_{}_{}.chunk", dir, cc.x, cc.y, cc.z);
            let mut f = match std::fs::File::create(&name) {
                Ok(f) => f,
                Err(_) => return false,
            };
            if f.write_all(&bytes).is_err() {
                return false;
            }
        }
        {
            let path = format!("{}/chests.dat", dir);
            let mut buf: Vec<u8> = Vec::new();
            buf.extend_from_slice(b"BFCH");
            let filled: Vec<(&(i32, i32, i32), &ChestData)> =
                self.chests.iter().filter(|(_, c)| c.filled).collect();
            buf.extend_from_slice(&(filled.len() as u32).to_le_bytes());
            buf.extend_from_slice(&(CHEST_SLOTS as u32).to_le_bytes());
            for (&(x, y, z), c) in filled {
                buf.extend_from_slice(&x.to_le_bytes());
                buf.extend_from_slice(&y.to_le_bytes());
                buf.extend_from_slice(&z.to_le_bytes());
                for s in &c.slots {
                    buf.extend_from_slice(&s.item.to_le_bytes());
                    buf.extend_from_slice(&s.count.to_le_bytes());
                    buf.extend_from_slice(&s.durability.to_le_bytes());
                }
            }
            let mut f = match std::fs::File::create(&path) {
                Ok(f) => f,
                Err(_) => return false,
            };
            if f.write_all(&buf).is_err() {
                return false;
            }
        }
        {
            let path = format!("{}/villages.dat", dir);
            let mut buf: Vec<u8> = Vec::new();
            buf.extend_from_slice(b"BFV2");
            buf.extend_from_slice(&(self.villages.len() as u32).to_le_bytes());
            for (&(ax, az), v) in self.villages.iter() {
                buf.extend_from_slice(&ax.to_le_bytes());
                buf.extend_from_slice(&az.to_le_bytes());
                buf.push(v.tier);
                buf.push(v.lights);
                buf.extend_from_slice(&v.wood_cells.to_le_bytes());
                buf.extend_from_slice(&v.progress.to_le_bytes());
            }
            let mut f = match std::fs::File::create(&path) {
                Ok(f) => f,
                Err(_) => return false,
            };
            if f.write_all(&buf).is_err() {
                return false;
            }
        }
        // #182 world map + warp totems: explored bits + markers (map.dat).
        if !self.save_map_dat(dir) {
            return false;
        }
        true
    }

    pub fn load(&mut self, dir: &str) -> bool {
        let meta = match std::fs::read(format!("{}/world.meta", dir)) {
            Ok(b) => b,
            Err(_) => return false,
        };
        let mut r = ByteReader::new(&meta);
        if r.take(4) != Some(b"BFWM") {
            return false;
        }
        self.seed = match r.u64() {
            Some(v) => v,
            None => return false,
        };
        if let Some(g) = self.gen.as_mut() {
            g.seed(self.seed);
        }
        let rc = r.u32().unwrap_or(0);
        self.region_sat.clear();
        for _ in 0..rc {
            let x = r.i32();
            let z = r.i32();
            let v = r.f32();
            if let (Some(x), Some(z), Some(v)) = (x, z, v) {
                self.region_sat.insert(RegionKey { x, z }, v);
            } else {
                break; // #216: truncated/garbage region count must not spin to EOF
            }
        }
        // #263: BFTM is an optional trailer. Saves written before it simply keep
        // the fresh-world clock, while corrupt/non-finite clocks are ignored.
        if r.take(4) == Some(b"BFTM") {
            if let Some(clock) = r.f64().filter(|clock| clock.is_finite() && *clock >= 0.0) {
                self.world_clock = clock;
            }
        }
        let mut quest_loaded = false;
        if let Ok(pl) = std::fs::read(format!("{}/player.dat", dir)) {
            let mut p = ByteReader::new(&pl);
            if p.take(4) == Some(b"BFPL") {
                self.pos.x = p.f32().unwrap_or(self.pos.x);
                self.pos.y = p.f32().unwrap_or(self.pos.y);
                self.pos.z = p.f32().unwrap_or(self.pos.z);
                self.yaw = p.f32().unwrap_or(self.yaw);
                self.pitch = p.f32().unwrap_or(self.pitch);
                let m = p.u8().unwrap_or(self.mode as i32 as u8);
                self.mode = if m == 1 {
                    bf_game_mode::BF_MODE_CREATIVE
                } else {
                    bf_game_mode::BF_MODE_SURVIVAL
                };
                self.health = p.f32().unwrap_or(self.health);
                self.hunger = p.f32().unwrap_or(self.hunger);
                self.selected = p.u8().unwrap_or(self.selected);
                for i in 0..BF_INVENTORY_SLOTS {
                    let item = p.u16().unwrap_or(0);
                    let count = p.u16().unwrap_or(0);
                    let durability = p.u16().unwrap_or(0xFFFF);
                    if let Some(inv) = self.inv.as_mut() {
                        inv.set(
                            i,
                            ItemStack {
                                item,
                                count,
                                durability,
                            },
                        );
                    }
                }
                if p.take(4) == Some(b"BFQ1") {
                    let aq = p.u32().unwrap_or(0);
                    let qc = p.u32().unwrap_or(0);
                    let aqd = p.u8().unwrap_or(0);
                    let opn = p.u32().unwrap_or(0);
                    self.start_quest(aq as usize);
                    // #216: cap by the array size so a garbage count cannot spin.
                    for i in 0..opn.min(self.obj_progress.len() as u32) {
                        let v = p.u32().unwrap_or(0);
                        if (i as usize) < self.obj_progress.len() {
                            self.obj_progress[i as usize] = v;
                        }
                    }
                    self.quests_completed = qc as i32;
                    self.all_quests_done = aqd != 0;
                    let an = p.u32().unwrap_or(0);
                    for i in 0..an.min(K_ACHIEVEMENT_COUNT as u32) {
                        // #216 cap
                        let dn = p.u8().unwrap_or(0);
                        let pr = p.i32().unwrap_or(0);
                        if (i as usize) < K_ACHIEVEMENT_COUNT {
                            self.ach_done[i as usize] = dn != 0;
                            self.ach_progress[i as usize] = pr;
                        }
                    }
                    self.ach_done_count = 0;
                    for i in 0..K_ACHIEVEMENT_COUNT {
                        if self.ach_done[i] {
                            self.ach_done_count += 1;
                        }
                    }
                    quest_loaded = true;
                }
            }
        }
        // #179: canonicalize loaded positions onto the torus (pre-wrap saves
        // with coords already in [0, WORLD_PERIOD) are untouched).
        self.pos.x = Self::wrap_pos_f(self.pos.x);
        self.pos.z = Self::wrap_pos_f(self.pos.z);
        self.spawn = self.pos;
        if self.health <= 0.0 {
            self.health = 20.0;
        }
        if let Ok(rd) = std::fs::read_dir(dir) {
            for entry in rd.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("chunk") {
                    continue;
                }
                let bytes = match std::fs::read(&path) {
                    Ok(b) => b,
                    Err(_) => continue,
                };
                if bytes.is_empty() {
                    continue;
                }
                if let Some(ch) = PaletteChunk::deserialize(&bytes) {
                    // #179: canonical key (old saves may hold negative coords).
                    let cc = Self::canon_chunk(ch.coord());
                    self.store.insert(ch);
                    self.mark_dirty(cc);
                    self.edited.insert(cc);
                }
            }
        }
        self.chests.clear();
        if let Ok(b) = std::fs::read(format!("{}/chests.dat", dir)) {
            let mut cr = ByteReader::new(&b);
            if cr.take(4) == Some(b"BFCH") {
                let n = cr.u32().unwrap_or(0);
                let slots = (cr.u32().unwrap_or(CHEST_SLOTS as u32) as usize).min(CHEST_SLOTS); // #216 cap
                for _ in 0..n {
                    let x = cr.i32();
                    let y = cr.i32();
                    let z = cr.i32();
                    let (x, y, z) = match (x, y, z) {
                        (Some(x), Some(y), Some(z)) => (x, y, z),
                        _ => break,
                    };
                    let mut data = ChestData {
                        slots: [ItemStack::default(); CHEST_SLOTS],
                        filled: true,
                    };
                    for i in 0..slots {
                        let item = cr.u16().unwrap_or(0);
                        let count = cr.u16().unwrap_or(0);
                        let durability = cr.u16().unwrap_or(0xFFFF);
                        if i < CHEST_SLOTS {
                            data.slots[i] = ItemStack {
                                item,
                                count,
                                durability,
                            };
                        }
                    }
                    self.chests
                        .insert((Self::wrap_block(x), y, Self::wrap_block(z)), data);
                }
            }
        }
        self.villages.clear();
        if let Ok(b) = std::fs::read(format!("{}/villages.dat", dir)) {
            let mut cr = ByteReader::new(&b);
            let magic = cr.take(4);
            if magic == Some(b"BFVL") || magic == Some(b"BFV2") {
                let has_lights = magic == Some(b"BFV2");
                let n = cr.u32().unwrap_or(0);
                for _ in 0..n {
                    let ax = cr.i32();
                    let az = cr.i32();
                    let (ax, az) = match (ax, az) {
                        (Some(ax), Some(az)) => (ax, az),
                        _ => break,
                    };
                    let tier = cr.u8().unwrap_or(0);
                    let lights = if has_lights { cr.u8().unwrap_or(0) } else { 0 };
                    let wood_cells = cr.i32().unwrap_or(0);
                    let progress = cr.i32().unwrap_or(0);
                    self.villages.insert(
                        (Self::wrap_block(ax), Self::wrap_block(az)),
                        VillageState {
                            tier,
                            lights,
                            wood_cells,
                            progress,
                        },
                    );
                }
            }
        }
        let wards: Vec<(i32, i32)> = self
            .villages
            .iter()
            .filter_map(|(&(ax, az), v)| (v.lights >= 8).then_some((ax, az)))
            .collect();
        for (ax, az) in wards {
            self.restore_village_ward(ax, az);
        }
        // #319: saves made before the raised portcullis fix have solid bars in
        // the only city exit. Move that exact legacy layout overhead on load.
        self.repair_legacy_city_gates();
        // #256 growth is tier-derived. Fresh chunks receive it during generation;
        // resident old-save chunks are refreshed only when their column has no saved
        // edits, preserving player builds and legacy plot changes conservatively.
        self.refresh_all_resident_settlement_growth();
        // #182 map progress (explored bits + totems + visited villages).
        // Missing/old saves simply start with an empty map (load_map_dat resets).
        self.load_map_dat(dir);
        // #255/#256 road geometry is rebuilt from seed + effective settlement
        // class after map.dat is loaded, so discovered natural cities participate.
        self.rebuild_road_routes();
        {
            let px = Self::ifloor(self.pos.x);
            let pz = Self::ifloor(self.pos.z);
            self.reveal_render_radius(px, pz); // #191 reveal at render-distance scale on load
            // #241: HOME is always lit. Worlds saved before the home-clearing
            // feature (or before spawn moved to a settlement) have map.dat bits
            // with a dark spawn; re-reveal the clearing on every load.
            self.reveal_circle(
                Self::ifloor(self.spawn.x),
                Self::ifloor(self.spawn.z),
                crate::world::HOME_CLEARING_CELLS,
            );
        }
        self.ensure_clear_spawn();
        self.refresh_resident_roads();
        self.last_center = Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        });
        self.first_stream = true;
        self.stream_active_r = 2.min(self.stream_r);
        self.creatures.clear();
        self.creature_timer = 0.0;
        self.assault_cooldown = 0.0;
        self.assault_wave_serial = 0;
        self.ruin_sites.clear();
        self.danger_timer = 0.0;
        if !quest_loaded {
            self.start_quest(0);
        }
        self.recompute_stream_set();
        true
    }
}

pub(super) struct ByteReader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> ByteReader<'a> {
    pub(super) fn new(buf: &'a [u8]) -> Self {
        ByteReader { buf, pos: 0 }
    }
    pub(super) fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.pos + n > self.buf.len() {
            return None;
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Some(s)
    }
    pub(super) fn u8(&mut self) -> Option<u8> {
        let b = self.take(1)?;
        Some(b[0])
    }
    pub(super) fn u16(&mut self) -> Option<u16> {
        let b = self.take(2)?;
        Some(u16::from_le_bytes([b[0], b[1]]))
    }
    pub(super) fn u32(&mut self) -> Option<u32> {
        let b = self.take(4)?;
        Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
    pub(super) fn i32(&mut self) -> Option<i32> {
        let b = self.take(4)?;
        Some(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
    pub(super) fn u64(&mut self) -> Option<u64> {
        let b = self.take(8)?;
        Some(u64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }
    pub(super) fn f32(&mut self) -> Option<f32> {
        let b = self.take(4)?;
        Some(f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
    pub(super) fn f64(&mut self) -> Option<f64> {
        let b = self.take(8)?;
        Some(f64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }
}
