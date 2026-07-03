//! Chunk store: faithful port of the ChunkStore in engine/include/blockcore/chunk.hpp.
//! An in-memory map of resident chunks. (The dead store-level serialize/deserialize was
//! removed from the C++ side too; saving goes through the chunk directly.)

use crate::chunk::PaletteChunk;
use crate::types::ChunkCoord;
use crate::worldgen::WORLD_PERIOD_CHUNKS;
use std::collections::HashMap;

// #179 looping world: chunk keys are CANONICAL on the x/z torus axes. Every
// store method wraps its key, so a lookup for the chunk "one past the seam"
// (x = 2048 or x = -1) resolves to the resident canonical chunk. This is the
// single residency choke point: meshing, lighting, physics and streaming all
// come through here, so cross-seam neighbour reads just work.
#[inline]
fn canon(c: ChunkCoord) -> ChunkCoord {
    ChunkCoord {
        x: c.x.rem_euclid(WORLD_PERIOD_CHUNKS),
        y: c.y,
        z: c.z.rem_euclid(WORLD_PERIOD_CHUNKS),
    }
}

#[derive(Default)]
pub struct ChunkStore {
    map: HashMap<ChunkCoord, PaletteChunk>,
}

impl ChunkStore {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn get(&self, c: ChunkCoord) -> Option<&PaletteChunk> {
        self.map.get(&canon(c))
    }
    pub fn get_mut(&mut self, c: ChunkCoord) -> Option<&mut PaletteChunk> {
        self.map.get_mut(&canon(c))
    }
    pub fn get_or_create(&mut self, c: ChunkCoord) -> &mut PaletteChunk {
        let c = canon(c);
        self.map.entry(c).or_insert_with(|| PaletteChunk::new(c, 0))
    }
    pub fn evict(&mut self, c: ChunkCoord) {
        self.map.remove(&canon(c));
    }
    pub fn is_resident(&self, c: ChunkCoord) -> bool {
        self.map.contains_key(&canon(c))
    }
    pub fn insert(&mut self, ch: PaletteChunk) {
        self.map.insert(canon(ch.coord()), ch);
    }
    pub fn resident_count(&self) -> usize {
        self.map.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_evict() {
        let mut s = ChunkStore::new();
        let c = ChunkCoord { x: 0, y: 0, z: 0 };
        assert!(s.get(c).is_none());
        s.get_or_create(c).set(8, 0, 8, 3);
        assert!(s.is_resident(c));
        assert_eq!(s.get(c).unwrap().get(8, 0, 8), 3);
        assert_eq!(s.resident_count(), 1);
        s.evict(c);
        assert!(!s.is_resident(c));
    }
}
