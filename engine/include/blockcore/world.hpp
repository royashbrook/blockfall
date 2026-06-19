// ============================================================================
// Blockfall — engine World (Track B+D+F+G integration for M1)
// Owns the chunk store, drives (re)meshing into UMA GPU buffers via the
// renderer's allocator, holds the player, and resolves the mine/place loop:
// raycast the camera into the voxel grid, break/place blocks, mark dirty
// chunks, remesh. The C-ABI layer (engine_c_api impl) is a thin translator
// over this. Meshing is injected (IMesher&) so the mesher impl can evolve
// independently. Remeshing is synchronous for M1 (a handful of chunks); the
// job-system path is wired in a later milestone.
// ============================================================================
#pragma once
#include "engine_c_api.h"
#include "blockcore/chunk.hpp"
#include "blockcore/vertex.hpp"
#include "blockcore/mathx.hpp"
#include "blockcore_interfaces.hpp"

#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <cmath>

namespace bf {

// M1 block palette (ids the renderer maps to colors; aligns loosely with
// /content but the engine doesn't load content yet at M1).
enum M1Block : BlockId {
    AIR = 0, GRASS = 1, DIRT = 2, STONE = 3, WOOD = 4, LEAF = 5,
    SAND = 6, GLOW = 7, BRICK = 8, WATER = 9
};

struct MeshRec {
    bf_gpu_buffer vbuf{};
    bf_gpu_buffer ibuf{};
    std::uint32_t index_count{0};
    bool          has_buffers{false};
};

class World {
public:
    explicit World(IMesher& mesher) : mesher_(mesher) {
        for (int i = 0; i < BF_HOTBAR_SLOTS; ++i) hotbar_[i] = 0;
        hotbar_[0] = GRASS; hotbar_[1] = STONE; hotbar_[2] = WOOD;
        hotbar_[3] = BRICK; hotbar_[4] = GLOW;  hotbar_[5] = SAND;
    }

    void set_allocator(const bf_gpu_allocator& a) { alloc_ = a; has_alloc_ = true; }
    void set_mode(bf_game_mode m) { mode_ = m; }

    // ---- world bootstrap: a small flat themed patch to fly over + dig into --
    void generate_test_world() {
        const int R = 2;                       // chunks in x/z around origin
        for (int cx = -R; cx <= R; ++cx)
        for (int cz = -R; cz <= R; ++cz) {
            ChunkCoord cc{cx, 0, cz};
            auto* ch = static_cast<PaletteChunk*>(store_.get_or_create(cc));
            for (int lx = 0; lx < kChunkDim; ++lx)
            for (int lz = 0; lz < kChunkDim; ++lz) {
                for (int ly = 0; ly < 8; ++ly) {
                    BlockId b = (ly == 7) ? GRASS : (ly >= 4 ? DIRT : STONE);
                    ch->set(lx, ly, lz, b);
                }
            }
            dirty_.insert(cc);
        }
        // A couple of decorative blocks so there's something to mine immediately.
        // A little structure to look at: a few decorative blocks on the surface.
        set_block_internal(IVec3{6, 8, 4}, GLOW);
        set_block_internal(IVec3{7, 8, 4}, BRICK);
        set_block_internal(IVec3{7, 9, 4}, BRICK);
        set_block_internal(IVec3{5, 8, 6}, WOOD);
        set_block_internal(IVec3{5, 9, 6}, LEAF);
        pos_ = V3{8.0f, 20.0f, 20.0f};           // elevated 3/4 vantage
        yaw_ = 3.14159f; pitch_ = -0.78f;        // look down onto the field + build
    }

    // ---- per-frame continuous update (movement + look + mining progress) ----
    void update(const bf_frame_input& in, double dt) {
        yaw_  += in.look_yaw_delta;
        pitch_ += in.look_pitch_delta;
        const float lim = 1.5533f;             // ~89 degrees
        if (pitch_ > lim) pitch_ = lim;
        if (pitch_ < -lim) pitch_ = -lim;

        V3 fwd = forward_dir();
        V3 flat = normalize(V3{fwd.x, 0, fwd.z});
        V3 right = normalize(cross(flat, V3{0,1,0}));
        float speed = (in.sprint ? 16.0f : 8.0f) * float(dt);

        V3 delta = flat * (in.move_forward * speed) + right * (in.move_strafe * speed);
        // Creative / M1: free vertical via jump(up) + sneak(down) or fly keys.
        float up = 0.0f;
        if (in.jump || in.fly_ascend)  up += speed;
        if (in.sneak || in.fly_descend) up -= speed;
        delta.y += up;
        pos_ = pos_ + delta;

        raycast_target();
        if (mining_ && has_target_) {
            mine_progress_ += float(dt) / break_time(block_at(target_));
            if (mine_progress_ >= 1.0f) {
                set_block_internal(target_, AIR);
                mine_progress_ = 0.0f;
                raycast_target();
            }
        } else {
            mine_progress_ = 0.0f;
        }
    }

    // ---- discrete actions (from bf_input_action) ---------------------------
    void action(const bf_action& a) {
        switch (a.kind) {
            case BF_ACT_MINE_START: mining_ = true; break;
            case BF_ACT_MINE_STOP:  mining_ = false; mine_progress_ = 0.0f; break;
            case BF_ACT_PLACE:
                if (has_target_ && hotbar_[selected_] != 0)
                    set_block_internal(place_, hotbar_[selected_]);
                break;
            case BF_ACT_HOTBAR_SELECT:
                if (a.arg_i >= 0 && a.arg_i < BF_HOTBAR_SLOTS) selected_ = std::uint8_t(a.arg_i);
                break;
            case BF_ACT_HOTBAR_SCROLL: {
                int s = int(selected_) + (a.arg_i >= 0 ? 1 : -1);
                s = (s % BF_HOTBAR_SLOTS + BF_HOTBAR_SLOTS) % BF_HOTBAR_SLOTS;
                selected_ = std::uint8_t(s);
                break;
            }
            case BF_ACT_MODE_TOGGLE:
                mode_ = (mode_ == BF_MODE_CREATIVE) ? BF_MODE_SURVIVAL : BF_MODE_CREATIVE;
                break;
            default: break;
        }
    }

    // ---- build the render frame (remesh dirty, fill camera + HUD) -----------
    void build_frame(bf_render_frame& out, std::vector<bf_draw_item>& draws, double clock) {
        remesh_dirty();

        draws.clear();
        for (auto& [cc, rec] : meshes_) {
            if (!rec.has_buffers || rec.index_count == 0) continue;
            bf_draw_item d{};
            d.vertex_buffer = rec.vbuf.handle;
            d.index_buffer  = rec.ibuf.handle;
            d.index_count   = rec.index_count;
            d.material_id   = 0;
            d.chunk_origin  = bf_ivec3{cc.x * kChunkDim, cc.y * kChunkDim, cc.z * kChunkDim};
            d.dim_saturation = 1.0f;
            draws.push_back(d);
        }

        V3 fwd = forward_dir();
        V3 eye = pos_;
        V3 ctr = eye + fwd;
        M4 view = look_at(eye, ctr, V3{0,1,0});
        M4 proj = perspective(1.20f, 1.6f, 0.05f, 512.0f); // renderer may override aspect

        std::memcpy(out.camera.view.m, view.m, sizeof(float) * 16);
        std::memcpy(out.camera.proj.m, proj.m, sizeof(float) * 16);
        out.camera.position = bf_vec3{eye.x, eye.y, eye.z};
        out.camera.forward  = bf_vec3{fwd.x, fwd.y, fwd.z};
        float t = float(std::fmod(clock * 0.01, 1.0));
        out.camera.time_of_day = t;
        float ang = t * 6.2831853f;
        out.camera.sun_dir = bf_vec3{std::cos(ang) * 0.5f, -0.8f, std::sin(ang) * 0.5f};
        out.interp_alpha = 0.0f;
        out.draws = draws.data();
        out.draw_count = std::uint32_t(draws.size());
        out.regions = nullptr; out.region_count = 0;

        fill_hud(out.hud);
    }

    bf_game_mode mode() const { return mode_; }

    // ---- test/debug seams (headless integration tests) ---------------------
    void    debug_set_camera(float px, float py, float pz, float yaw, float pitch) {
        pos_ = V3{px, py, pz}; yaw_ = yaw; pitch_ = pitch;
    }
    BlockId debug_block_at(int x, int y, int z) const { return block_at(IVec3{x, y, z}); }
    bool    debug_has_target() const { return has_target_; }
    void    debug_set_selected(std::uint8_t s) { selected_ = s; }

private:
    V3 forward_dir() const {
        return normalize(V3{ std::cos(pitch_) * std::sin(yaw_),
                             std::sin(pitch_),
                             std::cos(pitch_) * std::cos(yaw_) });
    }

    static float break_time(BlockId b) {
        switch (b) { case STONE: case BRICK: return 0.6f; case AIR: return 1e9f; default: return 0.3f; }
    }

    BlockId block_at(IVec3 w) const {
        ChunkCoord cc = to_chunk(w);
        auto* ch = const_cast<ChunkStore&>(store_).get(cc);
        if (!ch) return AIR;
        return ch->get(mod16(w.x), mod16(w.y), mod16(w.z));
    }

    void set_block_internal(IVec3 w, BlockId b) {
        ChunkCoord cc = to_chunk(w);
        auto* ch = store_.get_or_create(cc);
        ch->set(mod16(w.x), mod16(w.y), mod16(w.z), b);
        dirty_.insert(cc);
        mark_neighbor_dirty(w, cc);
    }

    // If the edit sits on a chunk boundary, the adjacent chunk's faces change too.
    void mark_neighbor_dirty(IVec3 w, ChunkCoord self) {
        const IVec3 dirs[6] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
        for (auto d : dirs) {
            ChunkCoord nc = to_chunk(IVec3{w.x + d.x, w.y + d.y, w.z + d.z});
            if (!(nc == self)) dirty_.insert(nc);
        }
    }

    void raycast_target() {
        // Amanatides-Woo voxel DDA from eye along forward, up to 6 blocks.
        has_target_ = false;
        V3 o = pos_;
        V3 d = forward_dir();
        IVec3 v{ ifloor(o.x), ifloor(o.y), ifloor(o.z) };
        IVec3 step{ d.x > 0 ? 1 : -1, d.y > 0 ? 1 : -1, d.z > 0 ? 1 : -1 };
        V3 tdelta{ d.x != 0 ? std::fabs(1.0f / d.x) : 1e30f,
                   d.y != 0 ? std::fabs(1.0f / d.y) : 1e30f,
                   d.z != 0 ? std::fabs(1.0f / d.z) : 1e30f };
        auto frac = [](float f, int s) {
            float fl = std::floor(f);
            return s > 0 ? (fl + 1 - f) : (f - fl);
        };
        V3 tmax{ tdelta.x * frac(o.x, step.x),
                 tdelta.y * frac(o.y, step.y),
                 tdelta.z * frac(o.z, step.z) };
        IVec3 prev = v;
        for (int i = 0; i < 96; ++i) {
            if (block_at(v) != AIR) {
                has_target_ = true; target_ = v; place_ = prev; return;
            }
            prev = v;
            if (tmax.x < tmax.y && tmax.x < tmax.z) { v.x += step.x; tmax.x += tdelta.x; }
            else if (tmax.y < tmax.z)               { v.y += step.y; tmax.y += tdelta.y; }
            else                                    { v.z += step.z; tmax.z += tdelta.z; }
        }
    }

    void remesh_dirty() {
        if (!has_alloc_) return;
        for (const ChunkCoord& cc : dirty_) {
            if (!store_.is_resident(cc)) continue;
            MeshRec& rec = meshes_[cc];
            // Free previous buffers (allocator guarantees GPU no longer reads).
            if (rec.has_buffers) {
                alloc_.free_(alloc_.user, rec.vbuf.handle);
                alloc_.free_(alloc_.user, rec.ibuf.handle);
                rec.has_buffers = false;
            }
            std::uint32_t vmax = mesher_.max_vertex_bytes();
            std::uint32_t imax = mesher_.max_index_bytes();
            bf_gpu_buffer vb = alloc_.alloc(alloc_.user, vmax);
            bf_gpu_buffer ib = alloc_.alloc(alloc_.user, imax);
            if (!vb.contents || !ib.contents) continue;
            std::span<std::byte> vspan(static_cast<std::byte*>(vb.contents), vb.bytes);
            std::span<std::byte> ispan(static_cast<std::byte*>(ib.contents), ib.bytes);
            MeshResult mr = mesher_.mesh(cc, store_, vspan, ispan, false);
            if (mr.empty || mr.index_count == 0) {
                alloc_.free_(alloc_.user, vb.handle);
                alloc_.free_(alloc_.user, ib.handle);
                rec.index_count = 0; rec.has_buffers = false;
            } else {
                rec.vbuf = vb; rec.ibuf = ib;
                rec.index_count = mr.index_count;
                rec.has_buffers = true;
            }
        }
        dirty_.clear();
    }

    void fill_hud(bf_hud_state& h) {
        h = bf_hud_state{};
        h.mode = mode_;
        h.selected_slot = selected_;
        h.inventory_open = 0;
        h.health = health_;
        h.hunger = hunger_;
        for (int i = 0; i < BF_HOTBAR_SLOTS; ++i) {
            h.hotbar[i].item = hotbar_[i];
            h.hotbar[i].count = std::uint16_t(hotbar_[i] ? 64 : 0);
            h.hotbar[i].durability = 0xFFFF;
        }
        h.active_quest_id = 1;
        std::strncpy(h.quest_title, "Bring back the color", sizeof(h.quest_title) - 1);
        std::strncpy(h.quest_objective, "Mine and place to restore the Dim", sizeof(h.quest_objective) - 1);
        h.quest_progress = 0.0f;
        h.has_target = has_target_ ? 1 : 0;
        h.target_block = bf_ivec3{target_.x, target_.y, target_.z};
        h.mine_progress = mine_progress_;
    }

    static int ifloor(float f) { return int(std::floor(f)); }
    static ChunkCoord to_chunk(IVec3 w) {
        return ChunkCoord{ floordiv(w.x, kChunkDim), floordiv(w.y, kChunkDim), floordiv(w.z, kChunkDim) };
    }
    static int floordiv(int a, int b) { int q = a / b; if ((a % b) && ((a < 0) != (b < 0))) --q; return q; }
    static int mod16(int a) { int m = a % kChunkDim; return m < 0 ? m + kChunkDim : m; }

    IMesher&    mesher_;
    ChunkStore  store_;
    bf_gpu_allocator alloc_{};
    bool        has_alloc_{false};
    std::unordered_map<ChunkCoord, MeshRec, ChunkCoordHash> meshes_;
    std::unordered_set<ChunkCoord, ChunkCoordHash> dirty_;

    // player
    V3            pos_{0, 12, 0};
    float         yaw_{0.0f}, pitch_{0.0f};
    bf_game_mode  mode_{BF_MODE_CREATIVE};
    float         health_{20.0f}, hunger_{20.0f};
    std::uint8_t  selected_{0};
    BlockId       hotbar_[BF_HOTBAR_SLOTS]{};
    bool          mining_{false};
    float         mine_progress_{0.0f};
    bool          has_target_{false};
    IVec3         target_{}, place_{};
};

} // namespace bf
