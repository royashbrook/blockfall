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

    // --- #41 quest-target compass: fill_quest_target finds the active objective's
    // creature (befriend or boss), by name, only when one is loaded nearby. ---
    {
        GreedyMesher m2; TerrainGen g2; World w2(m2, &g2);
        bf_gpu_allocator a2{}; a2.alloc=af; a2.free_=ff; w2.set_allocator(a2);
        w2.set_content(&c); w2.set_extra(&x);
        w2.set_mode(BF_MODE_SURVIVAL);
        w2.init_world(11);

        // Advance the chain until the active quest has an objective with `trig`,
        // returning that objective (without completing its quest).
        auto advanceTo = [&](const char* trig)->const QuestObjX*{
            for (int guard = 0; guard < 50; ++guard) {
                std::uint32_t aqId = w2.debug_active_quest();
                const QuestDefX* q = nullptr;
                for (auto& qq : x.quests()) if (qq.id == aqId) { q = &qq; break; }
                if (!q) return nullptr;
                for (auto& o : q->objectives) if (o.trigger == trig) return &o;
                for (const auto& o : q->objectives)                  // not it — complete + advance
                    for (std::uint32_t i = 0; i < o.count; ++i)
                        w2.debug_notify(o.trigger.c_str(), o.target.c_str());
            }
            return nullptr;
        };

        const QuestObjX* befr = advanceTo("befriend_creature");
        CHECK(befr != nullptr, "reached a befriend_creature quest");

        bf_quest_target qt{};
        CHECK(w2.fill_quest_target(&qt) == false, "no target while the creature isn't loaded");
        if (befr) w2.debug_spawn_named(befr->target.c_str());
        CHECK(w2.fill_quest_target(&qt) == true, "target active once the creature is loaded");
        CHECK(qt.active == 1 && qt.is_boss == 0, "befriend target: active, not a boss");
        CHECK(std::string(qt.label) == "Gloom Stag", "label title-cased from creature name");
        CHECK(qt.distance > 0.0f && qt.distance < 20.0f, "distance to target is sane");

        const QuestObjX* boss = advanceTo("calm_boss");
        CHECK(boss != nullptr, "reached a calm_boss quest");
        bf_quest_target qb{};
        if (boss) w2.debug_spawn_named(boss->target.c_str());
        CHECK(w2.fill_quest_target(&qb) == true, "boss target active once loaded");
        CHECK(qb.is_boss == 1, "calm_boss target is flagged is_boss");
    }

    // Taming a platypus earns the "Perry the Platypus" achievement (a fun nod).
    {
        GreedyMesher m3; TerrainGen g3; World w3(m3, &g3);
        bf_gpu_allocator a3{}; a3.alloc=af; a3.free_=ff; w3.set_allocator(a3);
        w3.set_content(&c); w3.set_extra(&x);
        w3.set_mode(BF_MODE_CREATIVE); w3.init_world(11);
        w3.debug_notify("befriend_creature", "platypus");
        CHECK(w3.debug_ach_toast() == "Achievement: Perry the Platypus",
              "befriending a platypus unlocks the Perry the Platypus achievement");
    }

    if (fails == 0) std::printf("OK: quest engine (%zu quests, complete+chain, target compass)\n", x.quests().size());
    return fails == 0 ? 0 : 1;
}
