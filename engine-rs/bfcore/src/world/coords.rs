use super::*;

impl<'c> World<'c> {
    // Mirrors the static helpers in world.hpp.
    pub(super) fn ifloor(f: f32) -> i32 {
        f.floor() as i32
    }

    pub(super) fn floordiv(a: i32, b: i32) -> i32 {
        let mut q = a / b;
        if (a % b) != 0 && ((a < 0) != (b < 0)) {
            q -= 1;
        }
        q
    }

    pub(super) fn mod16(a: i32) -> i32 {
        let m = a % KCHUNK_DIM;
        if m < 0 {
            m + KCHUNK_DIM
        } else {
            m
        }
    }

    pub(super) fn to_chunk(w: IVec3) -> ChunkCoord {
        ChunkCoord {
            x: Self::floordiv(w.x, KCHUNK_DIM),
            y: Self::floordiv(w.y, KCHUNK_DIM),
            z: Self::floordiv(w.z, KCHUNK_DIM),
        }
    }

    pub(super) fn player_voxel(&self) -> IVec3 {
        IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        }
    }

    pub(super) fn dist2(a: ChunkCoord, c: ChunkCoord) -> i64 {
        let dx = (a.x - c.x) as i64;
        let dz = (a.z - c.z) as i64;
        dx * dx + dz * dz
    }

    pub(super) fn chunk_center_distance_from(&self, cc: ChunkCoord, pos: V3) -> f32 {
        let ctr = V3::new(
            (cc.x as f32 + 0.5) * KCHUNK_DIM as f32,
            (cc.y as f32 + 0.5) * KCHUNK_DIM as f32,
            (cc.z as f32 + 0.5) * KCHUNK_DIM as f32,
        );
        let to_c = V3::new(ctr.x - pos.x, ctr.y - pos.y, ctr.z - pos.z);
        dot(to_c, to_c).sqrt()
    }

    pub(super) fn forward_dir(&self) -> V3 {
        normalize(V3::new(
            self.pitch.cos() * self.yaw.sin(),
            self.pitch.sin(),
            self.pitch.cos() * self.yaw.cos(),
        ))
    }

    pub(super) fn rand01(&mut self) -> f32 {
        self.rng = self.rng.wrapping_mul(1664525).wrapping_add(1013904223);
        (self.rng >> 8) as f32 / 16777216.0
    }
}
