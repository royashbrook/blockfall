use super::*;

impl<'c> World<'c> {
    pub(super) fn hurt_player(&mut self, dmg: f32) {
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
        let y = if top != NO_FLOOR {
            top as f32 + 3.2
        } else {
            self.spawn.y
        };
        self.pos = V3::new(self.spawn.x, y, self.spawn.z);
        self.vy = 0.0;
        self.health = 20.0;
        self.oxygen = 1.0;
        self.hurt_cd = 1.5;
        self.regen_cd = 0.0;
        self.drown_cd = 0.0;
        self.first_stream = true;
        self.stream_active_r = 2.min(self.stream_r);
        self.recompute_stream_set();
        self.creatures.retain(|c| !c.hostile);
        let pv = self.player_voxel();
        self.fx(6, pv, 0);
    }

    // Small helper: set the achievement-toast banner with the standard 3s timer.
    pub(super) fn toast(&mut self, msg: &str) {
        self.ach_toast = msg.into();
        self.ach_toast_timer = 3.0;
    }

    // ---- per-frame update ------------------------------------------------
    pub fn update(&mut self, input: &bf_frame_input, dt: f64) {
        let mut dt = dt;
        if dt > 0.1 {
            dt = 0.1;
        }
        let dtf = dt as f32;
        self.moving =
            (input.move_forward.abs() + input.move_strafe.abs() + (input.jump as f32).abs()) > 0.1;
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
        let base_spd = if self.mode == bf_game_mode::BF_MODE_CREATIVE {
            8.0
        } else {
            5.0
        };
        // Creative sprint is a fast fly/run for building and exploring: roughly 5x the
        // survival sprint speed (survival sprint stays at 8.5; 8.5 * 5 = 42.5).
        let sprint_spd = if self.mode == bf_game_mode::BF_MODE_CREATIVE {
            42.5
        } else {
            8.5
        };
        let speed = (if input.sprint != 0 {
            sprint_spd
        } else {
            base_spd
        }) * dtf;
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

        // #179 looping world: canonicalize the player onto the torus AFTER all
        // movement/collision for this tick (collision reads canonicalize block
        // coords themselves, so a transiently out-of-range pos is safe). From
        // here on every consumer (streaming, chunk math, saves) sees x/z in
        // [0, WORLD_PERIOD).
        self.pos.x = Self::wrap_pos_f(self.pos.x);
        self.pos.z = Self::wrap_pos_f(self.pos.z);

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
        self.maybe_expand_stream_radius();

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
                    self.block_at(IVec3 {
                        x: pv.x,
                        y: gy - 1,
                        z: pv.z,
                    })
                } else {
                    GRASS
                };
                self.fx(2, pv, Self::footstep_class(fb));
                // #117 footprint: if the cell at the player's feet is fresh snow, compress
                // it into a trodden print. Bounded by construction (one cell per step, and
                // fresh snow only converts once), so there is no growing print buffer.
                if gy != NO_FLOOR {
                    self.stamp_footprint(IVec3 {
                        x: pv.x,
                        y: gy,
                        z: pv.z,
                    });
                }
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
        self.update_debris(dtf);
    }
}
