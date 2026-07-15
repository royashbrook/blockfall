use super::*;

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(super) struct RegionKey {
    pub(super) x: i32,
    pub(super) z: i32,
}

impl<'c> World<'c> {
    pub(super) fn region_key(cc: ChunkCoord) -> RegionKey {
        // #179: canonical chunk first so region keys are unique on the torus
        // (KREGION_CHUNKS divides WRAP_CHUNKS, so regions tile it exactly).
        let cc = Self::canon_chunk(cc);
        RegionKey {
            x: Self::floordiv(cc.x, KREGION_CHUNKS),
            z: Self::floordiv(cc.z, KREGION_CHUNKS),
        }
    }

    pub(super) fn region_sat(&self, cc: ChunkCoord) -> f32 {
        match self.region_sat.get(&Self::region_key(cc)) {
            Some(&v) => v,
            None => DIM_SAT,
        }
    }

    pub(super) fn restore_region(&mut self, cc: ChunkCoord) {
        self.region_sat.insert(Self::region_key(cc), 1.0);
    }

    pub(super) fn restore_homeland(&mut self, wx: i32, wz: i32) {
        let center = Self::region_key(Self::to_chunk(IVec3 { x: wx, y: 0, z: wz }));
        let region_count = WRAP_CHUNKS / KREGION_CHUNKS;
        for dz in -2..=2 {
            for dx in -2..=2 {
                self.region_sat.insert(
                    RegionKey {
                        x: (center.x + dx).rem_euclid(region_count),
                        z: (center.z + dz).rem_euclid(region_count),
                    },
                    1.0,
                );
            }
        }
    }
}
