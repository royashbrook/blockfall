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

namespace bf {

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
        // Creative-style hotbar of placeable blocks + functional blocks.
        const char* hot[BF_HOTBAR_SLOTS] = {
            "glow_block", "stone", "oak_planks", "stone_brick", "sand",
            "oak_log", "torch", "chest", "crafting_table"
        };
        for (int i = 0; i < BF_HOTBAR_SLOTS; ++i) {
            ItemId id = item_id_by_name(hot[i]);
            if (id) inv_->set(std::size_t(i), ItemStack{id, 64, 0xFFFF});
        }
        // A few raw materials in the main grid so crafting has inputs.
        if (ItemId log = item_id_by_name("oak_log")) inv_->set(9, ItemStack{log, 16, 0xFFFF});
    }

    // ---- M2: procedural spawn + streaming --------------------------------
    void init_world(std::uint64_t seed) {
        seed_ = seed;
        if (!gen_) { generate_test_world(); return; }
        gen_->seed(seed);
        // Find the surface at spawn column (0,0): generate the vertical band and
        // scan from the top for the first solid block.
        int surface = 8;
        for (int cy = CY_MAX; cy >= CY_MIN; --cy) {
            auto ch = std::make_unique<PaletteChunk>(ChunkCoord{0, cy, 0});
            gen_->generate(ChunkCoord{0, cy, 0}, *ch);
            for (int ly = kChunkDim - 1; ly >= 0; --ly) {
                if (ch->get(0, ly, 0) != AIR) { surface = cy * kChunkDim + ly; goto found; }
            }
        }
        found:
        pos_ = V3{0.5f, float(surface) + 2.5f, 0.5f};
        yaw_ = 0.6f; pitch_ = -0.25f;
        restore_region(ChunkCoord{0, 0, 0});           // spawn region starts colorful
        recompute_stream_set();
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
        float speed = (in.sprint ? 22.0f : 11.0f) * float(dt);
        V3 delta = flat * (in.move_forward * speed) + right * (in.move_strafe * speed);
        if (in.jump || in.fly_ascend)   delta.y += speed;
        if (in.sneak || in.fly_descend) delta.y -= speed;
        pos_ = pos_ + delta;

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
                // Survival: the block drops an item into the inventory.
                if (mode_ == BF_MODE_SURVIVAL && inv_ && blocks_) {
                    const BlockDef* bd = blocks_->by_id(broken);
                    ItemId drop = bd ? bd->drop_item : ItemId(0);
                    if (drop) inv_->add(ItemStack{drop, 1, 0xFFFF});
                }
                set_block_internal(target_, AIR);
                mine_progress_ = 0.0f; raycast_target();
            }
        } else mine_progress_ = 0.0f;
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
                if (pb == glow_id_) restore_region(to_chunk(place_));  // light up the Dim
                break;
            }
            case BF_ACT_CRAFT:      try_craft_available(); break;
            case BF_ACT_INV_OPEN:   inv_open_ = true;  break;
            case BF_ACT_INV_CLOSE:  inv_open_ = false; break;
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

        V3 fwd = forward_dir(), eye = pos_, ctr = eye + fwd;
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
        out.interp_alpha = 0.0f;
        out.draws = draws.data();
        out.draw_count = std::uint32_t(draws.size());
        out.regions = nullptr; out.region_count = 0;
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

private:
    // Start in bright morning (+0.30) and cycle ~50 s/day.
    static float day_time(double clock) { return float(std::fmod(clock * 0.02 + 0.30, 1.0)); }

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
    void try_craft_available() {
        if (!content_ || !inv_ || !craft_) return;
        for (std::uint32_t i = 0; i < content_->recipe_count(); ++i) {
            const RecipeEntry& r = content_->recipe(i);
            if (craft_->commit(*inv_, std::span<const ItemId>(r.pattern.data(), r.pattern.size()),
                               r.grid_size))
                return;   // crafted the first recipe the player can make
        }
    }

    BlockId block_at(IVec3 w) const {
        ChunkCoord cc = to_chunk(w);
        auto* ch = const_cast<ChunkStore&>(store_).get(cc);
        return ch ? ch->get(mod16(w.x), mod16(w.y), mod16(w.z)) : AIR;
    }
    void set_block_internal(IVec3 w, BlockId b) {
        ChunkCoord cc = to_chunk(w);
        store_.get_or_create(cc)->set(mod16(w.x), mod16(w.y), mod16(w.z), b);
        dirty_.insert(cc);
        edited_.insert(cc);    // player-edited -> persisted on save

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
        }
        h.active_quest_id = 1;
        std::strncpy(h.quest_title, "Bring back the color", sizeof(h.quest_title) - 1);
        std::strncpy(h.quest_objective, "Place a glow block in the grey Dim", sizeof(h.quest_objective) - 1);
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

    // Track J content + gameplay state.
    const ContentRegistry*        content_{nullptr};
    const IBlockRegistry*         blocks_{nullptr};
    const IItemRegistry*          items_{nullptr};
    const IRecipeBook*            recipes_{nullptr};
    std::optional<Inventory>      inv_;
    std::optional<CraftingSystem> craft_;
    BlockId                       glow_id_{GLOW};
    bool                          inv_open_{false};
    float         mine_progress_{0.0f};
    bool          has_target_{false};
    IVec3         target_{}, place_{};
};

} // namespace bf
