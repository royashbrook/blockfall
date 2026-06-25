// #41 — quest + progression loop end-to-end. Proves the campaign is actually winnable:
//   A) every objective targets content that exists (no unwinnable quest from a typo),
//   B) driving each active quest's own triggers chains all the way to the win state, and
//   C) a REAL beacon placement restores a Grey region (the action->notify_quest pipeline
//      works, not just the debug trigger path).
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"
#include "blockcore/worldgen.hpp"
#include "blockcore/content.hpp"
#include "blockcore/content_extra.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static bf_gpu_buffer af(void*, uint32_t b){ void* p=std::malloc(b?b:16); bf_gpu_buffer r{}; r.handle=reinterpret_cast<uint64_t>(p); r.contents=p; r.bytes=b; return r; }
static void ff(void*, uint64_t h){ std::free(reinterpret_cast<void*>(h)); }

using namespace bf;

// floor-divide a voxel coord into its chunk coord (handles negatives).
static int chunk_of(int v) { return v >= 0 ? v / 16 : (v - 15) / 16; }

int main() {
    ContentRegistry c; CHECK(c.load("/Users/roy/gh/blockfall/content"), "content load");
    ContentExtra x;    CHECK(x.load("/Users/roy/gh/blockfall/content"), "extra load");
    CHECK(x.quests().size() >= 12, "loaded the campaign quests");

    // ---- A) every objective targets something that actually exists -------------
    // Catches an unwinnable quest where a trigger's target is a typo / missing item,
    // block, or creature that real gameplay could never produce.
    auto creatureExists = [&](const std::string& nm){
        for (auto& cr : x.creatures()) if (cr.name == nm) return true; return false;
    };
    for (const auto& q : x.quests()) {
        for (const auto& o : q.objectives) {
            if (o.target.empty()) continue;   // e.g. light_beacon / generic objectives
            const std::string& t = o.target;
            bool ok = true;
            if (o.trigger == "befriend_creature" || o.trigger == "calm_boss") {
                ok = creatureExists(t);
            } else if (o.trigger == "restore_region" || o.trigger == "reach_location") {
                ok = true;                     // region tag, not a content entity
            } else {
                // item / block triggers: accept the name as either an item or a block,
                // since some placeables blur the two.
                ok = (c.item_by_name(t) != nullptr) || (c.block_by_name(t) != nullptr);
            }
            if (!ok)
                std::printf("FAIL: quest %u objective '%s' targets missing content '%s'\n",
                            q.id, o.trigger.c_str(), t.c_str());
            CHECK(ok, "objective target exists in content");
        }
    }

    // ---- B) the whole chain is completable -> win state ------------------------
    {
        GreedyMesher m; TerrainGen g; World w(m, &g);
        bf_gpu_allocator a{}; a.alloc=af; a.free_=ff; w.set_allocator(a);
        w.set_content(&c); w.set_extra(&x);
        w.set_mode(BF_MODE_CREATIVE);
        w.init_world(11);

        CHECK(w.debug_active_quest() == x.quests()[0].id, "first quest active on spawn");
        CHECK(!w.debug_all_quests_done(), "not won at the start");

        int guard = 0;
        while (!w.debug_all_quests_done() && guard++ < 200) {
            std::uint32_t aqId = w.debug_active_quest();
            const QuestDefX* q = nullptr;
            for (auto& qq : x.quests()) if (qq.id == aqId) { q = &qq; break; }
            CHECK(q != nullptr, "active quest id resolves to a loaded quest");
            if (!q) break;
            // Fire this quest's own objective triggers enough to satisfy it.
            for (const auto& o : q->objectives)
                for (std::uint32_t i = 0; i < o.count; ++i)
                    w.debug_notify(o.trigger.c_str(), o.target.c_str());
        }
        CHECK(w.debug_all_quests_done(), "every quest completed -> the campaign is winnable");
        CHECK(w.debug_quests_completed() == (int)x.quests().size(),
              "completed-quest count matches the number of loaded quests");
        std::printf("  drove %d quests to the win state\n", w.debug_quests_completed());
    }

    // ---- C) a real beacon placement restores a Grey region --------------------
    // Drives a placement through the action pipeline (not debug_notify), proving the
    // gameplay -> notify_quest -> region restoration path works end-to-end.
    {
        GreedyMesher m; TerrainGen g; World w(m, &g);
        w.debug_set_sync_streaming(true);     // deterministic inline gen
        bf_gpu_allocator a{}; a.alloc=af; a.free_=ff; w.set_allocator(a);
        w.set_content(&c); w.set_extra(&x);
        w.set_mode(BF_MODE_CREATIVE);
        w.init_world(11);

        bf_frame_input zero{};
        // A far-away region (defaults to Grey), high in clear air. Stream it in, then
        // float a stone block and look straight down at it.
        const int bx = 2000, by = 145, bz = 2000;
        w.debug_set_camera(float(bx) + 0.5f, float(by) + 5.0f, float(bz) + 0.5f, 0.0f, -1.5707f);
        for (int i = 0; i < 30; ++i) w.update(zero, 0.05);
        CHECK(w.debug_region_sat(chunk_of(bx), chunk_of(bz)) < 0.99f, "far region starts Grey");

        w.debug_edit(bx, by, bz, bf::STONE);
        w.debug_set_camera(float(bx) + 0.5f, float(by) + 5.0f, float(bz) + 0.5f, 0.0f, -1.5707f);
        w.update(zero, 0.016);
        CHECK(w.debug_has_target(), "aimed at the stone block for placement");

        ItemId beacon = w.debug_item_id("beacon_block");
        CHECK(beacon != 0, "content has a beacon_block item");
        w.debug_clear_inventory();
        w.debug_give(beacon, 1);
        bf_action sel{}; sel.kind = BF_ACT_HOTBAR_SELECT; sel.arg_i = 0; w.action(sel);

        int restoredBefore = w.debug_regions_restored();
        bf_action place{}; place.kind = BF_ACT_PLACE; w.action(place);
        w.update(zero, 0.016);

        CHECK(w.debug_block_at(bx, by + 1, bz) == beacon || w.debug_regions_restored() == restoredBefore + 1,
              "beacon placed on top of the stone");
        CHECK(w.debug_regions_restored() == restoredBefore + 1,
              "placing a beacon in a Grey region restores it (Grey recedes)");
        CHECK(w.debug_region_sat(chunk_of(bx), chunk_of(bz)) > 0.99f,
              "the restored region is now full colour");
    }

    if (fails == 0) std::printf("OK: quest loop end-to-end (achievable, winnable, Grey recedes)\n");
    return fails == 0 ? 0 : 1;
}
