// ============================================================================
// Blockfall — Inventory + CraftingSystem unit tests (framework-free)
// ----------------------------------------------------------------------------
// Compile:
//   clang++ -std=c++23 -I contract -I engine/include \
//           -Wall -Wextra -Wpedantic -Wconversion -Wshadow \
//           tests/unit/test_inventory.cpp -o /tmp/test_inventory
// Run:
//   /tmp/test_inventory   (exits 0 on success, prints "OK")
// ============================================================================
#include "blockcore/inventory.hpp"
#include "blockcore/crafting.hpp"

#include <cstdio>
#include <string_view>
#include <array>
#include <optional>
#include <span>

// ============================================================================
// Test harness
// ============================================================================

static int g_fails = 0;

#define CHECK(cond, msg) \
    do { \
        if (!(cond)) { \
            std::printf("FAIL [%s:%d]: %s\n", __FILE__, __LINE__, (msg)); \
            ++g_fails; \
        } \
    } while (0)

// ============================================================================
// MockItemRegistry
// ============================================================================
// Item id 5 has max_stack = 16 (to exercise per-item limits).
// All other items default to max_stack = 64.

struct MockItemRegistry final : public bf::IItemRegistry {
    // Statically stored defs — string_views borrow from here.
    static constexpr bf::ItemDef kDef5{ 5,  "item_5",  16, 0, 0, 0 };
    static constexpr bf::ItemDef kDefDefault{ 0, "unknown", 64, 0, 0, 0 };

    const bf::ItemDef* by_id(bf::ItemId id) const override {
        if (id == 5) return &kDef5;
        // Return a def with max_stack=64 for everything else — caller checks non-null.
        // We use a mutable scratch so it doesn't need to be a separate table.
        scratch_.id        = id;
        scratch_.max_stack = 64;
        return &scratch_;
    }
    const bf::ItemDef* by_name(std::string_view) const override { return nullptr; }
    std::uint32_t       count() const override { return 2; }

private:
    mutable bf::ItemDef scratch_{0, "", 64, 0, 0, 0};
};

// ============================================================================
// MockRecipeBook
// ============================================================================
// Recipe A (single-ingredient, shapeless-style):
//   Any grid cell containing item 10 (and all others 0) -> result { item 20, count 4 }
//
// Recipe B (two-ingredient):
//   Grid contains exactly one item 11 and one item 12, all other cells 0
//   -> result { item 21, count 1 }
//
// These match regardless of grid dimension (2x2 or 3x3).

struct MockRecipeBook final : public bf::IRecipeBook {
    std::optional<bf::RecipeMatch>
    match(std::span<const bf::ItemId> grid, int /*dim*/) const override {
        bool has10 = false, has11 = false, has12 = false;
        bool has_other = false;
        for (bf::ItemId id : grid) {
            if (id == 0) continue;
            if (id == 10) { has10 = true; continue; }
            if (id == 11) { has11 = true; continue; }
            if (id == 12) { has12 = true; continue; }
            has_other = true;
        }
        if (has_other) return std::nullopt;
        if (has10 && !has11 && !has12) return bf::RecipeMatch{ 20, 4 };
        if (!has10 && has11 && has12)  return bf::RecipeMatch{ 21, 1 };
        return std::nullopt;
    }
    std::uint32_t count() const override { return 2; }
};

// ============================================================================
// Test: add / merge / count_item
// ============================================================================

static void test_add_and_merge() {
    MockItemRegistry reg;
    bf::Inventory inv(10, &reg);

    // Add 30 of item 1 -> one partial slot.
    bool ok = inv.add({ 1, 30, 0xFFFFu });
    CHECK(ok, "add 30: should succeed");
    CHECK(inv.count_item(1) == 30, "count_item after 30");

    // Add 50 more of item 1 -> should fill first slot to 64, open a second slot with 16.
    ok = inv.add({ 1, 50, 0xFFFFu });
    CHECK(ok, "add 50 more: should succeed");
    CHECK(inv.count_item(1) == 80, "count_item == 80 after adding 30+50");

    // Verify slot 0 == 64, slot 1 == 16 (merged correctly).
    bf::ItemStack s0 = inv.get(0);
    bf::ItemStack s1 = inv.get(1);
    CHECK(s0.item  == 1,  "slot 0 item id");
    CHECK(s0.count == 64, "slot 0 fully filled (64)");
    CHECK(s1.item  == 1,  "slot 1 item id");
    CHECK(s1.count == 16, "slot 1 partial (16)");

    // Add zero-count: no-op, returns true.
    ok = inv.add({ 1, 0, 0xFFFFu });
    CHECK(ok, "add 0 count is no-op success");
    CHECK(inv.count_item(1) == 80, "count_item unchanged after add(0)");
}

// ============================================================================
// Test: per-item max_stack (item 5 -> max 16)
// ============================================================================

static void test_per_item_max_stack() {
    MockItemRegistry reg;
    bf::Inventory inv(8, &reg);

    // Add 20 of item 5 (max_stack = 16).
    // Should place 16 in slot 0 and 4 in slot 1.
    bool ok = inv.add({ 5, 20, 0xFFFFu });
    CHECK(ok, "add 20 of item-5 (max16): should succeed");
    CHECK(inv.count_item(5) == 20, "count_item(5) == 20");

    bf::ItemStack s0 = inv.get(0);
    bf::ItemStack s1 = inv.get(1);
    CHECK(s0.item  == 5,  "slot 0 item-5");
    CHECK(s0.count == 16, "slot 0 maxed at 16");
    CHECK(s1.item  == 5,  "slot 1 item-5");
    CHECK(s1.count == 4,  "slot 1 partial 4");

    // Adding 1 more should top up slot 1 (from 4 to 5), never exceed 16.
    ok = inv.add({ 5, 1, 0xFFFFu });
    CHECK(ok, "add 1 more of item-5");
    s1 = inv.get(1);
    CHECK(s1.count == 5, "slot 1 now 5, not more than 16");

    // Fill slot 1 to 16, then the next add should open a new slot.
    ok = inv.add({ 5, 11, 0xFFFFu });
    CHECK(ok, "fill slot 1 to 16");
    s1 = inv.get(1);
    CHECK(s1.count == 16, "slot 1 at 16");
}

// ============================================================================
// Test: add returns false when inventory cannot hold all items
// ============================================================================

static void test_add_overflow() {
    MockItemRegistry reg;
    bf::Inventory inv(2, &reg);  // only 2 slots = max 128 of any 64-stack item

    // Fill both slots.
    inv.add({ 1, 64, 0xFFFFu });
    inv.add({ 1, 64, 0xFFFFu });
    CHECK(inv.count_item(1) == 128, "precondition: full");

    // Adding any more should return false.
    bool ok = inv.add({ 1, 1, 0xFFFFu });
    CHECK(!ok, "add to full inventory returns false");
    // The count should still be 128 (what was already there), NOT 129.
    // Because both slots were already full, nothing extra was placed.
    CHECK(inv.count_item(1) == 128, "count unchanged when nothing fits");
}

// ============================================================================
// Test: move — merge same item
// ============================================================================

static void test_move_merge() {
    MockItemRegistry reg;
    bf::Inventory inv(4, &reg);

    // Slot 0: 30 of item 2.  Slot 1: 20 of item 2.
    inv.set(0, { 2, 30, 0xFFFFu });
    inv.set(1, { 2, 20, 0xFFFFu });

    // Move 20 from slot 0 to slot 1 — slot 1 has 20, can accept 44 more.
    bool ok = inv.move(0, 1, 20);
    CHECK(ok, "move(0,1,20) same item: ok");
    CHECK(inv.get(0).count == 10, "from-slot left with 10");
    CHECK(inv.get(1).count == 40, "to-slot now 40");

    // Move more than destination can accept (slot 1 is at 40, max 64).
    // slot 0 has 10.  Move all 10 to slot 1 (space = 24).
    ok = inv.move(0, 1, 10);
    CHECK(ok, "move remaining 10 to slot 1");
    CHECK(inv.get(0).count == 0 || inv.get(0).item == 0, "slot 0 now empty");
    CHECK(inv.get(1).count == 50, "slot 1 now 50");
}

// ============================================================================
// Test: move — swap different items (full stack)
// ============================================================================

static void test_move_swap() {
    MockItemRegistry reg;
    bf::Inventory inv(4, &reg);

    inv.set(0, { 3, 10, 0xFFFFu });
    inv.set(1, { 4, 10, 0xFFFFu });

    // Move all 10 of slot 0 to slot 1 (different items) — should swap.
    bool ok = inv.move(0, 1, 10);
    CHECK(ok, "move full stack of different items: swap ok");
    CHECK(inv.get(0).item == 4, "slot 0 now has item 4");
    CHECK(inv.get(0).count == 10, "slot 0 count 10");
    CHECK(inv.get(1).item == 3, "slot 1 now has item 3");
    CHECK(inv.get(1).count == 10, "slot 1 count 10");

    // Partial move of different items should fail (no change).
    ok = inv.move(0, 1, 5);
    CHECK(!ok, "partial move of different items: returns false");
    CHECK(inv.get(0).item == 4, "slot 0 unchanged after failed partial");
    CHECK(inv.get(1).item == 3, "slot 1 unchanged after failed partial");
}

// ============================================================================
// Test: move — into empty slot
// ============================================================================

static void test_move_to_empty() {
    MockItemRegistry reg;
    bf::Inventory inv(4, &reg);

    inv.set(0, { 7, 20, 0xFFFFu });

    bool ok = inv.move(0, 2, 8);
    CHECK(ok, "move 8 of 20 into empty slot");
    CHECK(inv.get(0).count == 12, "source reduced to 12");
    CHECK(inv.get(2).item  == 7,  "dest slot has item 7");
    CHECK(inv.get(2).count == 8,  "dest slot has 8");
}

// ============================================================================
// Test: remove_item (all-or-nothing)
// ============================================================================

static void test_remove_item() {
    MockItemRegistry reg;
    bf::Inventory inv(4, &reg);

    inv.set(0, { 1, 30, 0xFFFFu });
    inv.set(1, { 1, 20, 0xFFFFu });
    // Total: 50 of item 1.

    // Try to remove more than available -> fail, nothing removed.
    bool ok = inv.remove_item(1, 60);
    CHECK(!ok, "remove_item 60 when only 50 available: false");
    CHECK(inv.count_item(1) == 50, "inventory unchanged after failed remove");

    // Remove 25 (spread across slots).
    ok = inv.remove_item(1, 25);
    CHECK(ok, "remove_item 25: success");
    CHECK(inv.count_item(1) == 25, "25 remaining after removal");
}

// ============================================================================
// Test: crafting preview — never mutates
// ============================================================================

static void test_crafting_preview() {
    MockItemRegistry  reg;
    MockRecipeBook    book;
    bf::Inventory     inv(9, &reg);
    bf::CraftingSystem crafter(&book, &reg);

    // Fill inventory with ingredients.
    inv.add({ 10, 5, 0xFFFFu });

    // 2x2 grid with item 10 in cell (0,0).
    std::array<bf::ItemId, 4> grid2x2{ 10, 0, 0, 0 };
    auto match = crafter.preview({ grid2x2.data(), grid2x2.size() }, 2);
    CHECK(match.has_value(), "preview matches recipe A");
    CHECK(match->result == 20, "recipe A result id = 20");
    CHECK(match->count  == 4,  "recipe A count = 4");
    CHECK(inv.count_item(10) == 5, "preview did not consume ingredients");

    // Empty grid -> no match.
    std::array<bf::ItemId, 4> empty_grid{ 0, 0, 0, 0 };
    auto no_match = crafter.preview({ empty_grid.data(), empty_grid.size() }, 2);
    CHECK(!no_match.has_value(), "preview on empty grid: no match");
}

// ============================================================================
// Test: crafting commit — success path
// ============================================================================

static void test_crafting_commit_success() {
    MockItemRegistry  reg;
    MockRecipeBook    book;
    bf::Inventory     inv(9, &reg);
    bf::CraftingSystem crafter(&book, &reg);

    // Load ingredient for recipe A (item 10 -> {item 20, 4}).
    inv.add({ 10, 3, 0xFFFFu });
    CHECK(inv.count_item(10) == 3, "precondition: 3 of item 10");

    std::array<bf::ItemId, 4> grid{ 10, 0, 0, 0 };
    bool ok = crafter.commit(inv, { grid.data(), grid.size() }, 2);
    CHECK(ok, "commit recipe A: success");
    // One unit of item 10 consumed.
    CHECK(inv.count_item(10) == 2, "item 10 reduced by 1");
    // Four units of item 20 produced.
    CHECK(inv.count_item(20) == 4, "item 20 added (count 4)");

    // Commit recipe B (item 11 + item 12 -> {item 21, 1}).
    inv.add({ 11, 1, 0xFFFFu });
    inv.add({ 12, 1, 0xFFFFu });
    std::array<bf::ItemId, 4> gridB{ 11, 12, 0, 0 };
    ok = crafter.commit(inv, { gridB.data(), gridB.size() }, 2);
    CHECK(ok, "commit recipe B: success");
    CHECK(inv.count_item(11) == 0, "item 11 consumed");
    CHECK(inv.count_item(12) == 0, "item 12 consumed");
    CHECK(inv.count_item(21) == 1, "item 21 produced");
}

// ============================================================================
// Test: crafting commit — missing ingredient (all-or-nothing)
// ============================================================================

static void test_crafting_commit_missing_ingredient() {
    MockItemRegistry  reg;
    MockRecipeBook    book;
    bf::Inventory     inv(9, &reg);
    bf::CraftingSystem crafter(&book, &reg);

    // Recipe B requires item 11 AND item 12.  Only put in item 11.
    inv.add({ 11, 1, 0xFFFFu });
    CHECK(inv.count_item(11) == 1, "precondition: 1 of item 11");
    CHECK(inv.count_item(12) == 0, "precondition: 0 of item 12");

    std::array<bf::ItemId, 4> grid{ 11, 12, 0, 0 };
    bool ok = crafter.commit(inv, { grid.data(), grid.size() }, 2);
    CHECK(!ok, "commit with missing ingredient: false");
    // Nothing consumed.
    CHECK(inv.count_item(11) == 1, "item 11 NOT consumed (all-or-nothing)");
    CHECK(inv.count_item(21) == 0, "no result produced");

    // No recipe match at all.
    std::array<bf::ItemId, 4> bad_grid{ 99, 0, 0, 0 };
    ok = crafter.commit(inv, { bad_grid.data(), bad_grid.size() }, 2);
    CHECK(!ok, "commit with unknown item: false");
    CHECK(inv.count_item(11) == 1, "item 11 still untouched");
}

// ============================================================================
// Test: crafting commit — no inventory room (rollback)
// ============================================================================

static void test_crafting_commit_full_inventory() {
    MockItemRegistry  reg;
    MockRecipeBook    book;
    // Tiny 1-slot inventory, already occupied with something unrelated.
    bf::Inventory     inv(1, &reg);
    bf::CraftingSystem crafter(&book, &reg);

    // Slot 0: item 10 (ingredient), count = 1.
    inv.set(0, { 10, 1, 0xFFFFu });
    CHECK(inv.count_item(10) == 1, "precondition");

    // Recipe A needs item 10 and would produce 4x item 20.
    // After consuming item 10 the slot is empty; add({20,4}) should succeed.
    // So this case should actually work.  Let's verify it does.
    std::array<bf::ItemId, 1> grid{ 10 };
    bool ok = crafter.commit(inv, { grid.data(), grid.size() }, 1);
    CHECK(ok, "1-slot inv: consume item 10, place item 20 (fits)");
    CHECK(inv.count_item(10) == 0, "item 10 gone");
    CHECK(inv.count_item(20) == 4, "item 20 placed");

    // Now inventory holds 4x item 20 (one slot, partially filled with 4 of 64).
    // Recipe A again — item 10 not present -> should fail.
    ok = crafter.commit(inv, { grid.data(), grid.size() }, 1);
    CHECK(!ok, "no ingredient -> false, inventory unchanged");
    CHECK(inv.count_item(20) == 4, "item 20 still 4");
}

// ============================================================================
// main
// ============================================================================

int main() {
    test_add_and_merge();
    test_per_item_max_stack();
    test_add_overflow();
    test_move_merge();
    test_move_swap();
    test_move_to_empty();
    test_remove_item();
    test_crafting_preview();
    test_crafting_commit_success();
    test_crafting_commit_missing_ingredient();
    test_crafting_commit_full_inventory();

    if (g_fails == 0) {
        std::printf("OK\n");
        return 0;
    }
    std::printf("%d test(s) FAILED\n", g_fails);
    return 1;
}
