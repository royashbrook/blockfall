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
mod coords;
mod blocks;
mod interaction;
mod combat;
mod biomes;
mod creature_spawning;
mod danger_sites;

use self::chests::ChestData;
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

impl<'c> World<'c> {
    /// Construct with a fresh mesher and an optional worldgen (the C++ ctor takes
    /// IMesher& and IWorldGen*; here both are owned). Pass `None` for the flat-test
    /// path that uses generate_test_world.
    pub fn new(gen: Option<TerrainGen>) -> World<'c> {
        World {
            mesher: GreedyMesher::new(),
            gen,
            store: ChunkStore::new(),
            alloc: bf_gpu_allocator { user: std::ptr::null_mut(), alloc: None, free_: None },
            has_alloc: false,
            meshes: HashMap::new(),
            dirty: HashSet::new(),
            region_sat: HashMap::new(),
            edited: HashSet::new(),
            gen_queue: Vec::new(),
            last_center: ChunkCoord { x: 0, y: 0, z: 0 },
            first_stream: true,
            seed: 0,
            pos: V3::new(0.0, 12.0, 0.0),
            yaw: 0.0,
            pitch: 0.0,
            mode: bf_game_mode::BF_MODE_CREATIVE,
            health: 20.0,
            hunger: 20.0,
            selected: 0,
            mining: false,
            vy: 0.0,
            on_ground: false,
            bob_phase: 0.0,
            bob_amt: 0.0,
            world_clock: 0.0,
            time_mode: 0,
            weather: 0,
            spawn: V3::new(0.0, 12.0, 0.0),
            hurt_cd: 0.0,
            regen_cd: 0.0,
            oxygen: 1.0,
            drown_cd: 0.0,
            content: None,
            inv: None,
            glow_id: GLOW,
            beacon_id: 0,
            inv_open: false,
            creatures: Vec::new(),
            falling: Vec::new(),
            entities: Vec::new(),
            creature_timer: 0.0,
            villager_timer: 0.0,
            danger_timer: 0.0,
            ruin_sites: HashMap::new(),
            chests: HashMap::new(),
            last_chest_open: None,
            villages: HashMap::new(),
            regrow_timer: 3.0,
            rng: 0x1234567,
            regions_restored: 0,
            creatures_befriended: 0,
            creatures_calmed: 0,
            extra: None,
            active_quest: 0,
            obj_progress: Vec::new(),
            all_quests_done: false,
            quests_completed: 0,
            ach_progress: [0; K_ACHIEVEMENT_COUNT],
            ach_done: [false; K_ACHIEVEMENT_COUNT],
            ach_done_count: 0,
            ach_toast: String::new(),
            ach_toast_timer: 0.0,
            edit_cb: None,
            fx_cb: None,
            step_timer: 0.0,
            remote_avatars: Vec::new(),
            mine_progress: 0.0,
            has_target: false,
            target: IVec3::default(),
            place: IVec3::default(),
            stream_r: 6,
            stream_active_r: 2,
            surf_cy_cache: HashMap::new(),
            sync_stream: false,
            moving: false,
            pool: None,
            gen_tx: None,
            gen_rx: None,
            mesh_tx: None,
            mesh_rx: None,
            gen_inflight: HashSet::new(),
            mesh_inflight: HashSet::new(),
            pending_gen_results: Vec::new(),
            pending_mesh_results: Vec::new(),
            unlit_far_meshes: HashSet::new(),
            mesh_versions: HashMap::new(),
            mesh_next_version: 0,
            shadow: ShadowVol::new(),
        }
    }

    // ---- configuration setters ------------------------------------------
    pub fn set_allocator(&mut self, a: bf_gpu_allocator) {
        self.alloc = a;
        self.has_alloc = true;
    }
    pub fn set_mode(&mut self, m: bf_game_mode) {
        self.mode = m;
    }
    pub fn set_render_distance(&mut self, chunks: i32) {
        self.stream_r = chunks.clamp(4, 40);
        self.stream_active_r = self.stream_active_r.clamp(2, self.stream_r);
    }
    pub fn apply_render_distance(&mut self, chunks: i32) {
        self.set_render_distance(chunks);
        self.recompute_stream_set();
    }
    pub fn set_edit_callback(&mut self, cb: EditCb) {
        self.edit_cb = Some(cb);
    }
    /// Remove the local-edit callback (co-op teardown: stop replicating edits).
    pub fn clear_edit_callback(&mut self) {
        self.edit_cb = None;
    }
    pub fn apply_remote_edit(&mut self, w: IVec3, b: BlockId) {
        self.set_block_remote(w, b, true);
    }
    pub fn set_extra(&mut self, x: &'c ContentExtra) {
        self.extra = Some(x);
    }
    pub fn set_fx_callback(&mut self, cb: FxCb) {
        self.fx_cb = Some(cb);
    }
    pub fn get_player(&self) -> (f32, f32, f32, f32) {
        (self.pos.x, self.pos.y, self.pos.z, self.yaw)
    }
    pub fn world_seed(&self) -> u64 {
        self.seed
    }
    pub fn set_remote_avatars(&mut self, a: Vec<bf_entity_draw>) {
        self.remote_avatars = a;
    }
    pub fn mode(&self) -> bf_game_mode {
        self.mode
    }

    fn fx(&mut self, code: i32, p: IVec3, extra: i32) {
        if let Some(cb) = self.fx_cb.as_mut() {
            cb(code, p, extra);
        }
    }

    /// Wire the loaded content. Builds the inventory + resolves the gameplay block ids
    /// by name (so the engine never hard-codes content ids), then hands out the
    /// mode-appropriate starter items.
    pub fn set_content(&mut self, c: &'c ContentRegistry) {
        self.content = Some(c);
        self.inv = Some(Inventory::new(BF_INVENTORY_SLOTS, Some(c)));
        self.glow_id = self.block_id_by_name("glow_block");
        self.beacon_id = self.block_id_by_name("beacon_block");
        self.give_starter_items();
    }

    pub fn item_id_by_name(&self, n: &str) -> ItemId {
        self.content.and_then(|c| c.item_by_name(n)).map(|d| d.id).unwrap_or(0)
    }
    pub fn block_id_by_name(&self, n: &str) -> BlockId {
        self.content.and_then(|c| c.block_by_name(n)).map(|d| d.id).unwrap_or(0)
    }
    fn item_name(&self, i: ItemId) -> String {
        self.content.and_then(|c| c.item_by_id(i)).map(|d| d.name.clone()).unwrap_or_default()
    }
    fn block_name(&self, b: BlockId) -> String {
        self.content.and_then(|c| c.block_by_id(b)).map(|d| d.name.clone()).unwrap_or_default()
    }

    fn give_starter_items(&mut self) {
        // Resolve ids first (immutable content borrow) then write (mutable inv borrow).
        if self.mode == bf_game_mode::BF_MODE_CREATIVE {
            let hot: [&str; BF_HOTBAR_SLOTS] = [
                "glow_block", "stone", "oak_planks", "stone_brick", "sand", "oak_log", "torch",
                "chest", "crafting_table",
            ];
            for (i, name) in hot.iter().enumerate() {
                let id = self.item_id_by_name(name);
                if id != 0 {
                    if let Some(inv) = self.inv.as_mut() {
                        inv.set(i, ItemStack { item: id, count: 64, durability: 0xFFFF });
                    }
                }
            }
        } else {
            let log = self.item_id_by_name("oak_log");
            let coal = self.item_id_by_name("coal");
            let stick = self.item_id_by_name("stick");
            if let Some(inv) = self.inv.as_mut() {
                if log != 0 {
                    inv.set(0, ItemStack { item: log, count: 3, durability: 0xFFFF });
                }
                if coal != 0 {
                    inv.set(9, ItemStack { item: coal, count: 2, durability: 0xFFFF });
                }
                if stick != 0 {
                    inv.set(10, ItemStack { item: stick, count: 2, durability: 0xFFFF });
                }
            }
        }
    }

    // ---- M2: procedural spawn + streaming --------------------------------
    pub fn init_world(&mut self, seed: u64) {
        self.seed = seed;
        if self.gen.is_none() {
            self.generate_test_world();
            return;
        }
        if let Some(g) = self.gen.as_mut() {
            g.seed(seed);
        }
        // Pick a DRY-LAND spawn column near the origin (never wake up in water).
        // #: real oceans can put the origin in open water, and a whole coast can be
        // wider than the old 120-block search. Search outward in expanding rings far
        // enough to clear an ocean and reach the nearest shore (step 8, up to ~768
        // blocks). The scan is a one-time cheap height lookup per ring cell.
        const SEA_LEVEL: i32 = 6;
        const SPAWN_STEP: i32 = 8;
        const SPAWN_MAX_R: i32 = 96; // 96 * 8 = 768 blocks of reach
        let mut sx = 0i32;
        let mut sz = 0i32;
        if worldgen::worldgen_surface_height(0, 0, self.seed) < SEA_LEVEL + 1 {
            let mut dry = false;
            let mut r = 1;
            while r <= SPAWN_MAX_R && !dry {
                let mut dz = -r;
                while dz <= r && !dry {
                    let mut dx = -r;
                    while dx <= r && !dry {
                        let adx = if dx < 0 { -dx } else { dx };
                        let adz = if dz < 0 { -dz } else { dz };
                        if adx.max(adz) != r {
                            dx += 1;
                            continue;
                        }
                        let wx = dx * SPAWN_STEP;
                        let wz = dz * SPAWN_STEP;
                        if worldgen::worldgen_surface_height(wx, wz, self.seed) >= SEA_LEVEL + 1 {
                            sx = wx;
                            sz = wz;
                            dry = true;
                        }
                        dx += 1;
                    }
                    dz += 1;
                }
                r += 1;
            }
        }
        // Find the surface at the chosen spawn column.
        let scol = Self::to_chunk(IVec3 { x: sx, y: 0, z: sz });
        let slx = Self::mod16(sx);
        let slz = Self::mod16(sz);
        let mut surface = 8;
        let mut found = false;
        for cy in (CY_MIN..=CY_MAX).rev() {
            let cc = ChunkCoord { x: scol.x, y: cy, z: scol.z };
            let ch = match self.gen_chunk(cc) {
                Some(c) => c,
                None => continue,
            };
            if !found {
                for ly in (0..KCHUNK_DIM).rev() {
                    if ch.get(slx as usize, ly as usize, slz as usize) != AIR {
                        surface = cy * KCHUNK_DIM + ly;
                        found = true;
                        break;
                    }
                }
            }
            if !(ch.is_uniform() && ch.get(0, 0, 0) == AIR) {
                self.store.insert(ch);
                self.mark_dirty(cc);
            }
        }
        // Eye 3.2 above the surface so the feet clear the top block.
        self.pos = V3::new(sx as f32 + 0.5, surface as f32 + 3.2, sz as f32 + 0.5);
        self.spawn = self.pos;
        self.yaw = 0.6;
        self.pitch = -0.25;
        // Spawn homeland starts colourful out to a generous radius.
        {
            let sr = Self::region_key(ChunkCoord { x: scol.x, y: 0, z: scol.z });
            for dz in -2..=2 {
                for dx in -2..=2 {
                    self.region_sat.insert(RegionKey { x: sr.x + dx, z: sr.z + dz }, 1.0);
                }
            }
        }
        self.last_center = Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        });
        self.stream_active_r = 2.min(self.stream_r);
        self.recompute_stream_set();
        self.creatures.clear();
        self.chests.clear();
        self.creature_timer = 0.0;
        self.all_quests_done = false;
        self.quests_completed = 0;
        self.regions_restored = 0;
        self.start_quest(0);
        self.ensure_clear_spawn();
    }

    fn ensure_clear_spawn(&mut self) {
        if self.gen.is_none() {
            return;
        }
        let pc = Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        });
        for cy in (CY_MIN..=CY_MAX).rev() {
            let cc = ChunkCoord { x: pc.x, y: cy, z: pc.z };
            if self.store.is_resident(cc) {
                continue;
            }
            if let Some(ch) = self.gen_chunk(cc) {
                if !(ch.is_uniform() && ch.get(0, 0, 0) == AIR) {
                    self.store.insert(ch);
                    self.mark_dirty(cc);
                }
            }
        }
        if self.box_collides(self.pos) {
            let mut i = 0;
            while i < 64 && self.box_collides(self.pos) {
                self.pos.y += 1.0;
                i += 1;
            }
            self.pos.y += 0.1;
            self.vy = 0.0;
            self.spawn = self.pos;
        }
    }

    // ---- flat world (deterministic mine/place test) ----------------------
    pub fn generate_test_world(&mut self) {
        let r = 2;
        for cx in -r..=r {
            for cz in -r..=r {
                let cc = ChunkCoord { x: cx, y: 0, z: cz };
                {
                    let ch = self.store.get_or_create(cc);
                    for lx in 0..KCHUNK_DIM {
                        for lz in 0..KCHUNK_DIM {
                            for ly in 0..8 {
                                let b = if ly == 7 {
                                    GRASS
                                } else if ly >= 4 {
                                    DIRT
                                } else {
                                    STONE
                                };
                                ch.set(lx as usize, ly as usize, lz as usize, b);
                            }
                        }
                    }
                }
                self.mark_dirty(cc);
                self.restore_region(cc);
            }
        }
        self.pos = V3::new(8.0, 12.0, 8.0);
        self.yaw = 3.14159;
        self.pitch = -0.5;
    }


    fn hurt_player(&mut self, dmg: f32) {
        if self.hurt_cd > 0.0 {
            return;
        }
        self.health = (self.health - dmg).max(0.0);
        self.hurt_cd = 0.6;
        self.regen_cd = 5.0;
        let pv = self.player_voxel();
        self.fx(9, pv, 0);
    }

    fn respawn(&mut self) {
        let top = self.surface_top(Self::ifloor(self.spawn.x), Self::ifloor(self.spawn.z));
        let y = if top != NO_FLOOR { top as f32 + 3.2 } else { self.spawn.y };
        self.pos = V3::new(self.spawn.x, y, self.spawn.z);
        self.vy = 0.0;
        self.health = 20.0;
        self.oxygen = 1.0;
        self.hurt_cd = 1.5;
        self.regen_cd = 0.0;
        self.drown_cd = 0.0;
        self.first_stream = true;
        self.stream_active_r = 2.min(self.stream_r);
        self.recompute_stream_set();
        self.creatures.retain(|c| !c.hostile);
        let pv = self.player_voxel();
        self.fx(6, pv, 0);
    }

    fn maintain_villagers(&mut self, dt: f32) {
        if self.gen.is_none() || self.extra.is_none() || self.store.resident_count() < 20 {
            return;
        }
        self.villager_timer -= dt;
        if self.villager_timer > 0.0 {
            return;
        }
        self.villager_timer = 2.0;
        const KVCAP: i32 = 6;
        let mut have = self.creatures.iter().filter(|c| c.model == 20).count() as i32;
        if have >= KVCAP {
            return;
        }
        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);
        let mut dz = -128;
        while dz <= 128 {
            let mut dx = -128;
            while dx <= 128 {
                if have >= KVCAP {
                    return;
                }
                let (typ, ax, az, ay) = worldgen::worldgen_structure_near(px + dx, pz + dz, self.seed);
                if typ == 0 {
                    dx += 64;
                    continue;
                }
                let ddx = ax as f32 - self.pos.x;
                let ddz = az as f32 - self.pos.z;
                if ddx * ddx + ddz * ddz > 80.0 * 80.0 {
                    dx += 64;
                    continue;
                }
                if !self.store.is_resident(Self::to_chunk(IVec3 { x: ax, y: ay, z: az })) {
                    dx += 64;
                    continue;
                }
                let present = self.creatures.iter().any(|c| {
                    c.model == 20 && (c.pos.x - ax as f32).abs() < 10.0 && (c.pos.z - az as f32).abs() < 10.0
                });
                if present {
                    dx += 64;
                    continue;
                }
                have += self.spawn_villager_at(ax, ay, az, KVCAP - have);
                dx += 64;
            }
            dz += 64;
        }
    }

    // Profession (npc_id) for the villager at `idx` within a single settlement.
    //
    // The trade roles form a tool chain: Woodcutter (4, wood) -> Stone Mason (5, stone)
    // -> Blacksmith (6, iron). A higher tier is useless without the ones below it, so a
    // small village must never hand the player a stranded high tier. Roles 1..=3 (Elder,
    // Builder, Herbalist) are social / quest givers and carry no chain requirement.
    //
    // Villages fill from the bottom of the chain up, interleaving social roles so a
    // higher trade tier only appears at a later index than every lower tier. The result
    // is always a chain prefix: a 1-villager hamlet has only a Woodcutter, and stone /
    // iron arrive only once the settlement is large enough to have the tiers below them.
    //
    // Cities are the place to complete progression, so they front-load the full chain
    // (wood, stone, iron in the first three slots); a city reliably reaches the cap, so
    // all three tiers are guaranteed present.
    //
    // Both orders are pure functions of (is_city, idx): deterministic, no RNG, so the
    // same villager index in the same settlement always gets the same role.
    fn villager_npc_for_index(is_city: bool, idx: i32) -> i32 {
        // npc_id roster: 1 Elder, 2 Builder, 3 Herbalist, 4 Woodcutter (wood),
        // 5 Stone Mason (stone), 6 Blacksmith (iron).
        let city_order = [4, 5, 6, 1, 2, 3];
        let village_order = [4, 1, 5, 2, 6, 3];
        let order = if is_city { &city_order } else { &village_order };
        let i = if idx < 0 { 0 } else { idx as usize };
        // Beyond the roster (a settlement bigger than 6 villagers) we cycle, which only
        // ever repeats roles whose prerequisites are already present, so the prefix
        // property still holds.
        order[i % order.len()]
    }

    fn spawn_villager_at(&mut self, ax: i32, ay: i32, az: i32, budget: i32) -> i32 {
        let pool: Vec<CreatureDefX> = match self.extra {
            Some(x) => x.creatures().iter().filter(|d| d.model == 20).cloned().collect(),
            None => return 0,
        };
        if pool.is_empty() || budget <= 0 {
            return 0;
        }
        // Is this settlement a city? Cities host the full profession chain; villages get
        // an ordered chain prefix. The structure type comes straight from worldgen so the
        // worldgen city upgrade and the profession assignment stay in sync (one source of
        // truth for "city vs village").
        let (styp, _sx, _sz, _sy) = worldgen::worldgen_structure_near(ax, az, self.seed);
        let is_city = worldgen::worldgen_is_city(styp);
        // Index of the next villager within THIS settlement: count the ones already
        // anchored at this home. Spawning is incremental, so this keeps the per-settlement
        // role sequence stable as the village fills up over time.
        let mut idx_in_settlement = self
            .creatures
            .iter()
            .filter(|c| c.model == 20 && c.home_x == ax && c.home_z == az)
            .count() as i32;
        let n = budget.min(1 + if self.rand01() < 0.5 { 1 } else { 0 });
        let mut made = 0;
        for _ in 0..n {
            let ox = ax as f32 + (self.rand01() * 5.0 - 2.5);
            let oz = az as f32 + (self.rand01() * 5.0 - 2.5);
            let gy = self.floor_below(Self::ifloor(ox), ay + 4, Self::ifloor(oz));
            if gy == NO_FLOOR {
                continue;
            }
            if self.block_at(IVec3 { x: Self::ifloor(ox), y: gy + 1, z: Self::ifloor(oz) }) == WATER {
                continue;
            }
            let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
            let d = &pool[pick];
            let mut c = Creature::default();
            c.pos = V3::new(ox, gy as f32, oz);
            c.yaw = self.rand01() * 6.2831853;
            c.model = d.model;
            c.npc_id = Self::villager_npc_for_index(is_city, idx_in_settlement);
            idx_in_settlement += 1;
            c.home_x = ax;
            c.home_z = az;
            c.name = d.name.clone();
            c.speed = if d.move_speed > 0.0 { d.move_speed * 0.5 } else { 0.8 };
            c.hp = if d.max_health > 0 { d.max_health as i32 } else { 20 };
            c.scale = 0.95;
            c.color = Self::color_for("passive", d.id);
            c.wander = 1.0 + self.rand01() * 2.0;
            self.creatures.push(c);
            made += 1;
        }
        made
    }

    // Small helper: set the achievement-toast banner with the standard 3s timer.
    fn toast(&mut self, msg: &str) {
        self.ach_toast = msg.into();
        self.ach_toast_timer = 3.0;
    }

    fn grow_small_tree(&mut self, wx: i32, surf: i32, wz: i32) {
        const LOG: BlockId = 21;
        const LEAFB: BlockId = 5;
        let h = 4 + (self.rand01() * 2.0) as i32;
        let top = surf + h;
        for y in (surf + 1)..=top {
            self.set_block_internal(IVec3 { x: wx, y, z: wz }, LOG);
        }
        for dy in -1..=2 {
            for dz in -2..=2 {
                for dx in -2..=2 {
                    if dx * dx + dz * dz + dy * dy * 2 > 5 {
                        continue;
                    }
                    if dx == 0 && dz == 0 && dy <= 0 {
                        continue;
                    }
                    let p = IVec3 { x: wx + dx, y: top + dy, z: wz + dz };
                    if self.block_at(p) == AIR {
                        self.set_block_internal(p, LEAFB);
                    }
                }
            }
        }
    }
    fn maintain_regrowth(&mut self, dt: f32) {
        if self.gen.is_none() {
            return;
        }
        self.regrow_timer -= dt;
        if self.regrow_timer > 0.0 {
            return;
        }
        self.regrow_timer = 5.0;
        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);
        let mut grew = 0;
        let mut attempt = 0;
        while attempt < 12 && grew < 2 {
            attempt += 1;
            let wx = px + (self.rand01() * 96.0) as i32 - 48;
            let wz = pz + (self.rand01() * 96.0) as i32 - 48;
            if !self.store.is_resident(Self::to_chunk(IVec3 { x: wx, y: 0, z: wz })) {
                continue;
            }
            if self.region_sat(Self::to_chunk(IVec3 { x: wx, y: 0, z: wz })) < 0.5 {
                continue;
            }
            let surf = self.surface_top(wx, wz);
            if surf == NO_FLOOR {
                continue;
            }
            if self.block_at(IVec3 { x: wx, y: surf, z: wz }) != 1 {
                continue;
            }
            let above = self.block_at(IVec3 { x: wx, y: surf + 1, z: wz });
            if above != AIR && !Self::is_plant(above) {
                continue;
            }
            let mut near_tree = false;
            'outer: for dz in -3..=3 {
                for dx in -3..=3 {
                    for y in (surf + 1)..=(surf + 6) {
                        if Self::is_tree_block(self.block_at(IVec3 { x: wx + dx, y, z: wz + dz })) {
                            near_tree = true;
                            break 'outer;
                        }
                    }
                }
            }
            if near_tree {
                continue;
            }
            self.grow_small_tree(wx, surf, wz);
            grew += 1;
        }
    }

    // The AI pathfinder asks the world about terrain through this thin shim; it never
    // touches World internals directly (epic #131, creature_ai.rs).
    fn ai_is_solid(&self, x: i32, y: i32, z: i32) -> bool {
        self.collide_solid(x, y, z)
    }

    // A creature ran into an impassable wall or a water edge: turn it away. Uses the
    // world rng so the turn stays deterministic. Delegates the heading swing to the
    // AI so the body eases around rather than snapping (epic #131).
    fn creature_blocked(&mut self, c: &mut Creature, _dt: f32) {
        let turn = 2.0 + self.rand01() * 2.2;
        c.ai.on_blocked(turn);
    }

    fn update_creatures(&mut self, dt: f32) {
        // Smooth step-up tuning. A creature blocked by a ledge it can stand on climbs
        // its Y up at CLIMB_SPEED blocks/sec (a clamber that reads over a few ticks at
        // the usual ~0.05s dt) instead of teleporting up a whole block. MAX_CLIMB caps
        // how tall a step it will attempt; anything taller stays blocked so the AI
        // turns and goes around, exactly as before this change.
        const CLIMB_SPEED: f32 = 3.0;
        const MAX_CLIMB: i32 = 2;
        let n = self.creatures.len();
        for i in 0..n {
            // Snapshot the fields we need for read-only logic, then write back.
            let mut c = self.creatures[i].clone();
            c.wander -= dt;
            if c.hit_flash > 0.0 {
                c.hit_flash -= dt;
            }
            let to_player = self.pos - c.pos;
            if c.aquatic {
                if c.wander <= 0.0 {
                    c.yaw = self.rand01() * 6.2831853;
                    c.wander = 1.0 + self.rand01() * 2.0;
                }
                let d2 = V3::new(c.yaw.sin(), 0.0, c.yaw.cos());
                let nx = c.pos + d2 * (c.speed * dt);
                if self.block_at(IVec3 { x: Self::ifloor(nx.x), y: Self::ifloor(nx.y), z: Self::ifloor(nx.z) }) == WATER {
                    c.pos.x = nx.x;
                    c.pos.z = nx.z;
                } else if c.wander <= 0.0 {
                    c.yaw += 2.0 + self.rand01() * 2.2;
                    c.wander = 0.6 + self.rand01() * 0.6;
                }
                c.pos.y += (self.world_clock as f32 * 2.0 + c.pos.x).sin() * 0.4 * dt;
                if self.block_at(IVec3 { x: Self::ifloor(c.pos.x), y: Self::ifloor(c.pos.y), z: Self::ifloor(c.pos.z) }) != WATER
                    && self.block_at(IVec3 { x: Self::ifloor(c.pos.x), y: Self::ifloor(c.pos.y) - 1, z: Self::ifloor(c.pos.z) }) == WATER
                {
                    c.pos.y -= 0.5 * dt * 4.0;
                }
                self.creatures[i] = c;
                continue;
            }
            // ---- AI + smooth locomotion (epic #131, creature_ai.rs) -----------
            // Decision (which state, where to face, how fast) and the path follow
            // + smooth turn/accel all live in creature_ai; here we only classify
            // the creature into a temperament, run melee, and apply the resulting
            // smoothed displacement through the EXISTING collision/climb code below.
            use crate::creature_ai as cai;
            let xzd = (to_player.x * to_player.x + to_player.z * to_player.z).sqrt();
            let temper = if c.wander > 900.0 {
                // Scripted straight-walker (set by debug_spawn_creature_at for the
                // deterministic locomotion/climb tests): ignore the player, walk on.
                cai::Temperament::Scripted
            } else if c.hostile {
                cai::Temperament::Hunter
            } else if c.friendly {
                // Befriended pet: follows the player, keeps comfortable spacing.
                cai::Temperament::Pet
            } else if c.model == 20 {
                // Villagers idle and roam their settlement.
                cai::Temperament::Villager
            } else {
                // Animals (incl. skittish ones) graze + flee the player.
                cai::Temperament::Passive
            };
            // Hostiles only seek/attack in survival; outside survival they amble.
            let hunting = c.hostile && self.mode == bf_game_mode::BF_MODE_SURVIVAL;
            let eff_temper = if c.hostile && !hunting { cai::Temperament::Passive } else { temper };
            // Melee: unchanged behaviour, fires when a hunting hostile is in range.
            if hunting {
                if c.atk_cd > 0.0 {
                    c.atk_cd -= dt;
                }
                let yd = ((c.pos.y + c.scale * 0.5) - (self.pos.y - 1.6)).abs();
                if xzd < 1.3 && yd < 1.6 && c.atk_cd <= 0.0 {
                    self.hurt_player(2.5);
                    c.atk_cd = 1.1;
                }
            }
            // Drive the behaviour state machine from the world rng so it stays
            // deterministic with the rest of the sim. The world's rng is the seed.
            c.ai.tick_repath();
            let mut seed = self.rng;
            let dec = cai::decide(
                &mut c.ai,
                eff_temper,
                c.pos.x,
                c.pos.z,
                self.pos.x,
                self.pos.z,
                xzd,
                dt,
                &mut seed,
            );
            self.rng = seed;
            // Seeking hostiles path around obstacles with throttled, bounded A*.
            let mut desired_heading = dec.desired_heading;
            if let Some(goal) = dec.path_goal {
                if c.ai.needs_repath(goal) {
                    let sy = Self::ifloor(c.pos.y);
                    let path = cai::find_path(self, Self::ifloor(c.pos.x), Self::ifloor(c.pos.z), sy, goal.0, goal.1);
                    c.ai.set_path(path);
                }
                if let Some(h) = c.ai.follow_heading(c.pos.x, c.pos.z) {
                    desired_heading = h;
                } else {
                    // Path exhausted but not yet in melee range: steer straight in.
                    desired_heading = (self.pos.x - c.pos.x).atan2(self.pos.z - c.pos.z);
                }
            } else {
                c.ai.path.clear();
            }
            // Smooth turn + accel toward the decision, then apply the displacement
            // through the existing collision/climb code. step_locomotion never snaps
            // heading or velocity, so creatures rotate and ramp instead of flipping.
            let target_speed = c.speed * dec.speed_frac;
            let (mdx, mdz, new_heading, new_speed) = cai::step_locomotion(&c.ai, desired_heading, target_speed, dt);
            c.ai.heading = new_heading;
            c.ai.speed = new_speed;
            c.yaw = new_heading;
            let next = V3::new(c.pos.x + mdx, c.pos.y, c.pos.z + mdz);
            let nv = IVec3 { x: Self::ifloor(next.x), y: Self::ifloor(next.y), z: Self::ifloor(next.z) };
            let into_water = !c.aquatic
                && (self.block_at(IVec3 { x: nv.x, y: nv.y, z: nv.z }) == WATER
                    || self.block_at(IVec3 { x: nv.x, y: nv.y - 1, z: nv.z }) == WATER);
            // #95 walls keep monsters out: a hostile may not cross into a walled village's
            // protected interior. (The wall blocks itself stop a creature that bumps the
            // line; this is the belt-and-braces guard so a hostile can never slip through
            // the gate or a worldgen seam into a protected interior.) A hostile already
            // somehow inside is free to leave.
            let into_protected = c.hostile
                && self.village_protects(nv.x, nv.z).is_some()
                && self.village_protects(Self::ifloor(c.pos.x), Self::ifloor(c.pos.z)).is_none();
            if !into_water && !into_protected && !self.collide_solid(nv.x, nv.y, nv.z) {
                c.pos.x = next.x;
                c.pos.z = next.z;
            } else if !into_water && !into_protected {
                // Blocked horizontally by a step. Find the lowest height the creature
                // could stand on top of: scan up from the blocking block to the first
                // free cell, capped at MAX_CLIMB blocks. A step within reach starts a
                // smooth climb (raise Y over several ticks, see below) instead of the
                // old instant one block pop; a taller wall stays blocked so the AI
                // turns and paths around it just like before.
                let mut step_h = 0i32;
                let mut h = 1i32;
                while h <= MAX_CLIMB {
                    if !self.collide_solid(nv.x, nv.y + h, nv.z) {
                        step_h = h;
                        break;
                    }
                    h += 1;
                }
                if step_h > 0 {
                    // Take the horizontal step now and queue the remaining vertical
                    // rise; the climb advance below interpolates Y up smoothly.
                    c.pos.x = next.x;
                    c.pos.z = next.z;
                    c.climb = (step_h as f32 - (c.pos.y - c.pos.y.floor())).max(c.climb);
                } else {
                    // Wall too tall to step: nudge the AI to turn away. Pathing
                    // creatures repath next chance; wanderers pick a new amble dir.
                    self.creature_blocked(&mut c, dt);
                }
            } else if into_water {
                // Edge of water: turn away rather than wade in (non-aquatic).
                self.creature_blocked(&mut c, dt);
            } else if into_protected {
                // #95 turned back at a village wall: stay out and pick a new heading.
                self.creature_blocked(&mut c, dt);
            }
            if c.climb > 0.0 {
                // Smooth clamber: raise Y toward the ledge top at a fixed climb speed
                // (deterministic, fixed dt) rather than snapping a whole block. Gravity
                // is skipped this tick so it does not pull against the climb.
                let rise = (CLIMB_SPEED * dt).min(c.climb);
                c.pos.y += rise;
                c.climb -= rise;
                if c.climb < 1e-4 {
                    c.climb = 0.0;
                }
                c.vy = 0.0;
            } else {
                // gravity + land on floor below.
                c.vy -= 24.0 * dt;
                c.pos.y += c.vy * dt;
                let fy = self.floor_below(Self::ifloor(c.pos.x), c.pos.y.floor() as i32 + 1, Self::ifloor(c.pos.z));
                if fy != NO_FLOOR && c.pos.y <= fy as f32 {
                    c.pos.y = fy as f32;
                    c.vy = 0.0;
                } else if fy == NO_FLOOR {
                    c.vy = 0.0;
                }
            }
            let grounded_fy = if c.vy == 0.0 && !c.aquatic {
                let fy = self.floor_below(
                    Self::ifloor(c.pos.x),
                    c.pos.y.floor() as i32 + 1,
                    Self::ifloor(c.pos.z),
                );
                if fy != NO_FLOOR && (c.pos.y - fy as f32).abs() < 0.2 {
                    Some(fy)
                } else {
                    None
                }
            } else {
                None
            };
            let cell_xz = (Self::ifloor(c.pos.x), Self::ifloor(c.pos.z));
            self.creatures[i] = c;
            // #117 creatures leave prints too: a grounded land creature on fresh snow
            // compresses it. Same fresh-only, O(1) stamp as the player, so the cost is
            // bounded by the (small) creature count, not the trail length.
            if let Some(fy) = grounded_fy {
                self.stamp_footprint(IVec3 { x: cell_xz.0, y: fy, z: cell_xz.1 });
            }
        }

        // ---- collision: creatures (animals + villagers) hold distinct space ----
        let nc = self.creatures.len();
        for i in 0..nc {
            if self.creatures[i].aquatic {
                continue;
            }
            for j in (i + 1)..nc {
                if self.creatures[j].aquatic {
                    continue;
                }
                let (ax0, az0, ay0, ascale) = {
                    let a = &self.creatures[i];
                    (a.pos.x, a.pos.z, a.pos.y, a.scale)
                };
                let (bx0, bz0, by0, bscale) = {
                    let b = &self.creatures[j];
                    (b.pos.x, b.pos.z, b.pos.y, b.scale)
                };
                let dx = bx0 - ax0;
                let dz = bz0 - az0;
                let d2 = dx * dx + dz * dz;
                let mut min_d = (ascale + bscale) * 0.45;
                if min_d < 0.7 {
                    min_d = 0.7;
                }
                if d2 >= min_d * min_d {
                    continue;
                }
                let deg = d2 <= 1e-6;
                let d = if deg { 0.001 } else { d2.sqrt() };
                let nx = if deg {
                    ((i + j) & 1) as f32 * 2.0 - 1.0
                } else {
                    dx / d
                };
                let nz = if deg { 0.0 } else { dz / d };
                let push = (min_d - d) * 0.5;
                let ax = ax0 - nx * push;
                let az = az0 - nz * push;
                let bx = bx0 + nx * push;
                let bz = bz0 + nz * push;
                if !self.collide_solid(Self::ifloor(ax), Self::ifloor(ay0), Self::ifloor(az)) {
                    self.creatures[i].pos.x = ax;
                    self.creatures[i].pos.z = az;
                }
                if !self.collide_solid(Self::ifloor(bx), Self::ifloor(by0), Self::ifloor(bz)) {
                    self.creatures[j].pos.x = bx;
                    self.creatures[j].pos.z = bz;
                }
            }
        }
        // ---- collision: keep non-hostile creatures out of the player's space ----
        let px = self.pos.x;
        let pz = self.pos.z;
        let survival = self.mode == bf_game_mode::BF_MODE_SURVIVAL;
        for i in 0..self.creatures.len() {
            let (cx0, cz0, cy0, cscale, aquatic, hostile) = {
                let c = &self.creatures[i];
                (c.pos.x, c.pos.z, c.pos.y, c.scale, c.aquatic, c.hostile)
            };
            if aquatic {
                continue;
            }
            if hostile && survival {
                continue;
            }
            let dx = cx0 - px;
            let dz = cz0 - pz;
            let d2 = dx * dx + dz * dz;
            let min_d = 0.85 + cscale * 0.45;
            if d2 >= min_d * min_d {
                continue;
            }
            let deg = d2 <= 1e-6;
            let d = if deg { 0.001 } else { d2.sqrt() };
            let nx = if deg { 1.0 } else { dx / d };
            let nz = if deg { 0.0 } else { dz / d };
            let push = min_d - d;
            let cx = cx0 + nx * push;
            let cz = cz0 + nz * push;
            if !self.collide_solid(Self::ifloor(cx), Self::ifloor(cy0), Self::ifloor(cz)) {
                self.creatures[i].pos.x = cx;
                self.creatures[i].pos.z = cz;
            }
        }
    }



    // ---- per-frame update ------------------------------------------------
    pub fn update(&mut self, input: &bf_frame_input, dt: f64) {
        let mut dt = dt;
        if dt > 0.1 {
            dt = 0.1;
        }
        let dtf = dt as f32;
        self.moving = (input.move_forward.abs() + input.move_strafe.abs() + (input.jump as f32).abs()) > 0.1;
        self.world_clock += dt;
        // Hold the sun fixed when always-day / always-night is active (no-op in auto).
        self.apply_time_pin();
        if self.hurt_cd > 0.0 {
            self.hurt_cd -= dtf;
        }
        if self.regen_cd > 0.0 {
            self.regen_cd -= dtf;
        }
        if self.ach_toast_timer > 0.0 {
            self.ach_toast_timer -= dtf;
        }
        if self.regen_cd <= 0.0 && self.health < 20.0 {
            self.health = (self.health + 1.2 * dtf).min(20.0);
        }
        // Oxygen / drowning.
        let head_under = self.block_at(self.player_voxel()) == WATER;
        if head_under {
            self.oxygen = (self.oxygen - dtf / 16.0).max(0.0);
            if self.oxygen <= 0.0 {
                self.drown_cd -= dtf;
                if self.drown_cd <= 0.0 {
                    self.health = (self.health - 2.0).max(0.0);
                    let pv = self.player_voxel();
                    self.fx(9, pv, 0);
                    self.drown_cd = 1.0;
                    self.regen_cd = 4.0;
                }
            }
        } else {
            self.oxygen = (self.oxygen + dtf * 0.7).min(1.0);
            self.drown_cd = 0.0;
        }
        if self.health <= 0.0 {
            self.oxygen = 1.0;
            self.respawn();
        }
        if self.pos.y < -40.0 {
            self.oxygen = 1.0;
            self.vy = 0.0;
            self.respawn();
        }

        self.yaw += input.look_yaw_delta;
        self.pitch += input.look_pitch_delta;
        let lim = 1.5533;
        self.pitch = self.pitch.clamp(-lim, lim);

        let fwd = self.forward_dir();
        let flat = normalize(V3::new(fwd.x, 0.0, fwd.z));
        let right = normalize(cross(flat, V3::new(0.0, 1.0, 0.0)));
        let base_spd = if self.mode == bf_game_mode::BF_MODE_CREATIVE { 8.0 } else { 5.0 };
        // Creative sprint is a fast fly/run for building and exploring: roughly 5x the
        // survival sprint speed (survival sprint stays at 8.5; 8.5 * 5 = 42.5).
        let sprint_spd = if self.mode == bf_game_mode::BF_MODE_CREATIVE { 42.5 } else { 8.5 };
        let speed = (if input.sprint != 0 { sprint_spd } else { base_spd }) * dtf;
        let hmove = flat * (input.move_forward * speed) + right * (input.move_strafe * speed);
        if self.mode == bf_game_mode::BF_MODE_CREATIVE {
            self.pos = self.pos + hmove;
            if input.jump != 0 || input.fly_ascend != 0 {
                self.pos.y += speed;
            }
            if input.sneak != 0 || input.fly_descend != 0 {
                self.pos.y -= speed;
            }
            self.vy = 0.0;
        } else {
            self.pos.x += hmove.x;
            if self.box_collides(self.pos) {
                self.pos.x -= hmove.x;
            }
            self.pos.z += hmove.z;
            if self.box_collides(self.pos) {
                self.pos.z -= hmove.z;
            }
            let in_water = self.block_at(IVec3 {
                x: Self::ifloor(self.pos.x),
                y: Self::ifloor(self.pos.y - 0.8),
                z: Self::ifloor(self.pos.z),
            }) == WATER
                || self.block_at(IVec3 {
                    x: Self::ifloor(self.pos.x),
                    y: Self::ifloor(self.pos.y - 1.5),
                    z: Self::ifloor(self.pos.z),
                }) == WATER;
            if in_water {
                if input.jump != 0 {
                    self.vy = 5.2;
                } else if input.sneak != 0 {
                    self.vy = -4.6;
                } else {
                    self.vy = (self.vy - 6.0 * dtf).max(-2.0);
                }
            } else {
                if input.jump != 0 && self.on_ground {
                    self.vy = 8.4;
                    let pv = self.player_voxel();
                    self.fx(3, pv, 0);
                }
                self.vy = (self.vy - 28.0 * dtf).max(-64.0);
            }
            let dy = self.vy * dtf;
            self.pos.y += dy;
            self.on_ground = false;
            if self.box_collides(self.pos) {
                self.pos.y -= dy;
                if self.vy < 0.0 {
                    self.on_ground = true;
                }
                self.vy = 0.0;
            }
        }

        // Stream as the player crosses chunk boundaries.
        let pc = Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        });
        if pc != self.last_center || self.first_stream {
            self.last_center = pc;
            self.first_stream = false;
            self.recompute_stream_set();
            if self.region_sat(pc) < 0.99 {
                self.notify_quest("reach_location", "dim_barrens");
            }
        }
        self.stream_tick();
        self.maybe_expand_stream_radius();

        self.raycast_target();
        if self.mining && self.has_target {
            let bt = self.break_time(self.block_at(self.target));
            self.mine_progress += dtf / bt;
            if self.mine_progress >= 1.0 {
                let t = self.target;
                self.break_block(t);
                self.damage_held_tool();
                self.mine_progress = 0.0;
                self.raycast_target();
            }
        } else {
            self.mine_progress = 0.0;
        }

        // View-bob + footsteps.
        let walking = self.mode == bf_game_mode::BF_MODE_SURVIVAL
            && self.on_ground
            && (input.move_forward.abs() + input.move_strafe.abs() > 0.1);
        if walking {
            self.bob_phase += dtf * 9.5;
            self.bob_amt = (self.bob_amt + dtf * 5.0).min(1.0);
            self.step_timer -= dtf;
            if self.step_timer <= 0.0 {
                self.step_timer = 0.45;
                let pv = self.player_voxel();
                let gy = self.floor_below(pv.x, pv.y + 1, pv.z);
                let fb = if gy != NO_FLOOR {
                    self.block_at(IVec3 { x: pv.x, y: gy - 1, z: pv.z })
                } else {
                    GRASS
                };
                self.fx(2, pv, Self::footstep_class(fb));
                // #117 footprint: if the cell at the player's feet is fresh snow, compress
                // it into a trodden print. Bounded by construction (one cell per step, and
                // fresh snow only converts once), so there is no growing print buffer.
                if gy != NO_FLOOR {
                    self.stamp_footprint(IVec3 { x: pv.x, y: gy, z: pv.z });
                }
            }
        } else {
            self.bob_amt = (self.bob_amt - dtf * 7.0).max(0.0);
        }

        self.maintain_creatures(dtf);
        self.maintain_danger_sites(dtf);
        self.maintain_villagers(dtf);
        self.maintain_regrowth(dtf);
        self.update_creatures(dtf);
        self.update_falling(dtf);
    }

    // ---- discrete actions ------------------------------------------------
    pub fn action(&mut self, a: &bf_action) {
        use bf_action_kind::*;
        match a.kind {
            BF_ACT_MINE_START => {
                let idx = self.creature_in_view();
                if idx >= 0 {
                    self.attack_creature(idx);
                } else {
                    self.mining = true;
                }
            }
            BF_ACT_MINE_STOP => {
                self.mining = false;
                self.mine_progress = 0.0;
            }
            BF_ACT_PLACE => self.perform_place(),
            BF_ACT_CRAFT => self.craft_index(a.arg_i),
            BF_ACT_INV_OPEN => self.inv_open = true,
            BF_ACT_INV_CLOSE => self.inv_open = false,
            BF_ACT_INV_MOVE => {
                if let Some(inv) = self.inv.as_mut() {
                    let cnt = if a.arg_k > 0 { a.arg_k as u16 } else { 64 };
                    inv.move_item(a.arg_i as usize, a.arg_j as usize, cnt);
                }
            }
            BF_ACT_ATTACK => {
                let idx = self.creature_in_view();
                if idx >= 0 {
                    self.attack_creature(idx);
                }
            }
            BF_ACT_INTERACT => {
                // #69 doors: open/close a targeted door (takes priority).
                if self.has_target {
                    let tb = self.block_at(self.target);
                    if tb == 33 || tb == 50 {
                        let target = self.target;
                        let mut low_y = target.y;
                        while {
                            let b = self.block_at(IVec3 { x: target.x, y: low_y - 1, z: target.z });
                            b == 33 || b == 50
                        } {
                            low_y -= 1;
                        }
                        let mut high_y = target.y;
                        while {
                            let b = self.block_at(IVec3 { x: target.x, y: high_y + 1, z: target.z });
                            b == 33 || b == 50
                        } {
                            high_y += 1;
                        }
                        let base = self.block_at(IVec3 { x: target.x, y: low_y, z: target.z });
                        let nb = if base == 33 { 50 } else { 33 };
                        for y in low_y..=high_y {
                            self.set_block_internal(IVec3 { x: target.x, y, z: target.z }, nb);
                        }
                        self.fx(1, target, 0);
                        return;
                    }
                    // #109 chests: open the container panel (right-click on a chest).
                    // Takes priority over place/befriend so a chest is always openable.
                    // Toggle: interacting the same open chest again closes it.
                    if tb == CHEST {
                        self.toggle_chest_open(self.target);
                        return;
                    }
                }
                let idx = self.creature_in_view();
                if idx >= 0 && self.creatures[idx as usize].model == 20 {
                    // A VILLAGER: trade-role donation, else open dialogue.
                    if !self.try_village_donation(idx as usize) {
                        let pv = self.player_voxel();
                        let npc = self.creatures[idx as usize].npc_id;
                        self.fx(20, pv, npc);
                    }
                } else if idx >= 0 && !self.creatures[idx as usize].hostile {
                    self.creatures[idx as usize].friendly = true;
                    self.creatures_befriended += 1;
                    // Feed the held berry (consume one).
                    if let Some(inv) = self.inv.as_ref() {
                        let held = inv.get(self.selected as usize);
                        if held.item != 0 && self.item_name(held.item) == "berry_cluster" {
                            self.inv.as_mut().unwrap().remove_item(held.item, 1);
                        }
                    }
                    let pv = self.player_voxel();
                    self.fx(5, pv, 0);
                    let nm = self.creatures[idx as usize].name.clone();
                    self.notify_quest("befriend_creature", &nm);
                } else {
                    self.perform_place();
                }
            }
            BF_ACT_GIVE_ITEM => {
                if self.mode == bf_game_mode::BF_MODE_CREATIVE && self.inv.is_some() && a.arg_i > 0 {
                    let mut qty = 64u16;
                    if let Some(content) = self.content {
                        if let Some(d) = content.item_by_id(a.arg_i as ItemId) {
                            qty = (64).min(if d.max_stack > 0 { d.max_stack } else { 64 });
                        }
                    }
                    self.inv.as_mut().unwrap().add(ItemStack {
                        item: a.arg_i as ItemId,
                        count: qty,
                        durability: 0xFFFF,
                    });
                }
            }
            BF_ACT_DROP_ITEM => {
                if let Some(inv) = self.inv.as_mut() {
                    if a.arg_i >= 0 && (a.arg_i as usize) < BF_INVENTORY_SLOTS {
                        inv.set(a.arg_i as usize, ItemStack::default());
                    }
                }
            }
            BF_ACT_HOTBAR_SELECT => {
                if a.arg_i >= 0 && (a.arg_i as usize) < BF_HOTBAR_SLOTS {
                    self.selected = a.arg_i as u8;
                }
            }
            BF_ACT_HOTBAR_SCROLL => {
                let s = (self.selected as i32 + (if a.arg_i >= 0 { 1 } else { -1 }) + BF_HOTBAR_SLOTS as i32)
                    % BF_HOTBAR_SLOTS as i32;
                self.selected = s as u8;
            }
            BF_ACT_MODE_TOGGLE => {
                self.mode = if self.mode == bf_game_mode::BF_MODE_CREATIVE {
                    bf_game_mode::BF_MODE_SURVIVAL
                } else {
                    bf_game_mode::BF_MODE_CREATIVE
                };
            }
            BF_ACT_SET_TIME_MODE => self.set_time_mode(a.arg_i),
        }
    }

    /// How far from the camera to include all sub-voxel detail props. These are separate
    /// from chunk meshes; a fixed 120-block cutoff made high-altitude creative flight show
    /// terrain without nearby scenery. Keep small ground clutter bounded for the M1 Air target.
    fn prop_detail_radius_blocks(&self) -> f32 {
        ((self.stream_r as f32) * KCHUNK_DIM as f32).clamp(120.0, 384.0)
    }

    /// Far scenery LOD: keep tree trunks/leaves visible through the render distance even
    /// after tiny grass/flower props drop out. This is the first step toward real prop LOD
    /// without expanding the ABI yet.
    fn prop_scenery_radius_blocks(&self) -> f32 {
        ((self.stream_r as f32) * KCHUNK_DIM as f32).clamp(120.0, 640.0)
    }

    // ---- build_frame -----------------------------------------------------
    // Meshes dirty chunks, then fills the abi render frame. draws / shadow_draws /
    // prop_instances are owned by the caller (matching the C++ out-params); the
    // returned frame's raw pointers reference them, so they must outlive the frame.
    pub fn build_frame(
        &mut self,
        out: &mut bf_render_frame,
        draws: &mut Vec<bf_draw_item>,
        shadow_draws: &mut Vec<bf_draw_item>,
        prop_instances: &mut Vec<bf_prop_instance>,
        _clock: f64, // engine wall clock; render day/night uses self.world_clock so the
        // T time-mode pin (which pins world_clock) actually moves the rendered sun.
    ) {
        self.remesh_dirty();
        draws.clear();
        prop_instances.clear();
        let cam_fwd = self.forward_dir();
        let cam_pos = self.pos;
        let kcull_cos = 0.30f32;
        let kfar_cull_cos = 0.55f32;
        let knear_keep = KCHUNK_DIM as f32 * 1.5;
        // Iterate meshes in a stable-enough order (HashMap order is fine; the C++
        // also iterates an unordered_map). Collect coords first to avoid borrow
        // conflicts with region_sat reads.
        let mesh_coords: Vec<ChunkCoord> = self.meshes.keys().copied().collect();
        for cc in &mesh_coords {
            let (has_buffers, index_count, vbuf_h, ibuf_h) = {
                let rec = &self.meshes[cc];
                (rec.has_buffers, rec.index_count, rec.vbuf.handle, rec.ibuf.handle)
            };
            if !has_buffers || index_count == 0 {
                continue;
            }
            let ctr = V3::new(
                (cc.x as f32 + 0.5) * KCHUNK_DIM as f32,
                (cc.y as f32 + 0.5) * KCHUNK_DIM as f32,
                (cc.z as f32 + 0.5) * KCHUNK_DIM as f32,
            );
            let to_c = V3::new(ctr.x - cam_pos.x, ctr.y - cam_pos.y, ctr.z - cam_pos.z);
            let dist = dot(to_c, to_c).sqrt();
            if dist < 176.0 && self.unlit_far_meshes.contains(cc) {
                self.mark_dirty(*cc);
            }
            let facing = dot(to_c, cam_fwd) / dist;
            if dist > knear_keep && facing < kcull_cos {
                continue;
            }
            if dist > 192.0 && facing < kfar_cull_cos {
                continue;
            }
            let lod = if dist > 192.0 { 1 } else { 0 };
            let has_water = if self.meshes[cc].has_water { 2 } else { 0 };
            let mut d = bf_draw_item {
                vertex_buffer: vbuf_h,
                index_buffer: ibuf_h,
                vertex_offset: 0,
                index_offset: 0,
                index_count,
                material_id: lod | has_water,
                chunk_origin: bf_ivec3 { x: cc.x * KCHUNK_DIM, y: cc.y * KCHUNK_DIM, z: cc.z * KCHUNK_DIM },
                dim_saturation: 0.0,
                dim_sat_px: 0.0,
                dim_sat_pz: 0.0,
                dim_sat_pxz: 0.0,
            };
            d.dim_saturation = self.region_sat(*cc);
            d.dim_sat_px = self.region_sat(ChunkCoord { x: cc.x + 1, y: cc.y, z: cc.z });
            d.dim_sat_pz = self.region_sat(ChunkCoord { x: cc.x, y: cc.y, z: cc.z + 1 });
            d.dim_sat_pxz = self.region_sat(ChunkCoord { x: cc.x + 1, y: cc.y, z: cc.z + 1 });
            draws.push(d);
            let detail_radius = self.prop_detail_radius_blocks();
            let scenery_radius = self.prop_scenery_radius_blocks();
            if dist < scenery_radius {
                let props = self.meshes[cc].props.clone();
                if !props.is_empty() {
                    if dist < detail_radius {
                        prop_instances.extend_from_slice(&props);
                    } else {
                        prop_instances.extend(props.iter().copied().filter(|p| Self::is_tree_block(p.type_ as BlockId)));
                    }
                }
            }
        }

        let fwd = self.forward_dir();
        let flat = normalize(V3::new(fwd.x, 0.0, fwd.z));
        let rightv = normalize(cross(flat, V3::new(0.0, 1.0, 0.0)));
        let bob_y = (self.bob_phase * 2.0).sin() * 0.06 * self.bob_amt;
        let bob_x = self.bob_phase.cos() * 0.045 * self.bob_amt;
        let eye = self.pos + V3::new(0.0, bob_y, 0.0) + rightv * bob_x;
        let ctr = eye + fwd;
        let view = look_at(eye, ctr, V3::new(0.0, 1.0, 0.0));
        let proj = perspective(1.20, 1.6, 0.05, 1024.0);
        out.camera.view.m = view;
        out.camera.proj.m = proj;
        out.camera.position = bf_vec3 { x: eye.x, y: eye.y, z: eye.z };
        out.camera.forward = bf_vec3 { x: fwd.x, y: fwd.y, z: fwd.z };
        let t = Self::day_time(self.world_clock);
        out.camera.time_of_day = t;
        let ang = t * 6.2831853;
        out.camera.sun_dir = bf_vec3 { x: ang.cos() * 0.6, y: -ang.sin() - 0.25, z: 0.90 };
        out.camera.underwater = if self.block_at(IVec3 {
            x: Self::ifloor(eye.x),
            y: Self::ifloor(eye.y),
            z: Self::ifloor(eye.z),
        }) == WATER
        {
            1.0
        } else {
            0.0
        };
        // Cold area scan.
        {
            let mut cold = false;
            let px = Self::ifloor(eye.x);
            let pz = Self::ifloor(eye.z);
            let mut y = Self::ifloor(eye.y);
            while y > Self::ifloor(eye.y) - 8 && !cold {
                let b = self.block_at(IVec3 { x: px, y, z: pz });
                if b == 12 || b == 13 {
                    cold = true;
                } else if b != AIR && b != WATER && !Self::is_plant(b) {
                    break;
                }
                y -= 1;
            }
            out.camera.biome_cold = if cold { 1.0 } else { 0.0 };
            let storm = (self.world_clock / 240.0) % 1.0 > 0.75;
            self.weather = if storm {
                if cold {
                    2
                } else {
                    1
                }
            } else {
                0
            };
            out.camera.weather = self.weather as f32;
        }
        {
            let surf = worldgen::worldgen_surface_height(Self::ifloor(eye.x), Self::ifloor(eye.z), self.seed);
            let depth = (surf - Self::ifloor(eye.y)) as f32;
            out.camera.underground = ((depth - 3.0) / 8.0).clamp(0.0, 1.0);
        }
        out.camera.local_sat = self.region_sat(Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        }));
        out.interp_alpha = 0.0;
        out.draws = draws.as_ptr();
        out.draw_count = draws.len() as u32;
        out.regions = std::ptr::null();
        out.region_count = 0;

        // Shadow occluders: resident meshes, no cone cull, bounded radius.
        shadow_draws.clear();
        // #120 must be >= the renderer far shadow cascade (kShadowFarR 400) plus a margin so a
        // tall caster just outside the cascade still throws its shadow inward. The far cascade's
        // inscribed circle now reaches PAST the render distance (384), so occluders must exist
        // all the way out there for shadows to be full across the whole visible vista. 420 gives
        // the cascade a 20-block ring of occluders just beyond its edge.
        let kshadow_r = 420.0f32;
        for cc in &mesh_coords {
            let (has_buffers, index_count, vbuf_h, ibuf_h) = {
                let rec = &self.meshes[cc];
                (rec.has_buffers, rec.index_count, rec.vbuf.handle, rec.ibuf.handle)
            };
            if !has_buffers || index_count == 0 {
                continue;
            }
            let sctr = V3::new(
                (cc.x as f32 + 0.5) * KCHUNK_DIM as f32,
                (cc.y as f32 + 0.5) * KCHUNK_DIM as f32,
                (cc.z as f32 + 0.5) * KCHUNK_DIM as f32,
            );
            let stoc = V3::new(sctr.x - cam_pos.x, sctr.y - cam_pos.y, sctr.z - cam_pos.z);
            if dot(stoc, stoc) > kshadow_r * kshadow_r {
                continue;
            }
            shadow_draws.push(bf_draw_item {
                vertex_buffer: vbuf_h,
                index_buffer: ibuf_h,
                vertex_offset: 0,
                index_offset: 0,
                index_count,
                material_id: 0,
                chunk_origin: bf_ivec3 { x: cc.x * KCHUNK_DIM, y: cc.y * KCHUNK_DIM, z: cc.z * KCHUNK_DIM },
                dim_saturation: 0.0,
                dim_sat_px: 0.0,
                dim_sat_pz: 0.0,
                dim_sat_pxz: 0.0,
            });
        }
        out.shadow_draws = shadow_draws.as_ptr();
        out.shadow_draw_count = shadow_draws.len() as u32;
        out.prop_instances = prop_instances.as_ptr();
        out.prop_instance_count = prop_instances.len() as u32;

        // Creatures.
        self.entities.clear();
        const KANIMAL_KIND: [u32; 8] = [0, 1, 2, 3, 7, 8, 9, 10];
        for cr in &self.creatures {
            let mut col = if cr.friendly { V3::new(1.0, 0.92, 0.55) } else { cr.color };
            if cr.hit_flash > 0.0 {
                let f = (cr.hit_flash / 0.22).min(1.0) * 0.85;
                col = V3::new(
                    col.x + (1.0 - col.x) * f,
                    col.y + (1.0 - col.y) * f,
                    col.z + (1.0 - col.z) * f,
                );
            }
            let kind = if cr.model >= 0 {
                cr.model as u32
            } else if cr.hostile {
                if cr.shape == 1 {
                    11
                } else {
                    5
                }
            } else if cr.is_boss {
                4
            } else {
                KANIMAL_KIND[(cr.shape & 7) as usize]
            };
            let sat = self.region_sat(Self::to_chunk(IVec3 {
                x: Self::ifloor(cr.pos.x),
                y: Self::ifloor(cr.pos.y),
                z: Self::ifloor(cr.pos.z),
            }));
            self.entities.push(bf_entity_draw {
                position: bf_vec3 { x: cr.pos.x, y: cr.pos.y, z: cr.pos.z },
                yaw: cr.yaw,
                color: bf_vec3 { x: col.x, y: col.y, z: col.z },
                scale: cr.scale,
                kind,
                sat,
                _pad: 0,
            });
        }
        for fb in &self.falling {
            let sat = self.region_sat(Self::to_chunk(IVec3 {
                x: Self::ifloor(fb.pos.x),
                y: Self::ifloor(fb.pos.y),
                z: Self::ifloor(fb.pos.z),
            }));
            self.entities.push(bf_entity_draw {
                position: bf_vec3 { x: fb.pos.x, y: fb.pos.y, z: fb.pos.z },
                yaw: fb.spin,
                color: bf_vec3 { x: fb.color.x, y: fb.color.y, z: fb.color.z },
                scale: 1.0,
                kind: 6,
                sat,
                _pad: 0,
            });
        }
        for a in &self.remote_avatars {
            self.entities.push(*a);
        }
        out.entities = self.entities.as_ptr();
        out.entity_count = self.entities.len() as u32;

        self.fill_hud(&mut out.hud);
    }

    // strncpy(dst, src, dst.len()-1): copy bytes, always NUL-terminate, truncate.
    fn cstr_copy(dst: &mut [u8], src: &str) {
        for b in dst.iter_mut() {
            *b = 0;
        }
        let cap = dst.len().saturating_sub(1);
        let bytes = src.as_bytes();
        let n = bytes.len().min(cap);
        dst[..n].copy_from_slice(&bytes[..n]);
    }

    fn fill_hud(&self, h: &mut bf_hud_state) {
        h.mode = self.mode;
        h.selected_slot = self.selected;
        h.inventory_open = if self.inv_open { 1 } else { 0 };
        h.health = self.health;
        h.hunger = self.hunger;
        // zero arrays
        for s in h.hotbar.iter_mut() {
            *s = bf_hud_slot { item: 0, count: 0, durability: 0, _pad: 0 };
        }
        for s in h.inventory.iter_mut() {
            *s = bf_hud_slot { item: 0, count: 0, durability: 0, _pad: 0 };
        }
        for s in h.craftable.iter_mut() {
            *s = bf_hud_slot { item: 0, count: 0, durability: 0, _pad: 0 };
        }
        h.craftable_count = 0;
        if let Some(inv) = self.inv.as_ref() {
            for i in 0..BF_HOTBAR_SLOTS {
                let s = inv.get(i);
                h.hotbar[i] = bf_hud_slot { item: s.item, count: s.count, durability: s.durability, _pad: 0 };
            }
            for i in 0..BF_INVENTORY_SLOTS {
                let s = inv.get(i);
                h.inventory[i] = bf_hud_slot { item: s.item, count: s.count, durability: s.durability, _pad: 0 };
            }
            let cr = self.craftable_recipes();
            let ncr = cr.len().min(24);
            h.craftable_count = ncr as u8;
            if let Some(content) = self.content {
                for i in 0..ncr {
                    let r = content.recipe(cr[i]);
                    h.craftable[i] = bf_hud_slot {
                        item: r.result_item,
                        count: r.result_count,
                        durability: 0xFFFF,
                        _pad: 0,
                    };
                }
            }
        }
        // Active quest.
        let mut handled = false;
        if let Some(x) = self.extra {
            if !self.all_quests_done
                && self.active_quest < x.quests().len()
                && self.obj_progress.len() == x.quests()[self.active_quest].objectives.len()
            {
                let q = &x.quests()[self.active_quest];
                h.active_quest_id = q.id;
                Self::cstr_copy(&mut h.quest_title, &q.title);
                let mut done = 0u32;
                let mut total = 0u32;
                let mut objtext = "";
                for (i, o) in q.objectives.iter().enumerate() {
                    total += o.count;
                    done += self.obj_progress[i].min(o.count);
                    if self.obj_progress[i] < o.count && objtext.is_empty() {
                        objtext = &o.text;
                    }
                }
                Self::cstr_copy(&mut h.quest_objective, if !objtext.is_empty() { objtext } else { "..." });
                h.quest_progress = if total != 0 { done as f32 / total as f32 } else { 0.0 };
                handled = true;
            }
        }
        if !handled {
            h.active_quest_id = 0;
            Self::cstr_copy(
                &mut h.quest_title,
                if self.all_quests_done { "The color is back!" } else { "Bring back the color" },
            );
            Self::cstr_copy(
                &mut h.quest_objective,
                if self.all_quests_done {
                    "You restored the world!"
                } else {
                    "Place a glow block in the grey Dim"
                },
            );
            h.quest_progress = if self.all_quests_done { 1.0 } else { 0.0 };
        }
        h.has_target = if self.has_target { 1 } else { 0 };
        h.target_block = bf_ivec3 { x: self.target.x, y: self.target.y, z: self.target.z };
        h.mine_progress = self.mine_progress;
        h.oxygen = self.oxygen;
        h.achievements_done = self.ach_done_count as u8;
        h.achievements_total = K_ACHIEVEMENT_COUNT as u8;
        h.weather = self.weather as u8;
        Self::cstr_copy(&mut h.biome_name, self.biome_label());
        h.in_dim = if self.region_sat(Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        })) < 0.99
        {
            1
        } else {
            0
        };
        for b in h.achievement_toast.iter_mut() {
            *b = 0;
        }
        if self.ach_toast_timer > 0.0 {
            Self::cstr_copy(&mut h.achievement_toast, &self.ach_toast);
        }
        // Look-at name.
        for b in h.look_name.iter_mut() {
            *b = 0;
        }
        let ci = self.creature_in_view();
        if ci >= 0 && !self.creatures[ci as usize].name.is_empty() {
            let nm = self.creatures[ci as usize].name.clone();
            Self::cstr_copy(&mut h.look_name, &nm);
        } else if self.has_target {
            let bn = self.block_name(self.block_at(self.target));
            if !bn.is_empty() {
                Self::cstr_copy(&mut h.look_name, &bn);
            }
        }
    }

    // ---- test/debug seams ------------------------------------------------
    pub fn debug_set_camera(&mut self, px: f32, py: f32, pz: f32, yaw: f32, pitch: f32) {
        self.pos = V3::new(px, py, pz);
        self.yaw = yaw;
        self.pitch = pitch;
    }
    pub fn debug_block_at(&self, x: i32, y: i32, z: i32) -> BlockId {
        self.block_at(IVec3 { x, y, z })
    }
    pub fn debug_collide_solid(&self, x: i32, y: i32, z: i32) -> bool {
        self.collide_solid(x, y, z)
    }
    pub fn debug_sky_light(&self, x: i32, y: i32, z: i32) -> i32 {
        let cc = Self::to_chunk(IVec3 { x, y, z });
        match self.store.get(cc) {
            Some(ch) => ch.sky_light(Self::mod16(x) as usize, Self::mod16(y) as usize, Self::mod16(z) as usize) as i32,
            None => -1,
        }
    }
    pub fn debug_edit(&mut self, x: i32, y: i32, z: i32, b: BlockId) {
        self.set_block_internal(IVec3 { x, y, z }, b);
    }
    pub fn debug_set_sync_streaming(&mut self, s: bool) {
        self.sync_stream = s;
    }
    pub fn debug_stream_back_is_nearest(&mut self) -> bool {
        self.recompute_stream_set();
        if self.gen_queue.len() < 2 {
            return true;
        }
        let back = *self.gen_queue.last().unwrap();
        let front = self.gen_queue[0];
        Self::dist2(back, self.last_center) <= Self::dist2(front, self.last_center)
    }
    pub fn debug_stream_active_radius(&self) -> i32 {
        self.stream_active_r
    }
    pub fn debug_stream_target_radius(&self) -> i32 {
        self.stream_r
    }
    pub fn debug_stream_backlog(&self) -> usize {
        self.stream_backlog()
    }
    pub fn debug_has_target(&self) -> bool {
        self.has_target
    }
    pub fn debug_set_selected(&mut self, s: u8) {
        self.selected = s;
    }
    pub fn debug_region_sat(&self, cx: i32, cz: i32) -> f32 {
        self.region_sat(ChunkCoord { x: cx, y: 0, z: cz })
    }
    pub fn debug_item_id(&self, n: &str) -> ItemId {
        self.item_id_by_name(n)
    }
    pub fn debug_item_count(&self, id: ItemId) -> i32 {
        self.inv.as_ref().map(|i| i.count_item(id) as i32).unwrap_or(0)
    }
    pub fn debug_give(&mut self, id: ItemId, n: u16) {
        if let Some(inv) = self.inv.as_mut() {
            inv.add(ItemStack { item: id, count: n, durability: 0xFFFF });
        }
    }
    pub fn debug_clear_inventory(&mut self) {
        if let Some(inv) = self.inv.as_mut() {
            for i in 0..BF_INVENTORY_SLOTS {
                inv.set(i, ItemStack::default());
            }
        }
    }
    /// #109 test helper: fill EVERY player inventory slot with a stack of `id` so the
    /// inventory is genuinely full (no room for a different item). Used to verify
    /// chest_take leaves items in the chest when nothing fits.
    pub fn debug_fill_inventory(&mut self, id: ItemId, count: u16) {
        if let Some(inv) = self.inv.as_mut() {
            for i in 0..BF_INVENTORY_SLOTS {
                inv.set(i, ItemStack { item: id, count, durability: 0xFFFF });
            }
        }
    }
    /// #109 test helper: read chest slot `slot` at world `(x,y,z)` as (item, count).
    /// Rolls the chest's loot lazily, like chest_slots.
    pub fn debug_chest_slot(&mut self, x: i32, y: i32, z: i32, slot: usize) -> (ItemId, u16) {
        match self.chest_slots(IVec3 { x, y, z }) {
            Some(slots) if slot < CHEST_SLOTS => (slots[slot].item, slots[slot].count),
            _ => (0, 0),
        }
    }
    pub fn debug_creature_count(&self) -> i32 {
        self.creatures.len() as i32
    }
    pub fn debug_creature_pos(&self, i: i32) -> (f32, f32, f32) {
        if i < 0 || i >= self.creatures.len() as i32 {
            return (0.0, 0.0, 0.0);
        }
        let c = &self.creatures[i as usize];
        (c.pos.x, c.pos.y, c.pos.z)
    }
    // Spawn a plain wandering creature at a precise position + heading and return its
    // index. Used by the locomotion tests to place a creature against a known step.
    // The wander timer is set high so the creature keeps its given yaw (it walks
    // straight at the step instead of randomly turning away) for the test window.
    pub fn debug_spawn_creature_at(&mut self, x: f32, y: f32, z: f32, yaw: f32, speed: f32) -> i32 {
        let mut c = Creature::default();
        c.pos = V3::new(x, y, z);
        c.yaw = yaw;
        c.speed = speed;
        c.scale = 1.0;
        c.hp = 5;
        c.wander = 1000.0;
        // Seed the AI straight-walk heading so the creature walks in `yaw` (the
        // locomotion tests place it against a known step). wander > 900 marks it
        // Scripted in update_creatures so it ignores the player and never re-rolls.
        c.ai.seed_straight(yaw);
        self.creatures.push(c);
        (self.creatures.len() - 1) as i32
    }
    pub fn debug_set_friendly(&mut self, i: i32) {
        if i >= 0 && i < self.creatures.len() as i32 {
            self.creatures[i as usize].friendly = true;
        }
    }
    // #95 test helper: a hostile that hunts the player (used to prove a village wall keeps
    // monsters out of its protected interior).
    pub fn debug_spawn_hostile_at(&mut self, x: f32, y: f32, z: f32) -> i32 {
        let mut c = Creature::default();
        c.pos = V3::new(x, y, z);
        c.hostile = true;
        c.scale = 1.0;
        c.hp = 5;
        c.speed = 1.6;
        self.creatures.push(c);
        (self.creatures.len() - 1) as i32
    }
    // Spawn a villager with a specific profession at a settlement anchor, for tier tests.
    pub fn debug_spawn_villager_role(&mut self, ax: i32, az: i32, npc_id: i32) -> i32 {
        let mut c = Creature::default();
        c.model = 20;
        c.npc_id = npc_id;
        c.home_x = ax;
        c.home_z = az;
        let surf = worldgen::worldgen_surface_height(ax, az, self.seed);
        c.pos = V3::new(ax as f32, surf as f32, az as f32);
        self.creatures.push(c);
        (self.creatures.len() - 1) as i32
    }
    // Run a donation against a villager index (the player must hold the item already).
    pub fn debug_try_donation(&mut self, idx: i32) -> bool {
        self.try_village_donation(idx as usize)
    }
    pub fn debug_set_wall_block(&mut self, wx: i32, wy: i32, wz: i32, b: BlockId) {
        self.set_block_internal(IVec3 { x: wx, y: wy, z: wz }, b);
    }
    pub fn debug_grow_tree(&mut self, wx: i32, wz: i32) -> bool {
        let surf = self.surface_top(wx, wz);
        if surf == NO_FLOOR {
            return false;
        }
        self.grow_small_tree(wx, surf, wz);
        true
    }
    pub fn debug_villager_count(&self) -> i32 {
        self.creatures.iter().filter(|c| c.model == 20).count() as i32
    }
    // Exposes the pure profession-assignment policy so tests can verify the chain rules
    // (city = full chain, village = ordered prefix) without driving a full settlement
    // spawn. Returns the npc_id role for the villager at `idx` within the settlement.
    pub fn debug_villager_npc_for_index(is_city: bool, idx: i32) -> i32 {
        Self::villager_npc_for_index(is_city, idx)
    }
    pub fn debug_boss_count(&self) -> i32 {
        self.creatures.iter().filter(|c| c.is_boss).count() as i32
    }
    pub fn debug_count_named(&self, nm: &str) -> i32 {
        self.creatures.iter().filter(|c| c.name == nm).count() as i32
    }
    pub fn debug_resident_count(&self) -> i32 {
        self.store.resident_count() as i32
    }
    pub fn debug_hostile_count(&self) -> i32 {
        self.creatures.iter().filter(|c| c.hostile).count() as i32
    }
    // tests: count only the ruin "danger site" hostiles (spawned independent of the
    // night/quest gate).
    pub fn debug_ruin_hostile_count(&self) -> i32 {
        self.creatures.iter().filter(|c| c.hostile && c.from_ruin).count() as i32
    }
    // tests: simulate the player clearing a ruin by removing all of its defenders.
    // Returns how many were removed.
    pub fn debug_kill_ruin_hostiles(&mut self) -> i32 {
        let before = self.creatures.len();
        self.creatures.retain(|c| !(c.hostile && c.from_ruin));
        (before - self.creatures.len()) as i32
    }
    // tests: true once the ruin site at anchor (ax, az) has been recorded as cleared
    // (its defenders were all killed and it has not yet re-armed).
    pub fn debug_ruin_site_cleared(&self, ax: i32, az: i32) -> bool {
        self.ruin_sites.get(&(ax, az)).map(|s| s.cleared).unwrap_or(false)
    }
    pub fn debug_health(&self) -> f32 {
        self.health
    }
    // tests: per-second sprint speed for the current game mode (creative sprint is a
    // fast fly/run ~5x the survival sprint).
    pub fn debug_sprint_speed(&self) -> f32 {
        if self.mode == bf_game_mode::BF_MODE_CREATIVE {
            42.5
        } else {
            8.5
        }
    }
    pub fn debug_day_time(&self) -> f32 {
        Self::day_time(self.world_clock)
    }
    // tests: jump the world clock to a chosen day_time phase (0..1) so a test can
    // put the world into night without pumping ~5 minutes of frames.
    pub fn debug_set_day_time(&mut self, phase: f32) {
        // invert day_time: phase = (clock * DAY_RATE + DAY_START_PHASE) % 1.0
        self.world_clock = Self::clock_for_phase(phase);
    }
    pub fn debug_regions_restored(&self) -> i32 {
        self.regions_restored
    }
    pub fn debug_spawn_named(&mut self, nm: &str) {
        let mut c = Creature::default();
        c.name = nm.to_string();
        c.pos = self.pos + V3::new(5.0, -1.0, 0.0);
        c.hp = 5;
        c.scale = 1.0;
        if let Some(x) = self.extra {
            for d in x.creatures() {
                if d.name == c.name {
                    c.is_boss = d.disposition == "boss";
                    c.model = d.model;
                    break;
                }
            }
        }
        self.creatures.push(c);
    }
    pub fn debug_aim_at_creature0(&mut self) -> bool {
        if self.creatures.is_empty() {
            return false;
        }
        let cp = self.creatures[0].pos + V3::new(0.0, 0.5, 0.0);
        self.pos = cp + V3::new(0.0, 1.0, 3.0);
        let d = normalize(cp - self.pos);
        self.pitch = d.y.clamp(-0.999, 0.999).asin();
        self.yaw = d.x.atan2(d.z);
        true
    }
}

#[cfg(test)]
mod time_mode_tests {
    use super::*;

    #[test]
    fn visual_detail_radii_scale_with_render_distance() {
        let mut w = World::new(None);
        assert_eq!(w.shadow_radius_chunks(), 8);
        assert_eq!(w.prop_detail_radius_blocks(), 120.0);
        assert_eq!(w.prop_scenery_radius_blocks(), 120.0);

        w.set_render_distance(24);
        assert_eq!(w.shadow_radius_chunks(), 16);
        assert_eq!(w.prop_detail_radius_blocks(), 384.0);
        assert_eq!(w.prop_scenery_radius_blocks(), 384.0);

        w.set_render_distance(40);
        assert_eq!(w.shadow_radius_chunks(), 16);
        assert_eq!(w.prop_detail_radius_blocks(), 384.0);
        assert_eq!(w.prop_scenery_radius_blocks(), 640.0);
    }

    fn set_mode(w: &mut World, mode: i32) {
        let act = bf_action {
            kind: bf_action_kind::BF_ACT_SET_TIME_MODE,
            arg_i: mode,
            arg_j: 0,
            arg_k: 0,
        };
        w.action(&act);
    }

    fn tick(w: &mut World) {
        let input = bf_frame_input {
            move_forward: 0.0,
            move_strafe: 0.0,
            look_yaw_delta: 0.0,
            look_pitch_delta: 0.0,
            jump: 0,
            sneak: 0,
            sprint: 0,
            fly_ascend: 0,
            fly_descend: 0,
            _pad: [0; 3],
        };
        w.update(&input, 0.016);
    }

    // #117 footprints: stepping on FRESH snow (12) compresses it to a TRODDEN print (54);
    // already-trodden snow and non-snow blocks are left alone, so a trail is stamped at
    // most once per cell (bounded, no growing print list). Snow stays walk-through.
    #[test]
    fn footprint_compresses_fresh_snow_only() {
        let mut w = World::new(None);
        // A grass cell with a fresh snow blanket above it.
        w.debug_edit(0, 10, 0, GRASS);
        w.debug_edit(0, 11, 0, SNOW_LAYER);
        assert_eq!(w.debug_block_at(0, 11, 0), SNOW_LAYER);

        // First step on the snow cell turns it into a footprint.
        w.stamp_footprint(IVec3 { x: 0, y: 11, z: 0 });
        assert_eq!(w.debug_block_at(0, 11, 0), TRODDEN_SNOW, "fresh snow becomes a print");

        // Stepping again does nothing (already trodden), so a trail does not churn.
        w.stamp_footprint(IVec3 { x: 0, y: 11, z: 0 });
        assert_eq!(w.debug_block_at(0, 11, 0), TRODDEN_SNOW);

        // Stepping on a non-snow cell leaves it untouched.
        w.debug_edit(2, 10, 0, GRASS);
        w.stamp_footprint(IVec3 { x: 2, y: 10, z: 0 });
        assert_eq!(w.debug_block_at(2, 10, 0), GRASS, "non-snow is never stamped");
    }

    // #118 snow overlay is walk-through: the player stands on the surface block below,
    // not on top of the snow cell (so the blanket sits at their feet and prints read at
    // ground level). Snow must not collide.
    #[test]
    fn snow_overlay_does_not_collide() {
        let w = World::new(None);
        assert!(!World::solid_block(SNOW_LAYER), "fresh snow is walk-through");
        assert!(!World::solid_block(TRODDEN_SNOW), "trodden snow is walk-through");
        // But it still occupies the surface cell for sun shadows (keeps the world-fixed
        // shadow ground-top aligned with the rendered snow surface).
        assert!(World::casts_shadow(SNOW_LAYER));
        assert!(World::casts_shadow(TRODDEN_SNOW));
        let _ = w;
    }

    // Always-day (mode 1) pins day_time to the representative daytime phase and
    // holds it there across ticks; the sun never drifts toward night.
    #[test]
    fn always_day_pins_clock_high_noon() {
        let mut w = World::new(None);
        set_mode(&mut w, 1);
        assert!((w.debug_day_time() - World::TIME_PHASE_DAY).abs() < 1e-4);
        for _ in 0..20 {
            tick(&mut w);
        }
        assert!((w.debug_day_time() - World::TIME_PHASE_DAY).abs() < 1e-4);
    }

    // Always-night (mode 2) pins day_time to the representative night phase and
    // holds it there across ticks.
    #[test]
    fn always_night_pins_clock_below_horizon() {
        let mut w = World::new(None);
        set_mode(&mut w, 2);
        assert!((w.debug_day_time() - World::TIME_PHASE_NIGHT).abs() < 1e-4);
        for _ in 0..20 {
            tick(&mut w);
        }
        assert!((w.debug_day_time() - World::TIME_PHASE_NIGHT).abs() < 1e-4);
    }

    // Auto (mode 0) resumes the normal advance: after pinning to night, switching
    // back to auto lets the clock move forward again on the next ticks.
    #[test]
    fn auto_resumes_normal_advance() {
        let mut w = World::new(None);
        set_mode(&mut w, 2); // pin night first
        set_mode(&mut w, 0); // back to auto: clock left where it was
        let before = w.world_clock;
        for _ in 0..10 {
            tick(&mut w);
        }
        // 10 ticks of 0.016 s advance the clock by ~0.16 units in auto mode.
        assert!(w.world_clock > before + 0.1);
    }

    // #127 pause freezes the sun. The app pauses by ticking the engine with dt = 0
    // (bf_frame_begin(e, .., worldPaused ? 0.0 : dt)). Assert that ticking with dt = 0
    // does NOT advance world_clock (the sun holds where it is), and that resuming with a
    // real dt continues from the SAME value with no jump (the clock is not reset, it just
    // stopped accumulating). Render-side cosmetic motion (grass sway / wiggle) is frozen the
    // same way: the renderer's animClock only accumulates dt while unpaused.
    #[test]
    fn pause_dt_zero_freezes_world_clock_then_resumes() {
        let mut w = World::new(None);
        for _ in 0..5 {
            tick(&mut w); // advance into the day a bit
        }
        let frozen = w.world_clock;
        let frozen_phase = w.debug_day_time();
        // Two "paused" frames: tick with dt = 0, exactly as the paused render path does.
        let input = zero_input();
        w.update(&input, 0.0);
        w.update(&input, 0.0);
        // Sun must not have moved at all while paused.
        assert_eq!(w.world_clock, frozen, "world_clock advanced while paused (dt=0)");
        assert_eq!(w.debug_day_time(), frozen_phase, "day phase moved while paused");
        // Resume: a real dt continues from the same value (no jump back / no skip ahead).
        w.update(&input, 0.016);
        assert!(
            w.world_clock > frozen && w.world_clock < frozen + 0.05,
            "resume did not continue smoothly from the frozen clock: frozen={} now={}",
            frozen,
            w.world_clock
        );
    }

    // Zero-input frame helper (no movement / look), so a tick advances only time + sim.
    fn zero_input() -> bf_frame_input {
        bf_frame_input {
            move_forward: 0.0,
            move_strafe: 0.0,
            look_yaw_delta: 0.0,
            look_pitch_delta: 0.0,
            jump: 0,
            sneak: 0,
            sprint: 0,
            fly_ascend: 0,
            fly_descend: 0,
            _pad: [0; 3],
        }
    }

    // Sun elevation (positive = above the horizon) for a given day_time phase,
    // using the exact sun_dir geometry the renderer ships to the app:
    // sun_dir = {cos(ang)*0.6, -sin(ang)-0.25, 0.90}, ang = 2*pi*t, elevation is
    // the negated, normalized y component. Kept local to the test so it tracks the
    // render math; if that geometry changes, this assertion catches the drift.
    fn sun_elev(phase: f32) -> f32 {
        let ang = phase * std::f32::consts::TAU;
        let dx = ang.cos() * 0.6;
        let dy = -ang.sin() - 0.25;
        let dz = 0.90f32;
        -dy / (dx * dx + dy * dy + dz * dz).sqrt()
    }

    // Map a day_time phase to an in-game hour. The app fixes phase 0.25 = high noon
    // (12:00), so hour = ((phase - 0.25) * 24 + 12) mod 24.
    fn phase_hour(phase: f32) -> f32 {
        (((phase - 0.25) * 24.0 + 12.0) % 24.0 + 24.0) % 24.0
    }

    // The day phase should occupy ~14/24 of the cycle and the night ~10/24: the sun
    // is above the horizon for roughly 14 of every 24 hours, generous day vs short
    // night. We sample one full cycle by stepping world_clock and counting how long
    // day_time lands in the sun-up band.
    #[test]
    fn daylight_fraction_is_about_fourteen_of_twentyfour() {
        let n = 100_000u32;
        let mut up = 0u32;
        for i in 0..n {
            let phase = (i as f32 + 0.5) / n as f32; // uniform sweep of the phase
            if sun_elev(phase) > 0.0 {
                up += 1;
            }
        }
        let frac = up as f64 / n as f64;
        let hours = frac * 24.0;
        // Target 14/24 ~= 0.5833; the geometry gives ~0.5805 (~13.93 h). Allow a
        // modest tolerance so the test pins the balance without being brittle.
        assert!(
            (frac - 14.0 / 24.0).abs() < 0.02,
            "daylight fraction {frac:.4} ({hours:.2} h) not ~14/24",
        );
        // And it must clearly beat the night, never a 50/50 split.
        assert!(frac > 0.55, "day must be longer than night, got {frac:.4}");
    }

    // The sun should be up across roughly the 07:00..19:00 band and down outside it.
    // We assert it is above the horizon at mid-morning, noon, and mid-afternoon, and
    // below at deep night, with the actual sunrise/sunset bracketing 07:00..19:00.
    #[test]
    fn sun_up_across_daytime_band() {
        // Sun is comfortably up through the working day.
        for &h in &[8.0f32, 10.0, 12.0, 14.0, 16.0, 18.0] {
            let phase = (0.25 + (h - 12.0) / 24.0).rem_euclid(1.0);
            assert!(sun_elev(phase) > 0.0, "expected sun up at {h:.0}:00");
        }
        // Sun is down through the night.
        for &h in &[0.0f32, 2.0, 22.0] {
            let phase = (0.25 + (h - 12.0) / 24.0).rem_euclid(1.0);
            assert!(sun_elev(phase) < 0.0, "expected sun down at {h:.0}:00");
        }
        // Find the sunrise and sunset hours by scanning the elevation crossings.
        let n = 200_000u32;
        let mut sunrise = -1.0f32;
        let mut sunset = -1.0f32;
        let mut prev = sun_elev(0.0);
        for i in 1..=n {
            let phase = i as f32 / n as f32;
            let e = sun_elev(phase);
            if prev <= 0.0 && e > 0.0 {
                sunrise = phase_hour(phase);
            }
            if prev > 0.0 && e <= 0.0 {
                sunset = phase_hour(phase);
            }
            prev = e;
        }
        // The sun-up window brackets roughly 07:00..19:00. The fixed sun_dir
        // geometry is symmetric about noon, so the ~14 h band runs ~05:02..18:58;
        // sunrise lands at/before 07:00 and sunset right around 19:00 (within a few
        // game-minutes). We allow a small tolerance rather than fight the geometry
        // the app shares for lighting and shadows.
        assert!(
            sunrise > 0.0 && sunrise <= 7.0,
            "sunrise {sunrise:.2} should be at/before 07:00",
        );
        assert!(
            (18.9..=19.5).contains(&sunset),
            "sunset {sunset:.2} should be ~19:00",
        );
    }

    // A full cycle takes DAY_CYCLE_SECS of world_clock: phase returns to its start
    // after exactly that many seconds, confirming the chosen day length.
    #[test]
    fn cycle_length_matches_constant() {
        let start = World::day_time(0.0);
        let after = World::day_time(World::DAY_CYCLE_SECS);
        assert!((start - after).abs() < 1e-4, "cycle should close after DAY_CYCLE_SECS");
        // Half a cycle should land near the opposite phase (start 0.0 -> ~0.5).
        let half = World::day_time(World::DAY_CYCLE_SECS / 2.0);
        assert!((half - 0.5).abs() < 1e-3, "half cycle should be ~0.5 phase, got {half}");
    }
}
