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
            self.detail_pending.remove(&cc);
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
            // Worker generated base terrain only; queue the deferred detail pass
            // (decorations) so this chunk resolves its trees/props a beat later,
            // nearest-first, in detail_tick.
            self.detail_pending.insert(r.cc);
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
                // Base terrain only. The cosmetic decoration pass is deferred to
                // detail_tick on the frame thread so ground shows up sooner; base
                // + detail together reproduce generate() exactly (same final world).
                g.generate_base(cc, &mut ch);
                let _ = tx.send(GenResult { cc, chunk: ch });
            };
            self.pool.as_ref().unwrap().submit(job);
        }
    }

    // Deferred decoration pass (#159). Base terrain streams in first; this runs
    // afterward, resolving the cosmetic detail (trees, plants, props, structures)
    // for a bounded number of chunks per tick, nearest to the player first. Each
    // chunk gets exactly one detail pass: it is removed from detail_pending the
    // instant it is processed and only base generation ever re-adds it, so there
    // is no re-mesh thrash. Applying generate_detail to the stored base chunk
    // reproduces the exact voxels of the non-deferred generate() path.
    pub(super) fn detail_tick(&mut self) {
        if self.detail_pending.is_empty() || self.gen.is_none() {
            return;
        }
        // Do not compete with the base-terrain fill: while there is a large base
        // backlog, spend the frame budget getting ground on screen. Detail catches
        // up once the near bubble is mostly resident. This preserves drop-in-sooner.
        let budget = if self.bulk_fill() || self.catchup_fill() { 2 } else { 6 };

        // Drop any pending entries that are no longer resident (evicted before we
        // got to them) so the set does not leak. Only consider chunks whose base
        // terrain has already meshed at least once: that is what guarantees the
        // ground shows FIRST and the decorations arrive as a visible second step
        // (not squeezed into the same frame the base was generated).
        let center = self.last_center;
        let mut cand: Vec<ChunkCoord> = Vec::with_capacity(self.detail_pending.len());
        let mut stale: Vec<ChunkCoord> = Vec::new();
        for &cc in self.detail_pending.iter() {
            if !self.store.is_resident(cc) {
                stale.push(cc);
            } else if self.meshes.contains_key(&cc) {
                cand.push(cc);
            }
        }
        for cc in stale {
            self.detail_pending.remove(&cc);
        }
        // Nearest-first: smallest squared chunk distance to the player center.
        cand.sort_by(|a, b| Self::dist2(*a, center).cmp(&Self::dist2(*b, center)));
        cand.truncate(budget);

        // A local generator keyed on the world seed reproduces the same decoration
        // pass the worker's generate() would have run (worldgen is a pure function
        // of seed + coord), without borrowing self.gen across the store mutation.
        let mut g = TerrainGen::new();
        g.seed(self.seed);
        for cc in cand {
            // One-time: remove from pending up front so this chunk is never
            // re-detailed unless it is evicted and base-regenerated.
            self.detail_pending.remove(&cc);
            let mut ch = match self.store.get(cc) {
                Some(c) => c.clone(),
                None => continue,
            };
            g.generate_detail(cc, &mut ch);
            self.store.insert(ch);
            // Re-mesh this chunk and its resident neighbours: decorations can add
            // blocks at the chunk boundary, so neighbour boundary faces may change.
            // This mirrors what base insertion already does and is bounded by the
            // per-tick detail budget, so no re-mesh storm.
            self.dirty_chunk_and_resident_neighbours(cc);
            self.shadow.refill_cols.insert((cc.x, cc.z));
        }
    }
}
