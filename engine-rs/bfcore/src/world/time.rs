use super::*;

impl<'c> World<'c> {
    // One full day/night cycle in seconds of world_clock.
    pub(super) const DAY_CYCLE_SECS: f64 = 24.0 * 60.0;
    pub(super) const DAY_RATE: f64 = 1.0 / Self::DAY_CYCLE_SECS;
    pub(super) const DAY_START_PHASE: f64 = 0.0;

    pub(super) const TIME_PHASE_DAY: f32 = 0.25;
    pub(super) const TIME_PHASE_NIGHT: f32 = 0.75;

    pub(super) fn day_time(clock: f64) -> f32 {
        ((clock * Self::DAY_RATE + Self::DAY_START_PHASE) % 1.0) as f32
    }

    pub(super) fn clock_for_phase(phase: f32) -> f64 {
        let p = phase.rem_euclid(1.0) as f64;
        let frac = (p - Self::DAY_START_PHASE).rem_euclid(1.0);
        frac / Self::DAY_RATE
    }

    // ---- Weather (#162) ---------------------------------------------------
    // Deterministic weather as a pure function of (seed, world_clock). The
    // clock freezes on pause and pins under the T time modes, so weather
    // freezes with it, and the same seed always replays the same skies.
    //
    // Cloud coverage 0..1: two slow sine waves with incommensurate periods
    // (a large fraction of the 24-minute day) and seed-derived phases. Their
    // sum overshoots both endpoints and is clamped, so genuinely clear-blue
    // stretches and full overcast sheets both actually happen, and coverage
    // drifts smoothly between them (no popping).
    pub(super) fn weather_cover(seed: u64, clock: f64) -> f32 {
        let tau = std::f64::consts::TAU;
        let p1 = (seed & 0xFFFF) as f64 * (tau / 65536.0);
        let p2 = ((seed >> 16) & 0xFFFF) as f64 * (tau / 65536.0);
        let a = (clock * (tau / 2210.0) + p1).sin();
        let b = (clock * (tau / 863.0) + p2).sin();
        (0.5 + 0.36 * a + 0.30 * b).clamp(0.0, 1.0) as f32
    }

    // Precipitation gate: its own slow seeded wave, so not every overcast
    // stretch rains. Rain/snow only happens when this is true AND coverage is
    // already heavy (see render_frame), so precip never falls from a clear sky.
    pub(super) fn weather_precip(seed: u64, clock: f64) -> bool {
        let tau = std::f64::consts::TAU;
        let p3 = ((seed >> 32) & 0xFFFF) as f64 * (tau / 65536.0);
        (clock * (tau / 1531.0) + p3).sin() > 0.15
    }

    // Night = the sun is below the horizon, from the SAME sun model render uses
    // (render_frame: sun elevation = sin(2*pi*t) + 0.25, noon at t = 0.25,
    // midnight at 0.75). Everything that gates on "night" must use this, not a
    // hand-rolled band: #237 shipped a t<0.20||t>0.80 gate that was mostly
    // morning, so night monsters never spawned at the T night pin (0.75).
    pub(super) fn is_night_phase(t: f32) -> bool {
        (t * 6.2831853).sin() < -0.25
    }

    pub(super) fn set_time_mode(&mut self, mode: i32) {
        self.time_mode = mode;
        match mode {
            1 => self.world_clock = Self::clock_for_phase(Self::TIME_PHASE_DAY),
            2 => self.world_clock = Self::clock_for_phase(Self::TIME_PHASE_NIGHT),
            _ => self.time_mode = 0,
        }
    }

    pub(super) fn apply_time_pin(&mut self) {
        match self.time_mode {
            1 => self.world_clock = Self::clock_for_phase(Self::TIME_PHASE_DAY),
            2 => self.world_clock = Self::clock_for_phase(Self::TIME_PHASE_NIGHT),
            _ => {}
        }
    }
}
