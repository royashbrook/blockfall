// ============================================================================
// Blockfall — engine_stub.cpp
// ----------------------------------------------------------------------------
// Phase-0 / M0 stub implementation of the frozen C ABI (contract/engine_c_api.h).
// It is intentionally minimal: enough to prove the Swift<->C++ boundary links,
// the frame loop runs, and the app can clear a colored frame + draw a HUD.
//
// Real subsystems (job pool, chunk store, mesher, net, gameplay) land behind
// the internal interfaces (contract/blockcore_interfaces.hpp) on tracks A-J.
// Nothing here allocates on a hot path; it just answers the ABI honestly.
// ============================================================================
#include "engine_c_api.h"

#include <cstring>
#include <cmath>
#include <string>
#include <atomic>

namespace {

thread_local std::string t_last_error = "ok";
std::string g_create_error = "ok";

void set_err(const char* msg) { t_last_error = msg; }

// Identity-ish camera helpers (column-major, drop straight into a MTLBuffer).
bf_mat4 identity() {
    bf_mat4 m{};
    m.m[0] = m.m[5] = m.m[10] = m.m[15] = 1.0f;
    return m;
}

} // namespace

// The opaque engine object. Kept tiny for the stub; grows as tracks land.
struct bf_engine_s {
    bf_engine_config cfg{};
    bool             world_ready = false;
    double           clock = 0.0;          // seconds since create
    float            day_time = 0.30f;     // start mid-morning
    bf_gpu_allocator alloc{};
    bool             has_alloc = false;
    bf_event_fn      evt_fn = nullptr;
    void*            evt_user = nullptr;

    // Borrowed render storage (stable between acquire/end). Stub has 0 draws.
    bf_render_frame  frame{};
    bool             frame_borrowed = false;
};

// ---------------------------------------------------------------------------
extern "C" {

uint32_t bf_abi_version(void) { return BF_ABI_VERSION; }

bf_engine bf_engine_create(const bf_engine_config* cfg, bf_result* out_err) {
    auto fail = [&](bf_result r, const char* m) -> bf_engine {
        g_create_error = m; if (out_err) *out_err = r; return nullptr;
    };
    if (!cfg)                              return fail(BF_ERR_BAD_ARG, "null config");
    if (cfg->abi_version != BF_ABI_VERSION) return fail(BF_ERR_ABI_MISMATCH, "ABI version mismatch");

    auto* e = new (std::nothrow) bf_engine_s();
    if (!e) return fail(BF_ERR_OUT_OF_MEMORY, "engine alloc failed");
    e->cfg = *cfg;
    if (e->cfg.render_distance_chunks == 0) e->cfg.render_distance_chunks = 10;
    if (out_err) *out_err = BF_OK;
    g_create_error = "ok";
    return e;
}

void bf_engine_destroy(bf_engine e) { delete e; }

const char* bf_last_error(bf_engine)        { return t_last_error.c_str(); }
const char* bf_last_error_global(void)      { return g_create_error.c_str(); }

bf_result bf_world_new(bf_engine e, uint64_t seed) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    e->cfg.world_seed = seed ? seed : e->cfg.world_seed;
    e->world_ready = true;
    return BF_OK;
}
bf_result bf_world_load(bf_engine e) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    // Stub: no save yet -> behave like a fresh world.
    e->world_ready = true;
    return BF_OK;
}
bf_result bf_world_save(bf_engine e) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    if (e->evt_fn) { bf_event ev{}; ev.kind = BF_EVT_SAVE_DONE; e->evt_fn(e->evt_user, &ev); }
    return BF_OK;
}

bf_result bf_frame_begin(bf_engine e, const bf_frame_input* in, double real_dt) {
    if (!e)  { set_err("null engine"); return BF_ERR_BAD_ARG; }
    if (!in) { set_err("null input");  return BF_ERR_BAD_ARG; }
    e->clock += real_dt;
    // Advance a slow day/night so the cleared sky color visibly drifts (M0 juice).
    e->day_time = std::fmod(e->day_time + float(real_dt) * 0.01f, 1.0f);
    return BF_OK;
}

bf_result bf_frame_acquire_render(bf_engine e, bf_render_frame* out) {
    if (!e || !out) { set_err("null arg"); return BF_ERR_BAD_ARG; }

    bf_render_frame& f = e->frame;
    f = bf_render_frame{};                 // zero
    f.camera.view = identity();
    f.camera.proj = identity();
    f.camera.position = bf_vec3{0, 4, 0};
    f.camera.forward  = bf_vec3{0, 0, -1};
    f.camera.time_of_day = e->day_time;
    // Simple overhead sun direction from time_of_day.
    float a = e->day_time * 6.2831853f;
    f.camera.sun_dir = bf_vec3{std::cos(a), -std::sin(a) - 0.2f, 0.3f};
    f.interp_alpha = 0.0f;
    f.draws = nullptr;       f.draw_count = 0;     // stub: nothing meshed yet
    f.regions = nullptr;     f.region_count = 0;

    // A believable starter HUD so the overlay has something to render (M0).
    bf_hud_state& h = f.hud;
    h.mode = e->cfg.start_mode;
    h.selected_slot = 0;
    h.inventory_open = 0;
    h.health = 20.0f;
    h.hunger = 20.0f;
    h.hotbar[0].item = 1; h.hotbar[0].count = 64; h.hotbar[0].durability = 0xFFFF; // "blocks"
    h.hotbar[1].item = 2; h.hotbar[1].count = 12; h.hotbar[1].durability = 0xFFFF;
    h.active_quest_id = 1;
    std::strncpy(h.quest_title, "Bring back the color", sizeof(h.quest_title) - 1);
    std::strncpy(h.quest_objective, "Place a glow block in the Dim", sizeof(h.quest_objective) - 1);
    h.quest_progress = 0.0f;
    h.has_target = 0;
    h.mine_progress = 0.0f;

    e->frame_borrowed = true;
    *out = f;
    return BF_OK;
}

void bf_frame_end(bf_engine e) { if (e) e->frame_borrowed = false; }

bf_result bf_input_action(bf_engine e, const bf_action* act) {
    if (!e || !act) { set_err("null arg"); return BF_ERR_BAD_ARG; }
    if (!e->world_ready) { set_err("world not ready"); return BF_ERR_NOT_READY; }
    // Stub: acknowledge mine/place by emitting an event so the app can wire SFX.
    if (e->evt_fn && (act->kind == BF_ACT_PLACE || act->kind == BF_ACT_MINE_STOP)) {
        bf_event ev{};
        ev.kind = (act->kind == BF_ACT_PLACE) ? BF_EVT_BLOCK_PLACED : BF_EVT_BLOCK_BROKEN;
        e->evt_fn(e->evt_user, &ev);
    }
    return BF_OK;
}

bf_result bf_set_gpu_allocator(bf_engine e, const bf_gpu_allocator* a) {
    if (!e || !a) { set_err("null arg"); return BF_ERR_BAD_ARG; }
    e->alloc = *a; e->has_alloc = true;
    return BF_OK;
}

bf_result bf_set_event_callback(bf_engine e, bf_event_fn fn, void* user) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    e->evt_fn = fn; e->evt_user = user;
    return BF_OK;
}

// --- Networking (stub: succeeds locally, 0 peers) --------------------------
bf_result bf_net_host_start(bf_engine e, uint16_t)          { return e ? BF_OK : BF_ERR_BAD_ARG; }
bf_result bf_net_client_connect(bf_engine e, const char*, uint16_t) { return e ? BF_OK : BF_ERR_BAD_ARG; }
bf_result bf_net_stop(bf_engine e)                          { return e ? BF_OK : BF_ERR_BAD_ARG; }
uint32_t  bf_net_peer_count(bf_engine)                      { return 0; }

} // extern "C"
