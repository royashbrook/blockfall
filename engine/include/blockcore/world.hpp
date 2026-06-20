// ============================================================================
// Blockfall — engine World (M1 core + M2 streaming/Dim)
// Owns the chunk store, streams procedural chunks around the player (Track C
// via injected IWorldGen), (re)meshes into tightly-sized UMA GPU buffers, and
// resolves the mine/place loop. M2 adds: deterministic streaming with a per-
// frame generation budget, chunk eviction, and per-region Dim saturation that
// the renderer desaturates by (the "bring back the color" mechanic).
//
// Memory: meshes go through a single reusable scratch buffer, then into an
// exact-sized GPU buffer (not the worst-case 1.5 MiB) so hundreds of streamed
// chunks fit the Air's UMA budget (spec §10).
// ============================================================================
#pragma once
#include "engine_c_api.h"
#include "blockcore/chunk.hpp"
#include "blockcore/vertex.hpp"
#include "blockcore/mathx.hpp"
#include "blockcore/lighting.hpp"
#include "blockcore/content.hpp"
#include "blockcore/content_extra.hpp"
#include "blockcore/inventory.hpp"
#include "blockcore/crafting.hpp"
#include "blockcore_interfaces.hpp"

#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <algorithm>
#include <cmath>
#include <string>
#include <fstream>
#include <filesystem>
#include <cstdio>
#include <optional>
#include <functional>

namespace bf {

enum M1Block : BlockId {
    AIR = 0, GRASS = 1, DIRT = 2, STONE = 3, WOOD = 4, LEAF = 5,
    SAND = 6, GLOW = 7, BRICK = 8, WATER = 9
};

// Animals + bosses (M3/M5). Original, bright, non-scary. Render/sim params are
// carried per-creature so the roster is content-driven (Track J).
struct Creature {
    V3    pos{};
    float yaw{0};
    float vy{0};            // vertical velocity (gravity)
    V3    color{0.9f, 0.8f, 0.5f};
    float scale{0.8f};
    float speed{1.6f};
    int   hp{3};            // calm hits remaining (bosses take more)
    bool  is_boss{false};
    bool  friendly{false};
    float wander{0};
    int   shape{0};         // renderer model variant (0..3 animals)
    std::string name;       // content creature name (quest befriend target)
};

struct MeshRec {
    bf_gpu_buffer vbuf{};
    bf_gpu_buffer ibuf{};
    std::uint32_t index_count{0};
    bool          has_buffers{false};
};

struct RegionKey { std::int32_t x, z; };
inline bool operator==(const RegionKey& a, const RegionKey& b) { return a.x == b.x && a.z == b.z; }
struct RegionKeyHash {
    std::size_t operator()(const RegionKey& k) const noexcept {
        return std::size_t(std::uint64_t(std::uint32_t(k.x)) * 0x9E3779B1u
                         ^ std::uint64_t(std::uint32_t(k.z)) * 0x85EBCA77u);
    }
};

class World {
public:
    static constexpr float  DIM_SAT      = 0.18f;  // unrestored regions: grey
    static constexpr int    STREAM_R     = 6;      // horizontal radius (chunks)
    static constexpr int    CY_MIN       = -1;     // vertical chunk band (terrain)
    static constexpr int    CY_MAX       = 3;
    static constexpr int    GEN_BUDGET   = 12;     // chunks generated per frame
    static constexpr int    MESH_BUDGET  = 8;      // chunks remeshed per frame

    explicit World(IMesher& mesher, IWorldGen* gen = nullptr)
        : mesher_(mesher), gen_(gen) {}

    void set_allocator(const bf_gpu_allocator& a) { alloc_ = a; has_alloc_ = true; }
    void set_mode(bf_game_mode m) { mode_ = m; }
    void set_worldgen(IWorldGen* g) { gen_ = g; }

    // ---- co-op hooks (Track H) -------------------------------------------
    // Fired on every LOCAL player edit (place/mine) so the net session can
    // replicate it. Remote edits (applied via apply_remote_edit) do NOT fire it.
    void set_edit_callback(std::function<void(IVec3, BlockId)> cb) { edit_cb_ = std::move(cb); }
    void apply_remote_edit(IVec3 w, BlockId b) { set_block_internal(w, b, /*from_remote=*/true); }
    void set_extra(const ContentExtra* x) { extra_ = x; }
    // Gameplay effects for the app (audio + particles). code: 0 break,1 place,
    // 2 step,3 jump,4 craft,5 befriend,6 quest-complete.
    void set_fx_callback(std::function<void(int, IVec3)> cb) { fx_cb_ = std::move(cb); }
    void fx(int code, IVec3 p) { if (fx_cb_) fx_cb_(code, p); }
    void get_player(float& x, float& y, float& z, float& yaw) const {
        x = pos_.x; y = pos_.y; z = pos_.z; yaw = yaw_;
    }
    std::uint64_t world_seed() const { return seed_; }
    // Other players' avatars to draw (set each frame by the net session).
    void set_remote_avatars(const std::vector<bf_entity_draw>& a) { remote_avatars_ = a; }

    // Wire the loaded content (Track J). Builds the inventory + crafting and
    // resolves the block ids gameplay needs by name (so the engine never
    // hard-codes content ids).
    void set_content(const ContentRegistry* c) {
        content_ = c;
        if (!c) return;
        blocks_  = &c->block_registry();
        items_   = &c->item_registry();
        recipes_ = &c->recipe_book();
        inv_.emplace(BF_INVENTORY_SLOTS, items_);
        craft_.emplace(recipes_);
        glow_id_ = block_id_by_name("glow_block");
        give_starter_items();
    }

    ItemId  item_id_by_name(const char* n) const {
        if (!items_) return 0; const ItemDef* d = items_->by_name(n); return d ? d->id : 0;
    }
    BlockId block_id_by_name(const char* n) const {
        if (!blocks_) return 0; const BlockDef* d = blocks_->by_name(n); return d ? d->id : 0;
    }
    void give_starter_items() {
        if (!inv_) return;
        if (mode_ == BF_MODE_CREATIVE) {
            // Creative: a full palette of placeable + functional blocks.
            const char* hot[BF_HOTBAR_SLOTS] = {
                "glow_block", "stone", "oak_planks", "stone_brick", "sand",
                "oak_log", "torch", "chest", "crafting_table"
            };
            for (int i = 0; i < BF_HOTBAR_SLOTS; ++i)
                if (ItemId id = item_id_by_name(hot[i])) inv_->set(std::size_t(i), ItemStack{id, 64, 0xFFFF});
        } else {
            // Survival: hotbar starts EMPTY so mined blocks visibly land in it.
            // Just a couple of logs to bootstrap the first crafts.
            if (ItemId log = item_id_by_name("oak_log")) inv_->set(0, ItemStack{log, 3, 0xFFFF});
        }
    }

    // ---- M2: procedural spawn + streaming --------------------------------
    void init_world(std::uint64_t seed) {
        seed_ = seed;
        if (!gen_) { generate_test_world(); return; }
        gen_->seed(seed);
        // Find the surface at spawn column (0,0): generate the vertical band and
        // scan from the top for the first solid block.
        int surface = 8; bool found = false;
        for (int cy = CY_MAX; cy >= CY_MIN; --cy) {
            ChunkCoord cc{0, cy, 0};
            auto ch = std::make_unique<PaletteChunk>(cc);
            gen_->generate(cc, *ch);
            if (!found)
                for (int ly = kChunkDim - 1; ly >= 0; --ly)
                    if (ch->get(0, ly, 0) != AIR) { surface = cy * kChunkDim + ly; found = true; break; }
            // Keep the spawn column resident so the player lands immediately
            // (rather than falling through before streaming fills it in).
            if (!(ch->is_uniform() && ch->get(0, 0, 0) == AIR)) {
                store_.insert(std::move(ch)); dirty_.insert(cc);
            }
        }
        pos_ = V3{0.5f, float(surface) + 2.5f, 0.5f};
        yaw_ = 0.6f; pitch_ = -0.25f;
        restore_region(ChunkCoord{0, 0, 0});           // spawn region starts colorful
        recompute_stream_set();
        creatures_.clear();
        creature_timer_ = 0.0f;                     // spawn once the area streams in
        all_quests_done_ = false; quests_completed_ = 0; regions_restored_ = 0;
        start_quest(0);
    }

    // ---- M2: disk save/load ----------------------------------------------
    // Only player-EDITED chunks are persisted; pure-procedural chunks regen
    // from the seed (spec §6: region/save persists edits + player + regions).
    bool save(const std::string& dir) {
        std::error_code ec; std::filesystem::create_directories(dir, ec);
        {
            std::ofstream f(dir + "/world.meta", std::ios::binary);
            if (!f) return false;
            f.write("BFWM", 4);
            f.write(reinterpret_cast<const char*>(&seed_), 8);
            std::uint32_t rc = std::uint32_t(region_sat_.size());
            f.write(reinterpret_cast<const char*>(&rc), 4);
            for (auto& [k, v] : region_sat_) {
                f.write(reinterpret_cast<const char*>(&k.x), 4);
                f.write(reinterpret_cast<const char*>(&k.z), 4);
                f.write(reinterpret_cast<const char*>(&v), 4);
            }
        }
        {
            std::ofstream f(dir + "/player.dat", std::ios::binary);
            f.write("BFPL", 4);
            f.write(reinterpret_cast<const char*>(&pos_), sizeof(pos_));
            f.write(reinterpret_cast<const char*>(&yaw_), 4);
            f.write(reinterpret_cast<const char*>(&pitch_), 4);
            std::uint8_t m = std::uint8_t(mode_);
            f.write(reinterpret_cast<const char*>(&m), 1);
            f.write(reinterpret_cast<const char*>(&health_), 4);
            f.write(reinterpret_cast<const char*>(&hunger_), 4);
            f.write(reinterpret_cast<const char*>(&selected_), 1);
            // Full 36-slot inventory (item,count,durability each). Always
            // written so the format is fixed even before content is wired.
            for (int i = 0; i < BF_INVENTORY_SLOTS; ++i) {
                ItemStack s = inv_ ? inv_->get(std::size_t(i)) : ItemStack{};
                f.write(reinterpret_cast<const char*>(&s.item), 2);
                f.write(reinterpret_cast<const char*>(&s.count), 2);
                f.write(reinterpret_cast<const char*>(&s.durability), 2);
            }
        }
        std::vector<std::byte> buf(1u << 20);
        for (ChunkCoord cc : edited_) {
            auto* ch = static_cast<PaletteChunk*>(store_.get(cc));
            if (!ch) continue;
            std::size_t n = ch->serialize(buf);
            if (!n) continue;
            char name[160];
            std::snprintf(name, sizeof(name), "%s/c_%d_%d_%d.chunk", dir.c_str(), cc.x, cc.y, cc.z);
            std::ofstream f(name, std::ios::binary);
            f.write(reinterpret_cast<const char*>(buf.data()), std::streamsize(n));
        }
        return true;
    }

    bool load(const std::string& dir) {
        std::ifstream meta(dir + "/world.meta", std::ios::binary);
        if (!meta) return false;
        char magic[4]; meta.read(magic, 4);
        if (std::memcmp(magic, "BFWM", 4) != 0) return false;
        meta.read(reinterpret_cast<char*>(&seed_), 8);
        if (gen_) gen_->seed(seed_);
        std::uint32_t rc = 0; meta.read(reinterpret_cast<char*>(&rc), 4);
        region_sat_.clear();
        for (std::uint32_t i = 0; i < rc; ++i) {
            RegionKey k{}; float v = 0;
            meta.read(reinterpret_cast<char*>(&k.x), 4);
            meta.read(reinterpret_cast<char*>(&k.z), 4);
            meta.read(reinterpret_cast<char*>(&v), 4);
            region_sat_[k] = v;
        }
        std::ifstream pl(dir + "/player.dat", std::ios::binary);
        if (pl) {
            char m4[4]; pl.read(m4, 4);
            if (std::memcmp(m4, "BFPL", 4) == 0) {
                pl.read(reinterpret_cast<char*>(&pos_), sizeof(pos_));
                pl.read(reinterpret_cast<char*>(&yaw_), 4);
                pl.read(reinterpret_cast<char*>(&pitch_), 4);
                std::uint8_t m = 0; pl.read(reinterpret_cast<char*>(&m), 1); mode_ = bf_game_mode(m);
                pl.read(reinterpret_cast<char*>(&health_), 4);
                pl.read(reinterpret_cast<char*>(&hunger_), 4);
                pl.read(reinterpret_cast<char*>(&selected_), 1);
                for (int i = 0; i < BF_INVENTORY_SLOTS; ++i) {
                    ItemStack s{};
                    pl.read(reinterpret_cast<char*>(&s.item), 2);
                    pl.read(reinterpret_cast<char*>(&s.count), 2);
                    pl.read(reinterpret_cast<char*>(&s.durability), 2);
                    if (inv_) inv_->set(std::size_t(i), s);
                }
            }
        }
        for (auto& e : std::filesystem::directory_iterator(dir)) {
            if (e.path().extension() != ".chunk") continue;
            std::ifstream f(e.path(), std::ios::binary | std::ios::ate);
            std::streamsize sz = f.tellg(); f.seekg(0);
            std::size_t n = std::size_t(sz);
            std::vector<std::byte> buf(n);
            f.read(reinterpret_cast<char*>(buf.data()), sz);
            auto ch = PaletteChunk::deserialize(std::span<const std::byte>(buf.data(), buf.size()));
            if (ch) {
                ChunkCoord cc = ch->coord();
                store_.insert(std::move(ch));
                dirty_.insert(cc); edited_.insert(cc);
            }
        }
        last_center_ = to_chunk(IVec3{ifloor(pos_.x), ifloor(pos_.y), ifloor(pos_.z)});
        first_stream_ = true;
        creatures_.clear();
        creature_timer_ = 0.0f;
        start_quest(0);
        recompute_stream_set();
        return true;
    }

    // ---- flat world (used by the deterministic mine/place test) ----------
    void generate_test_world() {
        const int R = 2;
        for (int cx = -R; cx <= R; ++cx)
        for (int cz = -R; cz <= R; ++cz) {
            ChunkCoord cc{cx, 0, cz};
            auto* ch = static_cast<PaletteChunk*>(store_.get_or_create(cc));
            for (int lx = 0; lx < kChunkDim; ++lx)
            for (int lz = 0; lz < kChunkDim; ++lz)
                for (int ly = 0; ly < 8; ++ly)
                    ch->set(lx, ly, lz, (ly == 7) ? GRASS : (ly >= 4 ? DIRT : STONE));
            dirty_.insert(cc);
            restore_region(cc);
        }
        pos_ = V3{8.0f, 12.0f, 8.0f}; yaw_ = 3.14159f; pitch_ = -0.5f;
    }

    void update(const bf_frame_input& in, double dt) {
        yaw_  += in.look_yaw_delta;
        pitch_ += in.look_pitch_delta;
        const float lim = 1.5533f;
        pitch_ = std::clamp(pitch_, -lim, lim);

        V3 fwd = forward_dir();
        V3 flat = normalize(V3{fwd.x, 0, fwd.z});
        V3 right = normalize(cross(flat, V3{0, 1, 0}));
        float speed = (in.sprint ? 16.0f : 8.0f) * float(dt);
        V3 hmove = flat * (in.move_forward * speed) + right * (in.move_strafe * speed);
        if (mode_ == BF_MODE_CREATIVE) {
            // Creative: free fly, no collision.
            pos_ = pos_ + hmove;
            if (in.jump || in.fly_ascend)   pos_.y += speed;
            if (in.sneak || in.fly_descend) pos_.y -= speed;
            vy_ = 0.0f;
        } else {
            // Survival: walk with AABB voxel collision + gravity + jump.
            pos_.x += hmove.x; if (box_collides(pos_)) pos_.x -= hmove.x;
            pos_.z += hmove.z; if (box_collides(pos_)) pos_.z -= hmove.z;
            if (in.jump && on_ground_) { vy_ = 8.4f; fx(3, player_voxel()); }
            vy_ = std::max(vy_ - 28.0f * float(dt), -64.0f);
            float dy = vy_ * float(dt);
            pos_.y += dy;
            on_ground_ = false;
            if (box_collides(pos_)) { pos_.y -= dy; if (vy_ < 0) on_ground_ = true; vy_ = 0.0f; }
        }

        // Stream as the player crosses chunk boundaries.
        ChunkCoord pc = to_chunk(IVec3{ifloor(pos_.x), ifloor(pos_.y), ifloor(pos_.z)});
        if (!(pc == last_center_) || first_stream_) {
            last_center_ = pc; first_stream_ = false;
            recompute_stream_set();
        }
        stream_tick();

        raycast_target();
        if (mining_ && has_target_) {
            mine_progress_ += float(dt) / break_time(block_at(target_));
            if (mine_progress_ >= 1.0f) {
                BlockId broken = block_at(target_);
                fx(0, target_);                       // break sound + particles
                notify_quest("mine_block", block_name(broken));
                // The broken block drops an item into the inventory (both modes,
                // so you always get the block you mined).
                if (inv_ && blocks_) {
                    const BlockDef* bd = blocks_->by_id(broken);
                    ItemId drop = bd ? bd->drop_item : ItemId(0);
                    if (drop == 0) drop = item_that_places(broken);   // fall back to the block's own item
                    if (drop) {
                        inv_->add(ItemStack{drop, 1, 0xFFFF});
                        fx(7, target_);               // pickup sound
                        notify_quest("collect_item", item_name(drop));
                    }
                }
                set_block_internal(target_, AIR);
                mine_progress_ = 0.0f; raycast_target();
            }
        } else mine_progress_ = 0.0f;

        // View-bob: ramp up while walking on the ground, decay otherwise.
        bool walking = (mode_ == BF_MODE_SURVIVAL) && on_ground_
                     && (std::fabs(in.move_forward) + std::fabs(in.move_strafe) > 0.1f);
        if (walking) {
            bob_phase_ += float(dt) * 9.5f;
            bob_amt_ = std::min(bob_amt_ + float(dt) * 5.0f, 1.0f);
            step_timer_ -= float(dt);
            if (step_timer_ <= 0.0f) { step_timer_ = 0.34f; fx(2, player_voxel()); }   // footstep
        } else { bob_amt_ = std::max(bob_amt_ - float(dt) * 7.0f, 0.0f); step_timer_ = 0.0f; }

        maintain_creatures(float(dt));   // spawn near the player, despawn far away
        update_creatures(float(dt));
    }

    void action(const bf_action& a) {
        switch (a.kind) {
            case BF_ACT_MINE_START: mining_ = true; break;
            case BF_ACT_MINE_STOP:  mining_ = false; mine_progress_ = 0.0f; break;
            case BF_ACT_PLACE: {
                if (!has_target_ || !inv_) break;
                ItemStack sel = inv_->get(selected_);
                if (sel.item == 0) break;
                const ItemDef* idef = items_ ? items_->by_id(sel.item) : nullptr;
                BlockId pb = idef ? idef->places_block : 0;
                if (pb == 0) break;                    // not a placeable item
                if (mode_ == BF_MODE_SURVIVAL && !inv_->remove_item(sel.item, 1)) break;
                set_block_internal(place_, pb);
                fx(1, place_);                        // place sound
                notify_quest("place_block", block_name(pb));
                if (pb == glow_id_) {
                    notify_quest("light_beacon", "");
                    ChunkCoord rc = to_chunk(place_);
                    if (region_sat(rc) < 0.99f) { ++regions_restored_; notify_quest("restore_region", ""); }
                    restore_region(rc);
                }
                break;
            }
            case BF_ACT_CRAFT:      craft_index(a.arg_i); break;
            case BF_ACT_INV_OPEN:   inv_open_ = true;  break;
            case BF_ACT_INV_CLOSE:  inv_open_ = false; break;
            case BF_ACT_ATTACK: {                  // calm -> puff away (no death)
                int idx = creature_in_view();
                if (idx >= 0) {
                    Creature& cr = creatures_[std::size_t(idx)];
                    if (--cr.hp <= 0) {
                        bool boss = cr.is_boss; std::string nm = cr.name;
                        creatures_.erase(creatures_.begin() + std::ptrdiff_t(idx));
                        ++creatures_calmed_;
                        fx(5, player_voxel());            // befriend sparkle
                        notify_quest(boss ? "calm_boss" : "befriend_creature", nm);
                    }
                }
                break;
            }
            case BF_ACT_INTERACT: {                // befriend
                int idx = creature_in_view();
                if (idx >= 0) {
                    creatures_[std::size_t(idx)].friendly = true; ++creatures_befriended_;
                    fx(5, player_voxel());
                    notify_quest("befriend_creature", creatures_[std::size_t(idx)].name);
                }
                break;
            }
            case BF_ACT_HOTBAR_SELECT:
                if (a.arg_i >= 0 && a.arg_i < BF_HOTBAR_SLOTS) selected_ = std::uint8_t(a.arg_i);
                break;
            case BF_ACT_HOTBAR_SCROLL: {
                int s = (int(selected_) + (a.arg_i >= 0 ? 1 : -1) + BF_HOTBAR_SLOTS) % BF_HOTBAR_SLOTS;
                selected_ = std::uint8_t(s); break;
            }
            case BF_ACT_MODE_TOGGLE:
                mode_ = (mode_ == BF_MODE_CREATIVE) ? BF_MODE_SURVIVAL : BF_MODE_CREATIVE; break;
            default: break;
        }
    }

    void build_frame(bf_render_frame& out, std::vector<bf_draw_item>& draws, double clock) {
        remesh_dirty();
        draws.clear();
        std::vector<bf_region_dim> regions; // built lazily below
        for (auto& [cc, rec] : meshes_) {
            if (!rec.has_buffers || rec.index_count == 0) continue;
            bf_draw_item d{};
            d.vertex_buffer = rec.vbuf.handle;
            d.index_buffer  = rec.ibuf.handle;
            d.index_count   = rec.index_count;
            d.chunk_origin  = bf_ivec3{cc.x * kChunkDim, cc.y * kChunkDim, cc.z * kChunkDim};
            d.dim_saturation = region_sat(cc);
            draws.push_back(d);
        }

        V3 fwd = forward_dir();
        V3 flat = normalize(V3{fwd.x, 0, fwd.z});
        V3 rightv = normalize(cross(flat, V3{0, 1, 0}));
        float bobY = std::sin(bob_phase_ * 2.0f) * 0.06f * bob_amt_;
        float bobX = std::cos(bob_phase_) * 0.045f * bob_amt_;
        V3 eye = pos_ + V3{0, bobY, 0} + rightv * bobX;
        V3 ctr = eye + fwd;
        M4 view = look_at(eye, ctr, V3{0, 1, 0});
        M4 proj = perspective(1.20f, 1.6f, 0.05f, 1024.0f);
        std::memcpy(out.camera.view.m, view.m, sizeof(float) * 16);
        std::memcpy(out.camera.proj.m, proj.m, sizeof(float) * 16);
        out.camera.position = bf_vec3{eye.x, eye.y, eye.z};
        out.camera.forward  = bf_vec3{fwd.x, fwd.y, fwd.z};
        float t = day_time(clock);
        out.camera.time_of_day = t;
        float ang = t * 6.2831853f;
        out.camera.sun_dir = bf_vec3{std::cos(ang) * 0.6f, -std::sin(ang) - 0.25f, 0.35f};
        out.camera.underwater =
            (block_at(IVec3{ifloor(eye.x), ifloor(eye.y), ifloor(eye.z)}) == WATER) ? 1.0f : 0.0f;
        out.interp_alpha = 0.0f;
        out.draws = draws.data();
        out.draw_count = std::uint32_t(draws.size());
        out.regions = nullptr; out.region_count = 0;

        // Creatures (ABI v2 entity draws).
        entities_.clear();
        for (auto& cr : creatures_) {
            V3 col = cr.friendly ? V3{1.0f, 0.92f, 0.55f} : cr.color;
            bf_entity_draw e{};
            e.position = bf_vec3{cr.pos.x, cr.pos.y, cr.pos.z};
            e.yaw = cr.yaw;
            e.color = bf_vec3{col.x, col.y, col.z};
            e.scale = cr.scale;
            e.kind = cr.is_boss ? 4u : std::uint32_t(cr.shape & 3);   // 0..3 animals, 4 boss
            e.sat = region_sat(to_chunk(IVec3{ifloor(cr.pos.x), ifloor(cr.pos.y), ifloor(cr.pos.z)}));
            entities_.push_back(e);
        }
        // Other players (co-op) drawn as taller avatars.
        for (const auto& a : remote_avatars_) entities_.push_back(a);
        out.entities = entities_.data();
        out.entity_count = std::uint32_t(entities_.size());

        fill_hud(out.hud);
    }

    bf_game_mode mode() const { return mode_; }

    // ---- test/debug seams --------------------------------------------------
    void    debug_set_camera(float px, float py, float pz, float yaw, float pitch) {
        pos_ = V3{px, py, pz}; yaw_ = yaw; pitch_ = pitch;
    }
    BlockId debug_block_at(int x, int y, int z) const { return block_at(IVec3{x, y, z}); }
    void    debug_edit(int x, int y, int z, BlockId b) { set_block_internal(IVec3{x, y, z}, b); }
    bool    debug_has_target() const { return has_target_; }
    void    debug_set_selected(std::uint8_t s) { selected_ = s; }
    std::size_t debug_resident_chunks() const { return store_.resident_count(); }
    float   debug_region_sat(int cx, int cz) const { return region_sat(ChunkCoord{cx, 0, cz}); }
    ItemId  debug_item_id(const char* n) const { return item_id_by_name(n); }
    int     debug_item_count(ItemId id) const { return inv_ ? int(inv_->count_item(id)) : 0; }
    void    debug_give(ItemId id, std::uint16_t n) { if (inv_) inv_->add(ItemStack{id, n, 0xFFFF}); }
    void    debug_clear_inventory() {
        if (inv_) for (int i = 0; i < BF_INVENTORY_SLOTS; ++i) inv_->set(std::size_t(i), ItemStack{});
    }
    int     debug_creature_count() const { return int(creatures_.size()); }
    int     debug_quests_completed() const { return quests_completed_; }
    std::uint32_t debug_active_quest() const {
        return (extra_ && active_quest_ < extra_->quests().size() && !all_quests_done_)
             ? extra_->quests()[active_quest_].id : 0u;
    }
    void    debug_notify(const char* trig, const char* target) { notify_quest(trig, target); }
    bool    debug_aim_at_creature0() {
        if (creatures_.empty()) return false;
        V3 cp = creatures_[0].pos + V3{0, 0.5f, 0};
        pos_ = cp + V3{0, 1.0f, 3.0f};            // stand within reach
        V3 d = normalize(cp - pos_);
        pitch_ = std::asin(std::clamp(d.y, -0.999f, 0.999f));
        yaw_ = std::atan2(d.x, d.z);
        return true;
    }

private:
    // Start in bright morning (+0.30) and cycle slowly (~12 min/day).
    static float day_time(double clock) { return float(std::fmod(clock * 0.0014 + 0.30, 1.0)); }

    V3 forward_dir() const {
        return normalize(V3{ std::cos(pitch_) * std::sin(yaw_), std::sin(pitch_),
                             std::cos(pitch_) * std::cos(yaw_) });
    }
    // Mining time from block hardness + the selected tool's tier (Track J).
    float break_time(BlockId b) const {
        if (b == AIR) return 1e9f;
        const BlockDef* bd = blocks_ ? blocks_->by_id(b) : nullptr;
        float hardness = bd ? float(bd->hardness) : 6.0f;
        std::uint8_t req = bd ? bd->required_tier : std::uint8_t(0);
        float t = 0.15f + hardness * 0.05f;
        if (inv_ && items_) {
            const ItemDef* it = items_->by_id(inv_->get(selected_).item);
            std::uint8_t tier = it ? it->tool_tier : std::uint8_t(0);
            if (tier > 0 && tier >= req) t *= 0.35f;          // right tool: faster
            else if (req > 0 && tier < req) t *= 4.0f;        // wrong tool: slow
        }
        return t;
    }
    // Recipe indices whose ingredients are all in the inventory now (cap 8).
    void craftable_recipes(std::vector<std::uint32_t>& out) const {
        out.clear();
        if (!content_ || !inv_) return;
        for (std::uint32_t i = 0; i < content_->recipe_count() && out.size() < 8; ++i) {
            const RecipeEntry& r = content_->recipe(i);
            if (r.pattern.empty() || r.result_item == 0) continue;
            std::unordered_map<ItemId, int> need;
            for (ItemId it : r.pattern) if (it != 0) need[it]++;
            bool ok = true;
            for (auto& [it, n] : need) if (int(inv_->count_item(it)) < n) { ok = false; break; }
            if (ok) out.push_back(i);
        }
    }
    // Craft a specific craftable index, or the first available if idx < 0.
    void craft_index(int idx) {
        if (!content_ || !inv_ || !craft_) return;
        std::vector<std::uint32_t> cr; craftable_recipes(cr);
        if (idx < 0) { if (!cr.empty()) idx = 0; else return; }
        if (std::size_t(idx) >= cr.size()) return;
        const RecipeEntry& r = content_->recipe(cr[std::size_t(idx)]);
        if (craft_->commit(*inv_, std::span<const ItemId>(r.pattern.data(), r.pattern.size()), r.grid_size))
            fx(4, player_voxel());
    }

    // ---- quest engine (Track J, M5) ---------------------------------------
    std::string block_name(BlockId b) const {
        const BlockDef* d = blocks_ ? blocks_->by_id(b) : nullptr; return d ? std::string(d->name) : std::string();
    }
    std::string item_name(ItemId i) const {
        const ItemDef* d = items_ ? items_->by_id(i) : nullptr; return d ? std::string(d->name) : std::string();
    }
    ItemId item_that_places(BlockId b) const {
        if (!items_ || b == 0) return 0;
        for (ItemId id = 1; id < 400; ++id) {
            const ItemDef* d = items_->by_id(id);
            if (d && d->places_block == b) return d->id;
        }
        return 0;
    }
    void start_quest(std::size_t i) {
        active_quest_ = i; obj_progress_.clear();
        if (extra_ && i < extra_->quests().size())
            obj_progress_.assign(extra_->quests()[i].objectives.size(), 0u);
    }
    bool quest_done(const QuestDefX& q) const {
        for (std::size_t i = 0; i < q.objectives.size(); ++i)
            if (obj_progress_[i] < q.objectives[i].count) return false;
        return true;
    }
    void notify_quest(const std::string& trig, const std::string& target) {
        if (!extra_ || active_quest_ >= extra_->quests().size()) return;
        const QuestDefX& q = extra_->quests()[active_quest_];
        if (obj_progress_.size() != q.objectives.size()) return;
        bool changed = false;
        for (std::size_t i = 0; i < q.objectives.size(); ++i) {
            const auto& o = q.objectives[i];
            if (o.trigger == trig && (o.target.empty() || o.target == target) && obj_progress_[i] < o.count) {
                ++obj_progress_[i]; changed = true;
            }
        }
        if (changed && quest_done(q)) {
            if (inv_) for (auto& [item, cnt] : q.rewards) {
                ItemId id = item_id_by_name(item.c_str());
                if (id) inv_->add(ItemStack{id, std::uint16_t(cnt), 0xFFFF});
            }
            ++quests_completed_;
            fx(6, player_voxel());                     // quest fanfare
            if (active_quest_ + 1 < extra_->quests().size()) start_quest(active_quest_ + 1);
            else all_quests_done_ = true;
        }
    }

    // ---- creatures (Track G, M3) ------------------------------------------
    float rand01() { rng_ = rng_ * 1664525u + 1013904223u; return float(rng_ >> 8) / 16777216.0f; }

    static constexpr int kNoFloor = -1000000;
    // Standable surface (top of the first solid block) scanning DOWN from yTop,
    // or kNoFloor if none found (e.g. chunk not resident) — callers must NOT
    // treat "no floor" as ground, or entities drift upward.
    int floor_below(int x, int yTop, int z) const {
        for (int y = yTop; y > yTop - 80; --y)
            if (block_at(IVec3{x, y, z}) != AIR) return y + 1;
        return kNoFloor;
    }

    // Is a block solid for player collision? (air + water are passable.)
    bool collide_solid(int x, int y, int z) const {
        BlockId b = block_at(IVec3{x, y, z});
        return b != AIR && b != WATER;
    }
    // Player AABB (0.6 wide, ~1.8 tall; pos_ is the eye). Returns true if it
    // overlaps any solid voxel.
    bool box_collides(V3 p) const {
        const float hw = 0.3f;
        int x0 = ifloor(p.x - hw), x1 = ifloor(p.x + hw);
        int z0 = ifloor(p.z - hw), z1 = ifloor(p.z + hw);
        int y0 = ifloor(p.y - 1.6f), y1 = ifloor(p.y + 0.2f);   // feet..head
        for (int x = x0; x <= x1; ++x)
            for (int y = y0; y <= y1; ++y)
                for (int z = z0; z <= z1; ++z)
                    if (collide_solid(x, y, z)) return true;
        return false;
    }

    static V3 hue_rgb(float h) {
        auto cl = [](float x) { return x < 0 ? 0.f : (x > 1 ? 1.f : x); };
        float r = std::fabs(std::fmod(h * 6 + 0, 6.f) - 3) - 1;
        float g = std::fabs(std::fmod(h * 6 + 4, 6.f) - 3) - 1;
        float b = std::fabs(std::fmod(h * 6 + 2, 6.f) - 3) - 1;
        return V3{0.45f + 0.5f * cl(r), 0.45f + 0.5f * cl(g), 0.45f + 0.5f * cl(b)};
    }
    static V3 color_for(const std::string& disp, std::uint16_t id) {
        float h = std::fmod(float(id) * 0.6180339f, 1.0f);
        if (disp == "night_gentle") h = 0.55f + 0.18f * h;     // cool blues/purples
        else if (disp == "boss")    h = 0.05f + 0.08f * h;     // warm, non-scary
        return hue_rgb(h);
    }
    // Spawn one creature on real ground in a ring around the player; returns
    // false if no ground was found there yet (try again next tick).
    bool spawn_ring_creature(bool boss, float rmin, float rmax) {
        float ang = rand01() * 6.2831853f, r = rmin + rand01() * (rmax - rmin);
        float cx = pos_.x + std::cos(ang) * r, cz = pos_.z + std::sin(ang) * r;
        int gy = floor_below(ifloor(cx), int(pos_.y) + 30, ifloor(cz));
        if (gy == kNoFloor) return false;
        Creature c;
        c.pos = V3{cx, float(gy), cz}; c.yaw = rand01() * 6.2831853f;
        c.wander = 1.0f + rand01() * 2.0f; c.is_boss = boss;
        if (extra_ && !extra_->creatures().empty()) {
            std::vector<const CreatureDefX*> pool;
            for (auto& d : extra_->creatures()) if ((d.disposition == "boss") == boss) pool.push_back(&d);
            if (!pool.empty()) {
                const CreatureDefX* d = pool[std::size_t(rand01() * float(pool.size())) % pool.size()];
                c.name = std::string(d->name);
                c.color = color_for(boss ? "boss" : d->disposition, d->id);
                c.speed = boss ? d->move_speed * 0.7f : d->move_speed;
                c.shape = int(d->id) % 4;            // model variant from the def
            }
        } else {
            c.color = color_for(boss ? "boss" : "passive", std::uint16_t(creatures_.size() + 1));
            c.speed = boss ? 1.2f : 1.6f; c.name = boss ? "guardian" : "critter";
        }
        c.scale = boss ? 2.0f : 0.8f; c.hp = boss ? 4 : 1;
        creatures_.push_back(c);
        return true;
    }
    // Keep a population near the player: despawn far ones, spawn fresh ones in a
    // ring just out of view as you explore (fixes "same animals follow forever").
    void maintain_creatures(float dt) {
        if (!gen_ || store_.resident_count() < 20) return;
        creature_timer_ -= dt;
        if (creature_timer_ > 0) return;
        const float kDespawn2 = 90.0f * 90.0f;
        creatures_.erase(std::remove_if(creatures_.begin(), creatures_.end(),
            [&](const Creature& c) {
                float dx = c.pos.x - pos_.x, dz = c.pos.z - pos_.z;
                return (dx*dx + dz*dz) > kDespawn2;
            }), creatures_.end());
        int ambient = 0, bosses = 0;
        for (auto& c : creatures_) (c.is_boss ? bosses : ambient)++;
        // Fill the area quickly at first (small timer), then top up slowly.
        creature_timer_ = (ambient < 4) ? 0.08f : 0.5f;
        // Spawn in view range so you actually meet them.
        if (ambient < 9)      spawn_ring_creature(false, 8.0f, 26.0f);
        else if (bosses < 2)  spawn_ring_creature(true,  18.0f, 40.0f);
    }

    void update_creatures(float dt) {
        for (auto& c : creatures_) {
            c.wander -= dt;
            V3 toPlayer = pos_ - c.pos;
            if (c.friendly) {
                // follow the player when not too close
                float d = std::sqrt(dot(toPlayer, toPlayer));
                if (d > 2.5f) c.yaw = std::atan2(toPlayer.x, toPlayer.z);
            } else if (c.wander <= 0.0f) {
                c.yaw = rand01() * 6.2831853f;
                c.wander = 1.5f + rand01() * 2.5f;
            }
            V3 dir{std::sin(c.yaw), 0, std::cos(c.yaw)};
            V3 next = c.pos + dir * (c.speed * dt);
            // turn away from walls
            if (block_at(IVec3{ifloor(next.x), ifloor(next.y), ifloor(next.z)}) != AIR) {
                c.yaw += 2.4f; c.wander = 0.5f;
            } else {
                c.pos.x = next.x; c.pos.z = next.z;
            }
            // gravity, then land on the floor below (never pushed upward).
            c.vy -= 24.0f * dt;
            c.pos.y += c.vy * dt;
            int fy = floor_below(ifloor(c.pos.x), int(std::floor(c.pos.y)) + 1, ifloor(c.pos.z));
            if (fy != kNoFloor && c.pos.y <= float(fy)) { c.pos.y = float(fy); c.vy = 0.0f; }
            else if (fy == kNoFloor) c.vy = 0.0f;   // no ground yet (streaming) -> hover
        }
    }

    // The creature most in line with the camera within reach (or -1).
    int creature_in_view() {
        V3 o = pos_, d = forward_dir();
        int best = -1; float bestT = 5.0f;
        for (std::size_t i = 0; i < creatures_.size(); ++i) {
            V3 cc = creatures_[i].pos + V3{0, 0.5f, 0};
            V3 rel = cc - o;
            float t = dot(rel, d);
            if (t < 0 || t > bestT) continue;
            V3 closest = o + d * t;
            V3 off = cc - closest;
            if (dot(off, off) < 0.7f) { bestT = t; best = int(i); }
        }
        return best;
    }

    BlockId block_at(IVec3 w) const {
        ChunkCoord cc = to_chunk(w);
        auto* ch = const_cast<ChunkStore&>(store_).get(cc);
        return ch ? ch->get(mod16(w.x), mod16(w.y), mod16(w.z)) : AIR;
    }
    void set_block_internal(IVec3 w, BlockId b, bool from_remote = false) {
        ChunkCoord cc = to_chunk(w);
        store_.get_or_create(cc)->set(mod16(w.x), mod16(w.y), mod16(w.z), b);
        dirty_.insert(cc);
        edited_.insert(cc);    // player-edited -> persisted on save
        if (!from_remote && edit_cb_) edit_cb_(w, b);   // replicate to peers

        const IVec3 dirs[6] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
        for (auto d : dirs) {
            ChunkCoord nc = to_chunk(IVec3{w.x + d.x, w.y + d.y, w.z + d.z});
            if (!(nc == cc) && store_.is_resident(nc)) dirty_.insert(nc);
        }
    }

    // ---- streaming ---------------------------------------------------------
    void recompute_stream_set() {
        gen_queue_.clear();
        ChunkCoord c = last_center_;
        for (int cy = CY_MIN; cy <= CY_MAX; ++cy)
        for (int dx = -STREAM_R; dx <= STREAM_R; ++dx)
        for (int dz = -STREAM_R; dz <= STREAM_R; ++dz) {
            ChunkCoord cc{c.x + dx, cy, c.z + dz};
            if (!store_.is_resident(cc)) gen_queue_.push_back(cc);
        }
        // nearest-first so the world fills in around the player
        std::sort(gen_queue_.begin(), gen_queue_.end(), [&](ChunkCoord a, ChunkCoord b) {
            return dist2(a, c) < dist2(b, c);
        });
        evict_far();
    }
    static long dist2(ChunkCoord a, ChunkCoord c) {
        long dx = a.x - c.x, dz = a.z - c.z; return dx*dx + dz*dz;
    }
    void evict_far() {
        std::vector<ChunkCoord> drop;
        for (auto& [cc, rec] : meshes_) {
            if (std::abs(cc.x - last_center_.x) > STREAM_R + 1 ||
                std::abs(cc.z - last_center_.z) > STREAM_R + 1) drop.push_back(cc);
        }
        for (auto cc : drop) {
            auto& rec = meshes_[cc];
            if (rec.has_buffers && has_alloc_) {
                alloc_.free_(alloc_.user, rec.vbuf.handle);
                alloc_.free_(alloc_.user, rec.ibuf.handle);
            }
            meshes_.erase(cc);
            store_.evict(cc);
        }
    }
    void stream_tick() {
        if (!gen_) return;
        int made = 0;
        while (!gen_queue_.empty() && made < GEN_BUDGET) {
            ChunkCoord cc = gen_queue_.back(); gen_queue_.pop_back();
            if (store_.is_resident(cc)) continue;
            auto ch = std::make_unique<PaletteChunk>(cc);
            gen_->generate(cc, *ch);
            // Skip pure-air chunks (above terrain): they cost nothing as "not
            // resident" and block_at() already returns AIR for them.
            if (ch->is_uniform() && ch->get(0,0,0) == AIR) { ++made; continue; }
            store_.insert(std::move(ch));
            dirty_.insert(cc);
            ++made;
        }
    }

    void remesh_dirty() {
        if (!has_alloc_ || dirty_.empty()) return;
        ensure_scratch();
        // Remesh nearest dirty chunks first, budgeted per frame.
        std::vector<ChunkCoord> todo(dirty_.begin(), dirty_.end());
        std::sort(todo.begin(), todo.end(), [&](ChunkCoord a, ChunkCoord b) {
            return dist2(a, last_center_) < dist2(b, last_center_);
        });
        int done = 0;
        for (ChunkCoord cc : todo) {
            if (done >= MESH_BUDGET) break;
            dirty_.erase(cc);
            if (!store_.is_resident(cc)) continue;
            ++done;
            // Light before meshing (the mesher reads per-voxel light). If a
            // boundary value changed, re-dirty neighbours so light bleeds across
            // chunk seams and settles over the next few frames (Track F).
            bool changed = FloodLighting::light_chunk(cc, store_);
            if (changed) {
                const IVec3 dirs[6] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
                for (auto d : dirs) {
                    ChunkCoord nc{cc.x + d.x, cc.y + d.y, cc.z + d.z};
                    if (store_.is_resident(nc)) dirty_.insert(nc);
                }
            }
            remesh_one(cc);
        }
    }
    void remesh_one(ChunkCoord cc) {
        MeshRec& rec = meshes_[cc];
        std::span<std::byte> vs(vscratch_.data(), vscratch_.size());
        std::span<std::byte> is(iscratch_.data(), iscratch_.size());
        MeshResult mr = mesher_.mesh(cc, store_, vs, is, false);
        if (rec.has_buffers) {
            alloc_.free_(alloc_.user, rec.vbuf.handle);
            alloc_.free_(alloc_.user, rec.ibuf.handle);
            rec.has_buffers = false;
        }
        if (mr.empty || mr.index_count == 0) { rec.index_count = 0; return; }
        // Tight allocation: exact size, not the worst case (memory, spec §10).
        bf_gpu_buffer vb = alloc_.alloc(alloc_.user, mr.vertex_bytes);
        bf_gpu_buffer ib = alloc_.alloc(alloc_.user, mr.index_bytes);
        if (!vb.contents || !ib.contents) { rec.index_count = 0; return; }
        std::memcpy(vb.contents, vscratch_.data(), mr.vertex_bytes);
        std::memcpy(ib.contents, iscratch_.data(), mr.index_bytes);
        rec.vbuf = vb; rec.ibuf = ib; rec.index_count = mr.index_count; rec.has_buffers = true;
    }
    void ensure_scratch() {
        if (vscratch_.empty()) {
            vscratch_.resize(mesher_.max_vertex_bytes());
            iscratch_.resize(mesher_.max_index_bytes());
        }
    }

    void raycast_target() {
        has_target_ = false;
        V3 o = pos_, d = forward_dir();
        IVec3 v{ ifloor(o.x), ifloor(o.y), ifloor(o.z) };
        IVec3 step{ d.x > 0 ? 1 : -1, d.y > 0 ? 1 : -1, d.z > 0 ? 1 : -1 };
        V3 td{ d.x != 0 ? std::fabs(1.0f / d.x) : 1e30f, d.y != 0 ? std::fabs(1.0f / d.y) : 1e30f,
               d.z != 0 ? std::fabs(1.0f / d.z) : 1e30f };
        auto frac = [](float f, int s){ float fl = std::floor(f); return s > 0 ? (fl + 1 - f) : (f - fl); };
        V3 tmax{ td.x * frac(o.x, step.x), td.y * frac(o.y, step.y), td.z * frac(o.z, step.z) };
        IVec3 prev = v;
        for (int i = 0; i < 128; ++i) {
            if (block_at(v) != AIR) { has_target_ = true; target_ = v; place_ = prev; return; }
            prev = v;
            if (tmax.x < tmax.y && tmax.x < tmax.z) { v.x += step.x; tmax.x += td.x; }
            else if (tmax.y < tmax.z)               { v.y += step.y; tmax.y += td.y; }
            else                                    { v.z += step.z; tmax.z += td.z; }
        }
    }

    // ---- Dim regions -------------------------------------------------------
    static RegionKey region_key(ChunkCoord cc) {
        return RegionKey{ floordiv(cc.x, kRegionChunks), floordiv(cc.z, kRegionChunks) };
    }
    float region_sat(ChunkCoord cc) const {
        auto it = region_sat_.find(region_key(cc));
        return it == region_sat_.end() ? DIM_SAT : it->second;
    }
    void restore_region(ChunkCoord cc) { region_sat_[region_key(cc)] = 1.0f; }

    void fill_hud(bf_hud_state& h) {
        h = bf_hud_state{};
        h.mode = mode_; h.selected_slot = selected_;
        h.inventory_open = inv_open_ ? 1 : 0;
        h.health = health_; h.hunger = hunger_;
        if (inv_) {
            for (int i = 0; i < BF_HOTBAR_SLOTS; ++i) {
                ItemStack s = inv_->get(std::size_t(i));
                h.hotbar[i].item = s.item; h.hotbar[i].count = s.count; h.hotbar[i].durability = s.durability;
            }
            for (int i = 0; i < BF_INVENTORY_SLOTS; ++i) {
                ItemStack s = inv_->get(std::size_t(i));
                h.inventory[i].item = s.item; h.inventory[i].count = s.count; h.inventory[i].durability = s.durability;
            }
            std::vector<std::uint32_t> cr; craftable_recipes(cr);
            h.craftable_count = std::uint8_t(cr.size());
            for (std::size_t i = 0; i < cr.size(); ++i) {
                const RecipeEntry& r = content_->recipe(cr[i]);
                h.craftable[i].item = r.result_item;
                h.craftable[i].count = r.result_count;
                h.craftable[i].durability = 0xFFFF;
            }
        }
        // Active quest from content (Track J quest engine).
        if (extra_ && !all_quests_done_ && active_quest_ < extra_->quests().size()
            && obj_progress_.size() == extra_->quests()[active_quest_].objectives.size()) {
            const QuestDefX& q = extra_->quests()[active_quest_];
            h.active_quest_id = q.id;
            std::strncpy(h.quest_title, q.title.c_str(), sizeof(h.quest_title) - 1);
            std::uint32_t done = 0, total = 0; const char* objtext = "";
            for (std::size_t i = 0; i < q.objectives.size(); ++i) {
                total += q.objectives[i].count;
                done += std::min(obj_progress_[i], q.objectives[i].count);
                if (obj_progress_[i] < q.objectives[i].count && objtext[0] == 0)
                    objtext = q.objectives[i].text.c_str();
            }
            std::strncpy(h.quest_objective, objtext[0] ? objtext : "...", sizeof(h.quest_objective) - 1);
            h.quest_progress = total ? float(done) / float(total) : 0.0f;
        } else {
            h.active_quest_id = 0;
            std::strncpy(h.quest_title, all_quests_done_ ? "The color is back!" : "Bring back the color",
                         sizeof(h.quest_title) - 1);
            std::strncpy(h.quest_objective, all_quests_done_ ? "You restored the world!"
                                                            : "Place a glow block in the grey Dim",
                         sizeof(h.quest_objective) - 1);
            h.quest_progress = all_quests_done_ ? 1.0f : 0.0f;
        }
        h.has_target = has_target_ ? 1 : 0;
        h.target_block = bf_ivec3{target_.x, target_.y, target_.z};
        h.mine_progress = mine_progress_;
    }

    static int ifloor(float f) { return int(std::floor(f)); }
    IVec3 player_voxel() const { return IVec3{ifloor(pos_.x), ifloor(pos_.y), ifloor(pos_.z)}; }
    static ChunkCoord to_chunk(IVec3 w) {
        return ChunkCoord{ floordiv(w.x, kChunkDim), floordiv(w.y, kChunkDim), floordiv(w.z, kChunkDim) };
    }
    static int floordiv(int a, int b) { int q = a / b; if ((a % b) && ((a < 0) != (b < 0))) --q; return q; }
    static int mod16(int a) { int m = a % kChunkDim; return m < 0 ? m + kChunkDim : m; }

    IMesher&    mesher_;
    IWorldGen*  gen_{nullptr};
    ChunkStore  store_;
    bf_gpu_allocator alloc_{};
    bool        has_alloc_{false};
    std::unordered_map<ChunkCoord, MeshRec, ChunkCoordHash> meshes_;
    std::unordered_set<ChunkCoord, ChunkCoordHash> dirty_;
    std::unordered_map<RegionKey, float, RegionKeyHash> region_sat_;
    std::unordered_set<ChunkCoord, ChunkCoordHash> edited_;   // player-edited (persisted)
    std::vector<ChunkCoord> gen_queue_;
    std::vector<std::byte>  vscratch_, iscratch_;
    ChunkCoord  last_center_{0, 0, 0};
    bool        first_stream_{true};
    std::uint64_t seed_{0};

    V3            pos_{0, 12, 0};
    float         yaw_{0.0f}, pitch_{0.0f};
    bf_game_mode  mode_{BF_MODE_CREATIVE};
    float         health_{20.0f}, hunger_{20.0f};
    std::uint8_t  selected_{0};
    bool          mining_{false};
    float         vy_{0.0f};            // vertical velocity (survival walk)
    bool          on_ground_{false};
    float         bob_phase_{0.0f}, bob_amt_{0.0f};   // view bob

    // Track J content + gameplay state.
    const ContentRegistry*        content_{nullptr};
    const IBlockRegistry*         blocks_{nullptr};
    const IItemRegistry*          items_{nullptr};
    const IRecipeBook*            recipes_{nullptr};
    std::optional<Inventory>      inv_;
    std::optional<CraftingSystem> craft_;
    BlockId                       glow_id_{GLOW};
    bool                          inv_open_{false};

    // Creatures + quest state (M3).
    std::vector<Creature>         creatures_;
    std::vector<bf_entity_draw>   entities_;
    float                         creature_timer_{0.0f};
    std::uint32_t                 rng_{0x1234567u};
    int                           regions_restored_{0};
    int                           creatures_befriended_{0};
    int                           creatures_calmed_{0};

    // Content roster + quest engine (Track J, M5).
    const ContentExtra*           extra_{nullptr};
    std::size_t                   active_quest_{0};
    std::vector<std::uint32_t>    obj_progress_;
    bool                          all_quests_done_{false};
    int                           quests_completed_{0};

    // Co-op (Track H).
    std::function<void(IVec3, BlockId)> edit_cb_;
    std::function<void(int, IVec3)>     fx_cb_;          // audio/particles
    float                               step_timer_{0.0f};
    std::vector<bf_entity_draw>         remote_avatars_;
    float         mine_progress_{0.0f};
    bool          has_target_{false};
    IVec3         target_{}, place_{};
};

} // namespace bf
