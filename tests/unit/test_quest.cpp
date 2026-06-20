// M5 — quest engine: loads content quests, completes the active quest when its
// objectives are met, grants the reward, and chains to the next quest.
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
    ContentExtra x;    CHECK(x.load("/Users/roy/gh/blockfall/content"), "extra load");
    CHECK(x.quests().size() >= 12, "loaded ~12+ quests");
    int bosses = 0; for (auto& cr : x.creatures()) if (cr.disposition == "boss") ++bosses;
    CHECK(bosses == 2, "two bosses in the roster");

    GreedyMesher m; TerrainGen g; World w(m, &g);
    bf_gpu_allocator a{}; a.alloc=af; a.free_=ff; w.set_allocator(a);
    w.set_content(&c); w.set_extra(&x);
    w.set_mode(BF_MODE_CREATIVE);
    w.init_world(11);

    const QuestDefX& q0 = x.quests()[0];
    std::uint32_t firstId = w.debug_active_quest();
    CHECK(firstId == q0.id, "active quest is the first content quest");
    CHECK(w.debug_quests_completed() == 0, "no quests completed yet");

    // Fire the first quest's objective triggers enough times to complete it.
    for (const auto& o : q0.objectives)
        for (std::uint32_t i = 0; i < o.count; ++i)
            w.debug_notify(o.trigger.c_str(), o.target.c_str());

    CHECK(w.debug_quests_completed() == 1, "first quest completed after meeting its objectives");
    CHECK(w.debug_active_quest() != firstId, "advanced to the next quest");

    if (fails == 0) std::printf("OK: quest engine (%zu quests, complete+chain)\n", x.quests().size());
    return fails == 0 ? 0 : 1;
}
