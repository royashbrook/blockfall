use super::*;

impl<'c> World<'c> {
    // ---- block reads/writes ---------------------------------------------
    pub(super) fn block_at(&self, w: IVec3) -> BlockId {
        let cc = Self::to_chunk(w);
        match self.store.get(cc) {
            Some(ch) => ch.get(
                Self::mod16(w.x) as usize,
                Self::mod16(w.y) as usize,
                Self::mod16(w.z) as usize,
            ),
            None => AIR,
        }
    }

    pub(super) fn set_block_internal(&mut self, w: IVec3, b: BlockId) {
        self.set_block_remote(w, b, false);
    }

    pub(super) fn set_block_remote(&mut self, w: IVec3, b: BlockId, from_remote: bool) {
        let cc = Self::to_chunk(w);
        self.store.get_or_create(cc).set(
            Self::mod16(w.x) as usize,
            Self::mod16(w.y) as usize,
            Self::mod16(w.z) as usize,
            b,
        );
        self.mark_dirty(cc);
        self.urgent_dirty.insert(cc); // player-visible edit: jump the mesh queue
        self.edited.insert(cc);
        // A block changed: re-stamp this chunk's column into the toroidal shadow grid.
        self.shadow.refill_cols.insert((cc.x, cc.z));
        if !from_remote {
            if let Some(cb) = self.edit_cb.as_mut() {
                cb(w, b);
            }
        }
        let dirs = [
            IVec3 { x: 1, y: 0, z: 0 },
            IVec3 { x: -1, y: 0, z: 0 },
            IVec3 { x: 0, y: 1, z: 0 },
            IVec3 { x: 0, y: -1, z: 0 },
            IVec3 { x: 0, y: 0, z: 1 },
            IVec3 { x: 0, y: 0, z: -1 },
        ];
        for d in dirs {
            let nc = Self::to_chunk(IVec3 {
                x: w.x + d.x,
                y: w.y + d.y,
                z: w.z + d.z,
            });
            if nc != cc && self.store.is_resident(nc) {
                self.mark_dirty(nc);
                self.urgent_dirty.insert(nc);
            }
        }
    }

    // ---- block classification (static, mirror world.hpp) -----------------
    pub(super) fn is_plant(b: BlockId) -> bool {
        (36..=47).contains(&b) || b == 5 || b == 27 || b == 48
    }

    // #118 snow overlay: snow_layer (12, fresh) and trodden_snow (54, footprint) are a
    // thin blanket on the surface block, not a solid cube. They are walk-through so the
    // player stands on the block below with the snow at their feet (and footprints, #117,
    // read at ground level rather than a block up).
    pub(super) fn is_snow_overlay(b: BlockId) -> bool {
        b == SNOW_LAYER || b == TRODDEN_SNOW
    }

    pub(super) fn solid_block(b: BlockId) -> bool {
        b != AIR && b != WATER && b != 50 && !Self::is_plant(b) && !Self::is_snow_overlay(b)
    }

    pub(super) fn is_gravity_block(b: BlockId) -> bool {
        b == 6 || b == 11
    }

    pub(super) fn is_log(b: BlockId) -> bool {
        b == 21 || b == 22 || b == 49
    }

    pub(super) fn is_leaf(b: BlockId) -> bool {
        // 48 = pine needles (#62); missing here meant felled pines left their
        // canopy floating and pine needles cast no occupancy shadow.
        b == 5 || b == 27 || b == 48
    }

    pub(super) fn is_prop_block(id: BlockId) -> bool {
        (36..=47).contains(&id)
    }

    pub(super) fn is_tree_block(id: BlockId) -> bool {
        id == 5 || id == 27 || id == 48 || id == 21 || id == 22 || id == 49
    }

    pub(super) fn collide_solid(&self, x: i32, y: i32, z: i32) -> bool {
        let b = self.block_at(IVec3 { x, y, z });
        b != AIR && b != WATER && b != 50 && !Self::is_plant(b) && !Self::is_snow_overlay(b)
    }

    pub(super) fn box_collides(&self, p: V3) -> bool {
        let hw = 0.3f32;
        let x0 = Self::ifloor(p.x - hw);
        let x1 = Self::ifloor(p.x + hw);
        let z0 = Self::ifloor(p.z - hw);
        let z1 = Self::ifloor(p.z + hw);
        let y0 = Self::ifloor(p.y - 1.6);
        let y1 = Self::ifloor(p.y + 0.2);
        for x in x0..=x1 {
            for y in y0..=y1 {
                for z in z0..=z1 {
                    if self.collide_solid(x, y, z) {
                        return true;
                    }
                }
            }
        }
        false
    }

    pub(super) fn voxel_in_player_box(&self, v: IVec3) -> bool {
        let hw = 0.3f32;
        let x0 = Self::ifloor(self.pos.x - hw);
        let x1 = Self::ifloor(self.pos.x + hw);
        let z0 = Self::ifloor(self.pos.z - hw);
        let z1 = Self::ifloor(self.pos.z + hw);
        let y0 = Self::ifloor(self.pos.y - 1.6);
        let y1 = Self::ifloor(self.pos.y + 0.2);
        v.x >= x0 && v.x <= x1 && v.y >= y0 && v.y <= y1 && v.z >= z0 && v.z <= z1
    }

    // Standable surface (top of first solid block) scanning DOWN from yTop, or
    // NO_FLOOR if none found.
    pub(super) fn floor_below(&self, x: i32, y_top: i32, z: i32) -> i32 {
        let mut y = y_top;
        while y > y_top - 80 {
            if self.collide_solid(x, y, z) {
                return y + 1;
            }
            y -= 1;
        }
        NO_FLOOR
    }

    // Standable feet Y at (x,z) scanning down from y_top, as an Option for the AI
    // pathfinder. Thin wrapper over floor_below so creature_ai never sees NO_FLOOR.
    pub(super) fn ai_floor(&self, x: i32, y_top: i32, z: i32) -> Option<i32> {
        let f = self.floor_below(x, y_top, z);
        if f == NO_FLOOR {
            None
        } else {
            Some(f)
        }
    }

    // Top standable block at a world column, GENERATING the column if not resident.
    pub(super) fn surface_top(&self, wx: i32, wz: i32) -> i32 {
        let gen = match self.gen.as_ref() {
            Some(g) => g,
            None => return NO_FLOOR,
        };
        let lx = Self::mod16(wx);
        let lz = Self::mod16(wz);
        for cy in (CY_MIN..=CY_MAX).rev() {
            let base = Self::to_chunk(IVec3 {
                x: wx,
                y: cy * KCHUNK_DIM,
                z: wz,
            });
            let cc = ChunkCoord {
                x: base.x,
                y: cy,
                z: base.z,
            };
            if let Some(res) = self.store.get(cc) {
                for ly in (0..KCHUNK_DIM).rev() {
                    if Self::solid_block(res.get(lx as usize, ly as usize, lz as usize)) {
                        return cy * KCHUNK_DIM + ly;
                    }
                }
            } else {
                let mut tmp = PaletteChunk::new(cc, 0);
                gen.generate(cc, &mut tmp);
                for ly in (0..KCHUNK_DIM).rev() {
                    if Self::solid_block(tmp.get(lx as usize, ly as usize, lz as usize)) {
                        return cy * KCHUNK_DIM + ly;
                    }
                }
            }
        }
        NO_FLOOR
    }

    // Generate a chunk via the worldgen (pure fn of seed+coord). Borrows gen
    // immutably and returns an owned chunk so the caller can mutate the store
    // afterward without a borrow conflict.
    pub(super) fn gen_chunk(&self, cc: ChunkCoord) -> Option<PaletteChunk> {
        let gen = self.gen.as_ref()?;
        let mut ch = PaletteChunk::new(cc, 0);
        gen.generate(cc, &mut ch);
        Some(ch)
    }
}
