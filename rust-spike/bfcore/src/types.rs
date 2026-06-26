//! Shared POD value types, mirroring contract/blockcore_interfaces.hpp.

pub type BlockId = u16;
pub type ItemId = u16;

pub const CHUNK_DIM: usize = 16;
pub const CHUNK_VOL: usize = CHUNK_DIM * CHUNK_DIM * CHUNK_DIM; // 4096
pub const REGION_CHUNKS: i32 = 8;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct ChunkCoord {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct IVec3 {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

/// One stack in an inventory slot. An empty slot is item == 0 || count == 0.
/// Default durability is 0xFFFF, matching the C++ `ItemStack{}`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct ItemStack {
    pub item: ItemId,
    pub count: u16,
    pub durability: u16,
}

impl Default for ItemStack {
    fn default() -> Self {
        Self { item: 0, count: 0, durability: 0xFFFF }
    }
}

impl ItemStack {
    pub fn is_empty(&self) -> bool {
        self.item == 0 || self.count == 0
    }
}

/// Item metadata the inventory consults for per-item stack limits. The C++ side
/// passes an `IItemRegistry*`; here it is a trait, and `None` means "default 64".
pub trait ItemRegistry {
    /// Max stack for `item`; 0 is treated as "no override" by callers.
    fn max_stack(&self, item: ItemId) -> u16;
}
