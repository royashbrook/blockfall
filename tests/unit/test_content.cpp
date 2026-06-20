// ============================================================================
// Blockfall — ContentRegistry unit tests (framework-free)
// tests/unit/test_content.cpp
// C++23.  Build:
//   clang++ -std=c++23 -I contract -I engine/include -Wall -Wextra -Wpedantic
//           -Wconversion -Wshadow tests/unit/test_content.cpp engine/src/content.cpp
//           -o /tmp/test_content
// ============================================================================
#include "blockcore/content.hpp"
#include "blockcore/json.hpp"

#include <cstdio>
#include <string>
#include <vector>

// ----------------------------------------------------------------------------
// Minimal test harness (mirrors test_chunk.cpp style)
// ----------------------------------------------------------------------------
static int fails = 0;
#define CHECK(cond, msg) \
    do { if (!(cond)) { std::printf("FAIL: %s\n", (msg)); ++fails; } } while(0)

// ============================================================================
// JSON parser unit tests
// ============================================================================
static void test_json_parser() {
    using namespace bf::json;

    // Null / bool / number
    {
        auto r = parse("null");
        CHECK(r.ok && r.value.is_null(), "parse null");
    }
    {
        auto r = parse("true");
        CHECK(r.ok && r.value.is_bool() && r.value.as_bool(), "parse true");
    }
    {
        auto r = parse("false");
        CHECK(r.ok && r.value.is_bool() && !r.value.as_bool(), "parse false");
    }
    {
        auto r = parse("42");
        CHECK(r.ok && r.value.is_int() && r.value.as_int() == 42, "parse int");
    }
    {
        auto r = parse("-7");
        CHECK(r.ok && r.value.is_int() && r.value.as_int() == -7, "parse negative int");
    }
    {
        auto r = parse("3.14");
        CHECK(r.ok && r.value.is_double(), "parse double");
    }

    // String with escapes
    {
        auto r = parse("\"hello\\nworld\"");
        CHECK(r.ok && r.value.is_string() && r.value.as_string() == "hello\nworld",
              "parse string with \\n escape");
    }
    {
        auto r = parse("\"back\\\\slash\"");
        CHECK(r.ok && r.value.is_string() && r.value.as_string() == "back\\slash",
              "parse string with \\\\ escape");
    }
    {
        auto r = parse("\"tab\\there\"");
        CHECK(r.ok && r.value.is_string() && r.value.as_string() == "tab\there",
              "parse string with \\t escape");
    }

    // Array
    {
        auto r = parse("[1, 2, 3]");
        CHECK(r.ok && r.value.is_array() && r.value.size() == 3, "parse array size");
        CHECK(r.value.at(0) && r.value.at(0)->as_int() == 1, "array[0]");
        CHECK(r.value.at(2) && r.value.at(2)->as_int() == 3, "array[2]");
        CHECK(r.value.at(99) == nullptr, "array oob returns nullptr");
    }

    // Empty array
    {
        auto r = parse("[]");
        CHECK(r.ok && r.value.is_array() && r.value.size() == 0, "empty array");
    }

    // Object
    {
        auto r = parse("{\"a\": 1, \"b\": \"hello\"}");
        CHECK(r.ok && r.value.is_object(), "parse object");
        CHECK(r.value.contains("a") && r.value.get("a")->as_int() == 1, "object key a");
        CHECK(r.value.contains("b") && r.value.get("b")->as_string() == "hello", "object key b");
        CHECK(!r.value.contains("z"), "object missing key");
        CHECK(r.value.get("z") == nullptr, "missing key returns nullptr");
    }

    // Nested
    {
        auto r = parse("{\"arr\": [null, true, {\"x\": 99}]}");
        CHECK(r.ok, "nested parse ok");
        const auto* arr = r.value.get("arr");
        CHECK(arr && arr->is_array() && arr->size() == 3, "nested array present");
        CHECK(arr->at(0) && arr->at(0)->is_null(), "nested null");
        CHECK(arr->at(1) && arr->at(1)->as_bool(), "nested bool");
        const auto* inner = arr->at(2);
        CHECK(inner && inner->is_object(), "nested object");
        CHECK(inner->get("x") && inner->get("x")->as_int() == 99, "nested object value");
    }

    // Malformed input — must not crash, must return ok=false.
    {
        auto r = parse("{bad json}}");
        CHECK(!r.ok, "malformed input fails gracefully");
    }
    {
        auto r = parse("");
        CHECK(!r.ok, "empty input fails gracefully");
    }
}

// ============================================================================
// ContentRegistry tests (use real content directory)
// ============================================================================
static const char* kContentDir = "/Users/roy/gh/blockfall/content";

static void test_load_counts() {
    bf::ContentRegistry reg;
    bool ok = reg.load(kContentDir);
    CHECK(ok, "load() returns true");
    CHECK(reg.block_count()  >= 30, "blocks loaded >= 30");
    CHECK(reg.item_count()   >= 40, "items loaded >= 40");
    CHECK(reg.recipe_count() >= 25, "recipes loaded >= 25");
    std::printf("  blocks=%u  items=%u  recipes=%u\n",
                reg.block_count(), reg.item_count(), reg.recipe_count());
}

static void test_block_by_name_and_roundtrip() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    const bf::BlockDef* stone = reg.block_by_name("stone");
    CHECK(stone != nullptr, "block_by_name(\"stone\") not null");
    if (!stone) return;

    CHECK(stone->name == "stone",           "stone name matches");
    CHECK(stone->id == 3,                   "stone id == 3");
    CHECK(stone->hardness == 20,            "stone hardness == 20");
    CHECK(stone->required_tier == 1,        "stone required_tier == 1");

    // Round-trip: block_by_id(stone->id) gives the same record.
    const bf::BlockDef* by_id = reg.block_by_id(stone->id);
    CHECK(by_id != nullptr,                 "block_by_id round-trip not null");
    CHECK(by_id->id == stone->id,           "block_by_id round-trip id matches");
    CHECK(by_id->name == stone->name,       "block_by_id round-trip name matches");

    // Non-existent.
    CHECK(reg.block_by_name("does_not_exist_block") == nullptr,
          "block_by_name missing returns null");
    CHECK(reg.block_by_id(9999) == nullptr, "block_by_id missing returns null");
}

static void test_block_drop_item_cross_ref() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    // stone (id=3) has explicit drop_item="cobblestone".
    const bf::BlockDef* stone = reg.block_by_name("stone");
    CHECK(stone != nullptr, "stone block present");
    if (!stone) return;

    CHECK(stone->drop_item != 0, "stone drop_item resolved (non-zero)");

    const bf::ItemDef* dropped = reg.item_by_id(stone->drop_item);
    CHECK(dropped != nullptr, "stone->drop_item resolves to valid ItemDef");
    if (dropped)
        CHECK(dropped->name == "cobblestone", "stone drops cobblestone item");
}

static void test_item_places_block_cross_ref() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    // "cobblestone" item (id=4) has places_block="cobblestone".
    const bf::ItemDef* cob_item = reg.item_by_name("cobblestone");
    CHECK(cob_item != nullptr, "cobblestone item present");
    if (!cob_item) return;

    CHECK(cob_item->places_block != 0, "cobblestone item places_block resolved");
    const bf::BlockDef* placed = reg.block_by_id(cob_item->places_block);
    CHECK(placed != nullptr, "cobblestone places_block -> valid BlockDef");
    if (placed)
        CHECK(placed->name == "cobblestone", "cobblestone item places cobblestone block");

    // "dirt" item (id=1) places "dirt" block.
    const bf::ItemDef* dirt_item = reg.item_by_name("dirt");
    CHECK(dirt_item != nullptr, "dirt item present");
    if (dirt_item) {
        CHECK(dirt_item->places_block != 0, "dirt item places_block resolved");
        const bf::BlockDef* dirt_block = reg.block_by_id(dirt_item->places_block);
        CHECK(dirt_block && dirt_block->name == "dirt", "dirt item places dirt block");
    }
}

static void test_item_by_name_and_roundtrip() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    const bf::ItemDef* stick = reg.item_by_name("stick");
    CHECK(stick != nullptr, "stick item present");
    if (!stick) return;
    CHECK(stick->name == "stick",           "stick name matches");
    CHECK(stick->id == 50,                  "stick id == 50");
    CHECK(stick->max_stack == 64,           "stick max_stack == 64");
    CHECK(stick->tool_kind == 0,            "stick is not a tool");

    const bf::ItemDef* pickaxe = reg.item_by_name("wood_pickaxe");
    CHECK(pickaxe != nullptr, "wood_pickaxe item present");
    if (pickaxe) {
        CHECK(pickaxe->tool_kind == 1,  "wood_pickaxe tool_kind == 1 (pickaxe)");
        CHECK(pickaxe->tool_tier == 1,  "wood_pickaxe tool_tier == 1 (wood)");
        CHECK(pickaxe->max_stack == 1,  "wood_pickaxe max_stack == 1");
    }

    // Round-trip via interface.
    const bf::ItemDef* by_id = reg.item_by_id(stick->id);
    CHECK(by_id && by_id->name == stick->name, "item by_id round-trip");
}

static void test_block_flags() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    // sand has gravity=true → bit0=1.
    const bf::BlockDef* sand = reg.block_by_name("sand");
    CHECK(sand != nullptr, "sand block present");
    if (sand) CHECK((sand->flags & 0x01u) != 0, "sand flags has gravity bit");

    // water has transparent=true → bit1=1.
    const bf::BlockDef* water = reg.block_by_name("water");
    CHECK(water != nullptr, "water block present");
    if (water) CHECK((water->flags & 0x02u) != 0, "water flags has transparent bit");

    // crafting_table has functional="crafting_table" (non-"none") → bit2=1.
    const bf::BlockDef* ct = reg.block_by_name("crafting_table");
    CHECK(ct != nullptr, "crafting_table block present");
    if (ct) CHECK((ct->flags & 0x04u) != 0, "crafting_table flags has functional bit");

    // dirt has no flags set.
    const bf::BlockDef* dirt = reg.block_by_name("dirt");
    CHECK(dirt != nullptr, "dirt block present");
    if (dirt) CHECK(dirt->flags == 0, "dirt flags == 0");
}

static void test_shaped_recipe_match() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    // Recipe "stone_brick_from_cobblestone" (basic.json):
    //   grid_size=2, pattern = [cobblestone, cobblestone, cobblestone, cobblestone]
    //   result = stone_brick item (id=16), count=4.
    //
    // We place the 2×2 pattern in the top-left of a 3×3 grid.
    //   [cob, cob, 0]
    //   [cob, cob, 0]
    //   [0,   0,   0]

    const bf::ItemDef* cob  = reg.item_by_name("cobblestone");
    const bf::ItemDef* sb   = reg.item_by_name("stone_brick");
    CHECK(cob != nullptr, "cobblestone item present for recipe test");
    CHECK(sb  != nullptr, "stone_brick item present for recipe test");
    if (!cob || !sb) return;

    bf::ItemId C = cob->id;
    std::vector<bf::ItemId> grid3x3 = {
        C, C, 0,
        C, C, 0,
        0, 0, 0
    };
    auto result = reg.recipe_match(grid3x3, 3);
    CHECK(result.has_value(), "stone_brick recipe matched in 3x3 grid");
    if (result) {
        CHECK(result->result == sb->id, "stone_brick recipe result item correct");
        CHECK(result->count  == 4,      "stone_brick recipe result count == 4");
    }

    // Same pattern in native 2×2 grid.
    std::vector<bf::ItemId> grid2x2 = { C, C, C, C };
    auto result2 = reg.recipe_match(grid2x2, 2);
    CHECK(result2.has_value(), "stone_brick recipe matched in 2x2 grid");
    if (result2) {
        CHECK(result2->result == sb->id, "stone_brick 2x2 result item correct");
    }

    // Shifted: place in bottom-right of 3×3 (shape-match allows any offset).
    std::vector<bf::ItemId> grid3x3_br = {
        0, 0, 0,
        0, C, C,
        0, C, C
    };
    auto result3 = reg.recipe_match(grid3x3_br, 3);
    CHECK(result3.has_value(), "stone_brick recipe matched at offset in 3x3 grid");
}

static void test_tool_recipe_match() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    // Recipe "wood_pickaxe_recipe" (tools.json):
    //   grid_size=3
    //   pattern:
    //     [oak_planks, oak_planks, oak_planks]
    //     [null,       stick,      null      ]
    //     [null,       stick,      null      ]
    //   result = wood_pickaxe (id=70), count=1.

    const bf::ItemDef* planks  = reg.item_by_name("oak_planks");
    const bf::ItemDef* stick   = reg.item_by_name("stick");
    const bf::ItemDef* pickaxe = reg.item_by_name("wood_pickaxe");
    CHECK(planks  != nullptr, "oak_planks item present");
    CHECK(stick   != nullptr, "stick item present");
    CHECK(pickaxe != nullptr, "wood_pickaxe item present");
    if (!planks || !stick || !pickaxe) return;

    bf::ItemId P = planks->id;
    bf::ItemId S = stick->id;
    std::vector<bf::ItemId> grid = {
        P, P, P,
        0, S, 0,
        0, S, 0
    };
    auto result = reg.recipe_match(grid, 3);
    CHECK(result.has_value(), "wood_pickaxe recipe matched");
    if (result) {
        CHECK(result->result == pickaxe->id, "wood_pickaxe recipe result correct");
        CHECK(result->count  == 1,           "wood_pickaxe count == 1");
    }
}

static void test_empty_grid_no_match() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    // All-zero 2×2 grid.
    std::vector<bf::ItemId> empty2x2(4, 0u);
    auto r2 = reg.recipe_match(empty2x2, 2);
    CHECK(!r2.has_value(), "empty 2x2 grid matches nothing");

    // All-zero 3×3 grid.
    std::vector<bf::ItemId> empty3x3(9, 0u);
    auto r3 = reg.recipe_match(empty3x3, 3);
    CHECK(!r3.has_value(), "empty 3x3 grid matches nothing");
}

static void test_recipe_count_via_interface() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);
    // Access via IRecipeBook interface.
    bf::IRecipeBook& rb = reg.recipe_book();
    CHECK(rb.count() >= 25, "IRecipeBook::count() >= 25");
    // Also via IBlockRegistry.
    bf::IBlockRegistry& br = reg.block_registry();
    CHECK(br.count() >= 30, "IBlockRegistry::count() >= 30");
    // Also via IItemRegistry.
    bf::IItemRegistry& ir = reg.item_registry();
    CHECK(ir.count() >= 40, "IItemRegistry::count() >= 40");
}

static void test_block_light_emit() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    // torch: light_emit=14.
    const bf::BlockDef* torch = reg.block_by_name("torch");
    CHECK(torch != nullptr, "torch block present");
    if (torch) CHECK(torch->light_emit == 14, "torch light_emit == 14");

    // beacon_block: light_emit=15.
    const bf::BlockDef* beacon = reg.block_by_name("beacon_block");
    CHECK(beacon != nullptr, "beacon_block present");
    if (beacon) CHECK(beacon->light_emit == 15, "beacon light_emit == 15");
}

// Test that IBlockRegistry interface methods work correctly.
static void test_interface_accessors() {
    bf::ContentRegistry reg;
    reg.load(kContentDir);

    bf::IBlockRegistry& br = reg.block_registry();
    const bf::BlockDef* stone_via_iface = br.by_name("stone");
    CHECK(stone_via_iface != nullptr, "IBlockRegistry::by_name works");
    if (stone_via_iface) {
        CHECK(stone_via_iface->id == 3, "IBlockRegistry::by_name returns correct id");
        const bf::BlockDef* stone2 = br.by_id(stone_via_iface->id);
        CHECK(stone2 && stone2->name == stone_via_iface->name,
              "IBlockRegistry::by_id round-trip");
    }

    bf::IItemRegistry& ir = reg.item_registry();
    const bf::ItemDef* coal = ir.by_name("coal");
    CHECK(coal != nullptr, "IItemRegistry::by_name(\"coal\") works");
    if (coal) {
        const bf::ItemDef* coal2 = ir.by_id(coal->id);
        CHECK(coal2 && coal2->name == coal->name, "IItemRegistry::by_id round-trip");
    }

    // IRecipeBook::match via interface.
    const bf::ItemDef* cob = ir.by_name("cobblestone");
    if (cob) {
        bf::ItemId C = cob->id;
        std::vector<bf::ItemId> g = { C, C, C, C };
        auto rm = reg.recipe_book().match(g, 2);
        CHECK(rm.has_value(), "IRecipeBook::match via interface works");
    }
}

// ============================================================================
// main
// ============================================================================
int main() {
    std::printf("--- JSON parser tests ---\n");
    test_json_parser();

    std::printf("--- ContentRegistry tests ---\n");
    test_load_counts();
    test_block_by_name_and_roundtrip();
    test_block_drop_item_cross_ref();
    test_item_places_block_cross_ref();
    test_item_by_name_and_roundtrip();
    test_block_flags();
    test_shaped_recipe_match();
    test_tool_recipe_match();
    test_empty_grid_no_match();
    test_recipe_count_via_interface();
    test_block_light_emit();
    test_interface_accessors();

    if (fails == 0)
        std::printf("OK: content tests\n");
    else
        std::printf("FAILED: %d checks failed\n", fails);

    return (fails == 0) ? 0 : 1;
}
