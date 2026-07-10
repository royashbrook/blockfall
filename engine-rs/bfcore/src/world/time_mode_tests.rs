use super::*;

#[test]
fn visual_detail_radii_scale_with_render_distance() {
    let detail_radius = |chunks: i32| (chunks as f32 * KCHUNK_DIM as f32).clamp(96.0, 130.0);   // #219 clutter cap
    let leaf_radius = |chunks: i32| (chunks as f32 * KCHUNK_DIM as f32).clamp(120.0, 256.0);
    let scenery_radius = |chunks: i32| (chunks as f32 * KCHUNK_DIM as f32).clamp(120.0, 384.0);
    let shadow_radius = |chunks: i32| {
        let stream_blocks = chunks * KCHUNK_DIM;
        let shadow_blocks = if stream_blocks >= 16 * RENDER_DISTANCE_UNIT_BLOCKS {
            16 * RENDER_DISTANCE_UNIT_BLOCKS
        } else {
            8 * RENDER_DISTANCE_UNIT_BLOCKS
        };
        block_radius_to_chunk_radius(shadow_blocks)
    };
    let mut w = World::new(None);
    assert_eq!(w.shadow_radius_chunks(), shadow_radius(w.stream_r));
    assert_eq!(w.prop_detail_radius_blocks(), detail_radius(w.stream_r));
    assert_eq!(w.prop_leaf_radius_blocks(), leaf_radius(w.stream_r));
    assert_eq!(w.prop_scenery_radius_blocks(), scenery_radius(w.stream_r));

    w.set_render_distance(24);
    assert_eq!(w.stream_r, render_units_to_chunk_radius(24));
    assert_eq!(w.shadow_radius_chunks(), shadow_radius(w.stream_r));
    assert_eq!(w.prop_detail_radius_blocks(), detail_radius(w.stream_r));
    assert_eq!(w.prop_leaf_radius_blocks(), leaf_radius(w.stream_r));
    assert_eq!(w.prop_scenery_radius_blocks(), scenery_radius(w.stream_r));

    w.set_render_distance(40);
    assert_eq!(w.stream_r, render_units_to_chunk_radius(40));
    assert_eq!(w.shadow_radius_chunks(), shadow_radius(w.stream_r));
    assert_eq!(w.prop_detail_radius_blocks(), detail_radius(w.stream_r));
    assert_eq!(w.prop_leaf_radius_blocks(), leaf_radius(w.stream_r));
    assert_eq!(w.prop_scenery_radius_blocks(), scenery_radius(w.stream_r));
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
    assert_eq!(
        w.debug_block_at(0, 11, 0),
        TRODDEN_SNOW,
        "fresh snow becomes a print"
    );

    // Stepping again does nothing (already trodden), so a trail does not churn.
    w.stamp_footprint(IVec3 { x: 0, y: 11, z: 0 });
    assert_eq!(w.debug_block_at(0, 11, 0), TRODDEN_SNOW);

    // Stepping on a non-snow cell leaves it untouched.
    w.debug_edit(2, 10, 0, GRASS);
    w.stamp_footprint(IVec3 { x: 2, y: 10, z: 0 });
    assert_eq!(
        w.debug_block_at(2, 10, 0),
        GRASS,
        "non-snow is never stamped"
    );
}

// #118 snow overlay is walk-through: the player stands on the surface block below,
// not on top of the snow cell (so the blanket sits at their feet and prints read at
// ground level). Snow must not collide.
#[test]
fn snow_overlay_does_not_collide() {
    let w = World::new(None);
    assert!(
        !World::solid_block(SNOW_LAYER),
        "fresh snow is walk-through"
    );
    assert!(
        !World::solid_block(TRODDEN_SNOW),
        "trodden snow is walk-through"
    );
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
    assert_eq!(
        w.world_clock, frozen,
        "world_clock advanced while paused (dt=0)"
    );
    assert_eq!(
        w.debug_day_time(),
        frozen_phase,
        "day phase moved while paused"
    );
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

// #237: the hostile-spawn night gate must agree with the sun. is_night_phase
// says night exactly when the sun is below the horizon in the render geometry,
// so the T night pin (TIME_PHASE_NIGHT) spawns monsters and mornings never do.
#[test]
fn night_gate_tracks_the_sun() {
    // The pinned phases are the two anchor cases that were broken.
    assert!(World::is_night_phase(World::TIME_PHASE_NIGHT), "night pin must gate as night");
    assert!(!World::is_night_phase(World::TIME_PHASE_DAY), "day pin must not gate as night");
    // The old t<0.20||t>0.80 band called 8am night; never again.
    for &h in &[6.5f32, 8.0, 10.0, 12.0, 18.0] {
        let phase = (0.25 + (h - 12.0) / 24.0).rem_euclid(1.0);
        assert!(!World::is_night_phase(phase), "{h:.1}h gated as night");
    }
    for &h in &[0.0f32, 2.0, 22.0, 23.5] {
        let phase = (0.25 + (h - 12.0) / 24.0).rem_euclid(1.0);
        assert!(World::is_night_phase(phase), "{h:.1}h should gate as night");
    }
    // And it must match the sun's sign everywhere (sunrise/sunset crossings are
    // exactly where sin(2*pi*t) = -0.25, the elevation zero).
    for i in 0..10_000u32 {
        let phase = (i as f32 + 0.5) / 10_000.0;
        assert_eq!(
            World::is_night_phase(phase),
            sun_elev(phase) < 0.0,
            "gate/sun disagree at phase {phase:.4}"
        );
    }
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
    assert!(
        (start - after).abs() < 1e-4,
        "cycle should close after DAY_CYCLE_SECS"
    );
    // Half a cycle should land near the opposite phase (start 0.0 -> ~0.5).
    let half = World::day_time(World::DAY_CYCLE_SECS / 2.0);
    assert!(
        (half - 0.5).abs() < 1e-3,
        "half cycle should be ~0.5 phase, got {half}"
    );
}

// #162 weather is a pure function of (seed, world_clock): deterministic, in
// range, and the coverage actually sweeps the whole 0..1 span across a few
// in-game days (genuinely clear days AND full overcast both happen).
#[test]
fn weather_cover_deterministic_and_full_range() {
    let seed = 0xB10C_FA11_u64;
    let (mut lo, mut hi) = (1.0f32, 0.0f32);
    let mut prev = World::weather_cover(seed, 0.0);
    let mut t = 0.0f64;
    while t < World::DAY_CYCLE_SECS * 3.0 {
        let c = World::weather_cover(seed, t);
        assert_eq!(c, World::weather_cover(seed, t), "must be deterministic");
        assert!((0.0..=1.0).contains(&c), "coverage out of range: {c}");
        // Smooth: one second of world time never jumps coverage (no popping).
        assert!((c - prev).abs() < 0.01, "coverage popped: {prev} -> {c}");
        prev = c;
        lo = lo.min(c);
        hi = hi.max(c);
        t += 1.0;
    }
    assert!(lo < 0.05, "never reached a clear sky (min {lo})");
    assert!(hi > 0.95, "never reached overcast (max {hi})");
    // A different seed produces a different sky on the same clock somewhere.
    let differs = (0..100).any(|i| {
        let t = i as f64 * 60.0;
        (World::weather_cover(seed, t) - World::weather_cover(seed ^ 0x5EED, t)).abs() > 0.05
    });
    assert!(differs, "seed does not influence weather");
}
