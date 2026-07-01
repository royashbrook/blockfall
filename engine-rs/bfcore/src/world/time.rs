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
