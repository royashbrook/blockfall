//! Flood-fill sky + block light for one chunk, seeded from neighbours so light bleeds
//! across boundaries. Faithful port of engine/include/blockcore/lighting.hpp.
//!
//! Sky light falls straight down at 15 through air until an opaque block (hard shadow),
//! then spreads horizontally at -1 per step. Block light BFS-spreads from emitters.
//! Glass and thin props/furniture (including trunks, doors, and beds) pass light;
//! leaves stay opaque.
//!
//! Where C++ uses raw pointers to read neighbours while writing the target chunk, this
//! port gathers every read (target blocks, old light, neighbour boundary light, column
//! openness) into owned locals first, then mutates the target. The borrow checker forces
//! that split, which also makes the read/write phases obvious.

use crate::store::ChunkStore;
use crate::types::{BlockId, ChunkCoord, CHUNK_DIM, CHUNK_VOL};

const N: usize = CHUNK_DIM;

fn idx(x: usize, y: usize, z: usize) -> usize {
    x + N * (y + N * z)
}

pub fn light_plant(b: BlockId) -> bool {
    (b >= 36 && b <= 47) || b == 21 || b == 22 || b == 49 || b == 33 || b == 50
}
pub fn light_glass(b: BlockId) -> bool {
    b == 25 || b == 26
}
// #118 snow overlay: snow_layer (12) and trodden_snow (54) are a thin blanket, not a
// solid cube. They must not block sky light, so the snow cell itself receives the open
// sky light the mesher reads onto the blanket faces (an opaque snow cell would store
// sky=0 and the white slab would render near-black).
pub fn light_snow_overlay(b: BlockId) -> bool {
    b == 12 || b == 54
}
pub fn light_opaque(b: BlockId) -> bool {
    b != 0 && b != 9 && b != 52 && !light_glass(b) && !light_plant(b) && !light_snow_overlay(b)
}
pub fn light_emit(b: BlockId) -> u8 {
    match b {
        7 => 14,  // glow_block
        32 => 14, // torch
        34 => 15, // beacon_block
        35 => 15, // crystal_lamp
        40 => 8,  // color_crystal
        _ => 0,
    }
}

fn on_boundary(x: usize, y: usize, z: usize) -> bool {
    x == 0 || y == 0 || z == 0 || x == N - 1 || y == N - 1 || z == N - 1
}

// Is the world column above (x,z) of chunk cc clear of opaque blocks (open to sky)?
fn column_open(store: &ChunkStore, cc: ChunkCoord, x: usize, z: usize) -> bool {
    // saturating add: chunk-y is bounded by streaming in practice, but guard against a
    // debug overflow panic if a corrupt/extreme cc.y is ever passed in.
    for cy in cc.y.saturating_add(1)..=cc.y.saturating_add(8) {
        match store.get(ChunkCoord {
            x: cc.x,
            y: cy,
            z: cc.z,
        }) {
            None => return true, // nothing resident above -> sky
            Some(above) => {
                for y in 0..N {
                    if light_opaque(above.get(x, y, z)) {
                        return false;
                    }
                }
            }
        }
    }
    true
}

// Increase-only BFS over a level grid, blocked by opaque blocks.
fn bfs(blocks: &[BlockId], lvl: &mut [u8], q: &mut Vec<usize>) {
    let steps: [(isize, isize, isize); 6] = [
        (1, 0, 0),
        (-1, 0, 0),
        (0, 1, 0),
        (0, -1, 0),
        (0, 0, 1),
        (0, 0, -1),
    ];
    let mut head = 0;
    while head < q.len() {
        let packed = q[head];
        head += 1;
        let x = packed % N;
        let y = (packed / N) % N;
        let z = packed / (N * N);
        let l = lvl[idx(x, y, z)];
        if l <= 1 {
            continue;
        }
        for (dx, dy, dz) in steps {
            let nx = x as isize + dx;
            let ny = y as isize + dy;
            let nz = z as isize + dz;
            if nx < 0
                || ny < 0
                || nz < 0
                || nx >= N as isize
                || ny >= N as isize
                || nz >= N as isize
            {
                continue;
            }
            let (nx, ny, nz) = (nx as usize, ny as usize, nz as usize);
            if light_opaque(blocks[idx(nx, ny, nz)]) {
                continue;
            }
            let ni = idx(nx, ny, nz);
            if lvl[ni] < l - 1 {
                lvl[ni] = l - 1;
                q.push(ni);
            }
        }
    }
}

/// Recompute light for resident chunk `cc`. Returns a 6-bit mask of which boundary faces
/// changed (bit order {+x,-x,+y,-y,+z,-z}) so the caller can re-dirty those neighbours.
pub fn light_chunk(store: &mut ChunkStore, cc: ChunkCoord) -> u8 {
    if store.get(cc).is_none() {
        return 0;
    }

    // ---- Phase 1: gather every read into owned locals. ----------------------
    let mut blocks = vec![0u16; CHUNK_VOL];
    let mut old_sky = vec![0u8; CHUNK_VOL];
    let mut old_blk = vec![0u8; CHUNK_VOL];
    {
        let ch = store.get(cc).unwrap();
        for z in 0..N {
            for y in 0..N {
                for x in 0..N {
                    let i = idx(x, y, z);
                    blocks[i] = ch.get(x, y, z);
                    old_sky[i] = ch.sky_light(x, y, z);
                    old_blk[i] = ch.block_light(x, y, z);
                }
            }
        }
    }
    let mut col_open = vec![false; N * N];
    for x in 0..N {
        for z in 0..N {
            col_open[x * N + z] = column_open(store, cc, x, z);
        }
    }
    // Neighbour boundary seeds: for each of our boundary cells, the highest (nv-1)
    // from the adjacent neighbour cell. Computed for sky and block light separately.
    let dirs: [(i32, i32, i32); 6] = [
        (1, 0, 0),
        (-1, 0, 0),
        (0, 1, 0),
        (0, -1, 0),
        (0, 0, 1),
        (0, 0, -1),
    ];
    let mut seed_sky = vec![0u8; CHUNK_VOL];
    let mut seed_blk = vec![0u8; CHUNK_VOL];
    for (dx, dy, dz) in dirs {
        let nb = match store.get(ChunkCoord {
            x: cc.x + dx,
            y: cc.y + dy,
            z: cc.z + dz,
        }) {
            Some(nb) => nb,
            None => continue,
        };
        for a in 0..N {
            for b in 0..N {
                // our boundary cell (x,y,z) + the neighbour's adjacent cell (nx,ny,nz)
                let (x, y, z, nx, ny, nz);
                if dx != 0 {
                    x = if dx > 0 { N - 1 } else { 0 };
                    nx = if dx > 0 { 0 } else { N - 1 };
                    y = a;
                    ny = a;
                    z = b;
                    nz = b;
                } else if dy != 0 {
                    y = if dy > 0 { N - 1 } else { 0 };
                    ny = if dy > 0 { 0 } else { N - 1 };
                    x = a;
                    nx = a;
                    z = b;
                    nz = b;
                } else {
                    z = if dz > 0 { N - 1 } else { 0 };
                    nz = if dz > 0 { 0 } else { N - 1 };
                    x = a;
                    nx = a;
                    y = b;
                    ny = b;
                }
                let i = idx(x, y, z);
                let svs = nb.sky_light(nx, ny, nz);
                if svs > 1 && svs - 1 > seed_sky[i] {
                    seed_sky[i] = svs - 1;
                }
                let svb = nb.block_light(nx, ny, nz);
                if svb > 1 && svb - 1 > seed_blk[i] {
                    seed_blk[i] = svb - 1;
                }
            }
        }
    }

    // ---- Phase 2: compute sky + block light on the gathered locals. ---------
    let mut sky = vec![0u8; CHUNK_VOL];
    let mut blk = vec![0u8; CHUNK_VOL];
    let mut q: Vec<usize> = Vec::with_capacity(512);

    // sky: direct vertical sunlight + hard shadow
    for x in 0..N {
        for z in 0..N {
            let mut s: u8 = if col_open[x * N + z] { 15 } else { 0 };
            for y in (0..N).rev() {
                let b = blocks[idx(x, y, z)];
                if light_opaque(b) {
                    s = 0;
                } else {
                    sky[idx(x, y, z)] = s;
                    if s > 1 {
                        q.push(idx(x, y, z));
                    }
                }
            }
        }
    }
    for i in 0..CHUNK_VOL {
        if seed_sky[i] > sky[i] {
            sky[i] = seed_sky[i];
            q.push(i);
        }
    }
    bfs(&blocks, &mut sky, &mut q);

    // block light: emitters + neighbour bleed
    q.clear();
    for i in 0..CHUNK_VOL {
        let e = light_emit(blocks[i]);
        if e > 0 {
            blk[i] = e;
            q.push(i);
        }
    }
    for i in 0..CHUNK_VOL {
        if seed_blk[i] > blk[i] {
            blk[i] = seed_blk[i];
            q.push(i);
        }
    }
    bfs(&blocks, &mut blk, &mut q);

    // ---- Phase 3: write back, detect boundary change. -----------------------
    let mut changed_faces: u8 = 0;
    let ch = store.get_mut(cc).unwrap();
    for x in 0..N {
        for y in 0..N {
            for z in 0..N {
                let i = idx(x, y, z);
                if on_boundary(x, y, z) && (old_sky[i] != sky[i] || old_blk[i] != blk[i]) {
                    if x == N - 1 {
                        changed_faces |= 1 << 0;
                    }
                    if x == 0 {
                        changed_faces |= 1 << 1;
                    }
                    if y == N - 1 {
                        changed_faces |= 1 << 2;
                    }
                    if y == 0 {
                        changed_faces |= 1 << 3;
                    }
                    if z == N - 1 {
                        changed_faces |= 1 << 4;
                    }
                    if z == 0 {
                        changed_faces |= 1 << 5;
                    }
                }
                ch.set_light(x, y, z, sky[i], blk[i]);
            }
        }
    }
    changed_faces
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chunk::PaletteChunk;

    #[test]
    fn open_column_is_sky_lit() {
        let mut store = ChunkStore::new();
        let cc = ChunkCoord { x: 0, y: 0, z: 0 };
        store.insert(PaletteChunk::new(cc, 0)); // all air, nothing above -> open
        light_chunk(&mut store, cc);
        let ch = store.get(cc).unwrap();
        assert_eq!(ch.sky_light(3, N - 1, 3), 15);
        assert_eq!(ch.sky_light(3, 0, 3), 15);
    }

    #[test]
    fn opaque_roof_casts_hard_shadow() {
        // A full opaque layer blocks sky for the whole space under it (no open column
        // beside it for light to flood in from), so it reads as a true hard shadow.
        let mut store = ChunkStore::new();
        let cc = ChunkCoord { x: 0, y: 0, z: 0 };
        let mut ch = PaletteChunk::new(cc, 0);
        for x in 0..N {
            for z in 0..N {
                ch.set(x, 10, z, 1); // opaque roof at y=10
            }
        }
        store.insert(ch);
        light_chunk(&mut store, cc);
        let ch = store.get(cc).unwrap();
        assert_eq!(ch.sky_light(5, 11, 5), 15); // above the roof: lit
        assert_eq!(ch.sky_light(5, 9, 5), 0); // under the roof: hard shadow
    }

    #[test]
    fn emitter_spreads_block_light() {
        let mut store = ChunkStore::new();
        let cc = ChunkCoord { x: 0, y: 0, z: 0 };
        let mut ch = PaletteChunk::new(cc, 0);
        ch.set(8, 8, 8, 35); // crystal_lamp, emits 15
        store.insert(ch);
        light_chunk(&mut store, cc);
        let ch = store.get(cc).unwrap();
        assert_eq!(ch.block_light(8, 8, 8), 15);
        assert_eq!(ch.block_light(8, 8, 9), 14); // one step out
        assert_eq!(ch.block_light(8, 8, 11), 12); // three steps out
    }

    #[test]
    fn bed_is_sky_light_pass_through() {
        let mut store = ChunkStore::new();
        let cc = ChunkCoord { x: 0, y: 0, z: 0 };
        let mut ch = PaletteChunk::new(cc, 0);
        ch.set(8, 8, 8, 52);
        store.insert(ch);

        light_chunk(&mut store, cc);
        let ch = store.get(cc).unwrap();
        assert_eq!(
            ch.sky_light(8, 8, 8),
            15,
            "bed mesh reads light from its cell"
        );
        assert_eq!(
            ch.sky_light(8, 7, 8),
            15,
            "low furniture must not cast a full-cube shadow"
        );
    }
}
