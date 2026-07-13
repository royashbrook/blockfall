use super::*;

// Worldgen's largest tree has 16 trunk logs plus three 3-log branches (25).
// Keep the walk bounded, with a little room for joined branch geometry.
const MAX_NATURAL_TREE_LOGS: usize = 32;

#[derive(Clone)]
pub(super) struct FallingBlock {
    pub(super) pos: V3,
    pub(super) vel: V3,
    pub(super) spin: f32,
    pub(super) spin_rate: f32,
    pub(super) block: BlockId,
    pub(super) color: V3,
    pub(super) as_item: bool,
    pub(super) life: f32,
}

impl<'c> World<'c> {
    fn falling_color(b: BlockId) -> V3 {
        match b {
            6 => V3::new(0.86, 0.79, 0.55),
            11 => V3::new(0.55, 0.53, 0.50),
            21 => V3::new(0.50, 0.36, 0.20),
            22 => V3::new(0.78, 0.72, 0.56),
            5 => V3::new(0.27, 0.55, 0.24),
            27 => V3::new(0.40, 0.62, 0.32),
            // Pine (#62): log 49 fell as a grey default box, needles 48 likewise.
            49 => V3::new(0.40, 0.25, 0.15),
            48 => V3::new(0.18, 0.42, 0.24),
            _ => V3::new(0.6, 0.6, 0.6),
        }
    }

    fn spawn_falling(&mut self, w: IVec3, b: BlockId, as_item: bool, vel: V3) {
        if self.falling.len() > 200 {
            return;
        }
        let spin = self.rand01() * 6.2831853;
        let spin_rate = (self.rand01() - 0.5) * 8.0;
        self.falling.push(FallingBlock {
            pos: V3::new(w.x as f32 + 0.5, w.y as f32, w.z as f32 + 0.5),
            vel,
            spin,
            spin_rate,
            block: b,
            color: Self::falling_color(b),
            as_item,
            life: 6.0,
        });
    }

    pub(super) fn flow_water(&mut self, t: IVec3) {
        if self.block_at(t) != AIR {
            return;
        }
        let fed = self.block_at(IVec3 {
            x: t.x,
            y: t.y + 1,
            z: t.z,
        }) == WATER
            || self.block_at(IVec3 {
                x: t.x + 1,
                y: t.y,
                z: t.z,
            }) == WATER
            || self.block_at(IVec3 {
                x: t.x - 1,
                y: t.y,
                z: t.z,
            }) == WATER
            || self.block_at(IVec3 {
                x: t.x,
                y: t.y,
                z: t.z + 1,
            }) == WATER
            || self.block_at(IVec3 {
                x: t.x,
                y: t.y,
                z: t.z - 1,
            }) == WATER;
        if !fed {
            return;
        }
        self.set_block_internal(t, WATER);
        let mut w = t;
        for _ in 0..64 {
            let below = IVec3 {
                x: w.x,
                y: w.y - 1,
                z: w.z,
            };
            if self.block_at(below) != AIR {
                break;
            }
            self.set_block_internal(w, AIR);
            self.set_block_internal(below, WATER);
            w = below;
        }
    }

    pub(super) fn apply_gravity_above(&mut self, w: IVec3) {
        let mut up = IVec3 {
            x: w.x,
            y: w.y + 1,
            z: w.z,
        };
        while Self::is_gravity_block(self.block_at(up)) {
            let b = self.block_at(up);
            self.set_block_internal(up, AIR);
            self.spawn_falling(up, b, false, V3::new(0.0, -1.0, 0.0));
            up.y += 1;
        }
    }

    pub(super) fn has_matching_tree_canopy(&self, base: IVec3) -> bool {
        let (log, leaf) = match self.block_at(base) {
            21 => (21, 5),
            22 => (22, 27),
            49 => (49, 48),
            _ => return false,
        };
        let mut stack = vec![base];
        let mut seen = HashSet::from([(base.x, base.y, base.z)]);
        let mut checked = 0;
        while let Some(w) = stack.pop() {
            if checked >= MAX_NATURAL_TREE_LOGS {
                break;
            }
            checked += 1;
            for dx in -3..=3 {
                for dy in -1..=4 {
                    for dz in -3..=3 {
                        if self.block_at(IVec3 {
                            x: w.x + dx,
                            y: w.y + dy,
                            z: w.z + dz,
                        }) == leaf
                        {
                            return true;
                        }
                    }
                }
            }
            for dx in -1..=1 {
                for dy in 0..=1 {
                    for dz in -1..=1 {
                        let n = IVec3 {
                            x: w.x + dx,
                            y: w.y + dy,
                            z: w.z + dz,
                        };
                        if self.block_at(n) == log && seen.insert((n.x, n.y, n.z)) {
                            stack.push(n);
                        }
                    }
                }
            }
        }
        false
    }

    pub(super) fn fell_tree(&mut self, base: IVec3) {
        let mut logs: Vec<IVec3> = Vec::new();
        let mut stack: Vec<IVec3> = vec![base];
        let mut seen: HashSet<(i32, i32, i32)> = HashSet::new();
        seen.insert((base.x, base.y, base.z));
        while let Some(w) = stack.pop() {
            if logs.len() >= MAX_NATURAL_TREE_LOGS {
                break;
            }
            logs.push(w);
            for dx in -1..=1 {
                for dy in 0..=1 {
                    for dz in -1..=1 {
                        let n = IVec3 {
                            x: w.x + dx,
                            y: w.y + dy,
                            z: w.z + dz,
                        };
                        if !Self::is_log(self.block_at(n)) {
                            continue;
                        }
                        if seen.insert((n.x, n.y, n.z)) {
                            stack.push(n);
                        }
                    }
                }
            }
        }
        for w in &logs {
            let b = self.block_at(*w);
            self.set_block_internal(*w, AIR);
            let h = (w.y - base.y) as f32;
            let vx = (self.rand01() - 0.5) * 2.0;
            let vz = (self.rand01() - 0.5) * 2.0;
            self.spawn_falling(*w, b, true, V3::new(vx, 1.5 + h * 0.4, vz));
        }
        let mut leaf_bursts = 0;
        let mut leaves_removed = 0;
        let logs_copy = logs.clone();
        for lw in &logs_copy {
            if leaves_removed >= 160 {
                break;
            }
            for dx in -3..=3 {
                for dy in -1..=4 {
                    for dz in -3..=3 {
                        let n = IVec3 {
                            x: lw.x + dx,
                            y: lw.y + dy,
                            z: lw.z + dz,
                        };
                        let lf = self.block_at(n);
                        if !Self::is_leaf(lf) {
                            continue;
                        }
                        self.set_block_internal(n, AIR);
                        leaves_removed += 1;
                        if leaf_bursts < 6 {
                            self.fx(0, n, ((lf as i32) << 4) | 6);
                            leaf_bursts += 1;
                        }
                    }
                }
            }
        }
        self.fx(2, base, 0);
    }

    pub(super) fn update_falling(&mut self, dt: f32) {
        let n = self.falling.len();
        for i in 0..n {
            let (px, py, pz) = {
                let fb = &mut self.falling[i];
                fb.vel.y -= 26.0 * dt;
                fb.pos = Self::wrap_v3_xz(fb.pos + fb.vel * dt);
                fb.spin += fb.spin_rate * dt;
                fb.life -= dt;
                (fb.pos.x, fb.pos.y, fb.pos.z)
            };
            let fy = self.floor_below(Self::ifloor(px), py.floor() as i32 + 1, Self::ifloor(pz));
            if fy != NO_FLOOR && py <= fy as f32 {
                let land = IVec3 {
                    x: Self::ifloor(px),
                    y: fy,
                    z: Self::ifloor(pz),
                };
                let (as_item, block) = {
                    let fb = &self.falling[i];
                    (fb.as_item, fb.block)
                };
                if as_item {
                    let id = self.item_that_places(block);
                    if id != 0 {
                        if let Some(inv) = self.inv.as_mut() {
                            inv.add(ItemStack {
                                item: id,
                                count: 1,
                                durability: 0xFFFF,
                            });
                        }
                    }
                    self.fx(7, land, 0);
                } else {
                    let mut settle = land;
                    let mut guard = 0;
                    while self.block_at(settle) != AIR && guard < 64 {
                        settle.y += 1;
                        guard += 1;
                    }
                    if self.block_at(settle) == AIR {
                        self.set_block_internal(settle, block);
                        self.fx(
                            0,
                            settle,
                            ((block as i32) << 4) | Self::sound_class_for(block),
                        );
                    }
                }
                self.falling[i].life = 0.0;
            }
        }
        self.falling.retain(|f| f.life > 0.0);
    }
}
