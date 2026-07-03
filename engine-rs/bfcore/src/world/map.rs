use super::*;

// #182 world map + warp totems (phase 4 of #173, the torus payoff).
//
// Three pieces of player progress live here, all persisted in map.dat:
//   - EXPLORED MASK: one bit per 64x64-block cell over the whole torus
//     (512 x 512 cells = 32 KiB). Cells near the player are marked as they
//     move; the map UI reveals only explored cells. O(1) per chunk crossing.
//   - WARP TOTEMS: placing the warp_totem block (id 55) registers a named
//     marker (auto-named "Totem 1", "Totem 2", ...); breaking it unregisters
//     (the item itself rides the normal debris refund path). Capped at 16.
//   - VISITED VILLAGES: coming within ~48 blocks of a settlement anchor
//     records it as a map marker. Capped at 32 (oldest kept; new ones beyond
//     the cap are simply not recorded, which a kid will never hit).
//
// Teleport: bf_map_teleport(marker_id) places the player on the destination
// surface (never inside solid, never over open water for a land marker),
// resets velocity, and recentres streaming so the destination streams in
// with the surface-first drop-in path. The magical charge-up is app-side;
// the engine call is instant.

/// The warp totem block id (content/blocks/functional.json id 55).
pub const WARP_TOTEM: BlockId = 55;

/// Explored-mask geometry: one bit per MAP_CELL x MAP_CELL block cell.
pub const MAP_CELL: i32 = 64;
pub const MAP_CELLS: i32 = worldgen::WORLD_PERIOD / MAP_CELL; // 512
pub const MAP_EXPLORED_BYTES: usize = (MAP_CELLS as usize * MAP_CELLS as usize) / 8; // 32768

/// Marker caps (fixed-size ABI arrays; no allocation across the boundary).
pub const MAP_MAX_TOTEMS: usize = 16;
pub const MAP_MAX_VILLAGES: usize = 32;

// Marker id scheme for bf_map_teleport: stable between a query and the
// teleport that follows it (both index the same live vectors).
pub(super) const MARKER_ID_HOME: u32 = 1;
pub(super) const MARKER_ID_VILLAGE_BASE: u32 = 100;
pub(super) const MARKER_ID_TOTEM_BASE: u32 = 200;

/// A placed warp totem: world position + its auto-assigned number.
#[derive(Clone, Copy)]
pub(super) struct TotemMark {
    pub(super) pos: IVec3,
    pub(super) num: u32,
}

/// One marker row handed to the FFI layer (which packs it into bf_map_marker).
pub struct MapMarkerInfo {
    pub pos: IVec3,
    pub kind: u32, // 0 = home, 1 = village, 2 = totem
    pub id: u32,
    pub name: String,
}

impl<'c> World<'c> {
    // ---- explored mask ----------------------------------------------------

    #[inline]
    fn explored_bit(cx: i32, cz: i32) -> (usize, u8) {
        let cx = cx.rem_euclid(MAP_CELLS) as usize;
        let cz = cz.rem_euclid(MAP_CELLS) as usize;
        let idx = cz * MAP_CELLS as usize + cx;
        (idx / 8, 1u8 << (idx % 8))
    }

    /// Mark the player's map cell and its 8 neighbours explored. O(1); called
    /// when the player crosses a chunk boundary (and on spawn/load/teleport).
    pub(super) fn mark_explored_around(&mut self, wx: i32, wz: i32) {
        let ccx = Self::wrap_block(wx) / MAP_CELL;
        let ccz = Self::wrap_block(wz) / MAP_CELL;
        for dz in -1..=1 {
            for dx in -1..=1 {
                let (byte, bit) = Self::explored_bit(ccx + dx, ccz + dz);
                self.explored[byte] |= bit;
            }
        }
    }

    pub fn debug_explored_at(&self, wx: i32, wz: i32) -> bool {
        let (byte, bit) =
            Self::explored_bit(Self::wrap_block(wx) / MAP_CELL, Self::wrap_block(wz) / MAP_CELL);
        (self.explored[byte] & bit) != 0
    }

    pub fn debug_explored_count(&self) -> usize {
        self.explored.iter().map(|b| b.count_ones() as usize).sum()
    }

    // ---- totem markers ----------------------------------------------------

    /// True when another totem may be placed (cap not reached).
    pub(super) fn totem_cap_free(&self) -> bool {
        self.totems.len() < MAP_MAX_TOTEMS
    }

    /// Register a marker for a freshly placed warp totem block.
    pub(super) fn note_totem_placed(&mut self, w: IVec3) {
        let w = Self::canon_block(w);
        if self.totems.iter().any(|t| t.pos == w) || !self.totem_cap_free() {
            return;
        }
        self.totem_next += 1;
        let num = self.totem_next;
        self.totems.push(TotemMark { pos: w, num });
        self.toast(&format!("Totem {} placed! Press M to see your map.", num));
    }

    /// Unregister the marker for a broken warp totem block. The item refund
    /// rides the normal debris path in break_block; nothing extra here.
    pub(super) fn note_totem_broken(&mut self, w: IVec3) {
        let w = Self::canon_block(w);
        self.totems.retain(|t| t.pos != w);
    }

    pub fn debug_totem_count(&self) -> usize {
        self.totems.len()
    }

    /// Test helper: place a warp totem block + marker directly (the live path
    /// goes through perform_place, which needs a raycast target).
    pub fn debug_place_totem(&mut self, x: i32, y: i32, z: i32) -> bool {
        if !self.totem_cap_free() {
            return false;
        }
        self.set_block_internal(IVec3 { x, y, z }, WARP_TOTEM);
        self.note_totem_placed(IVec3 { x, y, z });
        true
    }

    /// Test helper: does the player's collision box currently overlap solid?
    pub fn debug_player_collides(&self) -> bool {
        self.box_collides(self.pos)
    }

    // ---- village visits ---------------------------------------------------

    /// Record the nearest settlement anchor as visited when the player is
    /// within ~48 blocks of it. Called on chunk crossings (cheap, throttled by
    /// movement itself); a pure worldgen query, no chunk residency needed.
    pub(super) fn note_village_visits(&mut self, wx: i32, wz: i32) {
        let (styp, ax, az, _ay) = worldgen::worldgen_structure_near(wx, wz, self.seed);
        if styp != 8 && !worldgen::worldgen_is_city(styp) {
            return;
        }
        let dx = Self::wrap_signed_block(ax - wx) as i64;
        let dz = Self::wrap_signed_block(az - wz) as i64;
        if dx * dx + dz * dz > 48 * 48 {
            return;
        }
        let key = (Self::wrap_block(ax), Self::wrap_block(az));
        if self.visited_villages.contains(&key) || self.visited_villages.len() >= MAP_MAX_VILLAGES {
            return;
        }
        self.visited_villages.push(key);
        self.toast("Village discovered! It is on your map now (M).");
    }

    pub fn debug_visited_village_count(&self) -> usize {
        self.visited_villages.len()
    }

    pub fn debug_visit_village(&mut self, wx: i32, wz: i32) {
        self.note_village_visits(wx, wz);
    }

    // ---- map view (FFI feed) ------------------------------------------------

    pub fn map_explored_bits(&self) -> &[u8] {
        &self.explored
    }

    /// All markers in a stable order: home, then visited villages, then totems.
    pub fn map_markers(&self) -> Vec<MapMarkerInfo> {
        let mut out: Vec<MapMarkerInfo> = Vec::with_capacity(1 + self.visited_villages.len() + self.totems.len());
        out.push(MapMarkerInfo {
            pos: IVec3 {
                x: Self::ifloor(self.spawn.x),
                y: Self::ifloor(self.spawn.y),
                z: Self::ifloor(self.spawn.z),
            },
            kind: 0,
            id: MARKER_ID_HOME,
            name: "Home".to_string(),
        });
        for (i, &(ax, az)) in self.visited_villages.iter().enumerate() {
            out.push(MapMarkerInfo {
                pos: IVec3 { x: ax, y: 0, z: az },
                kind: 1,
                id: MARKER_ID_VILLAGE_BASE + i as u32,
                name: format!("Village {}", i + 1),
            });
        }
        for (i, t) in self.totems.iter().enumerate() {
            out.push(MapMarkerInfo {
                pos: t.pos,
                kind: 2,
                id: MARKER_ID_TOTEM_BASE + i as u32,
                name: format!("Totem {}", t.num),
            });
        }
        out
    }

    // ---- teleport -----------------------------------------------------------

    /// Teleport to a marker by its id (see the MARKER_ID_* scheme). Returns
    /// false for an unknown id. Lands on the surface, never inside solid.
    pub fn map_teleport(&mut self, marker_id: u32) -> bool {
        let (tx, tz, is_totem) = if marker_id == MARKER_ID_HOME {
            (Self::ifloor(self.spawn.x), Self::ifloor(self.spawn.z), false)
        } else if marker_id >= MARKER_ID_TOTEM_BASE {
            let i = (marker_id - MARKER_ID_TOTEM_BASE) as usize;
            match self.totems.get(i) {
                Some(t) => (t.pos.x, t.pos.z, true),
                None => return false,
            }
        } else if marker_id >= MARKER_ID_VILLAGE_BASE {
            let i = (marker_id - MARKER_ID_VILLAGE_BASE) as usize;
            match self.visited_villages.get(i) {
                Some(&(ax, az)) => (ax, az, false),
                None => return false,
            }
        } else {
            return false;
        };
        self.teleport_to_column(tx, tz, is_totem);
        true
    }

    /// Place the player safely on the surface of (wx, wz): find a dry column
    /// nearby (a totem stands on land already, so it skips the search), stand
    /// on the generated surface, resolve any solid overlap upward, and
    /// recentre streaming so the destination drops in surface-first.
    fn teleport_to_column(&mut self, wx: i32, wz: i32, on_land_already: bool) {
        const SEA_LEVEL: i32 = 6;
        let (mut tx, mut tz) = (Self::wrap_block(wx), Self::wrap_block(wz));
        if !on_land_already && worldgen::worldgen_surface_height(tx, tz, self.seed) < SEA_LEVEL + 1 {
            // Cheap pure-worldgen spiral for the nearest dry column (never lands
            // the player in open water). Bounded: 4-block steps out to 64 blocks.
            'search: for r in 1i32..=16 {
                for dz in -r..=r {
                    for dx in -r..=r {
                        if dx.abs().max(dz.abs()) != r {
                            continue;
                        }
                        let cx = Self::wrap_block(tx + dx * 4);
                        let cz = Self::wrap_block(tz + dz * 4);
                        if worldgen::worldgen_surface_height(cx, cz, self.seed) >= SEA_LEVEL + 1 {
                            tx = cx;
                            tz = cz;
                            break 'search;
                        }
                    }
                }
            }
        }
        // surface_top generates the destination column if it is not resident,
        // so this works for far-away, never-visited targets.
        let top = self.surface_top(tx, tz);
        let y = if top != NO_FLOOR { top as f32 + 3.2 } else { 40.0 };
        self.pos = V3::new(tx as f32 + 0.5, y, tz as f32 + 0.5);
        self.vy = 0.0;
        self.on_ground = false;
        // Never arrive inside solid: same upward resolve ensure_clear_spawn uses.
        self.ensure_clear_spawn_at_pos();
        // Recentre streaming NOW so the destination streams immediately with the
        // drop-in-sooner path (small active radius that re-expands).
        self.last_center = Self::to_chunk(self.player_voxel());
        self.first_stream = true;
        self.stream_active_r = 2.min(self.stream_r);
        self.recompute_stream_set();
        self.mark_explored_around(tx, tz);
        // Arrival sparkle + sound (same fx code the respawn poof uses).
        let pv = self.player_voxel();
        self.fx(6, pv, 0);
    }

    /// ensure_clear_spawn without touching self.spawn: make the CURRENT
    /// position collision-free by generating the local column and nudging up.
    fn ensure_clear_spawn_at_pos(&mut self) {
        if self.gen.is_none() {
            return;
        }
        let pc = Self::to_chunk(self.player_voxel());
        for cy in (CY_MIN..=CY_MAX).rev() {
            let cc = ChunkCoord { x: pc.x, y: cy, z: pc.z };
            if self.store.is_resident(cc) {
                continue;
            }
            if let Some(ch) = self.gen_chunk(cc) {
                if !(ch.is_uniform() && ch.get(0, 0, 0) == AIR) {
                    self.store.insert(ch);
                    self.mark_dirty(cc);
                }
            }
        }
        let mut i = 0;
        while i < 64 && self.box_collides(self.pos) {
            self.pos.y += 1.0;
            i += 1;
        }
    }

    // ---- persistence (map.dat) ----------------------------------------------

    pub(super) fn save_map_dat(&self, dir: &str) -> bool {
        use std::io::Write;
        let mut buf: Vec<u8> = Vec::with_capacity(MAP_EXPLORED_BYTES + 256);
        buf.extend_from_slice(b"BFMD");
        buf.extend_from_slice(&(MAP_EXPLORED_BYTES as u32).to_le_bytes());
        buf.extend_from_slice(&self.explored);
        buf.extend_from_slice(&self.totem_next.to_le_bytes());
        buf.extend_from_slice(&(self.totems.len() as u32).to_le_bytes());
        for t in &self.totems {
            buf.extend_from_slice(&t.pos.x.to_le_bytes());
            buf.extend_from_slice(&t.pos.y.to_le_bytes());
            buf.extend_from_slice(&t.pos.z.to_le_bytes());
            buf.extend_from_slice(&t.num.to_le_bytes());
        }
        buf.extend_from_slice(&(self.visited_villages.len() as u32).to_le_bytes());
        for &(ax, az) in &self.visited_villages {
            buf.extend_from_slice(&ax.to_le_bytes());
            buf.extend_from_slice(&az.to_le_bytes());
        }
        let path = format!("{}/map.dat", dir);
        let mut f = match std::fs::File::create(&path) {
            Ok(f) => f,
            Err(_) => return false,
        };
        f.write_all(&buf).is_ok()
    }

    pub(super) fn load_map_dat(&mut self, dir: &str) {
        self.explored = vec![0u8; MAP_EXPLORED_BYTES];
        self.totems.clear();
        self.visited_villages.clear();
        self.totem_next = 0;
        let bytes = match std::fs::read(format!("{}/map.dat", dir)) {
            Ok(b) => b,
            Err(_) => return,
        };
        let mut r = super::persistence::ByteReader::new(&bytes);
        if r.take(4) != Some(b"BFMD") {
            return;
        }
        let n = r.u32().unwrap_or(0) as usize;
        if let Some(bits) = r.take(n) {
            let take = n.min(MAP_EXPLORED_BYTES);
            self.explored[..take].copy_from_slice(&bits[..take]);
        }
        self.totem_next = r.u32().unwrap_or(0);
        let tc = r.u32().unwrap_or(0) as usize;
        for _ in 0..tc.min(MAP_MAX_TOTEMS) {
            let x = r.i32();
            let y = r.i32();
            let z = r.i32();
            let num = r.u32();
            if let (Some(x), Some(y), Some(z), Some(num)) = (x, y, z, num) {
                self.totems.push(TotemMark {
                    pos: IVec3 { x: Self::wrap_block(x), y, z: Self::wrap_block(z) },
                    num,
                });
            }
        }
        let vc = r.u32().unwrap_or(0) as usize;
        for _ in 0..vc.min(MAP_MAX_VILLAGES) {
            let ax = r.i32();
            let az = r.i32();
            if let (Some(ax), Some(az)) = (ax, az) {
                self.visited_villages.push((Self::wrap_block(ax), Self::wrap_block(az)));
            }
        }
    }
}
