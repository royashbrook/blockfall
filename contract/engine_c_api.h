/* ============================================================================
 * Blockfall — Engine C ABI  (contract/engine_c_api.h)
 * ----------------------------------------------------------------------------
 * FROZEN after Phase 0. This is the ONLY surface across which the Swift app
 * shell (window/event loop/Metal/HUD) talks to the C++ core (`blockcore`).
 *
 * RULES (hard):
 *   - Pure C. No C++ types, no STL, no exceptions cross this boundary.
 *   - All structs are POD with explicit, fixed-width fields and fixed layout.
 *   - The engine is the authority. Swift injects input and consumes render +
 *     HUD data; it never mutates world state directly.
 *   - Any change to a struct layout or function signature bumps BF_ABI_VERSION
 *     and requires an ADR (see /docs/adr). Additive callbacks may be appended.
 *
 * THREADING (see /contract/threading.md for the full model):
 *   - The "main thread" is the Swift thread that owns the window + Metal queue.
 *   - Functions marked [MAIN] must be called from that thread only.
 *   - The engine runs its own internal job pool + 20 Hz fixed-step sim thread;
 *     callbacks (bf_event_fn etc.) may fire from those threads — see each.
 * ========================================================================== */
#ifndef BLOCKFALL_ENGINE_C_API_H
#define BLOCKFALL_ENGINE_C_API_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on ANY breaking change to this header. App refuses to run on a
 * mismatch (engine reports its compiled-in value via bf_abi_version()). */
#define BF_ABI_VERSION 14u  /* v14: bf_render_frame.shadow_draws (un-culled shadow occluders) */

#if defined(_WIN32)
#  define BF_API __declspec(dllexport)
#else
#  define BF_API __attribute__((visibility("default")))
#endif

/* --------------------------------------------------------------------------
 * Primitive types
 * ------------------------------------------------------------------------ */
typedef uint8_t  bf_bool;   /* 0 = false, 1 = true */
typedef uint64_t bf_handle; /* opaque, engine-assigned; 0 = invalid/none     */
typedef uint16_t bf_block_id;
typedef uint16_t bf_item_id;

/* Row-major 4x4 (matches simd_float4x4 column data passed straight to Metal;
 * the engine writes whichever convention the renderer doc specifies — see
 * render-data.md. Stored column-major to drop straight into a MTLBuffer.) */
typedef struct { float m[16]; } bf_mat4;
typedef struct { float x, y, z; } bf_vec3;
typedef struct { int32_t x, y, z; } bf_ivec3;

/* --------------------------------------------------------------------------
 * Opaque handles
 * ------------------------------------------------------------------------ */
typedef struct bf_engine_s* bf_engine;

/* ==========================================================================
 * 1. LIFECYCLE
 * ======================================================================== */

/* Result codes. Non-zero = failure; see bf_last_error() for detail. */
typedef enum bf_result {
    BF_OK = 0,
    BF_ERR_ABI_MISMATCH      = 1,
    BF_ERR_BAD_ARG           = 2,
    BF_ERR_IO                = 3,   /* save/load/disk                       */
    BF_ERR_CORRUPT_SAVE      = 4,   /* magic/version/checksum bad           */
    BF_ERR_CONTENT_INVALID   = 5,   /* /content failed schema validation    */
    BF_ERR_OUT_OF_MEMORY     = 6,
    BF_ERR_NET               = 7,
    BF_ERR_NOT_READY         = 8,   /* called before world loaded           */
    BF_ERR_INTERNAL          = 99
} bf_result;

typedef enum bf_game_mode {
    BF_MODE_SURVIVAL = 0,
    BF_MODE_CREATIVE = 1
} bf_game_mode;

typedef enum bf_session_role {
    BF_ROLE_SINGLEPLAYER = 0, /* local client + local authoritative server */
    BF_ROLE_HOST         = 1, /* authoritative server + local client + LAN */
    BF_ROLE_CLIENT       = 2  /* remote client, no local authority         */
} bf_session_role;

/* Memory/feel knobs. The Air is the target: defaults here MUST be Air-safe.
 * (See spec §2/§10 — budget against 16 GB UMA, not the dev box.) */
typedef struct bf_engine_config {
    uint32_t        abi_version;     /* caller sets BF_ABI_VERSION           */
    uint64_t        world_seed;      /* 0 = derive from save or random       */
    bf_session_role role;
    bf_game_mode    start_mode;
    uint32_t        render_distance_chunks; /* default 10 (Air perf gate)    */
    uint64_t        memory_budget_bytes;    /* soft cap; default ~10 GiB     */
    const char*     content_dir;     /* absolute path to bundled /content    */
    const char*     save_dir;        /* absolute; created if absent          */
    const char*     player_name;     /* UTF-8, <= 32 bytes                   */
} bf_engine_config;

BF_API uint32_t    bf_abi_version(void);
/* [MAIN] Validates config + content, allocates arenas, spins up job pool +
 * sim thread (paused). Returns NULL on failure (check bf_last_error_global).*/
BF_API bf_engine   bf_engine_create(const bf_engine_config* cfg, bf_result* out_err);
/* [MAIN] Stops threads, flushes save, frees everything. Safe on NULL.      */
BF_API void        bf_engine_destroy(bf_engine e);

/* Thread-local last-error string for the most recent failed call on this
 * thread. Valid until the next API call on the same thread. Never NULL. */
BF_API const char* bf_last_error(bf_engine e);
BF_API const char* bf_last_error_global(void); /* for create() failures      */

/* World lifecycle. [MAIN]. */
BF_API bf_result   bf_world_new (bf_engine e, uint64_t seed);
BF_API bf_result   bf_world_load(bf_engine e); /* from cfg.save_dir          */
BF_API bf_result   bf_world_save(bf_engine e); /* explicit checkpoint        */

/* ==========================================================================
 * 2. FRAME TICK
 * --------------------------------------------------------------------------
 * The Swift run loop does, per displayed frame:
 *   bf_frame_begin(e, &input, real_dt);   // inject input, advance render view
 *   bf_frame_acquire_render(e, &frame);   // read draw list + HUD + dim state
 *   ... encode Metal draws from `frame` ...
 *   bf_frame_end(e);                       // release borrowed render data
 * The authoritative sim advances on the engine's own 20 Hz thread; the
 * interpolation factor for smooth rendering is returned in bf_render_frame.
 * ======================================================================== */

/* Per-frame input snapshot. Swift fills this from NSEvent/GameController. */
typedef struct bf_frame_input {
    /* Continuous look/move (camera-relative; engine resolves to world).     */
    float    move_forward;   /* -1..1 (W/S)                                  */
    float    move_strafe;    /* -1..1 (A/D)                                  */
    float    look_yaw_delta; /* radians, this frame                          */
    float    look_pitch_delta;
    bf_bool  jump;           /* space (held)                                 */
    bf_bool  sneak;          /* shift (held)                                 */
    bf_bool  sprint;
    bf_bool  fly_ascend;     /* creative                                     */
    bf_bool  fly_descend;
    /* Discrete actions are delivered via bf_input_action() below, NOT here,
     * so a click is never lost to frame aliasing. This struct is sampled.   */
    uint8_t  _pad[3];
} bf_frame_input;

/* NOTE: the frame-tick functions (bf_frame_begin / _acquire_render / _end) are
 * declared at the end of §4, after bf_render_frame is fully defined — so the
 * Swift importer sees a complete struct, not an opaque pointer. */

/* ==========================================================================
 * 3. DISCRETE INPUT / ACTIONS  (mine / place / hotbar / inventory / craft)
 * --------------------------------------------------------------------------
 * Queued, processed by the sim at the next tick, replicated to the server in
 * co-op. Ordering within a frame is preserved. [MAIN]
 * ======================================================================== */
typedef enum bf_action_kind {
    BF_ACT_MINE_START   = 0,  /* begin holding to break the targeted block   */
    BF_ACT_MINE_STOP    = 1,
    BF_ACT_PLACE        = 2,  /* place selected hotbar block at target face  */
    BF_ACT_INTERACT     = 3,  /* open chest/door/crafting table at target    */
    BF_ACT_HOTBAR_SELECT= 4,  /* arg_i = slot 0..8                           */
    BF_ACT_HOTBAR_SCROLL= 5,  /* arg_i = +1 / -1                             */
    BF_ACT_INV_OPEN     = 6,
    BF_ACT_INV_CLOSE    = 7,
    BF_ACT_INV_MOVE     = 8,  /* arg_i=from_slot, arg_j=to_slot, arg_k=count */
    BF_ACT_CRAFT        = 9,  /* arg_i = recipe grid commit (see crafting)   */
    BF_ACT_DROP_ITEM    = 10,
    BF_ACT_MODE_TOGGLE  = 11, /* survival<->creative (creative requires perm) */
    BF_ACT_ATTACK       = 12, /* swing at targeted creature (calm-not-kill)   */
    BF_ACT_GIVE_ITEM    = 13  /* creative only: arg_i = item id to grant      */
} bf_action_kind;

typedef struct bf_action {
    bf_action_kind kind;
    int32_t        arg_i, arg_j, arg_k; /* meaning per kind (see comments)   */
} bf_action;

/* [MAIN] Enqueue one discrete action. Returns BF_ERR_NOT_READY pre-world.   */
BF_API bf_result bf_input_action(bf_engine e, const bf_action* act);

/* ==========================================================================
 * 4. RENDER DATA HANDOFF  (per-frame, borrowed)
 * --------------------------------------------------------------------------
 * UMA zero-copy: the engine does NOT own MTLBuffers. Swift registers an
 * allocator (§6); the engine writes mesh/uniform bytes into Swift-provided
 * storageModeShared buffers and references them here by `buffer` handle.
 * Swift maps handle -> MTLBuffer for the draw call. Nothing is copied.
 * ======================================================================== */

/* One draw: a chunk mesh (or other batch) already resident in a GPU buffer. */
typedef struct bf_draw_item {
    bf_handle vertex_buffer;  /* Swift-side MTLBuffer handle (see §6)        */
    bf_handle index_buffer;   /* 0 if non-indexed                            */
    uint32_t  vertex_offset;  /* bytes                                       */
    uint32_t  index_offset;   /* bytes                                       */
    uint32_t  index_count;    /* draw count (or vertex_count if non-indexed) */
    uint32_t  material_id;    /* index into the material/atlas table         */
    bf_ivec3  chunk_origin;   /* world coords of chunk min corner            */
    float     dim_saturation; /* 0=fully Dim/grey ... 1=full colour (min corner) */
    /* Region saturation at the chunk's +X, +Z and +XZ corners, so the shader can
     * bilinearly blend the Dim->colour transition across region seams (v9). */
    float     dim_sat_px;
    float     dim_sat_pz;
    float     dim_sat_pxz;
} bf_draw_item;

/* Per-region restoration state, supplied so the post-effect can blend the
 * Dim->colour transition smoothly. Regions are 8x8 chunk areas (see
 * region-format.md). Only regions overlapping the frustum are reported. */
typedef struct bf_region_dim {
    bf_ivec3 region_coord;    /* in region units                            */
    float    saturation;      /* 0..1 authoritative restoration progress     */
    float    fog_density;     /* 0..1 cheap distance/Dim fog                  */
} bf_region_dim;

/* One creature/entity to draw (ABI v2, ADR 0005). Engine-owned, borrowed. */
typedef struct bf_entity_draw {
    bf_vec3  position;
    float    yaw;
    bf_vec3  color;       /* base tint                                       */
    float    scale;       /* model scale (world units)                       */
    uint32_t kind;        /* archetype id (renderer may vary the model)      */
    float    sat;         /* per-region Dim saturation at the entity         */
    uint32_t _pad;
} bf_entity_draw;

typedef struct bf_camera {
    bf_mat4 view;
    bf_mat4 proj;
    bf_vec3 position;
    float   biome_cold;       /* 0..1: 1 = snowy/cold area (precip falls as snow) */
    bf_vec3 forward;
    float   time_of_day;      /* 0..1, 0=midnight 0.5=noon                   */
    bf_vec3 sun_dir;
    float   underwater;       /* 1 when the eye is submerged (for water tint)  */
    float   weather;          /* 0=clear, 1=rain, 2=snow (drives the overlay)  */
    float   underground;      /* 0..1: how deep below the surface the eye is;   */
                              /* 1 = deep cave. Darkens the sky so unstreamed   */
                              /* far-underground doesn't show as bright daylight */
} bf_camera;

/* ---- HUD state (read-only snapshot for the SwiftUI/Metal overlay) ------- */
typedef struct bf_hud_slot {
    bf_item_id item;          /* 0 = empty                                   */
    uint16_t   count;
    uint16_t   durability;    /* 0xFFFF = N/A                                */
    uint16_t   _pad;
} bf_hud_slot;

#define BF_HOTBAR_SLOTS    9
#define BF_INVENTORY_SLOTS 36   /* 9 hotbar + 27 main, Minecraft-faithful    */

typedef struct bf_hud_state {
    bf_game_mode mode;
    uint8_t      selected_slot;     /* 0..8                                  */
    uint8_t      inventory_open;    /* bf_bool                               */
    float        health;            /* 0..20                                 */
    float        hunger;            /* 0..20 (hunger-lite)                   */
    bf_hud_slot  hotbar[BF_HOTBAR_SLOTS];
    bf_hud_slot  inventory[BF_INVENTORY_SLOTS]; /* full grid when open       */
    /* Active quest (one tracked at a time on the HUD). */
    uint32_t     active_quest_id;   /* 0 = none                              */
    char         quest_title[64];   /* UTF-8, NUL-terminated                 */
    char         quest_objective[96];
    float        quest_progress;    /* 0..1                                  */
    /* Crosshair target feedback. */
    bf_bool      has_target;
    bf_ivec3     target_block;
    float        mine_progress;     /* 0..1 of current break                 */
    /* Recipes craftable right now (result item+count); shown in inventory,
     * craft with number keys (first 9) or click -> BF_ACT_CRAFT arg_i.       */
    bf_hud_slot  craftable[24];
    uint8_t      craftable_count;
    /* v4 additions */
    float        oxygen;            /* 0..1 air remaining underwater (1 = full) */
    char         look_name[40];     /* name of the block/creature under the crosshair, "" if none */
    /* v5 additions */
    char         achievement_toast[48]; /* recently-unlocked achievement banner, "" if none */
    uint8_t      achievements_done;
    uint8_t      achievements_total;
    uint8_t      weather;          /* 0=clear, 1=rain, 2=snow (for the HUD label) */
    char         biome_name[24];   /* current biome, e.g. "Meadow", "Desert"       */
    uint8_t      in_dim;           /* 1 = standing in an unrestored "Grey" region   */
} bf_hud_state;

/* One quest in the full progression list (for the quest/achievement screen). */
typedef enum bf_quest_state {
    BF_QUEST_UPCOMING = 0,   /* not yet started (locked behind earlier quests) */
    BF_QUEST_ACTIVE   = 1,   /* currently tracked                              */
    BF_QUEST_DONE     = 2,   /* completed                                      */
} bf_quest_state;

typedef struct bf_quest_entry {
    char     title[64];       /* UTF-8, NUL-terminated                         */
    char     objective[96];   /* current/next objective text                   */
    uint8_t  state;           /* bf_quest_state                                */
    float    progress;        /* 0..1 (meaningful for the active quest)        */
} bf_quest_entry;

/* The live creature the ACTIVE quest wants you to reach — the nearest spawned
 * one matching a befriend_creature / calm_boss objective. Powers the quest-target
 * compass (#41): one marker that points at the thing to fight/befriend, by name.
 * `active` is 0 when the current objective isn't creature-based OR no matching
 * creature is currently loaded near the player (then the marker is hidden). */
typedef struct bf_quest_target {
    uint8_t  active;          /* 1 = a matching creature is loaded; fields valid */
    uint8_t  is_boss;         /* 1 = fight (calm_boss), 0 = befriend/find        */
    bf_vec3  position;        /* world position of the nearest matching creature */
    float    distance;        /* metres from the player                          */
    char     label[48];       /* display name, e.g. "Gloom Stag"                 */
} bf_quest_target;

/* The whole frame, borrowed from the engine between acquire/end. */
typedef struct bf_render_frame {
    bf_camera             camera;
    float                 interp_alpha;  /* 0..1 sim interpolation factor    */
    const bf_draw_item*   draws;         /* engine-owned array               */
    uint32_t              draw_count;
    const bf_region_dim*  regions;       /* engine-owned array               */
    uint32_t              region_count;
    const bf_entity_draw* entities;      /* engine-owned array (ABI v2)       */
    uint32_t              entity_count;
    bf_hud_state          hud;           /* value copy, always valid         */
    /* Shadow occluders: like `draws` but WITHOUT the view-cone cull, so geometry
     * behind/beside the camera still casts shadows into view (#46 turn-stability).
     * Bounded to the shadow cascades' radius. (ABI v14) */
    const bf_draw_item*   shadow_draws;
    uint32_t              shadow_draw_count;
} bf_render_frame;

/* ---- Frame-tick functions (defined here so bf_render_frame is complete) -- */
/* [MAIN] Sample continuous input + advance camera/interp. real_dt seconds.  */
BF_API bf_result bf_frame_begin(bf_engine e, const bf_frame_input* in, double real_dt);
/* [MAIN] Fill `out` with a borrowed view of this frame's render data.
 * Pointers inside remain valid until bf_frame_end(). DO NOT free.           */
BF_API bf_result bf_frame_acquire_render(bf_engine e, bf_render_frame* out);

/* Fill `out` (capacity `cap`) with the FULL quest progression list and return the
 * total quest count (may exceed cap; only min(count,cap) are written). Powers the
 * quest/achievement overview screen. Order = the quest chain; states reflect what's
 * done / active / upcoming. */
BF_API uint32_t bf_quest_list(bf_engine e, bf_quest_entry* out, uint32_t cap);
/* Fill `out` with the active quest's target creature (nearest loaded match) and
 * return 1, or return 0 (and zero `out`) when there's no creature objective active
 * or none is loaded. Powers the quest-target compass (#41). */
BF_API uint8_t bf_quest_target_get(bf_engine e, bf_quest_target* out);
/* [MAIN] Release the borrow. After this, pointers from acquire are invalid. */
BF_API void      bf_frame_end(bf_engine e);

/* ==========================================================================
 * 5. GPU BUFFER ALLOCATOR  (Swift -> engine)
 * --------------------------------------------------------------------------
 * The renderer owns the MTLDevice. It hands the engine a way to allocate +
 * free storageModeShared buffers so the mesher can write directly into UMA
 * memory the GPU will read. Called from engine worker threads -> the
 * implementation MUST be thread-safe (MTLDevice.makeBuffer is). See §10.
 * ======================================================================== */
typedef struct bf_gpu_buffer {
    bf_handle handle;   /* Swift-side opaque id mapping to a MTLBuffer        */
    void*     contents; /* CPU pointer = MTLBuffer.contents (UMA shared)     */
    uint32_t  bytes;
} bf_gpu_buffer;

typedef struct bf_gpu_allocator {
    void* user; /* opaque Swift context (e.g. the Renderer)                  */
    /* Allocate >= bytes of storageModeShared memory. Thread-safe.           */
    bf_gpu_buffer (*alloc)(void* user, uint32_t bytes);
    /* Return a buffer for reuse/free. Engine guarantees the GPU is no longer
     * reading it (respects triple-buffer fences — see threading.md).        */
    void          (*free_)(void* user, bf_handle handle);
} bf_gpu_allocator;

/* [MAIN] Register before the first frame. Engine retains the struct by value
 * and the `user` pointer for its lifetime. */
BF_API bf_result bf_set_gpu_allocator(bf_engine e, const bf_gpu_allocator* a);

/* ==========================================================================
 * 6. EVENT CALLBACKS  (engine -> Swift)
 * --------------------------------------------------------------------------
 * For things the app must react to outside the render snapshot: sounds to
 * play, particles spawned, a quest completing, a peer joining. Callbacks may
 * fire from sim/net threads; the app must marshal to main as needed. Keep
 * handlers short + non-blocking. Set NULL to ignore an event class.
 * ======================================================================== */
typedef enum bf_event_kind {
    BF_EVT_BLOCK_BROKEN   = 0,  /* i=block_id; pos in ivec; spawn particles   */
    BF_EVT_BLOCK_PLACED   = 1,
    BF_EVT_SFX            = 2,  /* i=sound_id; pos for spatialization         */
    BF_EVT_QUEST_UPDATED  = 3,  /* i=quest_id                                 */
    BF_EVT_QUEST_COMPLETE = 4,  /* i=quest_id; j=reward summary handle        */
    BF_EVT_CREATURE_CALMED= 5,  /* i=creature_id -> sparkle puff             */
    BF_EVT_REGION_RESTORED= 6,  /* a Dim region flipped to colour            */
    BF_EVT_PEER_JOINED    = 7,  /* co-op                                      */
    BF_EVT_PEER_LEFT      = 8,
    BF_EVT_SAVE_DONE      = 9,
    BF_EVT_ERROR          = 10  /* i=bf_result; non-fatal notice              */
} bf_event_kind;

typedef struct bf_event {
    bf_event_kind kind;
    int32_t       i, j;
    bf_ivec3      pos;
    float         fx, fy, fz; /* extra payload (e.g. volume, pitch)          */
} bf_event;

typedef void (*bf_event_fn)(void* user, const bf_event* ev);
/* [MAIN] Register the sink. `user` retained for engine lifetime. */
BF_API bf_result bf_set_event_callback(bf_engine e, bf_event_fn fn, void* user);

/* ==========================================================================
 * 7. NETWORK (co-op) — thin control surface; transport lives in core (§H)
 * ======================================================================== */
/* [MAIN] Host advertises via Bonjour; clients discover + connect. Detailed
 * snapshot/delta/reconcile is internal (see wire-format.md). */
BF_API bf_result bf_net_host_start(bf_engine e, uint16_t port);
BF_API bf_result bf_net_client_connect(bf_engine e, const char* host, uint16_t port);
BF_API bf_result bf_net_stop(bf_engine e);
BF_API uint32_t  bf_net_peer_count(bf_engine e);

#ifdef __cplusplus
} /* extern "C" */
#endif
#endif /* BLOCKFALL_ENGINE_C_API_H */
