// #69 — doors open and close. A closed door (33) blocks you like a wall; right-clicking
// (BF_ACT_INTERACT) swings it to the open state (50) which is passable; right-clicking
// again closes it. Verifies the toggle through the action pipeline and the collision flip.
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"
#include "blockcore/worldgen.hpp"
#include "blockcore/content.hpp"
#include "blockcore/content_extra.hpp"

#include <cstdio>
#include <cstdlib>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static bf_gpu_buffer af(void*, uint32_t b){ void* p=std::malloc(b?b:16); bf_gpu_buffer r{}; r.handle=reinterpret_cast<uint64_t>(p); r.contents=p; r.bytes=b; return r; }
static void ff(void*, uint64_t h){ std::free(reinterpret_cast<void*>(h)); }

using namespace bf;

int main() {
    ContentRegistry c; CHECK(c.load("/Users/roy/gh/blockfall/content"), "content load");
    CHECK(c.block_by_name("oak_door") != nullptr, "content has oak_door (closed)");
    CHECK(c.block_by_name("oak_door_open") != nullptr, "content has oak_door_open");

    GreedyMesher m; TerrainGen g; World w(m, &g);
    w.debug_set_sync_streaming(true);
    bf_gpu_allocator a{}; a.alloc=af; a.free_=ff; w.set_allocator(a);
    w.set_content(&c);
    w.set_mode(BF_MODE_CREATIVE);
    w.init_world(11);

    bf_frame_input zero{};
    const int dx = 100, dy = 145, dz = 100;   // high in clear air, above terrain
    w.debug_set_camera(float(dx) + 0.5f, float(dy) + 5.0f, float(dz) + 0.5f, 0.0f, -1.5707f);
    for (int i = 0; i < 25; ++i) w.update(zero, 0.05);

    // Place a closed door and look straight down at it.
    w.debug_edit(dx, dy, dz, BlockId(33));
    w.debug_set_camera(float(dx) + 0.5f, float(dy) + 5.0f, float(dz) + 0.5f, 0.0f, -1.5707f);
    w.update(zero, 0.016);
    CHECK(w.debug_block_at(dx, dy, dz) == 33, "closed door in place");
    CHECK(w.debug_collide_solid(dx, dy, dz), "a closed door blocks movement");
    CHECK(w.debug_has_target(), "aimed at the door");

    // Right-click: it opens.
    bf_action use{}; use.kind = BF_ACT_INTERACT;
    w.action(use);
    w.update(zero, 0.016);
    CHECK(w.debug_block_at(dx, dy, dz) == 50, "interacting opens the door");
    CHECK(!w.debug_collide_solid(dx, dy, dz), "an open door is passable");

    // Right-click again: it closes.
    w.action(use);
    w.update(zero, 0.016);
    CHECK(w.debug_block_at(dx, dy, dz) == 33, "interacting again closes the door");
    CHECK(w.debug_collide_solid(dx, dy, dz), "the re-closed door blocks movement again");

    if (fails == 0) std::printf("OK: doors open/close (toggle + collision)\n");
    return fails == 0 ? 0 : 1;
}
