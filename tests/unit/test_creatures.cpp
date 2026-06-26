// Creature collision + friendly-follow spacing. Two creatures must never occupy the
// same space (a separation push keeps them apart), and a befriended pet follows the
// player but holds a comfortable distance instead of crowding on top of them.
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"
#include "blockcore/worldgen.hpp"
#include "blockcore/content.hpp"
#include "blockcore/content_extra.hpp"

#include <cstdio>
#include <cstdlib>
#include <cmath>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static bf_gpu_buffer af(void*, uint32_t b){ void* p=std::malloc(b?b:16); bf_gpu_buffer r{}; r.handle=reinterpret_cast<uint64_t>(p); r.contents=p; r.bytes=b; return r; }
static void ff(void*, uint64_t h){ std::free(reinterpret_cast<void*>(h)); }

using namespace bf;

int main() {
    ContentRegistry c; CHECK(c.load("/Users/roy/gh/blockfall/content"), "content load");
    ContentExtra x;    CHECK(x.load("/Users/roy/gh/blockfall/content"), "extra load");

    GreedyMesher m; TerrainGen g; World w(m, &g);
    w.debug_set_sync_streaming(true);
    bf_gpu_allocator a{}; a.alloc=af; a.free_=ff; w.set_allocator(a);
    w.set_content(&c); w.set_extra(&x);
    w.set_mode(BF_MODE_CREATIVE);
    w.init_world(11);

    bf_frame_input zero{};
    // Park the player high in clear air so the test creatures move through open space.
    w.debug_set_camera(100.5f, 145.0f, 100.5f, 0.0f, 0.0f);
    for (int i = 0; i < 10; ++i) w.update(zero, 0.05);

    // --- creatures cannot occupy the same space -----------------------------
    // debug_spawn_named drops each one at the same offset from the player, so the two
    // start stacked; the separation pass must push them apart.
    int base = w.debug_creature_count();
    w.debug_spawn_named("river_fox");
    w.debug_spawn_named("river_fox");
    CHECK(w.debug_creature_count() >= base + 2, "two creatures spawned");
    for (int i = 0; i < 12; ++i) w.update(zero, 0.05);
    float ax, ay, az, bx, by, bz;
    w.debug_creature_pos(base,     ax, ay, az);
    w.debug_creature_pos(base + 1, bx, by, bz);
    float dxz = std::sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az));
    CHECK(dxz > 0.7f, "two creatures separate instead of stacking");

    // --- a befriended pet follows but does not stand on the player ----------
    w.debug_set_friendly(base + 1);
    for (int i = 0; i < 30; ++i) w.update(zero, 0.05);
    float fx, fy, fz; w.debug_creature_pos(base + 1, fx, fy, fz);
    float pd = std::sqrt((fx - 100.5f) * (fx - 100.5f) + (fz - 100.5f) * (fz - 100.5f));
    CHECK(pd > 1.0f, "befriended pet does not crowd onto the player");
    CHECK(pd < 5.0f, "befriended pet follows toward the player");

    // --- living villages: woodcutter donations build a palisade ring ------------
    // The wall builder is stateless (the placed logs ARE the progress), so driving it
    // twice must extend the ring, and it must never re-fill the same cells.
    {
        const int vcx = 100, vcz = 100;          // near where the player streamed terrain
        auto ringLogs = [&]() {
            int n = 0;
            for (int dx = -8; dx <= 8; ++dx)
                for (int dz = -8; dz <= 8; ++dz) {
                    int adx = dx < 0 ? -dx : dx, adz = dz < 0 ? -dz : dz;
                    if ((adx > adz ? adx : adz) != 8) continue;   // ring perimeter only
                    for (int wy = 120; wy >= -8; --wy)
                        if (w.debug_block_at(vcx + dx, wy, vcz + dz) == 21) { ++n; break; }
                }
            return n;
        };
        int built1 = w.debug_build_palisade(vcx, vcz, 6);
        CHECK(built1 > 0, "village: first donation builds wall cells");
        int after1 = ringLogs();
        CHECK(after1 >= built1, "village: built cells are present in the ring");
        int built2 = w.debug_build_palisade(vcx, vcz, 6);
        int after2 = ringLogs();
        CHECK(built2 > 0 && after2 > after1, "village: a second donation extends the wall");
    }

    if (fails == 0) std::printf("OK: creature collision + friendly follow spacing\n");
    return fails == 0 ? 0 : 1;
}
