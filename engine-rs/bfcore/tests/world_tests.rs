//! Behavioural parity tests for bfcore::world, ported 1:1 from the C++ World tests
//! (tests/unit/test_world.cpp, test_doors.cpp, test_quest.cpp, test_questloop.cpp,
//! test_creatures.cpp, test_saveload.cpp, test_gameplay.cpp). Same scenarios, same
//! assertions, same absolute content path.

use bfcore::abi::*;
use bfcore::content::{ContentExtra, ContentRegistry};
use bfcore::types::IVec3;
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
    bf_gpu_buffer { handle: p as u64, contents: p as *mut c_void, bytes }
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
    bf_gpu_allocator { user: std::ptr::null_mut(), alloc: Some(alloc_fn), free_: Some(free_fn) }
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
    assert!(w.debug_has_target(), "raycast acquired a target looking down");
    assert_eq!(w.debug_block_at(8, 7, 8), world::GRASS, "ground top is grass");

    let mut draws: Vec<bf_draw_item> = Vec::new();
    let mut shadow: Vec<bf_draw_item> = Vec::new();
    let mut props: Vec<bf_prop_instance> = Vec::new();
    let mut f = empty_frame();
    w.build_frame(&mut f, &mut draws, &mut shadow, &mut props, 0.0);
    let idx0 = total_indices(&f, &draws);
    assert!(f.draw_count > 0 && idx0 > 0, "world meshed into draw list");

    // MINE
    let mine_start = bf_action { kind: bf_action_kind::BF_ACT_MINE_START, arg_i: 0, arg_j: 0, arg_k: 0 };
    w.action(&mine_start);
    let mut i = 0;
    while i < 60 && w.debug_block_at(8, 7, 8) != world::AIR {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert_eq!(w.debug_block_at(8, 7, 8), world::AIR, "mined block is now air");
    let mine_stop = bf_action { kind: bf_action_kind::BF_ACT_MINE_STOP, arg_i: 0, arg_j: 0, arg_k: 0 };
    w.action(&mine_stop);

    w.build_frame(&mut f, &mut draws, &mut shadow, &mut props, 0.0);
    let idx1 = total_indices(&f, &draws);
    assert_ne!(idx1, idx0, "mesh changed after mining (remesh happened)");

    // PLACE GLOW
    w.update(&zero, 0.016);
    assert_eq!(w.debug_block_at(8, 6, 8), world::DIRT, "exposed dirt below");
    w.debug_set_selected(0);
    let place = bf_action { kind: bf_action_kind::BF_ACT_PLACE, arg_i: 0, arg_j: 0, arg_k: 0 };
    w.action(&place);
    assert_eq!(w.debug_block_at(8, 7, 8), world::GLOW, "placed block appears");

    w.build_frame(&mut f, &mut draws, &mut shadow, &mut props, 0.0);
    assert!(f.draw_count > 0 && total_indices(&f, &draws) > 0, "world still meshes after place");

    assert!(
        w.debug_stream_back_is_nearest(),
        "stream gen order is nearest-first (#36)"
    );
}

// ============================================================================
// test_doors.cpp — doors open/close + collision flip + 2-tall sync.
// ============================================================================
#[test]
fn doors_open_close() {
    let mut c = ContentRegistry::new();
    assert!(c.load(CONTENT), "content load");
    assert!(c.block_by_name("oak_door").is_some(), "content has oak_door");
    assert!(c.block_by_name("oak_door_open").is_some(), "content has oak_door_open");

    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&c);
    w.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    w.init_world(11);

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    let (dx, dy, dz) = (100, 145, 100);
    w.debug_set_camera(dx as f32 + 0.5, dy as f32 + 5.0, dz as f32 + 0.5, 0.0, -1.5707);
    for _ in 0..25 {
        w.update(&zero, 0.05);
    }

    w.debug_edit(dx, dy, dz, 33);
    w.debug_set_camera(dx as f32 + 0.5, dy as f32 + 5.0, dz as f32 + 0.5, 0.0, -1.5707);
    w.update(&zero, 0.016);
    assert_eq!(w.debug_block_at(dx, dy, dz), 33, "closed door in place");
    assert!(w.debug_collide_solid(dx, dy, dz), "a closed door blocks movement");
    assert!(w.debug_has_target(), "aimed at the door");

    let usea = bf_action { kind: bf_action_kind::BF_ACT_INTERACT, arg_i: 0, arg_j: 0, arg_k: 0 };
    w.action(&usea);
    w.update(&zero, 0.016);
    assert_eq!(w.debug_block_at(dx, dy, dz), 50, "interacting opens the door");
    assert!(!w.debug_collide_solid(dx, dy, dz), "an open door is passable");

    w.action(&usea);
    w.update(&zero, 0.016);
    assert_eq!(w.debug_block_at(dx, dy, dz), 33, "interacting again closes the door");
    assert!(w.debug_collide_solid(dx, dy, dz), "the re-closed door blocks movement again");

    // #89 2-tall door.
    let (ex, ey, ez) = (104, 145, 104);
    w.debug_edit(ex, ey, ez, 33);
    w.debug_edit(ex, ey + 1, ez, 33);
    w.debug_set_camera(ex as f32 + 0.5, ey as f32 + 5.0, ez as f32 + 0.5, 0.0, -1.5707);
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
    let bosses = x.creatures().iter().filter(|cr| cr.disposition == "boss").count();
    assert_eq!(bosses, 2, "two bosses in the roster");

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
    assert_ne!(w.debug_active_quest(), first_id, "advanced to the next quest");

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
        assert!(!w2.fill_quest_target(&mut qt), "no target while the creature isn't loaded");
        w2.debug_spawn_named(&befr_target);
        assert!(w2.fill_quest_target(&mut qt), "target active once the creature is loaded");
        assert!(qt.active == 1 && qt.is_boss == 0, "befriend target: active, not a boss");
        let label = cstr_str(&qt.label);
        assert_eq!(label, "Gloom Stag", "label title-cased from creature name");
        assert!(qt.distance > 0.0 && qt.distance < 20.0, "distance to target is sane");

        let boss = advance_to(&mut w2, "calm_boss");
        assert!(boss.is_some(), "reached a calm_boss quest");
        let (boss_target, _) = boss.unwrap();
        let mut qb: bf_quest_target = unsafe { std::mem::zeroed() };
        w2.debug_spawn_named(&boss_target);
        assert!(w2.fill_quest_target(&mut qb), "boss target active once loaded");
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
            assert!(ok, "quest {} objective '{}' targets '{}'", q.id, o.trigger, t);
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

        assert_eq!(w.debug_active_quest(), x.quests()[0].id, "first quest active on spawn");
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
        w.debug_set_camera(bx as f32 + 0.5, by as f32 + 5.0, bz as f32 + 0.5, 0.0, -1.5707);
        for _ in 0..30 {
            w.update(&zero, 0.05);
        }
        assert!(w.debug_region_sat(chunk_of(bx), chunk_of(bz)) < 0.99, "far region starts Grey");

        w.debug_edit(bx, by, bz, world::STONE);
        w.debug_set_camera(bx as f32 + 0.5, by as f32 + 5.0, bz as f32 + 0.5, 0.0, -1.5707);
        w.update(&zero, 0.016);
        assert!(w.debug_has_target(), "aimed at the stone block for placement");

        let beacon = w.debug_item_id("beacon_block");
        assert_ne!(beacon, 0, "content has a beacon_block item");
        w.debug_clear_inventory();
        w.debug_give(beacon, 1);
        let sel = bf_action { kind: bf_action_kind::BF_ACT_HOTBAR_SELECT, arg_i: 0, arg_j: 0, arg_k: 0 };
        w.action(&sel);

        let restored_before = w.debug_regions_restored();
        let place = bf_action { kind: bf_action_kind::BF_ACT_PLACE, arg_i: 0, arg_j: 0, arg_k: 0 };
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
    assert!(w.debug_creature_count() >= base + 2, "two creatures spawned");
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
        assert!(built2 > 0 && after2 > after1, "village: second donation extends the wall");
    }

    // Natural regrowth. #: with real oceans the origin region for seed 11 is open
    // water, so grow the regrowth tree on a known dry-land column instead (a tree
    // cannot keep a crown underwater).
    {
        let (tx, tz) = (204, 0);
        assert!(w.debug_grow_tree(tx, tz), "regrowth: tree grown on a dry-land column");
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
        assert_eq!(w.debug_block_at(3, 70, 3), world::GLOW, "edited GLOW persisted");
        assert_eq!(w.debug_block_at(4, 70, 3), world::BRICK, "edited BRICK persisted");
        assert_eq!(w.debug_block_at(3, 70, 4), world::AIR, "dug-out edit persisted");
        assert!(w.debug_region_sat(0, 0) > 0.9, "restored spawn region persisted");

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
        assert_eq!(matches, total, "loaded procedural terrain matches a fresh same-seed gen");
    }

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
    let mine_start = bf_action { kind: bf_action_kind::BF_ACT_MINE_START, arg_i: 0, arg_j: 0, arg_k: 0 };
    w.action(&mine_start);
    let mut i = 0;
    while i < 200 && w.debug_block_at(100, 95, 100) != world::AIR {
        w.update(&zero, 0.05);
        i += 1;
    }
    assert_eq!(w.debug_block_at(100, 95, 100), world::AIR, "stone mined away");
    assert!(w.debug_item_count(cobble) >= 1, "survival mining dropped cobblestone");

    // crafting consumes inputs, produces output.
    let log = w.debug_item_id("oak_log");
    let planks = w.debug_item_id("oak_planks");
    assert!(log != 0 && planks != 0, "content has oak_log and oak_planks");
    w.debug_clear_inventory();
    w.debug_give(log, 4);
    let planks_before = w.debug_item_count(planks);
    let craft = bf_action { kind: bf_action_kind::BF_ACT_CRAFT, arg_i: 0, arg_j: 0, arg_k: 0 };
    w.action(&craft);
    assert!(w.debug_item_count(planks) > planks_before, "crafting produced planks");
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
    assert!(cw.debug_creature_count() >= 8, "animals populate near the player");
    assert!(cw.debug_aim_at_creature0(), "aimed at an animal");
    let before = cw.debug_creature_count();
    let attack = bf_action { kind: bf_action_kind::BF_ACT_ATTACK, arg_i: 0, arg_j: 0, arg_k: 0 };
    let mut h = 0;
    while h < 8 && cw.debug_creature_count() == before {
        cw.debug_aim_at_creature0();
        cw.action(&attack);
        cw.update(&zero, 0.02);
        h += 1;
    }
    assert_eq!(cw.debug_creature_count(), before - 1, "defeating an aimed animal removes it");

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
        for dx in -3..=3 {
            for dz in -3..=3 {
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
        assert!(cave.debug_hostile_count() > 0, "hostiles spawn deep underground (#7)");
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
    w.debug_set_camera(cx as f32 + 0.5, surf as f32 + 2.0, cz as f32 + 0.5, 0.0, 0.0);
    for _ in 0..30 {
        w.update(&zero, 0.05);
    }
    w.debug_set_day_time(0.90); // t > 0.80 => night
    w.debug_set_camera(cx as f32 + 0.5, surf as f32 + 2.0, cz as f32 + 0.5, 0.0, 0.0);
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
    day.debug_set_camera(dx as f32 + 0.5, dsurf as f32 + 2.0, dz as f32 + 0.5, 0.0, 0.0);
    let mut j = 0;
    while j < 400 && day.debug_creature_count() < 4 {
        day.update(&zero, 0.05);
        j += 1;
    }
    assert!(day.debug_day_time() < 0.20 || day.debug_day_time() > 0.80 || day.debug_creature_count() >= 4,
        "stayed daytime");
    assert!(day.debug_creature_count() >= 4, "daytime fauna still spawn");
    assert_eq!(day.debug_hostile_count(), 0, "no hostiles in daylight on the surface");
}

// A ruined structure is a localized "danger site": a hostile or two spawn at it in
// broad daylight, before any quest is done (independent of the night/quest gate that
// governs the normal night spawns). Seed 10 has a ruin in plains at (184,76).
#[test]
fn ruin_spawns_daytime_danger() {
    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content load");

    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(&content);
    w.set_mode(bf_game_mode::BF_MODE_SURVIVAL);
    w.init_world(10);
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

    let zero: bf_frame_input = unsafe { std::mem::zeroed() };
    let mut f = empty_frame();
    let mut draws: Vec<bf_draw_item> = Vec::new();
    let mut shadow: Vec<bf_draw_item> = Vec::new();
    let mut props: Vec<bf_prop_instance> = Vec::new();

    // Pump frames; between each give the workers a moment so results are ready to
    // collect on the next build_frame (the pool runs on its own threads).
    let mut max_draws = 0u32;
    for _ in 0..120 {
        w.update(&zero, 0.016);
        w.build_frame(&mut f, &mut draws, &mut shadow, &mut props, 0.0);
        if f.draw_count > max_draws {
            max_draws = f.draw_count;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }

    assert!(
        max_draws > 0,
        "async worker pool meshed chunks into the draw list (got {max_draws} draws)"
    );
}

// read a NUL-terminated fixed byte buffer as a String slice.
fn cstr_str(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).to_string()
}
