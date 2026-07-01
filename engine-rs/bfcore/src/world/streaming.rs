use super::*;

impl<'c> World<'c> {
    pub(super) fn recompute_stream_set(&mut self) {
        self.gen_queue.clear();
        let c = self.last_center;
        let creative = self.mode == bf_game_mode::BF_MODE_CREATIVE;
        let target_r = self.stream_active_r.clamp(2, self.stream_r);
        let near_r = 5.min(target_r);
        let player_cy = Self::floordiv(Self::ifloor(self.pos.y), KCHUNK_DIM);
        for dx in -target_r..=target_r {
            for dz in -target_r..=target_r {
                let near = creative || (dx.abs() <= near_r && dz.abs() <= near_r);
                let mut surf_cy = player_cy;
                if !near {
                    let key = ((c.x + dx) as i64) << 32 | ((c.z + dz) as u32 as i64);
                    if let Some(&v) = self.surf_cy_cache.get(&key) {
                        surf_cy = v;
                    } else {
                        let sy = worldgen::worldgen_surface_height(
                            (c.x + dx) * KCHUNK_DIM + KCHUNK_DIM / 2,
                            (c.z + dz) * KCHUNK_DIM + KCHUNK_DIM / 2,
                            self.seed,
                        );
                        surf_cy = Self::floordiv(sy, KCHUNK_DIM);
                        if self.surf_cy_cache.len() > 200000 {
                            self.surf_cy_cache.clear();
                        }
                        self.surf_cy_cache.insert(key, surf_cy);
                    }
                }
                let lo = player_cy.min(surf_cy) - 1;
                let hi = surf_cy + 1;
                for cy in CY_MIN..=CY_MAX {
                    let want = near || (cy >= lo && cy <= hi);
                    if !want {
                        continue;
                    }
                    let cc = ChunkCoord { x: c.x + dx, y: cy, z: c.z + dz };
                    if !self.store.is_resident(cc) {
                        self.gen_queue.push(cc);
                    }
                }
            }
        }
        self.gen_queue.sort_by(|a, b| Self::dist2(*b, c).cmp(&Self::dist2(*a, c)));
        self.evict_far();
    }

    fn evict_far(&mut self) {
        let mut drop: Vec<ChunkCoord> = Vec::new();
        for (cc, _) in self.meshes.iter() {
            if (cc.x - self.last_center.x).abs() > self.stream_r + 1
                || (cc.z - self.last_center.z).abs() > self.stream_r + 1
            {
                drop.push(*cc);
            }
        }
        for cc in drop {
            if let Some(rec) = self.meshes.get(&cc) {
                if rec.has_buffers && self.has_alloc {
                    self.gpu_free(rec.vbuf.handle);
                    self.gpu_free(rec.ibuf.handle);
                }
            }
            self.meshes.remove(&cc);
            self.unlit_far_meshes.remove(&cc);
            self.mesh_versions.remove(&cc);
            self.mesh_inflight.remove(&cc);
            self.store.evict(cc);
        }
    }

    pub(super) fn stream_backlog(&self) -> usize {
        self.gen_queue.len()
            + self.gen_inflight.len()
            + self.pending_gen_results.len()
            + self.dirty.len()
            + self.mesh_inflight.len()
            + self.pending_mesh_results.len()
    }

    pub(super) fn maybe_expand_stream_radius(&mut self) {
        if self.stream_active_r >= self.stream_r {
            return;
        }
        if self.stream_backlog() > 48 {
            return;
        }
        self.stream_active_r += 1;
        self.recompute_stream_set();
    }

    pub(super) fn mark_dirty(&mut self, cc: ChunkCoord) {
        self.dirty.insert(cc);
        self.mesh_next_version = self.mesh_next_version.wrapping_add(1);
        if self.mesh_next_version == 0 {
            self.mesh_next_version = 1;
        }
        self.mesh_versions.insert(cc, self.mesh_next_version);
    }

    pub(super) fn mesh_version(&self, cc: ChunkCoord) -> u64 {
        self.mesh_versions.get(&cc).copied().unwrap_or(0)
    }

    pub(super) fn dirty_chunk_and_resident_neighbours(&mut self, cc: ChunkCoord) {
        self.mark_dirty(cc);
        let dirs = [
            ChunkCoord { x: cc.x + 1, y: cc.y, z: cc.z },
            ChunkCoord { x: cc.x - 1, y: cc.y, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y + 1, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y - 1, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y, z: cc.z + 1 },
            ChunkCoord { x: cc.x, y: cc.y, z: cc.z - 1 },
        ];
        for nc in dirs {
            if self.store.is_resident(nc) {
                self.mark_dirty(nc);
            }
        }
    }

    pub(super) fn bulk_fill(&self) -> bool {
        !self.moving && self.store.resident_count() < 128 && self.stream_backlog() > 384
    }

    pub(super) fn catchup_fill(&self) -> bool {
        !self.bulk_fill() && self.stream_backlog() > 192
    }

    pub(super) fn ensure_pool(&mut self) {
        if self.pool.is_some() {
            return;
        }
        self.pool = Some(crate::jobs::WorkerPool::new(crate::jobs::recommended_workers()));
        let (gtx, grx) = std::sync::mpsc::channel::<GenResult>();
        let (mtx, mrx) = std::sync::mpsc::channel::<MeshJobResult>();
        self.gen_tx = Some(gtx);
        self.gen_rx = Some(grx);
        self.mesh_tx = Some(mtx);
        self.mesh_rx = Some(mrx);
    }

    pub(super) fn stream_tick(&mut self) {
        if self.gen.is_none() {
            return;
        }
        if self.sync_stream {
            let mut made = 0;
            while !self.gen_queue.is_empty() && made < GEN_BUDGET {
                let cc = self.gen_queue.pop().unwrap();
                if self.store.is_resident(cc) {
                    continue;
                }
                let ch = match self.gen_chunk(cc) {
                    Some(c) => c,
                    None => continue,
                };
                if ch.is_uniform() && ch.get(0, 0, 0) == AIR {
                    made += 1;
                    continue;
                }
                self.store.insert(ch);
                self.dirty_chunk_and_resident_neighbours(cc);
                self.shadow.refill_cols.insert((cc.x, cc.z));
                made += 1;
            }
            return;
        }

        self.ensure_pool();
        let bulk = self.bulk_fill();
        let catchup = self.catchup_fill();

        let gen_collect = if bulk { 24 } else if catchup { 16 } else { 12 };
        let gen_drain = gen_collect * 4;
        if let Some(rx) = self.gen_rx.as_ref() {
            while self.pending_gen_results.len() < gen_drain {
                match rx.try_recv() {
                    Ok(r) => self.pending_gen_results.push(r),
                    Err(_) => break,
                }
            }
        }
        self.pending_gen_results
            .sort_by(|a, b| Self::dist2(b.cc, self.last_center).cmp(&Self::dist2(a.cc, self.last_center)));
        let mut handled = 0;
        while handled < gen_collect {
            let Some(r) = self.pending_gen_results.pop() else { break };
            handled += 1;
            self.gen_inflight.remove(&r.cc);
            if self.store.is_resident(r.cc) {
                continue;
            }
            if r.chunk.is_uniform() && r.chunk.get(0, 0, 0) == AIR {
                continue;
            }
            self.store.insert(r.chunk);
            self.dirty_chunk_and_resident_neighbours(r.cc);
            self.shadow.refill_cols.insert((r.cc.x, r.cc.z));
        }

        let max_inflight = if bulk { 48 } else if catchup { 32 } else { 24 };
        let seed = self.seed;
        while !self.gen_queue.is_empty() && self.gen_inflight.len() < max_inflight {
            let cc = self.gen_queue.pop().unwrap();
            if self.store.is_resident(cc) || self.gen_inflight.contains(&cc) {
                continue;
            }
            let tx = match self.gen_tx.as_ref() {
                Some(t) => t.clone(),
                None => break,
            };
            if self.pool.is_none() {
                break;
            }
            self.gen_inflight.insert(cc);
            let job = move || {
                let mut g = TerrainGen::new();
                g.seed(seed);
                let mut ch = PaletteChunk::new(cc, 0);
                g.generate(cc, &mut ch);
                let _ = tx.send(GenResult { cc, chunk: ch });
            };
            self.pool.as_ref().unwrap().submit(job);
        }
    }
}
