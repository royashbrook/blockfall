use super::*;

impl<'c> World<'c> {
    pub(super) fn equip_from_inventory(&mut self, inventory_slot: usize) -> bool {
        let mut incoming = match self.inv.as_ref() {
            Some(inv) if inventory_slot < inv.slot_count() => inv.get(inventory_slot),
            _ => return false,
        };
        let def = match self.content.and_then(|c| c.item_by_id(incoming.item)) {
            Some(def) if (1..=3).contains(&def.armor_slot) => def,
            _ => return false,
        };
        let equipment_slot = usize::from(def.armor_slot - 1);
        if incoming.durability == 0xFFFF {
            incoming.durability = def.armor_durability;
        }
        let old = self.equipment[equipment_slot];
        if !self.inv.as_mut().unwrap().set(inventory_slot, old) {
            return false;
        }
        self.equipment[equipment_slot] = incoming;
        true
    }

    pub(super) fn unequip(&mut self, equipment_slot: usize) -> bool {
        if equipment_slot >= self.equipment.len() || self.equipment[equipment_slot].is_empty() {
            return false;
        }
        let stack = self.equipment[equipment_slot];
        if self.inv.as_mut().is_some_and(|inv| inv.add(stack)) {
            self.equipment[equipment_slot] = ItemStack::default();
            return true;
        }
        false
    }

    pub(crate) fn armor_mask(&self) -> u8 {
        self.equipment
            .iter()
            .enumerate()
            .fold(0, |mask, (i, stack)| {
                mask | if stack.is_empty() { 0 } else { 1 << i }
            })
    }

    pub(crate) fn armor_tier_bits(&self) -> u8 {
        self.equipment
            .iter()
            .enumerate()
            .fold(0, |bits, (i, stack)| {
                let tier = self
                    .content
                    .and_then(|c| c.item_by_id(stack.item))
                    .map(|d| d.armor_tier.min(3))
                    .unwrap_or(0);
                bits | (tier << (i * 2))
            })
    }

    pub(super) fn absorb_armor_damage(&mut self, damage: f32) -> f32 {
        let points: u8 = self
            .equipment
            .iter()
            .filter_map(|stack| self.content.and_then(|c| c.item_by_id(stack.item)))
            .map(|def| def.armor_points)
            .sum();
        if points == 0 {
            return damage;
        }

        for i in 0..self.equipment.len() {
            let stack = self.equipment[i];
            if stack.is_empty() {
                continue;
            }
            let maximum = self
                .content
                .and_then(|c| c.item_by_id(stack.item))
                .map(|def| def.armor_durability)
                .unwrap_or(0);
            let durability = if stack.durability == 0xFFFF {
                maximum
            } else {
                stack.durability
            }
            .saturating_sub(1);
            if durability == 0 {
                self.equipment[i] = ItemStack::default();
            } else {
                self.equipment[i].durability = durability;
            }
        }

        damage * (1.0 - (f32::from(points) * 0.08).min(0.60))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn armor_equips_swaps_mitigates_and_breaks() {
        let mut content = ContentRegistry::new();
        content.load(concat!(env!("CARGO_MANIFEST_DIR"), "/../../content"));
        let mut world = World::new(None);
        world.set_content(&content);
        world.inv.as_mut().unwrap().set(
            0,
            ItemStack {
                item: 104,
                count: 1,
                durability: 0xFFFF,
            },
        );

        assert!(world.equip_from_inventory(0));
        assert_eq!(world.armor_mask(), 1);
        assert_eq!(world.armor_tier_bits(), 1);
        assert_eq!(world.equipment[0].durability, 80);
        assert!((world.absorb_armor_damage(10.0) - 9.2).abs() < 0.001);
        assert_eq!(world.equipment[0].durability, 79);

        world.equipment[0].durability = 1;
        world.absorb_armor_damage(1.0);
        assert_eq!(world.armor_mask(), 0);
        assert!(world.inv.as_ref().unwrap().get(0).is_empty());

        world.inv.as_mut().unwrap().set(
            0,
            ItemStack {
                item: 108,
                count: 1,
                durability: 0xFFFF,
            },
        );
        assert!(world.equip_from_inventory(0));
        let path = std::env::temp_dir().join(format!(
            "blockfall-equipment-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&path);
        assert!(world.save(path.to_str().unwrap()));

        let mut loaded = World::new(None);
        loaded.set_content(&content);
        assert!(loaded.load(path.to_str().unwrap()));
        assert_eq!(loaded.equipment[1].item, 108);
        assert_eq!(loaded.equipment[1].durability, 400);
        assert_eq!(loaded.armor_mask(), 0x2);
        assert_eq!(loaded.armor_tier_bits(), 0x8);
        let _ = std::fs::remove_dir_all(path);
    }
}
