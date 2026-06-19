// Blockfall — ABI smoke test (engine side). Links blockcore, exercises the
// C ABI lifecycle end-to-end. Part of ci/check.sh unit stage. No framework:
// returns non-zero on first failure so CTest reports it.
#include "engine_c_api.h"
#include <cstdio>
#include <cstring>

static int fails = 0;
#define CHECK(cond, msg) do { if(!(cond)) { std::printf("FAIL: %s\n", msg); ++fails; } } while(0)

int main() {
    CHECK(bf_abi_version() == BF_ABI_VERSION, "abi version matches header");

    // ABI mismatch is rejected.
    bf_engine_config bad{};
    bad.abi_version = BF_ABI_VERSION + 1;
    bf_result err = BF_OK;
    CHECK(bf_engine_create(&bad, &err) == nullptr, "rejects bad ABI");
    CHECK(err == BF_ERR_ABI_MISMATCH, "reports ABI mismatch code");

    // Happy path.
    bf_engine_config cfg{};
    cfg.abi_version = BF_ABI_VERSION;
    cfg.role = BF_ROLE_SINGLEPLAYER;
    cfg.start_mode = BF_MODE_CREATIVE;
    cfg.render_distance_chunks = 0;          // -> defaults to 10
    cfg.content_dir = "/tmp"; cfg.save_dir = "/tmp"; cfg.player_name = "kid";
    err = BF_ERR_INTERNAL;
    bf_engine e = bf_engine_create(&cfg, &err);
    CHECK(e != nullptr, "creates engine");
    CHECK(err == BF_OK, "create ok code");

    CHECK(bf_world_new(e, 1234) == BF_OK, "new world");

    bf_frame_input in{};
    in.move_forward = 1.0f;
    CHECK(bf_frame_begin(e, &in, 0.016) == BF_OK, "frame begin");

    bf_render_frame f{};
    CHECK(bf_frame_acquire_render(e, &f) == BF_OK, "acquire render");
    CHECK(f.hud.health == 20.0f, "hud health populated");
    CHECK(f.hud.mode == BF_MODE_CREATIVE, "hud mode carried from config");
    CHECK(std::strlen(f.hud.quest_title) > 0, "hud has a quest title");
    bf_frame_end(e);

    bf_action act{}; act.kind = BF_ACT_PLACE;
    CHECK(bf_input_action(e, &act) == BF_OK, "place action accepted");

    CHECK(bf_world_save(e) == BF_OK, "save");
    bf_engine_destroy(e);

    if (fails == 0) std::printf("OK: abi smoke (%s)\n", "all checks passed");
    return fails == 0 ? 0 : 1;
}
