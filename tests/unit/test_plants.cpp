// #68 plant clustering — same-kind plants packed together carry a higher neighbour
// "density" in their prop seed (top nibble), which the renderer uses to grow the clump
// bigger; as you break pieces the survivors' neighbour counts drop on the next re-scan, so
// the clump shrinks. This verifies the density the engine emits equals the exact number of
// same-kind horizontal neighbours (full patch = 8, gapped = 7, edge = 5, lone = 0), which
// is what makes a packed patch read as one big clump and a thinned one read as smaller.
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"
#include "blockcore/content.hpp"

#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cmath>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static bf_gpu_buffer af(void*, uint32_t b){ void* p=std::malloc(b?b:16); bf_gpu_buffer r{}; r.handle=reinterpret_cast<uint64_t>(p); r.contents=p; r.bytes=b; return r; }
static void ff(void*, uint64_t h){ std::free(reinterpret_cast<void*>(h)); }

using namespace bf;

int main() {
    ContentRegistry c; CHECK(c.load("/Users/roy/gh/blockfall/content"), "content load");

    GreedyMesher m; TerrainGen g; World w(m, &g);
    w.debug_set_sync_streaming(true);
    bf_gpu_allocator a{}; a.alloc=af; a.free_=ff; w.set_allocator(a);
    w.set_content(&c);
    w.set_mode(BF_MODE_CREATIVE);
    w.init_world(11);

    bf_frame_input zero{};
    const int gx = 200, gy = 120, gz = 200;
    w.debug_set_camera(float(gx) + 0.5f, float(gy) + 4.0f, float(gz) + 0.5f, 0.0f, -1.5707f);
    for (int i = 0; i < 30; ++i) w.update(zero, 0.05);   // stream the chunks in

    // A stone floor (so the chunk has real geometry; an all-air+props chunk meshes empty
    // and its props are not gathered). On top: a FULL 3x3 grass patch (centre has 8
    // neighbours), a GAPPED 3x3 with one neighbour of its centre removed (7), and a lone
    // tuft (0). All placed before the gather so there is no re-mesh-timing in play.
    const int fx = gx,      fz = gz;        // full patch centre
    const int hx = gx,      hz = gz + 6;    // gapped patch centre
    const int lx = gx + 6,  lz = gz;        // lone tuft
    for (int dz = -2; dz <= 8; ++dz)
        for (int dx = -2; dx <= 8; ++dx)
            w.debug_edit(gx + dx, gy - 1, gz + dz, bf::STONE);   // shared floor under everything
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx) {
            w.debug_edit(fx + dx, gy, fz + dz, BlockId(38));     // full patch
            if (!(dx == 1 && dz == 0))                            // gapped: skip the +x neighbour
                w.debug_edit(hx + dx, gy, hz + dz, BlockId(38));
        }
    w.debug_edit(lx, gy, lz, BlockId(38));                        // lone
    for (int i = 0; i < 6; ++i) w.update(zero, 0.016);

    std::vector<bf_draw_item> draws, shadow_draws;
    std::vector<bf_prop_instance> props;
    bf_render_frame f{};
    w.build_frame(f, draws, shadow_draws, props, 0.0);

    auto densityAt = [&](int wx, int wy, int wz, bool& found) -> int {
        found = false;
        for (const auto& p : props) {
            if (p.type != 38u) continue;
            if (std::lround(p.position.x) == wx && std::lround(p.position.y) == wy &&
                std::lround(p.position.z) == wz) { found = true; return int((p.seed >> 28) & 0xF); }
        }
        return -1;
    };

    bool ff_=false, fg=false, fl=false, fe=false;
    int fullD = densityAt(fx, gy, fz, ff_);          // 8 neighbours
    int gapD  = densityAt(hx, gy, hz, fg);           // 7 (one removed)
    int edgeD = densityAt(fx + 1, gy, fz, fe);       // patch edge: 5 neighbours
    int loneD = densityAt(lx, gy, lz, fl);           // 0
    CHECK(ff_ && fg && fl && fe, "found all the test grass instances");
    CHECK(fullD == 8, "grass fully surrounded by grass has density 8 (big merged clump)");
    CHECK(gapD  == 7, "removing one neighbour drops the clump's density to 7 (it shrinks)");
    CHECK(edgeD == 5, "a patch-edge tuft has density 5 (partway)");
    CHECK(loneD == 0, "a lone tuft has density 0 (stays small)");

    if (fails == 0) std::printf("OK: plant clustering density (lone=%d edge=%d gapped=%d full=%d)\n",
                                loneD, edgeD, gapD, fullD);
    return fails == 0 ? 0 : 1;
}
