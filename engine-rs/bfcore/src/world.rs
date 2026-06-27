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
use crate::content::{ContentExtra, ContentRegistry, CreatureDefX, QuestDefX};
use crate::inventory::Inventory;
use crate::lighting;
use crate::mesher::{self, GreedyMesher};
use crate::store::ChunkStore;
use crate::types::{BlockId, ChunkCoord, ItemId, ItemStack, IVec3, CHUNK_DIM, REGION_CHUNKS};
use crate::worldgen::{self, TerrainGen};

use std::collections::{HashMap, HashSet};

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
    name: String,
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
            name: String::new(),
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

// A block in mid air: undermined sand/gravel, or logs from a felled tree.
#[derive(Clone)]
struct FallingBlock {
    pos: V3,
    vel: V3,
    spin: f32,
    spin_rate: f32,
    block: BlockId,
    color: V3,
    as_item: bool,
    life: f32,
}

// A meshed chunk's GPU buffers + cached prop instances (#51).
#[derive(Clone)]
struct MeshRec {
    vbuf: bf_gpu_buffer,
    ibuf: bf_gpu_buffer,
    index_count: u32,
    has_buffers: bool,
    props: Vec<bf_prop_instance>,
}
impl Default for MeshRec {
    fn default() -> MeshRec {
        MeshRec {
            vbuf: bf_gpu_buffer { handle: 0, contents: std::ptr::null_mut(), bytes: 0 },
            ibuf: bf_gpu_buffer { handle: 0, contents: std::ptr::null_mut(), bytes: 0 },
            index_count: 0,
            has_buffers: false,
            props: Vec::new(),
        }
    }
}

// Region saturation key (region = 8x8 chunks horizontally).
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct RegionKey {
    x: i32,
    z: i32,
}

// An achievement row (mirrors World::Achievement).
struct Achievement {
    trig: &'static str,
    target: &'static str,
    count: i32,
    title: &'static str,
}

const K_ACHIEVEMENTS: &[Achievement] = &[
    Achievement { trig: "collect_item", target: "oak_log", count: 1, title: "Knock On Wood" },
    Achievement { trig: "mine_block", target: "oak_log", count: 3, title: "Timberrr!" },
    Achievement { trig: "collect_item", target: "dirt", count: 16, title: "Dirt Rich" },
    Achievement { trig: "mine_block", target: "stone", count: 1, title: "Between a Rock" },
    Achievement { trig: "craft_item", target: "", count: 1, title: "Arts & Crafts" },
    Achievement { trig: "mine_block", target: "coal_ore", count: 1, title: "Coal Digger" },
    Achievement { trig: "mine_block", target: "iron_ore", count: 1, title: "Pumping Iron" },
    Achievement { trig: "place_block", target: "", count: 10, title: "Block Party" },
    Achievement { trig: "collect_item", target: "mushroom", count: 1, title: "Fun Guy" },
    Achievement { trig: "place_block", target: "crafting_table", count: 1, title: "Table Manners" },
    Achievement { trig: "befriend_creature", target: "", count: 1, title: "Best Friends Furever" },
    Achievement { trig: "defeat_animal", target: "", count: 1, title: "Circle of Life" },
    Achievement { trig: "defeat_monster", target: "", count: 1, title: "Who's Scared Now?" },
    Achievement { trig: "mine_block", target: "iron_ore", count: 5, title: "Iron Will" },
    Achievement { trig: "collect_item", target: "color_dust", count: 4, title: "Tickled Pink" },
    Achievement { trig: "reach_location", target: "dim_barrens", count: 1, title: "Into the Grey" },
    Achievement { trig: "calm_boss", target: "", count: 1, title: "Big Softie" },
    Achievement { trig: "light_beacon", target: "", count: 1, title: "Guiding Light" },
    Achievement { trig: "restore_region", target: "dim_barrens", count: 1, title: "True Colors" },
    Achievement { trig: "befriend_creature", target: "platypus", count: 1, title: "Perry the Platypus" },
];
const K_ACHIEVEMENT_COUNT: usize = K_ACHIEVEMENTS.len();

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

    // ---- coordinate helpers (mirror the static helpers in world.hpp) -----
    fn ifloor(f: f32) -> i32 {
        f.floor() as i32
    }
    fn floordiv(a: i32, b: i32) -> i32 {
        let mut q = a / b;
        if (a % b) != 0 && ((a < 0) != (b < 0)) {
            q -= 1;
        }
        q
    }
    fn mod16(a: i32) -> i32 {
        let m = a % KCHUNK_DIM;
        if m < 0 {
            m + KCHUNK_DIM
        } else {
            m
        }
    }
    fn to_chunk(w: IVec3) -> ChunkCoord {
        ChunkCoord {
            x: Self::floordiv(w.x, KCHUNK_DIM),
            y: Self::floordiv(w.y, KCHUNK_DIM),
            z: Self::floordiv(w.z, KCHUNK_DIM),
        }
    }
    fn player_voxel(&self) -> IVec3 {
        IVec3 { x: Self::ifloor(self.pos.x), y: Self::ifloor(self.pos.y), z: Self::ifloor(self.pos.z) }
    }
    fn dist2(a: ChunkCoord, c: ChunkCoord) -> i64 {
        let dx = (a.x - c.x) as i64;
        let dz = (a.z - c.z) as i64;
        dx * dx + dz * dz
    }
    fn forward_dir(&self) -> V3 {
        normalize(V3::new(
            self.pitch.cos() * self.yaw.sin(),
            self.pitch.sin(),
            self.pitch.cos() * self.yaw.cos(),
        ))
    }
    fn rand01(&mut self) -> f32 {
        self.rng = self.rng.wrapping_mul(1664525).wrapping_add(1013904223);
        (self.rng >> 8) as f32 / 16777216.0
    }

    // ---- block reads/writes ---------------------------------------------
    fn block_at(&self, w: IVec3) -> BlockId {
        let cc = Self::to_chunk(w);
        match self.store.get(cc) {
            Some(ch) => ch.get(Self::mod16(w.x) as usize, Self::mod16(w.y) as usize, Self::mod16(w.z) as usize),
            None => AIR,
        }
    }
    fn set_block_internal(&mut self, w: IVec3, b: BlockId) {
        self.set_block_remote(w, b, false);
    }
    fn set_block_remote(&mut self, w: IVec3, b: BlockId, from_remote: bool) {
        let cc = Self::to_chunk(w);
        self.store.get_or_create(cc).set(
            Self::mod16(w.x) as usize,
            Self::mod16(w.y) as usize,
            Self::mod16(w.z) as usize,
            b,
        );
        self.dirty.insert(cc);
        self.edited.insert(cc);
        if !from_remote {
            if let Some(cb) = self.edit_cb.as_mut() {
                cb(w, b);
            }
        }
        let dirs = [
            IVec3 { x: 1, y: 0, z: 0 },
            IVec3 { x: -1, y: 0, z: 0 },
            IVec3 { x: 0, y: 1, z: 0 },
            IVec3 { x: 0, y: -1, z: 0 },
            IVec3 { x: 0, y: 0, z: 1 },
            IVec3 { x: 0, y: 0, z: -1 },
        ];
        for d in dirs {
            let nc = Self::to_chunk(IVec3 { x: w.x + d.x, y: w.y + d.y, z: w.z + d.z });
            if nc != cc && self.store.is_resident(nc) {
                self.dirty.insert(nc);
            }
        }
    }

    // ---- block classification (static, mirror world.hpp) -----------------
    fn is_plant(b: BlockId) -> bool {
        (36..=47).contains(&b) || b == 5 || b == 27 || b == 48
    }
    fn solid_block(b: BlockId) -> bool {
        b != AIR && b != WATER && b != 50 && !Self::is_plant(b)
    }
    fn is_gravity_block(b: BlockId) -> bool {
        b == 6 || b == 11
    }
    fn is_log(b: BlockId) -> bool {
        b == 21 || b == 22 || b == 49
    }
    fn is_leaf(b: BlockId) -> bool {
        b == 5 || b == 27
    }
    fn is_prop_block(id: BlockId) -> bool {
        (36..=47).contains(&id)
    }
    fn is_tree_block(id: BlockId) -> bool {
        id == 5 || id == 27 || id == 48 || id == 21 || id == 22 || id == 49
    }
    fn collide_solid(&self, x: i32, y: i32, z: i32) -> bool {
        let b = self.block_at(IVec3 { x, y, z });
        b != AIR && b != WATER && b != 50 && !Self::is_plant(b)
    }
    fn box_collides(&self, p: V3) -> bool {
        let hw = 0.3f32;
        let x0 = Self::ifloor(p.x - hw);
        let x1 = Self::ifloor(p.x + hw);
        let z0 = Self::ifloor(p.z - hw);
        let z1 = Self::ifloor(p.z + hw);
        let y0 = Self::ifloor(p.y - 1.6);
        let y1 = Self::ifloor(p.y + 0.2);
        for x in x0..=x1 {
            for y in y0..=y1 {
                for z in z0..=z1 {
                    if self.collide_solid(x, y, z) {
                        return true;
                    }
                }
            }
        }
        false
    }
    fn voxel_in_player_box(&self, v: IVec3) -> bool {
        let hw = 0.3f32;
        let x0 = Self::ifloor(self.pos.x - hw);
        let x1 = Self::ifloor(self.pos.x + hw);
        let z0 = Self::ifloor(self.pos.z - hw);
        let z1 = Self::ifloor(self.pos.z + hw);
        let y0 = Self::ifloor(self.pos.y - 1.6);
        let y1 = Self::ifloor(self.pos.y + 0.2);
        v.x >= x0 && v.x <= x1 && v.y >= y0 && v.y <= y1 && v.z >= z0 && v.z <= z1
    }
    // Standable surface (top of first solid block) scanning DOWN from yTop, or
    // NO_FLOOR if none found.
    fn floor_below(&self, x: i32, y_top: i32, z: i32) -> i32 {
        let mut y = y_top;
        while y > y_top - 80 {
            if self.collide_solid(x, y, z) {
                return y + 1;
            }
            y -= 1;
        }
        NO_FLOOR
    }

    // ---- region saturation ----------------------------------------------
    fn region_key(cc: ChunkCoord) -> RegionKey {
        RegionKey { x: Self::floordiv(cc.x, KREGION_CHUNKS), z: Self::floordiv(cc.z, KREGION_CHUNKS) }
    }
    fn region_sat(&self, cc: ChunkCoord) -> f32 {
        match self.region_sat.get(&Self::region_key(cc)) {
            Some(&v) => v,
            None => DIM_SAT,
        }
    }
    fn restore_region(&mut self, cc: ChunkCoord) {
        self.region_sat.insert(Self::region_key(cc), 1.0);
    }

    // Top standable block at a world column, GENERATING the column if not resident.
    fn surface_top(&self, wx: i32, wz: i32) -> i32 {
        let gen = match self.gen.as_ref() {
            Some(g) => g,
            None => return NO_FLOOR,
        };
        let lx = Self::mod16(wx);
        let lz = Self::mod16(wz);
        for cy in (CY_MIN..=CY_MAX).rev() {
            let base = Self::to_chunk(IVec3 { x: wx, y: cy * KCHUNK_DIM, z: wz });
            let cc = ChunkCoord { x: base.x, y: cy, z: base.z };
            if let Some(res) = self.store.get(cc) {
                for ly in (0..KCHUNK_DIM).rev() {
                    if Self::solid_block(res.get(lx as usize, ly as usize, lz as usize)) {
                        return cy * KCHUNK_DIM + ly;
                    }
                }
            } else {
                let mut tmp = PaletteChunk::new(cc, 0);
                gen.generate(cc, &mut tmp);
                for ly in (0..KCHUNK_DIM).rev() {
                    if Self::solid_block(tmp.get(lx as usize, ly as usize, lz as usize)) {
                        return cy * KCHUNK_DIM + ly;
                    }
                }
            }
        }
        NO_FLOOR
    }

    // day/night cycle phase in 0..1 (start bright morning, ~12 min/day).
    fn day_time(clock: f64) -> f32 {
        ((clock * 0.00175 + 0.30) % 1.0) as f32
    }

    // Generate a chunk via the worldgen (pure fn of seed+coord). Borrows gen
    // immutably and returns an owned chunk so the caller can mutate the store
    // afterward without a borrow conflict.
    fn gen_chunk(&self, cc: ChunkCoord) -> Option<PaletteChunk> {
        let gen = self.gen.as_ref()?;
        let mut ch = PaletteChunk::new(cc, 0);
        gen.generate(cc, &mut ch);
        Some(ch)
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
                self.dirty.insert(cc);
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
        self.recompute_stream_set();
        self.creatures.clear();
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
                    self.dirty.insert(cc);
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
                self.dirty.insert(cc);
                self.restore_region(cc);
            }
        }
        self.pos = V3::new(8.0, 12.0, 8.0);
        self.yaw = 3.14159;
        self.pitch = -0.5;
    }

    // ---- M2: disk save/load ----------------------------------------------
    // Only player-EDITED chunks are persisted; pure-procedural chunks regen from seed.
    pub fn save(&self, dir: &str) -> bool {
        use std::io::Write;
        if std::fs::create_dir_all(dir).is_err() {
            // C++ ignores the error_code and keeps going; mirror that.
        }
        // world.meta
        {
            let path = format!("{}/world.meta", dir);
            let mut f = match std::fs::File::create(&path) {
                Ok(f) => f,
                Err(_) => return false,
            };
            let mut buf: Vec<u8> = Vec::new();
            buf.extend_from_slice(b"BFWM");
            buf.extend_from_slice(&self.seed.to_le_bytes());
            let rc = self.region_sat.len() as u32;
            buf.extend_from_slice(&rc.to_le_bytes());
            for (k, v) in self.region_sat.iter() {
                buf.extend_from_slice(&k.x.to_le_bytes());
                buf.extend_from_slice(&k.z.to_le_bytes());
                buf.extend_from_slice(&v.to_le_bytes());
            }
            if f.write_all(&buf).is_err() {
                return false;
            }
        }
        // player.dat
        {
            let path = format!("{}/player.dat", dir);
            let mut buf: Vec<u8> = Vec::new();
            buf.extend_from_slice(b"BFPL");
            buf.extend_from_slice(&self.pos.x.to_le_bytes());
            buf.extend_from_slice(&self.pos.y.to_le_bytes());
            buf.extend_from_slice(&self.pos.z.to_le_bytes());
            buf.extend_from_slice(&self.yaw.to_le_bytes());
            buf.extend_from_slice(&self.pitch.to_le_bytes());
            buf.push(self.mode as i32 as u8);
            buf.extend_from_slice(&self.health.to_le_bytes());
            buf.extend_from_slice(&self.hunger.to_le_bytes());
            buf.push(self.selected);
            for i in 0..BF_INVENTORY_SLOTS {
                let s = self.inv.as_ref().map(|inv| inv.get(i)).unwrap_or_default();
                buf.extend_from_slice(&s.item.to_le_bytes());
                buf.extend_from_slice(&s.count.to_le_bytes());
                buf.extend_from_slice(&s.durability.to_le_bytes());
            }
            // Quest + achievement progress.
            buf.extend_from_slice(b"BFQ1");
            buf.extend_from_slice(&(self.active_quest as u32).to_le_bytes());
            buf.extend_from_slice(&(self.quests_completed as u32).to_le_bytes());
            buf.push(if self.all_quests_done { 1 } else { 0 });
            buf.extend_from_slice(&(self.obj_progress.len() as u32).to_le_bytes());
            for &v in &self.obj_progress {
                buf.extend_from_slice(&v.to_le_bytes());
            }
            buf.extend_from_slice(&(K_ACHIEVEMENT_COUNT as u32).to_le_bytes());
            for i in 0..K_ACHIEVEMENT_COUNT {
                buf.push(if self.ach_done[i] { 1 } else { 0 });
                buf.extend_from_slice(&self.ach_progress[i].to_le_bytes());
            }
            if let Ok(mut f) = std::fs::File::create(&path) {
                let _ = f.write_all(&buf);
            }
        }
        // edited chunks
        for &cc in &self.edited {
            let ch = match self.store.get(cc) {
                Some(c) => c,
                None => continue,
            };
            let bytes = ch.serialize();
            if bytes.is_empty() {
                continue;
            }
            let name = format!("{}/c_{}_{}_{}.chunk", dir, cc.x, cc.y, cc.z);
            if let Ok(mut f) = std::fs::File::create(&name) {
                let _ = f.write_all(&bytes);
            }
        }
        true
    }

    pub fn load(&mut self, dir: &str) -> bool {
        let meta = match std::fs::read(format!("{}/world.meta", dir)) {
            Ok(b) => b,
            Err(_) => return false,
        };
        let mut r = ByteReader::new(&meta);
        if r.take(4) != Some(b"BFWM") {
            return false;
        }
        self.seed = match r.u64() {
            Some(v) => v,
            None => return false,
        };
        if let Some(g) = self.gen.as_mut() {
            g.seed(self.seed);
        }
        let rc = r.u32().unwrap_or(0);
        self.region_sat.clear();
        for _ in 0..rc {
            let x = r.i32();
            let z = r.i32();
            let v = r.f32();
            if let (Some(x), Some(z), Some(v)) = (x, z, v) {
                self.region_sat.insert(RegionKey { x, z }, v);
            }
        }
        let mut quest_loaded = false;
        if let Ok(pl) = std::fs::read(format!("{}/player.dat", dir)) {
            let mut p = ByteReader::new(&pl);
            if p.take(4) == Some(b"BFPL") {
                self.pos.x = p.f32().unwrap_or(self.pos.x);
                self.pos.y = p.f32().unwrap_or(self.pos.y);
                self.pos.z = p.f32().unwrap_or(self.pos.z);
                self.yaw = p.f32().unwrap_or(self.yaw);
                self.pitch = p.f32().unwrap_or(self.pitch);
                let m = p.u8().unwrap_or(self.mode as i32 as u8);
                self.mode = if m == 1 {
                    bf_game_mode::BF_MODE_CREATIVE
                } else {
                    bf_game_mode::BF_MODE_SURVIVAL
                };
                self.health = p.f32().unwrap_or(self.health);
                self.hunger = p.f32().unwrap_or(self.hunger);
                self.selected = p.u8().unwrap_or(self.selected);
                for i in 0..BF_INVENTORY_SLOTS {
                    let item = p.u16().unwrap_or(0);
                    let count = p.u16().unwrap_or(0);
                    let durability = p.u16().unwrap_or(0xFFFF);
                    if let Some(inv) = self.inv.as_mut() {
                        inv.set(i, ItemStack { item, count, durability });
                    }
                }
                // Quest + achievement progress (only present in newer saves).
                if p.take(4) == Some(b"BFQ1") {
                    let aq = p.u32().unwrap_or(0);
                    let qc = p.u32().unwrap_or(0);
                    let aqd = p.u8().unwrap_or(0);
                    let opn = p.u32().unwrap_or(0);
                    self.start_quest(aq as usize);
                    for i in 0..opn {
                        let v = p.u32().unwrap_or(0);
                        if (i as usize) < self.obj_progress.len() {
                            self.obj_progress[i as usize] = v;
                        }
                    }
                    self.quests_completed = qc as i32;
                    self.all_quests_done = aqd != 0;
                    let an = p.u32().unwrap_or(0);
                    for i in 0..an {
                        let dn = p.u8().unwrap_or(0);
                        let pr = p.i32().unwrap_or(0);
                        if (i as usize) < K_ACHIEVEMENT_COUNT {
                            self.ach_done[i as usize] = dn != 0;
                            self.ach_progress[i as usize] = pr;
                        }
                    }
                    self.ach_done_count = 0;
                    for i in 0..K_ACHIEVEMENT_COUNT {
                        if self.ach_done[i] {
                            self.ach_done_count += 1;
                        }
                    }
                    quest_loaded = true;
                }
            }
        }
        self.spawn = self.pos;
        if self.health <= 0.0 {
            self.health = 20.0;
        }
        // Load edited chunks (*.chunk).
        if let Ok(rd) = std::fs::read_dir(dir) {
            for entry in rd.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("chunk") {
                    continue;
                }
                let bytes = match std::fs::read(&path) {
                    Ok(b) => b,
                    Err(_) => continue,
                };
                if bytes.is_empty() {
                    continue;
                }
                if let Some(ch) = PaletteChunk::deserialize(&bytes) {
                    let cc = ch.coord();
                    self.store.insert(ch);
                    self.dirty.insert(cc);
                    self.edited.insert(cc);
                }
            }
        }
        self.ensure_clear_spawn();
        self.last_center = Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        });
        self.first_stream = true;
        self.creatures.clear();
        self.creature_timer = 0.0;
        if !quest_loaded {
            self.start_quest(0);
        }
        self.recompute_stream_set();
        true
    }

    // ---- quest engine ----------------------------------------------------
    fn start_quest(&mut self, i: usize) {
        self.active_quest = i;
        self.obj_progress.clear();
        if let Some(x) = self.extra {
            if i < x.quests().len() {
                self.obj_progress = vec![0u32; x.quests()[i].objectives.len()];
            }
        }
    }
    fn quest_done(q: &QuestDefX, prog: &[u32]) -> bool {
        for (i, o) in q.objectives.iter().enumerate() {
            if prog[i] < o.count {
                return false;
            }
        }
        true
    }
    fn check_achievements(&mut self, trig: &str, target: &str) {
        for i in 0..K_ACHIEVEMENT_COUNT {
            let a = &K_ACHIEVEMENTS[i];
            if self.ach_done[i] || trig != a.trig {
                continue;
            }
            if !a.target.is_empty() && target != a.target {
                continue;
            }
            self.ach_progress[i] += 1;
            if self.ach_progress[i] >= a.count {
                self.ach_done[i] = true;
                self.ach_done_count += 1;
                self.ach_toast = format!("Achievement: {}", a.title);
                self.ach_toast_timer = 4.0;
                let pv = self.player_voxel();
                self.fx(6, pv, 0);
            }
        }
    }
    fn notify_quest(&mut self, trig: &str, target: &str) {
        self.check_achievements(trig, target);
        let extra = match self.extra {
            Some(x) => x,
            None => return,
        };
        if self.active_quest >= extra.quests().len() {
            return;
        }
        // Gather quest data (immutable borrow) before mutating obj_progress.
        let q = &extra.quests()[self.active_quest];
        if self.obj_progress.len() != q.objectives.len() {
            return;
        }
        let mut changed = false;
        for (i, o) in q.objectives.iter().enumerate() {
            if o.trigger == trig
                && (o.target.is_empty() || o.target == target)
                && self.obj_progress[i] < o.count
            {
                self.obj_progress[i] += 1;
                changed = true;
            }
        }
        if changed && Self::quest_done(q, &self.obj_progress) {
            // Reward + advance. Collect rewards first (immutable), then add (mutable inv).
            let rewards: Vec<(String, u32)> = q.rewards.clone();
            let next = self.active_quest + 1;
            let total = extra.quests().len();
            for (item, cnt) in rewards {
                let id = self.item_id_by_name(&item);
                if id != 0 {
                    if let Some(inv) = self.inv.as_mut() {
                        inv.add(ItemStack { item: id, count: cnt as u16, durability: 0xFFFF });
                    }
                }
            }
            self.quests_completed += 1;
            let pv = self.player_voxel();
            self.fx(6, pv, 0);
            if next < total {
                self.start_quest(next);
            } else {
                self.all_quests_done = true;
            }
        }
    }

    // ---- crafting --------------------------------------------------------
    // Recipe indices whose ingredients are all in the inventory now (cap 24).
    fn craftable_recipes(&self) -> Vec<u32> {
        let mut out = Vec::new();
        let content = match self.content {
            Some(c) => c,
            None => return out,
        };
        let inv = match self.inv.as_ref() {
            Some(i) => i,
            None => return out,
        };
        let has_table = {
            let ct = self.item_id_by_name("crafting_table");
            ct != 0 && inv.count_item(ct) > 0
        };
        let mut i = 0u32;
        while i < content.recipe_count() && out.len() < 24 {
            let r = content.recipe(i);
            if r.pattern.is_empty() || r.result_item == 0 {
                i += 1;
                continue;
            }
            if r.grid_size >= 3 && !has_table {
                i += 1;
                continue;
            }
            let pat = &r.pattern;
            let mut ok = true;
            let mut a = 0usize;
            while a < pat.len() && ok {
                let it = pat[a];
                if it == 0 {
                    a += 1;
                    continue;
                }
                let mut first_occ = true;
                let mut need = 0i32;
                for s in 0..pat.len() {
                    if pat[s] == it {
                        need += 1;
                        if s < a {
                            first_occ = false;
                        }
                    }
                }
                if !first_occ {
                    a += 1;
                    continue;
                }
                if (inv.count_item(it) as i32) < need {
                    ok = false;
                }
                a += 1;
            }
            if ok {
                out.push(i);
            }
            i += 1;
        }
        out
    }

    fn craft_index(&mut self, idx: i32) {
        let content = match self.content {
            Some(c) => c,
            None => return,
        };
        let cr = self.craftable_recipes();
        let mut idx = idx;
        if idx < 0 {
            if !cr.is_empty() {
                idx = 0;
            } else {
                return;
            }
        }
        if idx as usize >= cr.len() {
            return;
        }
        let r = content.recipe(cr[idx as usize]);
        // Clone the recipe data we need so we can take a mutable inv borrow.
        let pattern: Vec<ItemId> = r.pattern.clone();
        let grid_size = r.grid_size;
        let result_item = r.result_item;
        let result_count = r.result_count;
        if self.craft_commit(&pattern, grid_size) {
            let pv = self.player_voxel();
            self.fx(4, pv, 0);
            let made = if result_count > 0 { result_count as i32 } else { 1 };
            let rname = self.item_name(result_item);
            for _ in 0..made {
                self.notify_quest("craft_item", &rname);
            }
        }
    }

    // Atomic crafting commit (port of CraftingSystem::commit). All-or-nothing.
    fn craft_commit(&mut self, grid: &[ItemId], dim: i32) -> bool {
        let content = match self.content {
            Some(c) => c,
            None => return false,
        };
        let m = match content.recipe_match(grid, dim) {
            Some(m) => m,
            None => return false,
        };
        // Tally required ingredients per id.
        let mut required: HashMap<ItemId, u16> = HashMap::new();
        for &id in grid {
            if id == 0 {
                continue;
            }
            *required.entry(id).or_insert(0) += 1;
        }
        let inv = match self.inv.as_mut() {
            Some(i) => i,
            None => return false,
        };
        // Verify availability.
        for (&item, &need) in &required {
            if inv.count_item(item) < need {
                return false;
            }
        }
        // Consume.
        for (&item, &need) in &required {
            inv.remove_item(item, need);
        }
        // Add result; roll back on no room.
        let result = ItemStack { item: m.result, count: m.count, durability: 0xFFFF };
        if !inv.add(result) {
            for (&item, &need) in &required {
                inv.add(ItemStack { item, count: need, durability: 0xFFFF });
            }
            return false;
        }
        true
    }

    // ---- mine/place + tool wear ------------------------------------------
    fn break_time(&self, b: BlockId) -> f32 {
        if b == AIR {
            return 1e9;
        }
        let bd = self.content.and_then(|c| c.block_by_id(b));
        let hardness = bd.map(|d| d.hardness as f32).unwrap_or(6.0);
        let req = bd.map(|d| d.required_tier).unwrap_or(0);
        let mut t = 0.15 + hardness * 0.05;
        if let (Some(inv), Some(content)) = (self.inv.as_ref(), self.content) {
            let it = content.item_by_id(inv.get(self.selected as usize).item);
            let tier = it.map(|d| d.tool_tier).unwrap_or(0);
            if tier > 0 && tier >= req {
                t *= 0.35;
            } else if req > 0 && tier < req {
                t *= 4.0;
            }
        }
        t
    }
    // Sound class for break audio.
    fn sound_class_for(b: BlockId) -> i32 {
        match b {
            3 | 8 | 10 | 15 | 29 => 1,
            21 | 22 | 4 | 23 | 30 | 31 | 33 => 2,
            1 | 2 | 14 | 16 | 12 => 3,
            6 | 11 => 4,
            25 | 26 | 13 => 5,
            5 | 27 | 36 | 37 | 38 | 39 => 6,
            17 | 18 | 19 | 20 => 7,
            _ => 0,
        }
    }
    fn footstep_class(b: BlockId) -> i32 {
        match b {
            3 | 8 | 10 | 29 => 1,
            6 => 2,
            12 | 13 => 3,
            4 | 23 | 21 | 22 | 49 | 51 | 33 => 4,
            _ => 0,
        }
    }
    fn item_that_places(&self, b: BlockId) -> ItemId {
        let content = match self.content {
            Some(c) => c,
            None => return 0,
        };
        if b == 0 {
            return 0;
        }
        for id in 1u16..400 {
            if let Some(d) = content.item_by_id(id) {
                if d.places_block == b {
                    return d.id;
                }
            }
        }
        0
    }

    fn damage_held_tool(&mut self) {
        let content = match self.content {
            Some(c) => c,
            None => return,
        };
        let sel = match self.inv.as_ref() {
            Some(i) => i.get(self.selected as usize),
            None => return,
        };
        if sel.item == 0 {
            return;
        }
        let it = match content.item_by_id(sel.item) {
            Some(it) if it.tool_durability != 0 => it,
            _ => return,
        };
        let mut dur = if sel.durability == 0xFFFF { it.tool_durability } else { sel.durability };
        if dur > 0 {
            dur -= 1;
        }
        let target = self.target;
        if dur == 0 {
            let mut newsel = sel;
            newsel.count = if newsel.count > 0 { newsel.count - 1 } else { 0 };
            let replacement = if newsel.count == 0 {
                ItemStack::default()
            } else {
                ItemStack { item: newsel.item, count: newsel.count, durability: 0xFFFF }
            };
            if let Some(inv) = self.inv.as_mut() {
                inv.set(self.selected as usize, replacement);
            }
            self.fx(0, target, 0);
        } else {
            let mut s = sel;
            s.durability = dur;
            if let Some(inv) = self.inv.as_mut() {
                inv.set(self.selected as usize, s);
            }
        }
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
        self.recompute_stream_set();
        self.creatures.retain(|c| !c.hostile);
        let pv = self.player_voxel();
        self.fx(6, pv, 0);
    }

    fn perform_place(&mut self) {
        if !self.has_target || self.inv.is_none() {
            return;
        }
        let sel = self.inv.as_ref().unwrap().get(self.selected as usize);
        if sel.item == 0 {
            return;
        }
        let pb = self.content.and_then(|c| c.item_by_id(sel.item)).map(|d| d.places_block).unwrap_or(0);
        if pb == 0 {
            return;
        }
        let solid = !(pb == AIR || pb == WATER || (36..=47).contains(&pb));
        if self.mode == bf_game_mode::BF_MODE_SURVIVAL && solid && self.voxel_in_player_box(self.place) {
            return;
        }
        if self.mode == bf_game_mode::BF_MODE_SURVIVAL {
            let removed = self.inv.as_mut().unwrap().remove_item(sel.item, 1);
            if !removed {
                return;
            }
        }
        let place = self.place;
        self.set_block_internal(place, pb);
        if pb == 33 {
            let up = IVec3 { x: place.x, y: place.y + 1, z: place.z };
            if self.block_at(up) == AIR {
                self.set_block_internal(up, 33);
            }
        }
        self.fx(1, place, 0);
        let pbname = self.block_name(pb);
        self.notify_quest("place_block", &pbname);
        if pb == self.glow_id || (self.beacon_id != 0 && pb == self.beacon_id) {
            self.notify_quest("light_beacon", &pbname);
            let rc = Self::to_chunk(place);
            if self.region_sat(rc) < 0.99 {
                self.regions_restored += 1;
                self.notify_quest("restore_region", "dim_barrens");
            }
            self.restore_region(rc);
        }
    }

    fn break_block(&mut self, t: IVec3) {
        let broken = self.block_at(t);
        if broken == AIR {
            return;
        }
        self.fx(0, t, ((broken as i32) << 4) | Self::sound_class_for(broken));
        let bn = self.block_name(broken);
        self.notify_quest("mine_block", &bn);
        if Self::is_log(broken) {
            let place_item = self.item_that_places(broken);
            let in_name = self.item_name(place_item);
            self.notify_quest("collect_item", &in_name);
            self.fell_tree(t);
        } else {
            // Drop the item (or the open-door / wood-beam special cases).
            let mut drop = self.content.and_then(|c| c.block_by_id(broken)).map(|d| d.drop_item).unwrap_or(0);
            if drop == 0 {
                drop = self.item_that_places(broken);
            }
            if broken == 50 {
                drop = self.item_id_by_name("oak_door");
            }
            if broken == 51 {
                drop = self.item_id_by_name("oak_log");
            }
            if drop != 0 {
                if let Some(inv) = self.inv.as_mut() {
                    inv.add(ItemStack { item: drop, count: 1, durability: 0xFFFF });
                }
                self.fx(7, t, 0);
                let dn = self.item_name(drop);
                self.notify_quest("collect_item", &dn);
            }
            self.set_block_internal(t, AIR);
            // 2-tall door: clear the other half (already dropped one door item).
            if broken == 33 || broken == 50 {
                let dup = IVec3 { x: t.x, y: t.y + 1, z: t.z };
                let ddn = IVec3 { x: t.x, y: t.y - 1, z: t.z };
                let du = self.block_at(dup);
                let dd = self.block_at(ddn);
                if du == 33 || du == 50 {
                    self.set_block_internal(dup, AIR);
                }
                if dd == 33 || dd == 50 {
                    self.set_block_internal(ddn, AIR);
                }
            }
            // A prop resting on this block loses support: break it too.
            let above = IVec3 { x: t.x, y: t.y + 1, z: t.z };
            let ab = self.block_at(above);
            if Self::is_prop_block(ab) {
                let adrop = self.content.and_then(|c| c.block_by_id(ab)).map(|d| d.drop_item).unwrap_or(0);
                if adrop != 0 {
                    if let Some(inv) = self.inv.as_mut() {
                        inv.add(ItemStack { item: adrop, count: 1, durability: 0xFFFF });
                    }
                    let an = self.item_name(adrop);
                    self.notify_quest("collect_item", &an);
                }
                self.set_block_internal(above, AIR);
            }
            self.apply_gravity_above(t);
            self.flow_water(t);
        }
    }

    // ---- destruction physics ---------------------------------------------
    fn falling_color(b: BlockId) -> V3 {
        match b {
            6 => V3::new(0.86, 0.79, 0.55),
            11 => V3::new(0.55, 0.53, 0.50),
            21 => V3::new(0.50, 0.36, 0.20),
            22 => V3::new(0.78, 0.72, 0.56),
            5 => V3::new(0.27, 0.55, 0.24),
            27 => V3::new(0.40, 0.62, 0.32),
            _ => V3::new(0.6, 0.6, 0.6),
        }
    }
    fn spawn_falling(&mut self, w: IVec3, b: BlockId, as_item: bool, vel: V3) {
        if self.falling.len() > 200 {
            return;
        }
        let spin = self.rand01() * 6.2831853;
        let spin_rate = (self.rand01() - 0.5) * 8.0;
        self.falling.push(FallingBlock {
            pos: V3::new(w.x as f32 + 0.5, w.y as f32, w.z as f32 + 0.5),
            vel,
            spin,
            spin_rate,
            block: b,
            color: Self::falling_color(b),
            as_item,
            life: 6.0,
        });
    }
    fn flow_water(&mut self, t: IVec3) {
        if self.block_at(t) != AIR {
            return;
        }
        let fed = self.block_at(IVec3 { x: t.x, y: t.y + 1, z: t.z }) == WATER
            || self.block_at(IVec3 { x: t.x + 1, y: t.y, z: t.z }) == WATER
            || self.block_at(IVec3 { x: t.x - 1, y: t.y, z: t.z }) == WATER
            || self.block_at(IVec3 { x: t.x, y: t.y, z: t.z + 1 }) == WATER
            || self.block_at(IVec3 { x: t.x, y: t.y, z: t.z - 1 }) == WATER;
        if !fed {
            return;
        }
        self.set_block_internal(t, WATER);
        let mut w = t;
        for _ in 0..64 {
            let below = IVec3 { x: w.x, y: w.y - 1, z: w.z };
            if self.block_at(below) != AIR {
                break;
            }
            self.set_block_internal(w, AIR);
            self.set_block_internal(below, WATER);
            w = below;
        }
    }
    fn apply_gravity_above(&mut self, w: IVec3) {
        let mut up = IVec3 { x: w.x, y: w.y + 1, z: w.z };
        while Self::is_gravity_block(self.block_at(up)) {
            let b = self.block_at(up);
            self.set_block_internal(up, AIR);
            self.spawn_falling(up, b, false, V3::new(0.0, -1.0, 0.0));
            up.y += 1;
        }
    }
    fn fell_tree(&mut self, base: IVec3) {
        let mut logs: Vec<IVec3> = Vec::new();
        let mut stack: Vec<IVec3> = vec![base];
        let mut seen: HashSet<(i32, i32, i32)> = HashSet::new();
        seen.insert((base.x, base.y, base.z));
        while let Some(w) = stack.pop() {
            if logs.len() >= 12 {
                break;
            }
            logs.push(w);
            for dx in -1..=1 {
                for dy in 0..=1 {
                    for dz in -1..=1 {
                        let n = IVec3 { x: w.x + dx, y: w.y + dy, z: w.z + dz };
                        if !Self::is_log(self.block_at(n)) {
                            continue;
                        }
                        if seen.insert((n.x, n.y, n.z)) {
                            stack.push(n);
                        }
                    }
                }
            }
        }
        // Logs fall outward+up from base, then drop as items.
        for w in &logs {
            let b = self.block_at(*w);
            self.set_block_internal(*w, AIR);
            let h = (w.y - base.y) as f32;
            let vx = (self.rand01() - 0.5) * 2.0;
            let vz = (self.rand01() - 0.5) * 2.0;
            self.spawn_falling(*w, b, true, V3::new(vx, 1.5 + h * 0.4, vz));
        }
        // Attached leaves removed; a FEW particle bursts (capped).
        let mut leaf_bursts = 0;
        let mut leaves_removed = 0;
        let logs_copy = logs.clone();
        for lw in &logs_copy {
            if leaves_removed >= 160 {
                break;
            }
            for dx in -3..=3 {
                for dy in -1..=4 {
                    for dz in -3..=3 {
                        let n = IVec3 { x: lw.x + dx, y: lw.y + dy, z: lw.z + dz };
                        let lf = self.block_at(n);
                        if !Self::is_leaf(lf) {
                            continue;
                        }
                        self.set_block_internal(n, AIR);
                        leaves_removed += 1;
                        if leaf_bursts < 6 {
                            self.fx(0, n, ((lf as i32) << 4) | 6);
                            leaf_bursts += 1;
                        }
                    }
                }
            }
        }
        self.fx(2, base, 0);
    }
    fn update_falling(&mut self, dt: f32) {
        // Mutate falling positions first (no self.block_at borrow conflict since
        // falling is a separate field, but landing logic needs block reads, so
        // process landings into a list then apply).
        let n = self.falling.len();
        for i in 0..n {
            let (px, py, pz) = {
                let fb = &mut self.falling[i];
                fb.vel.y -= 26.0 * dt;
                fb.pos = fb.pos + fb.vel * dt;
                fb.spin += fb.spin_rate * dt;
                fb.life -= dt;
                (fb.pos.x, fb.pos.y, fb.pos.z)
            };
            let fy = self.floor_below(Self::ifloor(px), py.floor() as i32 + 1, Self::ifloor(pz));
            if fy != NO_FLOOR && py <= fy as f32 {
                let land = IVec3 { x: Self::ifloor(px), y: fy, z: Self::ifloor(pz) };
                let (as_item, block) = {
                    let fb = &self.falling[i];
                    (fb.as_item, fb.block)
                };
                if as_item {
                    let id = self.item_that_places(block);
                    if id != 0 {
                        if let Some(inv) = self.inv.as_mut() {
                            inv.add(ItemStack { item: id, count: 1, durability: 0xFFFF });
                        }
                    }
                    self.fx(7, land, 0);
                } else {
                    let mut settle = land;
                    let mut guard = 0;
                    while self.block_at(settle) != AIR && guard < 64 {
                        settle.y += 1;
                        guard += 1;
                    }
                    if self.block_at(settle) == AIR {
                        self.set_block_internal(settle, block);
                        self.fx(0, settle, ((block as i32) << 4) | Self::sound_class_for(block));
                    }
                }
                self.falling[i].life = 0.0;
            }
        }
        self.falling.retain(|f| f.life > 0.0);
    }

    // ---- raycast + combat ------------------------------------------------
    fn raycast_target(&mut self) {
        self.has_target = false;
        let o = self.pos;
        let d = self.forward_dir();
        let mut v = IVec3 { x: Self::ifloor(o.x), y: Self::ifloor(o.y), z: Self::ifloor(o.z) };
        let step = IVec3 {
            x: if d.x > 0.0 { 1 } else { -1 },
            y: if d.y > 0.0 { 1 } else { -1 },
            z: if d.z > 0.0 { 1 } else { -1 },
        };
        let td = V3::new(
            if d.x != 0.0 { (1.0 / d.x).abs() } else { 1e30 },
            if d.y != 0.0 { (1.0 / d.y).abs() } else { 1e30 },
            if d.z != 0.0 { (1.0 / d.z).abs() } else { 1e30 },
        );
        let frac = |f: f32, s: i32| -> f32 {
            let fl = f.floor();
            if s > 0 {
                fl + 1.0 - f
            } else {
                f - fl
            }
        };
        let mut tmax = V3::new(
            td.x * frac(o.x, step.x),
            td.y * frac(o.y, step.y),
            td.z * frac(o.z, step.z),
        );
        let mut prev = v;
        for _ in 0..128 {
            if self.block_at(v) != AIR {
                self.has_target = true;
                self.target = v;
                self.place = prev;
                return;
            }
            prev = v;
            if tmax.x < tmax.y && tmax.x < tmax.z {
                v.x += step.x;
                tmax.x += td.x;
            } else if tmax.y < tmax.z {
                v.y += step.y;
                tmax.y += td.y;
            } else {
                v.z += step.z;
                tmax.z += td.z;
            }
        }
    }

    fn creature_in_view(&self) -> i32 {
        let o = self.pos;
        let d = self.forward_dir();
        let mut best = -1i32;
        let mut best_t = 6.0f32;
        for (i, c) in self.creatures.iter().enumerate() {
            let cc = c.pos + V3::new(0.0, c.scale * 0.5, 0.0);
            let rel = cc - o;
            let t = dot(rel, d);
            if t < 0.0 || t > best_t {
                continue;
            }
            let closest = o + d * t;
            let off = cc - closest;
            let rad = 0.55 + c.scale * 0.7;
            if dot(off, off) < rad * rad {
                best_t = t;
                best = i as i32;
            }
        }
        best
    }

    fn attack_creature(&mut self, idx: i32) {
        let idx = idx as usize;
        let (cx, cy, cz, is_boss) = {
            let cr = &self.creatures[idx];
            (cr.pos.x, cr.pos.y, cr.pos.z, cr.is_boss)
        };
        let cv = IVec3 { x: Self::ifloor(cx), y: Self::ifloor(cy), z: Self::ifloor(cz) };
        // Damage by held weapon.
        let mut dmg = 2;
        if let (Some(inv), Some(content)) = (self.inv.as_ref(), self.content) {
            if let Some(it) = content.item_by_id(inv.get(self.selected as usize).item) {
                if it.tool_kind == 4 {
                    dmg = 4 + it.tool_tier as i32 * 2;
                } else if it.tool_kind == 2 {
                    dmg = 3;
                }
            }
        }
        self.damage_held_tool();
        // Apply hit + knockback.
        let px = self.pos.x;
        let pz = self.pos.z;
        {
            let cr = &mut self.creatures[idx];
            cr.hp -= dmg;
            cr.hit_flash = 0.22;
            let ax = cr.pos.x - px;
            let az = cr.pos.z - pz;
            let ad = (ax * ax + az * az).sqrt();
            let kb = if cr.is_boss { 0.25 } else { 1.3 };
            if ad > 0.01 {
                cr.pos.x += ax / ad * kb;
                cr.pos.z += az / ad * kb;
            }
            cr.vy = if cr.is_boss { 0.8 } else { 3.0 };
        }
        self.fx(8, cv, 0);
        if self.creatures[idx].hp <= 0 {
            let (boss, hostile, nm) = {
                let cr = &self.creatures[idx];
                (cr.is_boss, cr.hostile, cr.name.clone())
            };
            let cr = self.creatures[idx].clone();
            self.drop_creature_loot(&cr);
            self.creatures.remove(idx);
            self.creatures_calmed += 1;
            let pv = self.player_voxel();
            self.fx(5, pv, 0);
            let trig = if boss {
                "calm_boss"
            } else if hostile {
                "defeat_monster"
            } else {
                "defeat_animal"
            };
            self.notify_quest(trig, &nm);
        }
        let _ = is_boss;
    }

    fn drop_creature_loot(&mut self, cr: &Creature) {
        if self.inv.is_none() {
            return;
        }
        if cr.hostile {
            let n1 = 1 + (self.rand01() * 2.0) as i32;
            self.give_loot("color_dust", n1);
            let n2 = 1 + (self.rand01() * 2.0) as i32;
            self.give_loot("glow_dust", n2);
            if self.rand01() < 0.5 {
                self.give_loot("coal", 1);
            }
        } else if cr.is_boss {
            let n1 = 2 + (self.rand01() * 2.0) as i32;
            self.give_loot("crystal_shard", n1);
            self.give_loot("color_dust", 2);
        } else {
            let n1 = 1 + (self.rand01() * 2.0) as i32;
            self.give_loot("feather", n1);
            if self.rand01() < 0.4 {
                self.give_loot("berry_cluster", 1);
            }
        }
        let pv = self.player_voxel();
        self.fx(7, pv, 0);
    }
    // Reward for clearing a ruin "danger site": a small bundle of worthwhile items
    // granted once when the last defender falls. Reuses give_loot (the same path
    // creatures use to drop loot on death), so it respects the existing inventory
    // behavior. Item ids are sensible existing content (food + a material + a block).
    fn drop_ruin_clear_reward(&mut self) {
        if self.inv.is_none() {
            return;
        }
        self.give_loot("honey_cake", 2); // food
        self.give_loot("iron_ingot", 2); // useful material
        self.give_loot("stone_brick", 4); // building block
        let pv = self.player_voxel();
        self.fx(7, pv, 0);
    }
    fn give_loot(&mut self, nm: &str, n: i32) {
        let id = self.item_id_by_name(nm);
        if id != 0 {
            if let Some(inv) = self.inv.as_mut() {
                inv.add(ItemStack { item: id, count: n as u16, durability: 0xFFFF });
            }
            self.notify_quest("collect_item", nm);
        }
    }

    // ---- creatures: colour + biome --------------------------------------
    fn biome_id(&self) -> i32 {
        worldgen::worldgen_dominant_biome(Self::ifloor(self.pos.x), Self::ifloor(self.pos.z), self.seed)
    }
    fn biome_label(&self) -> &'static str {
        if self.block_at(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y) - 1,
            z: Self::ifloor(self.pos.z),
        }) == WATER
        {
            return "Ocean";
        }
        match self.biome_id() {
            1 => "Forest",
            2 => "Mountains",
            3 => "Desert",
            4 => "Snowy",
            5 => "Swamp",
            6 => "Beach",
            _ => "Plains",
        }
    }
    fn biome_key(&self) -> &'static str {
        match self.biome_id() {
            1 => "forest",
            2 => "mountains",
            3 => "desert",
            4 => "snowy",
            5 => "swamp",
            6 => "beach",
            _ => "plains",
        }
    }
    fn hue_rgb(h: f32) -> V3 {
        let cl = |x: f32| -> f32 {
            if x < 0.0 {
                0.0
            } else if x > 1.0 {
                1.0
            } else {
                x
            }
        };
        let r = (((h * 6.0 + 0.0) % 6.0) - 3.0).abs() - 1.0;
        let g = (((h * 6.0 + 4.0) % 6.0) - 3.0).abs() - 1.0;
        let b = (((h * 6.0 + 2.0) % 6.0) - 3.0).abs() - 1.0;
        V3::new(0.45 + 0.5 * cl(r), 0.45 + 0.5 * cl(g), 0.45 + 0.5 * cl(b))
    }
    fn color_for(disp: &str, id: u16) -> V3 {
        let mut h = (id as f32 * 0.6180339) % 1.0;
        if disp == "night_gentle" {
            h = 0.55 + 0.18 * h;
        } else if disp == "boss" {
            h = 0.05 + 0.08 * h;
        } else if disp == "hostile" {
            let base = Self::hue_rgb(0.72 + 0.15 * h);
            return V3::new(base.x * 0.45, base.y * 0.45, base.z * 0.55);
        }
        Self::hue_rgb(h)
    }

    fn spawn_ring_creature(&mut self, boss: bool, rmin: f32, rmax: f32) -> bool {
        let ang = self.rand01() * 6.2831853;
        let r = rmin + self.rand01() * (rmax - rmin);
        let cx = self.pos.x + ang.cos() * r;
        let cz = self.pos.z + ang.sin() * r;
        let gy = self.floor_below(Self::ifloor(cx), self.pos.y as i32 + 30, Self::ifloor(cz));
        if gy == NO_FLOOR {
            return false;
        }
        if self.block_at(IVec3 { x: Self::ifloor(cx), y: gy + 1, z: Self::ifloor(cz) }) == WATER {
            return false;
        }
        let mut c = Creature::default();
        c.pos = V3::new(cx, gy as f32, cz);
        c.yaw = self.rand01() * 6.2831853;
        c.wander = 1.0 + self.rand01() * 2.0;
        c.is_boss = boss;
        let have_extra = self.extra.map(|x| !x.creatures().is_empty()).unwrap_or(false);
        if have_extra {
            let bk = self.biome_key();
            // Build the pool (immutable borrow of extra) collecting cloned defs.
            let pool: Vec<CreatureDefX> = {
                let x = self.extra.unwrap();
                let mut p: Vec<CreatureDefX> = Vec::new();
                for d in x.creatures() {
                    if (d.disposition == "boss") != boss {
                        continue;
                    }
                    if d.model == 20 {
                        continue;
                    }
                    if !boss && (d.disposition == "hostile" || d.disposition == "aquatic") {
                        continue;
                    }
                    if !(d.biome.is_empty() || d.biome == "any" || d.biome == bk) {
                        continue;
                    }
                    p.push(d.clone());
                }
                if p.is_empty() {
                    for d in x.creatures() {
                        if (d.disposition == "boss") != boss {
                            continue;
                        }
                        if d.model == 20 {
                            continue;
                        }
                        if !boss && (d.disposition == "hostile" || d.disposition == "aquatic") {
                            continue;
                        }
                        p.push(d.clone());
                    }
                }
                p
            };
            if !pool.is_empty() {
                let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
                let d = &pool[pick];
                c.name = d.name.clone();
                c.color = Self::color_for(if boss { "boss" } else { &d.disposition }, d.id);
                c.speed = if boss { d.move_speed * 0.7 } else { d.move_speed };
                c.shape = (d.id % 8) as i32;
                c.model = d.model;
                c.skittish = d.disposition == "skittish";
                c.hp = if d.max_health > 0 {
                    d.max_health as i32
                } else if boss {
                    10
                } else {
                    5
                };
            } else {
                c.hp = if boss { 10 } else { 5 };
            }
        } else {
            c.color = Self::color_for(if boss { "boss" } else { "passive" }, (self.creatures.len() + 1) as u16);
            c.speed = if boss { 1.2 } else { 1.6 };
            c.name = if boss { "guardian".into() } else { "critter".into() };
            c.shape = (self.creatures.len() % 8) as i32;
            c.hp = if boss { 10 } else { 5 };
        }
        c.scale = if boss { 2.0 } else { 0.8 };
        self.creatures.push(c);
        true
    }

    fn spawn_hostile(&mut self, rmin: f32, rmax: f32) -> bool {
        let ang = self.rand01() * 6.2831853;
        let r = rmin + self.rand01() * (rmax - rmin);
        let cx = self.pos.x + ang.cos() * r;
        let cz = self.pos.z + ang.sin() * r;
        let gy = self.floor_below(Self::ifloor(cx), self.pos.y as i32 + 3, Self::ifloor(cz));
        if gy == NO_FLOOR {
            return false;
        }
        // Never spawn in lit areas (torches make a safe zone).
        {
            let lc = Self::to_chunk(IVec3 { x: Self::ifloor(cx), y: gy, z: Self::ifloor(cz) });
            if let Some(lch) = self.store.get(lc) {
                let bl = lch.block_light(
                    Self::mod16(Self::ifloor(cx)) as usize,
                    Self::mod16(gy) as usize,
                    Self::mod16(Self::ifloor(cz)) as usize,
                );
                if bl >= 7 {
                    return false;
                }
            }
        }
        let mut c = Creature::default();
        c.pos = V3::new(cx, gy as f32, cz);
        c.yaw = self.rand01() * 6.2831853;
        c.hostile = true;
        c.scale = 1.0;
        let pool: Vec<CreatureDefX> = self
            .extra
            .map(|x| x.creatures().iter().filter(|d| d.disposition == "hostile").cloned().collect())
            .unwrap_or_default();
        if !pool.is_empty() {
            let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
            let d = &pool[pick];
            c.name = d.name.clone();
            c.model = d.model;
            c.speed = if d.move_speed > 0.0 { d.move_speed } else { 2.6 };
            c.hp = if d.max_health > 0 { d.max_health as i32 } else { 6 };
            c.color = Self::color_for("hostile", d.id);
        } else {
            c.speed = 2.6;
            c.hp = 6;
            c.shape = if self.rand01() < 0.5 { 1 } else { 0 };
            c.color = if c.shape == 1 {
                V3::new(0.16, 0.13, 0.20)
            } else {
                V3::new(0.12, 0.10, 0.16)
            };
            c.name = if c.shape == 1 { "lurker".into() } else { "monster".into() };
        }
        self.creatures.push(c);
        true
    }

    fn spawn_fish(&mut self, rmin: f32, rmax: f32) -> bool {
        let pool: Vec<CreatureDefX> = match self.extra {
            Some(x) => x.creatures().iter().filter(|d| d.disposition == "aquatic").cloned().collect(),
            None => return false,
        };
        if pool.is_empty() {
            return false;
        }
        let ang = self.rand01() * 6.2831853;
        let r = rmin + self.rand01() * (rmax - rmin);
        let wx = Self::ifloor(self.pos.x + ang.cos() * r);
        let wz = Self::ifloor(self.pos.z + ang.sin() * r);
        let mut wy = NO_FLOOR;
        let mut y = Self::ifloor(self.pos.y) + 4;
        while y > Self::ifloor(self.pos.y) - 20 {
            if self.block_at(IVec3 { x: wx, y, z: wz }) == WATER {
                wy = y;
                break;
            }
            y -= 1;
        }
        if wy == NO_FLOOR {
            return false;
        }
        let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
        let d = &pool[pick];
        let mut c = Creature::default();
        c.pos = V3::new(wx as f32 + 0.5, wy as f32, wz as f32 + 0.5);
        c.yaw = self.rand01() * 6.2831853;
        c.aquatic = true;
        c.model = d.model;
        c.name = d.name.clone();
        c.speed = if d.move_speed > 0.0 { d.move_speed } else { 2.0 };
        c.hp = if d.max_health > 0 { d.max_health as i32 } else { 3 };
        c.scale = 0.55;
        c.color = Self::color_for("aquatic", d.id);
        self.creatures.push(c);
        true
    }

    fn maintain_creatures(&mut self, dt: f32) {
        if self.gen.is_none() || self.store.resident_count() < 20 {
            return;
        }
        self.creature_timer -= dt;
        if self.creature_timer > 0.0 {
            return;
        }
        let kdespawn2 = 90.0f32 * 90.0;
        let px = self.pos.x;
        let pz = self.pos.z;
        self.creatures.retain(|c| {
            let dx = c.pos.x - px;
            let dz = c.pos.z - pz;
            (dx * dx + dz * dz) <= kdespawn2
        });
        let t = Self::day_time(self.world_clock);
        let surv = self.mode == bf_game_mode::BF_MODE_SURVIVAL;
        let night = surv && (t < 0.20 || t > 0.80);
        let dark_cave = surv
            && (worldgen::worldgen_surface_height(Self::ifloor(self.pos.x), Self::ifloor(self.pos.z), self.seed)
                - Self::ifloor(self.pos.y))
                > 6;
        let monsters_active = (night || dark_cave) && self.quests_completed > 0;
        if !monsters_active {
            // Cull gated (night/cave) hostiles when the gate is closed, but keep the
            // ruin "danger site" hostiles, which are dangerous around the clock.
            self.creatures.retain(|c| !c.hostile || c.from_ruin);
        }
        let mut ambient = 0;
        let mut bosses = 0;
        let mut hostiles = 0;
        for c in &self.creatures {
            if c.hostile {
                // Ruin hostiles are managed by the danger-site pass, not the night
                // cap, so they do not block normal night spawns.
                if !c.from_ruin {
                    hostiles += 1;
                }
            } else if c.is_boss {
                bosses += 1;
            } else if c.model != 20 {
                ambient += 1;
            }
        }
        self.creature_timer = 1.0;
        if monsters_active {
            self.creature_timer = 2.5;
            if hostiles < 4 {
                self.spawn_hostile(10.0, 22.0);
            }
        } else if ambient < 9 {
            self.creature_timer = if ambient < 6 { 0.1 } else { 0.5 };
            self.spawn_ring_creature(false, 8.0, 26.0);
        } else if bosses < 2 {
            self.creature_timer = 1.0;
            self.spawn_ring_creature(true, 18.0, 40.0);
        }
        let fish = self.creatures.iter().filter(|c| c.aquatic).count();
        if fish < 4 && self.rand01() < 0.5 {
            self.spawn_fish(6.0, 22.0);
        }
    }

    // Ruined structures are localized "danger sites": when the player is near one, a
    // small fixed band of defenders spawns at it regardless of the night/quest gate (so
    // ruins feel dangerous in the daytime too). A ruin is CLEARABLE: each site spawns
    // its defenders at most once, and once the player kills them they do NOT immediately
    // respawn. A cleared site only re-arms after a long cooldown AND once the player has
    // moved well away, so killing the defenders actually clears the ruin instead of
    // refilling a global cap. Per-site state is keyed on the deterministic ruin anchor.
    fn maintain_danger_sites(&mut self, dt: f32) {
        // Re-arm cooldown for a cleared ruin, and how far the player must be for the
        // cooldown to tick / a respawn to be allowed.
        const REARM_COOLDOWN: f32 = 300.0; // several minutes
        const AWAY_DIST: f32 = 64.0;
        // Defenders per ruin site (a small fixed number).
        const DEFENDERS_PER_SITE: i32 = 3;

        if self.gen.is_none() || self.store.resident_count() < 20 {
            return;
        }
        // Only meaningful in survival (hostiles do not act in creative).
        if self.mode != bf_game_mode::BF_MODE_SURVIVAL {
            return;
        }
        self.danger_timer -= dt;
        if self.danger_timer > 0.0 {
            return;
        }
        self.danger_timer = 3.0;

        let px = Self::ifloor(self.pos.x);
        let pz = Self::ifloor(self.pos.z);

        // Advance re-arm cooldowns for cleared sites the player is away from, and re-arm
        // any whose cooldown has elapsed. We only re-arm far-away sites so a cleared
        // ruin cannot reload under the player's feet. One fixed danger tick of time.
        let tick = self.danger_timer;
        for (&(sx, sz), st) in self.ruin_sites.iter_mut() {
            if !st.cleared {
                continue;
            }
            let far = ((sx - px) as f32).abs() >= AWAY_DIST || ((sz - pz) as f32).abs() >= AWAY_DIST;
            if !far {
                continue;
            }
            st.rearm_cd -= tick;
            if st.rearm_cd <= 0.0 {
                st.cleared = false;
                st.spawned = 0;
                st.rearm_cd = 0.0;
            }
        }

        // Find the nearest ruin within a reasonable radius of the player.
        let site = worldgen::worldgen_dangerous_site_near(px, pz, 48, self.seed);
        let (ax, ay, az) = match site {
            Some(s) => s,
            None => return,
        };
        // Only spawn once the ruin's chunk is actually resident (avoids spawning into
        // ungenerated space).
        if !self.store.is_resident(Self::to_chunk(IVec3 { x: ax, y: ay, z: az })) {
            return;
        }

        let key = (ax, az);
        let st = self.ruin_sites.entry(key).or_default();
        // A cleared site stays cleared until it re-arms (handled above). Do not respawn.
        if st.cleared {
            return;
        }
        // This site has already spawned its full band of defenders for this cycle. If
        // they are all dead, mark it cleared (one-shot until re-arm); otherwise wait.
        if st.spawned >= DEFENDERS_PER_SITE {
            let alive = self.creatures.iter().any(|c| {
                c.hostile && c.from_ruin && c.home_x == ax && c.home_z == az
            });
            if !alive {
                let already_rewarded = {
                    let st = self.ruin_sites.get_mut(&key).expect("site present");
                    st.cleared = true;
                    st.rearm_cd = REARM_COOLDOWN;
                    st.rewarded
                };
                // Reward the player for clearing the ruin, once per site (never on a
                // re-cleared site). Reuses the same loot path creatures use on death.
                if !already_rewarded {
                    self.drop_ruin_clear_reward();
                    let st = self.ruin_sites.get_mut(&key).expect("site present");
                    st.rewarded = true;
                }
            }
            return;
        }
        // Still arming: spawn one defender per tick (the 3s danger_timer spaces them out)
        // up to the fixed band. Each defender jitters within a few blocks of the anchor,
        // so they do not stack on one spot.
        if self.spawn_hostile_at(ax, ay, az) {
            let st = self.ruin_sites.get_mut(&key).expect("site present");
            st.spawned += 1;
        }
    }

    // Spawn a single ruin "danger site" hostile near (ax,ay,az). Mirrors the body of
    // spawn_hostile but anchors at the site and marks the creature from_ruin so the
    // night/quest gate does not cull it. The anchor is recorded in home_x/home_z so the
    // danger-site pass can tell which ruin a defender belongs to. Returns true on
    // success.
    fn spawn_hostile_at(&mut self, ax: i32, ay: i32, az: i32) -> bool {
        let ox = ax as f32 + (self.rand01() * 6.0 - 3.0);
        let oz = az as f32 + (self.rand01() * 6.0 - 3.0);
        let gy = self.floor_below(Self::ifloor(ox), ay + 5, Self::ifloor(oz));
        if gy == NO_FLOOR {
            return false;
        }
        let mut c = Creature::default();
        c.pos = V3::new(ox, gy as f32, oz);
        c.yaw = self.rand01() * 6.2831853;
        c.hostile = true;
        c.from_ruin = true;
        // Record the ruin anchor so the danger-site pass can tell which site this
        // defender belongs to (used to detect a cleared ruin).
        c.home_x = ax;
        c.home_z = az;
        c.scale = 1.0;
        let pool: Vec<CreatureDefX> = self
            .extra
            .map(|x| x.creatures().iter().filter(|d| d.disposition == "hostile").cloned().collect())
            .unwrap_or_default();
        if !pool.is_empty() {
            let pick = (self.rand01() * pool.len() as f32) as usize % pool.len();
            let d = &pool[pick];
            c.name = d.name.clone();
            c.model = d.model;
            c.speed = if d.move_speed > 0.0 { d.move_speed } else { 2.6 };
            c.hp = if d.max_health > 0 { d.max_health as i32 } else { 6 };
            c.color = Self::color_for("hostile", d.id);
        } else {
            c.speed = 2.6;
            c.hp = 6;
            c.shape = if self.rand01() < 0.5 { 1 } else { 0 };
            c.color = if c.shape == 1 {
                V3::new(0.16, 0.13, 0.20)
            } else {
                V3::new(0.12, 0.10, 0.16)
            };
            c.name = if c.shape == 1 { "lurker".into() } else { "monster".into() };
        }
        self.creatures.push(c);
        true
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

    // Build the next missing segment of a palisade ring (stateless: placed logs are
    // the progress). Returns the number of wall cells built this call.
    fn build_palisade_segment(&mut self, cx: i32, cz: i32, cells_to_build: i32) -> i32 {
        const R: i32 = 8;
        const WALL: BlockId = 21;
        let mut built = 0;
        // Order: top edge, right edge, bottom edge, left edge (matches C++).
        let mut order: Vec<(i32, i32)> = Vec::new();
        for dx in -R..=R {
            order.push((dx, -R));
        }
        for dz in (-R + 1)..=R {
            order.push((R, dz));
        }
        for dx in (-R..=(R - 1)).rev() {
            order.push((dx, R));
        }
        for dz in ((-R + 1)..=(R - 1)).rev() {
            order.push((-R, dz));
        }
        for (dx, dz) in order {
            if built >= cells_to_build {
                break;
            }
            if dz == R && (dx == 0 || dx == 1) {
                continue; // gate on south edge
            }
            let wx = cx + dx;
            let wz = cz + dz;
            let surf = worldgen::worldgen_surface_height(wx, wz, self.seed);
            if self.block_at(IVec3 { x: wx, y: surf + 1, z: wz }) == WALL {
                continue;
            }
            self.set_block_internal(IVec3 { x: wx, y: surf + 1, z: wz }, WALL);
            self.set_block_internal(IVec3 { x: wx, y: surf + 2, z: wz }, WALL);
            built += 1;
        }
        built
    }

    fn try_village_donation(&mut self, idx: usize) -> bool {
        let held = match self.inv.as_ref() {
            Some(i) => i.get(self.selected as usize),
            None => return false,
        };
        if held.item == 0 {
            return false;
        }
        let in_name = self.item_name(held.item);
        let npc_id = self.creatures[idx].npc_id;
        if npc_id == 4 {
            let is_log = in_name == "oak_log" || in_name == "birch_log" || in_name == "pine_log";
            if !is_log {
                return false;
            }
            if held.count < 2 {
                self.ach_toast = "Woodcutter: bring me more logs for the wall.".into();
                self.ach_toast_timer = 3.0;
                return true;
            }
            let cells = (held.count.min(8) as i32) / 2;
            let (hx, hz) = (self.creatures[idx].home_x, self.creatures[idx].home_z);
            let built = self.build_palisade_segment(hx, hz, cells);
            if built > 0 {
                if let Some(inv) = self.inv.as_mut() {
                    inv.remove_item(held.item, (built * 2) as u16);
                }
                let pv = self.player_voxel();
                self.fx(1, pv, 0);
                self.ach_toast = "Woodcutter: the village wall grows!".into();
                self.ach_toast_timer = 3.0;
            } else {
                self.ach_toast = "Woodcutter: our palisade is complete!".into();
                self.ach_toast_timer = 3.0;
            }
            return true;
        }
        false
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

    fn update_creatures(&mut self, dt: f32) {
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
            let mut spd_mul = 1.0f32;
            if c.hostile && self.mode == bf_game_mode::BF_MODE_SURVIVAL {
                if c.atk_cd > 0.0 {
                    c.atk_cd -= dt;
                }
                let xzd = (to_player.x * to_player.x + to_player.z * to_player.z).sqrt();
                let kaggro = 16.0;
                if xzd < kaggro {
                    if dot(to_player, to_player) > 0.0001 {
                        c.yaw = to_player.x.atan2(to_player.z);
                    }
                    let yd = ((c.pos.y + c.scale * 0.5) - (self.pos.y - 1.6)).abs();
                    if xzd < 1.3 && yd < 1.6 && c.atk_cd <= 0.0 {
                        self.hurt_player(2.5);
                        c.atk_cd = 1.1;
                    }
                } else if c.wander <= 0.0 {
                    c.yaw = self.rand01() * 6.2831853;
                    c.wander = 1.5 + self.rand01() * 2.5;
                }
            } else if c.friendly {
                let d = dot(to_player, to_player).sqrt();
                if d > 2.2 {
                    c.yaw = to_player.x.atan2(to_player.z);
                } else {
                    spd_mul = 0.0;
                    if c.wander <= 0.0 {
                        c.yaw = self.rand01() * 6.2831853;
                        c.wander = 1.0 + self.rand01() * 1.5;
                    }
                }
            } else if c.skittish && dot(to_player, to_player) < 36.0 {
                c.yaw = (-to_player.x).atan2(-to_player.z);
                c.wander = 0.8;
            } else if c.wander <= 0.0 {
                c.yaw = self.rand01() * 6.2831853;
                c.wander = 1.5 + self.rand01() * 2.5;
            }
            let dir = V3::new(c.yaw.sin(), 0.0, c.yaw.cos());
            let next = c.pos + dir * (c.speed * spd_mul * dt);
            let nv = IVec3 { x: Self::ifloor(next.x), y: Self::ifloor(next.y), z: Self::ifloor(next.z) };
            let into_water = !c.aquatic
                && (self.block_at(IVec3 { x: nv.x, y: nv.y, z: nv.z }) == WATER
                    || self.block_at(IVec3 { x: nv.x, y: nv.y - 1, z: nv.z }) == WATER);
            if !into_water && !self.collide_solid(nv.x, nv.y, nv.z) {
                c.pos.x = next.x;
                c.pos.z = next.z;
            } else if !into_water && !self.collide_solid(nv.x, nv.y + 1, nv.z) {
                c.pos.x = next.x;
                c.pos.z = next.z;
                c.pos.y += 1.0;
            } else if c.wander <= 0.0 {
                c.yaw += 2.0 + self.rand01() * 2.2;
                c.wander = 0.6 + self.rand01() * 0.6;
            }
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
            self.creatures[i] = c;
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

    // ---- streaming -------------------------------------------------------
    fn recompute_stream_set(&mut self) {
        self.gen_queue.clear();
        let c = self.last_center;
        let creative = self.mode == bf_game_mode::BF_MODE_CREATIVE;
        let near_r = 5;
        let player_cy = Self::floordiv(Self::ifloor(self.pos.y), KCHUNK_DIM);
        for dx in -self.stream_r..=self.stream_r {
            for dz in -self.stream_r..=self.stream_r {
                let near = creative || (dx.abs() <= near_r && dz.abs() <= near_r);
                let mut surf_cy = player_cy;
                if !near {
                    let key = ((c.x + dx) as i64) << 32 | ((c.z + dz) as u32 as i64);
                    if let Some(&v) = self.surf_cy_cache.get(&key) {
                        surf_cy = v;
                    } else {
                        let sy = worldgen::worldgen_surface_height(
                            (c.x + dx) * KCHUNK_DIM + KCHUNK_DIM / 2,
                            (c.z + dz) * KCHUNK_DIM + KCHUNK_DIM / 2,
                            self.seed,
                        );
                        surf_cy = Self::floordiv(sy, KCHUNK_DIM);
                        if self.surf_cy_cache.len() > 200000 {
                            self.surf_cy_cache.clear();
                        }
                        self.surf_cy_cache.insert(key, surf_cy);
                    }
                }
                let lo = player_cy.min(surf_cy) - 1;
                let hi = surf_cy + 1;
                for cy in CY_MIN..=CY_MAX {
                    let want = near || (cy >= lo && cy <= hi);
                    if !want {
                        continue;
                    }
                    let cc = ChunkCoord { x: c.x + dx, y: cy, z: c.z + dz };
                    if !self.store.is_resident(cc) {
                        self.gen_queue.push(cc);
                    }
                }
            }
        }
        // Sort farthest-first so the nearest chunk is at the back (popped first).
        self.gen_queue.sort_by(|a, b| Self::dist2(*b, c).cmp(&Self::dist2(*a, c)));
        self.evict_far();
    }

    fn evict_far(&mut self) {
        let mut drop: Vec<ChunkCoord> = Vec::new();
        for (cc, _) in self.meshes.iter() {
            if (cc.x - self.last_center.x).abs() > self.stream_r + 1
                || (cc.z - self.last_center.z).abs() > self.stream_r + 1
            {
                drop.push(*cc);
            }
        }
        for cc in drop {
            if let Some(rec) = self.meshes.get(&cc) {
                if rec.has_buffers && self.has_alloc {
                    self.gpu_free(rec.vbuf.handle);
                    self.gpu_free(rec.ibuf.handle);
                }
            }
            self.meshes.remove(&cc);
            self.store.evict(cc);
        }
    }

    // How much terrain is still waiting to be generated + meshed.
    fn stream_backlog(&self) -> usize {
        self.gen_queue.len() + self.dirty.len()
    }
    // A LARGE backlog means a bulk fill (spawn-in, teleport, the initial load at a
    // big render distance), not the small ring added by normal walking. Only then
    // do we crank the per-frame budgets + in-flight caps, so steady-state play
    // never floods the upload/dirty work. Mirrors the C++ bulk_fill heuristic.
    fn bulk_fill(&self) -> bool {
        !self.moving && self.stream_backlog() > 384
    }

    // Lazily create the worker pool + result channels on the first live tick.
    // Never called on the sync test path (that branch returns before this).
    fn ensure_pool(&mut self) {
        if self.pool.is_some() {
            return;
        }
        self.pool = Some(crate::jobs::WorkerPool::new(crate::jobs::recommended_workers()));
        let (gtx, grx) = std::sync::mpsc::channel::<GenResult>();
        let (mtx, mrx) = std::sync::mpsc::channel::<MeshJobResult>();
        self.gen_tx = Some(gtx);
        self.gen_rx = Some(grx);
        self.mesh_tx = Some(mtx);
        self.mesh_rx = Some(mrx);
    }

    fn stream_tick(&mut self) {
        if self.gen.is_none() {
            return;
        }
        // Synchronous mode (tests): generate inline so chunk availability is
        // deterministic per update() call rather than dependent on worker
        // wall-clock. KEEP THIS PATH EXACTLY as the original sync streamer (#25:
        // the unit/world tests run with debug_set_sync_streaming(true) and depend
        // on this inline, deterministic behaviour).
        if self.sync_stream {
            let mut made = 0;
            while !self.gen_queue.is_empty() && made < GEN_BUDGET {
                let cc = self.gen_queue.pop().unwrap();
                if self.store.is_resident(cc) {
                    continue;
                }
                let ch = match self.gen_chunk(cc) {
                    Some(c) => c,
                    None => continue,
                };
                if ch.is_uniform() && ch.get(0, 0, 0) == AIR {
                    made += 1;
                    continue;
                }
                self.store.insert(ch);
                self.dirty.insert(cc);
                made += 1;
            }
            return;
        }

        // Live (async) path: generate on workers, collect finished chunks here.
        self.ensure_pool();
        let bulk = self.bulk_fill();

        // 1) Drain finished gen chunks. Budgeted: meshing downstream is the limit,
        // so inserting the whole worker backlog at once explodes dirty_ and the
        // per-frame dirty scan, tanking FPS (mirrors the C++ kGenCollect).
        let gen_collect = if bulk { 64 } else { 16 };
        let mut done: Vec<GenResult> = Vec::new();
        if let Some(rx) = self.gen_rx.as_ref() {
            while done.len() < gen_collect {
                match rx.try_recv() {
                    Ok(r) => done.push(r),
                    Err(_) => break,
                }
            }
        }
        for r in done {
            self.gen_inflight.remove(&r.cc);
            if self.store.is_resident(r.cc) {
                continue;
            }
            // Skip pure-air chunks (above terrain): block_at() returns AIR anyway.
            if r.chunk.is_uniform() && r.chunk.get(0, 0, 0) == AIR {
                continue;
            }
            self.store.insert(r.chunk);
            self.dirty.insert(r.cc);
        }

        // 2) Submit more gen jobs, keeping a bounded number in flight (the queue is
        // sorted farthest-first, so popping the back submits nearest-first).
        let max_inflight = if bulk { 128 } else { 32 };
        // worldgen is a pure fn of coord + seed; each job builds its own seeded
        // generator from this seed (TerrainGen does not derive Clone, so we re-seed
        // a fresh one rather than capture self.gen).
        let seed = self.seed;
        while !self.gen_queue.is_empty() && self.gen_inflight.len() < max_inflight {
            let cc = self.gen_queue.pop().unwrap();
            if self.store.is_resident(cc) || self.gen_inflight.contains(&cc) {
                continue;
            }
            let tx = match self.gen_tx.as_ref() {
                Some(t) => t.clone(),
                None => break,
            };
            if self.pool.is_none() {
                break;
            }
            self.gen_inflight.insert(cc);
            let job = move || {
                let mut g = TerrainGen::new();
                g.seed(seed);
                let mut ch = PaletteChunk::new(cc, 0);
                g.generate(cc, &mut ch);
                // If the channel is gone (World dropped) the send just fails.
                let _ = tx.send(GenResult { cc, chunk: ch });
            };
            self.pool.as_ref().unwrap().submit(job);
        }
    }


    // ---- GPU allocator boundary (the one unsafe FFI surface) -------------
    // Allocate a GPU buffer through the registered allocator function pointer.
    // The Swift side provides storageModeShared Metal memory; in tests it is a
    // malloc-backed shim. Returns a zeroed buffer if no allocator is set.
    fn gpu_alloc(&self, bytes: u32) -> bf_gpu_buffer {
        match self.alloc.alloc {
            // The abi types this fn pointer as a safe extern "C" fn, so the call
            // itself needs no unsafe. alloc was registered by the host via
            // set_allocator and user is its opaque context (the FFI contract in
            // contract/engine_c_api.h bf_gpu_allocator). The unsafety is in writing
            // to the returned contents pointer, which happens in remesh_one.
            Some(f) => f(self.alloc.user, bytes),
            None => bf_gpu_buffer { handle: 0, contents: std::ptr::null_mut(), bytes: 0 },
        }
    }
    fn gpu_free(&self, handle: bf_handle) {
        if let Some(f) = self.alloc.free_ {
            // free_ is the host-registered counterpart to alloc; handle came from a
            // prior gpu_alloc on the same allocator (FFI contract).
            f(self.alloc.user, handle);
        }
    }

    // #51 cache the chunk's prop blocks as instances for the prop renderer.
    fn scan_chunk_props(&self, cc: ChunkCoord) -> Vec<bf_prop_instance> {
        let mut props: Vec<bf_prop_instance> = Vec::new();
        let ch = match self.store.get(cc) {
            Some(c) => c,
            None => return props,
        };
        let sat = self.region_sat(cc);
        let bx = cc.x * KCHUNK_DIM;
        let by = cc.y * KCHUNK_DIM;
        let bz = cc.z * KCHUNK_DIM;
        for lz in 0..KCHUNK_DIM {
            for ly in 0..KCHUNK_DIM {
                for lx in 0..KCHUNK_DIM {
                    let id = ch.get(lx as usize, ly as usize, lz as usize);
                    let prop = Self::is_prop_block(id);
                    let tree = Self::is_tree_block(id);
                    if !prop && !tree {
                        continue;
                    }
                    if tree && (id == 5 || id == 27 || id == 48) {
                        let see_through = |ax: i32, ay: i32, az: i32| -> bool {
                            if ax < 0 || ay < 0 || az < 0 || ax >= KCHUNK_DIM || ay >= KCHUNK_DIM || az >= KCHUNK_DIM {
                                return true;
                            }
                            let n = ch.get(ax as usize, ay as usize, az as usize);
                            n == 0 || n == 9
                        };
                        let exposed = see_through(lx + 1, ly, lz)
                            || see_through(lx - 1, ly, lz)
                            || see_through(lx, ly + 1, lz)
                            || see_through(lx, ly - 1, lz)
                            || see_through(lx, ly, lz + 1)
                            || see_through(lx, ly, lz - 1);
                        if !exposed {
                            continue;
                        }
                    }
                    let mut h = ((bx + lx).wrapping_mul(73856093)
                        ^ (by + ly).wrapping_mul(19349663)
                        ^ (bz + lz).wrapping_mul(83492791)) as u32;
                    if id == 21 || id == 22 || id == 49 {
                        let is_logf = |dx: i32, dy: i32, dz: i32| -> bool {
                            let b = self.block_at(IVec3 { x: bx + lx + dx, y: by + ly + dy, z: bz + lz + dz });
                            b == 21 || b == 22 || b == 49
                        };
                        let above = is_logf(0, 1, 0);
                        let below = is_logf(0, -1, 0);
                        let xax = is_logf(1, 1, 0) || is_logf(-1, 1, 0) || is_logf(1, -1, 0)
                            || is_logf(-1, -1, 0) || is_logf(1, 0, 0) || is_logf(-1, 0, 0);
                        let zax = is_logf(0, 1, 1) || is_logf(0, 1, -1) || is_logf(0, -1, 1)
                            || is_logf(0, -1, -1) || is_logf(0, 0, 1) || is_logf(0, 0, -1);
                        if !above && !below && !xax && !zax {
                            h &= 0x001FFFFF;
                        } else if !above && !below {
                            let axis: u32 = if zax && !xax { 1 } else { 0 };
                            h = 0x80000000 | (axis << 30) | (h & 0x3FFFFFFF);
                        } else {
                            let mut level = 0;
                            for k in 1..=24 {
                                if !is_logf(0, -k, 0) {
                                    break;
                                }
                                level += 1;
                            }
                            if level > 127 {
                                level = 127;
                            }
                            let mut slant: u32 = 0;
                            let mut sdir: u32 = 0;
                            if !below {
                                if is_logf(1, -1, 0) {
                                    slant = 1;
                                    sdir = 0;
                                } else if is_logf(-1, -1, 0) {
                                    slant = 1;
                                    sdir = 1;
                                } else if is_logf(0, -1, 1) {
                                    slant = 1;
                                    sdir = 2;
                                } else if is_logf(0, -1, -1) {
                                    slant = 1;
                                    sdir = 3;
                                }
                            }
                            h = ((level as u32) << 24) | (slant << 23) | (sdir << 21) | (h & 0x001FFFFF);
                        }
                    } else if id == 38 || id == 42 {
                        let same = |dx: i32, dz: i32| -> bool {
                            self.block_at(IVec3 { x: bx + lx + dx, y: by + ly, z: bz + lz + dz }) == id
                        };
                        let mut dens: u32 = 0;
                        for dz2 in -1..=1 {
                            for dx2 in -1..=1 {
                                if (dx2 != 0 || dz2 != 0) && same(dx2, dz2) {
                                    dens += 1;
                                }
                            }
                        }
                        h = (h & 0x0FFFFFFF) | (dens << 28);
                    }
                    props.push(bf_prop_instance {
                        position: bf_vec3 { x: (bx + lx) as f32, y: (by + ly) as f32, z: (bz + lz) as f32 },
                        type_: id as u32,
                        seed: h,
                        sat,
                    });
                }
            }
        }
        props
    }

    fn remesh_dirty(&mut self) {
        if !self.has_alloc {
            return;
        }
        let async_mode = !self.sync_stream;
        if async_mode {
            self.ensure_pool();
        }
        let bulk = self.bulk_fill();

        // 1) (async) Upload meshes finished on worker threads. The GPU allocator is
        // frame-thread only, so this is the one place worker output reaches the GPU.
        // Budgeted: buffer alloc + memcpy is the main-thread cost (mirrors the C++
        // kUploadBudget); the rest waits a frame rather than tanking FPS.
        if async_mode {
            let upload_budget = if bulk { 24 } else { 8 };
            let mut batch: Vec<MeshJobResult> = Vec::new();
            if let Some(rx) = self.mesh_rx.as_ref() {
                while batch.len() < upload_budget {
                    match rx.try_recv() {
                        Ok(r) => batch.push(r),
                        Err(_) => break,
                    }
                }
            }
            for r in batch {
                self.mesh_inflight.remove(&r.cc);
                self.upload_mesh_result(r);
            }
        }

        if self.dirty.is_empty() {
            return;
        }
        // Order dirty chunks: nearest first, preferring chunks in view, with
        // never-meshed chunks before re-meshes.
        let mut todo: Vec<ChunkCoord> = self.dirty.iter().copied().collect();
        let cam_fwd = self.forward_dir();
        let pos = self.pos;
        let meshes = &self.meshes;
        let score = |a: ChunkCoord| -> f64 {
            let ctr = V3::new(
                (a.x as f32 + 0.5) * KCHUNK_DIM as f32,
                (a.y as f32 + 0.5) * KCHUNK_DIM as f32,
                (a.z as f32 + 0.5) * KCHUNK_DIM as f32,
            );
            let to = V3::new(ctr.x - pos.x, ctr.y - pos.y, ctr.z - pos.z);
            let d2 = dot(to, to);
            let facing = dot(to, cam_fwd) / (d2.sqrt() + 0.001);
            let mut s = d2 as f64 * (if facing > 0.2 { 1.0 } else { 4.0 });
            if meshes.contains_key(&a) {
                s += 1e15;
            }
            s
        };
        // Sync (tests): a small fixed budget so per-frame chunk counts stay
        // deterministic (lighting + meshing run inline on the frame thread).
        // Async (live): a bigger budget that just SUBMITS jobs (cheap), letting the
        // workers do the meshing; bulk fill cranks it so a big load rushes in. The
        // C++ used the same split (MESH_BUDGET sync, bulk 36 async).
        let mesh_budget = if !async_mode {
            MESH_BUDGET
        } else if bulk {
            36
        } else {
            MESH_BUDGET
        };
        let kremesh_cap = if bulk { 12 } else { 4 };
        let mesh_inflight_cap = if bulk { 192 } else { 64 };
        // NaN-safe: a finite score sorts normally; if pos ever went NaN we keep order
        // instead of panicking (the C++ comparator tolerated NaN as UB-but-non-crashing).
        todo.sort_by(|a, b| score(*a).partial_cmp(&score(*b)).unwrap_or(std::cmp::Ordering::Equal));
        let mut done = 0;
        let mut remeshes = 0;
        // Collect the chunks to mesh (so the dirty set + lighting cascade can mutate
        // without iterator invalidation), mirroring the C++ in-loop dirty edits.
        let order: Vec<ChunkCoord> = todo;
        for cc in order {
            if done >= mesh_budget {
                break;
            }
            // (async) Do not re-enqueue a chunk already meshing on a worker, and
            // stop submitting once the in-flight cap is hit (back-pressure).
            if async_mode && (self.mesh_inflight.contains(&cc) || self.mesh_inflight.len() >= mesh_inflight_cap) {
                continue;
            }
            let fresh = !self.meshes.contains_key(&cc);
            if !fresh && remeshes >= kremesh_cap {
                continue;
            }
            if !self.store.is_resident(cc) {
                self.dirty.remove(&cc);
                continue;
            }
            self.dirty.remove(&cc);
            if !fresh {
                remeshes += 1;
            }
            done += 1;
            // Light before meshing; re-dirty only neighbours whose boundary changed.
            // Lighting stays on the FRAME THREAD (it mutates the live store and drives
            // the re-dirty cascade); the worker only meshes the resulting lit snapshot,
            // so async results match the sync inline path exactly.
            let faces = lighting::light_chunk(&mut self.store, cc);
            if faces != 0 {
                let dirs = [
                    IVec3 { x: 1, y: 0, z: 0 },
                    IVec3 { x: -1, y: 0, z: 0 },
                    IVec3 { x: 0, y: 1, z: 0 },
                    IVec3 { x: 0, y: -1, z: 0 },
                    IVec3 { x: 0, y: 0, z: 1 },
                    IVec3 { x: 0, y: 0, z: -1 },
                ];
                for f in 0..6 {
                    if faces & (1 << f) != 0 {
                        let nc = ChunkCoord { x: cc.x + dirs[f].x, y: cc.y + dirs[f].y, z: cc.z + dirs[f].z };
                        if self.store.is_resident(nc) {
                            self.dirty.insert(nc);
                        }
                    }
                }
            }
            if async_mode {
                self.submit_mesh_job(cc); // game: mesh on a worker, upload when done
            } else {
                self.remesh_one(cc); // sync / tests: inline mesh + upload
            }
        }
    }

    // Snapshot the lit chunk + its 6 face neighbours and enqueue a mesh job. The
    // worker greedy-meshes the snapshot into CPU byte buffers; the frame thread
    // uploads them later (upload_mesh_result). The snapshot is owned COPIES, so
    // the worker never races the live store.
    fn submit_mesh_job(&mut self, cc: ChunkCoord) {
        let mut chunks: HashMap<ChunkCoord, PaletteChunk> = HashMap::new();
        let add = |w: &mut HashMap<ChunkCoord, PaletteChunk>, c: ChunkCoord| {
            if let Some(ch) = self.store.get(c) {
                w.insert(c, ch.clone());
            }
        };
        add(&mut chunks, cc);
        let dirs = [
            ChunkCoord { x: cc.x + 1, y: cc.y, z: cc.z },
            ChunkCoord { x: cc.x - 1, y: cc.y, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y + 1, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y - 1, z: cc.z },
            ChunkCoord { x: cc.x, y: cc.y, z: cc.z + 1 },
            ChunkCoord { x: cc.x, y: cc.y, z: cc.z - 1 },
        ];
        for d in dirs {
            add(&mut chunks, d);
        }
        let tx = match self.mesh_tx.as_ref() {
            Some(t) => t.clone(),
            None => return,
        };
        if self.pool.is_none() {
            return;
        }
        self.mesh_inflight.insert(cc);
        // The mesher is a zero-size, stateless unit struct; make a fresh one for the
        // job rather than borrowing self.mesher into the closure.
        let mesher = GreedyMesher::new();
        let job = move || {
            let snap = SnapStore { chunks };
            let (mr, vbytes, ibytes) = mesher.mesh(cc, &snap, false);
            let empty = mr.empty || mr.index_count == 0;
            let _ = tx.send(MeshJobResult {
                cc,
                vbytes: if empty { Vec::new() } else { vbytes },
                ibytes: if empty { Vec::new() } else { ibytes },
                index_count: mr.index_count,
                empty,
            });
        };
        self.pool.as_ref().unwrap().submit(job);
    }

    // Frame-thread upload of a worker mesh result: refresh the prop cache (props
    // are scanned here against the LIVE store, exactly as the sync remesh_one does),
    // free the old GPU buffers, and upload the new ones through the allocator.
    fn upload_mesh_result(&mut self, r: MeshJobResult) {
        if !self.store.is_resident(r.cc) {
            return; // evicted while meshing — drop the result
        }
        let props = self.scan_chunk_props(r.cc);
        if let Some(rec) = self.meshes.get(&r.cc) {
            if rec.has_buffers {
                self.gpu_free(rec.vbuf.handle);
                self.gpu_free(rec.ibuf.handle);
            }
        }
        let rec = self.meshes.entry(r.cc).or_default();
        rec.props = props;
        rec.has_buffers = false;
        if r.empty {
            rec.index_count = 0;
            return;
        }
        let vbytes_len = r.vbytes.len() as u32;
        let ibytes_len = r.ibytes.len() as u32;
        let vb = self.gpu_alloc(vbytes_len);
        let ib = self.gpu_alloc(ibytes_len);
        if vb.contents.is_null() || ib.contents.is_null() {
            let rec = self.meshes.get_mut(&r.cc).unwrap();
            rec.index_count = 0;
            return;
        }
        // SAFETY: the allocator returned contents pointing to >= vbytes_len /
        // ibytes_len of writable shared memory; we copy exactly that many bytes.
        unsafe {
            std::ptr::copy_nonoverlapping(r.vbytes.as_ptr(), vb.contents as *mut u8, vbytes_len as usize);
            std::ptr::copy_nonoverlapping(r.ibytes.as_ptr(), ib.contents as *mut u8, ibytes_len as usize);
        }
        let rec = self.meshes.get_mut(&r.cc).unwrap();
        rec.vbuf = vb;
        rec.ibuf = ib;
        rec.index_count = r.index_count;
        rec.has_buffers = true;
    }

    fn remesh_one(&mut self, cc: ChunkCoord) {
        let props = self.scan_chunk_props(cc);
        let (mr, vbytes, ibytes) = self.mesher.mesh(cc, &self.store, false);
        // Free old buffers if any.
        if let Some(rec) = self.meshes.get(&cc) {
            if rec.has_buffers {
                self.gpu_free(rec.vbuf.handle);
                self.gpu_free(rec.ibuf.handle);
            }
        }
        let rec = self.meshes.entry(cc).or_default();
        rec.props = props;
        rec.has_buffers = false;
        if mr.empty || mr.index_count == 0 {
            rec.index_count = 0;
            return;
        }
        let vb = self.gpu_alloc(mr.vertex_bytes);
        let ib = self.gpu_alloc(mr.index_bytes);
        if vb.contents.is_null() || ib.contents.is_null() {
            let rec = self.meshes.get_mut(&cc).unwrap();
            rec.index_count = 0;
            return;
        }
        // SAFETY: the allocator returned contents pointing to >= vertex_bytes /
        // index_bytes of writable shared memory; we copy exactly that many bytes.
        unsafe {
            std::ptr::copy_nonoverlapping(vbytes.as_ptr(), vb.contents as *mut u8, mr.vertex_bytes as usize);
            std::ptr::copy_nonoverlapping(ibytes.as_ptr(), ib.contents as *mut u8, mr.index_bytes as usize);
        }
        let rec = self.meshes.get_mut(&cc).unwrap();
        rec.vbuf = vb;
        rec.ibuf = ib;
        rec.index_count = mr.index_count;
        rec.has_buffers = true;
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
                        let nb = if tb == 33 { 50 } else { 33 };
                        let target = self.target;
                        self.set_block_internal(target, nb);
                        let up = IVec3 { x: target.x, y: target.y + 1, z: target.z };
                        let dn = IVec3 { x: target.x, y: target.y - 1, z: target.z };
                        let bu = self.block_at(up);
                        let bd = self.block_at(dn);
                        if bu == 33 || bu == 50 {
                            self.set_block_internal(up, nb);
                        }
                        if bd == 33 || bd == 50 {
                            self.set_block_internal(dn, nb);
                        }
                        self.fx(1, target, 0);
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

    // Representative day/night phases (in day_time's 0..1 space) used to pin the
    // sun for lighting tests. day_time feeds sun_dir as y = -sin(2*pi*t) - 0.25:
    // sin peaks at t = 0.25 (sun highest, brightest day) and bottoms at t = 0.75
    // (sun below the horizon, deepest night).
    const TIME_PHASE_DAY: f32 = 0.25;
    const TIME_PHASE_NIGHT: f32 = 0.75;

    // Invert day_time (phase = (clock * 0.00175 + 0.30) % 1.0) to the smallest
    // non-negative world_clock that yields the given phase. Mirrors the math in
    // debug_set_day_time so the pinned clock reads back as exactly `phase`.
    fn clock_for_phase(phase: f32) -> f64 {
        let p = phase.rem_euclid(1.0) as f64;
        let frac = (p - 0.30).rem_euclid(1.0);
        frac / 0.00175
    }

    // Set the day/night pin: 0 = auto (clock advances normally), 1 = always-day,
    // 2 = always-night. Driven purely by player input, never by wall-clock, so
    // the headless/sync path is untouched unless the action is sent. When a pin
    // is selected we snap the clock immediately so the change is visible without
    // waiting for the next tick; update() then holds it there each frame.
    fn set_time_mode(&mut self, mode: i32) {
        self.time_mode = mode;
        match mode {
            1 => self.world_clock = Self::clock_for_phase(Self::TIME_PHASE_DAY),
            2 => self.world_clock = Self::clock_for_phase(Self::TIME_PHASE_NIGHT),
            _ => self.time_mode = 0, // auto: leave the clock where it is
        }
    }

    // Re-pin the clock when a day/night mode is active. Called each tick after
    // the normal advance so always-day / always-night hold a fixed sun; in auto
    // mode this is a no-op and time advances as usual.
    fn apply_time_pin(&mut self) {
        match self.time_mode {
            1 => self.world_clock = Self::clock_for_phase(Self::TIME_PHASE_DAY),
            2 => self.world_clock = Self::clock_for_phase(Self::TIME_PHASE_NIGHT),
            _ => {}
        }
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
            if dist > knear_keep && dot(to_c, cam_fwd) / dist < kcull_cos {
                continue;
            }
            let mut d = bf_draw_item {
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
            };
            d.dim_saturation = self.region_sat(*cc);
            d.dim_sat_px = self.region_sat(ChunkCoord { x: cc.x + 1, y: cc.y, z: cc.z });
            d.dim_sat_pz = self.region_sat(ChunkCoord { x: cc.x, y: cc.y, z: cc.z + 1 });
            d.dim_sat_pxz = self.region_sat(ChunkCoord { x: cc.x + 1, y: cc.y, z: cc.z + 1 });
            draws.push(d);
            if dist < 120.0 {
                let props = self.meshes[cc].props.clone();
                if !props.is_empty() {
                    prop_instances.extend_from_slice(&props);
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
        let kshadow_r = 320.0f32; // must cover the renderer far shadow cascade (kShadowFarR 300) so distant shadows have casters
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

    // Full quest progression list (#42 overview). Returns total quest count.
    pub fn fill_quest_list(&self, out: &mut [bf_quest_entry]) -> u32 {
        let x = match self.extra {
            Some(x) => x,
            None => return 0,
        };
        let qs = x.quests();
        let n = qs.len() as u32;
        let cap = out.len();
        for i in 0..(n as usize).min(cap) {
            let q = &qs[i];
            let e = &mut out[i];
            *e = bf_quest_entry { title: [0; 64], objective: [0; 96], state: 0, progress: 0.0 };
            Self::cstr_copy(&mut e.title, &q.title);
            let done = self.all_quests_done || (i as u32) < self.active_quest as u32;
            let active = !self.all_quests_done && i == self.active_quest;
            e.state = if done {
                bf_quest_state::BF_QUEST_DONE as u8
            } else if active {
                bf_quest_state::BF_QUEST_ACTIVE as u8
            } else {
                bf_quest_state::BF_QUEST_UPCOMING as u8
            };
            if active && self.obj_progress.len() == q.objectives.len() {
                let mut cdone = 0u32;
                let mut total = 0u32;
                let mut objtext = "";
                for (k, o) in q.objectives.iter().enumerate() {
                    total += o.count;
                    cdone += self.obj_progress[k].min(o.count);
                    if self.obj_progress[k] < o.count && objtext.is_empty() {
                        objtext = &o.text;
                    }
                }
                Self::cstr_copy(&mut e.objective, if !objtext.is_empty() { objtext } else { "..." });
                e.progress = if total != 0 { cdone as f32 / total as f32 } else { 0.0 };
            } else {
                e.progress = if done { 1.0 } else { 0.0 };
                if !q.objectives.is_empty() {
                    Self::cstr_copy(&mut e.objective, &q.objectives[0].text);
                }
            }
        }
        n
    }

    // #41 quest-target compass.
    pub fn fill_quest_target(&self, out: &mut bf_quest_target) -> bool {
        *out = bf_quest_target { active: 0, is_boss: 0, position: bf_vec3 { x: 0.0, y: 0.0, z: 0.0 }, distance: 0.0, label: [0; 48] };
        let x = match self.extra {
            Some(x) => x,
            None => return false,
        };
        if self.all_quests_done || self.active_quest >= x.quests().len() {
            return false;
        }
        let q = &x.quests()[self.active_quest];
        if self.obj_progress.len() != q.objectives.len() {
            return false;
        }
        let mut obj = None;
        for (i, o) in q.objectives.iter().enumerate() {
            if self.obj_progress[i] >= o.count {
                continue;
            }
            if o.trigger == "befriend_creature" || o.trigger == "calm_boss" {
                obj = Some(o);
                break;
            }
        }
        let obj = match obj {
            Some(o) if !o.target.is_empty() => o,
            _ => return false,
        };
        let mut best: Option<&Creature> = None;
        let mut bestd2 = 1e30f32;
        for c in &self.creatures {
            if c.name != obj.target {
                continue;
            }
            let dx = c.pos.x - self.pos.x;
            let dy = c.pos.y - self.pos.y;
            let dz = c.pos.z - self.pos.z;
            let d2 = dx * dx + dy * dy + dz * dz;
            if d2 < bestd2 {
                bestd2 = d2;
                best = Some(c);
            }
        }
        let best = match best {
            Some(b) => b,
            None => return false,
        };
        out.active = 1;
        out.is_boss = if obj.trigger == "calm_boss" { 1 } else { 0 };
        out.position = bf_vec3 { x: best.pos.x, y: best.pos.y, z: best.pos.z };
        out.distance = bestd2.sqrt();
        // Title-case the creature name.
        let mut lbl = String::new();
        let mut up = true;
        for ch in best.name.chars() {
            if ch == '_' {
                lbl.push(' ');
                up = true;
            } else if up && ch.is_ascii_lowercase() {
                lbl.push(ch.to_ascii_uppercase());
                up = false;
            } else {
                lbl.push(ch);
                up = false;
            }
        }
        Self::cstr_copy(&mut out.label, &lbl);
        true
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
    pub fn debug_set_friendly(&mut self, i: i32) {
        if i >= 0 && i < self.creatures.len() as i32 {
            self.creatures[i as usize].friendly = true;
        }
    }
    pub fn debug_build_palisade(&mut self, cx: i32, cz: i32, cells: i32) -> i32 {
        self.build_palisade_segment(cx, cz, cells)
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
        // invert day_time: phase = (clock * 0.00175 + 0.30) % 1.0
        let p = phase.rem_euclid(1.0) as f64;
        let frac = (p - 0.30).rem_euclid(1.0);
        self.world_clock = frac / 0.00175;
    }
    pub fn debug_quests_completed(&self) -> i32 {
        self.quests_completed
    }
    pub fn debug_all_quests_done(&self) -> bool {
        self.all_quests_done
    }
    pub fn debug_regions_restored(&self) -> i32 {
        self.regions_restored
    }
    pub fn debug_active_quest(&self) -> u32 {
        match self.extra {
            Some(x) if self.active_quest < x.quests().len() && !self.all_quests_done => {
                x.quests()[self.active_quest].id
            }
            _ => 0,
        }
    }
    pub fn debug_notify(&mut self, trig: &str, target: &str) {
        self.notify_quest(trig, target);
    }
    pub fn debug_ach_toast(&self) -> &str {
        &self.ach_toast
    }
    pub fn debug_force_quest_done(&mut self) {
        self.quests_completed = 1;
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

// Bounds-checked little-endian byte cursor for the save/load formats. Mirrors the
// C++ ifstream reads; every read returns Option so a truncated file can't panic.
struct ByteReader<'a> {
    buf: &'a [u8],
    pos: usize,
}
impl<'a> ByteReader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        ByteReader { buf, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let s = self.buf.get(self.pos..self.pos + n)?;
        self.pos += n;
        Some(s)
    }
    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }
    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes(self.take(2)?.try_into().ok()?))
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
    fn i32(&mut self) -> Option<i32> {
        Some(i32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }
    fn f32(&mut self) -> Option<f32> {
        Some(f32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
}

#[cfg(test)]
mod time_mode_tests {
    use super::*;

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
}
