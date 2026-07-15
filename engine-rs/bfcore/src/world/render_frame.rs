use super::*;

fn creature_animation_id(
    model: i32,
    given: &str,
    home_x: i32,
    home_z: i32,
    npc_id: i32,
    color: V3,
    entity_index: usize,
) -> u32 {
    if model != 20 {
        return (entity_index as u32).wrapping_add(1);
    }
    let mut id = 2_166_136_261u32;
    for byte in given.bytes() {
        id = (id ^ u32::from(byte)).wrapping_mul(16_777_619);
    }
    // Names repeat within a city and most residents share home + role. Clothing
    // is generated from the per-villager stable hash, so its exact bits finish
    // the identity without tying animation state to render order or position.
    for value in [home_x as u32, home_z as u32, npc_id as u32,
                  color.x.to_bits(), color.y.to_bits(), color.z.to_bits()] {
        id = (id ^ value).wrapping_mul(16_777_619);
    }
    id.max(1)
}

impl<'c> World<'c> {
    /// How far from the camera to include all sub-voxel detail props. These are separate
    /// from chunk meshes; a fixed 120-block cutoff made high-altitude creative flight show
    /// terrain without nearby scenery. Keep small ground clutter bounded for the M1 Air target.
    pub(super) fn prop_detail_radius_blocks(&self) -> f32 {
        // #219: capped 192 -> 130. Past ~130 blocks a grass sprig is 1-3px, too
        // small to read, and under cel shading its ink outline collapsed it into
        // black plus-dots printing rows across open ground in every biome. Also a
        // small #211 win (fewer far clutter instances).
        ((self.stream_r as f32) * KCHUNK_DIM as f32).clamp(96.0, 130.0)
    }

    /// Leaf props dominate dense-forest vertex count, so keep canopies closer than trunks.
    pub(super) fn prop_leaf_radius_blocks(&self) -> f32 {
        ((self.stream_r as f32) * KCHUNK_DIM as f32).clamp(120.0, 256.0)
    }

    /// Far scenery LOD: keep trunks visible after tiny grass/flower props and leaf detail
    /// drop out. This is a CPU-side prop cull, so it needs no renderer ABI changes.
    pub(super) fn prop_scenery_radius_blocks(&self) -> f32 {
        ((self.stream_r as f32) * KCHUNK_DIM as f32).clamp(120.0, 384.0)
    }

    // ---- build_frame -----------------------------------------------------
    // Meshes dirty chunks, then fills the abi render frame. draws / shadow_draws /
    // prop_instances are owned by the caller (matching the C++ out-params); the
    // returned frame's raw pointers reference them, so they must outlive the frame.
    pub fn build_frame(
        &mut self,
        out: &mut bf_render_frame,
        draws: &mut Vec<bf_draw_item>,
        shadow_draws: &mut Vec<bf_draw_item>,
        prop_instances: &mut Vec<bf_prop_instance>,
        _clock: f64, // engine wall clock; render day/night uses self.world_clock so the
                     // T time-mode pin (which pins world_clock) actually moves the rendered sun.
    ) {
        self.remesh_dirty();
        draws.clear();
        prop_instances.clear();
        let cam_fwd = self.forward_dir();
        let cam_pos = self.pos;
        // #179 looping world: everything sent to the GPU is positioned at its
        // NEAREST IMAGE relative to the camera, so a chunk or creature just
        // across the seam renders adjacent instead of 32K blocks away.
        let cam_cx = Self::floordiv(Self::ifloor(cam_pos.x), KCHUNK_DIM);
        let cam_cz = Self::floordiv(Self::ifloor(cam_pos.z), KCHUNK_DIM);
        let rel_chunk = |cc: &ChunkCoord| -> (i32, i32) {
            (
                cam_cx + Self::wrap_signed_chunk(cc.x - cam_cx),
                cam_cz + Self::wrap_signed_chunk(cc.z - cam_cz),
            )
        };
        let kcull_cos = 0.30f32;
        let kfar_cull_cos = 0.45f32;
        let knear_keep = KCHUNK_DIM as f32 * 1.5;
        // #196: a chunk is a VOLUME, not a point. Culling on the CENTER angle alone
        // dropped chunks whose near corner was still on-screen, so rotating the view
        // made geometry pop in/out at the screen edges. Cull against the chunk's
        // bounding sphere instead: keep when dot(to_c, fwd) >= cos * dist - R, which
        // is the center test relaxed by the sphere radius (conservative first-order
        // sphere-vs-cone). R = half the chunk diagonal, plus a small slack for the
        // linearisation error of the relaxed test at near range.
        let kchunk_r = KCHUNK_DIM as f32 * 0.8660254 + 3.0;
        // Iterate meshes in a stable-enough order (HashMap order is fine; the C++
        // also iterates an unordered_map). Collect coords first to avoid borrow
        // conflicts with region_sat reads.
        let mesh_coords: Vec<ChunkCoord> = self.meshes.keys().copied().collect();
        for cc in &mesh_coords {
            let (has_buffers, index_count, vbuf_h, ibuf_h) = {
                let rec = &self.meshes[cc];
                (
                    rec.has_buffers,
                    rec.index_count,
                    rec.vbuf.handle,
                    rec.ibuf.handle,
                )
            };
            let (rcx, rcz) = rel_chunk(cc);
            let ctr = V3::new(
                (rcx as f32 + 0.5) * KCHUNK_DIM as f32,
                (cc.y as f32 + 0.5) * KCHUNK_DIM as f32,
                (rcz as f32 + 0.5) * KCHUNK_DIM as f32,
            );
            let to_c = V3::new(ctr.x - cam_pos.x, ctr.y - cam_pos.y, ctr.z - cam_pos.z);
            let dist = dot(to_c, to_c).sqrt();
            if dist < 176.0 && self.unlit_far_meshes.contains(cc) {
                self.mark_dirty(*cc);
            }
            // #196: sphere-relaxed view cone tests (see kchunk_r above). The far
            // threshold also widened (0.55 -> 0.45): with the app's real aspect the
            // screen half-diagonal reaches ~55-60 degrees, so the old 56.6-degree
            // far cone clipped chunks that were still on-screen at the corners.
            let along = dot(to_c, cam_fwd);
            if dist > knear_keep && along < kcull_cos * dist - kchunk_r {
                continue;
            }
            if dist > 192.0 && along < kfar_cull_cos * dist - kchunk_r {
                continue;
            }
            // Props BEFORE the empty-mesh skip below. Since #62 leaves and logs are
            // instanced props, not cube faces, so a canopy-only chunk meshes EMPTY
            // (no buffers) and used to be skipped entirely: its trees never rendered
            // while their occupancy shadows did (a field of tree shadows with
            // invisible, breakable trees). Props do not need mesh buffers.
            let detail_radius = self.prop_detail_radius_blocks();
            let leaf_radius = self.prop_leaf_radius_blocks();
            let scenery_radius = self.prop_scenery_radius_blocks();
            let max_prop_radius = detail_radius.max(leaf_radius).max(scenery_radius);
            if dist < max_prop_radius + kchunk_r {
                let props = &self.meshes[cc].props;
                if !props.is_empty() {
                    // #179: props carry ABSOLUTE world positions and the prop shader
                    // does world = position + local, so they must be shifted by the
                    // SAME nearest-image chunk offset the terrain mesh uses above.
                    // Without this a chunk across the seam draws its terrain adjacent
                    // (via chunk_origin) but every tree/grass/flower 32768 blocks away,
                    // so the whole forest pops out of existence while its occupancy
                    // shadows stay, the exact invisible-breakable-trees failure props
                    // were built to avoid.
                    let dx_off = ((rcx - cc.x) * KCHUNK_DIM) as f32;
                    let dz_off = ((rcz - cc.z) * KCHUNK_DIM) as f32;
                    let shift = |mut p: bf_prop_instance| {
                        p.position.x += dx_off;
                        p.position.z += dz_off;
                        p
                    };
                    let detail_r2 = detail_radius * detail_radius;
                    let leaf_r2 = leaf_radius * leaf_radius;
                    let scenery_r2 = scenery_radius * scenery_radius;
                    for p in props.iter().copied().map(shift) {
                        let dx = p.position.x - cam_pos.x;
                        let dy = p.position.y - cam_pos.y;
                        let dz = p.position.z - cam_pos.z;
                        let d2 = dx * dx + dy * dy + dz * dz;
                        let ty = p.type_ as BlockId;
                        if d2 < detail_r2
                            || (d2 < leaf_r2 && Self::is_leaf(ty))
                            || (d2 < scenery_r2 && Self::is_log(ty))
                        {
                            prop_instances.push(p);
                        }
                    }
                }
            }
            if !has_buffers || index_count == 0 {
                continue;
            }
            let lod = if dist > 192.0 { 1 } else { 0 };
            let has_water = if self.meshes[cc].has_water { 2 } else { 0 };
            let mut d = bf_draw_item {
                vertex_buffer: vbuf_h,
                index_buffer: ibuf_h,
                vertex_offset: 0,
                index_offset: 0,
                index_count,
                material_id: lod | has_water,
                chunk_origin: bf_ivec3 {
                    x: rcx * KCHUNK_DIM,
                    y: cc.y * KCHUNK_DIM,
                    z: rcz * KCHUNK_DIM,
                },
                dim_saturation: 0.0,
                dim_sat_px: 0.0,
                dim_sat_pz: 0.0,
                dim_sat_pxz: 0.0,
            };
            d.dim_saturation = self.region_sat(*cc);
            d.dim_sat_px = self.region_sat(ChunkCoord {
                x: cc.x + 1,
                y: cc.y,
                z: cc.z,
            });
            d.dim_sat_pz = self.region_sat(ChunkCoord {
                x: cc.x,
                y: cc.y,
                z: cc.z + 1,
            });
            d.dim_sat_pxz = self.region_sat(ChunkCoord {
                x: cc.x + 1,
                y: cc.y,
                z: cc.z + 1,
            });
            draws.push(d);
        }

        let fwd = self.forward_dir();
        let flat = normalize(V3::new(fwd.x, 0.0, fwd.z));
        let rightv = normalize(cross(flat, V3::new(0.0, 1.0, 0.0)));
        let bob_y = (self.bob_phase * 2.0).sin() * 0.06 * self.bob_amt;
        let bob_x = self.bob_phase.cos() * 0.045 * self.bob_amt;
        let eye = self.pos + V3::new(0.0, bob_y, 0.0) + rightv * bob_x;
        let ctr = eye + fwd;
        let view = look_at(eye, ctr, V3::new(0.0, 1.0, 0.0));
        let proj = perspective(1.20, 1.6, 0.05, 1024.0);
        out.camera.view.m = view;
        out.camera.proj.m = proj;
        out.camera.position = bf_vec3 {
            x: eye.x,
            y: eye.y,
            z: eye.z,
        };
        out.camera.forward = bf_vec3 {
            x: fwd.x,
            y: fwd.y,
            z: fwd.z,
        };
        let t = Self::day_time(self.world_clock);
        out.camera.time_of_day = t;
        let ang = t * 6.2831853;
        out.camera.sun_dir = bf_vec3 {
            x: ang.cos() * 0.6,
            y: -ang.sin() - 0.25,
            z: 0.90,
        };
        out.camera.underwater = if self.block_at(IVec3 {
            x: Self::ifloor(eye.x),
            y: Self::ifloor(eye.y),
            z: Self::ifloor(eye.z),
        }) == WATER
        {
            1.0
        } else {
            0.0
        };
        // Cold area scan.
        {
            let mut cold = false;
            let px = Self::ifloor(eye.x);
            let pz = Self::ifloor(eye.z);
            let mut y = Self::ifloor(eye.y);
            while y > Self::ifloor(eye.y) - 8 && !cold {
                let b = self.block_at(IVec3 { x: px, y, z: pz });
                if b == 12 || b == 13 {
                    cold = true;
                } else if b != AIR && b != WATER && !Self::is_plant(b) {
                    break;
                }
                y -= 1;
            }
            out.camera.biome_cold = if cold { 1.0 } else { 0.0 };
            // #162 deterministic weather: cloud coverage + precip from (seed,
            // world_clock), see time.rs. State for the HUD:
            //   0 = Clear, 1 = Rain, 2 = Snow, 3 = Partly Cloudy, 4 = Overcast.
            // Precip only under heavy coverage, so rain never falls from blue sky.
            let cover = Self::weather_cover(self.seed, self.world_clock);
            let precip = cover > 0.78 && Self::weather_precip(self.seed, self.world_clock);
            self.weather = if precip {
                if cold {
                    2
                } else {
                    1
                }
            } else if cover < 0.30 {
                0
            } else if cover < 0.62 {
                3
            } else {
                4
            };
            // camera.weather packs the renderer's two weather inputs into the
            // existing f32 (no ABI change): integer part = precip mode (0 none,
            // 1 rain, 2 snow), fraction = cloud coverage scaled by 0.98 so a
            // full-cover value never bumps the integer part.
            let precip_mode = match self.weather {
                1 | 2 => self.weather as f32,
                _ => 0.0,
            };
            out.camera.weather = precip_mode + (cover * 0.98).clamp(0.0, 0.98);
        }
        {
            let surf = worldgen::worldgen_surface_height(
                Self::ifloor(eye.x),
                Self::ifloor(eye.z),
                self.seed,
            );
            let depth = (surf - Self::ifloor(eye.y)) as f32;
            out.camera.underground = ((depth - 3.0) / 8.0).clamp(0.0, 1.0);
        }
        out.camera.local_sat = self.region_sat(Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        }));
        out.interp_alpha = 0.0;
        out.draws = draws.as_ptr();
        out.draw_count = draws.len() as u32;
        out.regions = std::ptr::null();
        out.region_count = 0;

        // The shadow-map pass is retired. World-space voxel shadows use
        // bf_world_shadow_volume instead, so keep the ABI field empty.
        shadow_draws.clear();
        out.shadow_draws = std::ptr::null();
        out.shadow_draw_count = 0;
        out.prop_instances = prop_instances.as_ptr();
        out.prop_instance_count = prop_instances.len() as u32;

        // Creatures.
        self.entities.clear();
        self.entity_role_actions.clear();
        self.entity_appearances.clear();
        const KANIMAL_KIND: [u32; 8] = [0, 1, 2, 3, 7, 8, 9, 10];
        for (entity_index, cr) in self.creatures.iter().enumerate() {
            let social = if cr.model == 20 {
                cr.social.visible_action()
            } else {
                0
            };
            // #262: pathfinding stops in the clear approach cell, but a seated
            // villager is drawn one block forward on the bench.  Keep collision
            // and path state outside the solid prop while aligning the visible
            // rig with the 9/16-high seat. The seated contact shadow is omitted
            // because shaped props occupy a full voxel in the shadow volume. The
            // approach yaw points into the bench, so the visible rig turns back
            // toward the room with the backrest behind it.
            let visual_pos = if social == super::creature_update::SOCIAL_SIT {
                V3::new(
                    Self::wrap_pos_f(cr.pos.x + cr.yaw.sin()),
                    cr.pos.y + 0.35,
                    Self::wrap_pos_f(cr.pos.z + cr.yaw.cos()),
                )
            } else {
                cr.pos
            };
            let visual_yaw = if social == super::creature_update::SOCIAL_SIT {
                cr.yaw + std::f32::consts::PI
            } else {
                cr.yaw
            };
            let mut col = if cr.friendly {
                V3::new(1.0, 0.92, 0.55)
            } else {
                cr.color
            };
            if cr.hit_flash > 0.0 {
                let f = (cr.hit_flash / 0.22).min(1.0) * 0.85;
                col = V3::new(
                    col.x + (1.0 - col.x) * f,
                    col.y + (1.0 - col.y) * f,
                    col.z + (1.0 - col.z) * f,
                );
            }
            let kind = if cr.model >= 0 {
                cr.model as u32
            } else if cr.hostile {
                if cr.shape == 1 {
                    11
                } else {
                    5
                }
            } else if cr.is_boss {
                4
            } else {
                KANIMAL_KIND[(cr.shape & 7) as usize]
            };
            let sat = self.region_sat(Self::to_chunk(IVec3 {
                x: Self::ifloor(cr.pos.x),
                y: Self::ifloor(cr.pos.y),
                z: Self::ifloor(cr.pos.z),
            }));
            let animation_id = creature_animation_id(
                cr.model,
                &cr.given,
                cr.home_x,
                cr.home_z,
                cr.npc_id,
                cr.color,
                entity_index,
            );
            self.entities.push(bf_entity_draw {
                position: bf_vec3 {
                    x: cam_pos.x + Self::wrap_signed_f(visual_pos.x - cam_pos.x),
                    y: visual_pos.y,
                    z: cam_pos.z + Self::wrap_signed_f(visual_pos.z - cam_pos.z),
                },
                yaw: visual_yaw,
                color: bf_vec3 {
                    x: col.x,
                    y: col.y,
                    z: col.z,
                },
                scale: cr.scale,
                kind,
                sat,
                // Reserved ABI word now carries a renderer-only stable animation
                // identity. It removes gait/phase swaps when villagers cross the
                // old half-block history buckets (#270).
                _pad: animation_id,
            });
            self.entity_role_actions.push(if cr.model == 20 {
                let artisan = (2..=6).contains(&cr.npc_id);
                bf_entity_role_action {
                    role: cr.npc_id.max(0) as u32,
                    action: if cr.guarding {
                        11
                    } else if social != 0 {
                        social
                    } else if artisan {
                        cr.routine.state.action()
                    } else {
                        0
                    },
                    progress: if cr.guarding {
                        cr.guard_progress
                    } else if social != 0 {
                        cr.social.progress()
                    } else if artisan {
                        cr.routine.progress()
                    } else {
                        0.0
                    },
                    // bit 0 is the engine-authored locomotion state. The renderer
                    // selects/blends a walk clip from this instead of deriving limb
                    // poses from noisy render-frame position deltas (#270).
                    _pad: u32::from(cr.ai.speed > 0.05),
                }
            } else {
                // The additive sidecar is index-aligned for every creature, so
                // authored species clips can consume the same stable locomotion
                // state as villagers without estimating velocity from render
                // positions. Role/action remain zero for non-villagers.
                let at_goal = cr.name == "smudgeling"
                    && cr.assault_goal.y != NO_FLOOR
                    && {
                        let dx = Self::wrap_signed_f(
                            cr.assault_goal.x as f32 + 0.5 - cr.pos.x,
                        );
                        let dz = Self::wrap_signed_f(
                            cr.assault_goal.z as f32 + 0.5 - cr.pos.z,
                        );
                        dx * dx + dz * dz < 2.2 * 2.2
                    };
                bf_entity_role_action {
                    action: if cr.name == "smudgeling" && cr.carrying_light {
                        12
                    } else if at_goal {
                        13
                    } else {
                        0
                    },
                    progress: if cr.name == "smudgeling" && cr.carrying_light {
                        1.0
                    } else {
                        0.0
                    },
                    _pad: u32::from(cr.ai.speed > 0.05),
                    ..bf_entity_role_action::default()
                }
            });
            self.entity_appearances.push(bf_player_appearance::default());
        }
        for fb in &self.falling {
            let sat = self.region_sat(Self::to_chunk(IVec3 {
                x: Self::ifloor(fb.pos.x),
                y: Self::ifloor(fb.pos.y),
                z: Self::ifloor(fb.pos.z),
            }));
            self.entities.push(bf_entity_draw {
                position: bf_vec3 {
                    x: cam_pos.x + Self::wrap_signed_f(fb.pos.x - cam_pos.x),
                    y: fb.pos.y,
                    z: cam_pos.z + Self::wrap_signed_f(fb.pos.z - cam_pos.z),
                },
                yaw: fb.spin,
                color: bf_vec3 {
                    x: fb.color.x,
                    y: fb.color.y,
                    z: fb.color.z,
                },
                scale: 1.0,
                kind: 6,
                sat,
                _pad: 0,
            });
            self.entity_role_actions.push(bf_entity_role_action::default());
            self.entity_appearances.push(bf_player_appearance::default());
        }
        // #170 debris fragments: kind 22 cube chips. yaw carries the tumble
        // phase and color the block colour (same convention as kind 6); scale
        // is the seeded fragment size, so the renderer needs no extra fields.
        for d in &self.debris {
            let sat = self.region_sat(Self::to_chunk(IVec3 {
                x: Self::ifloor(d.pos.x),
                y: Self::ifloor(d.pos.y),
                z: Self::ifloor(d.pos.z),
            }));
            self.entities.push(bf_entity_draw {
                position: bf_vec3 {
                    x: cam_pos.x + Self::wrap_signed_f(d.pos.x - cam_pos.x),
                    y: d.pos.y,
                    z: cam_pos.z + Self::wrap_signed_f(d.pos.z - cam_pos.z),
                },
                yaw: d.spin,
                color: bf_vec3 {
                    x: d.color.x,
                    y: d.color.y,
                    z: d.color.z,
                },
                scale: d.scale,
                kind: 22,
                sat,
                _pad: 0,
            });
            self.entity_role_actions.push(bf_entity_role_action::default());
            self.entity_appearances.push(bf_player_appearance::default());
        }
        // #258 nearby-only caravan. The engine owns route travel/state; kind 27
        // reuses the app's finished merchant-cart model without joining creature AI.
        if let Some(caravan) = self.caravan_draw(cam_pos) {
            self.entities.push(caravan);
            self.entity_role_actions
                .push(bf_entity_role_action::default());
            self.entity_appearances.push(bf_player_appearance::default());
        }
        for (index, (a, appearance)) in self
            .remote_avatars
            .iter()
            .zip(&self.remote_avatar_appearances)
            .enumerate()
        {
            // #179: co-op peers render at their nearest image too.
            let mut a = *a;
            a.position.x = cam_pos.x + Self::wrap_signed_f(a.position.x - cam_pos.x);
            a.position.z = cam_pos.z + Self::wrap_signed_f(a.position.z - cam_pos.z);
            self.entities.push(a);
            self.entity_role_actions.push(
                self.remote_avatar_actions
                    .get(index)
                    .copied()
                    .unwrap_or_default(),
            );
            self.entity_appearances.push(*appearance);
        }
        debug_assert_eq!(self.entities.len(), self.entity_role_actions.len());
        debug_assert_eq!(self.entities.len(), self.entity_appearances.len());
        out.entities = self.entities.as_ptr();
        out.entity_count = self.entities.len() as u32;

        self.fill_hud(&mut out.hud);
    }

    /// #254 v28: borrowed, index-aligned metadata for the latest render frame.
    pub fn entity_role_actions(&self) -> &[bf_entity_role_action] {
        &self.entity_role_actions
    }

    /// #264 v29: borrowed, index-aligned player appearance metadata.
    pub fn entity_appearances(&self) -> &[bf_player_appearance] {
        &self.entity_appearances
    }

    // strncpy(dst, src, dst.len()-1): copy bytes, always NUL-terminate, truncate.
    pub(super) fn cstr_copy(dst: &mut [u8], src: &str) {
        for b in dst.iter_mut() {
            *b = 0;
        }
        let cap = dst.len().saturating_sub(1);
        let bytes = src.as_bytes();
        let n = bytes.len().min(cap);
        dst[..n].copy_from_slice(&bytes[..n]);
    }

    pub(super) fn fill_hud(&self, h: &mut bf_hud_state) {
        h.mode = self.mode;
        h.selected_slot = self.selected;
        h.inventory_open = if self.inv_open { 1 } else { 0 };
        h.health = self.health;
        h.hunger = self.hunger;
        // zero arrays
        for s in h.hotbar.iter_mut() {
            *s = bf_hud_slot {
                item: 0,
                count: 0,
                durability: 0,
                _pad: 0,
            };
        }
        for s in h.inventory.iter_mut() {
            *s = bf_hud_slot {
                item: 0,
                count: 0,
                durability: 0,
                _pad: 0,
            };
        }
        for s in h.craftable.iter_mut() {
            *s = bf_hud_slot {
                item: 0,
                count: 0,
                durability: 0,
                _pad: 0,
            };
        }
        h.craftable_count = 0;
        if let Some(inv) = self.inv.as_ref() {
            for i in 0..BF_HOTBAR_SLOTS {
                let s = inv.get(i);
                h.hotbar[i] = bf_hud_slot {
                    item: s.item,
                    count: s.count,
                    durability: s.durability,
                    _pad: 0,
                };
            }
            for i in 0..BF_INVENTORY_SLOTS {
                let s = inv.get(i);
                h.inventory[i] = bf_hud_slot {
                    item: s.item,
                    count: s.count,
                    durability: s.durability,
                    _pad: 0,
                };
            }
            let cr = self.craftable_recipes();
            let ncr = cr.len().min(24);
            h.craftable_count = ncr as u8;
            if let Some(content) = self.content {
                for i in 0..ncr {
                    let r = content.recipe(cr[i]);
                    h.craftable[i] = bf_hud_slot {
                        item: r.result_item,
                        count: r.result_count,
                        durability: 0xFFFF,
                        _pad: 0,
                    };
                }
            }
        }
        // Active quest.
        let mut handled = false;
        if let Some(x) = self.extra {
            if !self.all_quests_done
                && self.active_quest < x.quests().len()
                && self.obj_progress.len() == x.quests()[self.active_quest].objectives.len()
            {
                let q = &x.quests()[self.active_quest];
                h.active_quest_id = q.id;
                Self::cstr_copy(&mut h.quest_title, &q.title);
                let mut done = 0u32;
                let mut total = 0u32;
                let mut objtext = "";
                for (i, o) in q.objectives.iter().enumerate() {
                    total += o.count;
                    done += self.obj_progress[i].min(o.count);
                    if self.obj_progress[i] < o.count && objtext.is_empty() {
                        objtext = &o.text;
                    }
                }
                Self::cstr_copy(
                    &mut h.quest_objective,
                    if !objtext.is_empty() { objtext } else { "..." },
                );
                h.quest_progress = if total != 0 {
                    done as f32 / total as f32
                } else {
                    0.0
                };
                handled = true;
            }
        }
        if !handled {
            h.active_quest_id = 0;
            Self::cstr_copy(
                &mut h.quest_title,
                if self.all_quests_done {
                    "The color is back!"
                } else {
                    "Bring back the color"
                },
            );
            Self::cstr_copy(
                &mut h.quest_objective,
                if self.all_quests_done {
                    "You restored the world!"
                } else {
                    "Place a glow block in the grey Dim"
                },
            );
            h.quest_progress = if self.all_quests_done { 1.0 } else { 0.0 };
        }
        h.has_target = if self.has_target { 1 } else { 0 };
        h.target_block = bf_ivec3 {
            x: self.target.x,
            y: self.target.y,
            z: self.target.z,
        };
        h.mine_progress = self.mine_progress;
        h.oxygen = self.oxygen;
        h.achievements_done = self.ach_done_count as u8;
        h.achievements_total = K_ACHIEVEMENT_COUNT as u8;
        h.weather = self.weather as u8;
        Self::cstr_copy(&mut h.biome_name, self.biome_label());
        h.in_dim = if self.region_sat(Self::to_chunk(IVec3 {
            x: Self::ifloor(self.pos.x),
            y: Self::ifloor(self.pos.y),
            z: Self::ifloor(self.pos.z),
        })) < 0.99
        {
            1
        } else {
            0
        };
        for b in h.achievement_toast.iter_mut() {
            *b = 0;
        }
        if self.ach_toast_timer > 0.0 {
            Self::cstr_copy(&mut h.achievement_toast, &self.ach_toast);
        }
        // Look-at name.
        for b in h.look_name.iter_mut() {
            *b = 0;
        }
        let ci = self.creature_in_view();
        if ci >= 0 && !self.creatures[ci as usize].name.is_empty() {
            // #234: villagers are named by PROFESSION (what they do), not by the
            // creature kind the spawn pool picked, so the label always matches
            // the dialogue and trade sheet behind it. #240: with their personal
            // name in front ("Pip the Woodcutter") when one was assigned.
            let c = &self.creatures[ci as usize];
            let title = if c.model == 20 { Self::profession_title(c.npc_id) } else { "" };
            let nm = if title.is_empty() {
                c.name.clone()
            } else if c.given.is_empty() {
                title.to_string()
            } else {
                format!("{} the {}", c.given, title)
            };
            Self::cstr_copy(&mut h.look_name, &nm);
        } else if self.has_target {
            let bn = self.block_name(self.block_at(self.target));
            if !bn.is_empty() {
                Self::cstr_copy(&mut h.look_name, &bn);
            }
        }
    }

    // ---- test/debug seams ------------------------------------------------
}

#[cfg(test)]
mod animation_identity_tests {
    use super::creature_animation_id;
    use crate::world::V3;

    #[test]
    fn villager_animation_identity_ignores_render_order_and_position() {
        let green = V3::new(0.2, 0.7, 0.3);
        let a = creature_animation_id(20, "Pip", 120, -44, 4, green, 0);
        let reordered = creature_animation_id(20, "Pip", 120, -44, 4, green, 31);
        let neighbour = creature_animation_id(20, "Juno", 121, -44, 4, green, 0);
        let same_name_role_home = creature_animation_id(
            20, "Pip", 120, -44, 4, V3::new(0.3, 0.6, 0.4), 1,
        );
        assert_eq!(a, reordered, "villager gait must not follow its frame index");
        assert_ne!(a, neighbour, "nearby villagers need distinct gait history");
        assert_ne!(a, same_name_role_home, "repeated names must not share gait history");
    }
}
