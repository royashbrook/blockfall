// M3 integration — data-driven gameplay: survival mining drops items into the
// inventory, and crafting consumes inputs to produce an output, all through the
// loaded content registries + Inventory + CraftingSystem.
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"
#include "blockcore/worldgen.hpp"
#include "blockcore/content.hpp"

#include <cstdio>
#include <cstdlib>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static bf_gpu_buffer alloc_fn(void*, uint32_t b) {
    void* p = std::malloc(b ? b : 16); bf_gpu_buffer r{};
    r.handle = reinterpret_cast<uint64_t>(p); r.contents = p; r.bytes = b; return r;
}
static void free_fn(void*, uint64_t h) { std::free(reinterpret_cast<void*>(h)); }

int main() {
    bf::ContentRegistry content;
    if (!content.load("/Users/roy/gh/blockfall/content")) { std::printf("FAIL: content load\n"); return 1; }

    bf::GreedyMesher mesher; bf::TerrainGen gen; bf::World world(mesher, &gen);
    bf_gpu_allocator alloc{}; alloc.alloc = alloc_fn; alloc.free_ = free_fn;
    world.set_allocator(alloc);
    world.set_mode(BF_MODE_SURVIVAL);
    world.set_content(&content);
    world.init_world(99);

    bf_frame_input zero{};

    // --- survival mining drops an item ---
    world.debug_clear_inventory();
    // A floating stone block high in clear air, with the camera looking straight down at it.
    world.debug_set_camera(100.5f, 100.0f, 100.5f, 0.0f, -1.5707f);
    world.debug_edit(100, 95, 100, bf::STONE);
    world.update(zero, 0.016);
    CHECK(world.debug_has_target(), "aimed at the stone block");

    bf::ItemId cobble = world.debug_item_id("cobblestone");
    CHECK(cobble != 0, "content has a cobblestone item");
    bf_action mineStart{}; mineStart.kind = BF_ACT_MINE_START; world.action(mineStart);
    for (int i = 0; i < 200 && world.debug_block_at(100, 95, 100) != bf::AIR; ++i)
        world.update(zero, 0.05);
    CHECK(world.debug_block_at(100, 95, 100) == bf::AIR, "stone mined away");
    CHECK(world.debug_item_count(cobble) >= 1, "survival mining dropped cobblestone into inventory");

    // --- crafting consumes inputs, produces output ---
    bf::ItemId log    = world.debug_item_id("oak_log");
    bf::ItemId planks = world.debug_item_id("oak_planks");
    CHECK(log != 0 && planks != 0, "content has oak_log and oak_planks items");
    world.debug_clear_inventory();
    world.debug_give(log, 4);                 // only logs -> the only craftable recipe is log->planks
    int planksBefore = world.debug_item_count(planks);
    bf_action craft{}; craft.kind = BF_ACT_CRAFT; world.action(craft);
    CHECK(world.debug_item_count(planks) > planksBefore, "crafting produced planks");
    CHECK(world.debug_item_count(log) < 4, "crafting consumed a log");

    if (fails == 0) std::printf("OK: M3 gameplay (survival drops + crafting)\n");
    return fails == 0 ? 0 : 1;
}
