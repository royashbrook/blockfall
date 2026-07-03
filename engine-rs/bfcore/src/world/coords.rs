use super::*;

// #179 looping world: the world is a torus with period WORLD_PERIOD blocks in
// x/z (WRAP_CHUNKS chunks). Chunk store keys, block coordinates and entity
// positions are kept CANONICAL (in [0, period)); distances and render-relative
// offsets use the NEAREST IMAGE so things across the seam behave as adjacent.
pub(crate) const WRAP_BLOCKS: i32 = worldgen::WORLD_PERIOD;
pub(crate) const WRAP_CHUNKS: i32 = worldgen::WORLD_PERIOD_CHUNKS;

impl<'c> World<'c> {
    // Mirrors the static helpers in world.hpp.
    pub(super) fn ifloor(f: f32) -> i32 {
        f.floor() as i32
    }

    // ---- #179 torus wrap helpers ------------------------------------------
    /// Canonical block x/z in [0, WRAP_BLOCKS). Bitmask (power-of-two period).
    #[inline]
    pub(super) fn wrap_block(v: i32) -> i32 {
        v & (WRAP_BLOCKS - 1)
    }

    /// Canonical block position (x/z wrapped, y untouched).
    #[inline]
    pub(super) fn canon_block(w: IVec3) -> IVec3 {
        IVec3 { x: Self::wrap_block(w.x), y: w.y, z: Self::wrap_block(w.z) }
    }

    /// Canonical chunk coordinate (x/z wrapped mod WRAP_CHUNKS, y untouched).
    #[inline]
    pub(super) fn canon_chunk(cc: ChunkCoord) -> ChunkCoord {
        ChunkCoord {
            x: cc.x.rem_euclid(WRAP_CHUNKS),
            y: cc.y,
            z: cc.z.rem_euclid(WRAP_CHUNKS),
        }
    }

    /// Nearest-image signed block delta in [-WRAP_BLOCKS/2, WRAP_BLOCKS/2).
    #[inline]
    pub(super) fn wrap_signed_block(d: i32) -> i32 {
        ((d + WRAP_BLOCKS / 2) & (WRAP_BLOCKS - 1)) - WRAP_BLOCKS / 2
    }

    /// Nearest-image signed chunk delta in [-WRAP_CHUNKS/2, WRAP_CHUNKS/2).
    #[inline]
    pub(super) fn wrap_signed_chunk(d: i32) -> i32 {
        let m = d.rem_euclid(WRAP_CHUNKS);
        if m >= WRAP_CHUNKS / 2 { m - WRAP_CHUNKS } else { m }
    }

    /// Nearest-image signed float delta in [-period/2, period/2).
    #[inline]
    pub(super) fn wrap_signed_f(d: f32) -> f32 {
        let w = WRAP_BLOCKS as f32;
        (d + w * 0.5).rem_euclid(w) - w * 0.5
    }

    /// Canonical float world x/z in [0, WRAP_BLOCKS).
    #[inline]
    pub(super) fn wrap_pos_f(v: f32) -> f32 {
        v.rem_euclid(WRAP_BLOCKS as f32)
    }

    /// Wrap an entity position onto the canonical torus frame (x/z only).
    #[inline]
    pub(super) fn wrap_v3_xz(v: V3) -> V3 {
        V3::new(Self::wrap_pos_f(v.x), v.y, Self::wrap_pos_f(v.z))
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
        // #179: nearest-image so chunks across the seam count as adjacent.
        let dx = Self::wrap_signed_chunk(a.x - c.x) as i64;
        let dz = Self::wrap_signed_chunk(a.z - c.z) as i64;
        dx * dx + dz * dz
    }

    pub(super) fn chunk_center_distance_from(&self, cc: ChunkCoord, pos: V3) -> f32 {
        let ctr = V3::new(
            (cc.x as f32 + 0.5) * KCHUNK_DIM as f32,
            (cc.y as f32 + 0.5) * KCHUNK_DIM as f32,
            (cc.z as f32 + 0.5) * KCHUNK_DIM as f32,
        );
        // #179: nearest-image on the torus axes.
        let to_c = V3::new(
            Self::wrap_signed_f(ctr.x - pos.x),
            ctr.y - pos.y,
            Self::wrap_signed_f(ctr.z - pos.z),
        );
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
