use super::*;

impl<'c> World<'c> {
    pub(super) fn recompute_stream_set(&mut self) {
        self.gen_queue.clear();
        let c = self.last_center;
        let target_r = self.stream_active_r.clamp(2, self.stream_r);
        let near_r = 5.min(target_r);
        let player_cy = Self::floordiv(Self::ifloor(self.pos.y), KCHUNK_DIM);
        for dx in -target_r..=target_r {
            for dz in -target_r..=target_r {
                // Surface-first everywhere: far columns stream only the band around the
                // surface (and down to the player when submerged); the near bubble keeps
                // the full stack so digging and caves always work. Creative used to force
                // FULL Y stacks for every column in radius, which burned most of the gen
                // budget on invisible underground and left visible holes while flying.
                let near = dx.abs() <= near_r && dz.abs() <= near_r;
                // #191: a SQUARE load box, filled radiating outward (the gen_queue
                // sorts nearest-first below). An earlier round cull was reverted:
                // culling the corners de-rendered already-loaded chunks as the
                // player moved, so the round boundary thrashed in/out and left an
                // empty ring when moving fast. Keeping everything already loaded
                // (and accepting the square) is what the player actually wants.
                // #179: canonical column so the cache key (and the queued chunk
                // below) is unique on the torus even when the window straddles
                // the seam.
                let col_cx = (c.x + dx).rem_euclid(WRAP_CHUNKS);
                let col_cz = (c.z + dz).rem_euclid(WRAP_CHUNKS);
                let mut surf_cy = player_cy;
                if !near {
                    let key = (col_cx as i64) << 32 | (col_cz as u32 as i64);
                    if let Some(&v) = self.surf_cy_cache.get(&key) {
                        surf_cy = v;
                    } else {
                        let sy = worldgen::worldgen_surface_height(
                            col_cx * KCHUNK_DIM + KCHUNK_DIM / 2,
                            col_cz * KCHUNK_DIM + KCHUNK_DIM / 2,
                            self.seed,
                        );
                        surf_cy = Self::floordiv(sy, KCHUNK_DIM);
                        if self.surf_cy_cache.len() > 200000 {
                            self.surf_cy_cache.clear();
                        }
                        self.surf_cy_cache.insert(key, surf_cy);
                    }
                }
                // Flyover: a player strictly above the surface only needs the surface
                // chunk and the one above it; the below-surface layer (dig adjacency,
                // caves) queues once they are at or below surface level, and the near
                // bubble always carries the full stack for mining. This is what keeps
                // fly-around from generating visible underground at all.
                let lo = if player_cy > surf_cy {
                    surf_cy
                } else {
                    player_cy.min(surf_cy) - 1
                };
                let hi = surf_cy + 1;
                for cy in CY_MIN..=CY_MAX {
                    let want = near || (cy >= lo && cy <= hi);
                    if !want {
                        continue;
                    }
                    let cc = ChunkCoord { x: col_cx, y: cy, z: col_cz };
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
            // #179: nearest-image distance so meshes just across the seam are
            // "near", not 32K blocks away. #191: SQUARE eviction (reverted the
            // round radius) so a chunk already loaded is never dropped until it is
            // truly outside the render box; the round version thrashed boundary
            // chunks and left an empty ring when moving fast.
            if Self::wrap_signed_chunk(cc.x - self.last_center.x).abs() > self.stream_r + 1
                || Self::wrap_signed_chunk(cc.z - self.last_center.z).abs() > self.stream_r + 1
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
        // Gate on the GENERATION backlog only. The full stream_backlog() includes the
        // dirty set and mesh queues, which never drain in live play (shadow refills,
        // footprints, block edits keep them busy), so gating on it stalled the radius
        // at the starting bubble forever: the player saw a tiny loaded disc ahead and
        // a long trail of old chunks behind. Meshing continues in parallel; the radius
        // only needs the near terrain to be GENERATED before it widens.
        let gen_backlog =
            self.gen_queue.len() + self.gen_inflight.len() + self.pending_gen_results.len();
        if gen_backlog > 24 {
            return;
        }
        self.stream_active_r += 1;
        self.recompute_stream_set();
    }

    pub(super) fn mark_dirty(&mut self, cc: ChunkCoord) {
        // #179: dirty / mesh-version keys are canonical, matching store keys.
        let cc = Self::canon_chunk(cc);
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
            // mark_dirty canonicalizes; is_resident wraps in the store.
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
