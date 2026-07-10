//! #203 kid-friendly money + trade. Coins are a plain inventory item; every
//! trade-capable villager profession carries a small FIXED offer sheet (pure
//! data, deterministic, no haggling), and executing an offer is one inventory
//! swap. Stateless over the ABI: the app queries offers for an npc_id and
//! executes by index; nothing to open, close, or persist beyond the inventory
//! itself (coins ride the existing save).

use super::*;

impl<'c> World<'c> {
    /// The offer sheet for a profession (npc_id). give = what the player PAYS,
    /// get = what the player RECEIVES. Names resolve through content at call
    /// time so content ids stay the single source of truth.
    /// Kid pricing: whole coins, small counts, generous sells.
    fn trade_table(npc_id: i32) -> &'static [(&'static str, u16, &'static str, u16)] {
        match npc_id {
            // Woodcutter: wood economy.
            4 => &[
                ("oak_log", 8, "coin", 1),      // sell logs
                ("coin", 1, "oak_planks", 8),   // buy planks
                ("coin", 1, "torch", 4),        // buy torches
            ],
            // Stone Mason: stone economy.
            5 => &[
                ("cobblestone", 8, "coin", 1),
                ("coin", 2, "stone_brick", 8),
                ("coin", 2, "glass", 4),
            ],
            // Blacksmith: iron economy.
            6 => &[
                ("raw_iron", 4, "coin", 2),
                ("coin", 3, "iron_ingot", 2),
                ("coin", 6, "iron_pickaxe", 1),
            ],
            // Herbalist: food economy.
            3 => &[
                ("berry_cluster", 6, "coin", 1),
                ("coin", 2, "honey_cake", 2),
            ],
            // Elder: curios.
            1 => &[
                ("color_dust", 6, "coin", 2),
                ("coin", 2, "glow_dust", 4),
            ],
            _ => &[],
        }
    }

    /// Fill `out` with the offer sheet for a profession. active=0 when the
    /// profession does not trade (Builder) or content is missing.
    pub fn trade_offers(&self, npc_id: i32, out: &mut bf_trade_view) {
        *out = bf_trade_view::default();
        let table = Self::trade_table(npc_id);
        if table.is_empty() || self.content.is_none() {
            return;
        }
        let mut n = 0usize;
        for &(give, gc, get, tc) in table.iter().take(out.offers.len()) {
            let gi = self.item_id_by_name(give);
            let ti = self.item_id_by_name(get);
            if gi == 0 || ti == 0 {
                continue; // content missing an item: skip the offer, not the sheet
            }
            out.offers[n] = bf_trade_offer { give_item: gi, give_count: gc, get_item: ti, get_count: tc };
            n += 1;
        }
        out.active = if n > 0 { 1 } else { 0 };
        out.npc_id = npc_id as u32;
        out.offer_count = n as u32;
    }

    /// Execute offer `idx` for profession `npc_id`: verify the player holds the
    /// payment, take it, give the goods. Returns false (and changes nothing) if
    /// the payment is short or the inventory cannot hold the goods.
    pub fn trade_execute(&mut self, npc_id: i32, idx: u32) -> bool {
        let mut view = bf_trade_view::default();
        self.trade_offers(npc_id, &mut view);
        if view.active == 0 || idx >= view.offer_count {
            return false;
        }
        let o = view.offers[idx as usize];
        let Some(inv) = self.inv.as_mut() else { return false };
        if inv.count_item(o.give_item) < o.give_count {
            return false;
        }
        // Pay first, then receive; if the goods do not fully fit, undo both sides.
        if !inv.remove_item(o.give_item, o.give_count) {
            return false;
        }
        let before = inv.count_item(o.get_item);
        let ok = inv.add(ItemStack { item: o.get_item, count: o.get_count, durability: 0xFFFF });
        if !ok {
            let added = inv.count_item(o.get_item).saturating_sub(before);
            if added > 0 {
                inv.remove_item(o.get_item, added);
            }
            let _ = inv.add(ItemStack { item: o.give_item, count: o.give_count, durability: 0xFFFF });
            return false;
        }
        let pv = self.player_voxel();
        self.fx(5, pv, 0); // little sparkle: the trade landed
        true
    }
}
