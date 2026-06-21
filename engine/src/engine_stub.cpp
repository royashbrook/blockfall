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
#include "blockcore/worldgen.hpp"
#include "blockcore/net.hpp"
#include "blockcore/session.hpp"

#include <cstring>
#include <string>
#include <vector>
#include <new>
#include <optional>

namespace {
thread_local std::string t_last_error = "ok";
std::string g_create_error = "ok";
void set_err(const char* m) { t_last_error = m; }
} // namespace

struct bf_engine_s {
    bf_engine_config cfg{};
    bf::ContentRegistry content{};
    bf::ContentExtra    content_extra{};
    bf::GreedyMesher mesher{};
    bf::TerrainGen   worldgen{};
    bf::World        world{mesher, &worldgen};
    bool             world_ready = false;
    double           clock = 0.0;
    bf_event_fn      evt_fn = nullptr;
    void*            evt_user = nullptr;
    std::vector<bf_draw_item> draws;     // backing store for the borrowed frame
    bf_render_frame  frame{};
    bool             borrowed = false;
    std::optional<bf::UdpTransport> transport;   // co-op (Track H)
    std::optional<bf::NetSession>   session;
};

namespace {
// Wire a freshly-created transport+session pair together.
void wire_net(bf_engine e) {
    e->transport->set_receive_callback(
        [e](std::uint32_t peer, bf::NetChannel ch, std::span<const std::byte> d) {
            if (e->session) e->session->on_payload(std::uint16_t(peer), ch, d);
        });
    e->session->set_sender(
        [e](std::uint16_t peer, bf::NetChannel ch, std::span<const std::byte> d) {
            if (e->transport) e->transport->send(ch, d, peer);
        });
}
} // namespace

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
    // Load data-driven content (blocks/items/recipes) and wire it in (Track J).
    e->content.load(cfg->content_dir ? cfg->content_dir : ".");
    e->world.set_content(&e->content);
    e->content_extra.load(cfg->content_dir ? cfg->content_dir : ".");
    e->world.set_extra(&e->content_extra);
    // Forward gameplay effects (audio/particles) to the app event callback.
    e->world.set_fx_callback([e](int code, bf::IVec3 p, int extra) {
        if (e->evt_fn) {
            bf_event ev{}; ev.kind = BF_EVT_SFX; ev.i = code; ev.j = extra;
            ev.pos = bf_ivec3{p.x, p.y, p.z};
            e->evt_fn(e->evt_user, &ev);
        }
    });
    if (out_err) *out_err = BF_OK;
    g_create_error = "ok";
    return e;
}

void bf_engine_destroy(bf_engine e) { delete e; }

const char* bf_last_error(bf_engine)   { return t_last_error.c_str(); }
const char* bf_last_error_global(void) { return g_create_error.c_str(); }

bf_result bf_world_new(bf_engine e, uint64_t seed) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    uint64_t s = seed ? seed : (e->cfg.world_seed ? e->cfg.world_seed : 1337u);
    e->cfg.world_seed = s;
    e->world.init_world(s);           // procedural streaming world (Track C)
    e->world_ready = true;
    return BF_OK;
}
bf_result bf_world_load(bf_engine e) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    const char* dir = e->cfg.save_dir ? e->cfg.save_dir : "";
    if (!e->world.load(dir))                       // no save yet -> fresh world
        e->world.init_world(e->cfg.world_seed ? e->cfg.world_seed : 1337u);
    e->world_ready = true;
    return BF_OK;
}
bf_result bf_world_save(bf_engine e) {
    if (!e) { set_err("null engine"); return BF_ERR_BAD_ARG; }
    bool ok = e->world.save(e->cfg.save_dir ? e->cfg.save_dir : "");
    if (e->evt_fn) { bf_event ev{}; ev.kind = BF_EVT_SAVE_DONE; ev.i = ok ? 0 : 1; e->evt_fn(e->evt_user, &ev); }
    return ok ? BF_OK : BF_ERR_IO;
}

bf_result bf_frame_begin(bf_engine e, const bf_frame_input* in, double real_dt) {
    if (!e || !in) { set_err("null arg"); return BF_ERR_BAD_ARG; }
    e->clock += real_dt;
    if (e->world_ready) e->world.update(*in, real_dt);
    if (e->transport) e->transport->poll();          // pump sockets -> session
    if (e->session)   e->session->update(real_dt);   // 20 Hz position snapshots
    return BF_OK;
}

bf_result bf_frame_acquire_render(bf_engine e, bf_render_frame* out) {
    if (!e || !out) { set_err("null arg"); return BF_ERR_BAD_ARG; }
    // If a frame is already acquired (double-acquire / a skipped frame_end), hand
    // back the SAME already-built frame instead of rebuilding. Rebuilding would
    // realloc e->draws/entities_ and dangle the pointers the prior acquire gave
    // Swift; returning an empty/unfilled frame would blank the world and zero the
    // HUD (black-through-ground + a false "you died"). So: return the live frame.
    if (e->borrowed) { *out = e->frame; return BF_OK; }
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

bf_result bf_net_host_start(bf_engine e, uint16_t port) {
    if (!e) return BF_ERR_BAD_ARG;
    e->transport.emplace();
    e->session.emplace(e->world, bf::NetRole::Host);
    wire_net(e);
    if (!e->transport->start_host(port)) { e->session.reset(); e->transport.reset(); return BF_ERR_NET; }
    return BF_OK;
}
bf_result bf_net_client_connect(bf_engine e, const char* host, uint16_t port) {
    if (!e || !host) return BF_ERR_BAD_ARG;
    e->transport.emplace();
    e->session.emplace(e->world, bf::NetRole::Client);
    wire_net(e);
    if (!e->transport->connect(host, port)) { e->session.reset(); e->transport.reset(); return BF_ERR_NET; }
    e->session->on_peer_join(1);   // host is peer 1; sends HELLO -> WELCOME(seed)
    return BF_OK;
}
bf_result bf_net_stop(bf_engine e) {
    if (!e) return BF_ERR_BAD_ARG;
    if (e->transport) e->transport->stop();
    e->session.reset();
    e->transport.reset();
    e->world.set_edit_callback(nullptr);   // drop the dangling replicate hook
    return BF_OK;
}
uint32_t  bf_net_peer_count(bf_engine e) { return (e && e->transport) ? e->transport->peer_count() : 0u; }

} // extern "C"
