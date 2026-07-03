//! bf::World, ported from engine/include/blockcore/world.hpp.
//!
//! The single player sim orchestrator: owns the chunk store, streams procedural
//! chunks around the player, runs movement/physics/collision, the mine/place loop,
//! the creature system (spawn/AI/collision/pets/villages/regrowth/doors/befriend),
//! quests + achievements, the Grey region saturation, save/load, and build_frame
//! (meshes visible chunks through the GPU allocator and fills the abi render frame).
//!
//! Faithful behavioural port. Where C++ pointer patterns fight the borrow checker
//! (neighbour reads while mutating, callbacks borrowing self) the code gathers reads
//! first or passes data explicitly. The fx/edit callbacks are Option<Box<dyn FnMut>>;
//! the GPU allocator is the raw abi::bf_gpu_allocator (C function pointers), used only
//! in build_frame's buffer alloc (the one unsafe FFI boundary).
//!
//! Streaming: the live game uses worker threads (#25); the tests all run with
//! synchronous inline gen (debug_set_sync_streaming(true)). This port implements the
//! synchronous path faithfully and treats the async/JobScheduler path as a no-op
//! fallback that also generates inline (no worker pool), so behaviour is deterministic.

use crate::abi::*;
use crate::chunk::PaletteChunk;
use crate::content::{ContentExtra, ContentRegistry, CreatureDefX};
use crate::creature_ai;
use crate::inventory::Inventory;
use crate::lighting;
use crate::mesher::{self, GreedyMesher};
use crate::store::ChunkStore;
use crate::types::{BlockId, ChunkCoord, ItemId, ItemStack, IVec3, CHUNK_DIM, REGION_CHUNKS};
use crate::worldgen::{self, TerrainGen};

use std::collections::{HashMap, HashSet};

mod streaming;
mod meshing;
mod persistence;
mod chests;
mod villages;
mod shadows;
mod quests;
mod crafting;
mod regions;
mod time;
mod falling;
mod debris;
mod coords;
mod blocks;
mod interaction;
mod combat;
mod biomes;
mod creature_spawning;
mod danger_sites;
mod regrowth;
mod creature_update;
mod debug;
mod render_frame;
mod actions;
mod player_update;
mod lifecycle;
mod map;

pub(crate) use self::coords::WRAP_CHUNKS;

use self::chests::ChestData;
use self::map::TotemMark;
pub use self::map::{MapMarkerInfo, MAP_CELL, MAP_CELLS, MAP_EXPLORED_BYTES, WARP_TOTEM};
use self::debris::Debris;
use self::falling::FallingBlock;
use self::quests::K_ACHIEVEMENT_COUNT;
use self::regions::RegionKey;
use self::shadows::ShadowVol;
use self::villages::VillageState;

// M1 block ids (engine/include/blockcore/world.hpp enum M1Block).
pub const AIR: BlockId = 0;
pub const GRASS: BlockId = 1;
pub const DIRT: BlockId = 2;
pub const STONE: BlockId = 3;
pub const WOOD: BlockId = 4;
pub const LEAF: BlockId = 5;
pub const SAND: BlockId = 6;
pub const GLOW: BlockId = 7;
pub const BRICK: BlockId = 8;
pub const WATER: BlockId = 9;
// #118 snow overlay / #117 footprints: snow is a thin blanket block, not a cube.
// Stepping on fresh snow (SNOW_LAYER) compacts it to TRODDEN_SNOW (a footprint).
pub const SNOW_LAYER: BlockId = 12;
pub const TRODDEN_SNOW: BlockId = 54;

// #109 chests: the chest block id (content/blocks/functional.json id 31) and the
// fixed per-chest slot count. A small fixed number keeps the panel kid-simple and
// avoids a generic container framework (ponytail). 9 slots = one panel row.
pub const CHEST: BlockId = 31;
pub const CHEST_SLOTS: usize = 9;

const KCHUNK_DIM: i32 = CHUNK_DIM as i32;
const KREGION_CHUNKS: i32 = REGION_CHUNKS;

// ============================================================================
// Small vector / matrix math (mirrors mathx.hpp V3/M4 + look_at/perspective).
// ============================================================================

#[derive(Clone, Copy, Default)]
struct V3 {
    x: f32,
    y: f32,
    z: f32,
}
impl V3 {
    fn new(x: f32, y: f32, z: f32) -> V3 {
        V3 { x, y, z }
    }
}
impl std::ops::Add for V3 {
    type Output = V3;
    fn add(self, o: V3) -> V3 {
        V3::new(self.x + o.x, self.y + o.y, self.z + o.z)
    }
}
impl std::ops::Sub for V3 {
    type Output = V3;
    fn sub(self, o: V3) -> V3 {
        V3::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }
}
impl std::ops::Mul<f32> for V3 {
    type Output = V3;
    fn mul(self, s: f32) -> V3 {
        V3::new(self.x * s, self.y * s, self.z * s)
    }
}
fn dot(a: V3, b: V3) -> f32 {
    a.x * b.x + a.y * b.y + a.z * b.z
}
fn cross(a: V3, b: V3) -> V3 {
    V3::new(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
fn normalize(v: V3) -> V3 {
    let l = (v.x * v.x + v.y * v.y + v.z * v.z).sqrt();
    if l > 1e-8 {
        V3::new(v.x / l, v.y / l, v.z / l)
    } else {
        v
    }
}

// Column-major 4x4, matching M4 in mathx.hpp (m[16]).
fn look_at(eye: V3, ctr: V3, up: V3) -> [f32; 16] {
    let f = normalize(ctr - eye);
    let s = normalize(cross(f, up));
    let u = cross(s, f);
    [
        s.x, u.x, -f.x, 0.0,
        s.y, u.y, -f.y, 0.0,
        s.z, u.z, -f.z, 0.0,
        -dot(s, eye), -dot(u, eye), dot(f, eye), 1.0,
    ]
}
fn perspective(fovy: f32, aspect: f32, znear: f32, zfar: f32) -> [f32; 16] {
    let t = (fovy * 0.5).tan();
    let mut m = [0.0f32; 16];
    m[0] = 1.0 / (aspect * t);
    m[5] = 1.0 / t;
    m[10] = zfar / (znear - zfar);
    m[11] = -1.0;
    m[14] = (znear * zfar) / (znear - zfar);
    m
}

// ============================================================================
// Bridges: worldgen + mesher traits over PaletteChunk / ChunkStore.
// ============================================================================

// worldgen uses i32 local coords (0..16).
impl worldgen::Chunk for PaletteChunk {
    fn get(&self, lx: i32, ly: i32, lz: i32) -> BlockId {
        PaletteChunk::get(self, lx as usize, ly as usize, lz as usize)
    }
    fn set(&mut self, lx: i32, ly: i32, lz: i32, b: BlockId) {
        PaletteChunk::set(self, lx as usize, ly as usize, lz as usize, b);
    }
}

// mesher uses usize local coords + sky/block light + is_uniform.
impl mesher::Chunk for PaletteChunk {
    fn get(&self, x: usize, y: usize, z: usize) -> BlockId {
        PaletteChunk::get(self, x, y, z)
    }
    fn sky_light(&self, x: usize, y: usize, z: usize) -> u8 {
        PaletteChunk::sky_light(self, x, y, z)
    }
    fn block_light(&self, x: usize, y: usize, z: usize) -> u8 {
        PaletteChunk::block_light(self, x, y, z)
    }
    fn is_uniform(&self) -> bool {
        PaletteChunk::is_uniform(self)
    }
}

impl mesher::ChunkStore for ChunkStore {
    type Chunk = PaletteChunk;
    fn get(&self, c: ChunkCoord) -> Option<&PaletteChunk> {
        ChunkStore::get(self, c)
    }
}

// ============================================================================
// Async streaming support (#25): a read-only chunk snapshot + worker results.
// ============================================================================

// A read-only store holding owned COPIES of a chunk + its 6 face neighbours, so
// a worker thread can greedy-mesh it without touching (or racing) the live store.
// Mirrors the C++ SnapStore. The mesher only ever calls get(); it resolves the
// cross-chunk lookups it needs from these seven entries.
struct SnapStore {
    chunks: HashMap<ChunkCoord, PaletteChunk>,
}
impl mesher::ChunkStore for SnapStore {
    type Chunk = PaletteChunk;
    fn get(&self, c: ChunkCoord) -> Option<&PaletteChunk> {
        self.chunks.get(&c)
    }
}

// A chunk generated on a worker, handed back to the frame thread to insert.
struct GenResult {
    cc: ChunkCoord,
    chunk: PaletteChunk,
}

// A meshed snapshot, handed back to the frame thread to upload through the GPU
// allocator. Carries the packed CPU buffers (the allocator is frame-thread only).
struct MeshJobResult {
    cc: ChunkCoord,
    version: u64,
    vbytes: Vec<u8>,
    ibytes: Vec<u8>,
    index_count: u32,
    empty: bool,
}

// ============================================================================
// Supporting POD types (mirror Creature / FallingBlock / MeshRec / RegionKey).
// ============================================================================

// Animals + bosses + villagers. Render/sim params are carried per creature so the
// roster is content driven.
#[derive(Clone)]
struct Creature {
    pos: V3,
    yaw: f32,
    vy: f32,
    color: V3,
    scale: f32,
    speed: f32,
    hp: i32,
    is_boss: bool,
    friendly: bool,
    hostile: bool,
    skittish: bool,
    aquatic: bool,
    atk_cd: f32,
    hit_flash: f32,
    wander: f32,
    shape: i32,
    model: i32,
    npc_id: i32,
    home_x: i32,
    home_z: i32,
    // Set for hostiles spawned at a ruined "danger site". These ignore the
    // night/quest gate (a ruin is dangerous around the clock) and are capped
    // separately so they never overwhelm the world.
    from_ruin: bool,
    // Vertical distance still to be climbed when the creature is stepping up onto
    // a ledge it bumped into. While this is > 0 the creature raises its Y toward
    // the ledge top over several ticks (a smooth clamber) instead of snapping up a
    // whole block in one tick, and gravity is suppressed so it does not fight the
    // climb. Deterministic: advanced by a fixed climb speed times the fixed dt.
    climb: f32,
    name: String,
    // Locomotion + AI state (epic #131). Holds the smooth heading/speed, the
    // behaviour state machine, and the throttled A* path. Logic lives in
    // creature_ai.rs; this is just the per creature data riding along.
    ai: creature_ai::CreatureAi,
}
impl Default for Creature {
    fn default() -> Creature {
        Creature {
            pos: V3::default(),
            yaw: 0.0,
            vy: 0.0,
            color: V3::new(0.9, 0.8, 0.5),
            scale: 0.8,
            speed: 1.6,
            hp: 3,
            is_boss: false,
            friendly: false,
            hostile: false,
            skittish: false,
            aquatic: false,
            atk_cd: 0.0,
            hit_flash: 0.0,
            wander: 0.0,
            shape: 0,
            model: -1,
            npc_id: 0,
            home_x: 0,
            home_z: 0,
            from_ruin: false,
            climb: 0.0,
            name: String::new(),
            ai: creature_ai::CreatureAi::default(),
        }
    }
}

// Per-ruin "danger site" state so a ruin is CLEARABLE rather than an endless spawner.
// Keyed in the world by the ruin anchor (ax, az). A site spawns a small fixed number
// of defenders exactly once. Once the player kills them the site is marked cleared and
// does NOT respawn while the player stays put; it only re-arms after a long cooldown
// AND once the player has moved well away (so you cannot farm it by camping on top of
// it, and a cleared ruin you walked away from can become dangerous again much later).
#[derive(Clone, Default)]
struct RuinSite {
    // Number of defenders spawned for this site so far in the current (armed) cycle.
    spawned: i32,
    // True once this site's defenders have all been killed. Blocks respawns until the
    // re-arm conditions below are met.
    cleared: bool,
    // Seconds remaining before a cleared site may re-arm. Counts down only while the
    // player is far from the site.
    rearm_cd: f32,
    // True once the clear reward has been granted for this ruin. The reward fires only
    // the first time the ruin is cleared, never again (even after a re-arm + reclear).
    rewarded: bool,
}

// A meshed chunk's GPU buffers + cached prop instances (#51).
#[derive(Clone)]
struct MeshRec {
    vbuf: bf_gpu_buffer,
    ibuf: bf_gpu_buffer,
    index_count: u32,
    has_buffers: bool,
    has_water: bool,
    props: Vec<bf_prop_instance>,
}
impl Default for MeshRec {
    fn default() -> MeshRec {
        MeshRec {
            vbuf: bf_gpu_buffer { handle: 0, contents: std::ptr::null_mut(), bytes: 0 },
            ibuf: bf_gpu_buffer { handle: 0, contents: std::ptr::null_mut(), bytes: 0 },
            index_count: 0,
            has_buffers: false,
            has_water: false,
            props: Vec::new(),
        }
    }
}

// ============================================================================
// World
// ============================================================================

// Fx/edit callback boxes (the C++ uses std::function). fx: (code, pos, extra).
type FxCb = Box<dyn FnMut(i32, IVec3, i32)>;
type EditCb = Box<dyn FnMut(IVec3, BlockId)>;

const DIM_SAT: f32 = 0.18;
const CY_MIN: i32 = -1;
const CY_MAX: i32 = 3;
const GEN_BUDGET: i32 = 6;
const MESH_BUDGET: usize = 12;
const NO_FLOOR: i32 = -1000000;

/// The single player sim. Borrows content/extra for its lifetime (`'c`), mirroring
/// the C++ `const ContentRegistry*` / `const ContentExtra*`. The mesher + worldgen
/// are owned (the C++ takes references; here owning them is simpler and equivalent
/// since the tests construct them alongside the world).
pub struct World<'c> {
    mesher: GreedyMesher,
    gen: Option<TerrainGen>,
    store: ChunkStore,
    alloc: bf_gpu_allocator,
    has_alloc: bool,
    meshes: HashMap<ChunkCoord, MeshRec>,
    dirty: HashSet<ChunkCoord>,
    // Player-visible edits (block break/place) jump the mesh queue. The main dirty
    // scoring favors FRESH meshes and caps remeshes per tick so streaming fill wins;
    // with continuous streaming that starved edit remeshes for so long that a broken
    // block stayed visible indefinitely. Urgent chunks remesh first, outside the caps.
    urgent_dirty: HashSet<ChunkCoord>,
    region_sat: HashMap<RegionKey, f32>,
    edited: HashSet<ChunkCoord>,
    gen_queue: Vec<ChunkCoord>,
    last_center: ChunkCoord,
    first_stream: bool,
    seed: u64,

    pos: V3,
    yaw: f32,
    pitch: f32,
    mode: bf_game_mode,
    health: f32,
    hunger: f32,
    selected: u8,
    mining: bool,
    vy: f32,
    on_ground: bool,
    bob_phase: f32,
    bob_amt: f32,
    world_clock: f64,
    // Day/night pin for lighting tests: 0 = auto (clock advances normally),
    // 1 = always-day, 2 = always-night. Set via BF_ACT_SET_TIME_MODE.
    time_mode: i32,
    weather: i32,
    spawn: V3,
    hurt_cd: f32,
    regen_cd: f32,
    oxygen: f32,
    drown_cd: f32,

    // Track J content + gameplay state.
    content: Option<&'c ContentRegistry>,
    inv: Option<Inventory<'c>>,
    glow_id: BlockId,
    beacon_id: BlockId,
    inv_open: bool,

    // Creatures + quest state.
    creatures: Vec<Creature>,
    falling: Vec<FallingBlock>,
    // #170 blockfall debris: physical fragments from broken blocks (transient,
    // never persisted). See world/debris.rs.
    debris: Vec<Debris>,
    entities: Vec<bf_entity_draw>,
    creature_timer: f32,
    villager_timer: f32,
    danger_timer: f32,
    // Per-ruin "danger site" state, keyed by the ruin anchor (ax, az). A ruin is
    // clearable: it spawns its defenders once, and once the player kills them it does
    // not immediately respawn. See RuinSite / maintain_danger_sites.
    ruin_sites: HashMap<(i32, i32), RuinSite>,
    // #109 per-chest container contents, keyed by the chest block's world position.
    // Lazily filled on first open (deterministic from seed+pos); persisted to chests.dat.
    chests: HashMap<(i32, i32, i32), ChestData>,
    // #109 the chest block position the last INTERACT opened (right-click on a chest),
    // or None. The app polls this via bf_chest_interacted to open/close the chest panel.
    // Interacting on the SAME open chest again clears it (toggle closed).
    last_chest_open: Option<IVec3>,
    // Living-villages (#95): per-settlement upgrade progress keyed by the settlement
    // anchor (ax, az). Player progress, persisted to villages.dat. See VillageState.
    villages: HashMap<(i32, i32), VillageState>,
    regrow_timer: f32,
    rng: u32,
    regions_restored: i32,
    creatures_befriended: i32,
    creatures_calmed: i32,

    // Content roster + quest engine.
    extra: Option<&'c ContentExtra>,
    active_quest: usize,
    obj_progress: Vec<u32>,
    all_quests_done: bool,
    quests_completed: i32,
    ach_progress: [i32; K_ACHIEVEMENT_COUNT],
    ach_done: [bool; K_ACHIEVEMENT_COUNT],
    ach_done_count: i32,
    ach_toast: String,
    ach_toast_timer: f32,

    // Co-op + fx.
    edit_cb: Option<EditCb>,
    fx_cb: Option<FxCb>,
    step_timer: f32,
    remote_avatars: Vec<bf_entity_draw>,
    mine_progress: f32,
    has_target: bool,
    target: IVec3,
    place: IVec3,

    // Streaming.
    stream_r: i32,
    stream_active_r: i32,
    surf_cy_cache: HashMap<i64, i32>,
    sync_stream: bool,
    moving: bool,

    // Async streaming (#25): worker pool + result channels. Created lazily on the
    // first live (sync_stream == false) stream_tick and torn down on Drop. The
    // sync test path never creates these (so it stays deterministic + inline).
    pool: Option<crate::jobs::WorkerPool>,
    gen_tx: Option<std::sync::mpsc::Sender<GenResult>>,
    gen_rx: Option<std::sync::mpsc::Receiver<GenResult>>,
    mesh_tx: Option<std::sync::mpsc::Sender<MeshJobResult>>,
    mesh_rx: Option<std::sync::mpsc::Receiver<MeshJobResult>>,
    // Chunks currently being generated / meshed on a worker (do not re-enqueue).
    gen_inflight: HashSet<ChunkCoord>,
    mesh_inflight: HashSet<ChunkCoord>,
    // Finished worker results waiting for the frame thread. Completion order is not
    // visual priority: simple far chunks can finish before nearby ocean/shore chunks,
    // so the frame thread buffers a small batch and consumes nearest-first.
    pending_gen_results: Vec<GenResult>,
    pending_mesh_results: Vec<MeshJobResult>,
    // Far chunks can be meshed once without frame-thread lighting, then promoted
    // to a fully lit mesh when the player approaches.
    unlit_far_meshes: HashSet<ChunkCoord>,
    // Monotonic dirty stamps for async meshing. Worker results carry the stamp
    // from submit time; if a chunk changed while the worker was meshing, the old
    // snapshot is discarded instead of overwriting the newer edit for a frame.
    mesh_versions: HashMap<ChunkCoord, u64>,
    mesh_next_version: u64,

    // #182 world map + warp totems: explored bitmask (one bit per 64x64-block
    // cell over the torus), placed totem markers, visited settlement anchors,
    // and the monotonically increasing totem number. Persisted in map.dat.
    explored: Vec<u8>,
    totems: Vec<TotemMark>,
    totem_next: u32,
    visited_villages: Vec<(i32, i32)>,

    // World-space voxel sun-shadow occupancy (ABI v19). A persistent occupancy
    // grid (1 byte/voxel: 1 = casts sun shadow) covering a fixed-size region
    // centred on the player chunk. Rebuilt only when the region origin moves or
    // resident chunks change; copied into the caller buffer by the FFI export.
    shadow: ShadowVol,
}

// Lets the creature AI pathfinder (creature_ai.rs) query terrain without seeing any
// World internals. Both methods are thin shims over existing helpers (epic #131).
impl<'c> creature_ai::WorldQuery for World<'c> {
    fn is_solid(&self, x: i32, y: i32, z: i32) -> bool {
        self.ai_is_solid(x, y, z)
    }
    fn floor(&self, x: i32, y_top: i32, z: i32) -> Option<i32> {
        self.ai_floor(x, y_top, z)
    }
}


#[cfg(test)]
mod time_mode_tests;
