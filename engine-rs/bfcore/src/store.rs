//! Chunk store: faithful port of the ChunkStore in engine/include/blockcore/chunk.hpp.
//! An in-memory map of resident chunks. (The dead store-level serialize/deserialize was
//! removed from the C++ side too; saving goes through the chunk directly.)

use crate::chunk::PaletteChunk;
use crate::types::ChunkCoord;
use std::collections::HashMap;

#[derive(Default)]
pub struct ChunkStore {
    map: HashMap<ChunkCoord, PaletteChunk>,
}

impl ChunkStore {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn get(&self, c: ChunkCoord) -> Option<&PaletteChunk> {
        self.map.get(&c)
    }
    pub fn get_mut(&mut self, c: ChunkCoord) -> Option<&mut PaletteChunk> {
        self.map.get_mut(&c)
    }
    pub fn get_or_create(&mut self, c: ChunkCoord) -> &mut PaletteChunk {
        self.map.entry(c).or_insert_with(|| PaletteChunk::new(c, 0))
    }
    pub fn evict(&mut self, c: ChunkCoord) {
        self.map.remove(&c);
    }
    pub fn is_resident(&self, c: ChunkCoord) -> bool {
        self.map.contains_key(&c)
    }
    pub fn insert(&mut self, ch: PaletteChunk) {
        self.map.insert(ch.coord(), ch);
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
