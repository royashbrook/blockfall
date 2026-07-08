//! Inventory: faithful port of engine/include/blockcore/inventory.hpp.
//! Minecraft-style: add tops up existing stacks then fills empties; move merges,
//! swaps on a full cross-item move, and refuses a partial cross-item move.
//! Single-threaded; callers serialize.

use crate::types::{ItemId, ItemRegistry, ItemStack};

#[derive(Clone)]
pub struct Inventory<'r> {
    slots: Vec<ItemStack>,
    registry: Option<&'r dyn ItemRegistry>,
}

impl<'r> Inventory<'r> {
    pub fn new(slot_count: usize, registry: Option<&'r dyn ItemRegistry>) -> Self {
        Self {
            slots: vec![ItemStack::default(); slot_count],
            registry,
        }
    }

    pub fn slot_count(&self) -> usize {
        self.slots.len()
    }

    pub fn get(&self, slot: usize) -> ItemStack {
        self.slots.get(slot).copied().unwrap_or_default()
    }

    /// Directly overwrite a slot. False if out of range.
    pub fn set(&mut self, slot: usize, s: ItemStack) -> bool {
        if slot >= self.slots.len() {
            return false;
        }
        self.slots[slot] = self.clamp_stack(s);
        true
    }

    fn max_stack(&self, item: ItemId) -> u16 {
        if let Some(r) = self.registry {
            let m = r.max_stack(item);
            if m > 0 {
                return m;
            }
        }
        64
    }

    fn clamp_stack(&self, mut s: ItemStack) -> ItemStack {
        if s.item == 0 || s.count == 0 {
            return ItemStack::default();
        }
        s.count = s.count.min(self.max_stack(s.item));
        s
    }

    /// Merge `s` into same-item stacks (slot 0..N), then fill empties (slot 0..N).
    /// Returns true only if every unit was placed.
    pub fn add(&mut self, mut s: ItemStack) -> bool {
        if s.item == 0 || s.count == 0 {
            return true;
        }
        let max_s = self.max_stack(s.item);
        for slot in self.slots.iter_mut() {
            if s.count == 0 {
                break;
            }
            if !slot.is_empty() && slot.item == s.item && slot.count < max_s {
                let take = s.count.min(max_s - slot.count);
                slot.count += take;
                s.count -= take;
            }
        }
        for slot in self.slots.iter_mut() {
            if s.count == 0 {
                break;
            }
            if slot.is_empty() {
                let take = s.count.min(max_s);
                *slot = ItemStack {
                    item: s.item,
                    count: take,
                    durability: s.durability,
                };
                s.count -= take;
            }
        }
        s.count == 0
    }

    /// Move up to `count` from `from` to `to`. See the rules in the module doc.
    pub fn move_item(&mut self, from: usize, to: usize, count: u16) -> bool {
        if from >= self.slots.len() || to >= self.slots.len() {
            return false;
        }
        if from == to {
            return true;
        }
        if count == 0 {
            return true;
        }
        if self.slots[from].is_empty() {
            return false;
        }
        let move_count = count.min(self.slots[from].count);

        if self.slots[to].is_empty() {
            let src = self.slots[from];
            self.slots[to] = ItemStack {
                item: src.item,
                count: move_count,
                durability: src.durability,
            };
            self.slots[from].count -= move_count;
            if self.slots[from].count == 0 {
                self.slots[from] = ItemStack::default();
            }
            return true;
        }

        if self.slots[to].item == self.slots[from].item {
            let max_s = self.max_stack(self.slots[from].item);
            let space = if self.slots[to].count < max_s {
                max_s - self.slots[to].count
            } else {
                0
            };
            let take = move_count.min(space);
            if take == 0 {
                return false;
            }
            self.slots[to].count += take;
            self.slots[from].count -= take;
            if self.slots[from].count == 0 {
                self.slots[from] = ItemStack::default();
            }
            return true;
        }

        // Different items: swap only if the whole from-stack is being moved.
        if move_count == self.slots[from].count {
            self.slots.swap(from, to);
            return true;
        }
        false
    }

    pub fn count_item(&self, item: ItemId) -> u16 {
        let mut total: u32 = 0;
        for slot in &self.slots {
            if !slot.is_empty() && slot.item == item {
                total += slot.count as u32;
            }
        }
        if total < 0xFFFF {
            total as u16
        } else {
            0xFFFF
        }
    }

    /// Remove exactly `count` of `item` across slots; all-or-nothing.
    pub fn remove_item(&mut self, item: ItemId, count: u16) -> bool {
        if count == 0 {
            return true;
        }
        if self.count_item(item) < count {
            return false;
        }
        let mut remaining = count;
        for slot in self.slots.iter_mut() {
            if remaining == 0 {
                break;
            }
            if !slot.is_empty() && slot.item == item {
                let take = slot.count.min(remaining);
                slot.count -= take;
                if slot.count == 0 {
                    *slot = ItemStack::default();
                }
                remaining -= take;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Reg; // item 99 caps at 16, everything else default 64
    impl ItemRegistry for Reg {
        fn max_stack(&self, item: ItemId) -> u16 {
            if item == 99 {
                16
            } else {
                64
            }
        }
    }
    fn stack(item: ItemId, count: u16) -> ItemStack {
        ItemStack {
            item,
            count,
            durability: 0xFFFF,
        }
    }

    #[test]
    fn add_stacks_and_fills() {
        let mut inv = Inventory::new(3, None);
        assert!(inv.add(stack(1, 50)));
        assert!(inv.add(stack(1, 50))); // 100 total: 64 in slot0, 36 spills to slot1
        assert_eq!(inv.get(0).count, 64);
        assert_eq!(inv.get(1), stack(1, 36));
        assert_eq!(inv.count_item(1), 100);
    }

    #[test]
    fn add_overflow_returns_false() {
        let mut inv = Inventory::new(1, None);
        assert!(!inv.add(stack(1, 100))); // only 64 fit
        assert_eq!(inv.get(0).count, 64);
        assert_eq!(inv.count_item(1), 64);
    }

    #[test]
    fn registry_caps_stack() {
        let reg = Reg;
        let mut inv = Inventory::new(4, Some(&reg));
        assert!(inv.add(stack(99, 40))); // 16 + 16 + 8 across three slots
        assert_eq!(inv.get(0).count, 16);
        assert_eq!(inv.get(1).count, 16);
        assert_eq!(inv.get(2).count, 8);
    }

    #[test]
    fn direct_set_clamps_to_registry_stack_size() {
        let reg = Reg;
        let mut inv = Inventory::new(1, Some(&reg));
        assert!(inv.set(0, stack(99, 40)));
        assert_eq!(inv.get(0), stack(99, 16));
    }

    #[test]
    fn move_rules() {
        let mut inv = Inventory::new(3, None);
        inv.set(0, stack(1, 10));
        inv.set(1, stack(1, 5));
        // same-item merge
        assert!(inv.move_item(0, 1, 3));
        assert_eq!(inv.get(0).count, 7);
        assert_eq!(inv.get(1).count, 8);
        // move into empty
        assert!(inv.move_item(0, 2, 7));
        assert!(inv.get(0).is_empty());
        assert_eq!(inv.get(2).count, 7);
        // cross-item: partial move is a no-op
        inv.set(0, stack(2, 4));
        assert!(!inv.move_item(0, 2, 2)); // slot2 holds item 1
        assert_eq!(inv.get(0), stack(2, 4));
        // cross-item: full move swaps
        assert!(inv.move_item(0, 2, 4));
        assert_eq!(inv.get(0), stack(1, 7));
        assert_eq!(inv.get(2), stack(2, 4));
    }

    #[test]
    fn remove_is_all_or_nothing() {
        let mut inv = Inventory::new(3, None);
        inv.add(stack(1, 30));
        assert!(!inv.remove_item(1, 50)); // not enough: removes nothing
        assert_eq!(inv.count_item(1), 30);
        assert!(inv.remove_item(1, 20));
        assert_eq!(inv.count_item(1), 10);
    }
}
