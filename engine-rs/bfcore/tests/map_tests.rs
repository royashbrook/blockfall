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

fn settlement(seed: u64, city: bool) -> (i32, i32) {
    for z in (-4096..4096).step_by(64) {
        for x in (-4096..4096).step_by(64) {
            let (typ, ax, az, _) = bfcore::worldgen::worldgen_structure_near(x, z, seed);
            if (city && bfcore::worldgen::worldgen_is_city(typ)) || (!city && typ == 8) {
                return (ax, az);
            }
        }
    }
    panic!("seed {seed} has no requested settlement");
}

#[test]
fn spawn_reveals_a_centred_home_clearing() {
    // #189: home must sit in the MIDDLE of a round explored clearing, not at the
    // edge of a walked trail. After a fresh spawn the explored mask is a disc
    // centred on the player: symmetric in +/-x and +/-z, filled through most of
    // the radius, and dark beyond it.
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let w = make_world(&content, 11);
    let (px, _py, pz, _) = w.get_player();
    let (cx, cz) = (px as i32, pz as i32);
    let cell = world::MAP_CELL;
    let r = world::HOME_CLEARING_CELLS;

    assert!(w.debug_explored_at(cx, cz), "home cell is explored");
    // Symmetric well inside the radius (a few cells in each cardinal direction).
    for k in 1..r - 1 {
        let d = k * cell + cell / 2;
        for (dx, dz) in [(d, 0), (-d, 0), (0, d), (0, -d)] {
            assert!(
                w.debug_explored_at(cx + dx, cz + dz),
                "cell {k} out from home should be inside the clearing"
            );
        }
    }
    // Well beyond the radius is still grey (the clearing is bounded, not the map).
    let far = (r + 4) * cell;
    assert!(
        !w.debug_explored_at(cx + far, cz) && !w.debug_explored_at(cx, cz + far),
        "cells past the clearing radius stay unexplored"
    );
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
    assert_eq!(
        w.debug_totem_count(),
        1,
        "placing a totem registers a marker"
    );
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
    assert!(
        !w.debug_place_totem(px as i32, 45, pz as i32),
        "17th placement refused"
    );
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

    // Walk the player east PAST the #189 spawn clearing (8 cells = 512 blocks):
    // cells out here get revealed as chunk boundaries are crossed. Move in
    // creative fly (no falling) for a clean run.
    let far_x = px + 900.0;
    w.debug_set_camera(far_x, 80.0, pz, 0.0, 0.0);
    w.update(&zero_input(), 0.05);
    assert!(
        w.debug_explored_at(far_x as i32, pz as i32),
        "cell at the new position is explored"
    );
    assert!(w.debug_explored_count() > before, "exploration grew");
}

// #233: a single-frame jump much larger than the reveal disc (hyperspeed +
// hitchy frame) must not leave unexplored holes along the flown path — the
// movement reveal sweeps the whole travelled segment.
#[test]
fn fast_flight_reveals_the_whole_path() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut w = make_world(&content, 11);
    let (px, _py, pz, _) = w.get_player();

    // One giant hop: 6000 blocks east in a single update.
    let far_x = px + 6000.0;
    w.debug_set_camera(far_x, 80.0, pz, 0.0, 0.0);
    w.update(&zero_input(), 0.05);

    // Every point along the segment is explored, not just the endpoints.
    for i in 0..=20 {
        let x = px + 6000.0 * (i as f32) / 20.0;
        assert!(
            w.debug_explored_at(x as i32, pz as i32),
            "path cell at x={x} explored (no gaps in the flight trail)"
        );
    }
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
    assert_eq!(
        w.debug_visited_village_count(),
        1,
        "village recorded when within range"
    );
    // Same village again: no duplicate.
    w.debug_visit_village(ax + 5, az + 5);
    assert_eq!(
        w.debug_visited_village_count(),
        1,
        "no duplicate for the same anchor"
    );
}

#[test]
fn settlement_markers_follow_derived_class_and_raw_tier_persists() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let seed = 11;
    let (vx, vz) = settlement(seed, false);
    let (cx, cz) = settlement(seed, true);
    let dir = std::env::temp_dir().join(format!("bf_growth_rt_{}", std::process::id()));
    let dir = dir.to_string_lossy().to_string();
    let _ = std::fs::remove_dir_all(&dir);

    let mut world = make_world(&content, seed);
    assert!(world.debug_road_route_count() > 0, "HOME city has a derived route");
    assert!((0..world.debug_road_route_count()).any(|i| {
        world
            .debug_road_route(i)
            .map(|route| route.6 == 3)
            .unwrap_or(false)
    }));
    world.debug_visit_village(vx, vz);
    let village = &world.map_markers()[1];
    assert_eq!((village.kind, village.name.as_str()), (1, "Village 1"));

    world.debug_set_village_tier(vx, vz, 2);
    let town = &world.map_markers()[1];
    assert_eq!((town.kind, town.name.as_str()), (4, "Town 1"));
    assert_eq!(world.debug_settlement_class(vx, vz), 1);
    assert_eq!(world.debug_village_raw_tier(vx, vz), 2);
    assert!(world.save(&dir));

    let mut loaded = World::new(Some(TerrainGen::new()));
    loaded.debug_set_sync_streaming(true);
    loaded.set_content(&content);
    assert!(loaded.load(&dir));
    assert_eq!(loaded.debug_village_raw_tier(vx, vz), 2);
    let town = &loaded.map_markers()[1];
    assert_eq!((town.kind, town.name.as_str()), (4, "Town 1"));

    loaded.debug_set_village_tier(vx, vz, 3);
    loaded.debug_set_village_tier(vx, vz, 1);
    let city = &loaded.map_markers()[1];
    assert_eq!((city.kind, city.name.as_str()), (3, "City 1"));
    assert_eq!(loaded.debug_village_raw_tier(vx, vz), 3, "no regression");

    let mut natural = make_world(&content, seed);
    natural.debug_visit_village(cx, cz);
    let city = &natural.map_markers()[1];
    assert_eq!((city.kind, city.name.as_str()), (3, "City 1"));
    assert_eq!(natural.debug_village_raw_tier(cx, cz), 0);
    assert_eq!(
        natural.debug_village_tier(cx, cz),
        3,
        "natural city is complete"
    );
    assert_eq!(
        natural.village_view_nearest().expect("HOME city HUD view").2,
        3,
        "natural city reports complete through the live HUD feed"
    );

    let _ = std::fs::remove_dir_all(&dir);
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
        (
            w.debug_explored_count(),
            w.debug_totem_count(),
            w.debug_visited_village_count(),
        )
    };
    assert!(
        std::fs::metadata(format!("{}/map.dat", dir)).is_ok(),
        "map.dat exists"
    );

    let mut w2 = World::new(Some(TerrainGen::new()));
    w2.debug_set_sync_streaming(true);
    w2.set_content(&content);
    assert!(w2.load(&dir), "reload the save");
    assert_eq!(w2.debug_totem_count(), totems, "totems survive reload");
    assert_eq!(
        w2.debug_visited_village_count(),
        villages,
        "villages survive reload"
    );
    // Load re-marks around the player, which can only ADD explored cells.
    assert!(
        w2.debug_explored_count() >= explored,
        "explored bits survive reload"
    );
    // Totem numbering continues after reload (Totem 3, not Totem 1 again).
    let (px, _py, pz, _) = w2.get_player();
    assert!(w2.debug_place_totem(px as i32 + 6, 40, pz as i32 + 2));
    let markers = w2.map_markers();
    let last = markers.last().unwrap();
    assert_eq!(last.name, "Totem 3", "totem numbering persists");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn caravan_trailer_roundtrips_and_old_or_truncated_maps_are_safe() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let dir = std::env::temp_dir().join(format!("bf_caravan_rt_{}", std::process::id()));
    let dir = dir.to_string_lossy().to_string();
    let _ = std::fs::remove_dir_all(&dir);

    let mut world = make_world(&content, 11);
    assert!(world.debug_set_caravan_state(0, 777, false, 1, 9));
    world.debug_caravan_tick(0.01);
    let expected = world.debug_caravan_state(0).unwrap();
    assert!(world.save(&dir));
    let map_path = format!("{dir}/map.dat");
    let full = std::fs::read(&map_path).unwrap();
    let trailer = full
        .windows(4)
        .rposition(|window| window == b"BFT1")
        .expect("BFT1 trailer");

    let mut loaded = World::new(Some(TerrainGen::new()));
    loaded.debug_set_sync_streaming(true);
    loaded.set_content(&content);
    assert!(loaded.load(&dir));
    assert_eq!(loaded.debug_caravan_state(0), Some(expected));
    world.debug_caravan_tick(0.001);
    loaded.debug_caravan_tick(0.001);
    assert_eq!(
        loaded.debug_caravan_state(0),
        world.debug_caravan_state(0),
        "the fixed-time remainder survives save/load"
    );

    std::fs::write(&map_path, &full[..trailer]).unwrap();
    assert!(loaded.debug_set_caravan_state(0, 999, false, 0, 0));
    assert!(loaded.load(&dir));
    assert_eq!(loaded.debug_caravan_state(0), Some((0, true, 3, 3)));

    std::fs::write(&map_path, &full[..trailer + 18]).unwrap();
    assert!(loaded.debug_set_caravan_state(0, 555, false, 0, 0));
    assert!(loaded.load(&dir));
    assert_eq!(loaded.debug_caravan_state(0), Some((0, true, 3, 3)));

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn endpoint_stock_gates_and_is_consumed_by_coin_buy_offers() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    let mut world = make_world(&content, 11);
    let (fx, fz, _, _) = world.debug_caravan_endpoints(0).unwrap();
    world.debug_set_camera(fx as f32 + 0.5, 20.0, fz as f32 + 0.5, 0.0, 0.0);
    assert!(world.debug_set_caravan_state(0, 0, true, 0, 0));

    let mut offers = bf_trade_view::default();
    world.trade_offers(4, &mut offers);
    assert_eq!(
        offers.offer_count, 1,
        "sell offer remains when caravan stock is empty"
    );

    assert!(world.debug_set_caravan_state(0, 0, true, 2, 0));
    world.trade_offers(4, &mut offers);
    assert_eq!(
        offers.offer_count, 3,
        "delivery stock enables both coin-buy offers"
    );
    let coin = world.debug_item_id("coin");
    world.debug_clear_inventory();
    assert!(
        !world.trade_execute(4, 1),
        "short payment refuses the purchase"
    );
    assert_eq!(
        world.debug_caravan_state(0).unwrap().2,
        2,
        "a failed purchase consumes no delivery stock"
    );
    world.debug_give(coin, 2);
    assert!(world.trade_execute(4, 1));
    assert!(world.trade_execute(4, 1));
    assert_eq!(world.debug_caravan_state(0).unwrap().2, 0);
    world.trade_offers(4, &mut offers);
    assert_eq!(
        offers.offer_count, 1,
        "buy offers hide after the last batch sells"
    );
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
    assert!(
        dx <= 1 && dz <= 1,
        "arrived at the totem column ({} {})",
        dx,
        dz
    );
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
    assert!(
        w.debug_explored_at(ttx, ttz),
        "teleport reveals the destination cell"
    );

    // Home teleport works too and lands clear of solid.
    assert!(w.map_teleport(1), "teleport home succeeds");
    assert!(!w.debug_player_collides(), "home arrival not in solid");
    // Unknown ids are refused.
    assert!(!w.map_teleport(999), "unknown marker id refused");
    assert!(!w.map_teleport(201), "missing totem index refused");
}

// #248: a fresh world spawns HOME beside a city, not the first smaller village.
#[test]
fn fresh_spawn_is_at_a_city() {
    let mut content = ContentRegistry::new();
    content.load(CONTENT);
    for seed in [11u64, 42, 99, 2026] {
        let w = make_world(&content, seed);
        let (px, _py, pz, _) = w.get_player();
        let near = bfcore::worldgen::worldgen_city_near(px as i32, pz as i32, 48, seed);
        assert!(
            near.is_some(),
            "seed {seed}: spawn ({px:.0},{pz:.0}) not within 48 blocks of a city"
        );
        assert!(
            bfcore::worldgen::worldgen_surface_height(px as i32, pz as i32, seed) >= 7,
            "seed {seed}: city HOME is not on dry land"
        );
        assert!(!w.debug_player_collides(), "seed {seed}: city spawn is clear");
    }
}
