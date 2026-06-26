//! bfcore: the `bf_*` C ABI implementation (the Swift app's only entry point).
//!
//! This is a faithful Rust port of `engine/src/engine_stub.cpp`, implementing
//! every function declared in the frozen `contract/engine_c_api.h` as a
//! `#[no_mangle] pub extern "C"` symbol. It wraps the pure-Rust `world::World`
//! sim behind the same POD ABI the C++ core exposes, so the Swift/Metal app can
//! link `libbfcore.a` in place of `libblockcore.a` with no source changes.
//!
//! Networking (co-op) is intentionally stubbed out (returns BF_ERR_NET): the
//! single-player path is the swap-in target; the UDP transport is a later port.
//!
//! ## Ownership and the self-reference problem
//!
//! `world::World<'c>` borrows `&'c ContentRegistry` + `&'c ContentExtra` for its
//! whole lifetime (it mirrors the C++ `const ContentRegistry*`). The engine must
//! own those, AND own the `World` that borrows them, in one struct. That is the
//! classic self-referential-struct problem.
//!
//! We solve it the standard FFI way: the content, extra, and worldgen live in
//! `Box`es (so their addresses are stable for the life of the `Engine`), and the
//! `World` is built borrowing them with the borrow lifetime widened to `'static`
//! via a single documented `unsafe` transmute. This is sound because:
//!   - the boxes are never moved or reallocated after construction (they sit
//!     behind a stable heap pointer), and
//!   - we control drop order: `world` is wrapped in `ManuallyDrop` and dropped
//!     FIRST in an explicit `Drop for Engine`, before the boxes it borrows. So
//!     the `World` never outlives the data it points at.
//! The transmuted references are only ever observed by the `World` itself, which
//! cannot outlive the `Engine`, so no `'static` reference escapes.

#![allow(clippy::missing_safety_doc)]

use core::ffi::{c_char, c_void};
use std::cell::RefCell;
use std::ffi::CStr;
use std::mem::ManuallyDrop;

use crate::abi::*;
use crate::content::{ContentExtra, ContentRegistry};
use crate::types::IVec3;
use crate::world::World;
use crate::worldgen::TerrainGen;

// ---------------------------------------------------------------------------
// Error strings (mirror the C++ thread_local + global).
// ---------------------------------------------------------------------------

thread_local! {
    /// Most recent failed call on this thread. Mirrors C++ `thread_local std::string`.
    static T_LAST_ERROR: RefCell<std::ffi::CString> =
        RefCell::new(std::ffi::CString::new("ok").unwrap());
}

/// Create-time error (used by bf_engine_create, read via bf_last_error_global).
/// Single-threaded create path, like the C++ global std::string.
static mut G_CREATE_ERROR: Option<std::ffi::CString> = None;

fn set_err(m: &str) {
    let c = std::ffi::CString::new(m).unwrap_or_else(|_| std::ffi::CString::new("err").unwrap());
    T_LAST_ERROR.with(|e| *e.borrow_mut() = c);
}

fn set_create_err(m: &str) {
    let c = std::ffi::CString::new(m).unwrap_or_else(|_| std::ffi::CString::new("err").unwrap());
    // SAFETY: bf_engine_create is [MAIN]-only (single thread), matching the C++
    // non-atomic global. No concurrent access. Use a raw pointer write to avoid
    // forming a reference to the mutable static.
    unsafe { core::ptr::write(core::ptr::addr_of_mut!(G_CREATE_ERROR), Some(c)) };
}

// ---------------------------------------------------------------------------
// The engine: the Rust analogue of `struct bf_engine_s`.
// ---------------------------------------------------------------------------

/// Owns the content/extra/worldgen (boxed for stable addresses) and the `World`
/// that borrows them. See the module docs for the lifetime/drop-order argument.
struct Engine {
    cfg: bf_engine_config,

    // Boxed so their heap address is stable for the World's borrow. Never moved
    // or reallocated after construction. Held only as owning anchors for the
    // 'static borrows inside `world`; not read directly (hence dead_code).
    #[allow(dead_code)]
    content: Box<ContentRegistry>,
    #[allow(dead_code)]
    extra: Box<ContentExtra>,
    #[allow(dead_code)]
    worldgen: Box<TerrainGen>, // owned for symmetry with the C++; World owns its own gen copy

    /// The sim. Borrows `content`/`extra` with the borrow widened to `'static`
    /// (see module docs). Dropped FIRST via the explicit Drop impl below.
    world: ManuallyDrop<World<'static>>,
    world_ready: bool,
    clock: f64,

    evt_fn: bf_event_fn,
    evt_user: *mut c_void,

    // Backing storage for the borrowed render frame. The bf_render_frame handed
    // to Swift points INTO these vectors; they must stay alive (and not realloc)
    // for the whole acquire..end borrow, so we cache them on the Engine.
    draws: Vec<bf_draw_item>,
    shadow_draws: Vec<bf_draw_item>,
    prop_instances: Vec<bf_prop_instance>,
    frame: bf_render_frame,
    borrowed: bool,
}

impl Drop for Engine {
    fn drop(&mut self) {
        // Drop the World (and the 'static borrows it holds) BEFORE the boxes it
        // borrows from. After this, the boxes drop normally in field order.
        // SAFETY: world is live (constructed in bf_engine_create) and dropped
        // exactly once here.
        unsafe { ManuallyDrop::drop(&mut self.world) };
    }
}

fn empty_frame() -> bf_render_frame {
    // All-zero is a valid initial frame (the C++ uses `bf_render_frame f{}`).
    // SAFETY: bf_render_frame is a #[repr(C)] POD whose all-zero bit pattern is
    // valid (null pointers, zero counts, zeroed camera/hud).
    unsafe { core::mem::zeroed() }
}

// ---------------------------------------------------------------------------
// 1. LIFECYCLE
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn bf_abi_version() -> u32 {
    BF_ABI_VERSION
}

#[no_mangle]
pub unsafe extern "C" fn bf_engine_create(
    cfg: *const bf_engine_config,
    out_err: *mut bf_result,
) -> bf_engine {
    let fail = |r: bf_result, m: &str, out_err: *mut bf_result| -> bf_engine {
        set_create_err(m);
        if !out_err.is_null() {
            unsafe { *out_err = r };
        }
        std::ptr::null_mut()
    };

    if cfg.is_null() {
        return fail(bf_result::BF_ERR_BAD_ARG, "null config", out_err);
    }
    let cfg = unsafe { *cfg };
    if cfg.abi_version != BF_ABI_VERSION {
        return fail(bf_result::BF_ERR_ABI_MISMATCH, "ABI version mismatch", out_err);
    }

    // Resolve the content dir (default "." like the C++).
    let content_dir = cstr_or(cfg.content_dir, ".");

    // Build the owned pieces on the heap (stable addresses for the World borrow).
    let mut content = Box::new(ContentRegistry::new());
    content.load(&content_dir);
    let mut extra = Box::new(ContentExtra::new());
    extra.load(&content_dir);
    let worldgen = Box::new(TerrainGen::new());

    // Construct the World borrowing the boxed content/extra. The C++ World ctor
    // takes (IMesher&, IWorldGen*); the Rust World owns its mesher and an
    // optional TerrainGen, so we hand it a fresh gen here.
    let mut world = World::new(Some(TerrainGen::new()));
    world.set_mode(cfg.start_mode);

    // Widen the borrows to 'static. SOUND because the Engine owns `content`/
    // `extra` in boxes that outlive `world` (Drop drops `world` first), and the
    // boxes are never moved after this point. See module docs.
    let content_ref: &'static ContentRegistry =
        unsafe { &*(content.as_ref() as *const ContentRegistry) };
    let extra_ref: &'static ContentExtra =
        unsafe { &*(extra.as_ref() as *const ContentExtra) };
    world.set_content(content_ref);
    world.set_extra(extra_ref);

    let mut cfg = cfg;
    if cfg.render_distance_chunks == 0 {
        cfg.render_distance_chunks = 10;
    }

    let engine = Box::new(Engine {
        cfg,
        content,
        extra,
        worldgen,
        world: ManuallyDrop::new(world),
        world_ready: false,
        clock: 0.0,
        evt_fn: None,
        evt_user: std::ptr::null_mut(),
        draws: Vec::new(),
        shadow_draws: Vec::new(),
        prop_instances: Vec::new(),
        frame: empty_frame(),
        borrowed: false,
    });
    let raw = Box::into_raw(engine);

    // Forward gameplay fx (audio/particles) to the app's event callback. The
    // closure captures the raw engine pointer; it is only ever called while the
    // Engine is alive (the World, which fires it, is dropped before the Engine).
    // Mirrors the C++ set_fx_callback lambda that emits a BF_EVT_SFX.
    // SAFETY: `raw` points at a live, pinned Engine for the whole World lifetime.
    {
        let e: &mut Engine = unsafe { &mut *raw };
        e.world.set_fx_callback(Box::new(move |code: i32, p: IVec3, extra: i32| {
            // SAFETY: see above; `raw` is live whenever the World fires fx.
            let e: &Engine = unsafe { &*raw };
            if let Some(fn_) = e.evt_fn {
                let ev = bf_event {
                    kind: bf_event_kind::BF_EVT_SFX,
                    i: code,
                    j: extra,
                    pos: bf_ivec3 { x: p.x, y: p.y, z: p.z },
                    fx: 0.0,
                    fy: 0.0,
                    fz: 0.0,
                };
                fn_(e.evt_user, &ev as *const bf_event);
            }
        }));
    }

    set_create_err("ok");
    if !out_err.is_null() {
        unsafe { *out_err = bf_result::BF_OK };
    }
    raw as bf_engine
}

#[no_mangle]
pub unsafe extern "C" fn bf_engine_destroy(e: bf_engine) {
    if e.is_null() {
        return;
    }
    // Reclaim ownership and drop (runs Drop for Engine -> drops World, then boxes).
    let _ = unsafe { Box::from_raw(e as *mut Engine) };
}

#[no_mangle]
pub extern "C" fn bf_last_error(_e: bf_engine) -> *const c_char {
    T_LAST_ERROR.with(|er| er.borrow().as_ptr())
}

#[no_mangle]
pub extern "C" fn bf_last_error_global() -> *const c_char {
    // SAFETY: single-threaded create path; initialized lazily below. Access via
    // raw pointer to avoid forming a reference to the mutable static.
    unsafe {
        let p = core::ptr::addr_of_mut!(G_CREATE_ERROR);
        if (*p).is_none() {
            core::ptr::write(p, Some(std::ffi::CString::new("ok").unwrap()));
        }
        (*p).as_ref().unwrap().as_ptr()
    }
}

#[no_mangle]
pub unsafe extern "C" fn bf_world_new(e: bf_engine, seed: u64) -> bf_result {
    let e = match engine_mut(e) {
        Some(e) => e,
        None => {
            set_err("null engine");
            return bf_result::BF_ERR_BAD_ARG;
        }
    };
    let s = if seed != 0 {
        seed
    } else if e.cfg.world_seed != 0 {
        e.cfg.world_seed
    } else {
        1337
    };
    e.cfg.world_seed = s;
    e.world.set_render_distance(e.cfg.render_distance_chunks as i32);
    e.world.init_world(s);
    e.world_ready = true;
    bf_result::BF_OK
}

#[no_mangle]
pub unsafe extern "C" fn bf_world_load(e: bf_engine) -> bf_result {
    let e = match engine_mut(e) {
        Some(e) => e,
        None => {
            set_err("null engine");
            return bf_result::BF_ERR_BAD_ARG;
        }
    };
    let dir = cstr_or(e.cfg.save_dir, "");
    e.world.set_render_distance(e.cfg.render_distance_chunks as i32);
    if !e.world.load(&dir) {
        let seed = if e.cfg.world_seed != 0 { e.cfg.world_seed } else { 1337 };
        e.world.init_world(seed);
    }
    e.world_ready = true;
    bf_result::BF_OK
}

#[no_mangle]
pub unsafe extern "C" fn bf_world_save(e: bf_engine) -> bf_result {
    let e = match engine_mut(e) {
        Some(e) => e,
        None => {
            set_err("null engine");
            return bf_result::BF_ERR_BAD_ARG;
        }
    };
    let dir = cstr_or(e.cfg.save_dir, "");
    let ok = e.world.save(&dir);
    if let Some(fn_) = e.evt_fn {
        let ev = bf_event {
            kind: bf_event_kind::BF_EVT_SAVE_DONE,
            i: if ok { 0 } else { 1 },
            j: 0,
            pos: bf_ivec3 { x: 0, y: 0, z: 0 },
            fx: 0.0,
            fy: 0.0,
            fz: 0.0,
        };
        fn_(e.evt_user, &ev as *const bf_event);
    }
    if ok {
        bf_result::BF_OK
    } else {
        bf_result::BF_ERR_IO
    }
}

// ---------------------------------------------------------------------------
// 2. FRAME TICK
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bf_frame_begin(
    e: bf_engine,
    input: *const bf_frame_input,
    real_dt: f64,
) -> bf_result {
    let e = match engine_mut(e) {
        Some(e) => e,
        None => {
            set_err("null arg");
            return bf_result::BF_ERR_BAD_ARG;
        }
    };
    if input.is_null() {
        set_err("null arg");
        return bf_result::BF_ERR_BAD_ARG;
    }
    let input = unsafe { *input };
    e.clock += real_dt;
    if e.world_ready {
        e.world.update(&input, real_dt);
    }
    // NET: transport/session are not ported (single-player swap-in). No-op.
    bf_result::BF_OK
}

#[no_mangle]
pub unsafe extern "C" fn bf_frame_acquire_render(
    e: bf_engine,
    out: *mut bf_render_frame,
) -> bf_result {
    let e = match engine_mut(e) {
        Some(e) => e,
        None => {
            set_err("null arg");
            return bf_result::BF_ERR_BAD_ARG;
        }
    };
    if out.is_null() {
        set_err("null arg");
        return bf_result::BF_ERR_BAD_ARG;
    }
    // Double-acquire: hand back the SAME already-built frame. Rebuilding would
    // realloc e.draws/etc and dangle the pointers a prior acquire gave Swift.
    // (Mirrors the C++ borrowed-frame guard verbatim.)
    if e.borrowed {
        unsafe { *out = e.frame };
        return bf_result::BF_OK;
    }
    e.frame = empty_frame();
    // build_frame writes the draws/shadow_draws/props vectors AND sets the
    // bf_render_frame pointers to point into them. The vectors live on the
    // Engine, so the pointers stay valid until the next rebuild (after end).
    e.world.build_frame(
        &mut e.frame,
        &mut e.draws,
        &mut e.shadow_draws,
        &mut e.prop_instances,
        e.clock,
    );
    e.borrowed = true;
    unsafe { *out = e.frame };
    bf_result::BF_OK
}

#[no_mangle]
pub unsafe extern "C" fn bf_frame_end(e: bf_engine) {
    if let Some(e) = engine_mut(e) {
        e.borrowed = false;
    }
}

#[no_mangle]
pub unsafe extern "C" fn bf_quest_list(
    e: bf_engine,
    out: *mut bf_quest_entry,
    cap: u32,
) -> u32 {
    let e = match engine_ref(e) {
        Some(e) => e,
        None => return 0,
    };
    if !e.world_ready {
        return 0;
    }
    let cap = if out.is_null() { 0 } else { cap };
    if cap == 0 {
        // Still return the total count (fill_quest_list takes a slice; an empty
        // slice yields the count with nothing written).
        return e.world.fill_quest_list(&mut []);
    }
    // SAFETY: caller guarantees `out` points at `cap` writable bf_quest_entry.
    let slice = unsafe { std::slice::from_raw_parts_mut(out, cap as usize) };
    e.world.fill_quest_list(slice)
}

#[no_mangle]
pub unsafe extern "C" fn bf_quest_target_get(e: bf_engine, out: *mut bf_quest_target) -> u8 {
    let e = match engine_ref(e) {
        Some(e) => e,
        None => return 0,
    };
    if !e.world_ready || out.is_null() {
        return 0;
    }
    // SAFETY: caller guarantees `out` is a writable bf_quest_target.
    let out = unsafe { &mut *out };
    if e.world.fill_quest_target(out) {
        1
    } else {
        0
    }
}

// ---------------------------------------------------------------------------
// 3. DISCRETE INPUT / ACTIONS
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bf_input_action(e: bf_engine, act: *const bf_action) -> bf_result {
    let e = match engine_mut(e) {
        Some(e) => e,
        None => {
            set_err("null arg");
            return bf_result::BF_ERR_BAD_ARG;
        }
    };
    if act.is_null() {
        set_err("null arg");
        return bf_result::BF_ERR_BAD_ARG;
    }
    if !e.world_ready {
        set_err("world not ready");
        return bf_result::BF_ERR_NOT_READY;
    }
    let act = unsafe { *act };
    e.world.action(&act);
    if let Some(fn_) = e.evt_fn {
        if act.kind == bf_action_kind::BF_ACT_PLACE
            || act.kind == bf_action_kind::BF_ACT_MINE_STOP
        {
            let kind = if act.kind == bf_action_kind::BF_ACT_PLACE {
                bf_event_kind::BF_EVT_BLOCK_PLACED
            } else {
                bf_event_kind::BF_EVT_BLOCK_BROKEN
            };
            let ev = bf_event {
                kind,
                i: 0,
                j: 0,
                pos: bf_ivec3 { x: 0, y: 0, z: 0 },
                fx: 0.0,
                fy: 0.0,
                fz: 0.0,
            };
            fn_(e.evt_user, &ev as *const bf_event);
        }
    }
    bf_result::BF_OK
}

// ---------------------------------------------------------------------------
// 5. GPU BUFFER ALLOCATOR
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bf_set_gpu_allocator(
    e: bf_engine,
    a: *const bf_gpu_allocator,
) -> bf_result {
    let e = match engine_mut(e) {
        Some(e) => e,
        None => {
            set_err("null arg");
            return bf_result::BF_ERR_BAD_ARG;
        }
    };
    if a.is_null() {
        set_err("null arg");
        return bf_result::BF_ERR_BAD_ARG;
    }
    e.world.set_allocator(unsafe { *a });
    bf_result::BF_OK
}

// ---------------------------------------------------------------------------
// 6. EVENT CALLBACKS
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bf_set_event_callback(
    e: bf_engine,
    fn_: bf_event_fn,
    user: *mut c_void,
) -> bf_result {
    let e = match engine_mut(e) {
        Some(e) => e,
        None => {
            set_err("null engine");
            return bf_result::BF_ERR_BAD_ARG;
        }
    };
    e.evt_fn = fn_;
    e.evt_user = user;
    bf_result::BF_OK
}

// ---------------------------------------------------------------------------
// 7. NETWORK (co-op) — stubbed for the single-player swap-in.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bf_net_host_start(e: bf_engine, _port: u16) -> bf_result {
    if e.is_null() {
        return bf_result::BF_ERR_BAD_ARG;
    }
    // Co-op transport is a later port. Single-player only for now.
    bf_result::BF_ERR_NET
}

#[no_mangle]
pub unsafe extern "C" fn bf_net_client_connect(
    e: bf_engine,
    host: *const c_char,
    _port: u16,
) -> bf_result {
    if e.is_null() || host.is_null() {
        return bf_result::BF_ERR_BAD_ARG;
    }
    bf_result::BF_ERR_NET
}

#[no_mangle]
pub unsafe extern "C" fn bf_net_stop(e: bf_engine) -> bf_result {
    if e.is_null() {
        return bf_result::BF_ERR_BAD_ARG;
    }
    bf_result::BF_OK
}

#[no_mangle]
pub extern "C" fn bf_net_peer_count(_e: bf_engine) -> u32 {
    0
}

#[no_mangle]
pub unsafe extern "C" fn bf_set_render_distance(e: bf_engine, chunks: u32) {
    if let Some(e) = engine_mut(e) {
        e.world.apply_render_distance(chunks as i32);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Borrow the Engine immutably from a `bf_engine`. None if null.
fn engine_ref<'a>(e: bf_engine) -> Option<&'a Engine> {
    if e.is_null() {
        None
    } else {
        // SAFETY: the app holds a live handle from bf_engine_create and does not
        // call API methods concurrently with destroy ([MAIN] contract).
        Some(unsafe { &*(e as *const Engine) })
    }
}

/// Borrow the Engine mutably from a `bf_engine`. None if null.
fn engine_mut<'a>(e: bf_engine) -> Option<&'a mut Engine> {
    if e.is_null() {
        None
    } else {
        // SAFETY: see engine_ref; the ABI is [MAIN]-single-threaded per call.
        Some(unsafe { &mut *(e as *mut Engine) })
    }
}

/// A `*const c_char` -> owned String, or `default` if null. UTF-8 lossy.
fn cstr_or(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_string();
    }
    // SAFETY: the app passes a NUL-terminated, persistent C string (see
    // Renderer.swift persistentCString); valid for the duration of this call.
    let s = unsafe { CStr::from_ptr(p) };
    s.to_string_lossy().into_owned()
}
