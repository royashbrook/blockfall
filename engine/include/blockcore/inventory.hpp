// ============================================================================
// Blockfall — Inventory implementation  (engine/include/blockcore/inventory.hpp)
// ----------------------------------------------------------------------------
// class Inventory final : public bf::IInventory
//
// Thread-safety: none — callers (game tick, net handler) must serialize.
// ============================================================================
#pragma once
#include "../../contract/blockcore_interfaces.hpp"

#include <vector>
#include <cstdint>

namespace bf {

class Inventory final : public IInventory {
public:
    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// @param slot_count  Number of inventory slots (fixed for the lifetime).
    /// @param registry    Optional item registry for per-item max_stack lookup.
    ///                    If nullptr, max_stack defaults to 64 for every item.
    explicit Inventory(std::size_t slot_count,
                       const IItemRegistry* registry = nullptr)
        : slots_(slot_count), registry_(registry) {}

    // -----------------------------------------------------------------------
    // IInventory interface
    // -----------------------------------------------------------------------

    std::size_t slot_count() const override { return slots_.size(); }

    ItemStack get(std::size_t slot) const override {
        if (slot >= slots_.size()) return {};
        return slots_[slot];
    }

    /// Directly overwrite a slot.  Returns false if slot is out of range.
    bool set(std::size_t slot, ItemStack s) override {
        if (slot >= slots_.size()) return false;
        slots_[slot] = s;
        return true;
    }

    /// Merge `s` into existing same-item stacks, then fill empty slots.
    ///
    /// Returns true ONLY if every unit in `s` was placed.
    /// If the inventory is too full to hold all of `s`, the method places as
    /// many items as possible and returns false — the caller must track the
    /// remainder (typically by examining count_item delta).
    ///
    /// NOTE: The stack is consumed left-to-right: existing partial stacks of
    /// the same item are topped up first (slot 0 → N), then empty slots are
    /// claimed (slot 0 → N).  This is consistent with Minecraft-style behaviour.
    bool add(ItemStack s) override {
        if (s.item == 0 || s.count == 0) return true;
        const std::uint16_t max_s = max_stack(s.item);

        // Pass 1 — top up existing partial stacks of the same item.
        for (auto& slot : slots_) {
            if (s.count == 0) break;
            if (!is_empty(slot) && slot.item == s.item && slot.count < max_s) {
                std::uint16_t space = static_cast<std::uint16_t>(max_s - slot.count);
                std::uint16_t take  = (s.count < space) ? s.count : space;
                slot.count = static_cast<std::uint16_t>(slot.count + take);
                s.count    = static_cast<std::uint16_t>(s.count    - take);
            }
        }

        // Pass 2 — fill empty slots.
        for (auto& slot : slots_) {
            if (s.count == 0) break;
            if (is_empty(slot)) {
                std::uint16_t take = (s.count < max_s) ? s.count : max_s;
                slot = { s.item, take, s.durability };
                s.count = static_cast<std::uint16_t>(s.count - take);
            }
        }

        return s.count == 0;
    }

    /// Move up to `count` items from slot `from` to slot `to`.
    ///
    /// Rules (Minecraft-like):
    ///  • Same item, `to` has room: merge up to `count` units (respects max_stack).
    ///  • Different items and `count` covers the ENTIRE `from` stack: swap the two slots.
    ///  • Different items, partial move (count < from.count): no-op, return false.
    ///  • `to` is empty: move up to `count` units into `to`.
    ///  • from == to: no-op, return true.
    bool move(std::size_t from, std::size_t to, std::uint16_t count) override {
        if (from >= slots_.size() || to >= slots_.size()) return false;
        if (from == to) return true;
        if (count == 0) return true;

        ItemStack& src = slots_[from];
        ItemStack& dst = slots_[to];

        if (is_empty(src)) return false;

        // Clamp count to what's available.
        std::uint16_t move_count = (count < src.count) ? count : src.count;

        if (is_empty(dst)) {
            // Destination is empty — just move.
            dst = { src.item, move_count, src.durability };
            src.count = static_cast<std::uint16_t>(src.count - move_count);
            if (src.count == 0) src = {};
            return true;
        }

        if (dst.item == src.item) {
            // Same item — merge.
            const std::uint16_t max_s = max_stack(src.item);
            std::uint16_t space = (dst.count < max_s)
                                  ? static_cast<std::uint16_t>(max_s - dst.count)
                                  : std::uint16_t{0};
            std::uint16_t take = (move_count < space) ? move_count : space;
            if (take == 0) return false;
            dst.count = static_cast<std::uint16_t>(dst.count + take);
            src.count = static_cast<std::uint16_t>(src.count - take);
            if (src.count == 0) src = {};
            return true;
        }

        // Different items — swap only if the full from-stack is being moved.
        if (move_count == src.count) {
            std::swap(src, dst);
            return true;
        }

        return false; // partial cross-item move: not allowed.
    }

    // -----------------------------------------------------------------------
    // Extended helpers (used by CraftingSystem and tests)
    // -----------------------------------------------------------------------

    /// Count how many of `item` exist across all slots.
    std::uint16_t count_item(ItemId item) const {
        std::uint32_t total = 0;
        for (const auto& slot : slots_) {
            if (!is_empty(slot) && slot.item == item)
                total += slot.count;
        }
        // Saturate at UINT16_MAX (pathological case).
        return static_cast<std::uint16_t>(total < 0xFFFFu ? total : 0xFFFFu);
    }

    /// Remove exactly `count` of `item` spread across slots.
    ///
    /// All-or-nothing: if there aren't enough, removes NOTHING and returns false.
    bool remove_item(ItemId item, std::uint16_t count) {
        if (count == 0) return true;
        // Verify first.
        if (count_item(item) < count) return false;

        // Remove.
        std::uint16_t remaining = count;
        for (auto& slot : slots_) {
            if (remaining == 0) break;
            if (!is_empty(slot) && slot.item == item) {
                std::uint16_t take = (slot.count < remaining) ? slot.count : remaining;
                slot.count = static_cast<std::uint16_t>(slot.count - take);
                if (slot.count == 0) slot = {};
                remaining  = static_cast<std::uint16_t>(remaining - take);
            }
        }
        return true;
    }

private:
    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    std::vector<ItemStack> slots_;
    const IItemRegistry*   registry_;

    static bool is_empty(const ItemStack& s) {
        return s.item == 0 || s.count == 0;
    }

    std::uint16_t max_stack(ItemId item) const {
        if (registry_) {
            const ItemDef* def = registry_->by_id(item);
            if (def && def->max_stack > 0) return def->max_stack;
        }
        return 64;
    }
};

} // namespace bf
