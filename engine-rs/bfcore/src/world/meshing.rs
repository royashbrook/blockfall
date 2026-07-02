use super::*;

impl<'c> World<'c> {
    pub(super) fn gpu_alloc(&self, bytes: u32) -> bf_gpu_buffer {
        match self.alloc.alloc {
            Some(f) => f(self.alloc.user, bytes),
            None => bf_gpu_buffer { handle: 0, contents: std::ptr::null_mut(), bytes: 0 },
        }
    }

    pub(super) fn gpu_free(&self, handle: bf_handle) {
        if let Some(f) = self.alloc.free_ {
            f(self.alloc.user, handle);
        }
    }

    fn scan_chunk_props(&self, cc: ChunkCoord) -> Vec<bf_prop_instance> {
        let mut props: Vec<bf_prop_instance> = Vec::new();
        let ch = match self.store.get(cc) {
            Some(c) => c,
            None => return props,
        };
        let sat = self.region_sat(cc);
        let bx = cc.x * KCHUNK_DIM;
        let by = cc.y * KCHUNK_DIM;
        let bz = cc.z * KCHUNK_DIM;
        for lz in 0..KCHUNK_DIM {
            for ly in 0..KCHUNK_DIM {
                for lx in 0..KCHUNK_DIM {
                    let id = ch.get(lx as usize, ly as usize, lz as usize);
                    let prop = Self::is_prop_block(id);
                    let tree = Self::is_tree_block(id);
                    if !prop && !tree {
                        continue;
                    }
                    if tree && (id == 5 || id == 27 || id == 48) {
                        let see_through = |ax: i32, ay: i32, az: i32| -> bool {
                            if ax < 0 || ay < 0 || az < 0 || ax >= KCHUNK_DIM || ay >= KCHUNK_DIM || az >= KCHUNK_DIM {
                                return true;
                            }
                            let n = ch.get(ax as usize, ay as usize, az as usize);
                            n == 0 || n == 9
                        };
                        let exposed = see_through(lx + 1, ly, lz)
                            || see_through(lx - 1, ly, lz)
                            || see_through(lx, ly + 1, lz)
                            || see_through(lx, ly - 1, lz)
                            || see_through(lx, ly, lz + 1)
                            || see_through(lx, ly, lz - 1);
                        if !exposed {
                            continue;
                        }
                    }
                    let mut h = ((bx + lx).wrapping_mul(73856093)
                        ^ (by + ly).wrapping_mul(19349663)
                        ^ (bz + lz).wrapping_mul(83492791)) as u32;
                    if id == 21 || id == 22 || id == 49 {
                        let is_logf = |dx: i32, dy: i32, dz: i32| -> bool {
                            let b = self.block_at(IVec3 { x: bx + lx + dx, y: by + ly + dy, z: bz + lz + dz });
                            b == 21 || b == 22 || b == 49
                        };
                        let above = is_logf(0, 1, 0);
                        let below = is_logf(0, -1, 0);
                        let xax = is_logf(1, 1, 0) || is_logf(-1, 1, 0) || is_logf(1, -1, 0)
                            || is_logf(-1, -1, 0) || is_logf(1, 0, 0) || is_logf(-1, 0, 0);
                        let zax = is_logf(0, 1, 1) || is_logf(0, 1, -1) || is_logf(0, -1, 1)
                            || is_logf(0, -1, -1) || is_logf(0, 0, 1) || is_logf(0, 0, -1);
                        if !above && !below && !xax && !zax {
                            h &= 0x001FFFFF;
                        } else if !above && !below {
                            let axis: u32 = if zax && !xax { 1 } else { 0 };
                            h = 0x80000000 | (axis << 30) | (h & 0x3FFFFFFF);
                        } else {
                            let mut level = 0;
                            for k in 1..=24 {
                                if !is_logf(0, -k, 0) {
                                    break;
                                }
                                level += 1;
                            }
                            if level > 127 {
                                level = 127;
                            }
                            let mut slant: u32 = 0;
                            let mut sdir: u32 = 0;
                            if !below {
                                if is_logf(1, -1, 0) {
                                    slant = 1;
                                    sdir = 0;
                                } else if is_logf(-1, -1, 0) {
                                    slant = 1;
                                    sdir = 1;
                                } else if is_logf(0, -1, 1) {
                                    slant = 1;
                                    sdir = 2;
                                } else if is_logf(0, -1, -1) {
                                    slant = 1;
                                    sdir = 3;
                                }
                            }
                            h = ((level as u32) << 24) | (slant << 23) | (sdir << 21) | (h & 0x001FFFFF);
                        }
                    } else if id == 38 || id == 42 {
                        let same = |dx: i32, dz: i32| -> bool {
                            self.block_at(IVec3 { x: bx + lx + dx, y: by + ly, z: bz + lz + dz }) == id
                        };
                        let mut dens: u32 = 0;
                        for dz2 in -1..=1 {
                            for dx2 in -1..=1 {
                                if (dx2 != 0 || dz2 != 0) && same(dx2, dz2) {
                                    dens += 1;
                                }
                            }
                        }
                        h = (h & 0x0FFFFFFF) | (dens << 28);
                    }
                    props.push(bf_prop_instance {
                        position: bf_vec3 { x: (bx + lx) as f32, y: (by + ly) as f32, z: (bz + lz) as f32 },
                        type_: id as u32,
                        seed: h,
                        sat,
                    });
                }
            }
        }
        props
    }

    fn chunk_has_water(&self, cc: ChunkCoord) -> bool {
        let ch = match self.store.get(cc) {
            Some(c) => c,
            None => return false,
        };
        for lz in 0..KCHUNK_DIM {
            for ly in 0..KCHUNK_DIM {
                for lx in 0..KCHUNK_DIM {
                    if ch.get(lx as usize, ly as usize, lz as usize) == WATER {
                        return true;
                    }
                }
            }
        }
        false
    }

    pub(super) fn remesh_dirty(&mut self) {
        if !self.has_alloc {
            return;
        }
        let async_mode = !self.sync_stream;
        if async_mode {
            self.ensure_pool();
        }
        let bulk = self.bulk_fill();
        let catchup = self.catchup_fill();

        if async_mode {
            let upload_budget = if bulk { 8 } else if catchup { 6 } else { 4 };
            let upload_drain = upload_budget * 4;
            if let Some(rx) = self.mesh_rx.as_ref() {
                while self.pending_mesh_results.len() < upload_drain {
                    match rx.try_recv() {
                        Ok(r) => self.pending_mesh_results.push(r),
                        Err(_) => break,
                    }
                }
            }
            self.pending_mesh_results
                .sort_by(|a, b| Self::dist2(b.cc, self.last_center).cmp(&Self::dist2(a.cc, self.last_center)));
            let mut uploaded = 0;
            while uploaded < upload_budget {
                let Some(r) = self.pending_mesh_results.pop() else { break };
                self.mesh_inflight.remove(&r.cc);
                self.upload_mesh_result(r);
                uploaded += 1;
            }
        }

        // Player-edit remeshes first, outside the fresh-first scoring and the remesh
        // cap below. The main queue deliberately favors fresh meshes so streaming fill
        // wins, but with continuous streaming that starved edit remeshes: a broken
        // block stayed visible long after its voxel was air. Edits are sparse, so a
        // small dedicated budget keeps them instant without hurting fill.
        if !self.urgent_dirty.is_empty() {
            let urgent: Vec<ChunkCoord> = self.urgent_dirty.drain().collect();
            let mut done_urgent = 0;
            for cc in urgent {
                if done_urgent >= 6 {
                    self.urgent_dirty.insert(cc); // remainder next tick
                    continue;
                }
                if !self.store.is_resident(cc) {
                    self.dirty.remove(&cc);
                    continue;
                }
                if async_mode && self.mesh_inflight.contains(&cc) {
                    // An older-version job is in flight; keep this urgent so the
                    // fresh remesh runs next tick instead of rejoining the slow queue.
                    self.urgent_dirty.insert(cc);
                    continue;
                }
                self.dirty.remove(&cc);
                done_urgent += 1;
                let faces = lighting::light_chunk(&mut self.store, cc);
                self.unlit_far_meshes.remove(&cc);
                if faces != 0 {
                    let dirs = [
                        IVec3 { x: 1, y: 0, z: 0 },
                        IVec3 { x: -1, y: 0, z: 0 },
                        IVec3 { x: 0, y: 1, z: 0 },
                        IVec3 { x: 0, y: -1, z: 0 },
                        IVec3 { x: 0, y: 0, z: 1 },
                        IVec3 { x: 0, y: 0, z: -1 },
                    ];
                    for f in 0..6 {
                        if faces & (1 << f) != 0 {
                            let nc = ChunkCoord { x: cc.x + dirs[f].x, y: cc.y + dirs[f].y, z: cc.z + dirs[f].z };
                            if self.store.is_resident(nc) {
                                self.mark_dirty(nc);
                            }
                        }
                    }
                }
                if async_mode {
                    self.submit_mesh_job(cc);
                } else {
                    self.remesh_one(cc);
                }
            }
        }

        if self.dirty.is_empty() {
            return;
        }

        let mut todo: Vec<ChunkCoord> = self.dirty.iter().copied().collect();
        let cam_fwd = self.forward_dir();
        let pos = self.pos;
        let meshes = &self.meshes;
        let score = |a: ChunkCoord| -> f64 {
            let ctr = V3::new(
                (a.x as f32 + 0.5) * KCHUNK_DIM as f32,
                (a.y as f32 + 0.5) * KCHUNK_DIM as f32,
                (a.z as f32 + 0.5) * KCHUNK_DIM as f32,
            );
            let to = V3::new(ctr.x - pos.x, ctr.y - pos.y, ctr.z - pos.z);
            let d2 = dot(to, to);
            let facing = dot(to, cam_fwd) / (d2.sqrt() + 0.001);
            let mut s = d2 as f64 * (if facing > 0.2 { 1.0 } else { 4.0 });
            if meshes.contains_key(&a) {
                s += 1e15;
            }
            s
        };
        let mesh_budget = if !async_mode {
            MESH_BUDGET
        } else if bulk {
            12
        } else if catchup {
            10
        } else {
            8
        };
        let kremesh_cap = if bulk { 6 } else { 3 };
        let mesh_inflight_cap = if bulk { 48 } else if catchup { 40 } else { 32 };
        // Top-k selection instead of a full sort: the dirty set can hold thousands of
        // chunks during fill and only ~mesh_budget of them are dispatched per tick, so
        // sorting all of them every frame was measurable main-thread time (profiled).
        // Keep 4x budget so the skip conditions below (inflight, remesh cap) still find
        // enough candidates, then order just that head.
        let keep = (mesh_budget * 4).min(todo.len());
        if todo.len() > keep {
            todo.select_nth_unstable_by(keep - 1, |a, b| {
                score(*a).partial_cmp(&score(*b)).unwrap_or(std::cmp::Ordering::Equal)
            });
            todo.truncate(keep);
        }
        todo.sort_by(|a, b| score(*a).partial_cmp(&score(*b)).unwrap_or(std::cmp::Ordering::Equal));
        let mut done = 0;
        let mut remeshes = 0;
        let order: Vec<ChunkCoord> = todo;
        for cc in order {
            if done >= mesh_budget {
                break;
            }
            if async_mode && (self.mesh_inflight.contains(&cc) || self.mesh_inflight.len() >= mesh_inflight_cap) {
                continue;
            }
            let fresh = !self.meshes.contains_key(&cc);
            if !fresh && remeshes >= kremesh_cap {
                continue;
            }
            if !self.store.is_resident(cc) {
                self.dirty.remove(&cc);
                continue;
            }
            self.dirty.remove(&cc);
            if !fresh {
                remeshes += 1;
            }
            done += 1;
            let far_lod = self.chunk_center_distance_from(cc, self.pos) > 192.0;
            if async_mode && far_lod && (fresh || self.unlit_far_meshes.contains(&cc)) {
                self.unlit_far_meshes.insert(cc);
                self.submit_mesh_job(cc);
                continue;
            }
            let faces = lighting::light_chunk(&mut self.store, cc);
            self.unlit_far_meshes.remove(&cc);
            if faces != 0 {
                let dirs = [
                    IVec3 { x: 1, y: 0, z: 0 },
                    IVec3 { x: -1, y: 0, z: 0 },
                    IVec3 { x: 0, y: 1, z: 0 },
                    IVec3 { x: 0, y: -1, z: 0 },
                    IVec3 { x: 0, y: 0, z: 1 },
                    IVec3 { x: 0, y: 0, z: -1 },
                ];
                for f in 0..6 {
                    if faces & (1 << f) != 0 {
                        let nc = ChunkCoord { x: cc.x + dirs[f].x, y: cc.y + dirs[f].y, z: cc.z + dirs[f].z };
                        if self.store.is_resident(nc) {
                            self.mark_dirty(nc);
                        }
                    }
                }
            }
            if async_mode {
                self.submit_mesh_job(cc);
            } else {
                self.remesh_one(cc);
            }
        }
    }

    fn submit_mesh_job(&mut self, cc: ChunkCoord) {
        let mut chunks: HashMap<ChunkCoord, PaletteChunk> = HashMap::new();
        let add = |w: &mut HashMap<ChunkCoord, PaletteChunk>, c: ChunkCoord| {
            if let Some(ch) = self.store.get(c) {
                w.insert(c, ch.clone());
            }
        };
        add(&mut chunks, cc);
        let dirs = [
            ChunkCoord { x: cc.x + 1, y: cc.y, z: cc.z },
            ChunkCoord { x: cc.x - 1, y: cc.y, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y + 1, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y - 1, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y, z: cc.z + 1 },
            ChunkCoord { x: cc.x, y: cc.y, z: cc.z - 1 },
        ];
        for d in dirs {
            add(&mut chunks, d);
        }
        let tx = match self.mesh_tx.as_ref() {
            Some(t) => t.clone(),
            None => return,
        };
        if self.pool.is_none() {
            return;
        }
        let version = self.mesh_version(cc);
        self.mesh_inflight.insert(cc);
        let mesher = GreedyMesher::new();
        let job = move || {
            let snap = SnapStore { chunks };
            let (mr, vbytes, ibytes) = mesher.mesh(cc, &snap, false);
            let empty = mr.empty || mr.index_count == 0;
            let _ = tx.send(MeshJobResult {
                cc,
                version,
                vbytes: if empty { Vec::new() } else { vbytes },
                ibytes: if empty { Vec::new() } else { ibytes },
                index_count: mr.index_count,
                empty,
            });
        };
        self.pool.as_ref().unwrap().submit(job);
    }

    fn upload_mesh_result(&mut self, r: MeshJobResult) {
        if !self.store.is_resident(r.cc) {
            return;
        }
        if r.version != self.mesh_version(r.cc) {
            self.dirty.insert(r.cc);
            return;
        }
        let props = self.scan_chunk_props(r.cc);
        let has_water = self.chunk_has_water(r.cc);
        if let Some(rec) = self.meshes.get(&r.cc) {
            if rec.has_buffers {
                self.gpu_free(rec.vbuf.handle);
                self.gpu_free(rec.ibuf.handle);
            }
        }
        let rec = self.meshes.entry(r.cc).or_default();
        rec.props = props;
        rec.has_water = has_water;
        rec.has_buffers = false;
        if r.empty {
            rec.index_count = 0;
            return;
        }
        let vbytes_len = r.vbytes.len() as u32;
        let ibytes_len = r.ibytes.len() as u32;
        let vb = self.gpu_alloc(vbytes_len);
        let ib = self.gpu_alloc(ibytes_len);
        if vb.contents.is_null() || ib.contents.is_null() {
            let rec = self.meshes.get_mut(&r.cc).unwrap();
            rec.index_count = 0;
            return;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(r.vbytes.as_ptr(), vb.contents as *mut u8, vbytes_len as usize);
            std::ptr::copy_nonoverlapping(r.ibytes.as_ptr(), ib.contents as *mut u8, ibytes_len as usize);
        }
        let rec = self.meshes.get_mut(&r.cc).unwrap();
        rec.vbuf = vb;
        rec.ibuf = ib;
        rec.index_count = r.index_count;
        rec.has_buffers = true;
    }

    fn remesh_one(&mut self, cc: ChunkCoord) {
        let props = self.scan_chunk_props(cc);
        let has_water = self.chunk_has_water(cc);
        let (mr, vbytes, ibytes) = self.mesher.mesh(cc, &self.store, false);
        if let Some(rec) = self.meshes.get(&cc) {
            if rec.has_buffers {
                self.gpu_free(rec.vbuf.handle);
                self.gpu_free(rec.ibuf.handle);
            }
        }
        let rec = self.meshes.entry(cc).or_default();
        rec.props = props;
        rec.has_water = has_water;
        rec.has_buffers = false;
        if mr.empty || mr.index_count == 0 {
            rec.index_count = 0;
            return;
        }
        let vb = self.gpu_alloc(mr.vertex_bytes);
        let ib = self.gpu_alloc(mr.index_bytes);
        if vb.contents.is_null() || ib.contents.is_null() {
            let rec = self.meshes.get_mut(&cc).unwrap();
            rec.index_count = 0;
            return;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(vbytes.as_ptr(), vb.contents as *mut u8, mr.vertex_bytes as usize);
            std::ptr::copy_nonoverlapping(ibytes.as_ptr(), ib.contents as *mut u8, mr.index_bytes as usize);
        }
        let rec = self.meshes.get_mut(&cc).unwrap();
        rec.vbuf = vb;
        rec.ibuf = ib;
        rec.index_count = mr.index_count;
        rec.has_buffers = true;
    }
}
