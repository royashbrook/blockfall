//! Behavioural parity tests for bfcore::world, ported 1:1 from the C++ World tests
//! (tests/unit/test_world.cpp, test_doors.cpp, test_quest.cpp, test_questloop.cpp,
//! test_creatures.cpp, test_saveload.cpp, test_gameplay.cpp). Same scenarios, same
//! assertions, same absolute content path.

use bfcore::abi::*;
use bfcore::content::{ContentExtra, ContentRegistry};
use bfcore::types::{IVec3, ItemId};
use bfcore::world::{self, World};
use bfcore::worldgen::{self, TerrainGen};

use std::os::raw::c_void;

const CONTENT: &str = "/Users/roy/gh/blockfall/content";

// ---- malloc-backed GPU allocator (handle == pointer bits, like the C++ tests) ----
extern "C" fn alloc_fn(_user: *mut c_void, bytes: u32) -> bf_gpu_buffer {
    let n = if bytes != 0 { bytes } else { 16 } as usize;
    // Allocate a Vec, leak its pointer (freed by free_fn). Layout-compatible with C malloc.
    let mut v = vec![0u8; n];
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    bf_gpu_buffer {
        handle: p as u64,
        contents: p as *mut c_void,
        bytes,
    }
}
extern "C" fn free_fn(_user: *mut c_void, handle: bf_handle) {
    if handle == 0 {
        return;
    }
    // We forgot a Vec<u8> with this pointer; we don't track the length, so leak it
    // for the lifetime of the test process (the C++ test's free() is exact, but a
    // small per-test leak is harmless in a test binary).
    let _ = handle;
}

fn allocator() -> bf_gpu_allocator {
    bf_gpu_allocator {
        user: std::ptr::null_mut(),
        alloc: Some(alloc_fn),
        free_: Some(free_fn),
    }
}

fn total_indices(f: &bf_render_frame, draws: &[bf_draw_item]) -> u32 {
    let _ = f;
    draws.iter().map(|d| d.index_count).sum()
}

fn empty_frame() -> bf_render_frame {
    // All-zero is a valid initial frame (the C++ uses bf_render_frame f{}).
    unsafe { std::mem::zeroed() }
}

// ============================================================================
// test_world.cpp — M1 mine/place loop on the flat test world.
// ============================================================================
#[test]
fn world_mine_place_loop() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = World::new(None);
    // Deterministic inline streaming/meshing (the async worker pool only runs on the
    // live sync_stream == false path; this test asserts meshes appear immediately).
    w.debug_set_sync_streaming(true);
    w.set_content(&content);
    w.set_allocator(allocator());

    w.generate_test_world();
    w.debug_set_camera(8.5, 20.0, 8.5, 0.0, -1.5707);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    w.update(&zero, 0.016);
    assert!(
        w.debug_has_target(),
        "raycast acquired a target looking down"
    );
    assert_eq!(
        w.debug_block_at(8, 7, 8),
        world::GRASS,
        "ground top is grass"
    );

    let mut draws: Vec<bf_draw_item> = Vec::new();
    let mut shadow: Vec<bf_draw_item> = Vec::new();
    let mut props: Vec<bf_prop_instance> = Vec::new();
    let mut f = empty_frame();
    w.build_frame(&mut f, &mut draws, &mut shadow, &mut props, 0.0);
    let idx0 = total_indices(&f, &draws);
    assert!(f.draw_count > 0 && idx0 > 0, "world meshed into draw list");

    // MINE
    let mine_start = bf_action {
        kind: bf_action_kind::BF_ACT_MINE_START,
        arg_i: 0,
        arg_j: 0,
        arg_k: 0,
    };
    w.action(&mine_start);
    let mut i = 0;
    while i < 60 && w.debug_block_at(8, 7, 8) != world::AIR {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert_eq!(
        w.debug_block_at(8, 7, 8),
        world::AIR,
        "mined block is now air"
    );
    let mine_stop = bf_action {
        kind: bf_action_kind::BF_ACT_MINE_STOP,
        arg_i: 0,
        arg_j: 0,
        arg_k: 0,
    };
    w.action(&mine_stop);

    w.build_frame(&mut f, &mut draws, &mut shadow, &mut props, 0.0);
    let idx1 = total_indices(&f, &draws);
    assert_ne!(idx1, idx0, "mesh changed after mining (remesh happened)");

    // PLACE GLOW
    w.update(&zero, 0.016);
    assert_eq!(w.debug_block_at(8, 6, 8), world::DIRT, "exposed dirt below");
    w.debug_set_selected(0);
    let place = bf_action {
        kind: bf_action_kind::BF_ACT_PLACE,
        arg_i: 0,
        arg_j: 0,
        arg_k: 0,
    };
    w.action(&place);
    assert_eq!(
        w.debug_block_at(8, 7, 8),
        world::GLOW,
        "placed block appears"
    );

    w.build_frame(&mut f, &mut draws, &mut shadow, &mut props, 0.0);
    assert!(
        f.draw_count > 0 && total_indices(&f, &draws) > 0,
        "world still meshes after place"
    );

    assert!(
        w.debug_stream_back_is_nearest(),
        "stream gen order is nearest-first (#36)"
    );
}

// A boundary face belongs to the chunk on the other side of the edited voxel.
// Both meshes must therefore be replaced before the draw list is exposed; publishing
// them as separate worker results briefly opened a see-through seam at local z=15.
#[test]
fn boundary_edit_remeshes_both_chunks_before_draw() {
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.generate_test_world();
    w.debug_set_camera(8.5, 12.0, 15.5, 0.0, -0.3);

    let mut draws = Vec::new();
    let mut shadow = Vec::new();
    let mut props = Vec::new();
    let mut frame = empty_frame();
    // The flat fixture has 25 chunks and the normal synchronous mesh budget is 12.
    for _ in 0..3 {
        w.build_frame(&mut frame, &mut draws, &mut shadow, &mut props, 0.0);
    }
    let handles = |draws: &[bf_draw_item], z: i32| {
        draws
            .iter()
            .find(|d| {
                d.chunk_origin.x == 0 && d.chunk_origin.y == 0 && d.chunk_origin.z == z
            })
            .map(|d| (d.vertex_buffer, d.index_buffer))
            .unwrap_or_else(|| panic!("missing flat-world chunk at z={z}"))
    };
    let before_edited = handles(&draws, 0);
    let before_neighbour = handles(&draws, 16);

    // Match the live worker-pool path, then remove the z=15 surface block. The edit
    // dirties its own chunk and the +z neighbour whose -z face becomes visible.
    w.debug_set_sync_streaming(false);
    w.debug_edit(8, 7, 15, world::AIR);
    w.build_frame(&mut frame, &mut draws, &mut shadow, &mut props, 0.0);

    assert_ne!(
        handles(&draws, 0),
        before_edited,
        "edited chunk remeshed before draw"
    );
    assert_ne!(
        handles(&draws, 16),
        before_neighbour,
        "boundary neighbour remeshed before the same draw"
    );
}

// ============================================================================
// World-space sun-shadow occupancy grid (ABI v19). Verifies the exported
// occupancy: solid terrain casts, air does not, an edit updates it and bumps the
// revision, and a placed leaf casts (foliage casts like the old shadow map).
// ============================================================================
#[test]
fn shadow_occupancy_grid() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_content(&content);
    w.set_allocator(allocator());
    w.generate_test_world();
    // Flat test world: solid y in [0,7], air above, around the player at (8,12,8).

    // Solid terrain casts; air above does not.
    assert_eq!(w.debug_shadow_occupancy(8, 7, 8), 1, "grass surface casts");
    assert_eq!(w.debug_shadow_occupancy(8, 0, 8), 1, "stone floor casts");
    assert_eq!(
        w.debug_shadow_occupancy(8, 9, 8),
        0,
        "air above does not cast"
    );
    assert_eq!(
        w.debug_shadow_occupancy(8, 30, 8),
        0,
        "high air does not cast"
    );

    let rev0 = w.debug_shadow_revision();

    // Mining the surface block must clear that voxel and bump the revision.
    w.debug_edit(8, 7, 8, world::AIR);
    assert_eq!(
        w.debug_shadow_occupancy(8, 7, 8),
        0,
        "mined voxel no longer casts"
    );
    let rev1 = w.debug_shadow_revision();
    assert_ne!(rev1, rev0, "occupancy revision bumps after an edit");

    // A placed leaf casts a shadow (foliage casts, matching the old shadow map).
    w.debug_edit(8, 9, 8, world::LEAF);
    assert_eq!(
        w.debug_shadow_occupancy(8, 9, 8),
        1,
        "leaf casts a sun shadow"
    );

    // Water does NOT cast.
    w.debug_edit(8, 10, 8, world::WATER);
    assert_eq!(w.debug_shadow_occupancy(8, 10, 8), 0, "water does not cast");

    // An unchanged re-read keeps the same revision (no needless rebuild/re-upload).
    let rev2 = w.debug_shadow_revision();
    let rev3 = w.debug_shadow_revision();
    assert_eq!(rev2, rev3, "no rebuild when nothing changed");
}

// ============================================================================
// test_doors.cpp — doors open/close + collision flip + 2-tall sync.
// ============================================================================
#[test]
fn doors_open_close() {
    let mut c = ContentRegistry::new();
    assert!(c.load(CONTENT), "content load");
    assert!(
        c.block_by_name("oak_door").is_some(),
        "content has oak_door"
    );
    assert!(
        c.block_by_name("oak_door_open").is_some(),
        "content has oak_door_open"
    );

    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&c);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(11);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    let (dx, dy, dz) = (100, 145, 100);
    w.debug_set_camera(
        dx as f32 + 0.5,
        dy as f32 + 5.0,
        dz as f32 + 0.5,
        0.0,
        -1.5707,
    );
    for _ in 0..25 {
        w.update(&zero, 0.05);
    }

    w.debug_edit(dx, dy, dz, 33);
    w.debug_set_camera(
        dx as f32 + 0.5,
        dy as f32 + 5.0,
        dz as f32 + 0.5,
        0.0,
        -1.5707,
    );
    w.update(&zero, 0.016);
    assert_eq!(w.debug_block_at(dx, dy, dz), 33, "closed door in place");
    assert!(
        w.debug_collide_solid(dx, dy, dz),
        "a closed door blocks movement"
    );
    assert!(w.debug_has_target(), "aimed at the door");

    let usea = bf_action {
        kind: bf_action_kind::BF_ACT_INTERACT,
        arg_i: 0,
        arg_j: 0,
        arg_k: 0,
    };
    w.action(&usea);
    w.update(&zero, 0.016);
    assert_eq!(
        w.debug_block_at(dx, dy, dz),
        50,
        "interacting opens the door"
    );
    assert!(
        !w.debug_collide_solid(dx, dy, dz),
        "an open door is passable"
    );

    w.action(&usea);
    w.update(&zero, 0.016);
    assert_eq!(
        w.debug_block_at(dx, dy, dz),
        33,
        "interacting again closes the door"
    );
    assert!(
        w.debug_collide_solid(dx, dy, dz),
        "the re-closed door blocks movement again"
    );

    // #89 2-tall door.
    let (ex, ey, ez) = (104, 145, 104);
    w.debug_edit(ex, ey, ez, 33);
    w.debug_edit(ex, ey + 1, ez, 33);
    w.debug_set_camera(
        ex as f32 + 0.5,
        ey as f32 + 5.0,
        ez as f32 + 0.5,
        0.0,
        -1.5707,
    );
    w.update(&zero, 0.016);
    assert!(
        w.debug_block_at(ex, ey, ez) == 33 && w.debug_block_at(ex, ey + 1, ez) == 33,
        "2-tall door both halves closed"
    );
    w.action(&usea);
    w.update(&zero, 0.016);
    assert!(
        w.debug_block_at(ex, ey, ez) == 50 && w.debug_block_at(ex, ey + 1, ez) == 50,
        "both halves open together (#89)"
    );
    w.action(&usea);
    w.update(&zero, 0.016);
    assert!(
        w.debug_block_at(ex, ey, ez) == 33 && w.debug_block_at(ex, ey + 1, ez) == 33,
        "both halves close together (#89)"
    );

    // #148 follow-up: stale / interacted doors must not visually split into two
    // independent 1-tall halves. Target the top half and canonicalize the whole run.
    w.debug_edit(ex, ey, ez, 33);
    w.debug_edit(ex, ey + 1, ez, 50);
    w.debug_set_camera(
        ex as f32 + 0.5,
        ey as f32 + 6.0,
        ez as f32 + 0.5,
        0.0,
        -1.5707,
    );
    w.update(&zero, 0.016);
    assert!(w.debug_has_target(), "aimed at the top half of the door");
    w.action(&usea);
    w.update(&zero, 0.016);
    assert!(
        w.debug_block_at(ex, ey, ez) == 50 && w.debug_block_at(ex, ey + 1, ez) == 50,
        "top-half interaction toggles from the bottom half and opens both halves together (#148)"
    );

    w.debug_edit(ex, ey, ez, 50);
    w.debug_edit(ex, ey + 1, ez, 33);
    w.debug_set_camera(
        ex as f32 + 0.5,
        ey as f32 + 5.0,
        ez as f32 + 0.5,
        0.0,
        -1.5707,
    );
    w.update(&zero, 0.016);
    assert!(
        w.debug_has_target(),
        "aimed at the bottom half of the mixed door"
    );
    w.action(&usea);
    w.update(&zero, 0.016);
    assert!(
        w.debug_block_at(ex, ey, ez) == 33 && w.debug_block_at(ex, ey + 1, ez) == 33,
        "bottom-half interaction toggles from the bottom half and closes both halves together (#148)"
    );
}

// ============================================================================
// test_quest.cpp — quest engine: complete + chain, target compass, platypus ach.
// ============================================================================
#[test]
fn quest_engine() {
    let mut c = ContentRegistry::new();
    assert!(c.load(CONTENT), "content load");
    let mut x = ContentExtra::new();
    assert!(x.load(CONTENT), "extra load");
    assert!(x.quests().len() >= 12, "loaded ~12+ quests");
    let bosses = x
        .creatures()
        .iter()
        .filter(|cr| cr.disposition == "boss")
        .count();
    assert_eq!(bosses, 2, "two bosses in the roster");
    assert_eq!(
        x.creatures().iter().find(|cr| cr.name == "stone_basilisk").map(|cr| cr.model),
        Some(2),
        "Stone Basilisk keeps its reptile silhouette"
    );
    assert_eq!(
        x.creatures().iter().find(|cr| cr.name == "dim_ramlord").map(|cr| cr.model),
        Some(3),
        "Dim Ramlord keeps its horned ram silhouette"
    );

    let mut w = World::new(Some(TerrainGen::new()));
    w.set_allocator(allocator());
    w.set_content(&c);
    w.set_extra(&x);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(11);

    let q0_id = x.quests()[0].id;
    let first_id = w.debug_active_quest();
    assert_eq!(first_id, q0_id, "active quest is the first content quest");
    assert_eq!(w.debug_quests_completed(), 0, "no quests completed yet");

    // Complete the first quest by firing its objective triggers.
    let q0_objs: Vec<(String, String, u32)> = x.quests()[0]
        .objectives
        .iter()
        .map(|o| (o.trigger.clone(), o.target.clone(), o.count))
        .collect();
    for (trig, target, count) in &q0_objs {
        for _ in 0..*count {
            w.debug_notify(trig, target);
        }
    }
    assert_eq!(w.debug_quests_completed(), 1, "first quest completed");
    assert_ne!(
        w.debug_active_quest(),
        first_id,
        "advanced to the next quest"
    );

    // Quest-target compass.
    {
        let mut w2 = World::new(Some(TerrainGen::new()));
        w2.set_allocator(allocator());
        w2.set_content(&c);
        w2.set_extra(&x);
        w2.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
        w2.init_world(11);

        // advance until active quest has an objective with `trig`, return that objective.
        let advance_to = |w2: &mut World, trig: &str| -> Option<(String, u32)> {
            for _ in 0..50 {
                let aq_id = w2.debug_active_quest();
                let q = x.quests().iter().find(|qq| qq.id == aq_id)?.clone();
                for o in &q.objectives {
                    if o.trigger == trig {
                        return Some((o.target.clone(), o.count));
                    }
                }
                for o in &q.objectives {
                    for _ in 0..o.count {
                        w2.debug_notify(&o.trigger, &o.target);
                    }
                }
            }
            None
        };

        let befr = advance_to(&mut w2, "befriend_creature");
        assert!(befr.is_some(), "reached a befriend_creature quest");
        let (befr_target, _) = befr.unwrap();

        let mut qt: bf_quest_target = unsafe { std::mem::zeroed() };
        assert!(
            !w2.fill_quest_target(&mut qt),
            "no target while the creature isn't loaded"
        );
        w2.debug_spawn_named(&befr_target);
        assert!(
            w2.fill_quest_target(&mut qt),
            "target active once the creature is loaded"
        );
        assert!(
            qt.active == 1 && qt.is_boss == 0,
            "befriend target: active, not a boss"
        );
        let label = cstr_str(&qt.label);
        assert_eq!(label, "Gloom Stag", "label title-cased from creature name");
        assert!(
            qt.distance > 0.0 && qt.distance < 20.0,
            "distance to target is sane"
        );

        let boss = advance_to(&mut w2, "calm_boss");
        assert!(boss.is_some(), "reached a calm_boss quest");
        let (boss_target, _) = boss.unwrap();
        let mut qb: bf_quest_target = unsafe { std::mem::zeroed() };
        w2.debug_spawn_named(&boss_target);
        assert!(
            w2.fill_quest_target(&mut qb),
            "boss target active once loaded"
        );
        assert_eq!(qb.is_boss, 1, "calm_boss target is flagged is_boss");
    }

    // Platypus achievement.
    {
        let mut w3 = World::new(Some(TerrainGen::new()));
        w3.set_allocator(allocator());
        w3.set_content(&c);
        w3.set_extra(&x);
        w3.set_mode(bf_game_mode::BF_MODE_CREATIVE);
        w3.init_world(11);
        w3.debug_notify("befriend_creature", "platypus");
        assert_eq!(
            w3.debug_ach_toast(),
            "Achievement: Perry the Platypus",
            "befriending a platypus unlocks the Perry achievement"
        );
    }
}

#[test]
fn curl_horn_ram_retaliates_when_struck() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");
    let mut extra = ContentExtra::new();
    assert!(extra.load(CONTENT), "extra load");
    let attack = bf_action {
        kind: bf_action_kind::BF_ACT_ATTACK,
        arg_i: 0,
        arg_j: 0,
        arg_k: 0,
    };

    let mut ram_world = World::new(Some(TerrainGen::new()));
    ram_world.set_content(&content);
    ram_world.set_extra(&extra);
    ram_world.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    ram_world.init_world(11);
    ram_world.debug_spawn_named("curl_horn_ram");
    assert!(ram_world.debug_aim_at_creature0(), "aimed at ram");
    ram_world.action(&attack);
    assert!(
        ram_world.debug_creature_provoked(0),
        "a struck curl-horn ram retaliates"
    );
    assert_eq!(
        ram_world.debug_hostile_count(),
        0,
        "retaliating ram remains an animal, not a monster"
    );

    let mut passive_world = World::new(Some(TerrainGen::new()));
    passive_world.set_content(&content);
    passive_world.set_extra(&extra);
    passive_world.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    passive_world.init_world(11);
    passive_world.debug_spawn_named("sky_necker");
    assert!(passive_world.debug_aim_at_creature0(), "aimed at sky-necker");
    passive_world.action(&attack);
    assert!(
        !passive_world.debug_creature_provoked(0),
        "other passive animals keep their current behavior"
    );
}

// ============================================================================
// test_questloop.cpp — campaign winnable + real beacon restores a Grey region.
// ============================================================================
fn chunk_of(v: i32) -> i32 {
    if v >= 0 {
        v / 16
    } else {
        (v - 15) / 16
    }
}

#[test]
fn quest_loop_end_to_end() {
    let mut c = ContentRegistry::new();
    assert!(c.load(CONTENT), "content load");
    let mut x = ContentExtra::new();
    assert!(x.load(CONTENT), "extra load");
    assert!(x.quests().len() >= 12, "loaded the campaign quests");

    // A) every objective targets content that exists.
    let creature_exists = |nm: &str| x.creatures().iter().any(|cr| cr.name == nm);
    for q in x.quests() {
        for o in &q.objectives {
            if o.target.is_empty() {
                continue;
            }
            let t = &o.target;
            let ok = if o.trigger == "befriend_creature" || o.trigger == "calm_boss" {
                creature_exists(t)
            } else if o.trigger == "restore_region" || o.trigger == "reach_location" {
                true
            } else {
                c.item_by_name(t).is_some() || c.block_by_name(t).is_some()
            };
            assert!(
                ok,
                "quest {} objective '{}' targets '{}'",
                q.id, o.trigger, t
            );
        }
    }

    // B) whole chain completable -> win state.
    {
        let mut w = World::new(Some(TerrainGen::new()));
        w.set_allocator(allocator());
        w.set_content(&c);
        w.set_extra(&x);
        w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
        w.init_world(11);

        assert_eq!(
            w.debug_active_quest(),
            x.quests()[0].id,
            "first quest active on spawn"
        );
        assert!(!w.debug_all_quests_done(), "not won at the start");

        let mut guard = 0;
        while !w.debug_all_quests_done() && guard < 200 {
            guard += 1;
            let aq_id = w.debug_active_quest();
            let q = x.quests().iter().find(|qq| qq.id == aq_id).cloned();
            assert!(q.is_some(), "active quest id resolves to a loaded quest");
            let q = q.unwrap();
            for o in &q.objectives {
                for _ in 0..o.count {
                    w.debug_notify(&o.trigger, &o.target);
                }
            }
        }
        assert!(w.debug_all_quests_done(), "campaign is winnable");
        assert_eq!(
            w.debug_quests_completed(),
            x.quests().len() as i32,
            "completed-quest count matches loaded quests"
        );
    }

    // C) a real beacon placement restores a Grey region.
    {
        let mut w = World::new(Some(TerrainGen::new()));
        w.debug_set_sync_streaming(true);
        w.set_allocator(allocator());
        w.set_content(&c);
        w.set_extra(&x);
        w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
        w.init_world(11);

        let zero: bf_frame_input = unsafe { std::mem::zeroed() };
        let (bx, by, bz) = (2000, 145, 2000);
        w.debug_set_camera(
            bx as f32 + 0.5,
            by as f32 + 5.0,
            bz as f32 + 0.5,
            0.0,
            -1.5707,
        );
        for _ in 0..30 {
            w.update(&zero, 0.05);
        }
        assert!(
            w.debug_region_sat(chunk_of(bx), chunk_of(bz)) < 0.99,
            "far region starts Grey"
        );

        w.debug_edit(bx, by, bz, world::STONE);
        w.debug_set_camera(
            bx as f32 + 0.5,
            by as f32 + 5.0,
            bz as f32 + 0.5,
            0.0,
            -1.5707,
        );
        w.update(&zero, 0.016);
        assert!(
            w.debug_has_target(),
            "aimed at the stone block for placement"
        );

        let beacon = w.debug_item_id("beacon_block");
        assert_ne!(beacon, 0, "content has a beacon_block item");
        w.debug_clear_inventory();
        w.debug_give(beacon, 1);
        let sel = bf_action {
            kind: bf_action_kind::BF_ACT_HOTBAR_SELECT,
            arg_i: 0,
            arg_j: 0,
            arg_k: 0,
        };
        w.action(&sel);

        let restored_before = w.debug_regions_restored();
        let place = bf_action {
            kind: bf_action_kind::BF_ACT_PLACE,
            arg_i: 0,
            arg_j: 0,
            arg_k: 0,
        };
        w.action(&place);
        w.update(&zero, 0.016);

        assert!(
            w.debug_block_at(bx, by + 1, bz) == beacon
                || w.debug_regions_restored() == restored_before + 1,
            "beacon placed on top of the stone"
        );
        assert_eq!(
            w.debug_regions_restored(),
            restored_before + 1,
            "placing a beacon in a Grey region restores it"
        );
        assert!(
            w.debug_region_sat(chunk_of(bx), chunk_of(bz)) > 0.99,
            "the restored region is now full colour"
        );
    }
}

// ============================================================================
// test_creatures.cpp — collision/separation, pet follow, palisade, regrowth.
// ============================================================================
#[test]
fn creature_collision_and_villages() {
    let mut c = ContentRegistry::new();
    assert!(c.load(CONTENT), "content load");
    let mut x = ContentExtra::new();
    assert!(x.load(CONTENT), "extra load");

    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&c);
    w.set_extra(&x);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(11);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    w.debug_set_camera(100.5, 145.0, 100.5, 0.0, 0.0);
    for _ in 0..10 {
        w.update(&zero, 0.05);
    }

    let base = w.debug_creature_count();
    w.debug_spawn_named("river_fox");
    w.debug_spawn_named("river_fox");
    assert!(
        w.debug_creature_count() >= base + 2,
        "two creatures spawned"
    );
    for _ in 0..12 {
        w.update(&zero, 0.05);
    }
    let (ax, _ay, az) = w.debug_creature_pos(base);
    let (bx, _by, bz) = w.debug_creature_pos(base + 1);
    let dxz = ((bx - ax) * (bx - ax) + (bz - az) * (bz - az)).sqrt();
    assert!(dxz > 0.7, "two creatures separate instead of stacking");

    // Befriended pet follow spacing.
    w.debug_set_friendly(base + 1);
    for _ in 0..30 {
        w.update(&zero, 0.05);
    }
    let (fx, _fy, fz) = w.debug_creature_pos(base + 1);
    let pd = ((fx - 100.5) * (fx - 100.5) + (fz - 100.5) * (fz - 100.5)).sqrt();
    assert!(pd > 1.0, "befriended pet does not crowd onto the player");
    assert!(pd < 5.0, "befriended pet follows toward the player");

    // Palisade ring (stateless: placed logs are the progress).
    {
        let (vcx, vcz) = (100, 100);
        let ring_logs = |w: &World| -> i32 {
            let mut n = 0;
            for dx in -8..=8 {
                for dz in -8..=8 {
                    let adx = if dx < 0 { -dx } else { dx };
                    let adz = if dz < 0 { -dz } else { dz };
                    if adx.max(adz) != 8 {
                        continue;
                    }
                    let mut wy = 120;
                    while wy >= -8 {
                        if w.debug_block_at(vcx + dx, wy, vcz + dz) == 21 {
                            n += 1;
                            break;
                        }
                        wy -= 1;
                    }
                }
            }
            n
        };
        let built1 = w.debug_build_palisade(vcx, vcz, 6);
        assert!(built1 > 0, "village: first donation builds wall cells");
        let after1 = ring_logs(&w);
        assert!(after1 >= built1, "village: built cells present in ring");
        let built2 = w.debug_build_palisade(vcx, vcz, 6);
        let after2 = ring_logs(&w);
        assert!(
            built2 > 0 && after2 > after1,
            "village: second donation extends the wall"
        );
    }

    // Natural regrowth. #: with real oceans the origin region for seed 11 is open
    // water, so grow the regrowth tree on a dry-land column instead (a tree
    // cannot keep a crown underwater). #172 reshuffled the biome map, so scan
    // outward for the nearest dry non-desert column rather than pinning one.
    {
        let mut spot = None;
        'grow: for r in (0..=2048i32).step_by(16) {
            for v in (-r..=r).step_by(16) {
                for &(sx, sz) in &[(r, v), (-r, v), (v, r), (v, -r)] {
                    let h = worldgen::worldgen_surface_height(sx, sz, 11);
                    if h > 10
                        && !worldgen::worldgen_is_ocean_col(sx, sz, 11)
                        && worldgen::worldgen_dominant_biome(sx, sz, 11)
                            != worldgen::Biome::Desert as i32
                        && worldgen::worldgen_dominant_biome(sx, sz, 11)
                            != worldgen::Biome::Beach as i32
                    {
                        spot = Some((sx, sz));
                        break 'grow;
                    }
                }
            }
        }
        let (tx, tz) = spot.expect("regrowth: no dry-land column found in scan");
        assert!(
            w.debug_grow_tree(tx, tz),
            "regrowth: tree grown on a dry-land column"
        );
        let mut logs = 0;
        let mut leaves = 0;
        for wy in 0..=120 {
            if w.debug_block_at(tx, wy, tz) == 21 {
                logs += 1;
            }
        }
        for dx in -2..=2 {
            for dz in -2..=2 {
                for wy in 0..=120 {
                    if w.debug_block_at(tx + dx, wy, tz + dz) == 5 {
                        leaves += 1;
                    }
                }
            }
        }
        assert!(logs >= 4, "regrowth: trunk has logs");
        assert!(leaves >= 4, "regrowth: tree has a leaf crown");
    }
}

#[test]
fn villagers_never_spawn_with_their_body_inside_blocks() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");
    let mut extra = ContentExtra::new();
    assert!(extra.load(CONTENT), "extra load");
    let mut w = World::new(None);
    w.set_content(&content);
    w.set_extra(&extra);
    w.init_world(243);
    w.generate_test_world();

    // Candidate feet land at y=8. A two-block wall through the random spawn square
    // catches any scale-aware footprint that overlaps it from an adjacent column.
    for z in 12..=20 {
        for y in 8..=9 {
            w.debug_edit(16, y, z, world::STONE);
        }
    }
    let mut made = 0;
    for _ in 0..80 {
        made += w.debug_spawn_villagers_at(16, 8, 16, 2);
    }
    assert!(made > 0, "test spawned villagers around the wall");
    assert!(
        w.debug_villagers_body_clear(),
        "villager spawn leaves every full body clear of solid blocks"
    );
}

// ============================================================================
// test_saveload.cpp — save/load round-trip + determinism.
// ============================================================================
#[test]
fn save_load_round_trip() {
    let dir = std::env::temp_dir().join("bf_saveload_test_rs");
    let dir = dir.to_string_lossy().to_string();
    let _ = std::fs::remove_dir_all(&dir);

    // session 1: generate, edit, save.
    {
        let mut w = World::new(Some(TerrainGen::new()));
        w.debug_set_sync_streaming(true);
        w.set_allocator(allocator());
        w.init_world(424242);
        w.debug_edit(3, 70, 3, world::GLOW);
        w.debug_edit(4, 70, 3, world::BRICK);
        w.debug_edit(3, 70, 4, world::AIR);
        assert!(w.save(&dir), "save succeeded");
    }

    // session 2: load + verify.
    {
        let mut w = World::new(Some(TerrainGen::new()));
        w.debug_set_sync_streaming(true);
        w.set_allocator(allocator());
        assert!(w.load(&dir), "load succeeded");
        assert_eq!(
            w.debug_block_at(3, 70, 3),
            world::GLOW,
            "edited GLOW persisted"
        );
        assert_eq!(
            w.debug_block_at(4, 70, 3),
            world::BRICK,
            "edited BRICK persisted"
        );
        assert_eq!(
            w.debug_block_at(3, 70, 4),
            world::AIR,
            "dug-out edit persisted"
        );
        // #190: spawn sits at the nearest settlement now, not the origin, so check
        // the saturated homeland ring at the SPAWN chunk rather than chunk (0,0).
        let (px, _py, pz, _) = w.get_player();
        let (scx, scz) = ((px as i32).div_euclid(16), (pz as i32).div_euclid(16));
        assert!(
            w.debug_region_sat(scx, scz) > 0.9,
            "restored spawn region persisted"
        );

        let mut w3 = World::new(Some(TerrainGen::new()));
        w3.debug_set_sync_streaming(true);
        w3.set_allocator(allocator());
        w3.init_world(424242);
        let zero: bf_frame_input = unsafe { std::mem::zeroed() };
        for _ in 0..300 {
            w3.update(&zero, 0.016);
            w.update(&zero, 0.016);
        }
        let mut matches = 0;
        let mut total = 0;
        for xx in 0..8 {
            for zz in 0..8 {
                for yy in 0..20 {
                    total += 1;
                    if w3.debug_block_at(xx, yy, zz) == w.debug_block_at(xx, yy, zz) {
                        matches += 1;
                    }
                }
            }
        }
        assert_eq!(
            matches, total,
            "loaded procedural terrain matches a fresh same-seed gen"
        );
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn save_load_preserves_world_clock_and_accepts_legacy_meta() {
    let dir = std::env::temp_dir().join(format!("bf_time_saveload_rs_{}", std::process::id()));
    let dir = dir.to_string_lossy().to_string();
    let _ = std::fs::remove_dir_all(&dir);

    let mut world = World::new(None);
    world.set_allocator(allocator());
    world.debug_set_day_time(0.61);
    assert!(world.save(&dir), "save with world time");

    let mut loaded = World::new(None);
    loaded.set_allocator(allocator());
    assert!(loaded.load(&dir), "load tagged world time");
    assert!(
        (loaded.debug_day_time() - 0.61).abs() < 1e-6,
        "world time resumed at the saved phase ({})",
        loaded.debug_day_time()
    );

    // #263: removing the optional BFTM trailer recreates the old world.meta
    // layout. It must still load, with the legacy fresh-world clock fallback.
    let meta_path = format!("{dir}/world.meta");
    let mut legacy_meta = std::fs::read(&meta_path).expect("read new world.meta");
    let trailer = legacy_meta.len() - 12;
    assert_eq!(&legacy_meta[trailer..trailer + 4], b"BFTM");
    legacy_meta.truncate(trailer);
    std::fs::write(&meta_path, legacy_meta).expect("write legacy world.meta");

    let mut legacy = World::new(None);
    legacy.set_allocator(allocator());
    assert!(legacy.load(&dir), "legacy world.meta still loads");
    assert!(
        legacy.debug_day_time().abs() < 1e-6,
        "legacy save keeps phase-zero fallback"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

// ============================================================================
// test_gameplay.cpp — survival drops, crafting, creatures, deep-cave hostiles.
// ============================================================================
#[test]
fn gameplay_drops_crafting_creatures() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");

    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    w.set_content(&content);
    w.init_world(99);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };

    // survival mining drops an item.
    w.debug_clear_inventory();
    w.debug_set_camera(100.5, 100.0, 100.5, 0.0, -1.5707);
    w.debug_edit(100, 95, 100, world::STONE);
    w.update(&zero, 0.016);
    assert!(w.debug_has_target(), "aimed at the stone block");

    let cobble = w.debug_item_id("cobblestone");
    assert_ne!(cobble, 0, "content has a cobblestone item");
    let mine_start = bf_action {
        kind: bf_action_kind::BF_ACT_MINE_START,
        arg_i: 0,
        arg_j: 0,
        arg_k: 0,
    };
    w.action(&mine_start);
    let mut i = 0;
    while i < 200 && w.debug_block_at(100, 95, 100) != world::AIR {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert_eq!(
        w.debug_block_at(100, 95, 100),
        world::AIR,
        "stone mined away"
    );
    // #170 the drop now rides on physical debris; walk the player up to the
    // fragments so the magnet collects them into the inventory.
    assert!(
        w.debug_debris_count() > 0,
        "mining burst the stone into debris"
    );
    for _ in 0..40 {
        w.update(&zero, 0.05); // let the burst arc + settle
    }
    let (dx, dy, dz) = w.debug_debris_pos(0);
    w.debug_set_camera(dx, dy + 1.5, dz, 0.0, -1.5707);
    let mut i = 0;
    while i < 100 && w.debug_item_count(cobble) < 1 {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert!(
        w.debug_item_count(cobble) >= 1,
        "survival mining dropped cobblestone (collected from debris)"
    );

    // crafting consumes inputs, produces output.
    let log = w.debug_item_id("oak_log");
    let planks = w.debug_item_id("oak_planks");
    assert!(
        log != 0 && planks != 0,
        "content has oak_log and oak_planks"
    );
    w.debug_clear_inventory();
    w.debug_give(log, 4);
    let planks_before = w.debug_item_count(planks);
    let craft = bf_action {
        kind: bf_action_kind::BF_ACT_CRAFT,
        arg_i: 0,
        arg_j: 0,
        arg_k: 0,
    };
    w.action(&craft);
    assert!(
        w.debug_item_count(planks) > planks_before,
        "crafting produced planks"
    );
    assert!(w.debug_item_count(log) < 4, "crafting consumed a log");

    // creatures populate + defeat one.
    let mut cw = World::new(Some(TerrainGen::new()));
    cw.debug_set_sync_streaming(true);
    cw.set_allocator(allocator());
    cw.set_content(&content);
    cw.init_world(5);
    let mut i = 0;
    while i < 200 && cw.debug_creature_count() < 8 {
        cw.update(&zero, 0.05);
        i += 1;
    }
    assert!(
        cw.debug_creature_count() >= 8,
        "animals populate near the player"
    );
    assert!(cw.debug_aim_at_creature0(), "aimed at an animal");
    let before = cw.debug_creature_count();
    let attack = bf_action {
        kind: bf_action_kind::BF_ACT_ATTACK,
        arg_i: 0,
        arg_j: 0,
        arg_k: 0,
    };
    let mut h = 0;
    while h < 8 && cw.debug_creature_count() == before {
        cw.debug_aim_at_creature0();
        cw.action(&attack);
        cw.update(&zero, 0.02);
        h += 1;
    }
    assert_eq!(
        cw.debug_creature_count(),
        before - 1,
        "defeating an aimed animal removes it"
    );

    // #7 deep-underground hostiles.
    {
        let mut cave = World::new(Some(TerrainGen::new()));
        cave.debug_set_sync_streaming(true);
        cave.set_allocator(allocator());
        cave.set_content(&content);
        cave.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
        cave.init_world(5);
        cave.debug_force_quest_done();
        let (cx, cz) = (200, 200);
        let surf = worldgen::worldgen_surface_height(cx, cz, 5);
        let cy = surf - 20;
        cave.debug_set_camera(cx as f32 + 0.5, cy as f32 + 0.5, cz as f32 + 0.5, 0.0, 0.0);
        for _ in 0..30 {
            cave.update(&zero, 0.05);
        }
        // Carve a cavern wide enough to contain the whole 10..22 spawn ring:
        // #232 spawns are body-clearance honest now, so hostiles only appear in
        // real air pockets (the old 7x7 pocket passed only because they spawned
        // embedded in the rock outside it).
        for dx in -23..=23 {
            for dz in -23..=23 {
                cave.debug_edit(cx + dx, cy - 1, cz + dz, world::STONE);
                for dy in 0..=3 {
                    cave.debug_edit(cx + dx, cy + dy, cz + dz, world::AIR);
                }
            }
        }
        cave.debug_set_camera(cx as f32 + 0.5, cy as f32 + 0.5, cz as f32 + 0.5, 0.0, 0.0);
        let mut i = 0;
        while i < 400 && cave.debug_hostile_count() == 0 {
            cave.update(&zero, 0.05);
            i += 1;
        }
        assert!(
            cave.debug_hostile_count() > 0,
            "hostiles spawn deep underground (#7)"
        );
    }
    let _ = IVec3::default();
}

// ============================================================================
// Hostiles must spawn at NIGHT on the open surface (not only in deep caves), and
// daytime fauna must still spawn. Regression guard for the night-spawn gate.
// ============================================================================
#[test]
fn hostiles_spawn_at_night_on_surface() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");

    // ---- night: hostiles appear on the surface ----
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&content);
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    w.init_world(5);
    w.debug_force_quest_done(); // lift the first-night grace gate

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };

    // Stand on the surface (not in a cave), then jump the clock to deep night.
    let (cx, cz) = (200, 200);
    let surf = worldgen::worldgen_surface_height(cx, cz, 5);
    w.debug_set_camera(
        cx as f32 + 0.5,
        surf as f32 + 2.0,
        cz as f32 + 0.5,
        0.0,
        0.0,
    );
    for _ in 0..30 {
        w.update(&zero, 0.05);
    }
    w.debug_set_day_time(0.90); // t > 0.80 => night
    w.debug_set_camera(
        cx as f32 + 0.5,
        surf as f32 + 2.0,
        cz as f32 + 0.5,
        0.0,
        0.0,
    );
    assert!(w.debug_day_time() > 0.80, "world clock is at night");

    let mut i = 0;
    while i < 400 && w.debug_hostile_count() == 0 {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert!(
        w.debug_hostile_count() > 0,
        "hostiles spawn at night on the surface (day_time = {})",
        w.debug_day_time()
    );

    // ---- daytime fauna still spawns (don't break passives) ----
    let mut day = World::new(Some(TerrainGen::new()));
    day.debug_set_sync_streaming(true);
    day.set_allocator(allocator());
    day.set_content(&content);
    day.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    day.init_world(5);
    day.debug_set_day_time(0.30); // bright morning, not night
    let (dx, dz) = (200, 200);
    let dsurf = worldgen::worldgen_surface_height(dx, dz, 5);
    day.debug_set_camera(
        dx as f32 + 0.5,
        dsurf as f32 + 2.0,
        dz as f32 + 0.5,
        0.0,
        0.0,
    );
    let mut j = 0;
    while j < 400 && day.debug_creature_count() < 4 {
        day.update(&zero, 0.05);
        j += 1;
    }
    assert!(
        day.debug_day_time() < 0.20
            || day.debug_day_time() > 0.80
            || day.debug_creature_count() >= 4,
        "stayed daytime"
    );
    assert!(day.debug_creature_count() >= 4, "daytime fauna still spawn");
    assert_eq!(
        day.debug_hostile_count(),
        0,
        "no hostiles in daylight on the surface"
    );
}

// ============================================================================
// #238 difficulty. Hard raises the night cap above normal's 4 and deliberately
// enables harmless monster observation in Creative; Easy removes every hostile
// and keeps them gone. Pins the T night phase (0.75), which also guards the #237
// fix: that phase must count as night for spawning.
// ============================================================================
#[test]
fn difficulty_hard_spawns_more_easy_removes_all() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&content);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(5);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    let (cx, cz) = (200, 200);
    let surf = worldgen::worldgen_surface_height(cx, cz, 5);
    w.debug_set_camera(cx as f32 + 0.5, surf as f32 + 2.0, cz as f32 + 0.5, 0.0, 0.0);
    for _ in 0..30 {
        w.update(&zero, 0.05);
    }
    w.debug_set_day_time(0.75); // the T night pin phase — must gate as night (#237)
    w.debug_set_camera(cx as f32 + 0.5, surf as f32 + 2.0, cz as f32 + 0.5, 0.0, 0.0);

    // Normal Creative remains peaceful even at night.
    for _ in 0..80 {
        w.update(&zero, 0.05);
    }
    assert_eq!(w.debug_hostile_count(), 0, "normal creative stays peaceful");

    // Hard Creative: the cap is 8 and the first-quest grace gate is bypassed, so
    // observers can see a representative group immediately in a fresh world.
    w.set_difficulty(2);
    let health_before = w.debug_health();
    w.debug_spawn_hostile_at(cx as f32 + 0.5, surf as f32, cz as f32 + 0.5);
    for _ in 0..40 {
        w.update(&zero, 0.05);
    }
    assert_eq!(
        w.debug_health(),
        health_before,
        "hard creative monsters remain harmless observation subjects"
    );
    let mut i = 0;
    while i < 3000 && w.debug_hostile_count() <= 4 {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert!(
        w.debug_hostile_count() > 4,
        "hard creative spawns past the normal cap (got {}, day_time {})",
        w.debug_hostile_count(),
        w.debug_day_time()
    );

    // Returning to Normal Creative immediately restores the peaceful contract.
    w.set_difficulty(1);
    for _ in 0..80 {
        w.update(&zero, 0.05);
    }
    assert_eq!(w.debug_hostile_count(), 0, "normal creative culls hard-mode observers");

    // Repopulate before the Easy check so that check proves an actual cull.
    w.set_difficulty(2);
    while i < 6000 && w.debug_hostile_count() == 0 {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert!(w.debug_hostile_count() > 0, "hard creative observers return");

    // Easy: every hostile is culled on the next maintain tick and none return.
    w.set_difficulty(0);
    for _ in 0..80 {
        w.update(&zero, 0.05);
    }
    assert_eq!(w.debug_hostile_count(), 0, "easy removes all hostiles");
    for _ in 0..200 {
        w.update(&zero, 0.05);
    }
    assert_eq!(w.debug_hostile_count(), 0, "easy keeps hostiles gone");
}

// ============================================================================
// #231: a creature whose body is embedded in solid blocks (bad spawn, closed
// wall) must relocate to the nearest clear cell instead of freezing forever.
// ============================================================================
#[test]
fn embedded_creature_unsticks_to_clear_ground() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&content);
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    w.init_world(5);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    let (cx, cz) = (200, 200);
    let surf = worldgen::worldgen_surface_height(cx, cz, 5);
    w.debug_set_camera(cx as f32 + 6.5, surf as f32 + 2.0, cz as f32 + 0.5, 0.0, 0.0);
    for _ in 0..30 {
        w.update(&zero, 0.05);
    }

    // A hostile hunts the player, so it attempts a move every tick. Entomb it in
    // a 3x3x3 stone block: every step stays inside solid and the 2-block climb
    // cap can't top the slab, so ONLY the unstick relocation can free it.
    let idx = w.debug_spawn_hostile_at(cx as f32 + 0.5, surf as f32, cz as f32 + 0.5);
    for dx in -1..=1 {
        for dz in -1..=1 {
            for dy in 0..=2 {
                w.debug_set_wall_block(cx + dx, surf + dy, cz + dz, 3);
            }
        }
    }
    for _ in 0..100 {
        w.update(&zero, 0.05);
    }
    let (px, py, pz) = w.debug_creature_pos(idx);
    let moved = (px - (cx as f32 + 0.5)).abs() > 1.4 || (pz - (cz as f32 + 0.5)).abs() > 1.4;
    assert!(
        moved,
        "embedded creature relocated (still at {px},{py},{pz} vs spawn {},{},{})",
        cx as f32 + 0.5,
        surf,
        cz as f32 + 0.5
    );
}

// A ruined structure is a localized "danger site": in Hard Creative, harmless
// defenders spawn in broad daylight before any quest is done (independent of the
// night/quest gate). Seed 10 has a ruin in plains at (184,76).
#[test]
fn ruin_spawns_daytime_danger_in_hard_creative() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");

    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&content);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(10);
    // init resets the runtime difficulty to Normal, just like a fresh app load.
    w.set_difficulty(2);
    // Deliberately do NOT complete a quest and keep it bright daytime: the normal
    // night/quest gate is shut, so any hostile that appears must be a ruin spawn.
    w.debug_set_day_time(0.30); // bright morning

    // Confirm the seed actually has a ruin near our stand point (guards the fixture).
    let site = worldgen::worldgen_dangerous_site_near(184, 76, 48, 10);
    assert!(site.is_some(), "seed 10 should have a ruin near (184,76)");
    let (rx, ry, rz) = site.unwrap();

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    // Stand right at the ruin so its chunk is resident and within danger radius.
    w.debug_set_camera(rx as f32 + 0.5, ry as f32 + 2.0, rz as f32 + 0.5, 0.0, 0.0);
    for _ in 0..30 {
        w.update(&zero, 0.05);
    }
    w.debug_set_camera(rx as f32 + 0.5, ry as f32 + 2.0, rz as f32 + 0.5, 0.0, 0.0);

    let mut i = 0;
    while i < 600 && w.debug_ruin_hostile_count() == 0 {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert!(
        w.debug_ruin_hostile_count() > 0,
        "a ruin should spawn a daytime danger hostile (day_time = {}, quests not done)",
        w.debug_day_time()
    );

    // It must stay capped: pump a long time and the ruin-hostile count never runs away.
    for _ in 0..2000 {
        w.update(&zero, 0.05);
    }
    assert!(
        w.debug_ruin_hostile_count() <= 3,
        "ruin danger hostiles stay capped, saw {}",
        w.debug_ruin_hostile_count()
    );
}

#[test]
fn epic_landmarks_spawn_their_guarded_encounters_and_high_tier_loot() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");
    let mut extra = ContentExtra::new();
    assert!(extra.load(CONTENT), "extra content load");
    let epic_item_ids: Vec<ItemId> = [
        "iron_sword",
        "iron_pickaxe",
        "iron_ingot",
        "crystal_shard",
        "color_dust",
        "glow_dust",
        "honey_cake",
        "crystal_lamp",
    ]
    .iter()
    .map(|name| content.item_by_name(name).expect("epic loot item exists").id)
    .collect();

    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&content);
    w.set_extra(&extra);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(11);
    w.set_difficulty(2);
    w.debug_set_day_time(0.30);
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };

    // Seed-11 boss castle: one actual content boss guards the courtyard and two
    // deterministic high-tier chests reward exploration of the rooms.
    let castle = worldgen::worldgen_dangerous_site_typed_near(6621, 30880, 0, 11)
        .expect("seed-11 castle fixture exists");
    assert!(worldgen::worldgen_danger_site_is_boss(castle.0));
    let (_, cx, cy, cz) = castle;
    w.debug_set_camera(cx as f32 + 0.5, cy as f32 + 2.0, cz as f32 + 0.5, 0.0, 0.0);
    for _ in 0..30 {
        w.update(&zero, 0.05);
    }
    let mut ticks = 0;
    while ticks < 600 && w.debug_danger_boss_count() == 0 {
        w.update(&zero, 0.05);
        ticks += 1;
    }
    assert_eq!(w.debug_danger_boss_count(), 1, "castle spawns exactly one anchored boss");
    let (boss_name, boss_model, boss_scale) = w.debug_danger_boss_info().expect("boss info");
    assert!(boss_name == "stone_basilisk" || boss_name == "dim_ramlord");
    assert!(boss_model == 2 || boss_model == 3, "landmark uses a content boss model");
    assert_eq!(boss_scale, 2.0);

    let mut rolled = 0;
    for slot in 0..world::CHEST_SLOTS {
        let (item, count) = w.debug_chest_slot(
            cx,
            cy + 1,
            (cz + 6).rem_euclid(worldgen::WORLD_PERIOD),
            slot,
        );
        if count > 0 {
            rolled += 1;
            assert!(epic_item_ids.contains(&item), "castle chest rolled non-epic item {item}");
        }
    }
    assert!(rolled > 0, "castle reward chest is populated");

    // A player respawn culls hostiles but is not a boss kill. Returning must re-arm
    // the encounter rather than silently clearing/rewarding the castle.
    w.debug_respawn_now();
    assert_eq!(w.debug_danger_boss_count(), 0);
    assert!(!w.debug_ruin_site_cleared(cx, cz));
    w.debug_set_camera(cx as f32 + 0.5, cy as f32 + 2.0, cz as f32 + 0.5, 0.0, 0.0);
    ticks = 0;
    while ticks < 600 && w.debug_danger_boss_count() == 0 {
        w.update(&zero, 0.05);
        ticks += 1;
    }
    assert_eq!(w.debug_danger_boss_count(), 1, "castle boss re-arms after player respawn");

    // The grand tower is the other encounter flavor: the existing three-defender
    // danger band guards its enterable climb and summit chest.
    let tower = worldgen::worldgen_dangerous_site_typed_near(31525, 3048, 0, 11)
        .expect("seed-11 grand tower fixture exists");
    assert!(!worldgen::worldgen_danger_site_is_boss(tower.0));
    let (_, tx, ty, tz) = tower;
    w.debug_set_camera(tx as f32 + 0.5, ty as f32 + 2.0, tz as f32 + 0.5, 0.0, 0.0);
    for _ in 0..30 {
        w.update(&zero, 0.05);
    }
    ticks = 0;
    while ticks < 900 && w.debug_ruin_hostile_count() < 3 {
        w.update(&zero, 0.05);
        ticks += 1;
    }
    assert_eq!(w.debug_danger_boss_count(), 0, "castle boss despawned after distant travel");
    assert_eq!(w.debug_ruin_hostile_count(), 3, "grand tower keeps the bounded defender band");

    // Partially abandoning a defender band replenishes only the missing member.
    assert!(w.debug_move_one_danger_hostile(tx, tz, tx as f32 + 200.0, ty as f32 + 1.0, tz as f32));
    for _ in 0..240 {
        w.update(&zero, 0.05);
    }
    assert_eq!(w.debug_ruin_hostile_count(), 3, "partial distance cull does not overfill defenders");

    rolled = 0;
    for slot in 0..world::CHEST_SLOTS {
        let (item, count) = w.debug_chest_slot(tx, ty + 25, tz, slot);
        if count > 0 {
            rolled += 1;
            assert!(epic_item_ids.contains(&item), "tower chest rolled non-epic item {item}");
        }
    }
    assert!(rolled > 0, "tower summit chest is populated");

    // Distance despawn is not a free clear/reward: returning re-arms the castle
    // encounter instead of marking it defeated behind the player's back.
    assert!(!w.debug_ruin_site_cleared(cx, cz));
    w.debug_set_camera(cx as f32 + 0.5, cy as f32 + 2.0, cz as f32 + 0.5, 0.0, 0.0);
    ticks = 0;
    while ticks < 600 && w.debug_danger_boss_count() == 0 {
        w.update(&zero, 0.05);
        ticks += 1;
    }
    assert_eq!(w.debug_danger_boss_count(), 1, "returning respawns an abandoned castle boss");
    assert!(!w.debug_ruin_site_cleared(cx, cz));

    // Reusing the World for another seed must not leak transient encounter state.
    assert!(w.debug_danger_site_count() > 0);
    w.init_world(12);
    assert_eq!(w.debug_danger_site_count(), 0, "fresh init clears old danger-site state");
}

// ============================================================================
// #25 async streaming: the LIVE (sync_stream == false) worker-pool path fills the
// world over a few frames. This exercises the gen + mesh worker pool end to end:
// update() submits gen jobs, build_frame() drains finished gen + uploads worker
// mesh results. We only assert that the async path actually fills (draws grow and
// stay bounded per frame); exact counts are nondeterministic (worker wall-clock).
// ============================================================================
#[test]
fn async_streaming_fills_world() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = World::new(Some(TerrainGen::new()));
    // NOTE: do NOT set sync streaming — this is the live async worker-pool path.
    w.set_content(&content);
    w.set_allocator(allocator());
    w.set_render_distance(8);
    w.init_world(424242);
    assert_eq!(w.debug_stream_target_radius(), 8);
    assert_eq!(w.debug_stream_active_radius(), 2);
    assert!(
        w.debug_stream_backlog() < 200,
        "initial stream is staged to the playable bubble, backlog={}",
        w.debug_stream_backlog()
    );

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    let mut f = empty_frame();
    let mut draws: Vec<bf_draw_item> = Vec::new();
    let mut shadow: Vec<bf_draw_item> = Vec::new();
    let mut props: Vec<bf_prop_instance> = Vec::new();

    // Pump frames until the pool lands its first mesh in the draw list. The
    // budget is WALL-CLOCK, not a fixed frame count: worker throughput on a
    // loaded/QoS-throttled dev box can drop an order of magnitude (a fixed 120
    // frames flaked exactly that way), and this gate is about the pipeline
    // producing draws at all, not about how fast the box is today.
    let mut max_draws = 0u32;
    let start = std::time::Instant::now();
    while start.elapsed() < std::time::Duration::from_secs(90) {
        w.update(&zero, 0.016);
        w.build_frame(&mut f, &mut draws, &mut shadow, &mut props, 0.0);
        if f.draw_count > max_draws {
            max_draws = f.draw_count;
            break; // first draw proves the async gen->mesh->upload path works
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }

    assert!(
        max_draws > 0,
        "async worker pool meshed chunks into the draw list (got {max_draws} draws, backlog {})",
        w.debug_stream_backlog()
    );
}

// ============================================================================
// Fix 1 (#creative-sprint): creative sprint is a fast fly/run, ~5x survival sprint.
// ============================================================================
#[test]
fn creative_sprint_is_five_x_survival_sprint() {
    let mut w = World::new(None);

    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    let survival = w.debug_sprint_speed();

    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    let creative = w.debug_sprint_speed();

    let ratio = creative / survival;
    assert!(
        (ratio - 5.0).abs() < 0.01,
        "creative sprint should be ~5x survival sprint (survival {survival}, creative {creative}, ratio {ratio})"
    );
    // And it must clearly beat survival sprint (not just nominally faster).
    assert!(
        creative > survival * 4.0,
        "creative sprint clearly faster than survival sprint"
    );
}

// ============================================================================
// Fix 2 (#108 follow-up): ruin "danger sites" are CLEARABLE. A ruin spawns a small
// fixed band of defenders once; once the player kills them they do not immediately
// respawn while the player stays put.
// ============================================================================
#[test]
fn ruin_danger_site_is_clearable() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");
    let mut extra = ContentExtra::new();
    assert!(extra.load(CONTENT), "extra load");

    const SEED: u64 = 11;

    // Find the nearest ruin anchor by querying the deterministic danger-site lookup on
    // a grid (radius 64 == one struct cell, step 64 so no cell is skipped).
    let mut anchor: Option<(i32, i32, i32)> = None;
    let mut best_d2 = i64::MAX;
    for gz in (-3000..=3000).step_by(64) {
        for gx in (-3000..=3000).step_by(64) {
            if let Some(s @ (ax, _, az)) = worldgen::worldgen_dangerous_site_near(gx, gz, 64, SEED)
            {
                let d2 = (ax as i64) * (ax as i64) + (az as i64) * (az as i64);
                if d2 < best_d2 {
                    best_d2 = d2;
                    anchor = Some(s);
                }
            }
        }
    }
    let (ax, ay, az) = anchor.expect("expected at least one ruin for seed 11");

    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&content);
    w.set_extra(&extra);
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    w.init_world(SEED);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };

    // Stand the player right on the ruin so its chunk streams in and the danger-site
    // pass targets this anchor.
    w.debug_set_camera(ax as f32 + 0.5, ay as f32 + 20.0, az as f32 + 0.5, 0.0, 0.0);

    // Pump frames until the site has spawned its band of defenders. danger_timer fires
    // every 3s, so 0.5s steps give it room to spawn one per ~6 steps.
    let mut i = 0;
    while i < 600 && w.debug_ruin_hostile_count() < 3 {
        // Keep this state-machine harness above melee range. Finished ruin arches
        // are intentionally traversable, so an unattended player can otherwise die.
        w.debug_set_camera(ax as f32 + 0.5, ay as f32 + 20.0, az as f32 + 0.5, 0.0, 0.0);
        w.update(&zero, 0.5);
        i += 1;
    }
    let spawned = w.debug_ruin_hostile_count();
    assert_eq!(spawned, 3, "ruin spawned its fixed defender band");

    // Let it finish arming, then confirm the count is small + fixed (does not grow
    // without bound).
    for _ in 0..40 {
        w.debug_set_camera(ax as f32 + 0.5, ay as f32 + 20.0, az as f32 + 0.5, 0.0, 0.0);
        w.update(&zero, 0.5);
    }
    let armed = w.debug_ruin_hostile_count();
    assert!(
        armed <= 3,
        "ruin defender band stays small/fixed (got {armed}, expected <= 3)"
    );

    // Reward item ids (granted once when the ruin is cleared).
    let cake = w.debug_item_id("honey_cake");
    let ingot = w.debug_item_id("iron_ingot");
    let brick = w.debug_item_id("stone_brick");
    assert!(
        cake != 0 && ingot != 0 && brick != 0,
        "reward items exist in content"
    );
    // No reward yet (ruin not cleared).
    assert_eq!(
        w.debug_item_count(cake),
        0,
        "no reward before the ruin is cleared"
    );
    let ingot_before = w.debug_item_count(ingot);
    let brick_before = w.debug_item_count(brick);

    // Player clears the ruin: kill every defender.
    // Keep it at the site so the local danger pass can observe the clear.
    w.debug_set_camera(ax as f32 + 0.5, ay as f32 + 20.0, az as f32 + 0.5, 0.0, 0.0);
    let killed = w.debug_kill_ruin_hostiles();
    assert_eq!(killed, 3, "cleared the ruin defenders");
    assert_eq!(
        w.debug_ruin_hostile_count(),
        0,
        "no ruin hostiles left after clearing"
    );

    // The danger-site pass needs one tick to notice the defenders are gone, mark the
    // site cleared, and grant the reward. Stay put and keep pumping: the ruin must NOT
    // respawn its defenders, and the reward must land exactly once.
    for _ in 0..120 {
        w.debug_set_camera(ax as f32 + 0.5, ay as f32 + 20.0, az as f32 + 0.5, 0.0, 0.0);
        w.update(&zero, 0.5);
    }
    assert_eq!(
        w.debug_ruin_hostile_count(),
        0,
        "cleared ruin does not respawn defenders while the player stays put"
    );
    assert!(
        w.debug_ruin_site_cleared(ax, az),
        "the ruin site is recorded as cleared"
    );

    // Reward dropped exactly once: a handful of each item, and it does not keep growing
    // as we keep pumping frames on the cleared site.
    let cake_after = w.debug_item_count(cake);
    let ingot_after = w.debug_item_count(ingot);
    let brick_after = w.debug_item_count(brick);
    assert_eq!(
        cake_after, 2,
        "clearing the ruin dropped the food reward once"
    );
    assert_eq!(
        ingot_after - ingot_before,
        2,
        "clearing the ruin dropped the material reward once"
    );
    assert_eq!(
        brick_after - brick_before,
        4,
        "clearing the ruin dropped the block reward once"
    );

    // Pump more frames on the cleared site: the reward does not fire again.
    for _ in 0..40 {
        w.debug_set_camera(ax as f32 + 0.5, ay as f32 + 20.0, az as f32 + 0.5, 0.0, 0.0);
        w.update(&zero, 0.5);
    }
    assert_eq!(
        w.debug_item_count(cake),
        cake_after,
        "ruin reward fires only once"
    );
    assert_eq!(
        w.debug_item_count(brick),
        brick_after,
        "ruin reward fires only once"
    );
}

// ---------------------------------------------------------------------------
// Villager profession chain gating (never strand the player).
//
// npc_id roster: 1 Elder, 2 Builder, 3 Herbalist (social), and the tool chain
// 4 Woodcutter (wood) -> 5 Stone Mason (stone) -> 6 Blacksmith (iron). A higher
// chain tier must never appear without all lower tiers present in the same
// settlement: a city hosts the full chain, a village gets an ordered prefix.
// ---------------------------------------------------------------------------

const WOOD: i32 = 4;
const STONE: i32 = 5;
const IRON: i32 = 6;

// Returns the chain tiers (4/5/6) present among the first `size` villagers of a
// settlement, in the order the policy assigns them.
fn chain_tiers(is_city: bool, size: i32) -> Vec<i32> {
    let mut out = Vec::new();
    for i in 0..size {
        let role = World::debug_villager_npc_for_index(is_city, i);
        if role == WOOD || role == STONE || role == IRON {
            out.push(role);
        }
    }
    out
}

// A city that has reached the villager cap must contain the FULL chain (wood, stone,
// iron) and front-load it so progression can be completed early.
#[test]
fn city_hosts_full_profession_chain() {
    let tiers = chain_tiers(true, 6);
    assert!(
        tiers.contains(&WOOD),
        "city missing Woodcutter (wood): {tiers:?}"
    );
    assert!(
        tiers.contains(&STONE),
        "city missing Stone Mason (stone): {tiers:?}"
    );
    assert!(
        tiers.contains(&IRON),
        "city missing Blacksmith (iron): {tiers:?}"
    );
    let first_three = chain_tiers(true, 3);
    assert_eq!(
        first_three,
        vec![WOOD, STONE, IRON],
        "city should front-load the chain"
    );
}

// A village of ANY size must yield a chain that is a strict bottom-up prefix: stone
// never appears without wood, iron never without stone. Checked at every size from a
// lone hamlet up to past the cap.
#[test]
fn village_professions_are_a_chain_prefix() {
    for size in 1..=8 {
        let tiers = chain_tiers(false, size);
        // The SET of chain tiers present must be a bottom-up prefix of [wood, stone, iron]:
        // stone present implies wood present, iron present implies wood and stone present.
        let have_wood = tiers.contains(&WOOD);
        let have_stone = tiers.contains(&STONE);
        let have_iron = tiers.contains(&IRON);
        if have_stone {
            assert!(
                have_wood,
                "village size {size}: Stone Mason without Woodcutter: {tiers:?}"
            );
        }
        if have_iron {
            assert!(
                have_wood && have_stone,
                "village size {size}: Blacksmith without wood+stone prerequisites: {tiers:?}"
            );
        }
        // The first appearance of each tier must respect chain order: wood is introduced
        // before stone, stone before iron (a higher tier never debuts first). Repeats of a
        // lower tier afterwards are fine and do not strand the player.
        let first_of = |tier: i32| tiers.iter().position(|&t| t == tier);
        if let (Some(w), Some(s)) = (first_of(WOOD), first_of(STONE)) {
            assert!(
                w < s,
                "village size {size}: Stone debuts before Wood: {tiers:?}"
            );
        }
        if let (Some(s), Some(ir)) = (first_of(STONE), first_of(IRON)) {
            assert!(
                s < ir,
                "village size {size}: Iron debuts before Stone: {tiers:?}"
            );
        }
    }
    // A lone village (one villager) must be a Woodcutter, never a stranded high tier.
    assert_eq!(
        World::debug_villager_npc_for_index(false, 0),
        WOOD,
        "a lone village villager must be a Woodcutter (bottom of the chain)"
    );
    // A two-villager village must not yet contain stone or iron (only wood + a social).
    let two = chain_tiers(false, 2);
    assert_eq!(
        two,
        vec![WOOD],
        "a 2-villager village has only the wood tier of the chain"
    );
}

// read a NUL-terminated fixed byte buffer as a String slice.
fn cstr_str(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).to_string()
}

// A villager home must be a real, enterable building: a footprint of at least 5x5,
// a door opening (a 2 tall door = 2 door blocks), at least two windows, a standable
// interior air cavity (>= 3x3 = 9 cells), a bed inside, and it must sit on the
// ground (no floaters). Checked across several seeds so the variety in size /
// orientation is exercised. Block id 52 is the bed added to content/blocks.
#[test]
fn villager_home_is_a_real_building() {
    const BED_BLOCK: bfcore::types::BlockId = 52;
    let mut homes_with_6 = 0;
    for &seed in &[11u64, 7, 42, 1, 99] {
        let s = worldgen::worldgen_villager_home_scan(seed);

        assert!(
            s.width >= 5 && s.depth >= 5,
            "seed {seed}: home footprint {}x{} is smaller than 5x5",
            s.width,
            s.depth
        );
        assert_eq!(
            s.door_blocks, 2,
            "seed {seed}: home should have a 1 wide, 2 tall door opening (2 door blocks), got {}",
            s.door_blocks
        );
        assert!(
            s.window_blocks >= 2,
            "seed {seed}: home should have at least two windows, got {}",
            s.window_blocks
        );
        assert_eq!(
            s.beam_blocks, 12,
            "seed {seed}: home should use shaped beams only for four solid-wall corner posts, got {} beam cells",
            s.beam_blocks
        );
        assert!(
            s.roof_levels >= 4 && s.roof_overhang,
            "seed {seed}: home should have a pitched roof with eaves (levels={}, overhang={})",
            s.roof_levels,
            s.roof_overhang
        );
        assert!(
            s.interior_air >= 9,
            "seed {seed}: home interior cavity {} is smaller than a 3x3 standable space",
            s.interior_air
        );
        assert!(
            s.bed_blocks >= 1,
            "seed {seed}: home is missing a bed (block {BED_BLOCK})"
        );
        assert!(s.on_ground, "seed {seed}: home floats off the ground");

        if s.width >= 6 || s.depth >= 6 {
            homes_with_6 += 1;
        }
    }
    // Homes vary in size: across the seeds at least one is bigger than the minimum
    // 5x5 (a 6 wide footprint), proving they are not all identical boxes.
    assert!(
        homes_with_6 > 0,
        "expected at least one home larger than 5x5 across the seeds (size variety)"
    );
}

const ARTISAN_STATIONS: [(i32, i32, i32, u16); 5] = [
    (2, 6, 6, 61),
    (3, 4, -4, 60),
    (4, 4, 4, 56),
    (5, -4, 4, 58),
    (6, -4, -4, 59),
];

// #253 routine fixture: flat supported ground, one role's real station at its
// canonical settlement offset, and the player far enough away not to push work.
fn artisan_routine_world(
    role: i32,
    with_station: bool,
    blocked_work_cell: bool,
) -> (World<'static>, i32) {
    let content: &'static ContentRegistry = {
        let mut c = ContentRegistry::new();
        assert!(c.load(CONTENT));
        Box::leak(Box::new(c))
    };
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(content);
    w.generate_test_world();
    w.debug_set_camera(0.5, 12.0, 0.5, 0.0, 0.0);
    let &(_, dx, dz, station) = ARTISAN_STATIONS
        .iter()
        .find(|&&(candidate, _, _, _)| candidate == role)
        .expect("artisan role");
    let (sx, sz) = (8 + dx, 8 + dz);
    if with_station {
        w.debug_edit(sx, 8, sz, station);
    }
    if blocked_work_cell {
        w.debug_edit(sx - 1, 8, sz, world::GLOW); // west work cell must stay body-clear
    }
    let worker = w.debug_spawn_villager_role(8, 8, role);
    w.debug_set_creature_pos(worker, 8.5, 8.0, 8.5);
    (w, worker)
}

#[test]
fn every_artisan_role_uses_its_station_and_reports_a_full_shift() {
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    for &(role, dx, dz, station) in &ARTISAN_STATIONS {
        let (mut w, worker) = artisan_routine_world(role, true, false);
        let mut sequence = vec![1u32];
        for _ in 0..600 {
            w.update(&zero, 0.05);
            let action = w.debug_villager_routine_action(worker);
            if sequence.last().copied() != Some(action) {
                sequence.push(action);
            }
            if action == 3 {
                break;
            }
        }
        assert!(sequence.len() >= 3, "role {role} never reached work: {sequence:?}");
        assert_eq!(
            &sequence[..3],
            &[1, 2, 3],
            "role {role} shift order; pos={:?} path={} station={}/{} work_floor={} work_body={}",
            w.debug_creature_pos(worker),
            w.debug_creature_path_len(worker),
            w.debug_block_at(8 + dx, 8, 8 + dz),
            station,
            w.debug_block_at(7 + dx, 7, 8 + dz),
            w.debug_block_at(7 + dx, 8, 8 + dz),
        );
        let (x, y, z) = w.debug_creature_pos(worker);
        let (want_x, want_z) = ((8 + dx) as f32 - 0.5, (8 + dz) as f32 + 0.5);
        assert!(
            (x - want_x).abs() < 0.06 && (y - 8.0).abs() < 0.06 && (z - want_z).abs() < 0.06,
            "role {role} used the wrong west work cell: ({x:.2},{y:.2},{z:.2})"
        );

        for _ in 0..10 {
            w.update(&zero, 0.05);
        }
        let mut frame = empty_frame();
        let mut draws = Vec::new();
        let mut shadows = Vec::new();
        let mut props = Vec::new();
        w.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
        let actions = w.entity_role_actions();
        assert_eq!(actions.len(), frame.entity_count as usize);
        let action = actions
            .iter()
            .find(|entry| entry.role == role as u32)
            .expect("artisan sidecar entry");
        assert_eq!(action.action, 3, "role {role} sidecar must show work");
        assert!((0.05..1.0).contains(&action.progress));

        for _ in 0..160 {
            w.update(&zero, 0.05);
            if w.debug_villager_routine_action(worker) == 4 {
                break;
            }
        }
        assert_eq!(
            w.debug_villager_routine_action(worker),
            4,
            "role {role} did not naturally enter return"
        );
        for _ in 0..500 {
            w.update(&zero, 0.05);
            if w.debug_villager_routine_action(worker) == 1 {
                break;
            }
        }
        assert_eq!(w.debug_villager_routine_action(worker), 1, "role {role} did not return home");
    }
}

#[test]
fn woodcutter_walks_to_station_works_and_returns_home() {
    let (mut w, worker) = artisan_routine_world(4, true, false);
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    assert_eq!(w.debug_villager_routine_action(worker), 1, "shift starts idle");

    let mut sequence = vec![1u32];
    let mut locomotion_flag_seen = false;
    for _ in 0..600 {
        w.update(&zero, 0.05);
        let action = w.debug_villager_routine_action(worker);
        if sequence.last().copied() != Some(action) {
            sequence.push(action);
        }
        if action == 2 && !locomotion_flag_seen {
            let mut frame = empty_frame();
            let mut draws = Vec::new();
            let mut shadows = Vec::new();
            let mut props = Vec::new();
            w.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
            locomotion_flag_seen = w
                .entity_role_actions()
                .iter()
                .any(|entry| entry.role == 4 && entry._pad & 1 != 0);
        }
        if action == 3 {
            break;
        }
    }
    assert_eq!(&sequence[..3], &[1, 2, 3], "idle -> station travel -> work");
    assert!(
        locomotion_flag_seen,
        "travel sidecar selects the authored walk clip"
    );
    let (x, y, z) = w.debug_creature_pos(worker);
    assert!((x - 11.5).abs() < 0.06 && (y - 8.0).abs() < 0.06 && (z - 12.5).abs() < 0.06,
            "worker occupies the west work cell: ({x:.2},{y:.2},{z:.2})");

    // The additive v28 sidecar is aligned with the frozen draw list and exposes
    // role/action/progress without changing bf_entity_draw's 44-byte layout.
    for _ in 0..10 {
        w.update(&zero, 0.05);
    }
    let mut frame = empty_frame();
    let mut draws = Vec::new();
    let mut shadows = Vec::new();
    let mut props = Vec::new();
    w.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
    let roles = w.entity_role_actions();
    assert_eq!(roles.len(), frame.entity_count as usize, "sidecar stays index-aligned");
    assert_eq!((roles[0].role, roles[0].action), (4, 3));
    assert!(roles[0].progress > 0.05 && roles[0].progress < 1.0,
            "work phase advances deterministically: {}", roles[0].progress);

    // Removing the station during the shift cancels work immediately and sends
    // the villager to a clear home cell instead of leaving stale movement behind.
    // #248's city core places tall civic lamps on the four cardinal home
    // offsets. They must not be mistaken for a walkable roof on return.
    for (lx, lz) in [(6, 8), (8, 6), (10, 8), (8, 10)] {
        for ly in 8..=10 {
            w.debug_edit(lx, ly, lz, world::GLOW);
        }
    }
    w.debug_edit(12, 8, 12, world::AIR);
    w.update(&zero, 0.05);
    assert_eq!(w.debug_villager_routine_action(worker), 4, "removed station -> return home");
    for _ in 0..500 {
        w.update(&zero, 0.05);
        if w.debug_villager_routine_action(worker) == 1 {
            break;
        }
    }
    assert_eq!(w.debug_villager_routine_action(worker), 1, "return completes at idle");
    let (hx, hy, hz) = w.debug_creature_pos(worker);
    assert!((hx - 8.5).hypot(hz - 8.5) <= 3.1, "returned beside home: ({hx:.2},{hz:.2})");
    assert!(hy < 9.0, "return target stays on the plaza, not a civic lamp roof: y={hy}");
}

#[test]
fn woodcutter_missing_blocked_and_unreachable_station_falls_back() {
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    for (with_station, blocked) in [(false, false), (true, true)] {
        let (mut w, worker) = artisan_routine_world(4, with_station, blocked);
        let mut saw_work_or_travel = false;
        for _ in 0..180 {
            w.update(&zero, 0.05);
            saw_work_or_travel |= matches!(w.debug_villager_routine_action(worker), 2 | 3);
        }
        assert!(!saw_work_or_travel, "missing/blocked station never starts a false shift");
        assert_ne!(w.debug_villager_routine_action(worker), 3);
    }

    // Real path failure: seal the worker inside a three-block-high ring while the
    // station and its work cell remain valid. The bounded pathfinder returns no
    // route, routine movement cancels, and generic wander never fights it.
    let (mut w, worker) = artisan_routine_world(4, true, false);
    for dz in -1..=1 {
        for dx in -1..=1 {
            if dx == 0 && dz == 0 { continue; }
            for y in 8..=10 {
                w.debug_edit(8 + dx, y, 8 + dz, world::GLOW);
            }
        }
    }
    let start = w.debug_creature_pos(worker);
    for _ in 0..180 {
        w.update(&zero, 0.05);
    }
    let end = w.debug_creature_pos(worker);
    assert_ne!(w.debug_villager_routine_action(worker), 3, "unreachable station never works");
    assert_eq!(w.debug_creature_path_len(worker), 0, "failed routine leaves no stale path");
    assert!((end.0 - start.0).hypot(end.2 - start.2) < 0.1,
            "one controller holds position after failure: start={start:?} end={end:?}");
}

#[test]
fn villager_social_loop_is_visible_home_bound_and_cancels_failed_prop_paths() {
    let content: &'static ContentRegistry = {
        let mut c = ContentRegistry::new();
        assert!(c.load(CONTENT));
        Box::leak(Box::new(c))
    };
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(content);
    w.generate_test_world();
    w.debug_set_camera(0.5, 12.0, 0.5, 0.0, 0.0);
    w.debug_edit(8, 8, 14, 62); // communal bench, west interaction cell is clear
    w.debug_edit(8, 8, 2, 63); // broom stand
    let elder = w.debug_spawn_villager_role(8, 8, 1);
    let partner = w.debug_spawn_villager_role(8, 8, 2);
    w.debug_set_creature_pos(elder, 8.5, 8.0, 8.5);
    w.debug_set_creature_pos(partner, 10.5, 8.0, 8.5);
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };

    for wanted in 5..=10 {
        assert!(w.debug_force_villager_social_action(elder, wanted));
        for _ in 0..320 {
            w.update(&zero, 0.05);
            let (x, _, z) = w.debug_creature_pos(elder);
            assert!(
                (x - 8.5).abs().max((z - 8.5).abs()) <= 12.01,
                "social action {wanted} escaped its home radius: ({x:.2}, {z:.2})"
            );
            if w.debug_villager_social_action(elder) == wanted {
                break;
            }
        }
        assert_eq!(w.debug_villager_social_action(elder), wanted);

        let mut frame = empty_frame();
        let mut draws = Vec::new();
        let mut shadows = Vec::new();
        let mut props = Vec::new();
        w.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
        let elder_draw_index = w
            .entity_role_actions()
            .iter()
            .position(|entry| entry.role == 1)
            .expect("elder sidecar entry");
        let sidecar = &w.entity_role_actions()[elder_draw_index];
        assert_eq!(sidecar.action, wanted, "social pose reaches the v28 sidecar");

        if wanted == 9 {
            // #262: collision remains in the clear approach cell, while the
            // authored draw is centered on the west-facing bench seat and faces
            // back toward the room.
            let physical = w.debug_creature_pos(elder);
            assert!(
                (physical.0 - 7.5).abs() < 0.01 && (physical.2 - 14.5).abs() < 0.01,
                "collision body left the west approach cell: {physical:?}"
            );
            let entities = unsafe {
                std::slice::from_raw_parts(frame.entities, frame.entity_count as usize)
            };
            let seated = &entities[elder_draw_index];
            assert!(
                (seated.position.x - 8.5).abs() < 0.01,
                "seat x was {} (physical={physical:?}, yaw={})",
                seated.position.x,
                seated.yaw
            );
            assert!(
                (seated.position.y - 8.35).abs() < 0.01,
                "seat y was {}",
                seated.position.y
            );
            assert!(
                (seated.position.z - 14.5).abs() < 0.01,
                "seat z was {}",
                seated.position.z
            );
            assert!(
                seated.yaw.sin() < -0.99 && seated.yaw.cos().abs() < 0.01,
                "seat faced yaw {}",
                seated.yaw
            );

            w.debug_edit(8, 8, 14, world::AIR);
            w.update(&zero, 0.05);
            assert_eq!(w.debug_villager_social_action(elder), 0, "removed bench cancels sitting");
            assert_eq!(w.debug_creature_path_len(elder), 0, "cancel clears the old prop path");
        }
    }

    // A forced social action cannot override the home tether.
    w.debug_set_creature_pos(elder, 21.5, 8.0, 8.5);
    assert!(w.debug_force_villager_social_action(elder, 6));
    for _ in 0..320 {
        w.update(&zero, 0.05);
        let (x, _, z) = w.debug_creature_pos(elder);
        if (x - 8.5).abs().max((z - 8.5).abs()) <= 12.0 {
            break;
        }
    }
    let (x, _, z) = w.debug_creature_pos(elder);
    assert!((x - 8.5).abs().max((z - 8.5).abs()) <= 12.01, "elder returns inside tether");
    assert_eq!(w.debug_villager_social_action(elder), 0, "tether cancels social state");

    // Keep the real broom and its interaction cell valid, but seal the villager in.
    // The bounded path failure must cancel sweep without leaving stale movement.
    w.debug_set_creature_pos(elder, 8.5, 8.0, 8.5);
    for dz in -1..=1 {
        for dx in -1..=1 {
            if dx == 0 && dz == 0 { continue; }
            for y in 8..=10 {
                w.debug_edit(8 + dx, y, 8 + dz, world::GLOW);
            }
        }
    }
    assert!(w.debug_force_villager_social_action(elder, 10));
    w.update(&zero, 0.05);
    assert_eq!(w.debug_villager_social_action(elder), 0, "unreachable broom cancels sweep");
    assert_eq!(w.debug_creature_path_len(elder), 0, "failed sweep leaves no stale path");
}

#[test]
fn dialogue_holds_only_the_addressed_villager_until_close() {
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.generate_test_world();
    let villager = w.debug_spawn_villager_role(8, 8, 4);
    w.debug_set_creature_pos(villager, 21.5, 8.0, 8.5);
    let start = w.debug_creature_pos(villager);
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };

    assert!(w.debug_begin_villager_dialogue(villager));
    assert!(w.debug_villager_dialogue_held(villager));
    for _ in 0..80 {
        w.update(&zero, 0.05);
    }
    let held = w.debug_creature_pos(villager);
    assert!(
        (held.0 - start.0).hypot(held.2 - start.2) < 0.001,
        "dialogue villager moved: {start:?} -> {held:?}"
    );
    assert_eq!(w.debug_creature_path_len(villager), 0);

    w.action(&bf_action {
        kind: bf_action_kind::BF_ACT_INTERACT,
        arg_i: 2,
        arg_j: 0,
        arg_k: 0,
    });
    assert!(!w.debug_villager_dialogue_held(villager));
    for _ in 0..160 {
        w.update(&zero, 0.05);
    }
    let released = w.debug_creature_pos(villager);
    assert!(
        (released.0 - held.0).hypot(released.2 - held.2) > 0.5,
        "released villager stayed pinned: {released:?}"
    );
}

#[test]
fn woodcutter_station_goal_uses_nearest_torus_image() {
    let period = worldgen::WORLD_PERIOD;
    let (gx, gz) = World::debug_villager_nearest_goal(
        period as f32 - 1.5,
        100.5,
        1,
        104,
    );
    assert_eq!((gx, gz), (period + 1, 104));
    assert_eq!(gx - (period - 2), 3, "station across seam is three blocks ahead, not a world away");
}

// ============================================================================
// Natural movement (#131) — creatures CLIMB a 1-block step smoothly (over a few
// ticks) instead of teleporting their Y up a whole block in a single tick, and a
// wall taller than the climb cap stays unclimbable (the AI must go around).
// ============================================================================
#[test]
fn creature_climbs_step_smoothly() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_content(&content);
    w.set_allocator(allocator());

    // Flat test world: grass top at y=7, so the standable surface is y=8.
    w.generate_test_world();
    // Keep the maintain_creatures spawner from running (it self-gates on resident
    // count, but place the camera far so any spawns land away from our column too).
    w.debug_set_camera(8.5, 12.0, 8.5, 0.0, 0.0);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };

    // ---- 1-block step: a single solid block on top of the grass at x=11 makes the
    // surface there y=9. A creature walking +X into it should clamber up to y=9. ----
    w.debug_edit(11, 8, 11, world::STONE);
    // yaw with sin=1, cos=0 -> direction (1,0,0), straight at the step in +X.
    let yaw = std::f32::consts::FRAC_PI_2;
    let idx = w.debug_spawn_creature_at(9.5, 8.0, 11.5, yaw, 2.0);

    let mut ys: Vec<f32> = Vec::new();
    let mut reached_top = false;
    for _ in 0..120 {
        w.update(&zero, 0.05);
        let (_x, y, _z) = w.debug_creature_pos(idx);
        ys.push(y);
        if (y - 9.0).abs() < 0.05 {
            reached_top = true;
            break;
        }
    }
    assert!(
        reached_top,
        "creature climbed onto the 1-block step (ends at y=9)"
    );

    // The rise must be GRADUAL: count frames where Y sits strictly between the
    // start floor (8) and the step top (9). A single-tick pop would show zero or
    // one such frame; a smooth climb shows several.
    let mid_frames = ys.iter().filter(|&&y| y > 8.05 && y < 8.95).count();
    assert!(
        mid_frames >= 3,
        "Y rose gradually across several frames (saw {} mid-climb frames), not an instant pop",
        mid_frames
    );
    // And no single tick jumped a whole block (the old pop moved a full 1.0 at once).
    let mut max_jump = 0.0f32;
    for win in ys.windows(2) {
        let dy = (win[1] - win[0]).abs();
        if dy > max_jump {
            max_jump = dy;
        }
    }
    assert!(
        max_jump < 0.9,
        "no single tick teleported a whole block (max per-tick dy was {:.3})",
        max_jump
    );

    // ---- too-tall wall: a 3-block stack is above the climb cap (2), so the
    // creature must NOT climb it; it stays on the ground (y stays ~8). ----
    w.debug_edit(31, 8, 31, world::STONE);
    w.debug_edit(31, 9, 31, world::STONE);
    w.debug_edit(31, 10, 31, world::STONE);
    let idx2 = w.debug_spawn_creature_at(29.5, 8.0, 31.5, yaw, 2.0);
    let mut max_y2 = 8.0f32;
    for _ in 0..120 {
        w.update(&zero, 0.05);
        let (_x, y, _z) = w.debug_creature_pos(idx2);
        if y > max_y2 {
            max_y2 = y;
        }
    }
    assert!(
        max_y2 < 8.6,
        "a 3-block wall is NOT climbed (creature stayed near the ground, peak y={:.3})",
        max_y2
    );
}

// ============================================================================
// #109 chests: container state, deterministic loot, take/full-inventory, persist.
// ============================================================================

// A world with content loaded, a chest block placed at a fixed spot, and an empty
// player inventory. Returns (world, chest_xyz). The CHEST id comes from the engine
// constant so it tracks content.
fn chest_world(seed: u64) -> (World<'static>, (i32, i32, i32)) {
    // Leak the content so the World can borrow it for 'static in a test (the process
    // exits at test end; a small leak is harmless, like the malloc allocator above).
    let content: &'static ContentRegistry = {
        let mut c = ContentRegistry::new();
        assert!(c.load(CONTENT), "content load");
        Box::leak(Box::new(c))
    };
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(content);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(seed);
    // Place a chest near the spawn area at a known column and clear the inventory.
    let (cx, cy, cz) = (120, 80, 120);
    w.debug_edit(cx, cy, cz, world::CHEST);
    w.debug_clear_inventory();
    (w, (cx, cy, cz))
}

#[test]
fn chest_loot_is_deterministic_from_seed() {
    // Same seed + same position -> identical rolled loot, every time.
    let (mut a, pa) = chest_world(777);
    let (mut b, pb) = chest_world(777);
    assert_eq!(pa, pb);
    let mut any = false;
    for s in 0..world::CHEST_SLOTS {
        let ra = a.debug_chest_slot(pa.0, pa.1, pa.2, s);
        let rb = b.debug_chest_slot(pb.0, pb.1, pb.2, s);
        assert_eq!(
            ra, rb,
            "slot {} deterministic across two same-seed worlds",
            s
        );
        if ra.0 != 0 {
            any = true;
        }
    }
    assert!(any, "a chest rolls at least one non-empty stack");

    // A different seed produces different loot (overwhelmingly likely; assert the
    // whole slot vector is not byte-identical).
    let (mut c, pc) = chest_world(778);
    let mut differs = false;
    for s in 0..world::CHEST_SLOTS {
        if a.debug_chest_slot(pa.0, pa.1, pa.2, s) != c.debug_chest_slot(pc.0, pc.1, pc.2, s) {
            differs = true;
        }
    }
    assert!(differs, "a different seed rolls different chest loot");
}

#[test]
fn chest_take_moves_to_player_inventory() {
    let (mut w, p) = chest_world(42);
    let pos = IVec3 {
        x: p.0,
        y: p.1,
        z: p.2,
    };
    // Find a non-empty chest slot.
    let slots = w.chest_slots(pos).expect("chest present");
    let slot = (0..world::CHEST_SLOTS)
        .find(|&i| slots[i].item != 0)
        .expect("at least one filled slot");
    let item = slots[slot].item;
    let count = slots[slot].count;
    assert_eq!(
        w.debug_item_count(item),
        0,
        "inventory starts without this item"
    );

    assert!(w.chest_take(pos, slot), "take moved the stack");
    assert_eq!(
        w.debug_item_count(item),
        count as i32,
        "the whole stack landed in the inventory"
    );
    let after = w.chest_slots(pos).expect("chest present");
    assert_eq!(after[slot].item, 0, "the chest slot is now empty");

    // Re-querying (the panel reopening) shows the updated, reduced contents: taking the
    // now-empty slot again moves nothing.
    assert!(
        !w.chest_take(pos, slot),
        "taking an already-empty slot moves nothing"
    );
}

#[test]
fn chest_take_full_inventory_leaves_items() {
    let (mut w, p) = chest_world(42);
    let pos = IVec3 {
        x: p.0,
        y: p.1,
        z: p.2,
    };
    let slots = w.chest_slots(pos).expect("chest present");
    let slot = (0..world::CHEST_SLOTS)
        .find(|&i| slots[i].item != 0)
        .expect("at least one filled slot");
    let chest_item = slots[slot].item;
    let chest_count = slots[slot].count;

    // Jam the inventory full with a DIFFERENT item so nothing of the chest item fits.
    let filler = w.debug_item_id("dirt");
    assert_ne!(filler, 0, "content has dirt");
    assert_ne!(filler, chest_item, "filler differs from the chest item");
    w.debug_fill_inventory(filler, 64);

    let moved = w.chest_take(pos, slot);
    assert!(!moved, "nothing moved: the inventory was full");
    // The item is NOT destroyed: it is still in the chest, unchanged.
    let after = w.chest_slots(pos).expect("chest present");
    assert_eq!(
        after[slot].item, chest_item,
        "chest item preserved on a full inventory"
    );
    assert_eq!(
        after[slot].count, chest_count,
        "chest count preserved on a full inventory"
    );
    assert_eq!(
        w.debug_item_count(chest_item),
        0,
        "no chest item leaked into the full inventory"
    );
}

#[test]
fn chest_contents_persist_round_trip() {
    let dir = std::env::temp_dir().join("bf_chest_persist_rs");
    let dir = dir.to_string_lossy().to_string();
    let _ = std::fs::remove_dir_all(&dir);

    let pos = IVec3 {
        x: 120,
        y: 80,
        z: 120,
    };
    let (taken_item, remaining): (ItemId, [(ItemId, u16); 9]);

    // Session 1: open the chest (rolls loot), take one slot, then save.
    {
        let (mut w, p) = chest_world(31337);
        assert_eq!((p.0, p.1, p.2), (pos.x, pos.y, pos.z));
        let slots = w.chest_slots(pos).expect("chest present");
        let slot = (0..world::CHEST_SLOTS)
            .find(|&i| slots[i].item != 0)
            .expect("a filled slot");
        taken_item = slots[slot].item;
        assert!(w.chest_take(pos, slot), "took a stack");
        let after = w.chest_slots(pos).expect("chest present");
        let mut snap = [(0u16, 0u16); 9];
        for i in 0..world::CHEST_SLOTS {
            snap[i] = (after[i].item, after[i].count);
        }
        remaining = snap;
        assert!(w.save(&dir), "save succeeded");
        let _ = taken_item;
    }

    // Session 2: load and confirm the chest's REMAINING contents survived the reload.
    {
        let content: &'static ContentRegistry = {
            let mut c = ContentRegistry::new();
            assert!(c.load(CONTENT), "content load");
            Box::leak(Box::new(c))
        };
        let mut w = World::new(Some(TerrainGen::new()));
        w.debug_set_sync_streaming(true);
        w.set_allocator(allocator());
        w.set_content(content);
        assert!(w.load(&dir), "load succeeded");
        // The chest block itself persisted via the chunk edit.
        assert_eq!(
            w.debug_block_at(pos.x, pos.y, pos.z),
            world::CHEST,
            "chest block persisted"
        );
        let slots = w.chest_slots(pos).expect("chest present after reload");
        for i in 0..world::CHEST_SLOTS {
            assert_eq!(
                (slots[i].item, slots[i].count),
                remaining[i],
                "chest slot {} survived the reload unchanged",
                i
            );
        }
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn chest_deposit_moves_from_inventory() {
    let (mut w, p) = chest_world(9000);
    let pos = IVec3 {
        x: p.0,
        y: p.1,
        z: p.2,
    };
    // Empty the chest so deposits land in clean slots, and give the player an item.
    for s in 0..world::CHEST_SLOTS {
        let _ = w.chest_take(pos, s);
    }
    let item = w.debug_item_id("stone");
    assert_ne!(item, 0, "content has stone");
    w.debug_clear_inventory();
    w.debug_give(item, 10);
    assert_eq!(w.debug_item_count(item), 10);

    // Deposit from inventory slot 0 (debug_give fills the first empty slot, slot 0).
    assert!(w.chest_deposit(pos, 0), "deposit moved the stack");
    assert_eq!(w.debug_item_count(item), 0, "the stack left the inventory");
    let slots = w.chest_slots(pos).expect("chest present");
    let in_chest: u16 = slots
        .iter()
        .filter(|s| s.item == item)
        .map(|s| s.count)
        .sum();
    assert_eq!(in_chest, 10, "the stack landed in the chest");
}

// ============================================================================
// Living villages (#95): donation tiers (wood -> stone -> iron), persistence,
// walls-keep-monsters-out, and deterministic generation.
// ============================================================================

// A creative world with content + extra loaded, ready for donation tests. Returns the
// world and a known on-land settlement anchor (ax, az) for the seed.
fn village_world(seed: u64) -> (World<'static>, (i32, i32)) {
    let content: &'static ContentRegistry = {
        let mut c = ContentRegistry::new();
        assert!(c.load(CONTENT), "content load");
        Box::leak(Box::new(c))
    };
    let extra: &'static ContentExtra = {
        let mut x = ContentExtra::new();
        assert!(x.load(CONTENT), "extra load");
        Box::leak(Box::new(x))
    };
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(content);
    w.set_extra(extra);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(seed);
    // Find a dry-land column to anchor a synthetic settlement (so the palisade footing
    // never tries to sit in water). #172 made biomes ~4x the area, so suitable high
    // ground can sit much farther from the origin than the old short ray scan reached:
    // walk expanding square rings and take the first qualifying column.
    let mut anchor = (204, 0);
    'find: for r in (0..=2048i32).step_by(32) {
        for v in (-r..=r).step_by(32) {
            for &(sx, sz) in &[(r, v), (-r, v), (v, r), (v, -r)] {
                let h = worldgen::worldgen_surface_height(sx, sz, seed);
                if h <= 36 || worldgen::worldgen_is_ocean_col(sx, sz, seed) {
                    continue;
                }
                // The palisade ring needs roughly level footing; a steep
                // mountainside leaves wall gaps a hostile can walk through.
                let flat = [(8, 0), (-8, 0), (0, 8), (0, -8)].iter().all(|&(dx, dz)| {
                    (worldgen::worldgen_surface_height(sx + dx, sz + dz, seed) - h).abs() <= 3
                });
                if flat {
                    anchor = (sx, sz);
                    break 'find;
                }
            }
        }
    }
    w.debug_clear_inventory();
    (w, anchor)
}

#[test]
fn village_woodcutter_builds_wall_to_tier1() {
    let (mut w, (ax, az)) = village_world(11);
    let wc = w.debug_spawn_villager_role(ax, az, 4); // woodcutter
    let log = w.debug_item_id("oak_log");
    assert_ne!(log, 0, "content has oak_log");
    assert_eq!(w.debug_village_tier(ax, az), 0, "starts at tier 0");

    // One donation uses the whole useful held stack instead of the old eight-log cap.
    let total = World::debug_palisade_cells_total();
    w.debug_give(log, 64);
    w.debug_set_selected(0);
    assert!(w.debug_try_donation(wc));
    assert_eq!(w.debug_count_wall(ax, az, 21), 32);
    assert_eq!(w.debug_item_count(log), 0);

    // Refill only as needed to finish a wall larger than one inventory stack.
    for _ in 0..3 {
        w.debug_clear_inventory();
        w.debug_give(log, 64);
        w.debug_set_selected(0);
        let _ = w.debug_try_donation(wc);
        if w.debug_count_wall(ax, az, 21) >= total {
            break;
        }
    }
    assert!(
        w.debug_count_wall(ax, az, 21) >= total,
        "wood palisade ring is complete ({} of {})",
        w.debug_count_wall(ax, az, 21),
        total
    );
    assert_eq!(
        w.debug_item_count(log),
        64 - (total - 32) * 2,
        "the final donation keeps logs the wall did not use"
    );
    assert_eq!(
        w.debug_village_tier(ax, az),
        1,
        "tier advances to 1 (wood) when ring closes"
    );
}

#[test]
fn natural_city_is_complete_and_logs_cannot_regress_stone_growth() {
    let (mut city, _) = village_world(11);
    let (px, _, pz, _) = city.get_player();
    let (typ, cx, cz) = worldgen::worldgen_settlement_near(px as i32, pz as i32, 80, 11)
        .expect("fresh HOME city");
    assert!(worldgen::worldgen_is_city(typ));
    assert_eq!(city.debug_settlement_class(cx, cz), 2);
    assert_eq!(city.debug_village_raw_tier(cx, cz), 0);
    assert_eq!(city.debug_village_tier(cx, cz), 3, "natural city reports complete");

    let worker = city.debug_spawn_villager_role(cx, cz, 4);
    let log = city.debug_item_id("oak_log");
    city.debug_give(log, 8);
    city.debug_set_selected(0);
    let before = city.debug_item_count(log);
    assert!(city.debug_try_donation(worker), "complete city explicitly refuses");
    assert_eq!(city.debug_item_count(log), before, "city consumes no donation");
    assert_eq!(city.debug_village_raw_tier(cx, cz), 0);

    let (mut town, (ax, az)) = village_world(11);
    town.debug_set_village_tier(ax, az, 2);
    let worker = town.debug_spawn_villager_role(ax, az, 4);
    let log = town.debug_item_id("oak_log");
    town.debug_give(log, 8);
    town.debug_set_selected(0);
    let before = town.debug_item_count(log);
    assert!(town.debug_try_donation(worker));
    assert_eq!(town.debug_item_count(log), before, "stone town consumes no logs");
    assert_eq!(town.debug_village_raw_tier(ax, az), 2, "wood never regresses stone");
}

#[test]
fn town_blacksmith_and_city_herbalist_keep_active_trade_sheets() {
    let (world, _) = village_world(11);
    assert_eq!(World::debug_villager_npc_for_index(false, 4), 6);
    assert_eq!(World::debug_villager_npc_for_index(false, 5), 3);

    let mut blacksmith = bf_trade_view::default();
    world.trade_offers(6, &mut blacksmith);
    assert_eq!(blacksmith.active, 1, "Town Blacksmith trades");
    assert!(blacksmith.offer_count > 0);

    let mut herbalist = bf_trade_view::default();
    world.trade_offers(3, &mut herbalist);
    assert_eq!(herbalist.active, 1, "City Herbalist trades");
    assert!(herbalist.offer_count > 0);
}

#[test]
fn village_mason_upgrades_wood_to_stone_tier2() {
    let (mut w, (ax, az)) = village_world(11);
    let mason = w.debug_spawn_villager_role(ax, az, 5);
    let stone = w.debug_item_id("stone_brick");
    assert_ne!(stone, 0, "content has stone_brick");

    // Build a complete wood ring first (the mason refuses before tier 1).
    let wc = w.debug_spawn_villager_role(ax, az, 4);
    let log = w.debug_item_id("oak_log");
    let total = World::debug_palisade_cells_total();
    for _ in 0..40 {
        w.debug_clear_inventory();
        w.debug_give(log, 8);
        w.debug_set_selected(0);
        let _ = w.debug_try_donation(wc);
        if w.debug_count_wall(ax, az, 21) >= total {
            break;
        }
    }
    assert_eq!(w.debug_village_tier(ax, az), 1, "tier 1 reached");
    let wood_before = w.debug_count_wall(ax, az, 21);
    assert!(wood_before > 0, "wood wall stands before mason upgrade");

    // Donate stone in two batches: the completing batch consumes only the six
    // still needed, not another fixed sixteen from the held stack.
    w.debug_clear_inventory();
    w.debug_give(stone, 10);
    w.debug_set_selected(0);
    let _ = w.debug_try_donation(mason);
    assert_eq!(w.debug_village_tier(ax, az), 1);
    w.debug_clear_inventory();
    w.debug_give(stone, 64);
    w.debug_set_selected(0);
    let _ = w.debug_try_donation(mason);
    assert_eq!(w.debug_item_count(stone), 58);
    assert_eq!(
        w.debug_village_tier(ax, az),
        2,
        "tier advances to 2 (stone)"
    );
    let stone_wall = w.debug_count_wall(ax, az, 8);
    let wood_after = w.debug_count_wall(ax, az, 21);
    assert!(
        stone_wall > 0,
        "wall is now stone brick ({} cells)",
        stone_wall
    );
    assert!(
        wood_after < wood_before,
        "wood wall cells were converted to stone"
    );
}

#[test]
fn mason_dialogue_accepts_all_stone_materials_without_a_camera_target() {
    let (mut w, (ax, az)) = village_world(11);
    w.debug_set_village_tier(ax, az, 1);
    let mason = w.debug_spawn_villager_role(ax, az, 5);
    let donate = bf_action {
        kind: bf_action_kind::BF_ACT_INTERACT,
        arg_i: 1,
        arg_j: 0,
        arg_k: 0,
    };

    for (name, count) in [("stone", 5), ("cobblestone", 5), ("stone_brick", 6)] {
        let material = w.debug_item_id(name);
        w.debug_clear_inventory();
        w.debug_give(material, count);
        w.debug_set_selected(0);
        // The camera is nowhere near the Mason: the active dialogue owns the target.
        w.debug_set_camera(1000.5, 40.0, 1000.5, 0.0, 0.0);
        assert!(w.debug_begin_villager_dialogue(mason));
        w.action(&donate);
        assert_eq!(w.debug_item_count(material), 0, "Mason rejected {name}");
    }
    assert_eq!(w.debug_village_tier(ax, az), 2);

    let dirt = w.debug_item_id("dirt");
    w.debug_clear_inventory();
    w.debug_give(dirt, 1);
    w.debug_set_selected(0);
    assert!(w.debug_begin_villager_dialogue(mason));
    w.action(&donate);
    assert!(w.debug_ach_toast().contains("stone, cobblestone, or stone bricks"));
}

#[test]
fn village_blacksmith_adds_iron_gate_tier3() {
    let (mut w, (ax, az)) = village_world(11);
    let bs = w.debug_spawn_villager_role(ax, az, 6);
    let iron = w.debug_item_id("iron_ingot");
    assert_ne!(iron, 0, "content has iron_ingot");

    // Fast-forward through wood + stone by donating to each role.
    let wc = w.debug_spawn_villager_role(ax, az, 4);
    let log = w.debug_item_id("oak_log");
    let total = World::debug_palisade_cells_total();
    for _ in 0..40 {
        w.debug_clear_inventory();
        w.debug_give(log, 8);
        w.debug_set_selected(0);
        let _ = w.debug_try_donation(wc);
        if w.debug_count_wall(ax, az, 21) >= total {
            break;
        }
    }
    let mason = w.debug_spawn_villager_role(ax, az, 5);
    let stone = w.debug_item_id("stone_brick");
    w.debug_clear_inventory();
    w.debug_give(stone, 64);
    w.debug_set_selected(0);
    let _ = w.debug_try_donation(mason);
    assert_eq!(
        w.debug_village_tier(ax, az),
        2,
        "reached tier 2 before iron"
    );

    // Partial progress plus an oversized final stack consumes exactly eight total.
    w.debug_clear_inventory();
    w.debug_give(iron, 3);
    w.debug_set_selected(0);
    let _ = w.debug_try_donation(bs);
    assert_eq!(w.debug_village_tier(ax, az), 2);
    w.debug_clear_inventory();
    w.debug_give(iron, 16);
    w.debug_set_selected(0);
    let _ = w.debug_try_donation(bs);
    assert_eq!(w.debug_item_count(iron), 11);
    assert_eq!(w.debug_village_tier(ax, az), 3, "tier advances to 3 (iron)");
    // Iron gate (block id 53) stands somewhere in the south gate columns.
    let mut iron_blocks = 0;
    for dx in -1..=2 {
        let wx = ax + dx;
        let wz = az + 8; // PALISADE_R
        for wy in 0..=140 {
            if w.debug_block_at(wx, wy, wz) == 53 {
                iron_blocks += 1;
            }
        }
    }
    assert!(
        iron_blocks > 0,
        "an iron gate (block 53) was placed at the south opening"
    );
}

#[test]
fn eight_village_torches_restore_a_boundary_safe_persistent_ward() {
    let (mut w, _) = village_world(11);
    let (px, _, pz, _) = w.get_player();
    let (_, ax, az) = worldgen::worldgen_settlement_near(px as i32, pz as i32, 80, 11)
        .expect("spawn settlement");
    w.debug_clear_region_saturation();
    let center = (chunk_of(ax), chunk_of(az));
    assert!(w.debug_region_sat(center.0, center.1) < 0.99);

    for n in 1..=8 {
        assert!(w.debug_note_village_torch(ax + n, 8, az));
        assert_eq!(w.debug_village_lights(ax, az), n as u8);
        if n < 8 {
            assert!(w.debug_region_sat(center.0, center.1) < 0.99);
        }
    }
    for dz in -1..=1 {
        for dx in -1..=1 {
            assert!(
                w.debug_region_sat(center.0 + dx * 8, center.1 + dz * 8) > 0.99,
                "ward missed region offset ({dx}, {dz})"
            );
        }
    }
    let view = w.village_view_nearest().expect("ward village remains visible to HUD");
    assert_eq!(view.7, 8, "HUD reports the completed eight-light ward");

    let dir = std::env::temp_dir().join(format!("bf_village_ward_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    assert!(w.save(dir.to_str().unwrap()));

    let mut loaded = World::new(Some(TerrainGen::new()));
    loaded.debug_set_sync_streaming(true);
    loaded.set_allocator(allocator());
    assert!(loaded.load(dir.to_str().unwrap()));
    assert_eq!(loaded.debug_village_lights(ax, az), 8);
    assert!(loaded.debug_region_sat(center.0, center.1) > 0.99);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn village_tier_persists_round_trip() {
    let dir = std::env::temp_dir().join(format!("bf_village_save_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.to_str().unwrap().to_string();

    let (ax, az);
    {
        let (mut w, anchor) = village_world(11);
        ax = anchor.0;
        az = anchor.1;
        // Drive to tier 2 (wood then stone).
        let wc = w.debug_spawn_villager_role(ax, az, 4);
        let log = w.debug_item_id("oak_log");
        let total = World::debug_palisade_cells_total();
        for _ in 0..40 {
            w.debug_clear_inventory();
            w.debug_give(log, 8);
            w.debug_set_selected(0);
            let _ = w.debug_try_donation(wc);
            if w.debug_count_wall(ax, az, 21) >= total {
                break;
            }
        }
        let mason = w.debug_spawn_villager_role(ax, az, 5);
        let stone = w.debug_item_id("stone_brick");
        w.debug_clear_inventory();
        w.debug_give(stone, 64);
        w.debug_set_selected(0);
        let _ = w.debug_try_donation(mason);
        assert_eq!(w.debug_village_tier(ax, az), 2, "tier 2 before save");
        assert!(w.save(&path), "save");
    }

    // Fresh world, load, and confirm the tier survived.
    {
        let content: &'static ContentRegistry = {
            let mut c = ContentRegistry::new();
            assert!(c.load(CONTENT));
            Box::leak(Box::new(c))
        };
        let mut w2 = World::new(Some(TerrainGen::new()));
        w2.debug_set_sync_streaming(true);
        w2.set_allocator(allocator());
        w2.set_content(content);
        assert!(w2.load(&path), "load");
        assert_eq!(
            w2.debug_village_tier(ax, az),
            2,
            "tier 2 restored after reload"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn artisan_growth_preserves_player_blocks_through_promotion_and_load() {
    let dir = std::env::temp_dir().join(format!("bf_growth_save_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.to_str().unwrap().to_string();
    let seed = 11;
    let (mut world, _) = village_world(seed);
    let mut village = None;
    'scan: for z in (-4096..4096).step_by(64) {
        for x in (-4096..4096).step_by(64) {
            let (typ, ax, az, _) = worldgen::worldgen_structure_near(x, z, seed);
            if typ == 8 {
                village = Some((ax, az));
                break 'scan;
            }
        }
    }
    let (ax, az) = village.expect("generated village");
    let shop_cell = |dx: i32, dz: i32| {
        let sx = ax + dx;
        let sz = az + dz;
        let floor = worldgen::worldgen_surface_height(sx, sz, seed)
            .max(worldgen::worldgen_surface_height(sx - 1, sz, seed))
            .max(7);
        (sx, floor + 3, sz + 2)
    };
    let player = shop_cell(-4, -4);
    let clean = shop_cell(-4, 4);
    let _ = world.debug_generate_chunk_at(player.0, player.1, player.2);
    let _ = world.debug_generate_chunk_at(clean.0, clean.1, clean.2);
    world.debug_edit(player.0, player.1, player.2, world::BRICK);

    world.debug_set_village_tier(ax, az, 2);
    assert_eq!(
        world.debug_block_at(player.0, player.1, player.2),
        world::BRICK,
        "promotion never overwrites the player shop block"
    );
    assert_eq!(
        world.debug_block_at(clean.0, clean.1, clean.2),
        24,
        "clean mason plot grows its pitched roof"
    );
    assert!(world.save(&path));

    let content: &'static ContentRegistry = {
        let mut c = ContentRegistry::new();
        assert!(c.load(CONTENT));
        Box::leak(Box::new(c))
    };
    let mut loaded = World::new(Some(TerrainGen::new()));
    loaded.debug_set_sync_streaming(true);
    loaded.set_allocator(allocator());
    loaded.set_content(content);
    assert!(loaded.load(&path));
    let _ = loaded.debug_generate_chunk_at(clean.0, clean.1, clean.2);
    assert_eq!(loaded.debug_block_at(player.0, player.1, player.2), world::BRICK);
    assert_eq!(loaded.debug_block_at(clean.0, clean.1, clean.2), 24);
    assert_eq!(loaded.debug_village_raw_tier(ax, az), 2);

    let _ = std::fs::remove_dir_all(&dir);
}

fn route_for_anchor(world: &World<'_>, ax: i32, az: i32, tier: u8) -> Option<usize> {
    let delta = |d: i32| {
        (d + worldgen::WORLD_PERIOD / 2).rem_euclid(worldgen::WORLD_PERIOD)
            - worldgen::WORLD_PERIOD / 2
    };
    (0..world.debug_road_route_count()).find(|&i| {
        let Some(r) = world.debug_road_route(i) else {
            return false;
        };
        let distance = |x: i32, z: i32| delta(x - ax).abs().max(delta(z - az).abs());
        r.6 == tier && distance(r.0, r.1).min(distance(r.4, r.5)) == 9
    })
}

fn develop_tier2_route(world: &mut World<'_>, seed: u64) -> (i32, i32, usize) {
    for z in (-4096..4096).step_by(64) {
        for x in (-4096..4096).step_by(64) {
            let (typ, ax, az, _) = worldgen::worldgen_structure_near(x, z, seed);
            if typ != 8 {
                continue;
            }
            world.debug_set_village_tier(ax, az, 2);
            if let Some(route) = route_for_anchor(world, ax, az, 2) {
                return (ax, az, route);
            }
        }
    }
    panic!("seed {seed} has no independent tier-2 village route");
}

#[test]
fn developed_roads_stream_upgrade_and_preserve_player_edits() {
    let (mut w, _) = village_world(11);
    let (ax, az, route) = develop_tier2_route(&mut w, 11);
    let (core_y, wet) = worldgen::worldgen_road_surface(ax, az, 11);
    assert!(!wet, "settlement anchors are dry");
    let _ = w.debug_generate_chunk_at(ax, core_y, az);
    let core_before = w.debug_block_at(ax, core_y, az);

    assert!(w.debug_road_route_count() > 0, "tier 2 creates a route");
    assert_eq!(
        w.debug_road_material_at(ax, az),
        world::AIR,
        "the city core is protected from the route overlay"
    );
    assert_eq!(
        w.debug_block_at(ax, core_y, az),
        core_before,
        "tier promotion leaves the procedural city core untouched"
    );

    let first_gate = w.debug_road_sample(route, 0).expect("route starts at a gate");
    let last_gate = w
        .debug_road_sample(route, w.debug_road_sample_count(route) - 1)
        .expect("route ends at a gate");
    let wrap_delta = |d: i32| {
        (d + worldgen::WORLD_PERIOD / 2).rem_euclid(worldgen::WORLD_PERIOD)
            - worldgen::WORLD_PERIOD / 2
    };
    let gate_distance = |p: (i32, i32, i32)| {
        wrap_delta(p.0 - ax)
            .abs()
            .max(wrap_delta(p.1 - az).abs())
    };
    let (gate_x, gate_z, _) = if gate_distance(first_gate) < gate_distance(last_gate) {
        first_gate
    } else {
        last_gate
    };
    assert_eq!(
        gate_distance((gate_x, gate_z, 0)),
        9,
        "regional road begins immediately outside the settlement gate"
    );
    assert_ne!(
        w.debug_road_material_at(gate_x, gate_z),
        world::AIR,
        "the broad structure reserve does not leave a 51-block endpoint gap"
    );

    let count = w.debug_road_sample_count(route);
    let (road_x, road_z, road_y) = (0..count)
        .filter_map(|i| w.debug_road_sample(route, i))
        .find(|&(x, z, _)| {
            !worldgen::worldgen_structure_footprint(x, z, 11)
                && !worldgen::worldgen_road_surface(x, z, 11).1
        })
        .expect("route reaches dry natural terrain outside protected structures");
    let (surface_y, _) = worldgen::worldgen_road_surface(road_x, road_z, 11);
    let _ = w.debug_generate_chunk_at(road_x, surface_y, road_z);
    let _ = w.debug_generate_chunk_at(road_x, road_y, road_z);
    assert_eq!(w.debug_road_material_at(road_x, road_z), 11, "tier 2 is gravel");
    assert_eq!(
        w.debug_block_at(road_x, road_y, road_z),
        11,
        "gravel overlays an actual road cell outside the settlement"
    );

    w.debug_set_village_tier(ax, az, 3);
    assert_eq!(w.debug_road_material_at(road_x, road_z), 10, "tier 3 is cobblestone");
    assert_eq!(
        w.debug_block_at(road_x, road_y, road_z),
        10,
        "resident route upgrades in place"
    );

    let (far_x, far_z, far_y) = (count / 2..count)
        .filter_map(|i| w.debug_road_sample(route, i))
        .find(|&(x, z, _)| {
            !worldgen::worldgen_structure_footprint(x, z, 11)
                && (x.div_euclid(32), z.div_euclid(32))
                    != (road_x.div_euclid(32), road_z.div_euclid(32))
        })
        .expect("route has an unstreamed middle cell");
    let (far_surface, _) = worldgen::worldgen_road_surface(far_x, far_z, 11);
    let _ = w.debug_generate_chunk_at(far_x, far_surface, far_z);
    let _ = w.debug_generate_chunk_at(far_x, far_y, far_z);
    assert_eq!(
        w.debug_block_at(far_x, far_y, far_z),
        w.debug_road_material_at(far_x, far_z),
        "a newly inserted route chunk receives the derived overlay"
    );

    w.debug_edit(road_x, road_y, road_z, world::BRICK);
    w.debug_set_village_tier(ax, az, 3);
    assert_eq!(
        w.debug_block_at(road_x, road_y, road_z),
        world::BRICK,
        "a player-edited vertical chunk column wins over road refresh"
    );
}

#[test]
fn road_routes_rebuild_from_saved_tiers_without_a_road_file() {
    let dir = std::env::temp_dir().join(format!("bf_road_save_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.to_str().unwrap().to_string();
    let (ax, az, route_before, road_cell);

    {
        let (mut w, _) = village_world(42);
        let developed = develop_tier2_route(&mut w, 42);
        ax = developed.0;
        az = developed.1;
        let route = developed.2;
        route_before = w.debug_road_route(route).expect("tier creates route");
        road_cell = (0..w.debug_road_sample_count(route))
            .filter_map(|i| w.debug_road_sample(route, i))
            .find(|&(x, z, _)| !worldgen::worldgen_structure_footprint(x, z, 42))
            .expect("saved route exits the protected settlement footprint");
        assert!(w.save(&path));
    }

    assert!(dir.join("villages.dat").exists());
    assert!(!dir.join("roads.dat").exists(), "roads have no independent save file");

    {
        let content: &'static ContentRegistry = {
            let mut c = ContentRegistry::new();
            assert!(c.load(CONTENT));
            Box::leak(Box::new(c))
        };
        let mut loaded = World::new(Some(TerrainGen::new()));
        loaded.debug_set_sync_streaming(true);
        loaded.set_allocator(allocator());
        loaded.set_content(content);
        assert!(loaded.load(&path));
        assert_eq!(loaded.debug_village_tier(ax, az), 2);
        let route = route_for_anchor(&loaded, ax, az, 2).expect("loaded town route");
        assert_eq!(loaded.debug_road_route(route), Some(route_before));
        let (x, z, y) = road_cell;
        let (surface_y, _) = worldgen::worldgen_road_surface(x, z, 42);
        let _ = loaded.debug_generate_chunk_at(x, surface_y, z);
        let _ = loaded.debug_generate_chunk_at(x, y, z);
        assert_eq!(
            loaded.debug_block_at(x, y, z),
            loaded.debug_road_material_at(x, z),
            "seed plus loaded tier reconstructs the same visible road"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn nearby_caravan_advances_and_joins_the_render_sidecar() {
    let (mut w, _) = village_world(11);
    assert!(
        w.debug_road_route_count() > 0,
        "HOME city has a trade route"
    );
    let (sample, (x, z, y)) = (0..w.debug_road_sample_count(0))
        .filter_map(|sample| w.debug_road_sample(0, sample).map(|point| (sample, point)))
        .find(|(_, (x, z, _))| !worldgen::worldgen_structure_footprint(*x, *z, 11))
        .expect("route reaches an unprotected paved cell");
    // Caravan progress is 1/256 block fixed point; put this fixture on the road
    // rather than assuming the route's lexicographically first endpoint is a city.
    assert!(w.debug_set_caravan_state(0, sample as u32 * 256, true, 0, 0));
    let _ = w.debug_generate_chunk_at(x, y, z);
    assert_ne!(w.debug_block_at(x, y, z), world::AIR);
    w.debug_set_camera(x as f32 + 0.5, y as f32 + 3.0, z as f32 + 0.5, 0.0, 0.0);
    assert!(w.debug_caravan_visible());

    let before = w.debug_caravan_state(0).unwrap().0;
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    w.update(&zero, 0.1);
    assert!(
        w.debug_caravan_state(0).unwrap().0 > before,
        "the normal world update advances the nearby physical route"
    );

    let mut frame = empty_frame();
    let mut draws = Vec::new();
    let mut shadows = Vec::new();
    let mut props = Vec::new();
    w.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
    let entities =
        unsafe { std::slice::from_raw_parts(frame.entities, frame.entity_count as usize) };
    let caravan_indices: Vec<usize> = entities
        .iter()
        .enumerate()
        .filter_map(|(index, entity)| (entity.kind == 27).then_some(index))
        .collect();
    assert_eq!(
        caravan_indices.len(),
        1,
        "exactly one merchant cart is drawn"
    );
    let sidecar = w.entity_role_actions();
    assert_eq!(
        sidecar.len(),
        entities.len(),
        "v28 sidecar remains index-aligned"
    );
    let action = sidecar[caravan_indices[0]];
    assert_eq!((action.role, action.action, action.progress), (0, 0, 0.0));

    w.debug_set_camera(
        (x + 256).rem_euclid(worldgen::WORLD_PERIOD) as f32 + 0.5,
        y as f32 + 3.0,
        z as f32 + 0.5,
        0.0,
        0.0,
    );
    assert!(
        !w.debug_caravan_visible(),
        "the physical cart is nearby-only"
    );
    w.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
    let entities =
        unsafe { std::slice::from_raw_parts(frame.entities, frame.entity_count as usize) };
    assert!(entities.iter().all(|entity| entity.kind != 27));
}

#[test]
fn village_wall_marks_protected_interior() {
    let (mut w, (ax, az)) = village_world(11);
    // Before any donation, nothing is protected.
    assert!(
        !w.debug_village_protects(ax, az),
        "no protection before tier 1"
    );
    // Build the wood ring to reach tier 1.
    let wc = w.debug_spawn_villager_role(ax, az, 4);
    let log = w.debug_item_id("oak_log");
    let total = World::debug_palisade_cells_total();
    for _ in 0..40 {
        w.debug_clear_inventory();
        w.debug_give(log, 8);
        w.debug_set_selected(0);
        let _ = w.debug_try_donation(wc);
        if w.debug_count_wall(ax, az, 21) >= total {
            break;
        }
    }
    assert_eq!(w.debug_village_tier(ax, az), 1, "tier 1");
    // The interior centre is protected; a point well outside the ring is not.
    assert!(
        w.debug_village_protects(ax, az),
        "village centre is protected at tier 1"
    );
    assert!(
        !w.debug_village_protects(ax + 40, az + 40),
        "far away is not protected"
    );
}

#[test]
fn village_generation_is_deterministic() {
    // The baked settlement structure must be identical for a seed regardless of player
    // tier state (the tier overlays blocks but never changes worldgen).
    let h_a = worldgen::worldgen_villager_home_scan(424242);
    let h_b = worldgen::worldgen_villager_home_scan(424242);
    assert_eq!(h_a.width, h_b.width, "home width deterministic");
    assert_eq!(h_a.depth, h_b.depth, "home depth deterministic");
    assert_eq!(h_a.bed_blocks, h_b.bed_blocks, "home bed deterministic");
    // Two worlds at the same seed: the same structure anchor near origin.
    let s1 = worldgen::worldgen_structure_near(0, 0, 99);
    let s2 = worldgen::worldgen_structure_near(0, 0, 99);
    assert_eq!(s1, s2, "structure-near query is deterministic");
}

#[test]
fn village_wall_keeps_hostiles_out() {
    let (mut w, (ax, az)) = village_world(11);
    // Build the wood ring to reach tier 1 (protection active).
    let wc = w.debug_spawn_villager_role(ax, az, 4);
    let log = w.debug_item_id("oak_log");
    let total = World::debug_palisade_cells_total();
    for _ in 0..40 {
        w.debug_clear_inventory();
        w.debug_give(log, 8);
        w.debug_set_selected(0);
        let _ = w.debug_try_donation(wc);
        if w.debug_count_wall(ax, az, 21) >= total {
            break;
        }
    }
    assert_eq!(w.debug_village_tier(ax, az), 1, "tier 1 (protected)");

    // Survival mode so the hostile actively hunts. Put the player at the village centre
    // (inside the protected ring) and a hostile just OUTSIDE the south wall.
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    let surf = worldgen::worldgen_surface_height(ax, az, 11) as f32;
    w.debug_set_camera(ax as f32 + 0.5, surf + 2.0, az as f32 + 0.5, 0.0, 0.0);
    let h = w.debug_spawn_hostile_at(ax as f32 + 0.5, surf + 1.0, az as f32 + 12.0);

    // Drive the sim: the hostile will try to path toward the player but must never end up
    // inside the protected interior (|dx|,|dz| < R = 8 of the anchor).
    let mut breached = false;
    for _ in 0..200 {
        w.update(&unsafe { std::mem::zeroed::<bf_frame_input>() }, 0.05);
        let (hx, _hy, hz) = w.debug_creature_pos(h);
        let dx = (hx - ax as f32).abs();
        let dz = (hz - az as f32).abs();
        if dx < 7.0 && dz < 7.0 {
            breached = true;
            break;
        }
    }
    assert!(!breached, "a hostile breached the walled village interior");
}

fn prepared_settlement_defense(tier: u8) -> (World<'static>, i32, i32, f32) {
    let (mut w, (ax, az)) = village_world(11);
    let surf = worldgen::worldgen_surface_height(ax, az, 11) as f32;
    w.debug_set_camera(ax as f32 + 0.5, surf + 2.0, az as f32 + 0.5, 0.0, 0.0);
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    for _ in 0..40 {
        w.update(&zero, 0.05);
    }
    w.debug_set_village_tier(ax, az, tier);
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    (w, ax, az, surf)
}

fn flat_grey_defense(tier: u8) -> (World<'static>, i32, i32) {
    let content: &'static ContentRegistry = {
        let mut c = ContentRegistry::new();
        assert!(c.load(CONTENT));
        Box::leak(Box::new(c))
    };
    let extra: &'static ContentExtra = {
        let mut x = ContentExtra::new();
        assert!(x.load(CONTENT));
        Box::leak(Box::new(x))
    };
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(content);
    w.set_extra(extra);
    w.generate_test_world();
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    w.debug_set_village_tier(8, 8, tier);
    w.debug_set_camera(8.5, 9.7, 8.5, 0.0, 0.0);
    (w, 8, 8)
}

#[test]
fn settlement_guards_scale_and_civilians_seek_safety() {
    // A new village fields one slow woodcutter militia member. The first ward
    // strike hurts but does not erase an ordinary attacker, leaving room for the
    // player to help.
    let (mut village, ax, az, surf) = prepared_settlement_defense(1);
    let militia = village.debug_spawn_villager_role(ax, az, 4);
    let attacker = village.debug_spawn_assault_hostile_at(
        ax,
        az,
        ax as f32 + 9.5,
        surf + 1.0,
        az as f32 + 0.5,
    );
    village.debug_update_creatures(0.05);
    assert!(
        village.debug_creature_guarding(militia),
        "woodcutter visibly takes guard duty"
    );
    assert_eq!(
        village.debug_creature_hp(attacker),
        4,
        "village militia deals one damage"
    );

    let mut frame = empty_frame();
    let mut draws = Vec::new();
    let mut shadows = Vec::new();
    let mut props = Vec::new();
    village.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
    assert!(
        village
            .entity_role_actions()
            .iter()
            .any(|a| a.role == 4 && a.action == 11),
        "guard sidecar selects the authored light-staff pose"
    );

    // A town civilian abandons the edge and moves toward the safe center while
    // the woodcutter holds the attacker at the wall.
    let (mut town, tx, tz, tsurf) = prepared_settlement_defense(2);
    let civilian = town.debug_spawn_villager_role(tx, tz, 1);
    town.debug_set_creature_pos(civilian, tx as f32 - 5.5, tsurf, tz as f32 + 0.5);
    town.debug_spawn_villager_role(tx, tz, 4);
    town.debug_spawn_assault_hostile_at(tx, tz, tx as f32 + 9.5, tsurf + 1.0, tz as f32 + 0.5);
    let before = town.debug_creature_pos(civilian).0;
    for _ in 0..12 {
        town.debug_update_creatures(0.05);
    }
    let after = town.debug_creature_pos(civilian).0;
    assert!(
        after > before,
        "civilian retreats toward settlement center ({before} -> {after})"
    );
    assert!(
        !town.debug_creature_guarding(civilian),
        "civilian never presents as a guard"
    );

    // A city has three eligible guards; their simultaneous first volley clears the
    // same ordinary attacker without player damage or loot credit.
    let (mut city, cx, cz, csurf) = prepared_settlement_defense(3);
    for role in [4, 2, 6] {
        city.debug_spawn_villager_role(cx, cz, role);
    }
    city.debug_spawn_assault_hostile_at(cx, cz, cx as f32 + 9.5, csurf + 1.0, cz as f32 + 0.5);
    city.debug_update_creatures(0.05);
    assert_eq!(
        city.debug_assault_count(),
        0,
        "city guard volley clears ordinary pressure"
    );
}

#[test]
fn settlement_assaults_are_outside_bounded_and_light_ward_reduced() {
    let (mut w, ax, az, surf) = prepared_settlement_defense(1);
    assert_eq!(w.debug_assault_wave_size(ax, az, 1), 3);
    w.debug_set_village_lights(ax, az, 8);
    assert_eq!(
        w.debug_assault_wave_size(ax, az, 1),
        2,
        "completed light ward thins a wave"
    );
    w.debug_set_village_lights(ax, az, 0);

    w.debug_force_quest_done();
    w.debug_set_day_time(0.90);
    w.debug_set_camera(ax as f32 + 0.5, surf + 2.0, az as f32 + 0.5, 0.0, 0.0);
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    for _ in 0..300 {
        if w.debug_assault_count() > 0 {
            break;
        }
        w.update(&zero, 0.05);
    }
    let first_wave = w.debug_assault_count();
    assert!(
        first_wave > 0 && first_wave <= 3,
        "one bounded village wave spawned: {first_wave}"
    );
    assert_eq!(
        w.debug_count_named("smudgeling"),
        first_wave,
        "the first Grey assault tier is composed of Smudgelings"
    );
    assert!(
        w.debug_assaults_outside_protection(),
        "attackers approach from outside the wall"
    );
    for _ in 0..200 {
        w.update(&zero, 0.05);
    }
    assert_eq!(
        w.debug_assault_count(),
        first_wave,
        "an active wave does not become constant trickle-spawning"
    );
}

#[test]
fn smudgeling_steals_and_drops_a_recoverable_ward_light() {
    let (mut w, ax, az, surf) = prepared_settlement_defense(1);
    w.debug_clear_inventory();
    w.debug_set_village_lights(ax, az, 8);
    let goal_x = ax + 8;
    let goal_z = az;
    let smudge = w.debug_spawn_smudgeling_at(
        ax,
        az,
        goal_x as f32 + 1.0,
        surf + 1.0,
        goal_z as f32 + 0.5,
        goal_x,
        surf as i32 + 1,
        goal_z,
        true,
    );
    w.debug_update_creatures(0.05);
    assert!(
        w.debug_creature_carrying_light(smudge),
        "the swarmer visibly carries its perimeter-light prize"
    );
    assert_eq!(w.debug_village_lights(ax, az), 7, "the live ward loses one charge");

    let mut frame = empty_frame();
    let mut draws = Vec::new();
    let mut shadows = Vec::new();
    let mut props = Vec::new();
    w.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
    let entities =
        unsafe { std::slice::from_raw_parts(frame.entities, frame.entity_count as usize) };
    let smudge_draw = w
        .entity_role_actions()
        .iter()
        .zip(entities.iter())
        .find(|(_, e)| e.kind == 28)
        .expect("Smudgeling model 28 is rendered");
    assert_eq!(smudge_draw.0.action, 12, "stolen light selects the carry pose");

    w.debug_attack_creature(smudge);
    w.debug_attack_creature(smudge);
    assert_eq!(w.debug_village_lights(ax, az), 8, "catching it restores the ward charge");
    assert_eq!(w.debug_item_count(w.debug_item_id("color_dust")), 1);
    assert_eq!(w.debug_item_count(w.debug_item_id("glow_dust")), 1);
}

#[test]
fn hollow_foot_soldiers_join_town_waves_and_wilt_under_a_light_ward() {
    let (mut wave, ax, az, _surf) = prepared_settlement_defense(2);
    wave.debug_clear_creatures();
    let spawned = wave.debug_spawn_settlement_assault(ax, az, 2);
    assert_eq!(spawned, 4, "normal town pressure stays bounded");
    assert_eq!(wave.debug_count_named("smudgeling"), 2);
    assert_eq!(wave.debug_count_named("hollow"), 2);

    let (mut ward, wx, wz, wsurf) = prepared_settlement_defense(2);
    ward.debug_clear_creatures();
    ward.debug_set_village_lights(wx, wz, 8);
    let hollow = ward.debug_spawn_hollow_at(
        wx,
        wz,
        wx as f32 + 9.5,
        wsurf + 1.0,
        wz as f32 + 0.5,
    );
    for _ in 0..20 {
        ward.debug_update_creatures(0.05);
    }
    assert!(ward.debug_creature_light_exposure(hollow) > 0.9);
    let mut frame = empty_frame();
    let mut draws = Vec::new();
    let mut shadows = Vec::new();
    let mut props = Vec::new();
    ward.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
    assert!(
        ward.entity_role_actions().iter().any(|a| a.action == 14),
        "ward exposure selects the authored recoil pose"
    );
    for _ in 0..21 {
        ward.debug_update_creatures(0.05);
    }
    assert_eq!(ward.debug_creature_hp(hollow), 7, "bright ward deals slow Grey damage");
}

#[test]
fn guards_scale_against_hollow_foot_soldiers() {
    let (mut town, ax, az, surf) = prepared_settlement_defense(2);
    town.debug_clear_creatures();
    for role in [4, 2] {
        town.debug_spawn_villager_role(ax, az, role);
    }
    let hollow = town.debug_spawn_hollow_at(
        ax,
        az,
        ax as f32 + 9.5,
        surf + 1.0,
        az as f32 + 0.5,
    );
    town.debug_update_creatures(0.05);
    assert_eq!(town.debug_creature_hp(hollow), 4, "two town guards halve an 8hp Hollow");

    let (mut city, cx, cz, csurf) = prepared_settlement_defense(3);
    city.debug_clear_creatures();
    city.debug_set_village_lights(cx, cz, 8);
    for role in [4, 2, 6] {
        city.debug_spawn_villager_role(cx, cz, role);
    }
    city.debug_spawn_hollow_at(
        cx,
        cz,
        cx as f32 + 9.5,
        csurf + 1.0,
        cz as f32 + 0.5,
    );
    city.debug_update_creatures(0.05);
    assert_eq!(city.debug_count_named("hollow"), 0, "city ward volley clears a 10hp Hollow");
}

#[test]
fn city_wave_has_one_herald_and_its_troops_move_as_a_coordinated_aura() {
    let (mut wave, ax, az, _surf) = prepared_settlement_defense(3);
    wave.debug_clear_creatures();
    wave.debug_set_assault_wave_serial(1);
    let spawned = wave.debug_spawn_settlement_assault(ax, az, 3);
    assert_eq!(spawned, 5, "normal city wave remains bounded");
    assert_eq!(wave.debug_count_named("smudgeling"), 2);
    assert_eq!(wave.debug_count_named("hollow"), 2);
    assert_eq!(wave.debug_count_named("crooked_herald"), 1);

    let run = |with_herald: bool| {
        let (mut w, hx, hz) = flat_grey_defense(3);
        let hollow_x = 18.5;
        let hollow_z = 8.5;
        let hollow = w.debug_spawn_hollow_at(
            hx,
            hz,
            hollow_x,
            8.0,
            hollow_z,
        );
        if with_herald {
            w.debug_spawn_crooked_herald_at(
                hx,
                hz,
                hollow_x,
                8.0,
                15.5,
            );
        }
        let start = w.debug_creature_pos(hollow);
        for _ in 0..20 {
            w.debug_update_creatures(0.05);
        }
        let end = w.debug_creature_pos(hollow);
        (end.0 - start.0).hypot(end.2 - start.2)
    };
    let alone = run(false);
    let conducted = run(true);
    assert!(
        conducted > alone * 1.08,
        "nearby Herald strengthens troop approach speed ({alone} -> {conducted})"
    );
}

#[test]
fn crooked_herald_holds_then_lunges_but_fears_a_completed_ward() {
    let (mut stalk, ax, az) = flat_grey_defense(3);
    let stalk_x = 9.5;
    let stalk_z = 19.5;
    let herald = stalk.debug_spawn_crooked_herald_at(
        ax,
        az,
        stalk_x,
        8.0,
        stalk_z,
    );
    let start = stalk.debug_creature_pos(herald);
    for _ in 0..9 {
        stalk.debug_update_creatures(0.05);
    }
    let held = stalk.debug_creature_pos(herald);
    assert!(
        (held.0 - start.0).hypot(held.2 - start.2) < 0.03,
        "readable tell is a true movement hold"
    );
    assert_eq!(stalk.debug_creature_motion_speed(herald), 0.0);
    for _ in 0..12 {
        stalk.debug_update_creatures(0.05);
    }
    assert!(
        stalk.debug_creature_motion_speed(herald) > 0.5,
        "hold breaks into a sudden elastic locomotion clip"
    );

    let (mut ward, wx, wz) = flat_grey_defense(3);
    ward.debug_set_village_lights(wx, wz, 8);
    let ward_x = 19.5;
    let ward_z = 8.5;
    let afraid = ward.debug_spawn_crooked_herald_at(
        wx,
        wz,
        ward_x,
        8.0,
        ward_z,
    );
    let before = ward.debug_creature_pos(afraid).0;
    for _ in 0..20 {
        ward.debug_update_creatures(0.05);
    }
    assert!(ward.debug_creature_pos(afraid).0 > before, "lit ward drives the Herald back");
    let mut frame = empty_frame();
    let mut draws = Vec::new();
    let mut shadows = Vec::new();
    let mut props = Vec::new();
    ward.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
    assert!(
        ward.entity_role_actions().iter().any(|a| a.action == 16),
        "ward fear selects the authored recoil silhouette"
    );
}

#[test]
fn crooked_herald_survives_one_city_volley_and_needs_player_attention() {
    let (mut city, ax, az, surf) = prepared_settlement_defense(3);
    city.debug_clear_creatures();
    for role in [4, 2, 6] {
        city.debug_spawn_villager_role(ax, az, role);
    }
    let herald = city.debug_spawn_crooked_herald_at(
        ax,
        az,
        ax as f32 + 9.5,
        surf + 1.0,
        az as f32 + 0.5,
    );
    city.debug_update_creatures(0.05);
    assert_eq!(city.debug_creature_hp(herald), 7, "three unlit guards deal nine damage");
    for _ in 0..4 {
        city.debug_attack_creature(herald);
    }
    assert_eq!(city.debug_count_named("crooked_herald"), 0);
}

#[test]
fn city_siege_waves_are_bounded_and_every_third_wave_has_one_ramlord() {
    let (mut wave, ax, az, _surf) = prepared_settlement_defense(3);
    wave.debug_clear_creatures();
    wave.debug_set_assault_wave_serial(0);
    assert_eq!(wave.debug_spawn_settlement_assault(ax, az, 3), 5);
    assert_eq!(wave.debug_count_named("smudgeling"), 2);
    assert_eq!(wave.debug_count_named("hollow"), 1);
    assert_eq!(wave.debug_count_named("crooked_herald"), 1);
    assert_eq!(wave.debug_count_named("dim_ramlord"), 1);
    assert!(wave.debug_assaults_outside_protection());

    wave.debug_clear_creatures();
    wave.debug_set_assault_wave_serial(1);
    assert_eq!(wave.debug_spawn_settlement_assault(ax, az, 3), 5);
    assert_eq!(wave.debug_count_named("dim_ramlord"), 0);
    assert_eq!(wave.debug_count_named("hollow"), 2);
}

#[test]
fn ramlord_telegraphs_at_the_gate_then_cracks_two_ward_charges() {
    let (mut ward, ax, az) = flat_grey_defense(3);
    ward.debug_set_village_lights(ax, az, 8);
    let ramlord = ward.debug_spawn_ramlord_at(ax, az, 9.5, 8.0, 18.5);
    for _ in 0..20 {
        ward.debug_update_creatures(0.05);
    }
    assert!(ward.debug_creature_siege_charge(ramlord) > 0.9);
    assert_eq!(ward.debug_village_lights(ax, az), 8);

    let mut frame = empty_frame();
    let mut draws = Vec::new();
    let mut shadows = Vec::new();
    let mut props = Vec::new();
    ward.build_frame(&mut frame, &mut draws, &mut shadows, &mut props, 0.0);
    assert!(
        ward.entity_role_actions()
            .iter()
            .any(|a| a.action == 18 && a.progress > 0.30),
        "three-second siege windup has a visible authored pose"
    );

    for _ in 0..41 {
        ward.debug_update_creatures(0.05);
    }
    assert_eq!(ward.debug_village_lights(ax, az), 6);
    assert!(ward.debug_assaults_outside_protection());
}

#[test]
fn city_guards_need_player_help_against_a_ramlord_and_it_drops_siege_rewards() {
    let (mut city, ax, az, surf) = prepared_settlement_defense(3);
    city.debug_clear_creatures();
    city.debug_clear_inventory();
    for role in [4, 2, 6] {
        city.debug_spawn_villager_role(ax, az, role);
    }
    let ramlord = city.debug_spawn_ramlord_at(
        ax,
        az,
        ax as f32 + 9.5,
        surf + 1.0,
        az as f32 + 0.5,
    );
    city.debug_update_creatures(0.05);
    assert_eq!(city.debug_creature_hp(ramlord), 71, "three city guards cannot erase the captain");

    city.debug_set_creature_hp(ramlord, 2);
    city.debug_attack_creature(ramlord);
    assert_eq!(city.debug_count_named("dim_ramlord"), 0);
    assert_eq!(city.debug_item_count(city.debug_item_id("crystal_shard")), 4);
    assert_eq!(city.debug_item_count(city.debug_item_id("color_dust")), 4);
    assert_eq!(city.debug_item_count(city.debug_item_id("glow_dust")), 3);
}

#[test]
fn ramlord_captain_rallies_nearby_grey_troops() {
    let run = |with_captain: bool| {
        let (mut w, ax, az) = flat_grey_defense(3);
        let hollow = w.debug_spawn_hollow_at(ax, az, 18.5, 8.0, 8.5);
        if with_captain {
            w.debug_spawn_ramlord_at(ax, az, 18.5, 8.0, 15.5);
        }
        let start = w.debug_creature_pos(hollow);
        for _ in 0..20 {
            w.debug_update_creatures(0.05);
        }
        let end = w.debug_creature_pos(hollow);
        (end.0 - start.0).hypot(end.2 - start.2)
    };
    let alone = run(false);
    let rallied = run(true);
    assert!(
        rallied > alone * 1.15,
        "nearby siege captain visibly accelerates its troops ({alone} -> {rallied})"
    );
}

// ============================================================================
// #170 the "blockfall" mechanic: breaking a block bursts it into physical
// debris that pops, arcs, bounces, settles, and magnets to the player.
// ============================================================================
fn debris_world() -> (ContentRegistry, World<'static>) {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");
    let content: &'static ContentRegistry = Box::leak(Box::new(content));
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_content(content);
    w.set_allocator(allocator());
    w.generate_test_world();
    (ContentRegistry::new(), w)
}

#[test]
fn debris_burst_on_break() {
    let (_c, mut w) = debris_world();
    // Park the player far above so the magnet never interferes here.
    w.debug_set_camera(8.5, 40.0, 8.5, 0.0, -1.5707);
    assert_eq!(w.debug_debris_count(), 0, "no debris before the break");
    w.debug_break_block(8, 7, 8);
    let n = w.debug_debris_count();
    assert!((6..=9).contains(&n), "break burst 6..9 fragments, #176 (got {n})");
    for i in 0..n {
        let (_, vy, _) = w.debug_debris_vel(i);
        assert!(vy > 2.0, "fragment {i} pops upward (vy = {vy})");
        let (px, py, pz) = w.debug_debris_pos(i);
        assert!(
            (px - 8.5).abs() < 1.0 && (py - 7.5).abs() < 1.0 && (pz - 8.5).abs() < 1.0,
            "fragment {i} starts at the broken block"
        );
    }
}

#[test]
fn debris_settles_on_flat_ground() {
    let (_c, mut w) = debris_world();
    w.debug_set_camera(8.5, 40.0, 8.5, 0.0, -1.5707);
    w.debug_break_block(8, 7, 8);
    let n = w.debug_debris_count();
    assert!(n > 0, "burst spawned debris");
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    // 6 seconds of fixed ticks: plenty for pop + a couple of bounces + roll.
    for _ in 0..360 {
        w.update(&zero, 1.0 / 60.0);
    }
    assert_eq!(
        w.debug_debris_count(),
        n,
        "nothing collected (player far away)"
    );
    assert_eq!(w.debug_debris_settled_count(), n, "all fragments settled");
    for i in 0..n {
        let (_, py, _) = w.debug_debris_pos(i);
        // Ground top is y=8 except inside the mined hole (top y=7).
        assert!(
            (6.9..=8.4).contains(&py),
            "settled fragment {i} rests on the ground (y = {py})"
        );
        let (vx, vy, vz) = w.debug_debris_vel(i);
        assert!(
            vx == 0.0 && vy == 0.0 && vz == 0.0,
            "settled fragment {i} is still"
        );
    }
}

#[test]
fn debris_magnet_collects_to_inventory() {
    let (_c, mut w) = debris_world();
    let dirt = w.debug_item_id("dirt");
    assert_ne!(dirt, 0, "content has a dirt item (grass drops dirt)");
    w.debug_clear_inventory();
    // Player standing on the flat ground right next to the break.
    w.debug_set_camera(8.5, 9.7, 8.5, 0.0, -1.5707);
    w.debug_break_block(9, 7, 9);
    assert!(w.debug_debris_count() > 0, "burst spawned debris");
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    let mut i = 0;
    while i < 600 && w.debug_debris_count() > 0 {
        w.update(&zero, 1.0 / 60.0);
        i += 1;
        // A fragment can legitimately scatter past the 2.5-block magnet
        // radius; every second, step the player over to the nearest
        // straggler exactly like a kid chasing their loot.
        if i % 60 == 0 && w.debug_debris_count() > 0 {
            let (px, py, pz) = w.debug_debris_pos(0);
            w.debug_set_camera(px, py + 1.6, pz, 0.0, -1.5707);
        }
    }
    assert_eq!(
        w.debug_debris_count(),
        0,
        "all fragments magneted to the player"
    );
    assert_eq!(
        w.debug_item_count(dirt),
        1,
        "one broken grass = one dirt in the inventory"
    );
}

#[test]
fn debris_hard_cap_collapses_oldest() {
    let (_c, mut w) = debris_world();
    w.debug_set_camera(8.5, 40.0, 8.5, 0.0, -1.5707);
    // 80 bursts x 4..6 fragments >> 256.
    for k in 0..80 {
        w.debug_spawn_debris(8.5, 12.0 + (k % 3) as f32, 8.5, world::STONE);
    }
    assert!(
        w.debug_debris_count() <= 256,
        "live debris never exceeds the hard cap"
    );
    assert!(w.debug_debris_count() > 200, "the pool actually filled up");
}

#[test]
fn debris_trajectories_are_deterministic() {
    let run = || -> Vec<(f32, f32, f32)> {
        let (_c, mut w) = debris_world();
        w.debug_set_camera(8.5, 40.0, 8.5, 0.0, -1.5707);
        w.debug_break_block(8, 7, 8);
        let zero: bf_frame_input = unsafe { std::mem::zeroed() };
        for _ in 0..90 {
            w.update(&zero, 1.0 / 60.0);
        }
        (0..w.debug_debris_count())
            .map(|i| w.debug_debris_pos(i))
            .collect()
    };
    let a = run();
    let b = run();
    assert!(!a.is_empty(), "run produced debris");
    assert_eq!(a, b, "same seed + same break = bit-identical trajectories");
}

// #184 hyperspeed: creative-only 100x flight for circumnavigation testing.
#[test]
fn hyperspeed_is_100x_and_creative_only() {
    let seed = 11u64;
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(seed);

    let dist = |w: &mut World, hyper: bool| -> f32 {
        let mut a: bf_action = unsafe { std::mem::zeroed() };
        a.kind = bf_action_kind::BF_ACT_SET_HYPERSPEED;
        a.arg_i = if hyper { 1 } else { 0 };
        w.action(&a);
        w.debug_set_camera(1000.5, 80.0, 1000.5, std::f32::consts::FRAC_PI_2, 0.0);
        let mut input: bf_frame_input = unsafe { std::mem::zeroed() };
        input.move_forward = 1.0;
        input.sprint = 1;
        input.fly_ascend = 1; // stay airborne in creative
        for _ in 0..10 {
            w.update(&input, 1.0 / 60.0);
        }
        let (px, _py, pz, _) = w.get_player();
        // Nearest-image displacement from the start point on the torus.
        let dx = (px - 1000.5).abs();
        let dz = (pz - 1000.5).abs();
        dx.min(WRAP as f32 - dx).max(dz.min(WRAP as f32 - dz))
    };
    let normal = dist(&mut w, false);
    let hyper = dist(&mut w, true);
    assert!(
        hyper > normal * 50.0,
        "hyperspeed must be ~100x (normal {normal}, hyper {hyper})"
    );

    // Survival ignores the toggle entirely.
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    let s_normal = dist(&mut w, false);
    let s_hyper = dist(&mut w, true);
    assert!(
        s_hyper < s_normal * 3.0 + 1.0,
        "survival must ignore hyperspeed ({s_normal} vs {s_hyper})"
    );
}

// Pine trees (#62 ids: log 49, needles 48) must fell like oak/birch: logs become
// coloured falling blocks (not the grey default) and the canopy clears.
#[test]
fn pine_tree_fells_with_canopy() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_content(&content);
    w.set_allocator(allocator());
    w.generate_test_world();
    // Flat test world: solid up to y=7. Build a pine at (8, 8.., 8).
    let (bx, bz) = (8, 8);
    for dy in 0..=3 {
        w.debug_edit(bx, 8 + dy, bz, 49);
    }
    for dx in -1..=1 {
        for dz in -1..=1 {
            w.debug_edit(bx + dx, 12, bz + dz, 48);
        }
    }
    w.debug_break_block(bx, 8, bz);
    let mut needles = 0;
    for dx in -1..=1 {
        for dz in -1..=1 {
            if w.debug_block_at(bx + dx, 12, bz + dz) == 48 {
                needles += 1;
            }
        }
    }
    assert_eq!(needles, 0, "felling a pine must clear its needle canopy");
    assert_eq!(w.debug_block_at(bx, 9, bz), 0, "pine trunk felled");
}

#[test]
fn breaking_tree_support_fells_matching_canopy() {
    for (log, leaf) in [(21, 5), (22, 27), (49, 48)] {
        let (_c, mut w) = debris_world();
        let (bx, bz) = (8, 8);
        for y in 8..=11 {
            w.debug_edit(bx, y, bz, log);
        }
        for dx in -1..=1 {
            for dz in -1..=1 {
                w.debug_edit(bx + dx, 12, bz + dz, leaf);
            }
        }

        w.debug_break_block(bx, 7, bz);

        for y in 8..=11 {
            assert_eq!(w.debug_block_at(bx, y, bz), 0, "log {log} stayed at y={y}");
        }
        assert_eq!(w.debug_block_at(bx + 1, 12, bz), 0, "leaf {leaf} stayed aloft");
    }
}

#[test]
fn breaking_support_fells_max_generated_tree_log_budget() {
    let (_c, mut w) = debris_world();
    let (bx, bz) = (8, 8);
    for y in 8..=23 {
        w.debug_edit(bx, y, bz, 21); // Maximum generated giant-oak trunk: 16 logs.
    }
    let branches = [(1, 0), (-1, 0), (0, 1)];
    for (dx, dz) in branches {
        for step in 1..=3 {
            let y = 20 + (step + 1) / 2;
            w.debug_edit(bx + dx * step, y, bz + dz * step, 21);
        }
    }
    for dx in -1..=1 {
        for dz in -1..=1 {
            w.debug_edit(bx + dx, 24, bz + dz, 5);
        }
    }

    w.debug_break_block(bx, 7, bz);

    for y in 8..=23 {
        assert_eq!(
            w.debug_block_at(bx, y, bz),
            0,
            "upper trunk stayed at y={y}"
        );
    }
    for (dx, dz) in branches {
        for step in 1..=3 {
            let y = 20 + (step + 1) / 2;
            assert_eq!(
                w.debug_block_at(bx + dx * step, y, bz + dz * step),
                0,
                "branch ({dx},{dz}) stayed at step {step}"
            );
        }
    }
    assert_eq!(
        w.debug_block_at(bx + 1, 24, bz),
        0,
        "canopy stayed aloft"
    );
}

#[test]
fn breaking_support_leaves_structural_logs_standing() {
    let (_c, mut w) = debris_world();
    let (bx, bz) = (8, 8);
    for y in 8..=11 {
        w.debug_edit(bx, y, bz, 21);
    }
    w.debug_edit(bx + 1, 12, bz, 27); // Wrong-species leaf is not this timber's canopy.

    w.debug_break_block(bx, 7, bz);

    for y in 8..=11 {
        assert_eq!(w.debug_block_at(bx, y, bz), 21, "structural log fell at y={y}");
    }
    assert_eq!(w.debug_block_at(bx + 1, 12, bz), 27);
}

// ============================================================================
// #179 looping world: seam behaviour of the live sim (wrap, physics, AI, render).
// ============================================================================

const WRAP: i32 = worldgen::WORLD_PERIOD;

// Find a z where both sides of the x seam are dry land (so a walk across the
// seam stands on solid ground the whole way).
fn dry_seam_z(seed: u64) -> i32 {
    const SEA_LEVEL: i32 = 6;
    for z in 0..4096 {
        let mut ok = true;
        for x in [WRAP - 24, WRAP - 8, WRAP - 1, 0, 8, 24] {
            let h = worldgen::worldgen_surface_height(x, z, seed);
            if h <= SEA_LEVEL + 1 || h > 40 {
                ok = false;
                break;
            }
        }
        if ok {
            return z;
        }
    }
    panic!("no dry seam strip found for seed {seed}");
}

// Block edits address the same voxel from either frame: writing at x = -1
// reads back at x = WRAP-1, and a write past the seam (x = WRAP) lands at 0.
#[test]
fn wrap_block_edits_are_canonical() {
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.init_world(11);
    let z = dry_seam_z(11);
    w.debug_edit(-1, 70, z, world::GLOW);
    assert_eq!(w.debug_block_at(WRAP - 1, 70, z), world::GLOW);
    w.debug_edit(WRAP, 71, z, world::BRICK);
    assert_eq!(w.debug_block_at(0, 71, z), world::BRICK);
    // And reads canonicalize too.
    assert_eq!(w.debug_block_at(-1, 70, z), world::GLOW);
}

// Walk the player east across the world seam in survival: the position wraps
// into [0, WRAP), the ground stays solid (no fall-through), and the chunk
// store does not blow up with duplicate columns.
#[test]
fn wrap_seam_walk_east() {
    let seed = 11u64;
    let z = dry_seam_z(seed);
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    w.init_world(seed);

    let x0 = WRAP - 20;
    let h = worldgen::worldgen_surface_height(x0, z, seed);
    // Face +x: forward = (sin yaw, 0, cos yaw) with pitch 0.
    w.debug_set_camera(
        x0 as f32 + 0.5,
        h as f32 + 3.5,
        z as f32 + 0.5,
        std::f32::consts::FRAC_PI_2,
        0.0,
    );

    let mut input: bf_frame_input = unsafe { std::mem::zeroed() };
    input.move_forward = 1.0;
    input.sprint = 1;
    // #181: the latitude bands moved the dry seam strip onto gently rising
    // ground (the near-equator seam is desert dunes now); hold jump so the
    // walker hops up the one-block steps instead of pinning against them.
    input.jump = 1;
    let mut crossed = false;
    let mut min_y = f32::MAX;
    for _ in 0..600 {
        w.update(&input, 0.05);
        let (px, py, _pz, _) = w.get_player();
        assert!(
            (0.0..WRAP as f32).contains(&px),
            "player x {px} escaped the canonical torus range"
        );
        min_y = min_y.min(py);
        if px < 64.0 {
            crossed = true;
            break;
        }
    }
    let (px, py, pz, _) = w.get_player();
    assert!(crossed, "player never crossed the seam (x = {px})");
    // Grounded on real terrain the whole way: never fell into the void and is
    // standing near the local surface now.
    assert!(
        min_y > 0.0,
        "player fell through the world near the seam (min y {min_y})"
    );
    let hs = worldgen::worldgen_surface_height(px as i32, pz as i32, seed);
    assert!(
        (py - hs as f32).abs() < 8.0,
        "player y {py} far from surface {hs} after crossing at ({px},{pz})"
    );
    // Store stayed bounded (no duplicate resident columns for the same torus
    // position; a duplicate would double the count for the walked window).
    let residents = w.debug_resident_count();
    assert!(
        residents < 6000,
        "resident chunk count {residents} exploded during the seam walk"
    );

    // Rendered geometry is camera-relative on the torus: every draw's chunk
    // origin sits at its nearest image (never ~32K blocks away).
    let mut frame: bf_render_frame = unsafe { std::mem::zeroed() };
    let mut draws = Vec::new();
    let mut shadow_draws = Vec::new();
    let mut props = Vec::new();
    w.build_frame(&mut frame, &mut draws, &mut shadow_draws, &mut props, 0.0);
    assert!(!draws.is_empty(), "no draws after the seam walk");
    for d in &draws {
        let dx = (d.chunk_origin.x as f32 + 8.0) - px;
        let dz = (d.chunk_origin.z as f32 + 8.0) - pz;
        assert!(
            dx.abs() < 1024.0 && dz.abs() < 1024.0,
            "draw origin ({}, {}) not nearest-image relative to camera ({px}, {pz})",
            d.chunk_origin.x,
            d.chunk_origin.z
        );
    }
}

// A befriended pet on the far side of the seam sees the player 12 blocks away
// (nearest image), not WRAP-12, and closes the gap across the seam.
#[test]
fn wrap_creature_follows_across_seam() {
    let seed = 11u64;
    let z = dry_seam_z(seed);
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    w.init_world(seed);

    let px = 6.5f32;
    let hp = worldgen::worldgen_surface_height(px as i32, z, seed);
    w.debug_set_camera(px, hp as f32 + 3.2, z as f32 + 0.5, 0.0, 0.0);
    // Warm the streaming window around the player (both sides of the seam).
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    for _ in 0..80 {
        w.update(&zero, 0.05);
    }

    let cx = (WRAP - 6) as f32 + 0.5; // wrapped distance ~13 blocks, raw ~32756
    let hc = worldgen::worldgen_surface_height(cx as i32, z, seed);
    // debug_spawn_creature_at marks the creature Scripted (ignores the player),
    // so spawn a plain creature via the hostile hook and befriend it: Pet AI.
    let idx = w.debug_spawn_hostile_at(cx, hc as f32 + 1.0, z as f32 + 0.5);
    w.debug_make_pet(idx); // real Pet AI: follows the player

    let wrapped = |a: f32, b: f32| {
        let d = (a - b).rem_euclid(WRAP as f32);
        d.min(WRAP as f32 - d)
    };
    let (sx, _sy, sz) = w.debug_creature_pos(idx);
    let d0 = wrapped(sx, px).hypot(sz - (z as f32 + 0.5));
    for _ in 0..400 {
        w.update(&zero, 0.05);
    }
    let (ex, _ey, ez) = w.debug_creature_pos(idx);
    let d1 = wrapped(ex, px).hypot(ez - (z as f32 + 0.5));
    assert!(
        d1 < d0 - 4.0,
        "pet did not close the gap across the seam (start {d0:.1}, end {d1:.1})"
    );
}

// #177: a Magnet Charm in the inventory triples the debris pull radius, so loot
// zips over from a distance the bare radius (2.5) would never reach.
#[test]
fn magnet_charm_extends_pickup_radius() {
    let (_c, mut w) = debris_world();
    let charm = w.debug_item_id("magnet_charm");
    assert_ne!(charm, 0, "content has the magnet charm");
    w.debug_clear_inventory();
    w.debug_give(charm, 1);
    // Stand ~4 blocks from the break: outside the bare 2.5 radius, and even the
    // outermost scatter stays inside the charmed 7.5. All fragments must come
    // home without moving the player (bare radius would strand the far ones).
    w.debug_set_camera(5.5, 9.7, 8.5, 0.0, -1.5707);
    // Burst an above-ground block so no fragment can land in a dug pit (a pit
    // traps fragments regardless of magnet radius; the charm pulls, walls win).
    let stone = w.debug_item_id("stone");
    let _ = stone;
    w.debug_edit(9, 8, 9, world::BRICK);
    w.debug_break_block(9, 8, 9);
    assert!(w.debug_debris_count() > 0, "burst spawned debris");
    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    let mut i = 0;
    while i < 900 && w.debug_debris_count() > 0 {
        w.update(&zero, 1.0 / 60.0);
        i += 1;
    }
    assert_eq!(
        w.debug_debris_count(),
        0,
        "charmed magnet pulled every fragment from ~4 blocks"
    );
}

// #203: trading swaps inventory both ways and never half-executes.
#[test]
fn trade_buy_and_sell_roundtrip() {
    let (_c, mut w) = debris_world();
    let coin = w.debug_item_id("coin");
    let log = w.debug_item_id("oak_log");
    let planks = w.debug_item_id("oak_planks");
    assert!(coin != 0 && log != 0 && planks != 0, "trade items exist");
    w.debug_clear_inventory();
    // No goods: woodcutter (npc 4) offer 0 (8 logs -> 1 coin) must refuse.
    assert!(!w.trade_execute(4, 0), "cannot sell logs you do not have");
    // Sell 8 logs for a coin.
    w.debug_give(log, 8);
    assert!(w.trade_execute(4, 0), "sell logs");
    assert_eq!(w.debug_item_count(coin), 1);
    assert_eq!(w.debug_item_count(log), 0);
    // Buy 8 planks with that coin.
    assert!(w.trade_execute(4, 1), "buy planks");
    assert_eq!(w.debug_item_count(coin), 0);
    assert_eq!(w.debug_item_count(planks), 8);
    // Broke now: buying again refuses.
    assert!(!w.trade_execute(4, 1), "no coins, no planks");
    // Bad profession / bad index refuse cleanly.
    assert!(!w.trade_execute(2, 0), "builder does not trade");
    assert!(!w.trade_execute(4, 9), "bad offer index");
}
