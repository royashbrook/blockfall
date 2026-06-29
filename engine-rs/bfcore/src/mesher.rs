// ============================================================================
// Blockfall - Greedy voxel mesher, Rust port (Track D)
//
// Faithful port of:
//   engine/src/mesher.cpp
//   engine/include/blockcore/mesher.hpp
//   engine/include/blockcore/vertex.hpp
//
// Algorithm: standard Mikola Lysenko / 0fps greedy meshing.
//
// For each of the 6 axis-aligned face directions (+/-X, +/-Y, +/-Z):
//   For each of the 16 slices perpendicular to that axis (coord d in 0..15):
//     Build a 16x16 mask[u][v]:
//       - non-zero (= block id) when the voxel at (d,u,v) is SOLID and the
//         neighbour in the face direction (d+/-1, u, v) is AIR.
//       - 0 (no face) otherwise.
//     Greedy-merge mask into maximal same-id rectangles (also matching light
//     and per-corner AO - any difference splits the merge).
//
// Vertex positions are within-chunk corners (0..16 inclusive).
// Winding: CCW as seen from outside (consistent with Metal front-face = CCW).
//
// INLINED TYPES (to swap for bfcore's on integration):
//   - BlockId (= u16), ChunkCoord: bfcore already defines these in
//     bfcore::types. Drop the local copies and `use bfcore::types::{...}`.
//   - Chunk + ChunkStore traits: minimal accessors modelling IChunk /
//     IChunkStore. bfcore::chunk::PaletteChunk and bfcore::store::ChunkStore
//     provide the same get / sky_light / block_light / is_uniform / get(coord)
//     surface; implement these traits for them (or swap the trait bounds for
//     the concrete types) and delete the test TestChunk / TestStore below.
//   - Block face / solidity rules (is_opaque, is_glass, is_door, is_prop,
//     is_occluder, ...): ported here verbatim from mesher.cpp's hard-coded id
//     checks. The C++ does not consult a block-def table for these, so neither
//     does this port. If a real BlockDef table lands, route these through it.
// ============================================================================

// ---- inlined value types (swap for bfcore::types) --------------------------

pub type BlockId = u16;

pub const CHUNK_DIM: usize = 16; // mirrors kChunkDim
pub const CHUNK_VOL: usize = CHUNK_DIM * CHUNK_DIM * CHUNK_DIM; // kChunkVol = 4096

pub use crate::types::ChunkCoord;

// ---- result type (mirrors MeshResult in blockcore_interfaces.hpp) -----------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct MeshResult {
    pub vertex_bytes: u32,
    pub index_bytes: u32,
    pub index_count: u32,
    pub empty: bool,
}

// ---- chunk access traits (model IChunk / IChunkStore) -----------------------
// The C++ mesher only ever calls get / sky_light / block_light on a chunk and
// is_uniform on the meshed chunk, plus store.get(coord) -> IChunk*. These two
// traits capture exactly that surface. Coordinates are always 0..15 (the mesher
// resolves cross-chunk lookups before calling get), so they take usize.

pub trait Chunk {
    fn get(&self, x: usize, y: usize, z: usize) -> BlockId;
    fn sky_light(&self, x: usize, y: usize, z: usize) -> u8;
    fn block_light(&self, x: usize, y: usize, z: usize) -> u8;
    fn is_uniform(&self) -> bool;
}

pub trait ChunkStore {
    type Chunk: Chunk;
    // IChunkStore::get returns a nullable pointer; None == not resident == air.
    fn get(&self, c: ChunkCoord) -> Option<&Self::Chunk>;
}

// ============================================================================
// BFVertex packing - frozen layout from contract/formats.md section 4 (16 bytes).
//
//   offset 0  u32 pos_packed   : x[0:6] y[6:12] z[12:18]  (0..16 incl. seam)
//                                fx[18:22] fy[22:26] fz[26:30]  (sub-cell /16)
//   offset 4  u32 normal_uv    : normal[0:3] ao[3:5] u[5:13] v[13:21]
//   offset 8  u16 material_id
//   offset 10 u8  sky_light    (0..15)
//   offset 11 u8  block_light  (0..15)
//   offset 12 u32 _reserved
// ============================================================================

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(C)]
pub struct BFVertex {
    pub pos_packed: u32,
    pub normal_uv: u32,
    pub material_id: u16,
    pub sky_light: u8,
    pub block_light: u8,
    pub reserved: u32,
}

// Compile-time check that the packed footprint is 16 bytes, like the C++
// static_assert(sizeof(BFVertex) == 16). #[repr(C)] keeps the field order and,
// with these field widths, the natural layout is exactly 16 bytes with no pad.
const _: () = assert!(core::mem::size_of::<BFVertex>() == 16);

impl BFVertex {
    // Serialize one vertex to its 16 packed little-endian bytes. This is what the
    // C++ std::memcpy of a BFVertex produces on a little-endian target (Apple
    // silicon / x86), so the byte stream matches the renderer's vertex buffer.
    #[inline]
    fn write_le(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.pos_packed.to_le_bytes());
        out.extend_from_slice(&self.normal_uv.to_le_bytes());
        out.extend_from_slice(&self.material_id.to_le_bytes());
        out.push(self.sky_light);
        out.push(self.block_light);
        out.extend_from_slice(&self.reserved.to_le_bytes());
    }
}

// Face/normal codes (also the index the renderer uses for flat shading).
pub const BF_NX_POS: u32 = 0;
pub const BF_NX_NEG: u32 = 1;
pub const BF_NY_POS: u32 = 2;
pub const BF_NY_NEG: u32 = 3;
pub const BF_NZ_POS: u32 = 4;
pub const BF_NZ_NEG: u32 = 5;

#[inline]
fn bf_pack_pos(x: u32, y: u32, z: u32, fx: u32, fy: u32, fz: u32) -> u32 {
    (x & 0x3F)
        | ((y & 0x3F) << 6)
        | ((z & 0x3F) << 12)
        | ((fx & 0xF) << 18)
        | ((fy & 0xF) << 22)
        | ((fz & 0xF) << 26)
}

#[inline]
fn bf_pack_normal_uv(normal: u32, ao: u32, u: u32, v: u32) -> u32 {
    (normal & 0x7) | ((ao & 0x3) << 3) | ((u & 0xFF) << 5) | ((v & 0xFF) << 13)
}

#[inline]
fn bf_make_vertex(
    x: u32,
    y: u32,
    z: u32,
    normal: u32,
    ao: u32,
    u: u32,
    v: u32,
    material: u16,
    sky: u8,
    block: u8,
) -> BFVertex {
    BFVertex {
        pos_packed: bf_pack_pos(x, y, z, 0, 0, 0),
        normal_uv: bf_pack_normal_uv(normal, ao, u, v),
        material_id: material,
        sky_light: sky,
        block_light: block,
        reserved: 0,
    }
}

// ============================================================================
// Mesher
// ============================================================================

const KCHUNK_DIM: i32 = CHUNK_DIM as i32;

// Worst-case byte budgets (mesher.hpp).
pub const K_MAX_QUADS: u32 = (CHUNK_VOL as u32) * 6; // 24576
pub const K_MAX_VERTEX_BYTES: u32 = K_MAX_QUADS * 4 * 16; // 1 572 864
pub const K_MAX_INDEX_BYTES: u32 = K_MAX_QUADS * 6 * 4; // 589 824

pub fn max_vertex_bytes() -> u32 {
    K_MAX_VERTEX_BYTES
}
pub fn max_index_bytes() -> u32 {
    K_MAX_INDEX_BYTES
}

// ---- axis description -------------------------------------------------------
// For each face direction we describe:
//   axis  : which world axis is the sweep axis (0=X,1=Y,2=Z)
//   sign  : +1 or -1 (which way the face points)
//   u_axis: first tangent axis
//   v_axis: second tangent axis
//   normal: BFNormal code
//   reverse: reverse u-winding so the quad is CCW from OUTSIDE
struct FaceDir {
    axis: i32,
    sign: i32,
    u_axis: i32,
    v_axis: i32,
    normal: u32,
    reverse: bool,
}

// `reverse` is true when cross(u_axis, v_axis) points OPPOSITE the outward
// normal (axis*sign). Correct reverse set: {-X, +Y, -Z}.
static K_FACE_DIRS: [FaceDir; 6] = [
    FaceDir { axis: 0, sign: 1, u_axis: 1, v_axis: 2, normal: BF_NX_POS, reverse: false }, // +X
    FaceDir { axis: 0, sign: -1, u_axis: 1, v_axis: 2, normal: BF_NX_NEG, reverse: true }, // -X
    FaceDir { axis: 1, sign: 1, u_axis: 0, v_axis: 2, normal: BF_NY_POS, reverse: true }, // +Y
    FaceDir { axis: 1, sign: -1, u_axis: 0, v_axis: 2, normal: BF_NY_NEG, reverse: false }, // -Y
    FaceDir { axis: 2, sign: 1, u_axis: 0, v_axis: 1, normal: BF_NZ_POS, reverse: false }, // +Z
    FaceDir { axis: 2, sign: -1, u_axis: 0, v_axis: 1, normal: BF_NZ_NEG, reverse: true }, // -Z
];

// ---- coordinate helpers -----------------------------------------------------
// Convert (axis, u_axis, v_axis, d, u, v) -> (x,y,z)
#[inline]
fn axes_to_xyz(fd: &FaceDir, d: i32, u: i32, v: i32) -> (i32, i32, i32) {
    let mut arr = [0i32; 3];
    arr[fd.axis as usize] = d;
    arr[fd.u_axis as usize] = u;
    arr[fd.v_axis as usize] = v;
    (arr[0], arr[1], arr[2])
}

// Block at (x,y,z) in the given chunk; coords are 0..15.
#[inline]
fn chunk_get<C: Chunk>(chunk: Option<&C>, x: i32, y: i32, z: i32) -> BlockId {
    match chunk {
        None => 0,
        Some(c) => c.get(x as usize, y as usize, z as usize),
    }
}

// Neighbour block at local (x,y,z) with offset along fd.axis.
// May cross into an adjacent chunk (fetched from store).
fn neighbour_block<S: ChunkStore>(
    current_chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    fd: &FaceDir,
    x: i32,
    y: i32,
    z: i32,
) -> BlockId {
    let (mut nx, mut ny, mut nz) = (x, y, z);
    if fd.axis == 0 {
        nx += fd.sign;
    } else if fd.axis == 1 {
        ny += fd.sign;
    } else {
        nz += fd.sign;
    }

    // Still inside the current chunk.
    if nx >= 0 && nx < KCHUNK_DIM && ny >= 0 && ny < KCHUNK_DIM && nz >= 0 && nz < KCHUNK_DIM {
        return chunk_get(current_chunk, nx, ny, nz);
    }

    // Crossed into adjacent chunk.
    let mut nc = cc;
    if nx < 0 {
        nc.x -= 1;
        nx += KCHUNK_DIM;
    } else if nx >= KCHUNK_DIM {
        nc.x += 1;
        nx -= KCHUNK_DIM;
    }
    if ny < 0 {
        nc.y -= 1;
        ny += KCHUNK_DIM;
    } else if ny >= KCHUNK_DIM {
        nc.y += 1;
        ny -= KCHUNK_DIM;
    }
    if nz < 0 {
        nc.z -= 1;
        nz += KCHUNK_DIM;
    } else if nz >= KCHUNK_DIM {
        nc.z += 1;
        nz -= KCHUNK_DIM;
    }

    match store.get(nc) {
        None => 0, // not resident -> treat as air
        Some(nb) => nb.get(nx as usize, ny as usize, nz as usize),
    }
}

// Like neighbour_block, but preserves the difference between loaded-air and an
// unknown neighbour chunk. Transparent water should not draw a full chunk-edge
// side wall while the adjacent chunk is still streaming in.
fn neighbour_block_known<S: ChunkStore>(
    current_chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    fd: &FaceDir,
    x: i32,
    y: i32,
    z: i32,
) -> Option<BlockId> {
    let (mut nx, mut ny, mut nz) = (x, y, z);
    if fd.axis == 0 {
        nx += fd.sign;
    } else if fd.axis == 1 {
        ny += fd.sign;
    } else {
        nz += fd.sign;
    }
    sample_block_known(current_chunk, cc, store, nx, ny, nz)
}

// Light (sky, block) of the cell adjacent to a face. That cell is the visible
// side, so its light is what the face shows.
//
// Leaf neighbours are special: the mesher does not cube-mesh leaves, so a solid
// face that borders a leaf is visible, yet the lighting pass treats leaves as
// opaque and stores no light in the leaf cell (sky=0, block=0). Reading that cell
// directly paints the face near-black where it meets foliage. To avoid that we
// step PAST a run of leaf cells along the face normal and read the light of the
// first non-leaf cell beyond them (the lit air the foliage sits in front of).
fn neighbour_light<S: ChunkStore>(
    current_chunk: &S::Chunk,
    cc: ChunkCoord,
    store: &S,
    fd: &FaceDir,
    x: i32,
    y: i32,
    z: i32,
) -> (u8, u8) {
    let cur = Some(current_chunk);

    // Walk outward along the face normal: one step to the immediate neighbour,
    // then keep stepping while we are inside a leaf cell. Bounded so a solid wall
    // of foliage cannot loop unreasonably; in practice a couple of steps suffice.
    let mut step = 1;
    const MAX_LEAF_SKIP: i32 = 4;
    loop {
        let (mut nx, mut ny, mut nz) = (x, y, z);
        if fd.axis == 0 {
            nx += fd.sign * step;
        } else if fd.axis == 1 {
            ny += fd.sign * step;
        } else {
            nz += fd.sign * step;
        }

        let (sky, blk) = light_at::<S>(cur, cc, store, nx, ny, nz);

        // Stop once we have looked far enough, or the cell is not a leaf. The
        // first probe (step 1) is the normal path for every non-foliage face.
        if step > MAX_LEAF_SKIP {
            return (sky, blk);
        }
        let nb = sample_block::<S>(cur, cc, store, nx, ny, nz);
        if !is_leaf(nb) {
            return (sky, blk);
        }
        step += 1;
    }
}

// Read (sky, block) light at an arbitrary cell offset, resolving cross-chunk
// lookups the same way sample_block does. Cells outside the loaded area read as
// open sky (15, 0), matching the prior neighbour_light fallback.
fn light_at<S: ChunkStore>(
    current_chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    x: i32,
    y: i32,
    z: i32,
) -> (u8, u8) {
    if x >= 0 && x < KCHUNK_DIM && y >= 0 && y < KCHUNK_DIM && z >= 0 && z < KCHUNK_DIM {
        return match current_chunk {
            None => (15, 0),
            Some(ch) => (
                ch.sky_light(x as usize, y as usize, z as usize),
                ch.block_light(x as usize, y as usize, z as usize),
            ),
        };
    }
    let mut nc = cc;
    let (mut nx, mut ny, mut nz) = (x, y, z);
    if nx < 0 {
        nc.x -= 1;
        nx += KCHUNK_DIM;
    } else if nx >= KCHUNK_DIM {
        nc.x += 1;
        nx -= KCHUNK_DIM;
    }
    if ny < 0 {
        nc.y -= 1;
        ny += KCHUNK_DIM;
    } else if ny >= KCHUNK_DIM {
        nc.y += 1;
        ny -= KCHUNK_DIM;
    }
    if nz < 0 {
        nc.z -= 1;
        nz += KCHUNK_DIM;
    } else if nz >= KCHUNK_DIM {
        nc.z += 1;
        nz -= KCHUNK_DIM;
    }
    match store.get(nc) {
        None => (15, 0), // outside loaded area -> open sky
        Some(nb) => (
            nb.sky_light(nx as usize, ny as usize, nz as usize),
            nb.block_light(nx as usize, ny as usize, nz as usize),
        ),
    }
}

// ---- prop / opacity / occluder helpers --------------------------------------
// All ported verbatim from mesher.cpp. These are hard-coded block-id checks in
// the C++; no block-def table is consulted, so none is here either.

// Sub-voxel props (#51/#52): flower_red(36)..color_crystal(40) and the rest of
// 36..47. Renderer draws these as instanced models; mesher emits no geometry.
#[inline]
fn is_subvoxel_prop(id: BlockId) -> bool {
    id >= 36 && id <= 47
}
// #62 trees: leaves (oak 5, birch 27, pine 48) and logs (oak 21, birch 22, pine 49)
// are drawn as instances, so the mesher emits no cube geometry for them.
#[inline]
fn is_tree_prop(id: BlockId) -> bool {
    id == 5 || id == 27 || id == 48 || id == 21 || id == 22 || id == 49
}
// Leaf blocks (oak 5, birch 27, pine 48). The mesher draws no cube geometry for
// these (they are instanced foliage), so a solid block's face that borders a leaf
// IS emitted. But the lighting pass (lighting.rs light_plant) treats leaves as
// opaque so the canopy casts shade, which means a leaf cell itself stores no light
// (sky=0, block=0). A visible solid face reads its light from the neighbour cell;
// if that neighbour is a leaf, it would read 0/0 and render near-black. So when we
// light such a face we must look PAST the leaf to the lit air beyond it. Mirrors
// the "plants on the ground" case, where ground props are non-opaque and lit.
#[inline]
fn is_leaf(id: BlockId) -> bool {
    id == 5 || id == 27 || id == 48
}
// Blocks the renderer draws as instanced models, so the mesher emits no geometry.
#[inline]
fn is_instanced_prop(id: BlockId) -> bool {
    is_subvoxel_prop(id) || is_tree_prop(id)
}
// No cross-billboard plants remain in the mesher (all are sub-voxel props now).
#[inline]
fn is_cross_plant(_id: BlockId) -> bool {
    false
}

// Torch block id (32): a thin sub-cell prop, not a full cube. Non-opaque, not an
// AO occluder, emits its own custom geometry instead of cube faces.
#[inline]
fn is_torch(id: BlockId) -> bool {
    id == 32
}

// A billboard/prop block emits custom geometry in the prop pass instead of
// greedy cube faces: cross-plants (none now), torches (32), instanced props.
#[inline]
fn is_prop(id: BlockId) -> bool {
    is_cross_plant(id) || is_torch(id) || is_instanced_prop(id)
}

// #68 glass (glass_pane 25, colored_glass 26): see-through translucent. Non-opaque
// so it does not occlude; glass-to-glass faces are culled into one sheet.
#[inline]
fn is_glass(id: BlockId) -> bool {
    id == 25 || id == 26
}

// #69 doors: a thin slab, not a full cube. Closed (33) fills the opening; open (50)
// swings to the side. Drawn by emit_door, never cube-meshed.
const DOOR_CLOSED: BlockId = 33;
const DOOR_OPEN: BlockId = 50;
#[inline]
fn is_door(id: BlockId) -> bool {
    id == DOOR_CLOSED || id == DOOR_OPEN
}

// #118 snow overlay: snow is a thin BLANKET on top of the surface block, not a solid
// cube. snow_layer (12) is fresh snow; trodden_snow (54) is a stepped/compressed print
// (#117). Both are emitted as a thin slab sitting at the bottom of their cell by
// emit_snow_layer, so the block underneath shows through on the sides. They are not
// opaque and do not occlude, so the surface below keeps its faces and AO is unchanged.
const SNOW_LAYER: BlockId = 12;
const TRODDEN_SNOW: BlockId = 54;
#[inline]
fn is_snow_overlay(id: BlockId) -> bool {
    id == SNOW_LAYER || id == TRODDEN_SNOW
}

// A cell is OPAQUE if it is non-air, not water (9), not glass, not a door, not a snow
// overlay, not a prop.
#[inline]
fn is_opaque(id: BlockId) -> bool {
    id != 0 && id != 9 && !is_glass(id) && !is_door(id) && !is_snow_overlay(id) && !is_prop(id)
}

// Waterlogged props (reed 43, lily pad 46): the cell still renders as water.
#[inline]
fn is_waterlogged(id: BlockId) -> bool {
    id == 43 || id == 46
}

// Is this block id an AO-occluder? Air(0), water(9), glass, doors, snow overlay, props
// do not occlude.
#[inline]
fn is_occluder(id: BlockId) -> bool {
    id != 0 && id != 9 && !is_glass(id) && !is_door(id) && !is_snow_overlay(id) && !is_prop(id)
}

// Sample a block at an arbitrary world offset from (x,y,z) in chunk cc.
// Used for AO neighbour lookups; may cross chunk boundaries.
fn sample_block<S: ChunkStore>(
    current_chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    x: i32,
    y: i32,
    z: i32,
) -> BlockId {
    if x >= 0 && x < KCHUNK_DIM && y >= 0 && y < KCHUNK_DIM && z >= 0 && z < KCHUNK_DIM {
        return chunk_get(current_chunk, x, y, z);
    }
    let mut nc = cc;
    let (mut nx, mut ny, mut nz) = (x, y, z);
    if nx < 0 {
        nc.x -= 1;
        nx += KCHUNK_DIM;
    } else if nx >= KCHUNK_DIM {
        nc.x += 1;
        nx -= KCHUNK_DIM;
    }
    if ny < 0 {
        nc.y -= 1;
        ny += KCHUNK_DIM;
    } else if ny >= KCHUNK_DIM {
        nc.y += 1;
        ny -= KCHUNK_DIM;
    }
    if nz < 0 {
        nc.z -= 1;
        nz += KCHUNK_DIM;
    } else if nz >= KCHUNK_DIM {
        nc.z += 1;
        nz -= KCHUNK_DIM;
    }
    match store.get(nc) {
        None => 0,
        Some(nb) => nb.get(nx as usize, ny as usize, nz as usize),
    }
}

// Sample a block while preserving missing cross-chunk neighbours as None. Inside
// the meshed chunk this is always Some; across a chunk edge it is None until the
// neighbour is resident in the snapshot.
fn sample_block_known<S: ChunkStore>(
    current_chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    x: i32,
    y: i32,
    z: i32,
) -> Option<BlockId> {
    if x >= 0 && x < KCHUNK_DIM && y >= 0 && y < KCHUNK_DIM && z >= 0 && z < KCHUNK_DIM {
        return current_chunk.map(|ch| ch.get(x as usize, y as usize, z as usize));
    }
    let mut nc = cc;
    let (mut nx, mut ny, mut nz) = (x, y, z);
    if nx < 0 {
        nc.x -= 1;
        nx += KCHUNK_DIM;
    } else if nx >= KCHUNK_DIM {
        nc.x += 1;
        nx -= KCHUNK_DIM;
    }
    if ny < 0 {
        nc.y -= 1;
        ny += KCHUNK_DIM;
    } else if ny >= KCHUNK_DIM {
        nc.y += 1;
        ny -= KCHUNK_DIM;
    }
    if nz < 0 {
        nc.z -= 1;
        nz += KCHUNK_DIM;
    } else if nz >= KCHUNK_DIM {
        nc.z += 1;
        nz -= KCHUNK_DIM;
    }
    store.get(nc).map(|nb| nb.get(nx as usize, ny as usize, nz as usize))
}

fn door_mesh_rotated<S: ChunkStore>(
    current_chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    x: i32,
    y: i32,
    z: i32,
) -> bool {
    let mut low_y = y;
    let mut guard = 0;
    while guard < KCHUNK_DIM * 4 && is_door(sample_block(current_chunk, cc, store, x, low_y - 1, z)) {
        low_y -= 1;
        guard += 1;
    }
    let mut high_y = y;
    guard = 0;
    while guard < KCHUNK_DIM * 4 && is_door(sample_block(current_chunk, cc, store, x, high_y + 1, z)) {
        high_y += 1;
        guard += 1;
    }

    let mut wall_x_score = 0;
    let mut wall_z_score = 0;
    for yy in low_y..=high_y {
        if is_opaque(sample_block(current_chunk, cc, store, x - 1, yy, z)) {
            wall_x_score += 1;
        }
        if is_opaque(sample_block(current_chunk, cc, store, x + 1, yy, z)) {
            wall_x_score += 1;
        }
        if is_opaque(sample_block(current_chunk, cc, store, x, yy, z - 1)) {
            wall_z_score += 1;
        }
        if is_opaque(sample_block(current_chunk, cc, store, x, yy, z + 1)) {
            wall_z_score += 1;
        }
    }
    wall_z_score > wall_x_score
}

fn door_mesh_run_state<S: ChunkStore>(
    current_chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    x: i32,
    y: i32,
    z: i32,
) -> BlockId {
    let mut low_y = y;
    let mut guard = 0;
    while guard < KCHUNK_DIM * 4 && is_door(sample_block(current_chunk, cc, store, x, low_y - 1, z)) {
        low_y -= 1;
        guard += 1;
    }
    let bottom = sample_block(current_chunk, cc, store, x, low_y, z);
    if is_door(bottom) {
        bottom
    } else {
        sample_block(current_chunk, cc, store, x, y, z)
    }
}

// ---- AO ---------------------------------------------------------------------

// Compute the AO value (0..3) for one quad corner. Lysenko formula:
//   if s1 && s2 -> ao=0; else ao = 3 - s1 - s2 - corner.
#[allow(clippy::too_many_arguments)]
fn compute_ao<S: ChunkStore>(
    chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    bx: i32,
    by: i32,
    bz: i32,
    norm_axis: i32,
    face_sign: i32,
    u_axis: i32,
    v_axis: i32,
    du: i32,
    dv: i32,
) -> u32 {
    // Step one voxel out along the face normal (into the air).
    let mut step = [0i32; 3];
    step[norm_axis as usize] = face_sign;

    // Tangent steps for this corner.
    let mut su = [0i32; 3];
    let mut sv = [0i32; 3];
    su[u_axis as usize] = du;
    sv[v_axis as usize] = dv;

    let s1x = bx + step[0] + su[0];
    let s1y = by + step[1] + su[1];
    let s1z = bz + step[2] + su[2];

    let s2x = bx + step[0] + sv[0];
    let s2y = by + step[1] + sv[1];
    let s2z = bz + step[2] + sv[2];

    let scx = bx + step[0] + su[0] + sv[0];
    let scy = by + step[1] + su[1] + sv[1];
    let scz = bz + step[2] + su[2] + sv[2];

    let s1 = is_occluder(sample_block(chunk, cc, store, s1x, s1y, s1z));
    let s2 = is_occluder(sample_block(chunk, cc, store, s2x, s2y, s2z));
    let c = is_occluder(sample_block(chunk, cc, store, scx, scy, scz));

    if s1 && s2 {
        return 0;
    }
    3 - (s1 as u32) - (s2 as u32) - (c as u32)
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
struct AOCorners {
    a0: u32,
    a1: u32,
    a2: u32,
    a3: u32,
}

// Compute all 4 corner AO values for a face on block (bx,by,bz).
//   c0: -u,-v   c1: +u,-v   c2: +u,+v   c3: -u,+v
fn compute_face_ao<S: ChunkStore>(
    chunk: Option<&S::Chunk>,
    cc: ChunkCoord,
    store: &S,
    fd: &FaceDir,
    bx: i32,
    by: i32,
    bz: i32,
) -> AOCorners {
    AOCorners {
        a0: compute_ao(chunk, cc, store, bx, by, bz, fd.axis, fd.sign, fd.u_axis, fd.v_axis, -1, -1),
        a1: compute_ao(chunk, cc, store, bx, by, bz, fd.axis, fd.sign, fd.u_axis, fd.v_axis, 1, -1),
        a2: compute_ao(chunk, cc, store, bx, by, bz, fd.axis, fd.sign, fd.u_axis, fd.v_axis, 1, 1),
        a3: compute_ao(chunk, cc, store, bx, by, bz, fd.axis, fd.sign, fd.u_axis, fd.v_axis, -1, 1),
    }
}

// Pack 4 AO corner values (each 0..3, 2 bits) into 8 bits for the merge key.
#[inline]
fn pack_ao(ao: &AOCorners) -> u8 {
    ((ao.a0 & 0x3) | ((ao.a1 & 0x3) << 2) | ((ao.a2 & 0x3) << 4) | ((ao.a3 & 0x3) << 6)) as u8
}

// ---- mask cell --------------------------------------------------------------
// Two cells can only be greedy-merged if ALL fields match.
#[derive(Clone, Copy, PartialEq, Eq)]
struct MaskCell {
    id: BlockId,
    sky: u8,
    blk: u8,
    ao_packed: u8,
}

// Accumulating output buffers. The C++ writes into caller spans with a byte
// budget and bails when full; we mirror that with byte caps and a `full` flag,
// pushing packed little-endian bytes (same stream the renderer reads).
struct MeshBuffers {
    vtx: Vec<u8>,
    idx: Vec<u8>,
    vtx_cap: usize,
    idx_cap: usize,
    vtx_count: u32, // vertices, not bytes
    full: bool,
}

impl MeshBuffers {
    fn new(vtx_cap: usize, idx_cap: usize) -> Self {
        Self {
            vtx: Vec::new(),
            idx: Vec::new(),
            vtx_cap,
            idx_cap,
            vtx_count: 0,
            full: false,
        }
    }
    #[inline]
    fn write_vertex(&mut self, v: &BFVertex) {
        v.write_le(&mut self.vtx);
        self.vtx_count += 1;
    }
    #[inline]
    fn write_index(&mut self, i: u32) {
        self.idx.extend_from_slice(&i.to_le_bytes());
    }
    // Emit one quad (4 verts, 6 indices) with corner order chosen so triangles
    // (0,1,2),(0,2,3) are CCW from outside. Used by the prop emitters (torch,
    // door, cross-plant) which all build axis-aligned boxes this way.
    #[inline]
    fn quad(&mut self, v0: &BFVertex, v1: &BFVertex, v2: &BFVertex, v3: &BFVertex) {
        let b = self.vtx_count;
        self.write_vertex(v0);
        self.write_vertex(v1);
        self.write_vertex(v2);
        self.write_vertex(v3);
        for &i in &[b, b + 1, b + 2, b, b + 2, b + 3] {
            self.write_index(i);
        }
    }
}

const VERTEX_SIZE: usize = 16;
const INDEX_SIZE: usize = 4;

// ---- quad emission ----------------------------------------------------------
// Emit one quad at position (d,u,v) in axis space with width w along u_axis and
// height h along v_axis. Returns false if buffers lack space (caller stops).
#[allow(clippy::too_many_arguments)]
fn emit_quad(
    fd: &FaceDir,
    d: i32,
    u: i32,
    v: i32,
    w: i32,
    h: i32,
    id: BlockId,
    sky: u8,
    block: u8,
    ao0: u32,
    ao1: u32,
    ao2: u32,
    ao3: u32,
    buf: &mut MeshBuffers,
    base_vtx: u32,
) -> bool {
    if buf.vtx_cap - buf.vtx.len() < 4 * VERTEX_SIZE {
        return false;
    }
    if buf.idx_cap - buf.idx.len() < 6 * INDEX_SIZE {
        return false;
    }

    // If sign is +1 the face is at d+1 (outward surface); if -1 the face is at d.
    let face_d = if fd.sign > 0 { d + 1 } else { d };

    // Four corners in (u,v) space:
    //   c0=(u,v) c1=(u+w,v) c2=(u+w,v+h) c3=(u,v+h)
    let to_xyz = |cd: i32, cu: i32, cv: i32| -> (u32, u32, u32) {
        let (ix, iy, iz) = axes_to_xyz(fd, cd, cu, cv);
        (ix as u32, iy as u32, iz as u32)
    };

    let (x0, y0, z0) = to_xyz(face_d, u, v);
    let (x1, y1, z1) = to_xyz(face_d, u + w, v);
    let (x2, y2, z2) = to_xyz(face_d, u + w, v + h);
    let (x3, y3, z3) = to_xyz(face_d, u, v + h);

    let uw = w as u32;
    let vh = h as u32;
    let mat = id;

    let verts = [
        bf_make_vertex(x0, y0, z0, fd.normal, ao0, 0, 0, mat, sky, block),
        bf_make_vertex(x1, y1, z1, fd.normal, ao1, uw, 0, mat, sky, block),
        bf_make_vertex(x2, y2, z2, fd.normal, ao2, uw, vh, mat, sky, block),
        bf_make_vertex(x3, y3, z3, fd.normal, ao3, 0, vh, mat, sky, block),
    ];
    for vtx in &verts {
        buf.write_vertex(vtx);
    }

    // AO flip-quad: if the AO gradient is asymmetric (a0+a2 != a1+a3), flip the
    // diagonal so interpolation follows the dominant gradient direction.
    let flip_diag = (ao0 + ao2) != (ao1 + ao3);

    let b = base_vtx;
    let fwd_normal = [b, b + 1, b + 2, b, b + 2, b + 3];
    let fwd_flip = [b, b + 1, b + 3, b + 1, b + 2, b + 3];
    let rev_normal = [b, b + 2, b + 1, b, b + 3, b + 2];
    let rev_flip = [b, b + 3, b + 1, b + 1, b + 3, b + 2];

    let idx_pattern: &[u32; 6] = if fd.reverse {
        if flip_diag {
            &rev_flip
        } else {
            &rev_normal
        }
    } else if flip_diag {
        &fwd_flip
    } else {
        &fwd_normal
    };
    for &i in idx_pattern {
        buf.write_index(i);
    }

    true
}

// ---- torch emission ---------------------------------------------------------
// Closed torch-shaped prop for a torch cell (id 32): post + head, 11 quads =
// 44 verts + 66 indices. Sub-cell positions use bf_pack_pos fractions.
fn emit_torch(bx: i32, by: i32, bz: i32, sky: u8, blk: u8, buf: &mut MeshBuffers) -> bool {
    if buf.vtx_cap - buf.vtx.len() < 44 * VERTEX_SIZE {
        return false;
    }
    if buf.idx_cap - buf.idx.len() < 66 * INDEX_SIZE {
        return false;
    }

    const AO: u32 = 3;
    let mat: u16 = 32;

    let x = bx as u32;
    let y = by as u32;
    let z = bz as u32;

    let vert = |fx: u32, fy: u32, fz: u32, normal: u32, u: u32, v: u32| -> BFVertex {
        BFVertex {
            pos_packed: bf_pack_pos(x, y, z, fx, fy, fz),
            normal_uv: bf_pack_normal_uv(normal, AO, u, v),
            material_id: mat,
            sky_light: sky,
            block_light: blk,
            reserved: 0,
        }
    };

    // 4 side faces between Y fracs [yb..yt] with the X/Z square spanning [lo..hi].
    let sides = |buf: &mut MeshBuffers, lo: u32, hi: u32, yb: u32, yt: u32| {
        // +X face.
        buf.quad(
            &vert(hi, yb, lo, BF_NX_POS, 0, 0),
            &vert(hi, yt, lo, BF_NX_POS, 0, 1),
            &vert(hi, yt, hi, BF_NX_POS, 1, 1),
            &vert(hi, yb, hi, BF_NX_POS, 1, 0),
        );
        // -X face.
        buf.quad(
            &vert(lo, yb, hi, BF_NX_NEG, 0, 0),
            &vert(lo, yt, hi, BF_NX_NEG, 0, 1),
            &vert(lo, yt, lo, BF_NX_NEG, 1, 1),
            &vert(lo, yb, lo, BF_NX_NEG, 1, 0),
        );
        // +Z face.
        buf.quad(
            &vert(hi, yb, hi, BF_NZ_POS, 0, 0),
            &vert(hi, yt, hi, BF_NZ_POS, 0, 1),
            &vert(lo, yt, hi, BF_NZ_POS, 1, 1),
            &vert(lo, yb, hi, BF_NZ_POS, 1, 0),
        );
        // -Z face.
        buf.quad(
            &vert(lo, yb, lo, BF_NZ_NEG, 0, 0),
            &vert(lo, yt, lo, BF_NZ_NEG, 0, 1),
            &vert(hi, yt, lo, BF_NZ_NEG, 1, 1),
            &vert(hi, yb, lo, BF_NZ_NEG, 1, 0),
        );
    };

    let top_cap = |buf: &mut MeshBuffers, lo: u32, hi: u32, yy: u32| {
        buf.quad(
            &vert(hi, yy, lo, BF_NY_POS, 0, 0),
            &vert(lo, yy, lo, BF_NY_POS, 1, 0),
            &vert(lo, yy, hi, BF_NY_POS, 1, 1),
            &vert(hi, yy, hi, BF_NY_POS, 0, 1),
        );
    };
    let bottom_cap = |buf: &mut MeshBuffers, lo: u32, hi: u32, yy: u32| {
        buf.quad(
            &vert(lo, yy, lo, BF_NY_NEG, 0, 0),
            &vert(hi, yy, lo, BF_NY_NEG, 1, 0),
            &vert(hi, yy, hi, BF_NY_NEG, 1, 1),
            &vert(lo, yy, hi, BF_NY_NEG, 0, 1),
        );
    };

    // POST: narrow shaft, X/Z frac 6..10, Y frac 0..7. Sides + bottom cap.
    const PLO: u32 = 6;
    const PHI: u32 = 10;
    const PBOT: u32 = 0;
    const PTOP: u32 = 7;
    sides(buf, PLO, PHI, PBOT, PTOP);
    bottom_cap(buf, PLO, PHI, PBOT);

    // HEAD: wider tuft, X/Z frac 5..11, Y frac 7..11. Sides + both caps.
    const HLO: u32 = 5;
    const HHI: u32 = 11;
    const HBOT: u32 = 7;
    const HTOP: u32 = 11;
    sides(buf, HLO, HHI, HBOT, HTOP);
    bottom_cap(buf, HLO, HHI, HBOT);
    top_cap(buf, HLO, HHI, HTOP);

    true
}

// ---- cross-plant billboard emission -----------------------------------------
// X-shaped billboard for a plant cell: 4 quads = 16 verts + 48 indices. Unused
// now (no cross-plants remain) but ported for parity with the C++ source.
#[allow(dead_code)]
fn emit_cross_plant(
    bx: i32,
    by: i32,
    bz: i32,
    id: BlockId,
    sky: u8,
    blk: u8,
    buf: &mut MeshBuffers,
) -> bool {
    if buf.vtx_cap - buf.vtx.len() < 16 * VERTEX_SIZE {
        return false;
    }
    if buf.idx_cap - buf.idx.len() < 48 * INDEX_SIZE {
        return false;
    }

    const AO: u32 = 3;
    const NORM: u32 = BF_NY_POS;
    let mat = id;

    let x0 = bx as u32;
    let x1 = (bx + 1) as u32;
    let y0 = by as u32;
    let y1 = (by + 1) as u32;
    let z0 = bz as u32;
    let z1 = (bz + 1) as u32;

    let emit_both_faces = |buf: &mut MeshBuffers,
                           px0: u32, py0: u32, pz0: u32,
                           px1: u32, py1: u32, pz1: u32,
                           px2: u32, py2: u32, pz2: u32,
                           px3: u32, py3: u32, pz3: u32| {
        let v0 = bf_make_vertex(px0, py0, pz0, NORM, AO, 0, 0, mat, sky, blk);
        let v1 = bf_make_vertex(px1, py1, pz1, NORM, AO, 1, 0, mat, sky, blk);
        let v2 = bf_make_vertex(px2, py2, pz2, NORM, AO, 1, 1, mat, sky, blk);
        let v3 = bf_make_vertex(px3, py3, pz3, NORM, AO, 0, 1, mat, sky, blk);

        // Forward quad.
        let b = buf.vtx_count;
        buf.write_vertex(&v0);
        buf.write_vertex(&v1);
        buf.write_vertex(&v2);
        buf.write_vertex(&v3);
        for &i in &[b, b + 1, b + 2, b, b + 2, b + 3] {
            buf.write_index(i);
        }

        // Reverse quad (same positions, opposite winding).
        let b = buf.vtx_count;
        buf.write_vertex(&v0);
        buf.write_vertex(&v1);
        buf.write_vertex(&v2);
        buf.write_vertex(&v3);
        for &i in &[b, b + 2, b + 1, b, b + 3, b + 2] {
            buf.write_index(i);
        }
    };

    // Diagonal A: (bx,bz)-(bx+1,bz+1).
    emit_both_faces(buf, x0, y0, z0, x1, y0, z1, x1, y1, z1, x0, y1, z0);
    // Diagonal B: (bx+1,bz)-(bx,bz+1).
    emit_both_faces(buf, x1, y0, z0, x0, y0, z1, x0, y1, z1, x1, y1, z0);

    true
}

// ---- door emission ----------------------------------------------------------
// Thin slab box (open vs closed), 6 quads = 24 verts + 36 indices.
#[allow(clippy::too_many_arguments)]
fn emit_door(
    bx: i32,
    by: i32,
    bz: i32,
    id: BlockId,
    rotated: bool,
    sky: u8,
    blk: u8,
    buf: &mut MeshBuffers,
) -> bool {
    if buf.vtx_cap - buf.vtx.len() < 24 * VERTEX_SIZE {
        return false;
    }
    if buf.idx_cap - buf.idx.len() < 36 * INDEX_SIZE {
        return false;
    }

    const AO: u32 = 3;
    // Both door states use the oak_door (closed, id 33) texture tile.
    let mat: u16 = DOOR_CLOSED;
    let x = bx as u32;
    let y = by as u32;
    let z = bz as u32;

    // Fracs run 0..16 across the cell; split into integer block step + 4-bit frac.
    let vert = |fx: u32, fy: u32, fz: u32, normal: u32, u: u32, v: u32| -> BFVertex {
        BFVertex {
            pos_packed: bf_pack_pos(
                x + (fx >> 4),
                y + (fy >> 4),
                z + (fz >> 4),
                fx & 0xF,
                fy & 0xF,
                fz & 0xF,
            ),
            normal_uv: bf_pack_normal_uv(normal, AO, u, v),
            material_id: mat,
            sky_light: sky,
            block_light: blk,
            reserved: 0,
        }
    };
    let bx_box = |buf: &mut MeshBuffers,
                  xlo: u32, xhi: u32, ylo: u32, yhi: u32, zlo: u32, zhi: u32| {
        buf.quad(
            &vert(xhi, ylo, zlo, BF_NX_POS, 0, 0),
            &vert(xhi, yhi, zlo, BF_NX_POS, 0, 1),
            &vert(xhi, yhi, zhi, BF_NX_POS, 1, 1),
            &vert(xhi, ylo, zhi, BF_NX_POS, 1, 0),
        );
        buf.quad(
            &vert(xlo, ylo, zhi, BF_NX_NEG, 0, 0),
            &vert(xlo, yhi, zhi, BF_NX_NEG, 0, 1),
            &vert(xlo, yhi, zlo, BF_NX_NEG, 1, 1),
            &vert(xlo, ylo, zlo, BF_NX_NEG, 1, 0),
        );
        buf.quad(
            &vert(xhi, ylo, zhi, BF_NZ_POS, 0, 0),
            &vert(xhi, yhi, zhi, BF_NZ_POS, 0, 1),
            &vert(xlo, yhi, zhi, BF_NZ_POS, 1, 1),
            &vert(xlo, ylo, zhi, BF_NZ_POS, 1, 0),
        );
        buf.quad(
            &vert(xlo, ylo, zlo, BF_NZ_NEG, 0, 0),
            &vert(xlo, yhi, zlo, BF_NZ_NEG, 0, 1),
            &vert(xhi, yhi, zlo, BF_NZ_NEG, 1, 1),
            &vert(xhi, ylo, zlo, BF_NZ_NEG, 1, 0),
        );
        buf.quad(
            &vert(xhi, yhi, zlo, BF_NY_POS, 0, 0),
            &vert(xlo, yhi, zlo, BF_NY_POS, 1, 0),
            &vert(xlo, yhi, zhi, BF_NY_POS, 1, 1),
            &vert(xhi, yhi, zhi, BF_NY_POS, 0, 1),
        );
        buf.quad(
            &vert(xlo, ylo, zlo, BF_NY_NEG, 0, 0),
            &vert(xhi, ylo, zlo, BF_NY_NEG, 1, 0),
            &vert(xhi, ylo, zhi, BF_NY_NEG, 1, 1),
            &vert(xlo, ylo, zhi, BF_NY_NEG, 0, 1),
        );
    };
    const T: u32 = 3; // panel thickness 3/16
    if id == DOOR_OPEN {
        if rotated {
            bx_box(buf, 0, 16, 0, 16, 0, T);
        } else {
            bx_box(buf, 0, T, 0, 16, 0, 16);
        }
    } else if rotated {
        bx_box(buf, 0, T, 0, 16, 0, 16);
    } else {
        bx_box(buf, 0, 16, 0, 16, 0, T);
    }
    true
}

// ---- snow overlay emission (#118) -------------------------------------------
// A thin white blanket sitting at the BOTTOM of the cell, on top of whatever block
// is below. The slab is full width in X and Z but only a few sixteenths tall, so the
// block under it shows on the sides and the snow reads as a covering rather than a
// cube. Fresh snow (12) is taller with a slight raised lip; trodden snow (54, #117)
// is flatter and uses a separate material id so the renderer tints the print darker.
//
// Fresh snow is the cheap path: 6 quads = 24 verts + 36 indices, same budget as a
// door, with a flat full-width top so adjacent cells tile into one cohesive blanket.
//
// Trodden snow (#144) is a pressed-track shape instead of a flat slab. Stepping in
// snow squeezes it up at the edges and packs it down in the middle, so the cell is
// meshed as a shallow bowl: a raised compressed rim around the perimeter and a
// recessed centre floor, joined by four inner walls. The rim catches light while the
// sunken centre falls into shadow, so a line of these cells reads as pressed tracks
// with clear edge definition against the surrounding fresh snow rather than a flat
// cleared patch. The bowl is fully contained inside the cell (rim height stays below
// fresh snow) and is deterministic from the cell alone, so it tiles with neighbours.
// 14 quads = 56 verts + 84 indices for the trodden bowl; the cap check uses that.
fn emit_snow_layer(
    bx: i32,
    by: i32,
    bz: i32,
    id: BlockId,
    sky: u8,
    blk: u8,
    buf: &mut MeshBuffers,
) -> bool {
    // Trodden snow is the larger shape (a bowl); reserve for the worst case so a
    // partial emit can never leave a half-written cell.
    if buf.vtx_cap - buf.vtx.len() < 56 * VERTEX_SIZE {
        return false;
    }
    if buf.idx_cap - buf.idx.len() < 84 * INDEX_SIZE {
        return false;
    }

    const AO: u32 = 3;
    let mat: u16 = id; // 12 fresh, 54 trodden, tinted by the renderer
    let x = bx as u32;
    let y = by as u32;
    let z = bz as u32;

    // Blanket thickness in sixteenths. Fresh snow stands a touch proud of the block.
    // (Trodden snow ignores this and builds its own bowl heights below.)
    let top: u32 = 6;

    // Fracs run 0..16 across the cell; split into integer block step + 4-bit frac.
    let vert = |fx: u32, fy: u32, fz: u32, normal: u32, u: u32, v: u32| -> BFVertex {
        BFVertex {
            pos_packed: bf_pack_pos(
                x + (fx >> 4),
                y + (fy >> 4),
                z + (fz >> 4),
                fx & 0xF,
                fy & 0xF,
                fz & 0xF,
            ),
            normal_uv: bf_pack_normal_uv(normal, AO, u, v),
            material_id: mat,
            sky_light: sky,
            block_light: blk,
            reserved: 0,
        }
    };

    // Trodden snow (#144): a pressed bowl rather than a flat slab. See the header
    // comment. Built and returned here so the fresh-snow blanket path below is left
    // exactly as #118 shaped it.
    if id == TRODDEN_SNOW {
        emit_trodden_bowl(&vert, buf);
        return true;
    }

    // Slab spans X/Z 0..16, Y 0..top, so adjacent snow cells tile seamlessly into one
    // blanket. The top cap is full width too: a per-cell lip inset made every cell border
    // read as an exposed-dirt grid, which fought the "cohesive blanket" goal. The blanket
    // reads as a covering purely from its thinness (the block shows on the sides at the
    // edge of the snow field and on every step riser), which is the #118 requirement.
    let lo: u32 = 0;
    let hi: u32 = 16;
    let tlo: u32 = lo;
    let thi: u32 = hi;

    // +X side.
    buf.quad(
        &vert(hi, 0, lo, BF_NX_POS, 0, 0),
        &vert(hi, top, lo, BF_NX_POS, 0, 1),
        &vert(hi, top, hi, BF_NX_POS, 1, 1),
        &vert(hi, 0, hi, BF_NX_POS, 1, 0),
    );
    // -X side.
    buf.quad(
        &vert(lo, 0, hi, BF_NX_NEG, 0, 0),
        &vert(lo, top, hi, BF_NX_NEG, 0, 1),
        &vert(lo, top, lo, BF_NX_NEG, 1, 1),
        &vert(lo, 0, lo, BF_NX_NEG, 1, 0),
    );
    // +Z side.
    buf.quad(
        &vert(hi, 0, hi, BF_NZ_POS, 0, 0),
        &vert(hi, top, hi, BF_NZ_POS, 0, 1),
        &vert(lo, top, hi, BF_NZ_POS, 1, 1),
        &vert(lo, 0, hi, BF_NZ_POS, 1, 0),
    );
    // -Z side.
    buf.quad(
        &vert(lo, 0, lo, BF_NZ_NEG, 0, 0),
        &vert(lo, top, lo, BF_NZ_NEG, 0, 1),
        &vert(hi, top, lo, BF_NZ_NEG, 1, 1),
        &vert(hi, 0, lo, BF_NZ_NEG, 1, 0),
    );
    // Top cap, inset by the lip so the rim reads.
    buf.quad(
        &vert(thi, top, tlo, BF_NY_POS, 0, 0),
        &vert(tlo, top, tlo, BF_NY_POS, 1, 0),
        &vert(tlo, top, thi, BF_NY_POS, 1, 1),
        &vert(thi, top, thi, BF_NY_POS, 0, 1),
    );
    // Bottom cap, sits flush on the block below.
    buf.quad(
        &vert(lo, 0, lo, BF_NY_NEG, 0, 0),
        &vert(hi, 0, lo, BF_NY_NEG, 1, 0),
        &vert(hi, 0, hi, BF_NY_NEG, 1, 1),
        &vert(lo, 0, hi, BF_NY_NEG, 0, 1),
    );
    true
}

// Pressed-track bowl for trodden snow (#144). `vert` is emit_snow_layer's vertex
// builder (already bound to this cell's origin, material and lighting), so the bowl
// is purely a set of quads in cell-local frac space (0..16 per axis). The shape:
//
//   rim --__        __-- rim        a raised compressed lip around the perimeter,
//          |        |               inner walls dropping into a sunken centre floor.
//   floor  |________|  floor
//
// Heights are fixed constants (no per-cell variation), so the bowl is deterministic
// and identical for every trodden cell, tiling cleanly along a trail. The rim stays
// below fresh snow (6/16), so a print sits visibly sunk inside the surrounding
// blanket; the inner walls + sunken floor give the print self-shadowing edges.
fn emit_trodden_bowl<F>(vert: &F, buf: &mut MeshBuffers)
where
    F: Fn(u32, u32, u32, u32, u32, u32) -> BFVertex,
{
    // Cell-local fracs (0..16).
    let lo: u32 = 0;
    let hi: u32 = 16;
    // Raised rim, below fresh snow (6) so the print reads as sunk in the blanket.
    let rim: u32 = 3;
    // Recessed centre floor, still a sliver of snow above the block below.
    let floor: u32 = 1;
    // Inner hole edges: a 5/16 rim band on each side, a 6/16 square pit in the middle.
    let il: u32 = 5;
    let ih: u32 = 11;

    // --- outer side walls (full perimeter, y 0..rim) -------------------------
    // +X side.
    buf.quad(
        &vert(hi, 0, lo, BF_NX_POS, 0, 0),
        &vert(hi, rim, lo, BF_NX_POS, 0, 1),
        &vert(hi, rim, hi, BF_NX_POS, 1, 1),
        &vert(hi, 0, hi, BF_NX_POS, 1, 0),
    );
    // -X side.
    buf.quad(
        &vert(lo, 0, hi, BF_NX_NEG, 0, 0),
        &vert(lo, rim, hi, BF_NX_NEG, 0, 1),
        &vert(lo, rim, lo, BF_NX_NEG, 1, 1),
        &vert(lo, 0, lo, BF_NX_NEG, 1, 0),
    );
    // +Z side.
    buf.quad(
        &vert(hi, 0, hi, BF_NZ_POS, 0, 0),
        &vert(hi, rim, hi, BF_NZ_POS, 0, 1),
        &vert(lo, rim, hi, BF_NZ_POS, 1, 1),
        &vert(lo, 0, hi, BF_NZ_POS, 1, 0),
    );
    // -Z side.
    buf.quad(
        &vert(lo, 0, lo, BF_NZ_NEG, 0, 0),
        &vert(lo, rim, lo, BF_NZ_NEG, 0, 1),
        &vert(hi, rim, lo, BF_NZ_NEG, 1, 1),
        &vert(hi, 0, lo, BF_NZ_NEG, 1, 0),
    );

    // --- bottom cap, flush on the block below --------------------------------
    buf.quad(
        &vert(lo, 0, lo, BF_NY_NEG, 0, 0),
        &vert(hi, 0, lo, BF_NY_NEG, 1, 0),
        &vert(hi, 0, hi, BF_NY_NEG, 1, 1),
        &vert(lo, 0, hi, BF_NY_NEG, 0, 1),
    );

    // --- raised rim ring (flat top at y=rim, framing the pit) ----------------
    // Built as four rectangles around the hole, same up-facing winding as a top cap.
    let rim_band = |a0: u32, a2: u32, c0: u32, c2: u32, buf: &mut MeshBuffers| {
        buf.quad(
            &vert(a2, rim, c0, BF_NY_POS, 0, 0),
            &vert(a0, rim, c0, BF_NY_POS, 1, 0),
            &vert(a0, rim, c2, BF_NY_POS, 1, 1),
            &vert(a2, rim, c2, BF_NY_POS, 0, 1),
        );
    };
    rim_band(lo, hi, lo, il, buf); // -Z band
    rim_band(lo, hi, ih, hi, buf); // +Z band
    rim_band(lo, il, il, ih, buf); // -X band
    rim_band(ih, hi, il, ih, buf); // +X band

    // --- inner walls of the pit (y rim..floor), facing inward ----------------
    // +X-facing wall at x=il (pit lies toward +X of it).
    buf.quad(
        &vert(il, floor, il, BF_NX_POS, 0, 0),
        &vert(il, rim, il, BF_NX_POS, 0, 1),
        &vert(il, rim, ih, BF_NX_POS, 1, 1),
        &vert(il, floor, ih, BF_NX_POS, 1, 0),
    );
    // -X-facing wall at x=ih.
    buf.quad(
        &vert(ih, floor, ih, BF_NX_NEG, 0, 0),
        &vert(ih, rim, ih, BF_NX_NEG, 0, 1),
        &vert(ih, rim, il, BF_NX_NEG, 1, 1),
        &vert(ih, floor, il, BF_NX_NEG, 1, 0),
    );
    // +Z-facing wall at z=il.
    buf.quad(
        &vert(ih, floor, il, BF_NZ_POS, 0, 0),
        &vert(ih, rim, il, BF_NZ_POS, 0, 1),
        &vert(il, rim, il, BF_NZ_POS, 1, 1),
        &vert(il, floor, il, BF_NZ_POS, 1, 0),
    );
    // -Z-facing wall at z=ih.
    buf.quad(
        &vert(il, floor, ih, BF_NZ_NEG, 0, 0),
        &vert(il, rim, ih, BF_NZ_NEG, 0, 1),
        &vert(ih, rim, ih, BF_NZ_NEG, 1, 1),
        &vert(ih, floor, ih, BF_NZ_NEG, 1, 0),
    );

    // --- recessed centre floor (flat at y=floor) -----------------------------
    buf.quad(
        &vert(ih, floor, il, BF_NY_POS, 0, 0),
        &vert(il, floor, il, BF_NY_POS, 1, 0),
        &vert(il, floor, ih, BF_NY_POS, 1, 1),
        &vert(ih, floor, ih, BF_NY_POS, 0, 1),
    );
}

// ============================================================================
// GreedyMesher::mesh
// ============================================================================

pub struct GreedyMesher;

impl Default for GreedyMesher {
    fn default() -> Self {
        GreedyMesher
    }
}

impl GreedyMesher {
    pub fn new() -> Self {
        GreedyMesher
    }

    pub fn max_vertex_bytes(&self) -> u32 {
        K_MAX_VERTEX_BYTES
    }
    pub fn max_index_bytes(&self) -> u32 {
        K_MAX_INDEX_BYTES
    }

    // Mesh chunk `c` using neighbour access via `store`. Returns the MeshResult
    // plus the packed vertex bytes and index bytes (the C++ writes these into
    // caller-provided spans; here we own them and the caller reads .0/.1/.2).
    //
    // `simplified` is accepted for signature parity (M2 LOD), currently ignored.
    pub fn mesh<S: ChunkStore>(
        &self,
        c: ChunkCoord,
        store: &S,
        simplified: bool,
    ) -> (MeshResult, Vec<u8>, Vec<u8>) {
        let _ = simplified; // TODO(M2): LOD meshing

        let chunk = store.get(c);

        // Null chunk or uniform-air chunk -> empty.
        let chunk = match chunk {
            None => return (MeshResult { vertex_bytes: 0, index_bytes: 0, index_count: 0, empty: true }, Vec::new(), Vec::new()),
            Some(ch) => ch,
        };
        if chunk.is_uniform() && chunk.get(0, 0, 0) == 0 {
            return (
                MeshResult { vertex_bytes: 0, index_bytes: 0, index_count: 0, empty: true },
                Vec::new(),
                Vec::new(),
            );
        }

        let mut buf = MeshBuffers::new(K_MAX_VERTEX_BYTES as usize, K_MAX_INDEX_BYTES as usize);

        // Mask arrays reused across slices and directions.
        let mut mask = [[MaskCell { id: 0, sky: 15, blk: 0, ao_packed: 0 }; CHUNK_DIM]; CHUNK_DIM];
        let mut ao_corners = [[AOCorners::default(); CHUNK_DIM]; CHUNK_DIM];

        let chunk_opt: Option<&S::Chunk> = Some(chunk);

        for fd in K_FACE_DIRS.iter() {
            for d in 0..KCHUNK_DIM {
                // Build visibility mask for this slice.
                for u in 0..KCHUNK_DIM {
                    for v in 0..KCHUNK_DIM {
                        let (x, y, z) = axes_to_xyz(fd, d, u, v);

                        let here = chunk_get(chunk_opt, x, y, z);
                        mask[u as usize][v as usize] = MaskCell { id: 0, sky: 15, blk: 0, ao_packed: 0 };
                        if here == 0 {
                            continue;
                        }

                        let nb = neighbour_block(chunk_opt, c, store, fd, x, y, z);

                        // Opacity rules (see mesher.cpp comments).
                        let emit;
                        if is_opaque(here) {
                            emit = !is_opaque(nb); // air, water, or glass neighbour
                        } else if here == 9 || is_waterlogged(here) {
                            emit = match neighbour_block_known(chunk_opt, c, store, fd, x, y, z) {
                                Some(known) => known == 0, // water surface only against loaded air
                                None => false,
                            };
                        } else if is_glass(here) {
                            emit = nb == 0 || nb == 9; // glass against air/water, cull glass-glass
                        } else {
                            emit = false;
                        }

                        if emit {
                            let (sky, blk) = neighbour_light(chunk, c, store, fd, x, y, z);

                            let ao = compute_face_ao(chunk_opt, c, store, fd, x, y, z);
                            ao_corners[u as usize][v as usize] = ao;

                            let mat_id = if is_waterlogged(here) { 9 } else { here };
                            mask[u as usize][v as usize] = MaskCell {
                                id: mat_id,
                                sky,
                                blk,
                                ao_packed: pack_ao(&ao),
                            };
                        }
                    }
                }

                // Greedy merge the mask.
                let mut merged = [[false; CHUNK_DIM]; CHUNK_DIM];

                for u in 0..KCHUNK_DIM {
                    for v in 0..KCHUNK_DIM {
                        let cell = mask[u as usize][v as usize];
                        if cell.id == 0 || merged[u as usize][v as usize] {
                            continue;
                        }

                        // Same key and not yet merged.
                        let same = |uu: i32, vv: i32, merged: &[[bool; CHUNK_DIM]; CHUNK_DIM]| {
                            mask[uu as usize][vv as usize] == cell && !merged[uu as usize][vv as usize]
                        };

                        // Max width w in +u.
                        let mut w = 1;
                        while u + w < KCHUNK_DIM && same(u + w, v, &merged) {
                            w += 1;
                        }

                        // Max height h in +v while entire row matches.
                        let mut h = 1;
                        let mut row_ok = true;
                        while v + h < KCHUNK_DIM && row_ok {
                            for k in 0..w {
                                if !same(u + k, v + h, &merged) {
                                    row_ok = false;
                                    break;
                                }
                            }
                            if row_ok {
                                h += 1;
                            }
                        }

                        // Mark merged.
                        for ku in 0..w {
                            for kv in 0..h {
                                merged[(u + ku) as usize][(v + kv) as usize] = true;
                            }
                        }

                        let ao = ao_corners[u as usize][v as usize];

                        let base = buf.vtx_count;
                        let ok = emit_quad(
                            fd, d, u, v, w, h, cell.id, cell.sky, cell.blk, ao.a0, ao.a1, ao.a2,
                            ao.a3, &mut buf, base,
                        );
                        if !ok {
                            buf.full = true;
                            return finalize(buf, false);
                        }
                    }
                }
            }
        }

        // ---- Prop pass ------------------------------------------------------
        for y in 0..KCHUNK_DIM {
            for x in 0..KCHUNK_DIM {
                for z in 0..KCHUNK_DIM {
                    let here = chunk_get(chunk_opt, x, y, z);

                    // #69 doors: thin slab geometry, not a prop or a cube.
                    if is_door(here) {
                        let dsky = chunk.sky_light(x as usize, y as usize, z as usize);
                        let dblk = chunk.block_light(x as usize, y as usize, z as usize);
                        let rotated = door_mesh_rotated(chunk_opt, c, store, x, y, z);
                        let render_id = door_mesh_run_state(chunk_opt, c, store, x, y, z);
                        if !emit_door(x, y, z, render_id, rotated, dsky, dblk, &mut buf) {
                            buf.full = true;
                            return finalize(buf, false);
                        }
                        continue;
                    }

                    // #118 snow overlay: a thin blanket slab at the bottom of the cell.
                    if is_snow_overlay(here) {
                        // #151 floating snow: a snow blanket only renders when it has a
                        // real surface to sit on. Walking into a carved ravine used to
                        // show snow slabs hanging in the air because the overlay emitted
                        // even where the cell directly below had been dug out. Gate the
                        // emit on the cell below being a solid (opaque) block, using the
                        // same is_opaque check the mesher uses for face culling. Snow,
                        // water, glass, doors and props are non-opaque, so a snow cell
                        // floating over air (or over another snow blanket) is skipped and
                        // nothing hangs in the gap. Snow on real ground is unchanged.
                        let below = sample_block(chunk_opt, c, store, x, y - 1, z);
                        if !is_opaque(below) {
                            continue;
                        }
                        let ssky = chunk.sky_light(x as usize, y as usize, z as usize);
                        let sblk = chunk.block_light(x as usize, y as usize, z as usize);
                        if !emit_snow_layer(x, y, z, here, ssky, sblk, &mut buf) {
                            buf.full = true;
                            return finalize(buf, false);
                        }
                        continue;
                    }

                    if !is_prop(here) {
                        continue;
                    }
                    if is_instanced_prop(here) {
                        continue; // drawn by the prop renderer, no mesh geometry
                    }

                    let sky = chunk.sky_light(x as usize, y as usize, z as usize);
                    let blk = chunk.block_light(x as usize, y as usize, z as usize);

                    let ok = if is_torch(here) {
                        emit_torch(x, y, z, sky, blk, &mut buf)
                    } else {
                        emit_cross_plant(x, y, z, here, sky, blk, &mut buf)
                    };
                    if !ok {
                        buf.full = true;
                        return finalize(buf, false);
                    }
                }
            }
        }

        finalize(buf, true)
    }
}

// Build the MeshResult + buffers. `complete` is false when we bailed on a full
// buffer (matches the C++ early-return path that reports empty=false).
fn finalize(buf: MeshBuffers, complete: bool) -> (MeshResult, Vec<u8>, Vec<u8>) {
    let vertex_bytes = buf.vtx.len() as u32;
    let index_bytes = buf.idx.len() as u32;
    let index_count = index_bytes / INDEX_SIZE as u32;
    let empty = if complete { index_count == 0 } else { false };
    (
        MeshResult { vertex_bytes, index_bytes, index_count, empty },
        buf.vtx,
        buf.idx,
    )
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    // ---- minimal test chunk / store ----------------------------------------
    // A flat 16^3 array chunk with optional light. Mirrors the surface the mesher
    // needs from bfcore's PaletteChunk (get / sky_light / block_light / is_uniform).
    struct TestChunk {
        blocks: [BlockId; CHUNK_VOL],
        sky: [u8; CHUNK_VOL],
        block: [u8; CHUNK_VOL],
        lit: bool,
    }

    impl TestChunk {
        fn new() -> Self {
            TestChunk {
                blocks: [0; CHUNK_VOL],
                sky: [0; CHUNK_VOL],
                block: [0; CHUNK_VOL],
                lit: false,
            }
        }
        fn idx(x: usize, y: usize, z: usize) -> usize {
            x + CHUNK_DIM * (y + CHUNK_DIM * z)
        }
        fn set(&mut self, x: usize, y: usize, z: usize, b: BlockId) {
            self.blocks[Self::idx(x, y, z)] = b;
        }
        // Set explicit per-cell light (also flips `lit` so the arrays are honored
        // instead of the unlit defaults).
        fn set_light(&mut self, x: usize, y: usize, z: usize, sky: u8, block: u8) {
            self.lit = true;
            let i = Self::idx(x, y, z);
            self.sky[i] = sky;
            self.block[i] = block;
        }
    }

    impl Chunk for TestChunk {
        fn get(&self, x: usize, y: usize, z: usize) -> BlockId {
            self.blocks[Self::idx(x, y, z)]
        }
        fn sky_light(&self, x: usize, y: usize, z: usize) -> u8 {
            if !self.lit {
                return 15;
            }
            self.sky[Self::idx(x, y, z)]
        }
        fn block_light(&self, x: usize, y: usize, z: usize) -> u8 {
            if !self.lit {
                return 0;
            }
            self.block[Self::idx(x, y, z)]
        }
        fn is_uniform(&self) -> bool {
            let first = self.blocks[0];
            self.blocks.iter().all(|&b| b == first)
        }
    }

    struct TestStore {
        chunks: HashMap<ChunkCoord, TestChunk>,
    }
    impl TestStore {
        fn new() -> Self {
            TestStore { chunks: HashMap::new() }
        }
    }
    impl ChunkStore for TestStore {
        type Chunk = TestChunk;
        fn get(&self, c: ChunkCoord) -> Option<&TestChunk> {
            self.chunks.get(&c)
        }
    }

    // FNV-1a over a byte slice. Same constants as the C++ harness so the hashes
    // are directly comparable.
    fn fnv1a(bytes: &[u8]) -> u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for &b in bytes {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
        h
    }

    // Build the canonical test chunk used by both the C++ harness and Rust:
    //   stone(1) cube 2x2x2 at (2..4, 2..4, 2..4)
    //   glass_pane(25) single block at (8,2,8)
    //   torch(32) single block at (12,2,12)
    //   color_crystal(40) instanced prop at (5,5,5) - emits no geometry
    // No light set (lit=false) so sky=15, block=0 everywhere, matching the C++
    // chunk whose sky_light/block_light return the unlit defaults.
    fn build_test_chunk() -> TestChunk {
        let mut ch = TestChunk::new();
        for x in 2..4 {
            for y in 2..4 {
                for z in 2..4 {
                    ch.set(x, y, z, 1);
                }
            }
        }
        ch.set(8, 2, 8, 25);
        ch.set(12, 2, 12, 32);
        ch.set(5, 5, 5, 40);
        ch
    }

    #[test]
    fn empty_chunk_is_empty() {
        let mut store = TestStore::new();
        store.chunks.insert(ChunkCoord::default(), TestChunk::new());
        let m = GreedyMesher::new();
        let (res, vtx, idx) = m.mesh(ChunkCoord::default(), &store, false);
        assert!(res.empty);
        assert_eq!(res.vertex_bytes, 0);
        assert_eq!(res.index_bytes, 0);
        assert!(vtx.is_empty());
        assert!(idx.is_empty());
    }

    #[test]
    fn null_chunk_is_empty() {
        let store = TestStore::new();
        let m = GreedyMesher::new();
        let (res, _, _) = m.mesh(ChunkCoord::default(), &store, false);
        assert!(res.empty);
        assert_eq!(res.index_count, 0);
    }

    #[test]
    fn single_stone_block_has_six_faces() {
        // One isolated solid cube => 6 faces => 24 verts, 36 indices.
        let mut store = TestStore::new();
        let mut ch = TestChunk::new();
        ch.set(8, 8, 8, 1);
        store.chunks.insert(ChunkCoord::default(), ch);
        let m = GreedyMesher::new();
        let (res, vtx, idx) = m.mesh(ChunkCoord::default(), &store, false);
        assert_eq!(res.vertex_bytes, 24 * 16);
        assert_eq!(res.index_count, 36);
        assert_eq!(vtx.len(), 24 * 16);
        assert_eq!(idx.len(), 36 * 4);
        assert!(!res.empty);
    }

    // Decode each vertex's continuous Y (integer cell + 4-bit fraction/16) and its
    // material id. Used by the snow-overlay test to prove the slab is thin.
    fn decode_y_and_mat(vtx: &[u8]) -> Vec<(f32, u16)> {
        let mut out = Vec::new();
        for ch in vtx.chunks_exact(16) {
            let pos = u32::from_le_bytes([ch[0], ch[1], ch[2], ch[3]]);
            let y = ((pos >> 6) & 0x3F) as f32;
            let fy = ((pos >> 22) & 0xF) as f32;
            let mat = u16::from_le_bytes([ch[8], ch[9]]);
            out.push((y + fy / 16.0, mat));
        }
        out
    }

    // #118 snow overlay: a snow_layer (12) block sitting directly on grass (1) must mesh
    // as a THIN blanket slab, not a full cube. The grass keeps all its faces; the snow
    // emits a separate slab whose top sits well below the top of its cell, so the grass
    // shows on the sides. trodden_snow (54, #117 footprint) is even flatter.
    #[test]
    fn snow_overlay_is_a_thin_slab_over_the_block() {
        let mut store = TestStore::new();
        let mut ch = TestChunk::new();
        ch.set(8, 8, 8, 1); // grass surface
        ch.set(8, 9, 8, 12); // fresh snow blanket on top
        store.chunks.insert(ChunkCoord::default(), ch);
        let m = GreedyMesher::new();
        let (res, vtx, _) = m.mesh(ChunkCoord::default(), &store, false);

        // Grass keeps 6 faces (24 verts), snow adds a 6-quad slab (24 verts). The snow is
        // not a culled cube and not opaque, so the grass top face is NOT removed.
        assert_eq!(res.index_count, 36 + 36, "grass cube + snow slab");

        let vm = decode_y_and_mat(&vtx);
        // Snow material (12) vertices all live in the snow cell's bottom few sixteenths:
        // the slab spans y=9.0 (cell floor, on top of grass) up to a fractional top well
        // under y=10.0 (the cell ceiling). A full cube would reach y=10.0.
        let snow_ys: Vec<f32> = vm.iter().filter(|&&(_, m)| m == 12).map(|&(y, _)| y).collect();
        assert!(!snow_ys.is_empty(), "snow slab must emit geometry");
        let snow_top = snow_ys.iter().cloned().fold(f32::MIN, f32::max);
        let snow_bot = snow_ys.iter().cloned().fold(f32::MAX, f32::min);
        assert!((snow_bot - 9.0).abs() < 1e-3, "snow slab sits on top of the grass (y=9)");
        assert!(snow_top < 9.5, "snow slab top {snow_top} must be a thin lip, not a full cube (y<9.5)");
        assert!(snow_top > 9.0, "snow slab must have some thickness");

        // The grass still has its own top face at y=9.0 (cell ceiling of the grass cell),
        // present because snow does not occlude. So the block reads through under the snow.
        let grass_top_faces = vm.iter().filter(|&&(y, m)| m == 1 && (y - 9.0).abs() < 1e-3).count();
        assert!(grass_top_faces >= 4, "grass keeps its top face under the non-opaque snow");
    }

    // #144: trodden snow (54) is no longer a flat slab; it is a pressed bowl with a
    // raised rim and a recessed centre. Two properties prove the shape: its rim stays
    // sunk below fresh snow (so a print reads as compressed into the blanket), and it
    // has a top surface ABOVE its lowest top surface (the rim sits proud of the sunken
    // floor) so the cell reads as an indented track, not a flat patch.
    #[test]
    fn trodden_snow_is_a_pressed_bowl_below_fresh_snow() {
        let snow_ys = |id: BlockId| -> Vec<f32> {
            let mut store = TestStore::new();
            let mut ch = TestChunk::new();
            ch.set(8, 8, 8, 1);
            ch.set(8, 9, 8, id);
            store.chunks.insert(ChunkCoord::default(), ch);
            let (_, vtx, _) = GreedyMesher::new().mesh(ChunkCoord::default(), &store, false);
            decode_y_and_mat(&vtx)
                .iter()
                .filter(|&&(_, m)| m == id)
                .map(|&(y, _)| y)
                .collect()
        };
        let max = |ys: &[f32]| ys.iter().cloned().fold(f32::MIN, f32::max);

        let fresh = snow_ys(12);
        let trod = snow_ys(54);
        let fresh_top = max(&fresh);
        let trod_rim = max(&trod);

        // The bowl's raised rim is still sunk below fresh snow's surface.
        assert!(
            trod_rim < fresh_top,
            "the trodden rim (54) sits below fresh snow (12): {trod_rim} < {fresh_top}"
        );

        // The bowl has at least two distinct top heights: the raised rim and the lower
        // recessed centre floor. Both are above the grass top (y=9.0) but the rim is
        // strictly higher than the sunken floor, so the cell is indented, not flat.
        let mut tops: Vec<f32> = trod
            .iter()
            .cloned()
            .filter(|&y| y > 9.0 + 1e-3) // exclude the bottom cap / wall feet at y=9.0
            .collect();
        tops.sort_by(|a, b| a.partial_cmp(b).unwrap());
        tops.dedup_by(|a, b| (*a - *b).abs() < 1e-3);
        assert!(
            tops.len() >= 2,
            "the bowl has a raised rim and a lower recessed floor (distinct tops: {tops:?})"
        );
        let floor = tops[0];
        assert!(
            floor < trod_rim - 1e-3,
            "the recessed floor ({floor}) is below the raised rim ({trod_rim})"
        );
    }

    // #151 floating snow: the snow overlay only renders when the cell directly below is
    // a solid (opaque) block. A snow cell over a carved-out ravine (air below) must emit
    // NO snow geometry, so nothing hangs in the gap; a snow cell over real ground emits
    // its slab unchanged. Both fresh (12) and trodden (54) snow are gated the same way.
    #[test]
    fn snow_only_emits_with_a_solid_block_below() {
        // Count snow-material vertices for a given snow id and a given block below it.
        let snow_verts = |snow_id: BlockId, below: BlockId| -> usize {
            let mut store = TestStore::new();
            let mut ch = TestChunk::new();
            if below != 0 {
                ch.set(8, 8, 8, below); // supporting block (or none for air)
            }
            ch.set(8, 9, 8, snow_id); // snow blanket in the cell above
            store.chunks.insert(ChunkCoord::default(), ch);
            let (_, vtx, _) = GreedyMesher::new().mesh(ChunkCoord::default(), &store, false);
            decode_y_and_mat(&vtx)
                .iter()
                .filter(|&&(_, m)| m == snow_id)
                .count()
        };

        // Solid ground below (grass=1, opaque): snow emits its slab.
        assert!(
            snow_verts(12, 1) > 0,
            "fresh snow on solid ground must emit a slab"
        );
        assert!(
            snow_verts(54, 1) > 0,
            "trodden snow on solid ground must emit its bowl"
        );

        // Air below (carved ravine, #151): snow emits nothing, so it cannot float.
        assert_eq!(
            snow_verts(12, 0),
            0,
            "fresh snow over air must emit no geometry"
        );
        assert_eq!(
            snow_verts(54, 0),
            0,
            "trodden snow over air must emit no geometry"
        );

        // Snow over snow is also unsupported (snow is non-opaque): the upper blanket is
        // skipped so a stranded stack does not hang in the air.
        assert_eq!(
            snow_verts(12, 12),
            0,
            "fresh snow over a non-opaque snow cell must emit no geometry"
        );
    }

    // Decode a packed vertex stream into (normal, sky_light, block_light) tuples,
    // one per vertex. Normal is normal_uv bits [0:3]; sky/block are bytes 10/11.
    fn decode_vertices(vtx: &[u8]) -> Vec<(u32, u8, u8)> {
        let mut out = Vec::new();
        for chunk in vtx.chunks_exact(16) {
            let normal_uv = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
            let normal = normal_uv & 0x7;
            let sky = chunk[10];
            let block = chunk[11];
            out.push((normal, sky, block));
        }
        out
    }

    fn decode_normal_and_mat(vtx: &[u8]) -> Vec<(u32, u16)> {
        let mut out = Vec::new();
        for chunk in vtx.chunks_exact(16) {
            let normal_uv = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
            let normal = normal_uv & 0x7;
            let mat = u16::from_le_bytes([chunk[8], chunk[9]]);
            out.push((normal, mat));
        }
        out
    }

    #[test]
    fn water_does_not_emit_faces_against_missing_chunk_neighbour() {
        let mut store = TestStore::new();
        let mut ch = TestChunk::new();
        ch.set(15, 8, 8, 9);
        ch.set(14, 8, 8, 9);
        ch.set(15, 7, 8, 9);
        ch.set(15, 9, 8, 9);
        ch.set(15, 8, 7, 9);
        ch.set(15, 8, 9, 9);
        store.chunks.insert(ChunkCoord::default(), ch);

        let (_, vtx, _) = GreedyMesher::new().mesh(ChunkCoord::default(), &store, false);
        let faces = decode_normal_and_mat(&vtx);
        assert!(
            !faces.iter().any(|&(n, m)| m == 9 && n == BF_NX_POS),
            "water at x=15 must not draw a blue +X chunk-edge wall while the neighbour chunk is missing"
        );
    }

    #[test]
    fn door_orientation_is_shared_across_vertical_run() {
        let mut store = TestStore::new();
        let mut ch = TestChunk::new();
        ch.set(8, 4, 8, DOOR_CLOSED);
        ch.set(8, 5, 8, DOOR_OPEN);

        // Bottom half alone would infer an X-wall; top half alone would infer a
        // Z-wall. The mesher must choose one orientation for the whole door run.
        ch.set(7, 4, 8, 1);
        ch.set(9, 4, 8, 1);
        ch.set(8, 5, 7, 1);
        ch.set(8, 5, 9, 1);
        store.chunks.insert(ChunkCoord::default(), ch);

        let cur = store.get(ChunkCoord::default());
        let bottom = door_mesh_rotated(cur, ChunkCoord::default(), &store, 8, 4, 8);
        let top = door_mesh_rotated(cur, ChunkCoord::default(), &store, 8, 5, 8);
        assert_eq!(bottom, top, "both halves of one door must render on the same axis");
    }

    #[test]
    fn door_state_is_shared_from_bottom_half() {
        let mut store = TestStore::new();
        let mut ch = TestChunk::new();
        ch.set(8, 4, 8, DOOR_CLOSED);
        ch.set(8, 5, 8, DOOR_OPEN);
        store.chunks.insert(ChunkCoord::default(), ch);

        let cur = store.get(ChunkCoord::default());
        let bottom = door_mesh_run_state(cur, ChunkCoord::default(), &store, 8, 4, 8);
        let top = door_mesh_run_state(cur, ChunkCoord::default(), &store, 8, 5, 8);
        assert_eq!(bottom, DOOR_CLOSED, "bottom half owns the canonical state");
        assert_eq!(top, DOOR_CLOSED, "top half renders with the bottom half's state");
    }

    #[test]
    fn stone_face_against_leaf_is_emitted() {
        // A solid stone block with a leaf in +X. The mesher does not cube-mesh the
        // leaf, so the stone's +X face must still be emitted (not culled into the
        // foliage). All six stone faces should be present.
        let mut store = TestStore::new();
        let mut ch = TestChunk::new();
        ch.set(8, 8, 8, 1); // stone
        ch.set(9, 8, 8, 48); // pine leaves directly against the +X face
        store.chunks.insert(ChunkCoord::default(), ch);
        let m = GreedyMesher::new();
        let (res, vtx, _) = m.mesh(ChunkCoord::default(), &store, false);

        // Leaves emit no cube geometry, so only the stone's 6 faces exist.
        assert_eq!(res.index_count, 36, "stone should keep all six faces");
        let faces = decode_vertices(&vtx);
        assert!(
            faces.iter().any(|&(n, _, _)| n == BF_NX_POS),
            "the +X stone face (touching the leaf) must be emitted"
        );
    }

    #[test]
    fn stone_face_against_leaf_reads_light_past_the_leaf() {
        // Regression for the black-foliage bug: leaves are lighting-opaque (the
        // canopy casts shade) so a leaf cell stores no light. The stone face that
        // borders the leaf must NOT read the leaf cell's 0/0 light (which renders
        // near-black); it should look past the leaf to the lit air beyond.
        //
        // Layout along +X at y=8,z=8:  stone(8) | leaf(9) | air(10)
        // Leaf cell light = 0/0 (shadowed), air-beyond light = sky 15.
        let mut store = TestStore::new();
        let mut ch = TestChunk::new();
        ch.set(8, 8, 8, 1); // stone
        ch.set(9, 8, 8, 48); // pine leaves
        // Light: leaf cell dark, the air just past it fully sky-lit.
        ch.set_light(9, 8, 8, 0, 0); // leaf cell: no light (would paint black)
        ch.set_light(10, 8, 8, 15, 0); // lit air beyond the foliage
        store.chunks.insert(ChunkCoord::default(), ch);

        let m = GreedyMesher::new();
        let (_, vtx, _) = m.mesh(ChunkCoord::default(), &store, false);

        let faces = decode_vertices(&vtx);
        let px = faces
            .iter()
            .find(|&&(n, _, _)| n == BF_NX_POS)
            .expect("stone +X face must exist");
        assert_eq!(
            px.1, 15,
            "the leaf-facing stone face must inherit the lit air past the leaf, not the leaf's dark cell"
        );
    }

    #[test]
    fn instanced_prop_emits_no_geometry() {
        // color_crystal(40) is an instanced prop: no cube faces, no prop geometry.
        let mut store = TestStore::new();
        let mut ch = TestChunk::new();
        ch.set(8, 8, 8, 40);
        store.chunks.insert(ChunkCoord::default(), ch);
        let m = GreedyMesher::new();
        let (res, _, _) = m.mesh(ChunkCoord::default(), &store, false);
        assert!(res.empty);
        assert_eq!(res.index_count, 0);
    }

    // ---- the parity test ---------------------------------------------------
    // Numbers + hash captured from the C++ harness (tools/mesher_parity.cpp,
    // compiled against engine/src/mesher.cpp). See the report for the build line.
    #[test]
    fn cpp_parity() {
        let mut store = TestStore::new();
        store.chunks.insert(ChunkCoord::default(), build_test_chunk());
        let m = GreedyMesher::new();
        let (res, vtx, idx) = m.mesh(ChunkCoord::default(), &store, false);

        let vhash = fnv1a(&vtx);
        let ihash = fnv1a(&idx);

        // Golden values from the C++ harness:
        const CPP_VERTEX_BYTES: u32 = CPP_GOLDEN.0;
        const CPP_INDEX_COUNT: u32 = CPP_GOLDEN.1;
        const CPP_VHASH: u64 = CPP_GOLDEN.2;
        const CPP_IHASH: u64 = CPP_GOLDEN.3;

        assert_eq!(res.vertex_bytes, CPP_VERTEX_BYTES, "vertex_bytes mismatch");
        assert_eq!(res.index_count, CPP_INDEX_COUNT, "index_count mismatch");
        assert_eq!(vhash, CPP_VHASH, "packed vertex byte hash mismatch");
        assert_eq!(ihash, CPP_IHASH, "packed index byte hash mismatch");
    }

    // (vertex_bytes, index_count, fnv1a(vertex_bytes), fnv1a(index_bytes))
    // Filled in from the C++ harness run.
    const CPP_GOLDEN: (u32, u32, u64, u64) = (
        include!("cpp_golden_vbytes.in"),
        include!("cpp_golden_icount.in"),
        include!("cpp_golden_vhash.in"),
        include!("cpp_golden_ihash.in"),
    );
}
