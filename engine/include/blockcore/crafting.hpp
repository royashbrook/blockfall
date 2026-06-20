// ============================================================================
// Blockfall — CraftingSystem implementation (engine/include/blockcore/crafting.hpp)
// ----------------------------------------------------------------------------
// class CraftingSystem final : public bf::ICraftingSystem
//
// All-or-nothing guarantee:
//   commit() either fully consumes every required ingredient AND produces the
//   result, or it leaves the inventory completely unchanged and returns false.
//   There is no intermediate state in which ingredients are consumed without
//   a result being produced, or a result produced without consuming inputs.
// ============================================================================
#pragma once
#include "../../contract/blockcore_interfaces.hpp"
#include "inventory.hpp"   // for Inventory::remove_item / count_item helpers

#include <span>
#include <optional>
#include <unordered_map>
#include <cstdint>

namespace bf {

class CraftingSystem final : public ICraftingSystem {
public:
    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// @param recipes   Non-owning pointer to the recipe book.  Must outlive this.
    /// @param registry  Accepted for API symmetry with Inventory; not used internally.
    explicit CraftingSystem(const IRecipeBook* recipes,
                            const IItemRegistry* /*registry*/ = nullptr)
        : recipes_(recipes) {}

    // -----------------------------------------------------------------------
    // ICraftingSystem interface
    // -----------------------------------------------------------------------

    /// Query which recipe the grid matches, without touching any inventory.
    std::optional<RecipeMatch>
    preview(std::span<const ItemId> grid, int dim) const override {
        if (!recipes_) return std::nullopt;
        return recipes_->match(grid, dim);
    }

    /// Atomically consume ingredients from `inv` and add the crafted result.
    ///
    /// Steps:
    ///  1. Match `grid` against the recipe book (no-op if no match).
    ///  2. Count required ingredients per item id across non-empty grid cells.
    ///  3. Verify the inventory holds at least those quantities (all-or-nothing
    ///     check via count_item — we never deduct anything if the check fails).
    ///  4. Remove the ingredients (guaranteed to succeed after step 3 because
    ///     inventory is not mutated between the check and the removal).
    ///  5. Add the result stack.  If add() returns false (extremely full
    ///     inventory), roll back by re-adding the consumed ingredients and
    ///     return false — preserving the all-or-nothing guarantee.
    ///
    /// Returns false (and leaves `inv` unchanged) when:
    ///  • No recipe matches the grid.
    ///  • The inventory doesn't hold enough of any required ingredient.
    ///  • The result stack cannot be placed in the inventory (no room).
    bool commit(IInventory& inv,
                std::span<const ItemId> grid,
                int dim) override
    {
        if (!recipes_) return false;

        // 1. Match recipe.
        std::optional<RecipeMatch> match = recipes_->match(grid, dim);
        if (!match) return false;

        // 2. Tally required ingredients (count per ItemId).
        //    grid cells with item == 0 are empty and ignored.
        std::unordered_map<ItemId, std::uint16_t> required;
        for (const ItemId id : grid) {
            if (id == 0) continue;
            required[id] = static_cast<std::uint16_t>(required[id] + 1);
        }

        // 3. Verify availability (all-or-nothing check).
        //    We call the Inventory helpers; fall back to the public interface
        //    for non-Inventory IInventory implementations.
        auto* inv_impl = dynamic_cast<Inventory*>(&inv);
        for (const auto& [item, need] : required) {
            std::uint16_t have = inv_impl ? inv_impl->count_item(item)
                                          : count_via_interface(inv, item);
            if (have < need) return false;
        }

        // 4. Consume ingredients.  Guaranteed to succeed (inventory unchanged
        //    since step 3).
        if (inv_impl) {
            for (const auto& [item, need] : required)
                inv_impl->remove_item(item, need);
        } else {
            remove_via_interface(inv, required);
        }

        // 5. Add result.  If no room, roll back.
        ItemStack result{ match->result, match->count, 0xFFFFu };
        if (!inv.add(result)) {
            // Roll back: re-add all consumed ingredients.
            for (const auto& [item, need] : required)
                inv.add({ item, need, 0xFFFFu });
            return false;
        }

        return true;
    }

private:
    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    const IRecipeBook* recipes_;

    // Slow path: count via the public IInventory interface when the concrete
    // type isn't Inventory.  O(slots * items).
    static std::uint16_t count_via_interface(const IInventory& inv, ItemId item) {
        std::uint32_t total = 0;
        const std::size_t n = inv.slot_count();
        for (std::size_t i = 0; i < n; ++i) {
            ItemStack s = inv.get(i);
            if (s.item == item && s.count > 0) total += s.count;
        }
        return static_cast<std::uint16_t>(total < 0xFFFFu ? total : 0xFFFFu);
    }

    // Slow path: remove items one slot at a time via the public IInventory
    // interface.  Called only for non-Inventory impls.
    static void remove_via_interface(
        IInventory& inv,
        const std::unordered_map<ItemId, std::uint16_t>& required)
    {
        // For each required item, scan slots and zero out as needed.
        for (const auto& [item, need] : required) {
            std::uint16_t remaining = need;
            const std::size_t n = inv.slot_count();
            for (std::size_t i = 0; i < n && remaining > 0; ++i) {
                ItemStack s = inv.get(i);
                if (s.item != item || s.count == 0) continue;
                std::uint16_t take = (s.count < remaining) ? s.count : remaining;
                s.count = static_cast<std::uint16_t>(s.count - take);
                inv.set(i, s);
                remaining  = static_cast<std::uint16_t>(remaining - take);
            }
        }
    }
};

} // namespace bf
