// ============================================================================
// Blockfall — engine.cpp (C ABI implementation, M1)
// Implements contract/engine_c_api.h on top of the real engine World: chunk
// storage (Track B), greedy meshing (Track D), and the player + mine/place
// loop (Track G). Single-player M1 path; networking/save are later milestones.
// The name is historical (was the Phase-0 stub) — it is now the live engine.
// ============================================================================
#include "engine_c_api.h"
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"

#include <cstring>
#include <string>
#include <vector>
#include <new>

namespace {
thread_local std::string t_last_error = "ok";
std::string g_create_error = "ok";
void set_err(const char* m) { t_last_error = m; }
} // namespace

struct bf_engine_s {
    bf_engine_config cfg{};
    bf::GreedyMesher mesher{};
    bf::World        world{mesher};
    bool             world_ready = false;
    double           clock = 0.0;
    bf_event_fn      evt_fn = nullptr;
    void*            evt_user = nullptr;
    std::vector<bf_draw_item> draws;     // backing store for the borrowed frame
    bf_render_frame  frame{};
    bool             borrowed = false;
};

extern "C" {

uint32_t bf_abi_version(void) { return BF_ABI_VERSION; }

bf_engine bf_engine_create(const bf_engine_config* cfg, bf_result* out_err) {
    auto fail = [&](bf_result r, const char* m) -> bf_engine {
        g_create_error = m; if (out_err) *out_err = r; return nullptr;
    };
    if (!cfg)                                return fail(BF_ERR_BAD_ARG, "null config");
    if (cfg->abi_version != BF_ABI_VERSION)  return fail(BF_ERR_ABI_MISMATCH, "ABI version mismatch");
    auto* e = new (std::nothrow) bf_engine_s();
    if (!e) return fail(BF_ERR_OUT_OF_MEMORY, "engine alloc failed");
    e->cfg = *cfg;
    if (e->cfg.render_distance_chunks == 0) e->cfg.render_distance_chunks = 10;
    e->world.set_mode(cfg->start_mode);
    if (out_err) *out_err = BF_OK;
    g_create_error = "ok";
    return e;
}

void bf_engine_destroy(bf_engine e) { delete e; }

const char* bf_last_error(bf_engine)   { return t_last_error.c_str(); }
const char* bf_last_error_global(void) { return g_create_error.c_str(); }

bf_result bf_world_new(bf_engine e, uint64_t seed) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    e->cfg.world_seed = seed ? seed : e->cfg.world_seed;
    e->world.generate_test_world();
    e->world_ready = true;
    return BF_OK;
}
bf_result bf_world_load(bf_engine e) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    e->world.generate_test_world();   // save/load arrives in M2
    e->world_ready = true;
    return BF_OK;
}
bf_result bf_world_save(bf_engine e) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    if (e->evt_fn) { bf_event ev{}; ev.kind = BF_EVT_SAVE_DONE; e->evt_fn(e->evt_user, &ev); }
    return BF_OK;
}

bf_result bf_frame_begin(bf_engine e, const bf_frame_input* in, double real_dt) {
    if (!e || !in) { set_err("null arg"); return BF_ERR_BAD_ARG; }
    e->clock += real_dt;
    if (e->world_ready) e->world.update(*in, real_dt);
    return BF_OK;
}

bf_result bf_frame_acquire_render(bf_engine e, bf_render_frame* out) {
    if (!e || !out) { set_err("null arg"); return BF_ERR_BAD_ARG; }
    e->frame = bf_render_frame{};
    e->world.build_frame(e->frame, e->draws, e->clock);
    e->borrowed = true;
    *out = e->frame;
    return BF_OK;
}

void bf_frame_end(bf_engine e) { if (e) e->borrowed = false; }

bf_result bf_input_action(bf_engine e, const bf_action* act) {
    if (!e || !act) { set_err("null arg"); return BF_ERR_BAD_ARG; }
    if (!e->world_ready) { set_err("world not ready"); return BF_ERR_NOT_READY; }
    e->world.action(*act);
    if (e->evt_fn && (act->kind == BF_ACT_PLACE || act->kind == BF_ACT_MINE_STOP)) {
        bf_event ev{};
        ev.kind = (act->kind == BF_ACT_PLACE) ? BF_EVT_BLOCK_PLACED : BF_EVT_BLOCK_BROKEN;
        e->evt_fn(e->evt_user, &ev);
    }
    return BF_OK;
}

bf_result bf_set_gpu_allocator(bf_engine e, const bf_gpu_allocator* a) {
    if (!e || !a) { set_err("null arg"); return BF_ERR_BAD_ARG; }
    e->world.set_allocator(*a);
    return BF_OK;
}

bf_result bf_set_event_callback(bf_engine e, bf_event_fn fn, void* user) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    e->evt_fn = fn; e->evt_user = user;
    return BF_OK;
}

bf_result bf_net_host_start(bf_engine e, uint16_t)                   { return e ? BF_OK : BF_ERR_BAD_ARG; }
bf_result bf_net_client_connect(bf_engine e, const char*, uint16_t)  { return e ? BF_OK : BF_ERR_BAD_ARG; }
bf_result bf_net_stop(bf_engine e)                                   { return e ? BF_OK : BF_ERR_BAD_ARG; }
uint32_t  bf_net_peer_count(bf_engine)                               { return 0; }

} // extern "C"
