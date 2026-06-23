// M1 integration — the mine/place loop, headless. Uses a malloc-backed GPU
// allocator (no Metal) so the full path runs in CI: generate -> mesh -> raycast
// -> mine a block (it disappears) -> place a block (it appears) -> remesh.
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"
#include "blockcore/content.hpp"

#include <cstdio>
#include <cstdlib>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

// Malloc-backed allocator: handle == pointer bits (so free is trivial).
static bf_gpu_buffer alloc_fn(void*, uint32_t bytes) {
    void* p = std::malloc(bytes ? bytes : 16);
    bf_gpu_buffer b{};
    b.handle = reinterpret_cast<uint64_t>(p);
    b.contents = p;
    b.bytes = bytes;
    return b;
}
static void free_fn(void*, uint64_t handle) { std::free(reinterpret_cast<void*>(handle)); }

static uint32_t total_indices(bf_render_frame& f) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < f.draw_count; ++i) n += f.draws[i].index_count;
    return n;
}

int main() {
    bf::GreedyMesher mesher;
    bf::World world(mesher);

    bf::ContentRegistry content;
    content.load("/Users/roy/gh/blockfall/content");
    world.set_content(&content);                 // hotbar slot 0 = glow_block item

    bf_gpu_allocator alloc{};
    alloc.user = nullptr; alloc.alloc = alloc_fn; alloc.free_ = free_fn;
    world.set_allocator(alloc);

    world.generate_test_world();
    // Aim straight down at column x=8,z=8 (ground top is grass at world y=7).
    world.debug_set_camera(8.5f, 20.0f, 8.5f, 0.0f, -1.5707f);

    bf_frame_input zero{};
    world.update(zero, 0.016);
    CHECK(world.debug_has_target(), "raycast acquired a target looking down");
    CHECK(world.debug_block_at(8, 7, 8) == bf::GRASS, "ground top is grass");

    std::vector<bf_draw_item> draws;
    std::vector<bf_draw_item> shadow_draws;
    std::vector<bf_prop_instance> prop_instances;
    bf_render_frame f{};
    world.build_frame(f, draws, shadow_draws, prop_instances, 0.0);
    uint32_t idx0 = total_indices(f);
    CHECK(f.draw_count > 0 && idx0 > 0, "world meshed into draw list");

    // --- MINE: hold, advance time, block breaks ---
    bf_action mineStart{}; mineStart.kind = BF_ACT_MINE_START;
    world.action(mineStart);
    for (int i = 0; i < 60 && world.debug_block_at(8, 7, 8) != bf::AIR; ++i)
        world.update(zero, 0.05);                  // hold-to-mine until it breaks
    CHECK(world.debug_block_at(8, 7, 8) == bf::AIR, "mined block is now air");
    bf_action mineStop{}; mineStop.kind = BF_ACT_MINE_STOP;
    world.action(mineStop);

    world.build_frame(f, draws, shadow_draws, prop_instances, 0.0);
    uint32_t idx1 = total_indices(f);
    CHECK(idx1 != idx0, "mesh changed after mining (remesh happened)");

    // --- PLACE: select GLOW (hotbar slot 4), place onto the new top face ---
    world.update(zero, 0.016);                    // retarget (now dirt at y=6)
    CHECK(world.debug_block_at(8, 6, 8) == bf::DIRT, "exposed dirt below");
    world.debug_set_selected(0);                  // GLOW (hotbar slot 0)
    bf_action place{}; place.kind = BF_ACT_PLACE;
    world.action(place);
    CHECK(world.debug_block_at(8, 7, 8) == bf::GLOW, "placed block appears");

    world.build_frame(f, draws, shadow_draws, prop_instances, 0.0);
    CHECK(f.draw_count > 0 && total_indices(f) > 0, "world still meshes after place");

    // #36 regression: spawn-in must fill from the player OUTWARD. stream_tick pops
    // gen_queue_.back() first, so the back must be the NEAREST pending chunk. With
    // the old ascending sort the back was the FARTHEST, so the surface backfilled
    // from the horizon inward. Fails on that bug; passes with farthest-first sort.
    CHECK(world.debug_stream_back_is_nearest(),
          "stream gen order is nearest-first (#36: world fills outward from player)");

    if (fails == 0) std::printf("OK: M1 mine/place loop (mesh idx %u -> %u)\n", idx0, idx1);
    return fails == 0 ? 0 : 1;
}
