//! Blockfall engine C ABI, ported to Rust #[repr(C)].
//!
//! This is a faithful, byte-for-byte port of `contract/engine_c_api.h` (the
//! frozen C ABI, BF_ABI_VERSION 17). Every typedef, enum, and struct here
//! mirrors the C declaration: same field names, same types, same order. The
//! layout must match the C structs exactly so the Swift app reads the same
//! bytes whether the engine is the C++ core or this Rust port.
//!
//! Type mapping used throughout:
//!   uint8_t  -> u8      int32_t -> i32     float    -> f32
//!   uint16_t -> u16     char[N] -> [u8; N] pointers -> *mut / *const
//!   uint32_t -> u32     enums   -> #[repr(C)] enum (C int, i.e. i32)
//!   uint64_t -> u64     fn ptrs -> Option<extern "C" fn(...)>
//!
//! Enums in C are `int`-sized (4 bytes) here, matching how clang lays out the
//! header on the target. They use #[repr(i32)] to pin that.

#![allow(non_camel_case_types)]

use core::ffi::{c_char, c_void};

// ---------------------------------------------------------------------------
// ABI version
// ---------------------------------------------------------------------------

/// Bumped on ANY breaking change to the header. v17.
pub const BF_ABI_VERSION: u32 = 17;

// ---------------------------------------------------------------------------
// Primitive types
// ---------------------------------------------------------------------------

/// 0 = false, 1 = true.
pub type bf_bool = u8;
/// Opaque, engine-assigned; 0 = invalid/none.
pub type bf_handle = u64;
pub type bf_block_id = u16;
pub type bf_item_id = u16;

/// Row-major (stored as the renderer doc specifies) 4x4 matrix.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_mat4 {
    pub m: [f32; 16],
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_ivec3 {
    pub x: i32,
    pub y: i32,
    pub z: i32,
}

// ---------------------------------------------------------------------------
// Opaque engine handle
// ---------------------------------------------------------------------------

/// Opaque engine pointer (struct bf_engine_s* in C). Represented as the
/// pointer width; the inner type is never dereferenced across the ABI.
#[repr(C)]
pub struct bf_engine_s {
    _private: [u8; 0],
}
pub type bf_engine = *mut bf_engine_s;

// ---------------------------------------------------------------------------
// 1. LIFECYCLE
// ---------------------------------------------------------------------------

/// Result codes. Non-zero = failure.
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum bf_result {
    BF_OK = 0,
    BF_ERR_ABI_MISMATCH = 1,
    BF_ERR_BAD_ARG = 2,
    BF_ERR_IO = 3,
    BF_ERR_CORRUPT_SAVE = 4,
    BF_ERR_CONTENT_INVALID = 5,
    BF_ERR_OUT_OF_MEMORY = 6,
    BF_ERR_NET = 7,
    BF_ERR_NOT_READY = 8,
    BF_ERR_INTERNAL = 99,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum bf_game_mode {
    BF_MODE_SURVIVAL = 0,
    BF_MODE_CREATIVE = 1,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum bf_session_role {
    BF_ROLE_SINGLEPLAYER = 0,
    BF_ROLE_HOST = 1,
    BF_ROLE_CLIENT = 2,
}

/// Memory/feel knobs. Defaults must be Air-safe.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct bf_engine_config {
    pub abi_version: u32,
    pub world_seed: u64,
    pub role: bf_session_role,
    pub start_mode: bf_game_mode,
    pub render_distance_chunks: u32,
    pub memory_budget_bytes: u64,
    pub content_dir: *const c_char,
    pub save_dir: *const c_char,
    pub player_name: *const c_char,
}

// ---------------------------------------------------------------------------
// 2. FRAME TICK
// ---------------------------------------------------------------------------

/// Per-frame input snapshot, sampled by the engine.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_frame_input {
    pub move_forward: f32,
    pub move_strafe: f32,
    pub look_yaw_delta: f32,
    pub look_pitch_delta: f32,
    pub jump: bf_bool,
    pub sneak: bf_bool,
    pub sprint: bf_bool,
    pub fly_ascend: bf_bool,
    pub fly_descend: bf_bool,
    pub _pad: [u8; 3],
}

// ---------------------------------------------------------------------------
// 3. DISCRETE INPUT / ACTIONS
// ---------------------------------------------------------------------------

#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum bf_action_kind {
    BF_ACT_MINE_START = 0,
    BF_ACT_MINE_STOP = 1,
    BF_ACT_PLACE = 2,
    BF_ACT_INTERACT = 3,
    BF_ACT_HOTBAR_SELECT = 4,
    BF_ACT_HOTBAR_SCROLL = 5,
    BF_ACT_INV_OPEN = 6,
    BF_ACT_INV_CLOSE = 7,
    BF_ACT_INV_MOVE = 8,
    BF_ACT_CRAFT = 9,
    BF_ACT_DROP_ITEM = 10,
    BF_ACT_MODE_TOGGLE = 11,
    BF_ACT_ATTACK = 12,
    BF_ACT_GIVE_ITEM = 13,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_action {
    pub kind: bf_action_kind,
    pub arg_i: i32,
    pub arg_j: i32,
    pub arg_k: i32,
}

// ---------------------------------------------------------------------------
// 4. RENDER DATA HANDOFF
// ---------------------------------------------------------------------------

/// One draw: a chunk mesh (or other batch) resident in a GPU buffer.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_draw_item {
    pub vertex_buffer: bf_handle,
    pub index_buffer: bf_handle,
    pub vertex_offset: u32,
    pub index_offset: u32,
    pub index_count: u32,
    pub material_id: u32,
    pub chunk_origin: bf_ivec3,
    pub dim_saturation: f32,
    pub dim_sat_px: f32,
    pub dim_sat_pz: f32,
    pub dim_sat_pxz: f32,
}

/// Per-region restoration state for the Dim->colour blend.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_region_dim {
    pub region_coord: bf_ivec3,
    pub saturation: f32,
    pub fog_density: f32,
}

/// One creature/entity to draw (ABI v2).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_entity_draw {
    pub position: bf_vec3,
    pub yaw: f32,
    pub color: bf_vec3,
    pub scale: f32,
    pub kind: u32,
    pub sat: f32,
    pub _pad: u32,
}

/// One decorative prop drawn as a detailed small-cuboid toy model (#51).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_prop_instance {
    pub position: bf_vec3,
    pub type_: u32,
    pub seed: u32,
    pub sat: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_camera {
    pub view: bf_mat4,
    pub proj: bf_mat4,
    pub position: bf_vec3,
    pub biome_cold: f32,
    pub forward: bf_vec3,
    pub time_of_day: f32,
    pub sun_dir: bf_vec3,
    pub underwater: f32,
    pub weather: f32,
    pub underground: f32,
    pub local_sat: f32,
}

// ---- HUD state ------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_hud_slot {
    pub item: bf_item_id,
    pub count: u16,
    pub durability: u16,
    pub _pad: u16,
}

pub const BF_HOTBAR_SLOTS: usize = 9;
pub const BF_INVENTORY_SLOTS: usize = 36;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct bf_hud_state {
    pub mode: bf_game_mode,
    pub selected_slot: u8,
    pub inventory_open: u8,
    pub health: f32,
    pub hunger: f32,
    pub hotbar: [bf_hud_slot; BF_HOTBAR_SLOTS],
    pub inventory: [bf_hud_slot; BF_INVENTORY_SLOTS],
    pub active_quest_id: u32,
    pub quest_title: [u8; 64],
    pub quest_objective: [u8; 96],
    pub quest_progress: f32,
    pub has_target: bf_bool,
    pub target_block: bf_ivec3,
    pub mine_progress: f32,
    pub craftable: [bf_hud_slot; 24],
    pub craftable_count: u8,
    pub oxygen: f32,
    pub look_name: [u8; 40],
    pub achievement_toast: [u8; 48],
    pub achievements_done: u8,
    pub achievements_total: u8,
    pub weather: u8,
    pub biome_name: [u8; 24],
    pub in_dim: u8,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum bf_quest_state {
    BF_QUEST_UPCOMING = 0,
    BF_QUEST_ACTIVE = 1,
    BF_QUEST_DONE = 2,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct bf_quest_entry {
    pub title: [u8; 64],
    pub objective: [u8; 96],
    pub state: u8,
    pub progress: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct bf_quest_target {
    pub active: u8,
    pub is_boss: u8,
    pub position: bf_vec3,
    pub distance: f32,
    pub label: [u8; 48],
}

/// The whole frame, borrowed from the engine between acquire/end.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct bf_render_frame {
    pub camera: bf_camera,
    pub interp_alpha: f32,
    pub draws: *const bf_draw_item,
    pub draw_count: u32,
    pub regions: *const bf_region_dim,
    pub region_count: u32,
    pub entities: *const bf_entity_draw,
    pub entity_count: u32,
    pub hud: bf_hud_state,
    pub shadow_draws: *const bf_draw_item,
    pub shadow_draw_count: u32,
    pub prop_instances: *const bf_prop_instance,
    pub prop_instance_count: u32,
}

// ---------------------------------------------------------------------------
// 5. GPU BUFFER ALLOCATOR
// ---------------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_gpu_buffer {
    pub handle: bf_handle,
    pub contents: *mut c_void,
    pub bytes: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct bf_gpu_allocator {
    /// Opaque Swift context (e.g. the Renderer).
    pub user: *mut c_void,
    /// Allocate >= bytes of storageModeShared memory. Thread-safe.
    pub alloc: Option<extern "C" fn(user: *mut c_void, bytes: u32) -> bf_gpu_buffer>,
    /// Return a buffer for reuse/free.
    pub free_: Option<extern "C" fn(user: *mut c_void, handle: bf_handle)>,
}

// ---------------------------------------------------------------------------
// 6. EVENT CALLBACKS
// ---------------------------------------------------------------------------

#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum bf_event_kind {
    BF_EVT_BLOCK_BROKEN = 0,
    BF_EVT_BLOCK_PLACED = 1,
    BF_EVT_SFX = 2,
    BF_EVT_QUEST_UPDATED = 3,
    BF_EVT_QUEST_COMPLETE = 4,
    BF_EVT_CREATURE_CALMED = 5,
    BF_EVT_REGION_RESTORED = 6,
    BF_EVT_PEER_JOINED = 7,
    BF_EVT_PEER_LEFT = 8,
    BF_EVT_SAVE_DONE = 9,
    BF_EVT_ERROR = 10,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct bf_event {
    pub kind: bf_event_kind,
    pub i: i32,
    pub j: i32,
    pub pos: bf_ivec3,
    pub fx: f32,
    pub fy: f32,
    pub fz: f32,
}

/// Event sink: void (*bf_event_fn)(void* user, const bf_event* ev).
pub type bf_event_fn = Option<extern "C" fn(user: *mut c_void, ev: *const bf_event)>;

// ===========================================================================
// Parity tests: assert size_of / offset_of match the C golden values.
// Golden values captured from `clang -I contract dump.c` on the target.
// ===========================================================================

#[cfg(test)]
mod parity {
    use super::*;
    use core::mem::{align_of, offset_of, size_of};

    #[test]
    fn sizes_match_c() {
        assert_eq!(size_of::<bf_mat4>(), 64, "bf_mat4");
        assert_eq!(size_of::<bf_vec3>(), 12, "bf_vec3");
        assert_eq!(size_of::<bf_ivec3>(), 12, "bf_ivec3");
        assert_eq!(size_of::<bf_engine_config>(), 64, "bf_engine_config");
        assert_eq!(size_of::<bf_frame_input>(), 24, "bf_frame_input");
        assert_eq!(size_of::<bf_action>(), 16, "bf_action");
        assert_eq!(size_of::<bf_draw_item>(), 64, "bf_draw_item");
        assert_eq!(size_of::<bf_region_dim>(), 20, "bf_region_dim");
        assert_eq!(size_of::<bf_entity_draw>(), 44, "bf_entity_draw");
        assert_eq!(size_of::<bf_prop_instance>(), 24, "bf_prop_instance");
        assert_eq!(size_of::<bf_camera>(), 188, "bf_camera");
        assert_eq!(size_of::<bf_hud_slot>(), 8, "bf_hud_slot");
        assert_eq!(size_of::<bf_hud_state>(), 880, "bf_hud_state");
        assert_eq!(size_of::<bf_quest_entry>(), 168, "bf_quest_entry");
        assert_eq!(size_of::<bf_quest_target>(), 68, "bf_quest_target");
        assert_eq!(size_of::<bf_render_frame>(), 1152, "bf_render_frame");
        assert_eq!(size_of::<bf_gpu_buffer>(), 24, "bf_gpu_buffer");
        assert_eq!(size_of::<bf_gpu_allocator>(), 24, "bf_gpu_allocator");
        assert_eq!(size_of::<bf_event>(), 36, "bf_event");
    }

    #[test]
    fn alignments_match_c() {
        assert_eq!(align_of::<bf_engine_config>(), 8, "bf_engine_config");
        assert_eq!(align_of::<bf_frame_input>(), 4, "bf_frame_input");
        assert_eq!(align_of::<bf_draw_item>(), 8, "bf_draw_item");
        assert_eq!(align_of::<bf_entity_draw>(), 4, "bf_entity_draw");
        assert_eq!(align_of::<bf_camera>(), 4, "bf_camera");
        assert_eq!(align_of::<bf_hud_state>(), 4, "bf_hud_state");
        assert_eq!(align_of::<bf_render_frame>(), 8, "bf_render_frame");
    }

    #[test]
    fn engine_config_offsets() {
        assert_eq!(offset_of!(bf_engine_config, abi_version), 0);
        assert_eq!(offset_of!(bf_engine_config, world_seed), 8);
        assert_eq!(offset_of!(bf_engine_config, role), 16);
        assert_eq!(offset_of!(bf_engine_config, start_mode), 20);
        assert_eq!(offset_of!(bf_engine_config, render_distance_chunks), 24);
        assert_eq!(offset_of!(bf_engine_config, memory_budget_bytes), 32);
        assert_eq!(offset_of!(bf_engine_config, content_dir), 40);
        assert_eq!(offset_of!(bf_engine_config, save_dir), 48);
        assert_eq!(offset_of!(bf_engine_config, player_name), 56);
    }

    #[test]
    fn frame_input_offsets() {
        assert_eq!(offset_of!(bf_frame_input, move_forward), 0);
        assert_eq!(offset_of!(bf_frame_input, move_strafe), 4);
        assert_eq!(offset_of!(bf_frame_input, look_yaw_delta), 8);
        assert_eq!(offset_of!(bf_frame_input, look_pitch_delta), 12);
        assert_eq!(offset_of!(bf_frame_input, jump), 16);
        assert_eq!(offset_of!(bf_frame_input, sneak), 17);
        assert_eq!(offset_of!(bf_frame_input, sprint), 18);
        assert_eq!(offset_of!(bf_frame_input, fly_ascend), 19);
        assert_eq!(offset_of!(bf_frame_input, fly_descend), 20);
        assert_eq!(offset_of!(bf_frame_input, _pad), 21);
    }

    #[test]
    fn draw_item_offsets() {
        assert_eq!(offset_of!(bf_draw_item, vertex_buffer), 0);
        assert_eq!(offset_of!(bf_draw_item, index_buffer), 8);
        assert_eq!(offset_of!(bf_draw_item, vertex_offset), 16);
        assert_eq!(offset_of!(bf_draw_item, index_offset), 20);
        assert_eq!(offset_of!(bf_draw_item, index_count), 24);
        assert_eq!(offset_of!(bf_draw_item, material_id), 28);
        assert_eq!(offset_of!(bf_draw_item, chunk_origin), 32);
        assert_eq!(offset_of!(bf_draw_item, dim_saturation), 44);
        assert_eq!(offset_of!(bf_draw_item, dim_sat_px), 48);
        assert_eq!(offset_of!(bf_draw_item, dim_sat_pz), 52);
        assert_eq!(offset_of!(bf_draw_item, dim_sat_pxz), 56);
    }

    #[test]
    fn entity_draw_offsets() {
        assert_eq!(offset_of!(bf_entity_draw, position), 0);
        assert_eq!(offset_of!(bf_entity_draw, yaw), 12);
        assert_eq!(offset_of!(bf_entity_draw, color), 16);
        assert_eq!(offset_of!(bf_entity_draw, scale), 28);
        assert_eq!(offset_of!(bf_entity_draw, kind), 32);
        assert_eq!(offset_of!(bf_entity_draw, sat), 36);
        assert_eq!(offset_of!(bf_entity_draw, _pad), 40);
    }

    #[test]
    fn camera_offsets() {
        assert_eq!(offset_of!(bf_camera, view), 0);
        assert_eq!(offset_of!(bf_camera, proj), 64);
        assert_eq!(offset_of!(bf_camera, position), 128);
        assert_eq!(offset_of!(bf_camera, biome_cold), 140);
        assert_eq!(offset_of!(bf_camera, forward), 144);
        assert_eq!(offset_of!(bf_camera, time_of_day), 156);
        assert_eq!(offset_of!(bf_camera, sun_dir), 160);
        assert_eq!(offset_of!(bf_camera, underwater), 172);
        assert_eq!(offset_of!(bf_camera, weather), 176);
        assert_eq!(offset_of!(bf_camera, underground), 180);
        assert_eq!(offset_of!(bf_camera, local_sat), 184);
    }

    #[test]
    fn hud_state_offsets() {
        assert_eq!(offset_of!(bf_hud_state, mode), 0);
        assert_eq!(offset_of!(bf_hud_state, selected_slot), 4);
        assert_eq!(offset_of!(bf_hud_state, inventory_open), 5);
        assert_eq!(offset_of!(bf_hud_state, health), 8);
        assert_eq!(offset_of!(bf_hud_state, hunger), 12);
        assert_eq!(offset_of!(bf_hud_state, hotbar), 16);
        assert_eq!(offset_of!(bf_hud_state, inventory), 88);
        assert_eq!(offset_of!(bf_hud_state, active_quest_id), 376);
        assert_eq!(offset_of!(bf_hud_state, quest_title), 380);
        assert_eq!(offset_of!(bf_hud_state, quest_objective), 444);
        assert_eq!(offset_of!(bf_hud_state, quest_progress), 540);
        assert_eq!(offset_of!(bf_hud_state, has_target), 544);
        assert_eq!(offset_of!(bf_hud_state, target_block), 548);
        assert_eq!(offset_of!(bf_hud_state, mine_progress), 560);
        assert_eq!(offset_of!(bf_hud_state, craftable), 564);
        assert_eq!(offset_of!(bf_hud_state, craftable_count), 756);
        assert_eq!(offset_of!(bf_hud_state, oxygen), 760);
        assert_eq!(offset_of!(bf_hud_state, look_name), 764);
        assert_eq!(offset_of!(bf_hud_state, achievement_toast), 804);
        assert_eq!(offset_of!(bf_hud_state, achievements_done), 852);
        assert_eq!(offset_of!(bf_hud_state, achievements_total), 853);
        assert_eq!(offset_of!(bf_hud_state, weather), 854);
        assert_eq!(offset_of!(bf_hud_state, biome_name), 855);
        assert_eq!(offset_of!(bf_hud_state, in_dim), 879);
    }

    #[test]
    fn render_frame_offsets() {
        assert_eq!(offset_of!(bf_render_frame, camera), 0);
        assert_eq!(offset_of!(bf_render_frame, interp_alpha), 188);
        assert_eq!(offset_of!(bf_render_frame, draws), 192);
        assert_eq!(offset_of!(bf_render_frame, draw_count), 200);
        assert_eq!(offset_of!(bf_render_frame, regions), 208);
        assert_eq!(offset_of!(bf_render_frame, region_count), 216);
        assert_eq!(offset_of!(bf_render_frame, entities), 224);
        assert_eq!(offset_of!(bf_render_frame, entity_count), 232);
        assert_eq!(offset_of!(bf_render_frame, hud), 236);
        assert_eq!(offset_of!(bf_render_frame, shadow_draws), 1120);
        assert_eq!(offset_of!(bf_render_frame, shadow_draw_count), 1128);
        assert_eq!(offset_of!(bf_render_frame, prop_instances), 1136);
        assert_eq!(offset_of!(bf_render_frame, prop_instance_count), 1144);
    }
}
