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
#include "blockcore/jobs.hpp"
#include "blockcore/worldgen.hpp"
#include "blockcore_interfaces.hpp"

#include <mutex>
#include <memory>

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
    bool  aquatic{false};   // lives in water (fish): swims, isn't water-blocked
    float atk_cd{0};        // cooldown between hits on the player
    float hit_flash{0};     // brief white flash when the player hits it
    float wander{0};
    int   shape{0};         // renderer model variant (0..3 animals)
    int   model{-1};        // explicit renderer kind from content (-1 = legacy mapping)
    int   npc_id{0};        // #82 dialogue id for villagers (1=Mira 2=Tom 3=Lena, 0=none)
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
    std::vector<bf_prop_instance> props;   // #51 sub-voxel props in this chunk (cached at mesh time)
};

// Read-only chunk store holding owned COPIES of a chunk + its neighbours, so a
// worker thread can greedy-mesh from it without touching (or racing) the live
// store. Only get()/is_resident() are used by the mesher (#25 async meshing).
struct SnapStore final : IChunkStore {
    std::unordered_map<ChunkCoord, std::unique_ptr<PaletteChunk>, ChunkCoordHash> chunks;
    IChunk* get(ChunkCoord c) override {
        auto it = chunks.find(c); return it != chunks.end() ? it->second.get() : nullptr;
    }
    IChunk* get_or_create(ChunkCoord c) override { return get(c); }
    void    evict(ChunkCoord) override {}
    bool    is_resident(ChunkCoord c) const override { return chunks.find(c) != chunks.end(); }
    std::size_t serialize(ChunkCoord, std::span<std::byte>) const override { return 0; }
    bool        deserialize(ChunkCoord, std::span<const std::byte>) override { return false; }
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
    static constexpr int    CY_MIN       = -1;     // vertical chunk band (terrain)
    static constexpr int    CY_MAX       = 3;
    // Streaming work is synchronous on the frame thread, so a big per-frame
    // budget = a big hitch when you cross a chunk boundary. Smaller budgets
    // spread the same work over more frames → much smoother 1%-low (pop-in is
    // marginally slower, which is the right trade for kids).
    static constexpr int    GEN_BUDGET   = 6;      // chunks generated per frame (sync fallback only)
    static constexpr int    MESH_BUDGET  = 12;     // mesh jobs submitted per frame (run on workers, #25)

    explicit World(IMesher& mesher, IWorldGen* gen = nullptr)
        : mesher_(mesher), gen_(gen) {}

    void set_allocator(const bf_gpu_allocator& a) { alloc_ = a; has_alloc_ = true; }
    void set_mode(bf_game_mode m) { mode_ = m; }
    // Horizontal streaming radius in chunks (from the render-distance config).
    void set_render_distance(int chunks) { stream_r_ = std::clamp(chunks, 4, 40); }  // #85 allow farther
    // Runtime change (a pause-menu slider, #85): also re-stream so the new radius takes
    // effect immediately. Only safe after the world is initialised.
    void apply_render_distance(int chunks) { set_render_distance(chunks); recompute_stream_set(); }

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
        // Spin up worker threads for async chunk generation (#25). Generation is a
        // pure fn of (seed, coord), so E-core workers can churn chunks in parallel
        // while the main thread just inserts + meshes them.
        if (!sched_) {
            CoreTopology topo = detect_core_topology();
            unsigned e = std::max(2u, topo.e_cores);
            unsigned p = std::max(1u, topo.p_cores > 1 ? topo.p_cores - 1 : 1u);
            sched_ = std::make_unique<JobScheduler>(p, e);
        }
        // Pick a DRY-LAND spawn column near the origin so the player never wakes up in
        // water. The continentalness/river terrain puts more water near some seeds, and
        // the scan below treats WATER as a surface (it is non-air), so a submerged origin
        // would spawn you floating over water. worldgen_surface_height is the cheap pure
        // surface query; H >= sea level + 1 means dry land. Spiral out in 6-block steps
        // for the nearest dry column; fall back to the origin if all-ocean (very rare).
        constexpr int kSeaLevel = 6;
        int sx = 0, sz = 0;
        if (worldgen_surface_height(0, 0, seed_) < kSeaLevel + 1) {
            bool dry = false;
            for (int r = 1; r <= 20 && !dry; ++r)
                for (int dz = -r; dz <= r && !dry; ++dz)
                    for (int dx = -r; dx <= r && !dry; ++dx) {
                        int adx = dx < 0 ? -dx : dx, adz = dz < 0 ? -dz : dz;
                        if ((adx > adz ? adx : adz) != r) continue;   // current ring only
                        int wx = dx * 6, wz = dz * 6;
                        if (worldgen_surface_height(wx, wz, seed_) >= kSeaLevel + 1) {
                            sx = wx; sz = wz; dry = true;
                        }
                    }
        }
        // Find the surface at the chosen spawn column: generate the vertical band and
        // scan from the top for the first solid block.
        ChunkCoord scol = to_chunk(IVec3{sx, 0, sz});
        int slx = mod16(sx), slz = mod16(sz);
        int surface = 8; bool found = false;
        for (int cy = CY_MAX; cy >= CY_MIN; --cy) {
            ChunkCoord cc{scol.x, cy, scol.z};
            auto ch = std::make_unique<PaletteChunk>(cc);
            gen_->generate(cc, *ch);
            if (!found)
                for (int ly = kChunkDim - 1; ly >= 0; --ly)
                    if (ch->get(slx, ly, slz) != AIR) { surface = cy * kChunkDim + ly; found = true; break; }
            // Keep the spawn column resident so the player lands immediately
            // (rather than falling through before streaming fills it in).
            if (!(ch->is_uniform() && ch->get(0, 0, 0) == AIR)) {
                store_.insert(std::move(ch)); dirty_.insert(cc);
            }
        }
        // Eye 3.2 above the surface block so the FEET (eye-1.6) clear the top
        // block and the player settles onto it, instead of spawning embedded
        // (which left you "stuck" until you jumped).
        pos_ = V3{float(sx) + 0.5f, float(surface) + 3.2f, float(sz) + 0.5f};
        spawn_ = pos_;                                  // respawn here on defeat
        yaw_ = 0.6f; pitch_ = -0.25f;
        restore_region(ChunkCoord{scol.x, 0, scol.z});  // spawn region starts colorful
        recompute_stream_set();
        creatures_.clear();
        creature_timer_ = 0.0f;                     // spawn once the area streams in
        all_quests_done_ = false; quests_completed_ = 0; regions_restored_ = 0;
        start_quest(0);
        ensure_clear_spawn();                // never spawn embedded in terrain
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
            // Build the path with std::string (not a fixed char[160]) — a long
            // save_dir (sandboxed app paths are easily >115 chars) would otherwise
            // truncate, write chunks to the wrong place, and silently lose the world.
            std::string name = dir + "/c_" + std::to_string(cc.x) + "_"
                                   + std::to_string(cc.y) + "_" + std::to_string(cc.z) + ".chunk";
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
        ensure_clear_spawn();                // don't load embedded in terrain (#: stuck-on-load bug)
        last_center_ = to_chunk(IVec3{ifloor(pos_.x), ifloor(pos_.y), ifloor(pos_.z)});
        first_stream_ = true;
        creatures_.clear();
        creature_timer_ = 0.0f;
        if (!quest_loaded) start_quest(0);   // old save: begin the arc fresh
        recompute_stream_set();
        return true;
    }

    // Make sure the player isn't loaded inside solid terrain. Load only restores
    // EDITED chunks, so the player's spawn chunk may be unedited (not on disk) and
    // not yet streamed; and terrain can drift between builds. Generate the player's
    // vertical column synchronously so collision is accurate on frame 1, then lift
    // them to the first clear spot if embedded (cave/surface poses are left alone).
    void ensure_clear_spawn() {
        if (!gen_) return;
        ChunkCoord pc = to_chunk(IVec3{ifloor(pos_.x), ifloor(pos_.y), ifloor(pos_.z)});
        for (int cy = CY_MAX; cy >= CY_MIN; --cy) {
            ChunkCoord cc{pc.x, cy, pc.z};
            if (store_.is_resident(cc)) continue;
            auto ch = std::make_unique<PaletteChunk>(cc);
            gen_->generate(cc, *ch);
            if (!(ch->is_uniform() && ch->get(0, 0, 0) == AIR)) { store_.insert(std::move(ch)); dirty_.insert(cc); }
        }
        if (box_collides(pos_)) {                       // embedded → rise to clear air
            for (int i = 0; i < 64 && box_collides(pos_); ++i) pos_.y += 1.0f;
            pos_.y += 0.1f; vy_ = 0.0f; spawn_ = pos_;
        }
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
        // Clamp the frame step: a lag spike (background tab, GC pause) with a big
        // dt would single-step the player tens of blocks and tunnel clean through
        // the ground into the void (collision is tested only at the end position).
        // Capping dt makes a spike merely slow the sim for a frame, never break it.
        if (dt > 0.1) dt = 0.1;
        // Is the player actively travelling? While moving you outrun the far fill
        // anyway, and cranking the stream budgets mid-travel would hitch — so the
        // aggressive "bulk fill" (P-cores + big budgets) only engages when you're
        // NOT moving (spawn-in, or stopped to look around), where it rushes the
        // backlog in fast. (#5 fill responsiveness)
        moving_ = (std::fabs(in.move_forward) + std::fabs(in.move_strafe) + std::fabs(float(in.jump))) > 0.1f;
        world_clock_ += dt;
        // Combat timers + slow health regeneration (kid-friendly: you bounce back).
        if (hurt_cd_  > 0) hurt_cd_  -= float(dt);
        if (regen_cd_ > 0) regen_cd_ -= float(dt);
        if (ach_toast_timer_ > 0) ach_toast_timer_ -= float(dt);
        // Heal only after a few damage-free seconds (regen_cd_) — NOT gated on the
        // achievement toast. Previously regen was an else-branch of the toast check
        // and ignored regen_cd_ entirely, so you healed instantly after every hit
        // and a single monster could never actually kill you.
        if (regen_cd_ <= 0.0f && health_ < 20.0f)
            health_ = std::min(20.0f, health_ + 1.2f * float(dt));
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
        // Void guard: if you dig through the bottom of the world (or fall out a
        // gap), you'd otherwise fall forever. Snap back to a safe surface.
        if (pos_.y < -40.0f) { oxygen_ = 1.0f; vy_ = 0.0f; respawn(); }

        yaw_  += in.look_yaw_delta;
        pitch_ += in.look_pitch_delta;
        const float lim = 1.5533f;
        pitch_ = std::clamp(pitch_, -lim, lim);

        V3 fwd = forward_dir();
        V3 flat = normalize(V3{fwd.x, 0, fwd.z});
        V3 right = normalize(cross(flat, V3{0, 1, 0}));
        // Creative flies fast; survival walks, with a real sprint boost (#14).
        float baseSpd   = (mode_ == BF_MODE_CREATIVE) ? 8.0f  : 5.0f;
        float sprintSpd = (mode_ == BF_MODE_CREATIVE) ? 16.0f : 8.5f;
        float speed = (in.sprint ? sprintSpd : baseSpd) * float(dt);
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
            if (step_timer_ <= 0.0f) {                                   // footstep
                step_timer_ = 0.45f;
                IVec3 pv = player_voxel();
                int gy = floor_below(pv.x, pv.y + 1, pv.z);
                BlockId fb = (gy != kNoFloor) ? block_at(IVec3{pv.x, gy - 1, pv.z}) : BlockId(GRASS);
                fx(2, pv, footstep_class(fb));                           // terrain class -> step sound
            }
        } else { bob_amt_ = std::max(bob_amt_ - float(dt) * 7.0f, 0.0f); }
        // (Don't reset step_timer_ when momentarily not walking — that caused the
        // footstep to re-trigger instantly and sound jittery on bumpy ground.)

        maintain_creatures(float(dt));   // spawn near the player, despawn far away
        maintain_villagers(float(dt));   // #39: friendly people at structures
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
            case BF_ACT_PLACE: perform_place(); break;
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
            case BF_ACT_INTERACT: {
                // #69 doors: looking at a door? open/close it (swings between solid-closed
                // and passable-open). Takes priority over befriend/place.
                if (has_target_) {
                    BlockId tb = block_at(target_);
                    if (tb == 33u || tb == 50u) {
                        set_block_internal(target_, tb == 33u ? BlockId(50u) : BlockId(33u));
                        fx(1, target_);            // door clack
                        break;
                    }
                }
                // Context-sensitive "use" (right-click): if you are looking at a creature,
                // befriend it (feeding a berry if you have one); otherwise place the held
                // block. This is why feeding animals did nothing before — the app never
                // sent INTERACT, and right-click only ever placed. (#69)
                int idx = creature_in_view();
                if (idx >= 0 && creatures_[std::size_t(idx)].model == 20) {
                    // #82 a VILLAGER: open their dialogue (do NOT befriend, which used to make
                    // them follow you around). The app shows the dialogue tree for this npc_id.
                    fx(20, player_voxel(), creatures_[std::size_t(idx)].npc_id);
                } else if (idx >= 0 && !creatures_[std::size_t(idx)].hostile) {
                    creatures_[std::size_t(idx)].friendly = true; ++creatures_befriended_;
                    // Feed the held berry (consume one) so it reads as feeding the animal.
                    if (inv_) {
                        ItemStack held = inv_->get(selected_);
                        if (held.item != 0 && item_name(held.item) == std::string("berry_cluster"))
                            inv_->remove_item(held.item, 1);
                    }
                    fx(5, player_voxel());
                    notify_quest("befriend_creature", creatures_[std::size_t(idx)].name);
                } else {
                    perform_place();               // nothing to interact with → place
                }
                break;
            }
            case BF_ACT_GIVE_ITEM:           // creative item picker (#15)
                if (mode_ == BF_MODE_CREATIVE && inv_ && a.arg_i > 0) {
                    // Give a full stack, but only ONE of a non-stacking item (#35) —
                    // a sword should hand you one sword, not 64.
                    std::uint16_t qty = 64;
                    if (items_) if (const ItemDef* d = items_->by_id(ItemId(a.arg_i)))
                        qty = std::uint16_t(std::min<int>(64, d->max_stack > 0 ? d->max_stack : 64));
                    inv_->add(ItemStack{ItemId(a.arg_i), qty, 0xFFFF});
                }
                break;
            case BF_ACT_DROP_ITEM:           // trash a slot (#34)
                if (inv_ && a.arg_i >= 0 && a.arg_i < BF_INVENTORY_SLOTS)
                    inv_->set(std::size_t(a.arg_i), ItemStack{});
                break;
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

    void build_frame(bf_render_frame& out, std::vector<bf_draw_item>& draws,
                     std::vector<bf_draw_item>& shadow_draws,
                     std::vector<bf_prop_instance>& prop_instances, double clock) {
        remesh_dirty();
        draws.clear();
        prop_instances.clear();
        std::vector<bf_region_dim> regions; // built lazily below
        // View-cone cull: skip chunks well outside the camera's forward cone so
        // draw cost scales with what's visible, not with render distance (#5).
        // Generous half-cone (~72°, ~2x the real FOV) + always-draw the immediate
        // neighbourhood so turning never pops chunks in.
        V3 camFwd = forward_dir(); V3 camPos = pos_;
        constexpr float kCullCos = 0.30f;
        const float kNearKeep = float(kChunkDim) * 1.5f;
        for (auto& [cc, rec] : meshes_) {
            if (!rec.has_buffers || rec.index_count == 0) continue;
            V3 ctr{(float(cc.x) + 0.5f) * kChunkDim, (float(cc.y) + 0.5f) * kChunkDim, (float(cc.z) + 0.5f) * kChunkDim};
            V3 toC{ctr.x - camPos.x, ctr.y - camPos.y, ctr.z - camPos.z};
            float dist = std::sqrt(dot(toC, toC));
            if (dist > kNearKeep && dot(toC, camFwd) / dist < kCullCos) continue;  // behind/outside view
            bf_draw_item d{};
            d.vertex_buffer = rec.vbuf.handle;
            d.index_buffer  = rec.ibuf.handle;
            d.index_count   = rec.index_count;
            d.chunk_origin  = bf_ivec3{cc.x * kChunkDim, cc.y * kChunkDim, cc.z * kChunkDim};
            // Saturation at this chunk's 4 horizontal corners (this region + the
            // +X/+Z/+XZ neighbour regions) so the shader bilerps the grey->colour
            // transition across region seams instead of a hard chunk-grid line.
            d.dim_saturation = region_sat(cc);
            d.dim_sat_px  = region_sat(ChunkCoord{cc.x + 1, cc.y, cc.z});
            d.dim_sat_pz  = region_sat(ChunkCoord{cc.x, cc.y, cc.z + 1});
            d.dim_sat_pxz = region_sat(ChunkCoord{cc.x + 1, cc.y, cc.z + 1});
            draws.push_back(d);
            // #51/#78 — emit this chunk's props (trees, plants, rocks) for the prop
            // renderer. Pushed out to 120 (was 80) so trees and props render noticeably
            // farther, closer to the land render distance, without tanking the framerate
            // (full 2x tripled the instance count and cost ~20 FPS).
            if (dist < 120.0f && !rec.props.empty())
                prop_instances.insert(prop_instances.end(), rec.props.begin(), rec.props.end());
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
        // How far below the terrain surface the eye sits (0 at/above surface, 1 deep).
        // The renderer darkens the sky by this so that when surface-priority streaming
        // hasn't loaded the far underground, the gaps read as dark cave — not as the
        // bright, sun-directional daytime sky bleeding in. (#33)
        {
            int surf = worldgen_surface_height(ifloor(eye.x), ifloor(eye.z), seed_);
            float depth = float(surf - ifloor(eye.y));
            out.camera.underground = std::clamp((depth - 3.0f) / 8.0f, 0.0f, 1.0f);
        }
        // Player's region saturation (1=full colour, <1 = The Grey) → drives the
        // grey ash-mote ambience so being in the Grey is viscerally obvious.
        out.camera.local_sat = region_sat(to_chunk(IVec3{ifloor(pos_.x), ifloor(pos_.y), ifloor(pos_.z)}));
        out.interp_alpha = 0.0f;
        out.draws = draws.data();
        out.draw_count = std::uint32_t(draws.size());
        out.regions = nullptr; out.region_count = 0;

        // Shadow occluder list: same resident meshes, NO view-cone cull, bounded to
        // the far shadow cascade's radius. Without this the shadow pass only saw the
        // forward-cone chunks, so shadows from geometry behind/beside you popped away
        // as you turned (#46). Depth-only + already-resident, so this is cheap.
        shadow_draws.clear();
        constexpr float kShadowR = 165.0f;   // #72: cover the widened far cascade (150) + margin
        for (auto& [cc, rec] : meshes_) {
            if (!rec.has_buffers || rec.index_count == 0) continue;
            V3 sctr{(float(cc.x) + 0.5f) * kChunkDim, (float(cc.y) + 0.5f) * kChunkDim, (float(cc.z) + 0.5f) * kChunkDim};
            V3 stoC{sctr.x - camPos.x, sctr.y - camPos.y, sctr.z - camPos.z};
            if (dot(stoC, stoC) > kShadowR * kShadowR) continue;     // beyond the far cascade
            bf_draw_item sd{};
            sd.vertex_buffer = rec.vbuf.handle;
            sd.index_buffer  = rec.ibuf.handle;
            sd.index_count   = rec.index_count;
            sd.chunk_origin  = bf_ivec3{cc.x * kChunkDim, cc.y * kChunkDim, cc.z * kChunkDim};
            shadow_draws.push_back(sd);
        }
        out.shadow_draws = shadow_draws.data();
        out.shadow_draw_count = std::uint32_t(shadow_draws.size());
        out.prop_instances = prop_instances.data();
        out.prop_instance_count = std::uint32_t(prop_instances.size());

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
            e.kind = (cr.model >= 0) ? std::uint32_t(cr.model)            // explicit content model
                   : cr.hostile ? (cr.shape == 1 ? 11u : 5u)
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
    bool    debug_collide_solid(int x, int y, int z) const { return collide_solid(x, y, z); } // #69
    int debug_sky_light(int x, int y, int z) const {
        ChunkCoord cc = to_chunk(IVec3{x, y, z});
        auto* ch = const_cast<ChunkStore&>(store_).get(cc);
        return ch ? int(ch->sky_light(mod16(x), mod16(y), mod16(z))) : -1;
    }
    void    debug_edit(int x, int y, int z, BlockId b) { set_block_internal(IVec3{x, y, z}, b); }
    void    debug_set_sync_streaming(bool s) { sync_stream_ = s; }   // tests: deterministic inline gen
    // #36 regression: stream_tick pops gen_queue_.back() first, so the back MUST be
    // the nearest pending chunk or the world fills from the horizon inward on spawn.
    // Rebuilds the stream set and reports whether the next-to-generate chunk (back)
    // is the closest to the player. Returns true if there's nothing to compare.
    bool    debug_stream_back_is_nearest() {
        recompute_stream_set();
        if (gen_queue_.size() < 2) return true;
        return dist2(gen_queue_.back(), last_center_) <= dist2(gen_queue_.front(), last_center_);
    }
    bool    debug_has_target() const { return has_target_; }
    void    debug_set_selected(std::uint8_t s) { selected_ = s; }
    float   debug_region_sat(int cx, int cz) const { return region_sat(ChunkCoord{cx, 0, cz}); }
    ItemId  debug_item_id(const char* n) const { return item_id_by_name(n); }
    int     debug_item_count(ItemId id) const { return inv_ ? int(inv_->count_item(id)) : 0; }
    void    debug_give(ItemId id, std::uint16_t n) { if (inv_) inv_->add(ItemStack{id, n, 0xFFFF}); }
    void    debug_clear_inventory() {
        if (inv_) for (int i = 0; i < BF_INVENTORY_SLOTS; ++i) inv_->set(std::size_t(i), ItemStack{});
    }
    int     debug_creature_count() const { return int(creatures_.size()); }
    int     debug_villager_count() const { int n=0; for (auto& c : creatures_) if (c.model == 20) ++n; return n; }   // #39
    int     debug_boss_count() const { int n=0; for (auto& c : creatures_) if (c.is_boss) ++n; return n; }
    int     debug_count_named(const char* nm) const { int n=0; for (auto& c : creatures_) if (c.name == nm) ++n; return n; }
    int     debug_resident_count() const { return int(store_.resident_count()); }   // streaming probe
    int     debug_hostile_count() const {
        int n = 0; for (auto& c : creatures_) if (c.hostile) ++n; return n;
    }
    float   debug_health() const { return health_; }
    float   debug_day_time() const { return day_time(world_clock_); }
    int     debug_quests_completed() const { return quests_completed_; }
    bool    debug_all_quests_done() const { return all_quests_done_; }   // #41 win state
    int     debug_regions_restored() const { return regions_restored_; } // #41 Grey receding
    std::uint32_t debug_active_quest() const {
        return (extra_ && active_quest_ < extra_->quests().size() && !all_quests_done_)
             ? extra_->quests()[active_quest_].id : 0u;
    }
    void    debug_notify(const char* trig, const char* target) { notify_quest(trig, target); }
    void    debug_force_quest_done() { quests_completed_ = 1; }   // tests: lift the first-quest monster gate
    void    debug_spawn_named(const char* nm) {                   // tests: drop a named creature 5m from the player
        Creature c; c.name = nm ? nm : ""; c.pos = pos_ + V3{5.0f, -1.0f, 0.0f}; c.hp = 5; c.scale = 1.0f;
        if (extra_) for (auto& d : extra_->creatures()) if (d.name == c.name) { c.is_boss = (d.disposition == "boss"); c.model = d.model; break; }
        creatures_.push_back(c);
    }

    // Fill the FULL quest progression list (for the #42 overview screen). Returns the
    // total quest count; writes min(count, cap) entries. Mirrors the active-quest HUD
    // fill so the screen and the top-left tracker agree.
    std::uint32_t fill_quest_list(bf_quest_entry* out, std::uint32_t cap) const {
        if (!extra_) return 0;
        const auto& qs = extra_->quests();
        std::uint32_t n = std::uint32_t(qs.size());
        for (std::uint32_t i = 0; i < n && i < cap; ++i) {
            const QuestDefX& q = qs[i];
            bf_quest_entry& e = out[i];
            std::memset(&e, 0, sizeof(e));
            std::strncpy(e.title, q.title.c_str(), sizeof(e.title) - 1);
            const bool done   = all_quests_done_ || i < std::uint32_t(active_quest_);
            const bool active = !all_quests_done_ && std::size_t(i) == active_quest_;
            e.state = done ? std::uint8_t(BF_QUEST_DONE)
                           : (active ? std::uint8_t(BF_QUEST_ACTIVE) : std::uint8_t(BF_QUEST_UPCOMING));
            if (active && obj_progress_.size() == q.objectives.size()) {
                std::uint32_t cdone = 0, total = 0; const char* objtext = "";
                for (std::size_t k = 0; k < q.objectives.size(); ++k) {
                    total += q.objectives[k].count;
                    cdone += std::min(obj_progress_[k], q.objectives[k].count);
                    if (obj_progress_[k] < q.objectives[k].count && objtext[0] == 0)
                        objtext = q.objectives[k].text.c_str();
                }
                std::strncpy(e.objective, objtext[0] ? objtext : "...", sizeof(e.objective) - 1);
                e.progress = total ? float(cdone) / float(total) : 0.0f;
            } else {
                e.progress = done ? 1.0f : 0.0f;
                if (!q.objectives.empty())
                    std::strncpy(e.objective, q.objectives.front().text.c_str(), sizeof(e.objective) - 1);
            }
        }
        return n;
    }
    // #41 quest-target compass: the nearest LOADED creature the active quest wants
    // you to reach (befriend_creature / calm_boss). Returns false when the current
    // objective isn't creature-based or no matching creature is spawned nearby.
    bool fill_quest_target(bf_quest_target* out) const {
        if (!out) return false;
        std::memset(out, 0, sizeof(*out));
        if (!extra_ || all_quests_done_ || active_quest_ >= extra_->quests().size()) return false;
        const QuestDefX& q = extra_->quests()[active_quest_];
        if (obj_progress_.size() != q.objectives.size()) return false;
        const QuestObjX* obj = nullptr;
        for (std::size_t i = 0; i < q.objectives.size(); ++i) {
            const auto& o = q.objectives[i];
            if (obj_progress_[i] >= o.count) continue;               // already satisfied
            if (o.trigger == "befriend_creature" || o.trigger == "calm_boss") { obj = &o; break; }
        }
        if (!obj || obj->target.empty()) return false;
        const Creature* best = nullptr; float bestd2 = 1e30f;
        for (const auto& c : creatures_) {
            if (c.name != obj->target) continue;
            float dx = c.pos.x - pos_.x, dy = c.pos.y - pos_.y, dz = c.pos.z - pos_.z;
            float d2 = dx*dx + dy*dy + dz*dz;
            if (d2 < bestd2) { bestd2 = d2; best = &c; }
        }
        if (!best) return false;                                     // target not loaded -> hide marker
        out->active   = 1;
        out->is_boss  = (obj->trigger == "calm_boss") ? 1u : 0u;
        out->position = bf_vec3{best->pos.x, best->pos.y, best->pos.z};
        out->distance = std::sqrt(bestd2);
        // Title-case the creature name for the label: "gloom_stag" -> "Gloom Stag".
        std::string lbl = best->name; bool up = true;
        for (char& ch : lbl) {
            if (ch == '_') { ch = ' '; up = true; }
            else if (up && ch >= 'a' && ch <= 'z') { ch = char(ch - 32); up = false; }
            else up = false;
        }
        std::strncpy(out->label, lbl.c_str(), sizeof(out->label) - 1);
        return true;
    }
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
    static float day_time(double clock) { return float(std::fmod(clock * 0.00175 + 0.30, 1.0)); }  // ~25% shorter cycle (#3)

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
        for (std::uint32_t i = 0; i < content_->recipe_count() && out.size() < 24; ++i) {
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
            // Count each crafted ITEM toward the quest, not each craft action — one
            // craft of the torch recipe yields 4 torches, so "craft 4 torches"
            // completes in a single craft instead of needing four.
            int made = (r.result_count > 0) ? int(r.result_count) : 1;
            for (int k = 0; k < made; ++k) notify_quest("craft_item", item_name(r.result_item));
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
        {"collect_item", "oak_log",  1,  "Knock On Wood"},
        {"mine_block",   "oak_log",  3,  "Timberrr!"},
        {"collect_item", "dirt",     16, "Dirt Rich"},
        {"mine_block",   "stone",    1,  "Between a Rock"},
        {"craft_item",   "",         1,  "Arts & Crafts"},
        {"mine_block",   "coal_ore", 1,  "Coal Digger"},
        {"mine_block",   "iron_ore", 1,  "Pumping Iron"},
        {"place_block",  "",         10, "Block Party"},
        {"collect_item", "mushroom", 1,  "Fun Guy"},
        {"place_block",  "crafting_table", 1, "Table Manners"},
        // Mid / late-game goals so there's always something to chase.
        {"befriend_creature", "",   1,  "Best Friends Furever"},
        {"defeat_animal",     "",   1,  "Circle of Life"},
        {"defeat_monster",    "",   1,  "Who's Scared Now?"},
        {"mine_block",   "iron_ore", 5,  "Iron Will"},
        {"collect_item", "color_dust", 4, "Tickled Pink"},
        {"reach_location", "dim_barrens", 1, "Into the Grey"},
        {"calm_boss",    "",         1,  "Big Softie"},
        {"light_beacon", "",         1,  "Guiding Light"},
        {"restore_region", "dim_barrens", 1, "True Colors"},
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
    // #69 an OPEN door (50) is passable; a CLOSED door (33) blocks you like any wall.
    static bool solid_block(BlockId b) { return b != AIR && b != WATER && b != 50u && !is_plant(b); }
    // Footstep terrain class for the ground you are standing on: 0 soft (grass/dirt),
    // 1 hard (stone/brick/cobble), 2 sand, 3 snow/ice, 4 wood. The app plays a different,
    // gentler step sound per class.
    static int footstep_class(BlockId b) {
        switch (b) {
            case 3: case 8: case 10: case 29: return 1;                         // stone/brick/cobble/mossy
            case 6:                           return 2;                         // sand
            case 12: case 13:                 return 3;                         // snow / ice
            case 4: case 23: case 21: case 22: case 49: case 51: case 33: return 4;  // wood
            default:                          return 0;                         // grass / dirt / soft
        }
    }
    // Cheap biome label from the surface block under the player + nearby trees.
    // Authoritative biome at the player, straight from worldgen (0=Plains 1=Forest
    // 2=Mountains 3=Desert 4=Snowy 5=Swamp 6=Beach) — the old block-sniffing
    // heuristic couldn't tell Swamp/Mountains apart, so those biomes' animals never
    // spawned. (#10)
    int biome_id() const { return worldgen_dominant_biome(ifloor(pos_.x), ifloor(pos_.z), seed_); }
    const char* biome_label() const {
        // Water surface reads as "Ocean" regardless of the underlying biome.
        if (block_at(IVec3{ifloor(pos_.x), ifloor(pos_.y) - 1, ifloor(pos_.z)}) == WATER) return "Ocean";
        switch (biome_id()) {
            case 1: return "Forest";   case 2: return "Mountains"; case 3: return "Desert";
            case 4: return "Snowy";    case 5: return "Swamp";     case 6: return "Beach";
            default: return "Plains";
        }
    }
    // Player's biome mapped to the content vocabulary (for biome-specific spawns).
    const char* biome_key() const {
        switch (biome_id()) {
            case 1: return "forest";   case 2: return "mountains"; case 3: return "desert";
            case 4: return "snowy";    case 5: return "swamp";     case 6: return "beach";
            default: return "plains";
        }
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
    // Pass-through decorations (no player/entity collision): all sub-voxel props
    // (flowers..fallen stick) plus tree LEAVES (oak 5, birch 27). Like plants, you walk
    // through them and break them but they never block movement. Leaves being solid made
    // jumping on tree tops feel weird (cube collision under organic puffs), #62. The
    // trunk logs stay solid, so trees still block you. (#: prop collision)
    static bool is_plant(BlockId b) { return (b >= 36 && b <= 47) || b == 5 || b == 27 || b == 48; }
    bool collide_solid(int x, int y, int z) const {
        BlockId b = block_at(IVec3{x, y, z});
        return b != AIR && b != WATER && b != 50u && !is_plant(b);  // #69 open door passable
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

    // Does voxel v fall inside the player's AABB? Used to stop you from placing
    // a solid block into yourself (which would trap you in place).
    bool voxel_in_player_box(IVec3 v) const {
        const float hw = 0.3f;
        int x0 = ifloor(pos_.x - hw), x1 = ifloor(pos_.x + hw);
        int z0 = ifloor(pos_.z - hw), z1 = ifloor(pos_.z + hw);
        int y0 = ifloor(pos_.y - 1.6f), y1 = ifloor(pos_.y + 0.2f);
        return v.x >= x0 && v.x <= x1 && v.y >= y0 && v.y <= y1 && v.z >= z0 && v.z <= z1;
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
        else if (disp == "hostile") {                          // dark, menacing (but cartoonish)
            V3 base = hue_rgb(0.72f + 0.15f * h);              // purples/greens
            return V3{base.x * 0.45f, base.y * 0.45f, base.z * 0.55f};
        }
        return hue_rgb(h);
    }
    // Spawn one creature on real ground in a ring around the player; returns
    // false if no ground was found there yet (try again next tick).
    bool spawn_ring_creature(bool boss, float rmin, float rmax) {
        float ang = rand01() * 6.2831853f, r = rmin + rand01() * (rmax - rmin);
        float cx = pos_.x + std::cos(ang) * r, cz = pos_.z + std::sin(ang) * r;
        int gy = floor_below(ifloor(cx), int(pos_.y) + 30, ifloor(cz));
        if (gy == kNoFloor) return false;
        // Don't drop a land animal into a lake/ocean (its body cell would be water) — #27.
        if (block_at(IVec3{ifloor(cx), gy + 1, ifloor(cz)}) == WATER) return false;
        Creature c;
        c.pos = V3{cx, float(gy), cz}; c.yaw = rand01() * 6.2831853f;
        c.wander = 1.0f + rand01() * 2.0f; c.is_boss = boss;
        if (extra_ && !extra_->creatures().empty()) {
            std::vector<const CreatureDefX*> pool;
            const char* bk = biome_key();
            for (auto& d : extra_->creatures()) {
                if ((d.disposition == "boss") != boss) continue;
                if (d.model == 20) continue;   // villagers (#39) spawn only at structures
                if (!boss && (d.disposition == "hostile" || d.disposition == "aquatic")) continue;
                // Biome-gate BOTH animals and bosses so each appears where its quest
                // expects it (e.g. stone_basilisk in mountains) instead of any boss
                // anywhere — which let you calm the wrong boss for the active quest. (#41)
                if (!(d.biome.empty() || d.biome == "any" || d.biome == bk)) continue;
                pool.push_back(&d);
            }
            // Never fail to spawn: if the biome filter emptied the pool, drop the gate.
            if (pool.empty())
                for (auto& d : extra_->creatures()) {
                    if ((d.disposition == "boss") != boss) continue;
                    if (d.model == 20) continue;
                    if (!boss && (d.disposition == "hostile" || d.disposition == "aquatic")) continue;
                    pool.push_back(&d);
                }
            if (!pool.empty()) {
                const CreatureDefX* d = pool[std::size_t(rand01() * float(pool.size())) % pool.size()];
                c.name = std::string(d->name);
                c.color = color_for(boss ? "boss" : d->disposition, d->id);
                c.speed = boss ? d->move_speed * 0.7f : d->move_speed;
                c.shape = int(d->id) % 8;            // legacy model variant
                c.model = d->model;                  // explicit content model (-1 = use shape)
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
        // #74: never spawn monsters in lit areas — torches and lamps make a safe zone.
        // Block light 14 (torch) falls off ~1/block, so a >=7 reading means within about
        // 7 blocks of a light. So placing torches around your base keeps it monster-free.
        {
            ChunkCoord lc = to_chunk(IVec3{ifloor(cx), gy, ifloor(cz)});
            if (auto* lch = store_.get(lc)) {
                int bl = int(lch->block_light(mod16(ifloor(cx)), mod16(gy), mod16(ifloor(cz))));
                if (bl >= 7) return false;   // lit by a nearby torch/lamp — no spawn here
            }
        }
        Creature c;
        c.pos = V3{cx, float(gy), cz}; c.yaw = rand01() * 6.2831853f;
        c.hostile = true; c.scale = 1.0f;
        // Prefer a content "hostile" monster (slime/spider/ghost + the legacy two);
        // fall back to the built-in beast/lurker if none are defined.
        std::vector<const CreatureDefX*> pool;
        if (extra_)
            for (auto& d : extra_->creatures()) if (d.disposition == "hostile") pool.push_back(&d);
        if (!pool.empty()) {
            const CreatureDefX* d = pool[std::size_t(rand01() * float(pool.size())) % pool.size()];
            c.name = std::string(d->name);
            c.model = d->model;
            c.speed = (d->move_speed > 0) ? d->move_speed : 2.6f;
            c.hp = (d->max_health > 0) ? int(d->max_health) : 6;
            c.color = color_for("hostile", d->id);
        } else {
            c.speed = 2.6f; c.hp = 6;
            c.shape = (rand01() < 0.5f) ? 1 : 0;   // 1=humanoid(kind11), 0=beast(kind5)
            c.color = (c.shape == 1) ? V3{0.16f, 0.13f, 0.20f} : V3{0.12f, 0.10f, 0.16f};
            c.name = (c.shape == 1) ? "lurker" : "monster";
        }
        creatures_.push_back(c);
        return true;
    }

    // A fish that swims in nearby water (renders as its content model). (#20)
    bool spawn_fish(float rmin, float rmax) {
        if (!extra_) return false;
        std::vector<const CreatureDefX*> pool;
        for (auto& d : extra_->creatures()) if (d.disposition == "aquatic") pool.push_back(&d);
        if (pool.empty()) return false;
        float ang = rand01() * 6.2831853f, r = rmin + rand01() * (rmax - rmin);
        int wx = ifloor(pos_.x + std::cos(ang) * r), wz = ifloor(pos_.z + std::sin(ang) * r);
        int wy = kNoFloor;                                   // find a water cell in the column
        for (int y = ifloor(pos_.y) + 4; y > ifloor(pos_.y) - 20; --y)
            if (block_at(IVec3{wx, y, wz}) == WATER) { wy = y; break; }
        if (wy == kNoFloor) return false;
        const CreatureDefX* d = pool[std::size_t(rand01() * float(pool.size())) % pool.size()];
        Creature c;
        c.pos = V3{float(wx) + 0.5f, float(wy), float(wz) + 0.5f};
        c.yaw = rand01() * 6.2831853f; c.aquatic = true; c.model = d->model;
        c.name = std::string(d->name);
        c.speed = (d->move_speed > 0) ? d->move_speed : 2.0f;
        c.hp = (d->max_health > 0) ? int(d->max_health) : 3;
        c.scale = 0.55f; c.color = color_for("aquatic", d->id);
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
        // Knockback away from the player so hits read as impacts. Bosses are heavy:
        // they barely budge, so you can stand and fight instead of chasing a fleeing
        // boss across the map for every hit of a multi-hit fight. (#41 boss feel)
        float ax = cr.pos.x - pos_.x, az = cr.pos.z - pos_.z;
        float ad = std::sqrt(ax*ax + az*az);
        float kb = cr.is_boss ? 0.25f : 1.3f;
        if (ad > 0.01f) { cr.pos.x += ax/ad * kb; cr.pos.z += az/ad * kb; }
        cr.vy = cr.is_boss ? 0.8f : 3.0f;               // little hop on hit (bosses barely)
        fx(8, cv);                                       // hit thwack
        if (cr.hp <= 0) {
            bool boss = cr.is_boss, hostile = cr.hostile; std::string nm = cr.name;
            drop_creature_loot(cr);
            creatures_.erase(creatures_.begin() + std::ptrdiff_t(idx));
            ++creatures_calmed_;
            fx(5, player_voxel());                       // poof
            // Killing a peaceful animal is NOT befriending it (that's BF_ACT_INTERACT).
            notify_quest(boss ? "calm_boss" : (hostile ? "defeat_monster" : "defeat_animal"), nm);
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
        if (dur == 0) {
            // Consume ONE tool from the slot (don't wipe the whole stack — matters
            // if a tool ever has max_stack > 1). The next one starts fresh.
            sel.count = std::uint16_t(sel.count > 0 ? sel.count - 1 : 0);
            inv_->set(std::size_t(selected_), sel.count == 0 ? ItemStack{}
                                                            : ItemStack{sel.item, sel.count, 0xFFFF});
            fx(0, target_, 0);   // snap!
        } else { sel.durability = dur; inv_->set(std::size_t(selected_), sel); }
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

    // Place the held block at the targeted face. Extracted so right-click INTERACT can
    // fall back to it when there is nothing to interact with. (#69)
    void perform_place() {
        if (!has_target_ || !inv_) return;
        ItemStack sel = inv_->get(selected_);
        if (sel.item == 0) return;
        const ItemDef* idef = items_ ? items_->by_id(sel.item) : nullptr;
        BlockId pb = idef ? idef->places_block : 0;
        if (pb == 0) return;                    // not a placeable item
        {
            bool solid = !(pb == AIR || pb == WATER || (pb >= 36 && pb <= 47));
            if (mode_ == BF_MODE_SURVIVAL && solid && voxel_in_player_box(place_)) return;
        }
        if (mode_ == BF_MODE_SURVIVAL && !inv_->remove_item(sel.item, 1)) return;
        set_block_internal(place_, pb);
        fx(1, place_);                          // place sound
        notify_quest("place_block", block_name(pb));
        if (pb == glow_id_ || (beacon_id_ != 0 && pb == beacon_id_)) {
            notify_quest("light_beacon", block_name(pb));
            ChunkCoord rc = to_chunk(place_);
            if (region_sat(rc) < 0.99f) { ++regions_restored_; notify_quest("restore_region", "dim_barrens"); }
            restore_region(rc);
        }
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
                if (broken == 50u) drop = item_id_by_name("oak_door");  // #69 open door drops the door item
                if (broken == 51u) drop = item_id_by_name("oak_log");   // wood beam is wood -> a log
                if (drop) {
                    inv_->add(ItemStack{drop, 1, 0xFFFF});
                    fx(7, t);                                      // pickup sound
                    notify_quest("collect_item", item_name(drop));
                }
            }
            set_block_internal(t, AIR);
            // #73: a plant, flower, grass, or rock resting on this block has lost its
            // support, so break it too (and drop it if it drops) instead of leaving it
            // floating.
            IVec3 above{t.x, t.y + 1, t.z};
            BlockId ab = block_at(above);
            if (is_prop_block(ab)) {
                if (inv_ && blocks_) {
                    const BlockDef* abd = blocks_->by_id(ab);
                    ItemId adrop = abd ? abd->drop_item : ItemId(0);
                    if (adrop) {
                        inv_->add(ItemStack{adrop, 1, 0xFFFF});
                        notify_quest("collect_item", item_name(adrop));
                    }
                }
                set_block_internal(above, AIR);
            }
            apply_gravity_above(t);                                // undermined sand/gravel falls
            flow_water(t);                                         // adjacent water flows in + falls
        }
    }
    // ---- Wave 3: destruction physics ---------------------------------------
    static bool is_gravity_block(BlockId b) { return b == 6 || b == 11; }   // sand, gravel
    static bool is_log(BlockId b)           { return b == 21 || b == 22 || b == 49; }  // oak/birch/pine log
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
                } else {
                    // Gravity block settles. If the landing cell is already taken
                    // (another block from the same column settled this same frame),
                    // stack upward to the first free cell instead of vanishing.
                    IVec3 settle = land; int guard = 0;
                    while (block_at(settle) != AIR && guard++ < 64) settle.y += 1;
                    if (block_at(settle) == AIR) {
                        set_block_internal(settle, fb.block);
                        fx(0, settle, (int(fb.block) << 4) | sound_class_for(fb.block));
                    }
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
        // Real cave/underground = actual ROCK directly overhead — NOT just a tree
        // canopy. (The old depth-vs-surface_top check treated a tree's leaves as the
        // "surface", so standing under a tree spawned monsters in daylight. #2)
        // "In a cave" = well below the terrain surface (from worldgen height, which
        // ignores trees) — robust even in tall chambers where the rock ceiling is
        // far overhead, unlike the old short overhead scan that missed them. (#7)
        bool darkCave = surv &&
            (worldgen_surface_height(ifloor(pos_.x), ifloor(pos_.z), seed_) - ifloor(pos_.y)) > 6;
        // First-night grace: no monsters until the kid finishes their first quest,
        // so a brand-new player gets a safe session to learn before the scary part.
        bool monstersActive = (night || darkCave) && quests_completed_ > 0;
        // Monsters flee only when it's both daytime AND lit (safe).
        if (!monstersActive)
            creatures_.erase(std::remove_if(creatures_.begin(), creatures_.end(),
                [](const Creature& c){ return c.hostile; }), creatures_.end());
        int ambient = 0, bosses = 0, hostiles = 0;
        // Villagers (model 20) are structure-spawned (#39), not part of the ambient
        // day-animal budget — don't let them block animal spawns.
        for (auto& c : creatures_) { if (c.hostile) ++hostiles; else if (c.is_boss) ++bosses; else if (c.model != 20) ++ambient; }
        creature_timer_ = 1.0f;   // default cadence when nothing needs spawning
        if (monstersActive) {
            // Pace hostile spawns so caves/night are challenging but explorable (#7):
            // a small cap and a long gap between spawns instead of a constant swarm.
            creature_timer_ = 2.5f;
            if (hostiles < 4) spawn_hostile(10.0f, 22.0f);
        } else if (ambient < 9) {
            creature_timer_ = (ambient < 6) ? 0.1f : 0.5f;   // fill day-animals fast (pacing is only for hostiles, #7)
            spawn_ring_creature(false, 8.0f, 26.0f);
        } else if (bosses < 2) {
            creature_timer_ = 1.0f;
            spawn_ring_creature(true, 18.0f, 40.0f);
        }
        // Fish swim in nearby water, independent of the land-spawn chain (#20).
        int fish = 0; for (auto& c : creatures_) if (c.aquatic) ++fish;
        if (fish < 4 && rand01() < 0.5f) spawn_fish(6.0f, 22.0f);
    }

    // #39: put friendly PEOPLE at structures. Sample the structure grid around the
    // player; for each structure within range that has no villager yet, spawn one.
    // Keyed on presence (not a persistent set) so villagers respawn if you leave and
    // return. Villagers are content creatures with model 20 (the humanoid).
    void maintain_villagers(float dt) {
        if (!gen_ || !extra_ || store_.resident_count() < 20) return;
        villager_timer_ -= dt;
        if (villager_timer_ > 0) return;
        villager_timer_ = 2.0f;
        // Cap nearby people so dense structure clusters don't mob the player.
        constexpr int kVillagerCap = 6;
        int have = 0; for (auto& c : creatures_) if (c.model == 20) ++have;
        if (have >= kVillagerCap) return;
        int px = ifloor(pos_.x), pz = ifloor(pos_.z);
        for (int dz = -128; dz <= 128; dz += 64)
        for (int dx = -128; dx <= 128; dx += 64) {
            if (have >= kVillagerCap) return;
            std::int32_t ax = 0, az = 0; int ay = 0;
            if (worldgen_structure_near(px + dx, pz + dz, seed_, &ax, &az, &ay) == 0) continue;
            float ddx = float(ax) - pos_.x, ddz = float(az) - pos_.z;
            if (ddx*ddx + ddz*ddz > 80.0f * 80.0f) continue;          // only nearby ones
            if (!store_.is_resident(to_chunk(IVec3{ax, ay, az}))) continue;
            bool present = false;
            for (auto& c : creatures_)
                if (c.model == 20 && std::abs(c.pos.x - float(ax)) < 10 && std::abs(c.pos.z - float(az)) < 10) { present = true; break; }
            if (present) continue;
            have += spawn_villager_at(ax, ay, az, kVillagerCap - have);
        }
    }
    int spawn_villager_at(int ax, int ay, int az, int budget) {
        std::vector<const CreatureDefX*> pool;
        for (auto& d : extra_->creatures()) if (d.model == 20) pool.push_back(&d);
        if (pool.empty() || budget <= 0) return 0;
        int n = std::min(budget, 1 + (rand01() < 0.5f ? 1 : 0));      // 1-2 people per structure
        int made = 0;
        for (int i = 0; i < n; ++i) {
            float ox = float(ax) + (rand01() * 5.0f - 2.5f);
            float oz = float(az) + (rand01() * 5.0f - 2.5f);
            int gy = floor_below(ifloor(ox), ay + 4, ifloor(oz));
            if (gy == kNoFloor) continue;
            if (block_at(IVec3{ifloor(ox), gy + 1, ifloor(oz)}) == WATER) continue;
            const CreatureDefX* d = pool[std::size_t(rand01() * float(pool.size())) % pool.size()];
            Creature c;
            c.pos = V3{ox, float(gy), oz}; c.yaw = rand01() * 6.2831853f;
            c.model = d->model;                                      // 20 = humanoid villager
            c.npc_id = (villager_npc_next_++ % 3) + 1;               // #82 cycle Mira/Tom/Lena
            c.name = std::string(d->name);
            c.speed = (d->move_speed > 0) ? d->move_speed * 0.5f : 0.8f;   // amble slowly
            c.hp = (d->max_health > 0) ? int(d->max_health) : 20;
            c.scale = 0.95f; c.color = color_for("passive", d->id);
            c.wander = 1.0f + rand01() * 2.0f;
            creatures_.push_back(c); ++made;
        }
        return made;
    }

    void update_creatures(float dt) {
        for (auto& c : creatures_) {
            c.wander -= dt;
            if (c.hit_flash > 0) c.hit_flash -= dt;
            V3 toPlayer = pos_ - c.pos;
            // Fish: swim within water, gently bob, turn back at the water's edge —
            // no land gravity/floor logic. (#20)
            if (c.aquatic) {
                if (c.wander <= 0.0f) { c.yaw = rand01() * 6.2831853f; c.wander = 1.0f + rand01() * 2.0f; }
                V3 d2{std::sin(c.yaw), 0, std::cos(c.yaw)};
                V3 nx = c.pos + d2 * (c.speed * dt);
                if (block_at(IVec3{ifloor(nx.x), ifloor(nx.y), ifloor(nx.z)}) == WATER) {
                    c.pos.x = nx.x; c.pos.z = nx.z;
                } else if (c.wander <= 0.0f) {                  // edge of water — turn back (gated, no spin)
                    c.yaw += 2.0f + rand01() * 2.2f; c.wander = 0.6f + rand01() * 0.6f;
                }
                c.pos.y += std::sin(float(world_clock_) * 2.0f + c.pos.x) * 0.4f * dt;   // bob
                // stay submerged: sink toward water if we drifted above it
                if (block_at(IVec3{ifloor(c.pos.x), ifloor(c.pos.y), ifloor(c.pos.z)}) != WATER &&
                    block_at(IVec3{ifloor(c.pos.x), ifloor(c.pos.y) - 1, ifloor(c.pos.z)}) == WATER)
                    c.pos.y -= 0.5f * dt * 4.0f;
                continue;
            }
            // In Creative the monsters leave you alone (no chase, no damage).
            if (c.hostile && mode_ == BF_MODE_SURVIVAL) {
                if (c.atk_cd > 0) c.atk_cd -= dt;
                float xzd = std::sqrt(toPlayer.x*toPlayer.x + toPlayer.z*toPlayer.z);
                // Aggro perimeter (#8): only chase + bite within range; beyond it they
                // give up and wander, so they don't track you across the whole world.
                constexpr float kAggro = 16.0f;
                if (xzd < kAggro) {
                    if (dot(toPlayer, toPlayer) > 0.0001f) c.yaw = std::atan2(toPlayer.x, toPlayer.z);
                    // Bite test in XZ (+ a vertical guard): pos_ is the EYE (~1.6 above
                    // the creature's feet), so a plain 3D distance never got close enough.
                    float yd = std::fabs((c.pos.y + c.scale * 0.5f) - (pos_.y - 1.6f));
                    if (xzd < 1.3f && yd < 1.6f && c.atk_cd <= 0.0f) { hurt_player(2.5f); c.atk_cd = 1.1f; }
                } else if (c.wander <= 0.0f) {                  // out of range — lose interest
                    c.yaw = rand01() * 6.2831853f; c.wander = 1.5f + rand01() * 2.5f;
                }
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
            // Land creatures refuse to step into water and turn away (#21); aquatic
            // ones (fish) ignore this. Use collide_solid so creatures still walk
            // THROUGH grass/flowers/mushrooms instead of bumping into them.
            bool intoWater = !c.aquatic && (block_at(IVec3{nv.x, nv.y, nv.z}) == WATER
                                         || block_at(IVec3{nv.x, nv.y - 1, nv.z}) == WATER);
            if (!intoWater && !collide_solid(nv.x, nv.y, nv.z)) {
                c.pos.x = next.x; c.pos.z = next.z;                       // clear path
            } else if (!intoWater && !collide_solid(nv.x, nv.y + 1, nv.z)) {
                c.pos.x = next.x; c.pos.z = next.z; c.pos.y += 1.0f;      // step up a 1-block ledge
            } else if (c.wander <= 0.0f) {
                // Blocked by water or a wall: pick a NEW heading, but only when the
                // wander cooldown elapses — turning every frame made stuck animals
                // spin frantically in place (#27).
                c.yaw += 2.0f + rand01() * 2.2f; c.wander = 0.6f + rand01() * 0.6f;
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
        const bool creative = (mode_ == BF_MODE_CREATIVE);
        const int  nearR    = 5;                          // full vertical band within this radius
        const int  playerCy = floordiv(ifloor(pos_.y), kChunkDim);
        for (int dx = -stream_r_; dx <= stream_r_; ++dx)
        for (int dz = -stream_r_; dz <= stream_r_; ++dz) {
            // Surface-priority (#36): near the player (or in creative) stream the
            // full vertical band (so caves/digging load); FAR away only stream the
            // chunks around the SURFACE — no deep underground you can't see. This
            // is what makes a large horizontal render distance affordable.
            const bool near = creative || (std::abs(dx) <= nearR && std::abs(dz) <= nearR);
            int surfCy = playerCy;
            if (!near) {
                // Cache surface chunk-y per column — recompute_stream_set runs on every
                // chunk-boundary cross over (2*stream_r+1)^2 columns, and the height
                // query isn't free; without the cache this spiked the 1%-low at large
                // radius. worldgen_surface_height is pure, so caching is exact.
                std::int64_t key = (std::int64_t(c.x + dx) << 32) | std::uint32_t(c.z + dz);
                auto it = surf_cy_cache_.find(key);
                if (it != surf_cy_cache_.end()) surfCy = it->second;
                else {
                    int sy = worldgen_surface_height((c.x + dx) * kChunkDim + kChunkDim/2,
                                                     (c.z + dz) * kChunkDim + kChunkDim/2, seed_);
                    surfCy = floordiv(sy, kChunkDim);
                    if (surf_cy_cache_.size() > 200000) surf_cy_cache_.clear();   // bound memory
                    surf_cy_cache_[key] = surfCy;
                }
            }
            // Stream the full VISIBLE vertical span of this far column: from the
            // player's level (or the surface, if the player is above it) up to just
            // over the surface. The old band (surfCy±1) streamed only the top ~48
            // blocks, so a tall mountain beyond the near-radius rendered only its cap
            // and its whole body was a hole. We still skip everything BELOW the player
            // far away, so deep caves stay unstreamed (memory + the dark-cave fix). (#5)
            int lo = std::min(playerCy, surfCy) - 1;
            int hi = surfCy + 1;
            for (int cy = CY_MIN; cy <= CY_MAX; ++cy) {
                bool want = near || (cy >= lo && cy <= hi);
                if (!want) continue;
                ChunkCoord cc{c.x + dx, cy, c.z + dz};
                if (!store_.is_resident(cc)) gen_queue_.push_back(cc);
            }
        }
        // Sort FARTHEST-first so the nearest chunk is at the back — stream_tick pops
        // from the back, so the world fills in from the player OUTWARD. (#36: this was
        // ascending, which popped the farthest chunk first and made spawn-in visibly
        // backfill the surface from the horizon inward.)
        std::sort(gen_queue_.begin(), gen_queue_.end(), [&](ChunkCoord a, ChunkCoord b) {
            return dist2(a, c) > dist2(b, c);
        });
        evict_far();
    }
    static long dist2(ChunkCoord a, ChunkCoord c) {
        long dx = a.x - c.x, dz = a.z - c.z; return dx*dx + dz*dz;
    }
    void evict_far() {
        std::vector<ChunkCoord> drop;
        for (auto& [cc, rec] : meshes_) {
            if (std::abs(cc.x - last_center_.x) > stream_r_ + 1 ||
                std::abs(cc.z - last_center_.z) > stream_r_ + 1) drop.push_back(cc);
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
    // Worker-thread entry: generate one chunk (pure fn of seed+coord) and hand it
    // back to the main thread. Touches only gen_ (outlives World) + gen_done_/mtx.
    struct GenTask { World* w; ChunkCoord cc; };
    static void gen_trampoline(void* user) noexcept {
        auto* t = static_cast<GenTask*>(user);
        t->w->run_gen_job(t->cc);
        delete t;
    }
    void run_gen_job(ChunkCoord cc) {
        auto ch = std::make_unique<PaletteChunk>(cc);
        gen_->generate(cc, *ch);
        std::lock_guard<std::mutex> lk(gen_mtx_);
        gen_done_.emplace_back(cc, std::move(ch));
    }

    // How much terrain is still waiting to be generated + meshed.
    std::size_t stream_backlog() const { return gen_queue_.size() + dirty_.size(); }
    // A LARGE backlog means a bulk fill (spawn-in, teleport, or the initial load at a
    // big render distance) — not the small ring added by normal walking. Only then do
    // we crank budgets + recruit the P-cores, so steady-state play never hitches.
    bool bulk_fill() const { return !moving_ && stream_backlog() > 384; }
    // Steady state: E-cores only (Utility), so the render thread on the P-cores is
    // never disturbed. Bulk fill: alternate pools so the idle P-cores pitch in too —
    // terrain is otherwise confined to the E-cores while half the machine sits idle.
    JobQoS terrain_qos() {
        if (!bulk_fill()) return JobQoS::Utility;
        return (job_rr_++ & 1u) ? JobQoS::Interactive : JobQoS::Utility;
    }

    void stream_tick() {
        if (!gen_) return;
        // Synchronous mode (tests): generate inline so chunk availability is
        // deterministic per update() call rather than dependent on worker wall-clock.
        if (!sync_stream_ && !sched_) {   // lazy-create workers (init_world + load paths)
            CoreTopology topo = detect_core_topology();
            unsigned e = std::max(2u, topo.e_cores);
            unsigned p = std::max(1u, topo.p_cores > 1 ? topo.p_cores - 1 : 1u);
            sched_ = std::make_unique<JobScheduler>(p, e);
        }
        if (sync_stream_ || !sched_) {
            int made = 0;
            while (!gen_queue_.empty() && made < GEN_BUDGET) {
                ChunkCoord cc = gen_queue_.back(); gen_queue_.pop_back();
                if (store_.is_resident(cc)) continue;
                auto ch = std::make_unique<PaletteChunk>(cc);
                gen_->generate(cc, *ch);
                if (ch->is_uniform() && ch->get(0,0,0) == AIR) { ++made; continue; }
                store_.insert(std::move(ch)); dirty_.insert(cc); ++made;
            }
            return;
        }
        // 1) Collect finished gen chunks (BUDGETED: meshing downstream is the limit,
        // so inserting the whole worker backlog at once explodes dirty_ and the
        // per-frame dirty scan, tanking FPS).
        const bool bulk = bulk_fill();
        const std::size_t kGenCollect = bulk ? 64 : 16;
        std::vector<std::pair<ChunkCoord, std::unique_ptr<PaletteChunk>>> done;
        {
            std::lock_guard<std::mutex> lk(gen_mtx_);
            std::size_t n = std::min<std::size_t>(gen_done_.size(), kGenCollect);
            for (std::size_t i = 0; i < n; ++i) done.push_back(std::move(gen_done_[i]));
            gen_done_.erase(gen_done_.begin(), gen_done_.begin() + std::ptrdiff_t(n));
        }
        for (auto& [cc, ch] : done) {
            gen_inflight_.erase(cc);
            if (store_.is_resident(cc)) continue;
            // Skip pure-air chunks (above terrain) — block_at() returns AIR anyway.
            if (ch->is_uniform() && ch->get(0,0,0) == AIR) continue;
            store_.insert(std::move(ch));
            dirty_.insert(cc);
        }
        // 2) Submit more gen jobs, keeping a bounded number in flight (nearest-first).
        const std::size_t kMaxInFlight = bulk ? 128 : 32;
        while (!gen_queue_.empty() && gen_inflight_.size() < kMaxInFlight) {
            ChunkCoord cc = gen_queue_.back(); gen_queue_.pop_back();
            if (store_.is_resident(cc) || gen_inflight_.count(cc)) continue;
            gen_inflight_.insert(cc);
            sched_->submit(&World::gen_trampoline, new GenTask{this, cc}, terrain_qos());
        }
    }

    // async meshing: a worker greedy-meshes a SnapStore (chunk + neighbour copies)
    // into CPU arrays; the main thread uploads the result to GPU buffers.
    struct MeshTask {
        World* w; ChunkCoord cc; SnapStore snap;
        std::vector<std::byte> vs, is;
        std::uint32_t index_count{0}, vbytes{0}, ibytes{0}; bool empty{true};
    };
    // Worker entry: greedy-mesh the snapshot into CPU arrays; main uploads later.
    static void mesh_trampoline(void* u) noexcept {
        auto* t = static_cast<MeshTask*>(u);
        t->w->run_mesh_job(t);
    }
    void run_mesh_job(MeshTask* t) {
        // Per-WORKER scratch (allocated once, reused). Meshing into a fresh ~2 MB
        // worst-case buffer PER JOB churned memory bandwidth and tanked the frame;
        // mesh into reused scratch, then keep only the actual mesh bytes.
        thread_local std::vector<std::byte> tvs, tis;
        if (tvs.size() < mesher_.max_vertex_bytes()) tvs.resize(mesher_.max_vertex_bytes());
        if (tis.size() < mesher_.max_index_bytes())  tis.resize(mesher_.max_index_bytes());
        MeshResult mr = mesher_.mesh(t->cc, t->snap,
            std::span<std::byte>(tvs.data(), tvs.size()),
            std::span<std::byte>(tis.data(), tis.size()), false);
        t->empty = mr.empty || mr.index_count == 0;
        t->index_count = mr.index_count; t->vbytes = mr.vertex_bytes; t->ibytes = mr.index_bytes;
        if (!t->empty) {
            t->vs.assign(tvs.begin(), tvs.begin() + std::ptrdiff_t(mr.vertex_bytes));
            t->is.assign(tis.begin(), tis.begin() + std::ptrdiff_t(mr.index_bytes));
        }
        std::lock_guard<std::mutex> lk(mesh_mtx_);
        mesh_done_.emplace_back(t);          // unique_ptr takes ownership
    }
    void submit_mesh_job(ChunkCoord cc) {
        auto t = std::make_unique<MeshTask>();
        t->w = this; t->cc = cc;
        auto add = [&](ChunkCoord c) {
            if (auto* ch = static_cast<PaletteChunk*>(store_.get(c))) t->snap.chunks.emplace(c, ch->clone());
        };
        add(cc);
        const IVec3 dirs[6] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
        for (auto d : dirs) add(ChunkCoord{cc.x + d.x, cc.y + d.y, cc.z + d.z});
        mesh_inflight_.insert(cc);
        // Steady state: Utility (E-cores) so mesh work never starves the P-core render
        // thread. Bulk fill: terrain_qos() also recruits the otherwise-idle P-cores so
        // a big load rushes in instead of trickling on the E-cores alone. (#5 fill)
        sched_->submit(&World::mesh_trampoline, t.release(), terrain_qos());
    }
    // #51 — is this block id drawn as a detailed sub-voxel prop (not a cube)?
    static bool is_prop_block(BlockId id) {
        return id >= 36u && id <= 47u;  // all sub-voxel props (flowers..seashell)
    }
    // #62 trees: leaves (oak 5, birch 27, pine 48) + logs (21,22) are drawn as
    // instanced organic models.
    static bool is_tree_block(BlockId id) {
        return id == 5u || id == 27u || id == 48u || id == 21u || id == 22u || id == 49u;
    }
    // Cache the chunk's prop blocks as instances for the prop renderer. Runs once
    // per (re)mesh, not per frame.
    void scan_chunk_props(ChunkCoord cc, MeshRec& rec) {
        rec.props.clear();
        IChunk* ch = store_.get(cc);          // fetch the chunk ONCE, not per cell
        if (!ch) return;
        float sat = region_sat(cc);
        int bx = cc.x * kChunkDim, by = cc.y * kChunkDim, bz = cc.z * kChunkDim;
        for (int lz = 0; lz < kChunkDim; ++lz)
        for (int ly = 0; ly < kChunkDim; ++ly)
        for (int lx = 0; lx < kChunkDim; ++lx) {
            BlockId id = ch->get(lx, ly, lz);   // direct read, no store lookup
            bool prop = is_prop_block(id);
            bool tree = is_tree_block(id);
            if (!prop && !tree) continue;
            // #62: a tree LEAF only emits a foliage instance if it is exposed (has an
            // air/water neighbour) — the visible canopy shell. Interior leaves stay
            // hidden, which keeps the instance count (and so the cost) sane in forests.
            // Logs (the trunk) are sparse, so they always emit. Out-of-chunk neighbours
            // are treated as exposed (a small over-count only at chunk seams).
            if (tree && (id == 5u || id == 27u || id == 48u)) {
                auto see_through = [&](int ax, int ay, int az) -> bool {
                    if (ax < 0 || ay < 0 || az < 0 || ax >= kChunkDim || ay >= kChunkDim || az >= kChunkDim)
                        return true;                       // OOB → assume exposed
                    BlockId n = ch->get(ax, ay, az);
                    return n == 0u || n == 9u;             // air or water
                };
                bool exposed = see_through(lx+1,ly,lz) || see_through(lx-1,ly,lz)
                            || see_through(lx,ly+1,lz) || see_through(lx,ly-1,lz)
                            || see_through(lx,ly,lz+1) || see_through(lx,ly,lz-1);
                if (!exposed) continue;
            }
            std::uint32_t h = std::uint32_t((bx + lx) * 73856093 ^ (by + ly) * 19349663 ^ (bz + lz) * 83492791);
            // #62 taper: a trunk log carries its height above the base (count of
            // contiguous logs below, across chunks) in the seed's high byte, so the
            // renderer can narrow the trunk as it rises. Low 24 bits keep the colour hash.
            if (id == 21u || id == 22u || id == 49u) {
                auto is_log = [&](int dx, int dy, int dz) {
                    BlockId b = block_at(IVec3{bx + lx + dx, by + ly + dy, bz + lz + dz});
                    return b == 21u || b == 22u || b == 49u;
                };
                // #62 branches: a log with no log directly above OR below is a BRANCH
                // (the trunk steps out-and-up diagonally), so it should be drawn lying
                // sideways, not as another vertical log. Trunk logs taper with height.
                bool above = is_log(0, 1, 0), below = is_log(0, -1, 0);
                bool xax = is_log(1,1,0)||is_log(-1,1,0)||is_log(1,-1,0)||is_log(-1,-1,0)||is_log(1,0,0)||is_log(-1,0,0);
                bool zax = is_log(0,1,1)||is_log(0,1,-1)||is_log(0,-1,1)||is_log(0,-1,-1)||is_log(0,0,1)||is_log(0,0,-1);
                if (!above && !below && !xax && !zax) {
                    // Lone log (no neighbours at all): render as a plain upright post, not a
                    // drooping branch. bit31=0 trunk, level 0, no slant. (#62 followup)
                    h = (h & 0x001FFFFFu);
                } else if (!above && !below) {
                    // Branch: a horizontal limb. It lies SIDEWAYS along x or z (bit 30) and
                    // is fattened + extended to bridge to its neighbours; NO downward slant
                    // (that made branches droop and point at the ground). (#62 followup)
                    std::uint32_t axis = (zax && !xax) ? 1u : 0u;   // 0 = x-axis, 1 = z-axis
                    h = 0x80000000u | (axis << 30) | (h & 0x3FFFFFFFu);
                } else {
                    int level = 0;
                    for (int k = 1; k <= 24; ++k) {
                        if (!is_log(0, -k, 0)) break;
                        ++level;
                    }
                    if (level > 127) level = 127;
                    // #62 slant: a trunk block whose VERTICAL below is air but a DIAGONAL
                    // below is a log is a lean-bend (the trunk jogs sideways). Tag it with
                    // the direction of the lower trunk so the renderer slants its base down
                    // toward it, connecting the two segments instead of leaving a gap.
                    std::uint32_t slant = 0, sdir = 0;
                    if (!below) {
                        if      (is_log( 1, -1,  0)) { slant = 1; sdir = 0; }   // lower trunk +x
                        else if (is_log(-1, -1,  0)) { slant = 1; sdir = 1; }   // -x
                        else if (is_log( 0, -1,  1)) { slant = 1; sdir = 2; }   // +z
                        else if (is_log( 0, -1, -1)) { slant = 1; sdir = 3; }   // -z
                    }
                    // bit31=0 trunk, 24-30 level, 23 slant, 21-22 dir, 0-20 colour hash.
                    h = (std::uint32_t(level) << 24) | (slant << 23) | (sdir << 21) | (h & 0x001FFFFFu);
                }
            } else if (id == 38u || id == 42u) {
                // #68 clustering: same-kind plants packed together read as one bigger clump
                // (and shrink as you break pieces, since breaking a cell drops its
                // neighbours' counts on the next re-gather). Count the 8 horizontal
                // same-type neighbours into the seed's top nibble; the renderer scales the
                // model by it. Low 28 bits keep the yaw + colour hash.
                auto same = [&](int dx, int dz) {
                    return block_at(IVec3{bx + lx + dx, by + ly, bz + lz + dz}) == id;
                };
                std::uint32_t dens = 0;
                for (int dz2 = -1; dz2 <= 1; ++dz2)
                    for (int dx2 = -1; dx2 <= 1; ++dx2)
                        if ((dx2 || dz2) && same(dx2, dz2)) ++dens;   // 0..8
                h = (h & 0x0FFFFFFFu) | (dens << 28);
            }
            bf_prop_instance p{};
            p.position = bf_vec3{float(bx + lx), float(by + ly), float(bz + lz)};
            p.type = std::uint32_t(id); p.seed = h; p.sat = sat;
            rec.props.push_back(p);
        }
    }
    void upload_mesh(ChunkCoord cc, MeshTask& t) {
        if (!store_.is_resident(cc)) return;          // evicted while meshing — drop
        MeshRec& rec = meshes_[cc];
        scan_chunk_props(cc, rec);                    // #51 refresh prop cache
        if (rec.has_buffers) {
            alloc_.free_(alloc_.user, rec.vbuf.handle);
            alloc_.free_(alloc_.user, rec.ibuf.handle);
            rec.has_buffers = false;
        }
        if (t.empty) { rec.index_count = 0; return; }
        bf_gpu_buffer vb = alloc_.alloc(alloc_.user, t.vbytes);
        bf_gpu_buffer ib = alloc_.alloc(alloc_.user, t.ibytes);
        if (!vb.contents || !ib.contents) { rec.index_count = 0; return; }
        std::memcpy(vb.contents, t.vs.data(), t.vbytes);
        std::memcpy(ib.contents, t.is.data(), t.ibytes);
        rec.vbuf = vb; rec.ibuf = ib; rec.index_count = t.index_count; rec.has_buffers = true;
    }

    void remesh_dirty() {
        if (!has_alloc_) return;
        ensure_scratch();
        const bool async = !sync_stream_ && sched_ != nullptr;
        // 1) Upload meshes finished on worker threads (allocator is main-thread only).
        // Budgeted: GPU buffer alloc + memcpy is the main-thread cost, so cap how
        // many we upload per frame and let the rest wait (uploading the whole
        // worker backlog in one frame tanks FPS).
        const bool bulk = bulk_fill();
        if (async) {
            const std::size_t kUploadBudget = bulk ? 24 : 8;
            std::vector<std::unique_ptr<MeshTask>> batch;
            {
                std::lock_guard<std::mutex> lk(mesh_mtx_);
                std::size_t n = std::min<std::size_t>(mesh_done_.size(), kUploadBudget);
                for (std::size_t i = 0; i < n; ++i) batch.push_back(std::move(mesh_done_[i]));
                mesh_done_.erase(mesh_done_.begin(), mesh_done_.begin() + std::ptrdiff_t(n));
            }
            for (auto& t : batch) { mesh_inflight_.erase(t->cc); upload_mesh(t->cc, *t); }
        }
        if (dirty_.empty()) return;
        // 2) Order dirty chunks: nearest first, and prefer chunks IN VIEW so what
        // you're looking at pops in first.
        std::vector<ChunkCoord> todo(dirty_.begin(), dirty_.end());
        V3 camFwd = forward_dir();
        auto score = [&](ChunkCoord a) -> double {
            V3 ctr{(float(a.x)+0.5f)*float(kChunkDim),(float(a.y)+0.5f)*float(kChunkDim),(float(a.z)+0.5f)*float(kChunkDim)};
            V3 to{ctr.x - pos_.x, ctr.y - pos_.y, ctr.z - pos_.z};
            float d2 = dot(to, to);                       // 3D distance from the camera
            float facing = dot(to, camFwd) / (std::sqrt(d2) + 0.001f);   // ~1 ahead, <0 behind
            // Prioritise by 3D distance (not horizontal): a surface chunk at eye
            // level meshes before a cave chunk directly under it, so you don't see
            // through a mountain to the caves below it. Behind-camera deprioritised.
            double s = double(d2) * (facing > 0.2f ? 1.0 : 4.0);
            // CRITICAL (#5 swiss-cheese): a NEVER-meshed chunk always beats a re-mesh.
            // The lighting re-dirty cascade re-queues already-drawn chunks faster than
            // the far backlog can fill; without this, ~98% of the mesh budget was spent
            // re-meshing visible chunks while the far field stayed full of holes.
            if (meshes_.find(a) != meshes_.end()) s += 1e15;   // already meshed -> last
            return s;
        };
        const std::size_t meshBudget      = bulk ? 36 : std::size_t(MESH_BUDGET);
        const std::size_t meshInflightCap = bulk ? 192 : 64;
        std::size_t k = std::min<std::size_t>(meshBudget, todo.size());
        std::partial_sort(todo.begin(), todo.begin() + std::ptrdiff_t(k), todo.end(),
                          [&](ChunkCoord a, ChunkCoord b){ return score(a) < score(b); });
        // Re-meshes (already-drawn chunks re-queued by the lighting cascade) are capped
        // so the light-settle churn can't consume the whole budget and tank FPS; fresh
        // (never-meshed) chunks are uncapped so the world always fills first. (#5)
        std::size_t done = 0, remeshes = 0;
        const std::size_t kRemeshCap = bulk ? 12 : 4;
        for (ChunkCoord cc : todo) {
            if (done >= meshBudget) break;
            if (async && (mesh_inflight_.count(cc) || mesh_inflight_.size() >= meshInflightCap)) continue;
            const bool fresh = (meshes_.find(cc) == meshes_.end());
            if (!fresh && remeshes >= kRemeshCap) continue;   // throttle lighting-churn re-meshes
            if (!store_.is_resident(cc)) { dirty_.erase(cc); continue; }
            dirty_.erase(cc);
            if (!fresh) ++remeshes;
            ++done;
            // Light before meshing (the mesher reads per-voxel light). Re-dirty ONLY
            // the neighbours across faces whose boundary light actually changed, so
            // light bleeds across seams and SETTLES — re-dirtying all 6 on any change
            // was a 6x churn that never converged (perpetual re-mesh of the world). (#5)
            std::uint8_t faces = FloodLighting::light_chunk(cc, store_);
            if (faces) {
                const IVec3 dirs[6] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
                for (int f = 0; f < 6; ++f) if (faces & (1u << f)) {
                    ChunkCoord nc{cc.x + dirs[f].x, cc.y + dirs[f].y, cc.z + dirs[f].z};
                    if (store_.is_resident(nc)) dirty_.insert(nc);
                }
            }
            if (async) submit_mesh_job(cc);       // game: mesh on a worker, upload when done
            else       remesh_one(cc);            // sync / no scheduler: inline mesh+upload
        }
    }
    void remesh_one(ChunkCoord cc) {
        MeshRec& rec = meshes_[cc];
        scan_chunk_props(cc, rec);                    // #51 refresh prop cache
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
            std::size_t ncr = std::min<std::size_t>(cr.size(), 24);
            h.craftable_count = std::uint8_t(ncr);
            for (std::size_t i = 0; i < ncr; ++i) {
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
        h.in_dim = region_sat(to_chunk(IVec3{ifloor(pos_.x), ifloor(pos_.y), ifloor(pos_.z)})) < 0.99f ? 1 : 0;
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
    float                         villager_timer_{0.0f};   // #39: structure NPC spawn cadence
    int                           villager_npc_next_{0};   // #82: round-robins villager dialogue ids
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

    // ---- async chunk generation (#25) ------------------------------------
    // Worker threads generate chunks (pure fn of seed+coord); the main thread
    // collects finished chunks and inserts them. gen_done_ is the only shared
    // state (guarded by gen_mtx_); gen_inflight_ is main-thread-only. sched_ is
    // declared LAST so it is destroyed FIRST — its dtor joins workers before the
    // members those jobs touch (gen_done_/gen_mtx_) are destroyed.
    int                                                             stream_r_{6};         // horizontal radius (chunks)
    std::unordered_map<std::int64_t, int>                           surf_cy_cache_;       // per-column surface chunk-y (streaming)
    bool                                                            sync_stream_{false};  // tests: inline gen+mesh
    std::mutex                                                       gen_mtx_;
    std::vector<std::pair<ChunkCoord, std::unique_ptr<PaletteChunk>>> gen_done_;
    std::unordered_set<ChunkCoord, ChunkCoordHash>                   gen_inflight_;
    unsigned                                                         job_rr_{0};   // round-robin P/E pools in bulk fill
    bool                                                             moving_{false}; // player gave movement input this frame
    std::mutex                                                       mesh_mtx_;
    std::vector<std::unique_ptr<MeshTask>>                           mesh_done_;
    std::unordered_set<ChunkCoord, ChunkCoordHash>                   mesh_inflight_;
    std::unique_ptr<JobScheduler>                                    sched_;
};

} // namespace bf
