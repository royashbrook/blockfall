use super::*;

impl<'c> World<'c> {
    /// Highest solid block in an already-loaded column. Regrowth is ambient
    /// maintenance and must never invoke procedural generation on the frame thread.
    fn resident_surface_top(&self, wx: i32, wz: i32) -> i32 {
        let wx = Self::wrap_block(wx);
        let wz = Self::wrap_block(wz);
        let lx = Self::mod16(wx) as usize;
        let lz = Self::mod16(wz) as usize;
        for cy in (CY_MIN..=CY_MAX).rev() {
            let cc = Self::to_chunk(IVec3 { x: wx, y: cy * KCHUNK_DIM, z: wz });
            let Some(chunk) = self.store.get(cc) else { continue };
            for ly in (0..KCHUNK_DIM).rev() {
                if Self::solid_block(chunk.get(lx, ly as usize, lz)) {
                    return cy * KCHUNK_DIM + ly;
                }
            }
        }
        NO_FLOOR
    }

    pub(super) fn grow_small_tree(&mut self, wx: i32, surf: i32, wz: i32) {
        const LOG: BlockId = 21;
        const LEAFB: BlockId = 5;
        let h = 4 + (self.rand01() * 2.0) as i32;
        let top = surf + h;
        for y in (surf + 1)..=top {
            self.set_block_internal(IVec3 { x: wx, y, z: wz }, LOG);
        }
        for dy in -1..=2 {
            for dz in -2..=2 {
                for dx in -2..=2 {
                    if dx * dx + dz * dz + dy * dy * 2 > 5 {
                        continue;
                    }
                    if dx == 0 && dz == 0 && dy <= 0 {
                        continue;
                    }
                    let p = IVec3 {
                        x: wx + dx,
                        y: top + dy,
                        z: wz + dz,
                    };
                    if self.block_at(p) == AIR {
                        self.set_block_internal(p, LEAFB);
                    }
                }
            }
        }
    }

    pub(super) fn maintain_regrowth(&mut self, dt: f32) {
        if self.gen.is_none() {
            return;
        }
        self.regrow_timer -= dt;
        if self.regrow_timer > 0.0 {
            return;
        }
        self.regrow_timer = 5.0;
        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);
        let mut grew = 0;
        let mut attempt = 0;
        while attempt < 12 && grew < 2 {
            attempt += 1;
            let wx = px + (self.rand01() * 96.0) as i32 - 48;
            let wz = pz + (self.rand01() * 96.0) as i32 - 48;
            if self.region_sat(Self::to_chunk(IVec3 { x: wx, y: 0, z: wz })) < 0.5 {
                continue;
            }
            let surf = self.resident_surface_top(wx, wz);
            if surf == NO_FLOOR {
                continue;
            }
            if self.block_at(IVec3 {
                x: wx,
                y: surf,
                z: wz,
            }) != 1
            {
                continue;
            }
            let above = self.block_at(IVec3 {
                x: wx,
                y: surf + 1,
                z: wz,
            });
            if above != AIR && !Self::is_plant(above) {
                continue;
            }
            let mut near_tree = false;
            'outer: for dz in -3..=3 {
                for dx in -3..=3 {
                    for y in (surf + 1)..=(surf + 6) {
                        if Self::is_tree_block(self.block_at(IVec3 {
                            x: wx + dx,
                            y,
                            z: wz + dz,
                        })) {
                            near_tree = true;
                            break 'outer;
                        }
                    }
                }
            }
            if near_tree {
                continue;
            }
            self.grow_small_tree(wx, surf, wz);
            grew += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resident_surface_query_never_generates_missing_columns() {
        let mut world = World::new(None);
        world.set_block_internal(IVec3 { x: 4, y: 37, z: 6 }, GRASS);
        let resident_before = world.store.resident_count();
        assert_eq!(world.resident_surface_top(4, 6), 37);
        assert_eq!(world.resident_surface_top(400, 600), NO_FLOOR);
        assert_eq!(world.store.resident_count(), resident_before);
    }
}
