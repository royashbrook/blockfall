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
#include <set>
#include <tuple>
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
    int   hp{3};            // hits remaining (bosses/monsters take more)
    bool  is_boss{false};
    bool  friendly{false};
    bool  hostile{false};   // night monster: chases + hurts the player (kind 5)
    bool  skittish{false};  // flees the player (rabbits/foxes)
    float atk_cd{0};        // cooldown between hits on the player
    float hit_flash{0};     // brief white flash when the player hits it
    float wander{0};
    int   shape{0};         // renderer model variant (0..3 animals)
    std::string name;       // content creature name (quest befriend target)
};

// A block in mid-air: undermined sand/gravel, or logs from a felled tree.
// Rendered as entity kind 6 (a tumbling cube). On landing it either becomes a
// solid block again (gravity) or drops into the inventory (tree logs).
struct FallingBlock {
    V3      pos{};
    V3      vel{};
    float   spin{0};
    float   spin_rate{0};
    BlockId block{0};
    V3      color{0.6f, 0.6f, 0.6f};
    bool    as_item{false};   // true: drop as item on land; false: re-place as a block
    float   life{6.0f};
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
    // Streaming work is synchronous on the frame thread, so a big per-frame
    // budget = a big hitch when you cross a chunk boundary. Smaller budgets
    // spread the same work over more frames → much smoother 1%-low (pop-in is
    // marginally slower, which is the right trade for kids).
    static constexpr int    GEN_BUDGET   = 6;      // chunks generated per frame
    static constexpr int    MESH_BUDGET  = 4;      // chunks remeshed per frame

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
    void set_fx_callback(std::function<void(int, IVec3, int)> cb) { fx_cb_ = std::move(cb); }
    void fx(int code, IVec3 p, int extra = 0) { if (fx_cb_) fx_cb_(code, p, extra); }
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
        beacon_id_ = block_id_by_name("beacon_block");
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
            // Coal + sticks in the backpack so the very first quest ("craft 4
            // torches") is doable the moment you open crafting — first action
            // succeeds instead of dead-ending on coal you don't know to mine.
            if (ItemId coal  = item_id_by_name("coal"))  inv_->set(9,  ItemStack{coal,  2, 0xFFFF});
            if (ItemId stick = item_id_by_name("stick")) inv_->set(10, ItemStack{stick, 2, 0xFFFF});
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
        // Eye 3.2 above the surface block so the FEET (eye-1.6) clear the top
        // block and the player settles onto it, instead of spawning embedded
        // (which left you "stuck" until you jumped).
        pos_ = V3{0.5f, float(surface) + 3.2f, 0.5f};
        spawn_ = pos_;                                  // respawn here on defeat
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
            // Quest + achievement progress (tagged so older saves load gracefully).
            f.write("BFQ1", 4);
            std::uint32_t aq = std::uint32_t(active_quest_);
            std::uint32_t qc = std::uint32_t(quests_completed_);
            std::uint8_t  aqd = all_quests_done_ ? 1 : 0;
            f.write(reinterpret_cast<const char*>(&aq), 4);
            f.write(reinterpret_cast<const char*>(&qc), 4);
            f.write(reinterpret_cast<const char*>(&aqd), 1);
            std::uint32_t opn = std::uint32_t(obj_progress_.size());
            f.write(reinterpret_cast<const char*>(&opn), 4);
            for (std::uint32_t v : obj_progress_) f.write(reinterpret_cast<const char*>(&v), 4);
            std::uint32_t an = std::uint32_t(kAchievementCount);
            f.write(reinterpret_cast<const char*>(&an), 4);
            for (int i = 0; i < kAchievementCount; ++i) {
                std::uint8_t dn = ach_done_[i] ? 1 : 0;
                std::int32_t pr = ach_progress_[i];
                f.write(reinterpret_cast<const char*>(&dn), 1);
                f.write(reinterpret_cast<const char*>(&pr), 4);
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
        bool quest_loaded = false;
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
                // Quest + achievement progress (only present in newer saves).
                char qt[4] = {}; pl.read(qt, 4);
                if (pl && std::memcmp(qt, "BFQ1", 4) == 0) {
                    std::uint32_t aq = 0, qc = 0, opn = 0; std::uint8_t aqd = 0;
                    pl.read(reinterpret_cast<char*>(&aq), 4);
                    pl.read(reinterpret_cast<char*>(&qc), 4);
                    pl.read(reinterpret_cast<char*>(&aqd), 1);
                    pl.read(reinterpret_cast<char*>(&opn), 4);
                    start_quest(std::size_t(aq));   // sizes obj_progress_ for this quest
                    for (std::uint32_t i = 0; i < opn; ++i) {
                        std::uint32_t v = 0; pl.read(reinterpret_cast<char*>(&v), 4);
                        if (i < obj_progress_.size()) obj_progress_[i] = v;
                    }
                    quests_completed_ = int(qc); all_quests_done_ = aqd != 0;
                    std::uint32_t an = 0; pl.read(reinterpret_cast<char*>(&an), 4);
                    for (std::uint32_t i = 0; i < an; ++i) {
                        std::uint8_t dn = 0; std::int32_t pr = 0;
                        pl.read(reinterpret_cast<char*>(&dn), 1);
                        pl.read(reinterpret_cast<char*>(&pr), 4);
                        if (int(i) < kAchievementCount) { ach_done_[i] = dn != 0; ach_progress_[i] = pr; }
                    }
                    ach_done_count_ = 0;
                    for (int i = 0; i < kAchievementCount; ++i) if (ach_done_[i]) ++ach_done_count_;
                    quest_loaded = pl.good() || pl.eof();
                }
            }
        }
        spawn_ = pos_;                                   // respawn at the saved location
        if (health_ <= 0.0f) health_ = 20.0f;            // never load in dead
        for (auto& e : std::filesystem::directory_iterator(dir)) {
            if (e.path().extension() != ".chunk") continue;
            std::ifstream f(e.path(), std::ios::binary | std::ios::ate);
            std::streamsize sz = f.tellg();   // -1 if the file can't be opened
            if (sz <= 0) continue;            // skip unreadable/empty (else size_t wrap → bad_alloc)
            f.seekg(0);
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
        if (!quest_loaded) start_quest(0);   // old save: begin the arc fresh
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
        world_clock_ += dt;
        // Combat timers + slow health regeneration (kid-friendly: you bounce back).
        if (hurt_cd_  > 0) hurt_cd_  -= float(dt);
        if (regen_cd_ > 0) regen_cd_ -= float(dt);
        if (ach_toast_timer_ > 0) ach_toast_timer_ -= float(dt);
        else if (health_ < 20.0f) health_ = std::min(20.0f, health_ + 1.2f * float(dt));
        // Oxygen / drowning: a submerged head drains air over ~16 s; once it's
        // empty you take steady drowning damage until you surface.
        bool head_under = block_at(player_voxel()) == WATER;
        if (head_under) {
            oxygen_ = std::max(0.0f, oxygen_ - float(dt) / 16.0f);
            if (oxygen_ <= 0.0f) {
                drown_cd_ -= float(dt);
                if (drown_cd_ <= 0.0f) { health_ = std::max(0.0f, health_ - 2.0f); fx(9, player_voxel()); drown_cd_ = 1.0f; regen_cd_ = 4.0f; }
            }
        } else {
            oxygen_ = std::min(1.0f, oxygen_ + float(dt) * 0.7f);
            drown_cd_ = 0.0f;
        }
        if (health_ <= 0.0f) { oxygen_ = 1.0f; respawn(); }

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
            // Swim when chest OR feet are in water (so you can still get lift at
            // the surface to climb out). pos_ is the EYE.
            bool in_water = block_at(IVec3{ifloor(pos_.x), ifloor(pos_.y - 0.8f), ifloor(pos_.z)}) == WATER
                         || block_at(IVec3{ifloor(pos_.x), ifloor(pos_.y - 1.5f), ifloor(pos_.z)}) == WATER;
            if (in_water) {
                if      (in.jump)  vy_ = 5.2f;                                 // swim up / spring out onto land
                else if (in.sneak) vy_ = -4.6f;                               // dive
                else               vy_ = std::max(vy_ - 6.0f * float(dt), -2.0f); // slow sink
            } else {
                if (in.jump && on_ground_) { vy_ = 8.4f; fx(3, player_voxel()); }
                vy_ = std::max(vy_ - 28.0f * float(dt), -64.0f);
            }
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
            // Entering a still-drained region = reaching the Dim Barrens (drives
            // quest 5; "dim_barrens" is the colour-drained state, not a biome).
            if (region_sat(pc) < 0.99f) notify_quest("reach_location", "dim_barrens");
        }
        stream_tick();

        raycast_target();
        if (mining_ && has_target_) {
            mine_progress_ += float(dt) / break_time(block_at(target_));
            if (mine_progress_ >= 1.0f) {
                break_block(target_);
                damage_held_tool();                 // tools wear out as you mine
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
            if (step_timer_ <= 0.0f) { step_timer_ = 0.45f; fx(2, player_voxel()); }   // footstep
        } else { bob_amt_ = std::max(bob_amt_ - float(dt) * 7.0f, 0.0f); }
        // (Don't reset step_timer_ when momentarily not walking — that caused the
        // footstep to re-trigger instantly and sound jittery on bumpy ground.)

        maintain_creatures(float(dt));   // spawn near the player, despawn far away
        update_creatures(float(dt));
        update_falling(float(dt));        // sand/gravel + felled-tree logs in mid-air
    }

    void action(const bf_action& a) {
        switch (a.kind) {
            case BF_ACT_MINE_START: {
                // Left-click a creature in reach to hit it; otherwise start mining.
                int idx = creature_in_view();
                if (idx >= 0) attack_creature(idx); else mining_ = true;
                break;
            }
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
                // A glow block or a crafted beacon lights up the dark and restores
                // colour. Fire with the block name so quest 10 (target beacon_block)
                // and the achievement (any) both match correctly.
                if (pb == glow_id_ || (beacon_id_ != 0 && pb == beacon_id_)) {
                    notify_quest("light_beacon", block_name(pb));
                    ChunkCoord rc = to_chunk(place_);
                    if (region_sat(rc) < 0.99f) { ++regions_restored_; notify_quest("restore_region", "dim_barrens"); }
                    restore_region(rc);
                }
                break;
            }
            case BF_ACT_CRAFT:      craft_index(a.arg_i); break;
            case BF_ACT_INV_OPEN:   inv_open_ = true;  break;
            case BF_ACT_INV_CLOSE:  inv_open_ = false; break;
            case BF_ACT_INV_MOVE:
                if (inv_) inv_->move(std::size_t(a.arg_i), std::size_t(a.arg_j),
                                     std::uint16_t(a.arg_k > 0 ? a.arg_k : 64));
                break;
            case BF_ACT_ATTACK: {
                int idx = creature_in_view();
                if (idx >= 0) attack_creature(idx);
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
        // Cold/snowy area? Scan down from the eye: snow_layer(12)/ice(13) before
        // solid ground -> precipitation falls as snow here.
        {
            bool cold = false; int px = ifloor(eye.x), pz = ifloor(eye.z);
            for (int y = ifloor(eye.y); y > ifloor(eye.y) - 8 && !cold; --y) {
                BlockId b = block_at(IVec3{px, y, pz});
                if (b == 12 || b == 13) { cold = true; }
                else if (b != AIR && b != WATER && !is_plant(b)) break;
            }
            out.camera.biome_cold = cold ? 1.0f : 0.0f;
            // Weather: a slow ~4-min cycle, precipitation ~25% of the time; snow
            // where it's cold, rain otherwise. Engine-owned so the HUD label and
            // the renderer overlay agree.
            bool storm = std::fmod(world_clock_ / 240.0, 1.0) > 0.75;
            weather_ = storm ? (cold ? 2 : 1) : 0;
            out.camera.weather = float(weather_);
        }
        out.interp_alpha = 0.0f;
        out.draws = draws.data();
        out.draw_count = std::uint32_t(draws.size());
        out.regions = nullptr; out.region_count = 0;

        // Creatures (ABI v2 entity draws).
        entities_.clear();
        for (auto& cr : creatures_) {
            V3 col = cr.friendly ? V3{1.0f, 0.92f, 0.55f} : cr.color;
            if (cr.hit_flash > 0.0f) {                    // flash white toward the camera on a hit
                float f = std::min(1.0f, cr.hit_flash / 0.22f) * 0.85f;
                col = V3{col.x + (1.0f - col.x) * f, col.y + (1.0f - col.y) * f, col.z + (1.0f - col.z) * f};
            }
            bf_entity_draw e{};
            e.position = bf_vec3{cr.pos.x, cr.pos.y, cr.pos.z};
            e.yaw = cr.yaw;
            e.color = bf_vec3{col.x, col.y, col.z};
            e.scale = cr.scale;
            // Map 8 animal shapes to renderer kinds (4=boss, 5=monster, 6=falling).
            static const std::uint32_t kAnimalKind[8] = {0u, 1u, 2u, 3u, 7u, 8u, 9u, 10u};
            e.kind = cr.hostile ? (cr.shape == 1 ? 11u : 5u)
                                : (cr.is_boss ? 4u : kAnimalKind[std::size_t(cr.shape & 7)]);
            e.sat = region_sat(to_chunk(IVec3{ifloor(cr.pos.x), ifloor(cr.pos.y), ifloor(cr.pos.z)}));
            entities_.push_back(e);
        }
        // Falling blocks (gravity sand/gravel, felled-tree logs) as kind 6 cubes.
        for (const auto& fb : falling_) {
            bf_entity_draw e{};
            e.position = bf_vec3{fb.pos.x, fb.pos.y, fb.pos.z};
            e.yaw = fb.spin;
            e.color = bf_vec3{fb.color.x, fb.color.y, fb.color.z};
            e.scale = 1.0f;
            e.kind = 6u;                                  // tumbling cube
            e.sat = region_sat(to_chunk(IVec3{ifloor(fb.pos.x), ifloor(fb.pos.y), ifloor(fb.pos.z)}));
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
    int debug_sky_light(int x, int y, int z) const {
        ChunkCoord cc = to_chunk(IVec3{x, y, z});
        auto* ch = const_cast<ChunkStore&>(store_).get(cc);
        return ch ? int(ch->sky_light(mod16(x), mod16(y), mod16(z))) : -1;
    }
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
    int     debug_hostile_count() const {
        int n = 0; for (auto& c : creatures_) if (c.hostile) ++n; return n;
    }
    float   debug_health() const { return health_; }
    int     debug_falling_count() const { return int(falling_.size()); }
    void    debug_break_at(int x, int y, int z) { break_block(IVec3{x, y, z}); }
    float   debug_day_time() const { return day_time(world_clock_); }
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
        // 3x3 recipes (tools/weapons/big items) need a crafting table in your pack —
        // the early progression beat: log → planks → table → tools.
        bool hasTable = false;
        if (ItemId ct = item_id_by_name("crafting_table")) hasTable = inv_->count_item(ct) > 0;
        for (std::uint32_t i = 0; i < content_->recipe_count() && out.size() < 8; ++i) {
            const RecipeEntry& r = content_->recipe(i);
            if (r.pattern.empty() || r.result_item == 0) continue;
            if (r.grid_size >= 3 && !hasTable) continue;   // needs a crafting table
            // Count required-per-item inline (pattern <= 9 slots) to avoid a
            // per-recipe heap allocation every frame (fill_hud runs this each frame).
            const auto& pat = r.pattern;
            bool ok = true;
            for (std::size_t a = 0; a < pat.size() && ok; ++a) {
                ItemId it = pat[a];
                if (it == 0) continue;
                bool firstOcc = true; int need = 0;
                for (std::size_t s = 0; s < pat.size(); ++s)
                    if (pat[s] == it) { ++need; if (s < a) { firstOcc = false; } }
                if (!firstOcc) continue;                   // already accounted for
                if (int(inv_->count_item(it)) < need) ok = false;
            }
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
        if (craft_->commit(*inv_, std::span<const ItemId>(r.pattern.data(), r.pattern.size()), r.grid_size)) {
            fx(4, player_voxel());
            notify_quest("craft_item", item_name(r.result_item));   // matches quest triggers
        }
    }

    // ---- quest engine (Track J, M5) ---------------------------------------
    std::string block_name(BlockId b) const {
        const BlockDef* d = blocks_ ? blocks_->by_id(b) : nullptr; return d ? std::string(d->name) : std::string();
    }
    std::string item_name(ItemId i) const {
        const ItemDef* d = items_ ? items_->by_id(i) : nullptr; return d ? std::string(d->name) : std::string();
    }
    // Sound class for break audio (matches GameAudio.playBreak materialClass):
    // 0 generic, 1 stone, 2 wood, 3 dirt/grass, 4 sand/gravel, 5 glass, 6 leaf, 7 ore.
    static int sound_class_for(BlockId b) {
        switch (b) {
            case 3: case 8: case 10: case 15: case 29: return 1;   // stone family
            case 21: case 22: case 4: case 23: case 30: case 31: case 33: return 2; // wood
            case 1: case 2: case 14: case 16: case 12: return 3;   // dirt/grass/clay/snow
            case 6: case 11: return 4;                             // sand/gravel
            case 25: case 26: case 13: return 5;                   // glass/ice
            case 5: case 27: case 36: case 37: case 38: case 39: return 6; // leaves/plants
            case 17: case 18: case 19: case 20: return 7;          // ores
            default: return 0;
        }
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
    // ---- Achievements: small early-game goals that guide what to do next ----
    struct Achievement { const char* trig; const char* target; int count; const char* title; };
    static constexpr Achievement kAchievements[] = {
        {"collect_item", "oak_log",  1,  "First Wood!"},
        {"mine_block",   "oak_log",  3,  "Timber!"},
        {"collect_item", "dirt",     16, "Dirt Collector"},
        {"mine_block",   "stone",    1,  "Stone Age"},
        {"craft_item",   "",         1,  "Crafty"},
        {"mine_block",   "coal_ore", 1,  "Coal Miner"},
        {"mine_block",   "iron_ore", 1,  "Iron Prospector"},
        {"place_block",  "",         10, "Builder"},
        {"collect_item", "mushroom", 1,  "Forager"},
        {"place_block",  "crafting_table", 1, "Workbench Ready"},
        // Mid / late-game goals so there's always something to chase.
        {"befriend_creature", "",   1,  "Animal Friend!"},
        {"defeat_monster",    "",   1,  "Monster Hunter"},
        {"mine_block",   "iron_ore", 5,  "Iron Miner"},
        {"collect_item", "color_dust", 4, "Color Catcher"},
        {"reach_location", "dim_barrens", 1, "Into the Dim"},
        {"calm_boss",    "",         1,  "Colossus Tamer"},
        {"light_beacon", "",         1,  "Beacon Builder"},
        {"restore_region", "dim_barrens", 1, "Color Returns!"},
    };
    static constexpr int kAchievementCount = int(sizeof(kAchievements) / sizeof(kAchievements[0]));
    void check_achievements(const std::string& trig, const std::string& target) {
        for (int i = 0; i < kAchievementCount; ++i) {
            const Achievement& a = kAchievements[i];
            if (ach_done_[std::size_t(i)] || trig != a.trig) continue;
            if (a.target[0] != '\0' && target != a.target) continue;
            if (++ach_progress_[std::size_t(i)] >= a.count) {
                ach_done_[std::size_t(i)] = true; ++ach_done_count_;
                ach_toast_ = std::string("Achievement: ") + a.title;
                ach_toast_timer_ = 4.0f;
                fx(6, player_voxel());
            }
        }
    }
    void notify_quest(const std::string& trig, const std::string& target) {
        check_achievements(trig, target);
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
            if (collide_solid(x, y, z)) return y + 1;   // water/plants aren't standable
        return kNoFloor;
    }
    static bool solid_block(BlockId b) { return b != AIR && b != WATER && !is_plant(b); }
    // Cheap biome label from the surface block under the player + nearby trees.
    const char* biome_label() const {
        int px = ifloor(pos_.x), pz = ifloor(pos_.z);
        int top = -100000; BlockId surf = AIR;
        for (int y = ifloor(pos_.y) + 2; y > ifloor(pos_.y) - 30; --y) {
            BlockId b = block_at(IVec3{px, y, pz});
            if (solid_block(b) || b == WATER) { surf = b; top = y; break; }
        }
        if (surf == 12 || surf == 13) return "Snowy";
        if (surf == 6)                return "Desert";
        if (surf == WATER)            return "Ocean";
        if (top < -50000)             return "Meadow";
        int logs = 0;
        for (int dx = -9; dx <= 9 && logs < 3; dx += 3)
            for (int dz = -9; dz <= 9 && logs < 3; dz += 3)
                for (int y = top + 1; y <= top + 6; ++y)
                    if (is_log(block_at(IVec3{px + dx, y, pz + dz}))) { ++logs; break; }
        return logs >= 3 ? "Forest" : "Meadow";
    }
    // Top standable block at a world column, GENERATING the column if it isn't
    // resident (used by respawn so you never land in unloaded void or dirt).
    int surface_top(int wx, int wz) const {
        if (!gen_) return kNoFloor;
        int lx = mod16(wx), lz = mod16(wz);
        for (int cy = CY_MAX; cy >= CY_MIN; --cy) {
            ChunkCoord cc{ to_chunk(IVec3{wx, cy * kChunkDim, wz}).x, cy, to_chunk(IVec3{wx, cy * kChunkDim, wz}).z };
            if (IChunk* res = const_cast<ChunkStore&>(store_).get(cc)) {
                for (int ly = kChunkDim - 1; ly >= 0; --ly)
                    if (solid_block(res->get(lx, ly, lz))) return cy * kChunkDim + ly;
            } else {
                PaletteChunk tmp(cc); gen_->generate(cc, tmp);
                for (int ly = kChunkDim - 1; ly >= 0; --ly)
                    if (solid_block(tmp.get(lx, ly, lz))) return cy * kChunkDim + ly;
            }
        }
        return kNoFloor;
    }

    // Is a block solid for player collision? (air + water are passable.)
    // Cross-plants (grass/flowers/mushroom) are decorative — you walk through them.
    static bool is_plant(BlockId b) { return b == 36 || b == 37 || b == 38 || b == 39; }
    bool collide_solid(int x, int y, int z) const {
        BlockId b = block_at(IVec3{x, y, z});
        return b != AIR && b != WATER && !is_plant(b);
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
                c.shape = int(d->id) % 8;            // model variant from the def (8 species)
                c.skittish = (d->disposition == "skittish");
                c.hp = (d->max_health > 0) ? int(d->max_health) : (boss ? 10 : 5);
            } else {
                c.hp = boss ? 10 : 5;
            }
        } else {
            c.color = color_for(boss ? "boss" : "passive", std::uint16_t(creatures_.size() + 1));
            c.speed = boss ? 1.2f : 1.6f; c.name = boss ? "guardian" : "critter";
            c.shape = int(creatures_.size()) % 8;
            c.hp = boss ? 10 : 5;
        }
        c.scale = boss ? 2.0f : 0.8f;                          // hp set above (from content)
        creatures_.push_back(c);
        return true;
    }

    // A scary night monster that hunts the player (renders as kind 5).
    bool spawn_hostile(float rmin, float rmax) {
        float ang = rand01() * 6.2831853f, r = rmin + rand01() * (rmax - rmin);
        float cx = pos_.x + std::cos(ang) * r, cz = pos_.z + std::sin(ang) * r;
        // Spawn near the player's own level so cave monsters appear in the cave
        // (not on the surface far above) — scan down from just above the player.
        int gy = floor_below(ifloor(cx), int(pos_.y) + 3, ifloor(cz));
        if (gy == kNoFloor) return false;
        Creature c;
        c.pos = V3{cx, float(gy), cz}; c.yaw = rand01() * 6.2831853f;
        c.hostile = true; c.speed = 2.6f; c.hp = 6; c.scale = 1.0f;
        // shape 1 = humanoid (kind 11), shape 0 = beast (kind 5).
        c.shape = (rand01() < 0.5f) ? 1 : 0;
        c.color = (c.shape == 1) ? V3{0.16f, 0.13f, 0.20f} : V3{0.12f, 0.10f, 0.16f};
        c.name = (c.shape == 1) ? "lurker" : "monster";
        creatures_.push_back(c);
        return true;
    }

    // Player melee: chip the creature's hp; on defeat drop loot + a poof.
    void attack_creature(int idx) {
        Creature& cr = creatures_[std::size_t(idx)];
        IVec3 cv{ifloor(cr.pos.x), ifloor(cr.pos.y), ifloor(cr.pos.z)};
        // Damage by held weapon: a SWORD hits much harder than a tool or a fist.
        int dmg = 2;
        if (inv_ && items_) {
            const ItemDef* it = items_->by_id(inv_->get(selected_).item);
            if (it) {
                if (it->tool_kind == 4) dmg = 4 + int(it->tool_tier) * 2;  // sword: 6/8/10
                else if (it->tool_kind == 2) dmg = 3;                       // axe
            }
        }
        cr.hp -= dmg;
        damage_held_tool();                              // weapons/tools wear when used
        cr.hit_flash = 0.22f;                            // visible white flash
        // Knockback away from the player so hits read as impacts.
        float ax = cr.pos.x - pos_.x, az = cr.pos.z - pos_.z;
        float ad = std::sqrt(ax*ax + az*az);
        if (ad > 0.01f) { cr.pos.x += ax/ad * 1.3f; cr.pos.z += az/ad * 1.3f; }
        cr.vy = 3.0f;                                    // little hop on hit
        fx(8, cv);                                       // hit thwack
        if (cr.hp <= 0) {
            bool boss = cr.is_boss, hostile = cr.hostile; std::string nm = cr.name;
            drop_creature_loot(cr);
            creatures_.erase(creatures_.begin() + std::ptrdiff_t(idx));
            ++creatures_calmed_;
            fx(5, player_voxel());                       // poof
            notify_quest(boss ? "calm_boss" : (hostile ? "defeat_monster" : "befriend_creature"), nm);
        }
    }

    void drop_creature_loot(const Creature& cr) {
        if (!inv_) return;
        auto give = [&](const char* nm, int n) {
            if (ItemId id = item_id_by_name(nm)) {
                inv_->add(ItemStack{id, std::uint16_t(n), 0xFFFF});
                notify_quest("collect_item", nm);   // loot counts toward collect quests/achievements
            }
        };
        // Dim/shadow creatures hold the world's lost colour — defeating them frees
        // colour dust (drives quest 7's "collect color_dust").
        if (cr.hostile)      { give("color_dust", 1 + int(rand01() * 2.0f)); give("glow_dust", 1 + int(rand01() * 2.0f)); if (rand01() < 0.5f) give("coal", 1); }
        else if (cr.is_boss) { give("crystal_shard", 2 + int(rand01() * 2.0f)); give("color_dust", 2); }
        else                 { give("feather", 1 + int(rand01() * 2.0f)); if (rand01() < 0.4f) give("berry_cluster", 1); }
        fx(7, player_voxel());                           // pickup chime
    }

    // Wear down the held tool by one use; it breaks at 0. Durability initializes
    // lazily from the item def (0xFFFF on a fresh stack = full).
    void damage_held_tool() {
        if (!inv_ || !items_) return;
        ItemStack sel = inv_->get(selected_);
        if (sel.item == 0) return;
        const ItemDef* it = items_->by_id(sel.item);
        if (!it || it->tool_durability == 0) return;     // not a breakable tool
        std::uint16_t dur = (sel.durability == 0xFFFF) ? it->tool_durability : sel.durability;
        if (dur > 0) --dur;
        if (dur == 0) { inv_->set(std::size_t(selected_), ItemStack{}); fx(0, target_, 0); } // snap!
        else { sel.durability = dur; inv_->set(std::size_t(selected_), sel); }
    }
    void hurt_player(float dmg) {
        if (hurt_cd_ > 0.0f) return;
        health_ = std::max(0.0f, health_ - dmg);
        hurt_cd_ = 0.6f; regen_cd_ = 5.0f;
        fx(9, player_voxel());                           // ouch
    }

    void respawn() {
        // Place the player safely ON the surface above the spawn column (scan +
        // generate it if needed) so you never wake up buried or floating in void.
        int top = surface_top(ifloor(spawn_.x), ifloor(spawn_.z));
        float y = (top != kNoFloor) ? float(top) + 3.2f : spawn_.y;
        pos_ = V3{spawn_.x, y, spawn_.z};
        vy_ = 0.0f; health_ = 20.0f; oxygen_ = 1.0f;
        hurt_cd_ = 1.5f; regen_cd_ = 0.0f; drown_cd_ = 0.0f;
        first_stream_ = true;                            // force the spawn area to (re)stream
        recompute_stream_set();
        creatures_.erase(std::remove_if(creatures_.begin(), creatures_.end(),
            [](const Creature& c){ return c.hostile; }), creatures_.end());
        fx(6, player_voxel());                           // respawn chime
    }

    // Break a block: drop its item (or fell the whole tree for logs), play the
    // material break sound, and let undermined sand/gravel fall.
    void break_block(IVec3 t) {
        BlockId broken = block_at(t);
        if (broken == AIR) return;
        fx(0, t, (int(broken) << 4) | sound_class_for(broken));   // sound + debris colour
        notify_quest("mine_block", block_name(broken));
        if (is_log(broken)) {
            notify_quest("collect_item", item_name(item_that_places(broken)));
            fell_tree(t);                                          // whole tree comes down
        } else {
            if (inv_ && blocks_) {
                const BlockDef* bd = blocks_->by_id(broken);
                ItemId drop = bd ? bd->drop_item : ItemId(0);
                if (drop == 0) drop = item_that_places(broken);
                if (drop) {
                    inv_->add(ItemStack{drop, 1, 0xFFFF});
                    fx(7, t);                                      // pickup sound
                    notify_quest("collect_item", item_name(drop));
                }
            }
            set_block_internal(t, AIR);
            apply_gravity_above(t);                                // undermined sand/gravel falls
            flow_water(t);                                         // adjacent water flows in + falls
        }
    }
    // ---- Wave 3: destruction physics ---------------------------------------
    static bool is_gravity_block(BlockId b) { return b == 6 || b == 11; }   // sand, gravel
    static bool is_log(BlockId b)           { return b == 21 || b == 22; }  // oak/birch log
    static bool is_leaf(BlockId b)          { return b == 5 || b == 27; }   // oak/birch leaves
    static V3   falling_color(BlockId b) {
        switch (b) {
            case 6:  return {0.86f, 0.79f, 0.55f};   // sand
            case 11: return {0.55f, 0.53f, 0.50f};   // gravel
            case 21: return {0.50f, 0.36f, 0.20f};   // oak log
            case 22: return {0.78f, 0.72f, 0.56f};   // birch log
            case 5:  return {0.27f, 0.55f, 0.24f};   // oak leaves
            case 27: return {0.40f, 0.62f, 0.32f};   // birch leaves
            default: return {0.6f, 0.6f, 0.6f};
        }
    }
    void spawn_falling(IVec3 w, BlockId b, bool as_item, V3 vel) {
        if (falling_.size() > 200) return;               // perf cap
        FallingBlock fb;
        fb.pos = V3{float(w.x) + 0.5f, float(w.y), float(w.z) + 0.5f};
        fb.vel = vel;
        fb.spin = rand01() * 6.2831853f;
        fb.spin_rate = (rand01() - 0.5f) * 8.0f;
        fb.block = b; fb.color = falling_color(b); fb.as_item = as_item;
        falling_.push_back(fb);
    }
    // Water flows into a freshly-cleared cell if water is above or beside it,
    // then falls straight down through any air below. Bounded (no infinite spread:
    // only the broken cell is filled, plus its fall column).
    void flow_water(IVec3 t) {
        if (block_at(t) != AIR) return;
        bool fed = block_at(IVec3{t.x, t.y + 1, t.z}) == WATER
                || block_at(IVec3{t.x + 1, t.y, t.z}) == WATER
                || block_at(IVec3{t.x - 1, t.y, t.z}) == WATER
                || block_at(IVec3{t.x, t.y, t.z + 1}) == WATER
                || block_at(IVec3{t.x, t.y, t.z - 1}) == WATER;
        if (!fed) return;
        set_block_internal(t, WATER);
        IVec3 w = t;
        for (int guard = 0; guard < 64; ++guard) {       // let it fall to the bottom
            IVec3 below{w.x, w.y - 1, w.z};
            if (block_at(below) != AIR) break;
            set_block_internal(w, AIR);
            set_block_internal(below, WATER);
            w = below;
        }
    }
    // Undermined sand/gravel above a cleared cell falls.
    void apply_gravity_above(IVec3 w) {
        IVec3 up{w.x, w.y + 1, w.z};
        while (is_gravity_block(block_at(up))) {
            BlockId b = block_at(up);
            set_block_internal(up, AIR);
            spawn_falling(up, b, /*as_item=*/false, V3{0, -1.0f, 0});
            up.y += 1;
        }
    }
    // Chop a trunk → the whole tree comes down: logs fall (and drop as items),
    // leaves burst into particles.
    void fell_tree(IVec3 base) {
        std::vector<IVec3> logs, stack{base};
        std::set<std::tuple<int,int,int>> seen{{base.x, base.y, base.z}};
        while (!stack.empty() && logs.size() < 12) {       // cap work to avoid a lag spike
            IVec3 w = stack.back(); stack.pop_back();
            logs.push_back(w);
            for (int dx = -1; dx <= 1; ++dx)
            for (int dy = 0; dy <= 1; ++dy)              // grow upward/sideways, not down
            for (int dz = -1; dz <= 1; ++dz) {
                IVec3 n{w.x + dx, w.y + dy, w.z + dz};
                if (!is_log(block_at(n))) continue;
                auto key = std::make_tuple(n.x, n.y, n.z);
                if (seen.insert(key).second) stack.push_back(n);
            }
        }
        // Logs fall outward+up from the base, then drop as items.
        for (IVec3 w : logs) {
            BlockId b = block_at(w);
            set_block_internal(w, AIR);
            float h = float(w.y - base.y);
            V3 vel{(rand01() - 0.5f) * 2.0f, 1.5f + h * 0.4f, (rand01() - 0.5f) * 2.0f};
            spawn_falling(w, b, /*as_item=*/true, vel);
        }
        // Attached leaves are removed; emit only a FEW particle bursts (capped)
        // so a big canopy doesn't spawn hundreds of debris at once (lag spike).
        int leaf_bursts = 0, leaves_removed = 0;
        for (IVec3 lw : logs) {
            if (leaves_removed >= 160) break;            // cap blocks changed → bounded remesh
            for (int dx = -3; dx <= 3; ++dx)             // ±3 catches broad/tall canopies
            for (int dy = -1; dy <= 4; ++dy)
            for (int dz = -3; dz <= 3; ++dz) {
                IVec3 n{lw.x + dx, lw.y + dy, lw.z + dz};
                BlockId lf = block_at(n);
                if (!is_leaf(lf)) continue;
                set_block_internal(n, AIR); ++leaves_removed;
                if (leaf_bursts < 6) { fx(0, n, (int(lf) << 4) | 6); ++leaf_bursts; }
            }
        }
        fx(2, base);                                     // "timber" thud
    }
    void update_falling(float dt) {
        for (auto& fb : falling_) {
            fb.vel.y -= 26.0f * dt;
            fb.pos = fb.pos + fb.vel * dt;
            fb.spin += fb.spin_rate * dt;
            fb.life -= dt;
            int fy = floor_below(ifloor(fb.pos.x), int(std::floor(fb.pos.y)) + 1, ifloor(fb.pos.z));
            if (fy != kNoFloor && fb.pos.y <= float(fy)) {
                IVec3 land{ifloor(fb.pos.x), fy, ifloor(fb.pos.z)};
                if (fb.as_item) {
                    if (inv_) { if (ItemId id = item_that_places(fb.block)) inv_->add(ItemStack{id, 1, 0xFFFF}); }
                    fx(7, land);                          // pickup chime
                } else if (block_at(land) == AIR) {
                    set_block_internal(land, fb.block);   // gravity block settles
                    fx(0, land, (int(fb.block) << 4) | sound_class_for(fb.block));
                }
                fb.life = 0.0f;
            }
        }
        falling_.erase(std::remove_if(falling_.begin(), falling_.end(),
            [](const FallingBlock& f){ return f.life <= 0.0f; }), falling_.end());
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
        // Monster rules (Survival only): they come out at NIGHT, or any time when
        // you're somewhere DARK (a cave / underground where sky light is low).
        float t = day_time(world_clock_);
        bool surv = mode_ == BF_MODE_SURVIVAL;
        bool night = surv && (t < 0.20f || t > 0.80f);
        // Underground = well below the surface (depth-based; reliable regardless
        // of the sky-light data). Monsters lurk in caves any time of day.
        int surfY = surface_top(ifloor(pos_.x), ifloor(pos_.z));
        bool darkCave = surv && surfY != kNoFloor && (surfY - ifloor(pos_.y)) > 6;
        // First-night grace: no monsters until the kid finishes their first quest,
        // so a brand-new player gets a safe session to learn before the scary part.
        bool monstersActive = (night || darkCave) && quests_completed_ > 0;
        // Monsters flee only when it's both daytime AND lit (safe).
        if (!monstersActive)
            creatures_.erase(std::remove_if(creatures_.begin(), creatures_.end(),
                [](const Creature& c){ return c.hostile; }), creatures_.end());
        int ambient = 0, bosses = 0, hostiles = 0;
        for (auto& c : creatures_) { if (c.hostile) ++hostiles; else if (c.is_boss) ++bosses; else ++ambient; }
        // Fill the area quickly at first (small timer), then top up slowly.
        creature_timer_ = ((monstersActive ? hostiles : ambient) < 4) ? 0.08f : 0.5f;
        if (monstersActive) {
            if (hostiles < 5) spawn_hostile(8.0f, 24.0f);   // a real but survivable night threat
        } else if (ambient < 9) {
            spawn_ring_creature(false, 8.0f, 26.0f);
        } else if (bosses < 2) {
            spawn_ring_creature(true, 18.0f, 40.0f);
        }
    }

    void update_creatures(float dt) {
        for (auto& c : creatures_) {
            c.wander -= dt;
            if (c.hit_flash > 0) c.hit_flash -= dt;
            V3 toPlayer = pos_ - c.pos;
            // In Creative the monsters leave you alone (no chase, no damage).
            if (c.hostile && mode_ == BF_MODE_SURVIVAL) {
                // Night monster: relentlessly chases the player and bites on contact.
                if (dot(toPlayer, toPlayer) > 0.0001f) c.yaw = std::atan2(toPlayer.x, toPlayer.z);
                if (c.atk_cd > 0) c.atk_cd -= dt;
                // Bite test in XZ (+ a vertical guard): pos_ is the EYE (~1.6 above
                // the feet) and c.pos is the creature's feet, so a 3D distance never
                // got close enough — that's why monsters never actually hurt you.
                float xzd = std::sqrt(toPlayer.x*toPlayer.x + toPlayer.z*toPlayer.z);
                float yd  = std::fabs((c.pos.y + c.scale * 0.5f) - (pos_.y - 1.6f));
                if (xzd < 1.3f && yd < 1.6f && c.atk_cd <= 0.0f) { hurt_player(2.5f); c.atk_cd = 1.1f; }
            } else if (c.friendly) {
                // follow the player when not too close
                float d = std::sqrt(dot(toPlayer, toPlayer));
                if (d > 2.5f) c.yaw = std::atan2(toPlayer.x, toPlayer.z);
            } else if (c.skittish && dot(toPlayer, toPlayer) < 36.0f) {
                // Rabbits/foxes bolt away when you get within ~6 blocks.
                c.yaw = std::atan2(-toPlayer.x, -toPlayer.z); c.wander = 0.8f;
            } else if (c.wander <= 0.0f) {
                c.yaw = rand01() * 6.2831853f;
                c.wander = 1.5f + rand01() * 2.5f;
            }
            V3 dir{std::sin(c.yaw), 0, std::cos(c.yaw)};
            V3 next = c.pos + dir * (c.speed * dt);
            IVec3 nv{ifloor(next.x), ifloor(next.y), ifloor(next.z)};
            // Use collide_solid so creatures walk THROUGH grass/flowers/mushrooms
            // (and water) instead of bumping into them like walls.
            if (!collide_solid(nv.x, nv.y, nv.z)) {
                c.pos.x = next.x; c.pos.z = next.z;                       // clear path
            } else if (!collide_solid(nv.x, nv.y + 1, nv.z)) {
                c.pos.x = next.x; c.pos.z = next.z; c.pos.y += 1.0f;      // step up a 1-block ledge
            } else {
                c.yaw += 2.4f; c.wander = 0.5f;                          // turn away from a wall
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
        int best = -1; float bestT = 6.0f;
        for (std::size_t i = 0; i < creatures_.size(); ++i) {
            const Creature& c = creatures_[i];
            V3 cc = c.pos + V3{0, c.scale * 0.5f, 0};       // aim at body centre, scaled
            V3 rel = cc - o;
            float t = dot(rel, d);
            if (t < 0 || t > bestT) continue;
            V3 closest = o + d * t;
            V3 off = cc - closest;
            // Hit radius grows with the creature's size so big animals/bosses are
            // easy to hit (was a fixed 0.84 radius regardless of size).
            float rad = 0.55f + c.scale * 0.7f;
            if (dot(off, off) < rad * rad) { bestT = t; best = int(i); }
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
        // We only ever process the nearest MESH_BUDGET this frame — partial_sort
        // instead of a full O(n log n) sort of the whole dirty set every frame.
        auto cmp = [&](ChunkCoord a, ChunkCoord b) {
            return dist2(a, last_center_) < dist2(b, last_center_);
        };
        std::size_t k = std::min<std::size_t>(std::size_t(MESH_BUDGET), todo.size());
        std::partial_sort(todo.begin(), todo.begin() + std::ptrdiff_t(k), todo.end(), cmp);
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
        h.oxygen = oxygen_;
        h.achievements_done  = std::uint8_t(ach_done_count_);
        h.achievements_total = std::uint8_t(kAchievementCount);
        h.weather = std::uint8_t(weather_);
        std::strncpy(h.biome_name, biome_label(), sizeof(h.biome_name) - 1);
        if (ach_toast_timer_ > 0.0f)
            std::strncpy(h.achievement_toast, ach_toast_.c_str(), sizeof(h.achievement_toast) - 1);
        // Look-at name: a creature under the crosshair takes priority, else the
        // targeted block. Drives the "what am I looking at" label.
        h.look_name[0] = '\0';
        int ci = creature_in_view();
        if (ci >= 0 && !creatures_[std::size_t(ci)].name.empty())
            std::strncpy(h.look_name, creatures_[std::size_t(ci)].name.c_str(), sizeof(h.look_name) - 1);
        else if (has_target_) {
            std::string bn = block_name(block_at(target_));
            if (!bn.empty()) std::strncpy(h.look_name, bn.c_str(), sizeof(h.look_name) - 1);
        }
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
    double        world_clock_{0.0};   // accumulates dt; drives day/night for spawns
    int           weather_{0};         // 0 clear, 1 rain, 2 snow
    V3            spawn_{0, 12, 0};     // respawn point
    float         hurt_cd_{0.0f};       // i-frames after taking damage
    float         regen_cd_{0.0f};      // delay before health regenerates
    float         oxygen_{1.0f};        // 1 = full air; drains while the head is submerged
    float         drown_cd_{0.0f};      // cooldown between drowning ticks

    // Track J content + gameplay state.
    const ContentRegistry*        content_{nullptr};
    const IBlockRegistry*         blocks_{nullptr};
    const IItemRegistry*          items_{nullptr};
    const IRecipeBook*            recipes_{nullptr};
    std::optional<Inventory>      inv_;
    std::optional<CraftingSystem> craft_;
    BlockId                       glow_id_{GLOW};
    BlockId                       beacon_id_{0};
    bool                          inv_open_{false};

    // Creatures + quest state (M3).
    std::vector<Creature>         creatures_;
    std::vector<FallingBlock>     falling_;
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
    // Achievements
    int                           ach_progress_[kAchievementCount] = {};
    bool                          ach_done_[kAchievementCount] = {};
    int                           ach_done_count_{0};
    std::string                   ach_toast_;
    float                         ach_toast_timer_{0.0f};

    // Co-op (Track H).
    std::function<void(IVec3, BlockId)> edit_cb_;
    std::function<void(int, IVec3, int)> fx_cb_;         // audio/particles (extra = sound class)
    float                               step_timer_{0.0f};
    std::vector<bf_entity_draw>         remote_avatars_;
    float         mine_progress_{0.0f};
    bool          has_target_{false};
    IVec3         target_{}, place_{};
};

} // namespace bf
