// ============================================================================
// Blockfall — Internal C++ interfaces (contract/blockcore_interfaces.hpp)
// ----------------------------------------------------------------------------
// FROZEN after Phase 0. Pure interfaces + POD only — NO implementations.
// These are the seams between parallel tracks (spec §6). A track owns its
// interface and may evolve its *implementation* freely; changing an interface
// here requires an ADR because it ripples across tracks.
//
// C++23. Header-only declarations. No heap allocation implied by any signature
// on a hot path (spec §9): callers pass spans/arenas; impls never `new` per
// call. `std::span`/`std::string_view` are borrowed, never owned past a call.
// ============================================================================
#pragma once
#include <cstdint>
#include <span>
#include <string_view>
#include <optional>

namespace bf {

// ---- Shared value types (POD) ---------------------------------------------
using BlockId = std::uint16_t;
using ItemId  = std::uint16_t;
using EntityId = std::uint32_t;   // ECS handle (index+generation packed below)

struct IVec3 { std::int32_t x, y, z; };
struct Vec3  { float x, y, z; };

inline constexpr int    kChunkDim   = 16;            // 16x16x16 (spec §4.2)
inline constexpr int    kChunkVol   = kChunkDim * kChunkDim * kChunkDim;
inline constexpr std::int32_t kColumnMinY = -512;
inline constexpr std::int32_t kColumnMaxY =  512;
inline constexpr int    kRegionChunks = 8;           // 8x8 chunks per region

// ECS handle: 24-bit index + 8-bit generation (stale-handle detection).
struct Entity {
    EntityId raw{0};
    constexpr std::uint32_t index()      const { return raw & 0x00FFFFFFu; }
    constexpr std::uint8_t  generation() const { return std::uint8_t(raw >> 24); }
    constexpr bool          valid()      const { return raw != 0; }
};

// ===========================================================================
// Job system  (Track A — built first; everything depends on it)
// ===========================================================================
enum class JobQoS : std::uint8_t {
    Interactive = 0,  // P-cores: mesh / render-prep / sim
    Utility     = 1,  // E-cores: worldgen / I-O / net / AI
};
using JobFn = void (*)(void* user) noexcept;

// Opaque token a caller can wait on / chain after.
struct JobHandle { std::uint64_t id{0}; };

struct IJobScheduler {
    virtual ~IJobScheduler() = default;
    // Submit one job. `deps` must all complete first. Non-blocking.
    virtual JobHandle submit(JobFn fn, void* user, JobQoS qos,
                             std::span<const JobHandle> deps = {}) = 0;
    virtual void      wait(JobHandle h) = 0;          // block until done
    virtual bool      is_done(JobHandle h) const = 0;
    virtual unsigned  worker_count(JobQoS qos) const = 0;
};

// ===========================================================================
// Memory arenas  (Track A) — zero hot-path heap alloc (spec §9)
// ===========================================================================
struct IArena {
    virtual ~IArena() = default;
    virtual void* alloc(std::size_t bytes, std::size_t align) = 0;
    virtual void  reset() = 0;                         // frees all at once
    virtual std::size_t high_water() const = 0;        // for budgeting
};

// ===========================================================================
// Voxel storage  (Track B) — palette-compressed per chunk (spec §4.3)
// ===========================================================================
struct ChunkCoord { std::int32_t x, y, z; };          // in chunk units

struct IChunk {
    virtual ~IChunk() = default;
    virtual BlockId get(int lx, int ly, int lz) const = 0;   // 0..15 local
    virtual void    set(int lx, int ly, int lz, BlockId b) = 0;
    virtual bool    is_uniform() const = 0;            // air/single-block fast path
    virtual std::uint32_t revision() const = 0;        // bumps on edit (remesh trigger)
};

struct IChunkStore {
    virtual ~IChunkStore() = default;
    virtual IChunk* get(ChunkCoord c) = 0;             // nullptr if not resident
    virtual IChunk* get_or_create(ChunkCoord c) = 0;
    virtual void    evict(ChunkCoord c) = 0;
    virtual bool    is_resident(ChunkCoord c) const = 0;
    // Serialize one chunk to a caller buffer; returns bytes written (0 = fail).
    virtual std::size_t serialize(ChunkCoord c, std::span<std::byte> out) const = 0;
    virtual bool        deserialize(ChunkCoord c, std::span<const std::byte> in) = 0;
};

// World query surface used by gameplay/physics/net (Track B owns impl).
struct IWorldProvider {
    virtual ~IWorldProvider() = default;
    virtual BlockId block_at(IVec3 world) const = 0;
    virtual bool    set_block(IVec3 world, BlockId b) = 0;  // authoritative edit
    virtual bool    is_solid(IVec3 world) const = 0;
    virtual float   region_saturation(IVec3 world) const = 0; // 0..1 Dim state
};

// ===========================================================================
// Procedural generation  (Track C) — deterministic, seeded (spec §6 C)
// ===========================================================================
struct IWorldGen {
    virtual ~IWorldGen() = default;
    virtual void     seed(std::uint64_t s) = 0;
    // Fill `chunk` for coord deterministically. Same seed+coord => identical.
    virtual void     generate(ChunkCoord c, IChunk& chunk) = 0;
    // Hash of generated content for the determinism test.
    virtual std::uint64_t content_hash(ChunkCoord c) const = 0;
};

// ===========================================================================
// Meshing  (Track D) — greedy mesh -> UMA buffers (spec §4.4)
// ===========================================================================
// Vertex layout is frozen in render-data.md; mesher writes raw bytes into the
// GPU buffer the renderer allocated. This interface returns ranges, not data.
struct MeshResult {
    std::uint32_t vertex_bytes;
    std::uint32_t index_bytes;
    std::uint32_t index_count;
    bool          empty;          // all-air chunk -> no draw
};
struct IMesher {
    virtual ~IMesher() = default;
    // Greedy-mesh `chunk` (with neighbour access via store for seam-correct
    // faces) into the provided shared-memory spans. Runs on a worker thread.
    virtual MeshResult mesh(ChunkCoord c, IChunkStore& store,
                            std::span<std::byte> vtx_out,
                            std::span<std::byte> idx_out,
                            bool simplified /* Dim LOD */) = 0;
    // Worst-case byte budget so the renderer can size the buffer up front.
    virtual std::uint32_t max_vertex_bytes() const = 0;
    virtual std::uint32_t max_index_bytes() const = 0;
};

// ===========================================================================
// Lighting  (Track F) — sun + colored block light, incremental (spec §6 F)
// ===========================================================================
struct ILighting {
    virtual ~ILighting() = default;
    virtual std::uint8_t sky_light(IVec3 world) const = 0;   // 0..15
    virtual std::uint8_t block_light(IVec3 world) const = 0; // 0..15 (packed RGB elsewhere)
    // Re-flood after an edit; cross-chunk correct. Queues remeshes via store.
    virtual void on_block_changed(IVec3 world, BlockId old_b, BlockId new_b) = 0;
};

// ===========================================================================
// Render data producer  (engine side of the C ABI §4)
// ===========================================================================
struct IRenderData {
    virtual ~IRenderData() = default;
    // Build the visible draw list for the current camera into engine-owned
    // storage; the C ABI bf_frame_acquire_render borrows it.
    virtual void build_frame(/* camera supplied internally */) = 0;
};

// ===========================================================================
// Networking  (Track H) — server-authoritative UDP (spec §4.7)
// ===========================================================================
enum class NetChannel : std::uint8_t {
    ReliableOrdered   = 0,  // block edits, inventory, quest state
    ReliableUnordered = 1,  // chunk stream
    Unreliable        = 2,  // movement snapshots
};
struct INetTransport {
    virtual ~INetTransport() = default;
    virtual bool start_host(std::uint16_t port) = 0;
    virtual bool connect(std::string_view host, std::uint16_t port) = 0;
    virtual void stop() = 0;
    virtual void send(NetChannel ch, std::span<const std::byte> payload,
                      std::uint32_t peer = 0 /* 0 = broadcast */) = 0;
    // Pump the socket; invoke `on_packet` for each received message. Runs on
    // the E-core net thread.
    virtual void poll() = 0;
    virtual unsigned peer_count() const = 0;
};

// ===========================================================================
// Gameplay registries + systems  (Track J) — content is data (spec §4.10)
// ===========================================================================
struct BlockDef {
    BlockId      id;
    std::string_view name;       // borrowed from loaded content table
    std::uint8_t hardness;       // mining time base
    std::uint8_t required_tier;  // 0 hand,1 wood,2 stone,3 iron-equiv
    std::uint8_t light_emit;     // 0..15
    std::uint8_t flags;          // bit0 gravity, bit1 transparent, bit2 functional...
    ItemId       drop_item;
};
struct IBlockRegistry {
    virtual ~IBlockRegistry() = default;
    virtual const BlockDef* by_id(BlockId id) const = 0;
    virtual const BlockDef* by_name(std::string_view name) const = 0;
    virtual std::uint32_t   count() const = 0;
};

struct ItemDef {
    ItemId       id;
    std::string_view name;
    std::uint16_t max_stack;
    std::uint8_t  tool_tier;     // 0 = not a tool
    std::uint8_t  tool_kind;     // pickaxe/axe/shovel/none
    BlockId       places_block;  // 0 = not placeable
};
struct IItemRegistry {
    virtual ~IItemRegistry() = default;
    virtual const ItemDef* by_id(ItemId id) const = 0;
    virtual const ItemDef* by_name(std::string_view name) const = 0;
    virtual std::uint32_t  count() const = 0;
};

struct ItemStack { ItemId item{0}; std::uint16_t count{0}; std::uint16_t durability{0xFFFF}; };

struct IInventory {
    virtual ~IInventory() = default;
    virtual std::size_t slot_count() const = 0;
    virtual ItemStack   get(std::size_t slot) const = 0;
    virtual bool        set(std::size_t slot, ItemStack s) = 0;
    virtual bool        add(ItemStack s) = 0;          // stack-merge into first fit
    virtual bool        move(std::size_t from, std::size_t to, std::uint16_t count) = 0;
};

struct RecipeMatch { ItemId result; std::uint16_t count; };
struct IRecipeBook {
    virtual ~IRecipeBook() = default;
    // grid: row-major item ids, dim x dim (2 or 3). Returns result if matched.
    virtual std::optional<RecipeMatch>
        match(std::span<const ItemId> grid, int dim) const = 0;
    virtual std::uint32_t count() const = 0;
};
struct ICraftingSystem {
    virtual ~ICraftingSystem() = default;
    virtual std::optional<RecipeMatch>
        preview(std::span<const ItemId> grid, int dim) const = 0;
    // Consume inputs from `inv`, push result; returns false if no match.
    virtual bool commit(IInventory& inv, std::span<const ItemId> grid, int dim) = 0;
};

// ---- Creatures / AI (Track G+J) -------------------------------------------
enum class Disposition : std::uint8_t { Passive, Skittish, NightGentle, Boss };
struct CreatureDef {
    std::uint16_t id;
    std::string_view name;
    Disposition  disposition;
    std::uint8_t max_health;
    std::uint8_t spawn_light_max;  // night mobs only spawn below this
    float        move_speed;
};
struct ICreatureSpawner {
    virtual ~ICreatureSpawner() = default;
    virtual const CreatureDef* def(std::uint16_t id) const = 0;
    virtual Entity spawn(std::uint16_t id, Vec3 pos) = 0;
    virtual void   despawn(Entity e) = 0;       // calm -> sparkle, not death
    virtual std::uint32_t live_count() const = 0;
};
struct IAIController {
    virtual ~IAIController() = default;
    // Advance behaviour for one fixed sim tick (20 Hz). Pathfinding on E-cores.
    virtual void tick(float fixed_dt) = 0;
};

// ---- Quests / dialogue (Track J) ------------------------------------------
struct QuestState { std::uint32_t id; float progress; bool complete; };
struct IQuestSystem {
    virtual ~IQuestSystem() = default;
    virtual bool       start(std::uint32_t quest_id) = 0;
    virtual QuestState state(std::uint32_t quest_id) const = 0;
    virtual std::optional<std::uint32_t> active_tracked() const = 0;
    // Fire a world event the quest engine may consume (mined X, lit beacon...).
    virtual void       notify(std::string_view trigger, std::int32_t arg) = 0;
    // Procedural generator: produce a fresh solvable quest from a seed.
    virtual std::uint32_t generate(std::uint64_t seed) = 0;
};
struct IDialogue {
    virtual ~IDialogue() = default;
    virtual std::string_view line(std::uint32_t npc_id, std::uint32_t node) const = 0;
    virtual std::uint32_t    next(std::uint32_t npc_id, std::uint32_t node,
                                  std::uint32_t choice) const = 0;
};

} // namespace bf
