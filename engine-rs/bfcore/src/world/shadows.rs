use super::*;

/// Persistent TOROIDAL occupancy grid for the world-space sun-shadow march (ABI v19).
///
/// The buffer is wrap-addressed: the cell for a world voxel w is at (w mod dim) on
/// each axis, a mapping that is independent of the origin. When the player walks
/// and the window scrolls, only the newly-exposed edge slabs are rewritten.
pub(super) struct ShadowVol {
    pub(super) voxels: Vec<u8>,
    /// Coarse mip: 1 byte per 4x4x4 fine cell, same toroidal wrap. Maintained
    /// incrementally per stamped column (#163) so the renderer never rescans
    /// the fine grid to rebuild it.
    pub(super) coarse: Vec<u8>,
    pub(super) origin: IVec3,
    pub(super) dim_x: i32,
    pub(super) dim_y: i32,
    pub(super) dim_z: i32,
    pub(super) revision: u32,
    pub(super) needs_full: bool,
    pub(super) dirty: Vec<(IVec3, IVec3)>,
    pub(super) have_cx0: i32,
    pub(super) have_cz0: i32,
    pub(super) refill_cols: std::collections::HashSet<(i32, i32)>,
}

const SHADOW_MAX_DIRTY: usize = 4;

impl ShadowVol {
    pub(super) fn new() -> ShadowVol {
        ShadowVol {
            voxels: Vec::new(),
            coarse: Vec::new(),
            origin: IVec3::default(),
            dim_x: 0,
            dim_y: 0,
            dim_z: 0,
            revision: 0,
            needs_full: true,
            dirty: Vec::new(),
            have_cx0: i32::MIN,
            have_cz0: i32::MIN,
            refill_cols: std::collections::HashSet::new(),
        }
    }

    fn empty_dirty(&mut self) {
        self.dirty.clear();
    }

    fn mark_full(&mut self) {
        self.dirty.clear();
        self.dirty.push((
            self.origin,
            IVec3 {
                x: self.origin.x + self.dim_x - 1,
                y: self.origin.y + self.dim_y - 1,
                z: self.origin.z + self.dim_z - 1,
            },
        ));
    }

    fn mark_dirty(&mut self, lo: IVec3, hi: IVec3) {
        if self.dirty.len() == 1
            && self.dirty[0].0 == self.origin
            && self.dirty[0].1.x == self.origin.x + self.dim_x - 1
        {
            return;
        }
        if self.dirty.len() >= SHADOW_MAX_DIRTY {
            self.mark_full();
            return;
        }
        self.dirty.push((lo, hi));
    }
}

/// Fine voxels per coarse cell edge. Must match the renderer's march (CO).
pub(super) const SHADOW_COARSE: i32 = 4;

impl<'c> World<'c> {
    pub(super) fn casts_shadow(b: BlockId) -> bool {
        Self::solid_block(b) || Self::is_leaf(b) || Self::is_snow_overlay(b)
    }

    pub(super) fn shadow_radius_chunks(&self) -> i32 {
        if self.stream_r >= 16 { 16 } else { 8 }
    }

    #[inline]
    fn wrap(v: i32, dim: i32) -> i32 {
        let m = v % dim;
        if m < 0 { m + dim } else { m }
    }

    fn shadow_fill_column(&mut self, cx: i32, cz: i32) {
        let dim_x = self.shadow.dim_x;
        let dim_y = self.shadow.dim_y;
        let dim_z = self.shadow.dim_z;
        let y_lo = self.shadow.origin.y;
        let base_wx = cx * KCHUNK_DIM;
        let base_wz = cz * KCHUNK_DIM;
        let gx0 = Self::wrap(base_wx, dim_x);
        let gz0 = Self::wrap(base_wz, dim_z);
        for lz in 0..KCHUNK_DIM {
            let gz = gz0 + lz;
            for gy in 0..dim_y {
                let row = (gz as usize) * (dim_y as usize) * (dim_x as usize)
                    + (gy as usize) * (dim_x as usize)
                    + gx0 as usize;
                for lx in 0..KCHUNK_DIM {
                    self.shadow.voxels[row + lx as usize] = 0;
                }
            }
        }
        for cy in CY_MIN..=CY_MAX {
            let cc = ChunkCoord { x: cx, y: cy, z: cz };
            let ch = match self.store.get(cc) {
                Some(c) => c,
                None => continue,
            };
            if ch.is_uniform() && !Self::casts_shadow(ch.get(0, 0, 0)) {
                continue;
            }
            let base_wy = cy * KCHUNK_DIM;
            for lz in 0..KCHUNK_DIM {
                let gz = gz0 + lz;
                for ly in 0..KCHUNK_DIM {
                    let gy = base_wy + ly - y_lo;
                    if gy < 0 || gy >= dim_y {
                        continue;
                    }
                    let row = (gz as usize) * (dim_y as usize) * (dim_x as usize)
                        + (gy as usize) * (dim_x as usize)
                        + gx0 as usize;
                    for lx in 0..KCHUNK_DIM {
                        let b = ch.get(lx as usize, ly as usize, lz as usize);
                        if Self::casts_shadow(b) {
                            self.shadow.voxels[row + lx as usize] = 1;
                        }
                    }
                }
            }
        }
        self.shadow_coarse_update_column(gx0, gz0);
    }

    /// Recompute the coarse mip cells covering one stamped chunk column. The
    /// column is chunk-aligned and SHADOW_COARSE divides KCHUNK_DIM, so its
    /// coarse footprint is a clean (KCHUNK_DIM/CO)^2 tile across every mip row;
    /// cost is exactly the fine voxels of that column, in Rust, once, instead of
    /// the renderer rescanning box unions of millions of voxels every frame.
    fn shadow_coarse_update_column(&mut self, gx0: i32, gz0: i32) {
        let co = SHADOW_COARSE;
        let dim_x = self.shadow.dim_x;
        let dim_y = self.shadow.dim_y;
        let cdx = dim_x / co;
        let cdy = dim_y / co;
        let cdz = self.shadow.dim_z / co;
        if self.shadow.coarse.len() != (cdx * cdy * cdz) as usize {
            self.shadow.coarse.resize((cdx * cdy * cdz) as usize, 0);
        }
        let cgx0 = gx0 / co;
        let cgz0 = gz0 / co;
        let fine = &self.shadow.voxels;
        let coarse = &mut self.shadow.coarse;
        for cgz in cgz0..cgz0 + KCHUNK_DIM / co {
            for cgy in 0..cdy {
                for cgx in cgx0..cgx0 + KCHUNK_DIM / co {
                    let mut any = 0u8;
                    'scan: for fz in cgz * co..(cgz + 1) * co {
                        for fy in cgy * co..(cgy + 1) * co {
                            let row = (fz as usize) * (dim_y as usize) * (dim_x as usize)
                                + (fy as usize) * (dim_x as usize)
                                + (cgx * co) as usize;
                            for i in 0..co as usize {
                                if fine[row + i] != 0 {
                                    any = 1;
                                    break 'scan;
                                }
                            }
                        }
                    }
                    coarse[(cgz * cdy + cgy) as usize * cdx as usize + cgx as usize] = any;
                }
            }
        }
    }

    fn ensure_shadow_volume(&mut self) {
        let pv = self.player_voxel();
        let pc = Self::to_chunk(pv);
        let rc = self.shadow_radius_chunks();
        let dim_x = rc * 2 * KCHUNK_DIM;
        let dim_z = rc * 2 * KCHUNK_DIM;
        let dim_y = (CY_MAX - CY_MIN + 1) * KCHUNK_DIM;
        let y_lo = CY_MIN * KCHUNK_DIM;
        let cx0 = pc.x - rc;
        let cz0 = pc.z - rc;
        let origin = IVec3 { x: cx0 * KCHUNK_DIM, y: y_lo, z: cz0 * KCHUNK_DIM };

        let dims_changed = self.shadow.dim_x != dim_x
            || self.shadow.dim_y != dim_y
            || self.shadow.dim_z != dim_z;

        if self.shadow.needs_full || dims_changed {
            let total = (dim_x as usize) * (dim_y as usize) * (dim_z as usize);
            self.shadow.voxels.clear();
            self.shadow.voxels.resize(total, 0u8);
            let ctotal = total / (SHADOW_COARSE as usize).pow(3);
            self.shadow.coarse.clear();
            self.shadow.coarse.resize(ctotal, 0u8);
            self.shadow.dim_x = dim_x;
            self.shadow.dim_y = dim_y;
            self.shadow.dim_z = dim_z;
            self.shadow.origin = origin;
            self.shadow.have_cx0 = cx0;
            self.shadow.have_cz0 = cz0;
            for cz in cz0..cz0 + 2 * rc {
                for cx in cx0..cx0 + 2 * rc {
                    self.shadow_fill_column(cx, cz);
                }
            }
            self.shadow.refill_cols.clear();
            self.shadow.mark_full();
            self.shadow.revision = self.shadow.revision.wrapping_add(1);
            self.shadow.needs_full = false;
            return;
        }

        let old_cx0 = self.shadow.have_cx0;
        let old_cz0 = self.shadow.have_cz0;
        let moved = old_cx0 != cx0 || old_cz0 != cz0;

        if !moved && self.shadow.refill_cols.is_empty() {
            return;
        }

        let mut changed = false;
        if moved {
            self.shadow.origin = origin;
            self.shadow.have_cx0 = cx0;
            self.shadow.have_cz0 = cz0;
            let cx1 = cx0 + 2 * rc;
            let cz1 = cz0 + 2 * rc;
            let oxx0 = old_cx0;
            let oxx1 = old_cx0 + 2 * rc;
            let ozz0 = old_cz0;
            let ozz1 = old_cz0 + 2 * rc;
            let mut x_lo = i32::MAX;
            let mut x_hi = i32::MIN;
            for cx in cx0..cx1 {
                if cx >= oxx0 && cx < oxx1 {
                    continue;
                }
                x_lo = x_lo.min(cx);
                x_hi = x_hi.max(cx);
                for cz in cz0..cz1 {
                    self.shadow_fill_column(cx, cz);
                    self.shadow.refill_cols.remove(&(cx, cz));
                }
            }
            let mut z_lo = i32::MAX;
            let mut z_hi = i32::MIN;
            for cz in cz0..cz1 {
                if cz >= ozz0 && cz < ozz1 {
                    continue;
                }
                z_lo = z_lo.min(cz);
                z_hi = z_hi.max(cz);
                for cx in cx0..cx1 {
                    if cx < oxx0 || cx >= oxx1 {
                        continue;
                    }
                    self.shadow_fill_column(cx, cz);
                    self.shadow.refill_cols.remove(&(cx, cz));
                }
            }
            if x_hi >= x_lo {
                self.shadow.mark_dirty(
                    IVec3 { x: x_lo * KCHUNK_DIM, y: y_lo, z: cz0 * KCHUNK_DIM },
                    IVec3 { x: (x_hi + 1) * KCHUNK_DIM - 1, y: y_lo + dim_y - 1, z: cz1 * KCHUNK_DIM - 1 },
                );
                changed = true;
            }
            if z_hi >= z_lo {
                let zx0 = oxx0.max(cx0);
                let zx1 = oxx1.min(cx1);
                if zx1 > zx0 {
                    self.shadow.mark_dirty(
                        IVec3 { x: zx0 * KCHUNK_DIM, y: y_lo, z: z_lo * KCHUNK_DIM },
                        IVec3 { x: zx1 * KCHUNK_DIM - 1, y: y_lo + dim_y - 1, z: (z_hi + 1) * KCHUNK_DIM - 1 },
                    );
                }
                changed = true;
            }
        }

        if !self.shadow.refill_cols.is_empty() {
            let cols: Vec<(i32, i32)> = self.shadow.refill_cols.drain().collect();
            for (cx, cz) in cols {
                if cx < cx0 || cx >= cx0 + 2 * rc || cz < cz0 || cz >= cz0 + 2 * rc {
                    continue;
                }
                self.shadow_fill_column(cx, cz);
                let wx = cx * KCHUNK_DIM;
                let wz = cz * KCHUNK_DIM;
                self.shadow.mark_dirty(
                    IVec3 { x: wx, y: y_lo, z: wz },
                    IVec3 { x: wx + KCHUNK_DIM - 1, y: y_lo + dim_y - 1, z: wz + KCHUNK_DIM - 1 },
                );
                changed = true;
            }
        }

        if changed {
            self.shadow.revision = self.shadow.revision.wrapping_add(1);
        }
    }

    pub fn fill_shadow_volume(&mut self, vol: &mut bf_shadow_volume) -> bf_result {
        self.ensure_shadow_volume();
        let need = self.shadow.voxels.len();
        vol.origin = bf_ivec3 {
            x: self.shadow.origin.x,
            y: self.shadow.origin.y,
            z: self.shadow.origin.z,
        };
        vol.dim_x = self.shadow.dim_x as u32;
        vol.dim_y = self.shadow.dim_y as u32;
        vol.dim_z = self.shadow.dim_z as u32;
        vol.revision = self.shadow.revision;
        let write_boxes = |vol: &mut bf_shadow_volume, boxes: &[(IVec3, IVec3)]| {
            let n = boxes.len().min(SHADOW_MAX_DIRTY);
            vol.dirty_count = n as u32;
            for i in 0..n {
                vol.dirty_lo[i] = bf_ivec3 { x: boxes[i].0.x, y: boxes[i].0.y, z: boxes[i].0.z };
                vol.dirty_hi[i] = bf_ivec3 { x: boxes[i].1.x, y: boxes[i].1.y, z: boxes[i].1.z };
            }
        };
        write_boxes(vol, &self.shadow.dirty);

        if vol.voxels.is_null() {
            return bf_result::BF_OK;
        }
        if (vol.voxel_cap as usize) < need {
            let full = (
                self.shadow.origin,
                IVec3 {
                    x: self.shadow.origin.x + self.shadow.dim_x - 1,
                    y: self.shadow.origin.y + self.shadow.dim_y - 1,
                    z: self.shadow.origin.z + self.shadow.dim_z - 1,
                },
            );
            write_boxes(vol, &[full]);
            self.shadow.needs_full = true;
            return bf_result::BF_ERR_BAD_ARG;
        }
        unsafe {
            core::ptr::copy_nonoverlapping(self.shadow.voxels.as_ptr(), vol.voxels, need);
        }
        // v22 (#163): export the engine-maintained coarse mip. Null pointer or a
        // too-small buffer just skips the copy; dims are always written so the
        // caller can size the buffer next call.
        let co = SHADOW_COARSE;
        vol.coarse_dim_x = (self.shadow.dim_x / co) as u32;
        vol.coarse_dim_y = (self.shadow.dim_y / co) as u32;
        vol.coarse_dim_z = (self.shadow.dim_z / co) as u32;
        if !vol.coarse.is_null() && (vol.coarse_cap as usize) >= self.shadow.coarse.len() {
            unsafe {
                core::ptr::copy_nonoverlapping(
                    self.shadow.coarse.as_ptr(),
                    vol.coarse,
                    self.shadow.coarse.len(),
                );
            }
        }
        self.shadow.empty_dirty();
        bf_result::BF_OK
    }

    pub fn debug_shadow_occupancy(&mut self, x: i32, y: i32, z: i32) -> i32 {
        self.ensure_shadow_volume();
        let o = self.shadow.origin;
        if x < o.x || x >= o.x + self.shadow.dim_x
            || y < o.y || y >= o.y + self.shadow.dim_y
            || z < o.z || z >= o.z + self.shadow.dim_z
        {
            return -1;
        }
        let gx = Self::wrap(x, self.shadow.dim_x);
        let gy = y - o.y;
        let gz = Self::wrap(z, self.shadow.dim_z);
        let idx = (gz as usize) * (self.shadow.dim_y as usize) * (self.shadow.dim_x as usize)
            + (gy as usize) * (self.shadow.dim_x as usize)
            + gx as usize;
        self.shadow.voxels[idx] as i32
    }

    pub fn debug_shadow_revision(&mut self) -> u32 {
        self.ensure_shadow_volume();
        self.shadow.revision
    }
}
