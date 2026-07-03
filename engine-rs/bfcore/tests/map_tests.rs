//! #182 world map + warp totems: explored mask, totem markers, village visits,
//! map.dat persistence, and safe teleport. Runs on the real worldgen with
//! deterministic inline streaming, mirroring the world_tests setup.

use bfcore::abi::*;
use bfcore::content::ContentRegistry;
use bfcore::world::{self, World};
use bfcore::worldgen::TerrainGen;

// This checkout's content (worktree-safe), so the new warp_totem block/item
// definitions are the ones under test.
const CONTENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../content");

fn zero_input() -> bf_frame_input {
    unsafe { std::mem::zeroed() }
}

fn make_world(content: &ContentRegistry, seed: u64) -> World<'_> {
    let mut w = World::new(Some(TerrainGen::new()));
    w.debug_set_sync_streaming(true);
    w.set_content(content);
    w.init_world(seed);
    w
}

#[test]
fn totem_place_registers_break_unregisters() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = make_world(&content, 11);
    assert_eq!(w.debug_totem_count(), 0, "fresh world has no totems");

    let (px, _py, pz, _) = w.get_player();
    let (tx, tz) = (px as i32 + 2, pz as i32 + 2);
    let ty = 40; // an air cell above the terrain; exact block content is irrelevant
    assert!(w.debug_place_totem(tx, ty, tz));
    assert_eq!(w.debug_totem_count(), 1, "placing a totem registers a marker");
    assert_eq!(w.debug_block_at(tx, ty, tz), world::WARP_TOTEM);

    // Markers include home + the totem, and the totem is auto-named Totem 1.
    let markers = w.map_markers();
    assert_eq!(markers.len(), 2);
    assert_eq!(markers[0].kind, 0, "first marker is home");
    assert_eq!(markers[1].kind, 2, "second marker is the totem");
    assert_eq!(markers[1].name, "Totem 1");

    // Breaking the block unregisters the marker.
    w.debug_break_block(tx, ty, tz);
    assert_eq!(w.debug_block_at(tx, ty, tz), 0, "totem block broken");
    assert_eq!(w.debug_totem_count(), 0, "breaking unregisters the marker");
}

#[test]
fn totem_cap_enforced_at_16() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = make_world(&content, 11);
    let (px, _py, pz, _) = w.get_player();
    for i in 0..20 {
        let _ = w.debug_place_totem(px as i32 + 3 + i, 40, pz as i32 + 3);
    }
    assert_eq!(w.debug_totem_count(), 16, "totem markers cap at 16");
    assert!(!w.debug_place_totem(px as i32, 45, pz as i32), "17th placement refused");
}

#[test]
fn explored_bits_set_as_player_moves() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = make_world(&content, 11);
    let (px, _py, pz, _) = w.get_player();
    assert!(
        w.debug_explored_at(px as i32, pz as i32),
        "spawn cell is explored immediately"
    );
    let before = w.debug_explored_count();
    assert!(before > 0);

    // Walk the player far east: cells along the way get revealed as chunk
    // boundaries are crossed. Move in creative fly (no falling) for a clean run.
    let far_x = px + 300.0;
    w.debug_set_camera(far_x, 80.0, pz, 0.0, 0.0);
    w.update(&zero_input(), 0.05);
    assert!(
        w.debug_explored_at(far_x as i32, pz as i32),
        "cell at the new position is explored"
    );
    assert!(w.debug_explored_count() > before, "exploration grew");
}

#[test]
fn village_visit_recorded_within_range() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = make_world(&content, 11);
    assert_eq!(w.debug_visited_village_count(), 0);

    // Scan for a settlement anchor near a grid of probe points, then "visit" it
    // by probing at the anchor itself (distance 0 < 48).
    let mut found = None;
    'scan: for gz in (-2048..2048).step_by(64) {
        for gx in (-2048..2048).step_by(64) {
            let (typ, ax, az, _ay) = bfcore::worldgen::worldgen_structure_near(gx, gz, 11);
            if typ == 8 || bfcore::worldgen::worldgen_is_city(typ) {
                found = Some((ax, az));
                break 'scan;
            }
        }
    }
    let (ax, az) = found.expect("seed 11 has at least one settlement in 4K x 4K");
    w.debug_visit_village(ax, az);
    assert_eq!(w.debug_visited_village_count(), 1, "village recorded when within range");
    // Same village again: no duplicate.
    w.debug_visit_village(ax + 5, az + 5);
    assert_eq!(w.debug_visited_village_count(), 1, "no duplicate for the same anchor");
}

#[test]
fn map_dat_roundtrip() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let dir = std::env::temp_dir().join(format!("bf_map_rt_{}", std::process::id()));
    let dir = dir.to_string_lossy().to_string();
    let _ = std::fs::remove_dir_all(&dir);

    let (explored, totems, villages) = {
        let mut w = make_world(&content, 11);
        let (px, _py, pz, _) = w.get_player();
        assert!(w.debug_place_totem(px as i32 + 2, 40, pz as i32 + 2));
        assert!(w.debug_place_totem(px as i32 + 4, 40, pz as i32 + 2));
        // Record a visited village (probe straight at some anchor).
        let mut found = None;
        'scan: for gz in (-2048..2048).step_by(64) {
            for gx in (-2048..2048).step_by(64) {
                let (typ, ax, az, _ay) = bfcore::worldgen::worldgen_structure_near(gx, gz, 11);
                if typ == 8 || bfcore::worldgen::worldgen_is_city(typ) {
                    found = Some((ax, az));
                    break 'scan;
                }
            }
        }
        if let Some((ax, az)) = found {
            w.debug_visit_village(ax, az);
        }
        assert!(w.save(&dir), "save wrote map.dat");
        (w.debug_explored_count(), w.debug_totem_count(), w.debug_visited_village_count())
    };
    assert!(std::fs::metadata(format!("{}/map.dat", dir)).is_ok(), "map.dat exists");

    let mut w2 = World::new(Some(TerrainGen::new()));
    w2.debug_set_sync_streaming(true);
    w2.set_content(&content);
    assert!(w2.load(&dir), "reload the save");
    assert_eq!(w2.debug_totem_count(), totems, "totems survive reload");
    assert_eq!(w2.debug_visited_village_count(), villages, "villages survive reload");
    // Load re-marks around the player, which can only ADD explored cells.
    assert!(w2.debug_explored_count() >= explored, "explored bits survive reload");
    // Totem numbering continues after reload (Totem 3, not Totem 1 again).
    let (px, _py, pz, _) = w2.get_player();
    assert!(w2.debug_place_totem(px as i32 + 6, 40, pz as i32 + 2));
    let markers = w2.map_markers();
    let last = markers.last().unwrap();
    assert_eq!(last.name, "Totem 3", "totem numbering persists");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn teleport_lands_on_surface_never_in_solid() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = make_world(&content, 11);

    // A totem placed FAR away (never streamed): sit it on the real surface.
    let (px, _py, pz, _) = w.get_player();
    let ttx = (px as i32 + 5000) & (bfcore::worldgen::WORLD_PERIOD - 1);
    let ttz = (pz as i32 + 7000) & (bfcore::worldgen::WORLD_PERIOD - 1);
    let surf = bfcore::worldgen::worldgen_surface_height(ttx, ttz, 11);
    assert!(w.debug_place_totem(ttx, surf + 1, ttz));

    // Teleport to it (totems are marker id 200 + index).
    assert!(w.map_teleport(200), "teleport to totem 0 succeeds");
    let (nx, ny, nz, _) = w.get_player();
    let dx = (nx as i32 - ttx).abs();
    let dz = (nz as i32 - ttz).abs();
    assert!(dx <= 1 && dz <= 1, "arrived at the totem column ({} {})", dx, dz);
    assert!(!w.debug_player_collides(), "never arrive inside solid");
    assert!(ny > surf as f32, "standing above the surface");
    // Streaming recentred: the destination area becomes resident on update.
    for _ in 0..40 {
        w.update(&zero_input(), 0.05);
    }
    assert!(
        w.debug_resident_count() > 0,
        "destination streams after teleport"
    );
    // The destination map cell is revealed.
    assert!(w.debug_explored_at(ttx, ttz), "teleport reveals the destination cell");

    // Home teleport works too and lands clear of solid.
    assert!(w.map_teleport(1), "teleport home succeeds");
    assert!(!w.debug_player_collides(), "home arrival not in solid");
    // Unknown ids are refused.
    assert!(!w.map_teleport(999), "unknown marker id refused");
    assert!(!w.map_teleport(201), "missing totem index refused");
}
