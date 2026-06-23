// Track D — greedy mesher unit tests.
// Framework-free: returns non-zero on first failure so CTest reports it.
// Style mirrors tests/unit/test_arena.cpp.
//
// FakeChunk and FakeStore implement bf::IChunk / bf::IChunkStore inline.
// They are the minimal in-header stubs needed to drive GreedyMesher without
// the real chunk storage subsystem (Track B).

#include "blockcore/mesher.hpp"
#include "blockcore/vertex.hpp"
#include "blockcore_interfaces.hpp"

#include <array>
#include <cstdio>
#include <cstring>
#include <vector>

// ============================================================================
// Fake implementations
// ============================================================================

struct FakeChunk final : public bf::IChunk {
    std::array<bf::BlockId, bf::kChunkVol> data{};
    std::uint32_t rev{0};

    static int idx(int lx, int ly, int lz) noexcept {
        return lx + bf::kChunkDim * (ly + bf::kChunkDim * lz);
    }

    bf::BlockId get(int lx, int ly, int lz) const override {
        return data[static_cast<std::size_t>(idx(lx, ly, lz))];
    }
    void set(int lx, int ly, int lz, bf::BlockId b) override {
        data[static_cast<std::size_t>(idx(lx, ly, lz))] = b;
        ++rev;
    }
    bool is_uniform() const override {
        bf::BlockId first = data[0];
        for (auto id : data) if (id != first) return false;
        return true;
    }
    std::uint32_t revision() const override { return rev; }

    void fill(bf::BlockId b) {
        data.fill(b);
        ++rev;
    }
};

struct FakeStore final : public bf::IChunkStore {
    // Primary chunk (at target_coord).
    bf::ChunkCoord target_coord{};
    FakeChunk*     chunk{nullptr};

    // Optional secondary chunk (for AO cross-chunk tests).
    bf::ChunkCoord extra_coord{};
    FakeChunk*     extra_chunk{nullptr};

    bf::IChunk* get(bf::ChunkCoord c) override {
        if (c.x == target_coord.x && c.y == target_coord.y && c.z == target_coord.z)
            return chunk;
        if (extra_chunk &&
            c.x == extra_coord.x && c.y == extra_coord.y && c.z == extra_coord.z)
            return extra_chunk;
        return nullptr;
    }
    bf::IChunk* get_or_create(bf::ChunkCoord c) override { return get(c); }
    void        evict(bf::ChunkCoord)              override {}
    bool        is_resident(bf::ChunkCoord c) const override {
        if (c.x == target_coord.x && c.y == target_coord.y && c.z == target_coord.z)
            return true;
        if (extra_chunk &&
            c.x == extra_coord.x && c.y == extra_coord.y && c.z == extra_coord.z)
            return true;
        return false;
    }
    std::size_t serialize(bf::ChunkCoord, std::span<std::byte>) const override { return 0; }
    bool        deserialize(bf::ChunkCoord, std::span<const std::byte>) override { return false; }
};

// ============================================================================
// Test harness
// ============================================================================
static int fails = 0;
#define CHECK(c, m) do { if (!(c)) { std::printf("FAIL: %s\n", (m)); ++fails; } } while(0)

// Helper: allocate max-sized buffers and mesh.
// Stores raw buffer pointers so callers can inspect vertices.
static std::vector<std::byte> g_vtx_buf(bf::GreedyMesher::kMaxVertexBytes);
static std::vector<std::byte> g_idx_buf(bf::GreedyMesher::kMaxIndexBytes);

static bf::MeshResult do_mesh(bf::GreedyMesher& gm, bf::ChunkCoord cc, bf::IChunkStore& store) {
    return gm.mesh(cc, store, {g_vtx_buf.data(), g_vtx_buf.size()},
                              {g_idx_buf.data(), g_idx_buf.size()}, false);
}

// Extract the AO value from a BFVertex's normal_uv field: bits [3:5].
static std::uint32_t vertex_ao(const bf::BFVertex& v) {
    return (v.normal_uv >> 3) & 0x3u;
}

// ----------------------------------------------------------------------------
// Test 1: all-air chunk -> empty=true, 0 indices.
// ----------------------------------------------------------------------------
static void test_all_air() {
    bf::GreedyMesher gm;
    FakeChunk chunk;
    // default-initialised to 0 (all air)
    FakeStore store;
    store.target_coord = {0, 0, 0};
    store.chunk        = &chunk;

    auto r = do_mesh(gm, {0,0,0}, store);
    CHECK(r.empty,           "all-air: empty flag set");
    CHECK(r.index_count == 0,"all-air: 0 indices");
    CHECK(r.vertex_bytes == 0,"all-air: 0 vertex bytes");
}

// ----------------------------------------------------------------------------
// Test 2: single solid block -> 6 quads = 36 indices, 24 vertices.
// A block in open space: no neighbours, all AO corners = 3.
// The merge key is uniform (all corners AO=3), so greedy still merges each
// face into a single 1x1 quad.  Face count unchanged from pre-AO.
// ----------------------------------------------------------------------------
static void test_single_block() {
    bf::GreedyMesher gm;
    FakeChunk chunk;
    chunk.set(7, 7, 7, 1);   // one block in the middle

    FakeStore store;
    store.target_coord = {0, 0, 0};
    store.chunk        = &chunk;

    auto r = do_mesh(gm, {0,0,0}, store);
    CHECK(!r.empty,           "single-block: not empty");
    CHECK(r.index_count == 36,"single-block: 36 indices (6 quads * 6 idx)");
    std::uint32_t nv = r.vertex_bytes / static_cast<std::uint32_t>(sizeof(bf::BFVertex));
    CHECK(nv == 24,           "single-block: 24 vertices (6 quads * 4 verts)");

    // All vertices on an isolated block in open space must have AO == 3.
    auto* V = reinterpret_cast<const bf::BFVertex*>(g_vtx_buf.data());
    bool all_ao3 = true;
    for (std::uint32_t i = 0; i < nv; ++i) {
        if (vertex_ao(V[i]) != 3) { all_ao3 = false; break; }
    }
    CHECK(all_ao3, "single-block: all vertices have AO=3 (open space)");
}

// ----------------------------------------------------------------------------
// Test 3: full-solid 16^3 chunk -> 6 quads total (one 16x16 rect per face).
// Outer face corners look outside the chunk (all-air -> AO=3 everywhere),
// so the merge key is uniform and greedy merges each face to a single rect.
// ----------------------------------------------------------------------------
static void test_full_solid() {
    bf::GreedyMesher gm;
    FakeChunk chunk;
    chunk.fill(1);

    FakeStore store;
    store.target_coord = {0, 0, 0};
    store.chunk        = &chunk;

    auto r = do_mesh(gm, {0,0,0}, store);
    // Every interior face is culled; only the 6 outer faces remain,
    // each merged into a single 16x16 quad by the greedy algorithm.
    CHECK(!r.empty,           "full-solid: not empty");
    CHECK(r.index_count == 36,"full-solid: 36 indices (6 merged quads)");
    std::uint32_t nv = r.vertex_bytes / static_cast<std::uint32_t>(sizeof(bf::BFVertex));
    CHECK(nv == 24,           "full-solid: 24 vertices (6 merged quads * 4 verts)");
}

// ----------------------------------------------------------------------------
// Test 4: 2x1x1 pair of blocks -> 6 quads (greedy merges Y/Z faces).
//
// Blocks at (4,4,4) and (5,4,4) — adjacent along X.
// All exposed corners are in open space -> AO=3 everywhere.
// AO does not split the merge; face count unchanged from pre-AO.
//
// Face accounting per direction:
//   +X: only (5,4,4) exposes +X at x=6 (the +X face of (4,4,4) is hidden). 1 quad.
//   -X: only (4,4,4) exposes -X at x=4 (the -X face of (5,4,4) is hidden). 1 quad.
//   +Y: both expose +Y; greedy merges into one 2×1 quad.                    1 quad.
//   -Y: same as +Y.                                                          1 quad.
//   +Z: both expose +Z; greedy merges into one 2×1 quad.                    1 quad.
//   -Z: same as +Z.                                                          1 quad.
// Total: 6 quads, 36 indices, 24 vertices.
// ----------------------------------------------------------------------------
static void test_two_adjacent_blocks() {
    bf::GreedyMesher gm;
    FakeChunk chunk;
    chunk.set(4, 4, 4, 1);
    chunk.set(5, 4, 4, 1);   // adjacent along X

    FakeStore store;
    store.target_coord = {0, 0, 0};
    store.chunk        = &chunk;

    auto r = do_mesh(gm, {0,0,0}, store);
    // 2 hidden interior X faces; 4 Y/Z face pairs each greedy-merged to 1 rect.
    // Net: 6 quads.
    CHECK(!r.empty,            "two-blocks: not empty");
    CHECK(r.index_count == 36, "two-blocks: 36 indices (6 greedy quads * 6 idx)");
    std::uint32_t nv = r.vertex_bytes / static_cast<std::uint32_t>(sizeof(bf::BFVertex));
    CHECK(nv == 24,            "two-blocks: 24 vertices (6 greedy quads * 4 verts)");
}

// ----------------------------------------------------------------------------
// Test 5: tiny buffer -> no crash, no overflow, returns truncated result.
// ----------------------------------------------------------------------------
static void test_tiny_buffer_no_overflow() {
    bf::GreedyMesher gm;
    FakeChunk chunk;
    chunk.fill(1);   // full solid to maximise output

    FakeStore store;
    store.target_coord = {0, 0, 0};
    store.chunk        = &chunk;

    // Buffers too small to hold even one quad's data.
    std::byte vtx_buf[1] = {};
    std::byte idx_buf[1] = {};
    auto r = gm.mesh({0,0,0}, store,
                     {vtx_buf, sizeof(vtx_buf)},
                     {idx_buf, sizeof(idx_buf)},
                     false);
    // Must not crash and reported bytes must not exceed buffer sizes.
    CHECK(r.vertex_bytes <= sizeof(vtx_buf), "tiny-buf: vtx_bytes within span");
    CHECK(r.index_bytes  <= sizeof(idx_buf), "tiny-buf: idx_bytes within span");
}

// ----------------------------------------------------------------------------
// Test 6: max_vertex_bytes / max_index_bytes sanity.
// ----------------------------------------------------------------------------
static void test_bounds() {
    bf::GreedyMesher gm;
    CHECK(gm.max_vertex_bytes() > 0,  "bounds: max_vertex_bytes positive");
    CHECK(gm.max_index_bytes()  > 0,  "bounds: max_index_bytes positive");
    // The bounds must accommodate a full checkerboard worst case:
    // kChunkVol * 6 quads * 4 verts * 16 bytes
    std::uint32_t min_vtx = static_cast<std::uint32_t>(bf::kChunkVol) * 6u * 4u * 16u;
    std::uint32_t min_idx = static_cast<std::uint32_t>(bf::kChunkVol) * 6u * 6u * 4u;
    CHECK(gm.max_vertex_bytes() >= min_vtx, "bounds: max_vertex_bytes covers worst case");
    CHECK(gm.max_index_bytes()  >= min_idx, "bounds: max_index_bytes covers worst case");
}

// ----------------------------------------------------------------------------
// Test 7: per-vertex AO — occluded vs. open corner verification.
//
// Setup (all in chunk {0,0,0}):
//   Main block at (5,5,5) with its +X face exposed (no block at (6,5,5)).
//   Occluder blocks at (6,4,5) and (6,5,4) — both are in the AO sample plane
//   one step out along +X (x=6).
//
// For the +X face (fd.axis=0, fd.sign=+1, u_axis=1/Y, v_axis=2/Z):
//   Corners use du ∈ {-1,+1} (Y offset) and dv ∈ {-1,+1} (Z offset).
//   Sample positions are at x=6 (one step +X from block at x=5):
//
//   c0 (du=-1, dv=-1): s1=(6,4,5)=SOLID, s2=(6,5,4)=SOLID -> AO=0 (fully occ.)
//   c1 (du=+1, dv=-1): s1=(6,6,5)=air,   s2=(6,5,4)=SOLID -> AO=2
//   c2 (du=+1, dv=+1): s1=(6,6,5)=air,   s2=(6,5,6)=air, corner=(6,6,6)=air -> AO=3
//   c3 (du=-1, dv=+1): s1=(6,4,5)=SOLID, s2=(6,5,6)=air, corner=(6,4,6)=air -> AO=2
//
// The +X face will NOT merge with any of the occluder block faces because the
// occluders are separate solid blocks with different positions and AO values.
//
// For validation: scan all emitted vertices and find those on the +X face of
// block (5,5,5).  The vertex at world position (6,5,5) — the corner c0 in 3D
// (face_d=6, u=5/Y, v=5/Z) — should have AO=0.  The corner at (6,6,6) should
// have AO=3.
//
// Additionally: a +Z face of the main block (5,5,5) should have all AO=3 since
// no blocks are placed in the z+1=6 plane in the u/v tangent directions.
// ----------------------------------------------------------------------------
static void test_ao_occluded_corners() {
    bf::GreedyMesher gm;
    FakeChunk chunk;

    // Main block.
    chunk.set(5, 5, 5, 1);

    // Occluders at x=6 (one step +X from (5,5,5)).
    // These make the lower-left corner of the +X face of (5,5,5) fully occluded.
    chunk.set(6, 4, 5, 1);  // s1 for c0 (Y side, du=-1)
    chunk.set(6, 5, 4, 1);  // s2 for c0 (Z side, dv=-1)

    FakeStore store;
    store.target_coord = {0, 0, 0};
    store.chunk        = &chunk;

    auto r = do_mesh(gm, {0,0,0}, store);
    CHECK(!r.empty, "ao-test: mesh not empty");

    auto* V = reinterpret_cast<const bf::BFVertex*>(g_vtx_buf.data());
    auto* I = reinterpret_cast<const std::uint32_t*>(g_idx_buf.data());
    std::uint32_t nv = r.vertex_bytes / static_cast<std::uint32_t>(sizeof(bf::BFVertex));

    // Helper: unpack vertex position.
    auto vx = [](const bf::BFVertex& v){ return int(v.pos_packed & 0x3Fu); };
    auto vy = [](const bf::BFVertex& v){ return int((v.pos_packed >> 6) & 0x3Fu); };
    auto vz = [](const bf::BFVertex& v){ return int((v.pos_packed >> 12) & 0x3Fu); };
    auto vn = [](const bf::BFVertex& v){ return v.normal_uv & 0x7u; }; // BFNormal code

    // BF_NX_POS=0, BF_NZ_POS=4
    constexpr std::uint32_t NX_POS = 0u;
    constexpr std::uint32_t NZ_POS = 4u;

    // Scan vertices: find those belonging to the +X face of (5,5,5).
    // The +X face of block (5,5,5) has face_d=6 -> x=6, and the 4 corners span
    // y ∈ {5,6}, z ∈ {5,6} (block occupies y=5..6, z=5..6 in corner space).
    // (Remember: vertex positions are block-corner coords; block at cell (5,5,5)
    //  has corners at y=5 and y=6, z=5 and z=6.)
    bool found_occ  = false;  // corner at (x=6, y=5, z=5): expected AO=0
    bool found_open = false;  // corner at (x=6, y=6, z=6): expected AO=3

    for (std::uint32_t i = 0; i < nv; ++i) {
        const bf::BFVertex& v = V[i];
        if (vn(v) != NX_POS) continue;            // only +X face
        int x = vx(v), y = vy(v), z = vz(v);
        if (x != 6) continue;                      // only at face_d=6

        // The +X face quad of block (5,5,5): corners at y∈{5,6}, z∈{5,6}.
        if (y == 5 && z == 5) {
            // This is corner c0: should be AO=0 (fully occluded).
            std::uint32_t ao = vertex_ao(v);
            CHECK(ao == 0, "ao-test: corner (6,5,5) on +X face of (5,5,5) has AO=0");
            found_occ = true;
        }
        if (y == 6 && z == 6) {
            // This is corner c2: should be AO=3 (open).
            std::uint32_t ao = vertex_ao(v);
            CHECK(ao == 3, "ao-test: corner (6,6,6) on +X face of (5,5,5) has AO=3");
            found_open = true;
        }
    }
    CHECK(found_occ,  "ao-test: found occluded corner vertex on +X face");
    CHECK(found_open, "ao-test: found open corner vertex on +X face");

    // Verify the +Z face of (5,5,5) has all AO=3 (no blocks at z=6).
    // The +Z face is at z=6, with corners at x∈{5,6}, y∈{5,6}.
    bool zface_all_open = true;
    for (std::uint32_t i = 0; i < nv; ++i) {
        const bf::BFVertex& v = V[i];
        if (vn(v) != NZ_POS) continue;
        int x = vx(v), y = vy(v), z = vz(v);
        if (x < 5 || x > 6 || y < 5 || y > 6 || z != 6) continue; // +Z face of (5,5,5)
        if (vertex_ao(v) != 3) { zface_all_open = false; break; }
    }
    CHECK(zface_all_open, "ao-test: +Z face of (5,5,5) has all AO=3 (open face)");

    // Winding sanity: every triangle must be front-facing (cross product dot normal > 0).
    auto px = [](const bf::BFVertex& v){ return float(v.pos_packed & 0x3Fu); };
    auto py = [](const bf::BFVertex& v){ return float((v.pos_packed >> 6) & 0x3Fu); };
    auto pz = [](const bf::BFVertex& v){ return float((v.pos_packed >> 12) & 0x3Fu); };
    const float normals[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
    int wrong = 0;
    for (std::uint32_t t = 0; t < r.index_count; t += 3) {
        const bf::BFVertex& a = V[I[t]], &b = V[I[t+1]], &c = V[I[t+2]];
        float e1[3] = {px(b)-px(a), py(b)-py(a), pz(b)-pz(a)};
        float e2[3] = {px(c)-px(a), py(c)-py(a), pz(c)-pz(a)};
        float cr[3] = {e1[1]*e2[2]-e1[2]*e2[1],
                       e1[2]*e2[0]-e1[0]*e2[2],
                       e1[0]*e2[1]-e1[1]*e2[0]};
        std::uint32_t nc = a.normal_uv & 0x7u;
        if (cr[0]*normals[nc][0] + cr[1]*normals[nc][1] + cr[2]*normals[nc][2] <= 0)
            ++wrong;
    }
    CHECK(wrong == 0, "ao-test: all triangles front-facing after AO flip-quad");
}

// ----------------------------------------------------------------------------
// Test 8: water transparency — solid block adjacent to water emits a face on
// the water-facing side (the previously-broken case).
//
// Setup:
//   Solid block (id=1) at (7,7,7).
//   Water block (id=9) at (8,7,7) — neighbour in +X direction.
//
// Before the fix: the mesher treated water as solid, so the +X face of (7,7,7)
// was suppressed (both sides occupied).  Now water is NON-opaque, so the solid
// block MUST emit a +X face.
//
// Additionally:
//   Water vs air: the water block at (8,7,7) has no block on its +X side (9,7,7)
//   is air, so the water's +X surface face MUST be emitted.
//
//   Water vs water: add a second water block at (9,7,7). The shared X-face
//   between (8,7,7) and (9,7,7) must NOT be emitted (water-against-water
//   produces no face).
//
//   Water vs solid: the -X face of the water block (8,7,7) borders the solid
//   block at (7,7,7). The water must NOT emit a -X face there (solid already
//   drew the wall; no double-draw).
//
// Face accounting for the final scene {solid(7,7,7), water(8,7,7), water(9,7,7)}:
//   solid(7,7,7) — 6 faces, all neighbours air EXCEPT +X which is water:
//     +X: neighbour=water -> non-opaque -> emit.          (1)
//     -X,-Y,+Y,-Z,+Z: neighbours=air -> emit.             (5)
//     Total solid quads: 6.
//   water(8,7,7) — only emits where neighbour is AIR:
//     -X: neighbour=solid(7,7,7) -> NOT air -> NO emit.
//     +X: neighbour=water(9,7,7) -> NOT air -> NO emit.
//     -Y,+Y,-Z,+Z: neighbours=air -> would emit 4, BUT greedy merges
//       each direction with the identical cell on water(9,7,7) into one
//       2×1 quad.  So these 4 directions yield 4 merged quads total.
//     Total water quads (both cells combined): 4 merged + 1 (+X of @9 vs air) = 5.
//   water(9,7,7) — only emits where neighbour is AIR:
//     -X: neighbour=water(8,7,7) -> NOT air -> NO emit.
//     +X: neighbour=air -> emit (1, NOT merged because @8 has no +X face).
//     -Y,+Y,-Z,+Z: merged with @8 above.
//   Grand total quads: 6 (solid) + 4 (merged water Y/Z) + 1 (water +X vs air)
//                    = 11 quads, indices = 11*6 = 66, vertices = 11*4 = 44.
// ----------------------------------------------------------------------------
static void test_water_transparency() {
    bf::GreedyMesher gm;
    FakeChunk chunk;
    chunk.set(7, 7, 7, 1);  // solid block
    chunk.set(8, 7, 7, 9);  // water block adjacent in +X
    chunk.set(9, 7, 7, 9);  // second water block (water-against-water)

    FakeStore store;
    store.target_coord = {0, 0, 0};
    store.chunk        = &chunk;

    auto r = do_mesh(gm, {0,0,0}, store);
    CHECK(!r.empty, "water: mesh not empty");

    // Total should be 11 quads = 66 indices, 44 vertices.
    // 6 solid faces + 4 greedy-merged water Y/Z faces + 1 water +X vs air.
    CHECK(r.index_count == 66, "water: 66 indices (11 quads: 6 solid + 4 merged water-YZ + 1 water-airX)");
    std::uint32_t nv = r.vertex_bytes / static_cast<std::uint32_t>(sizeof(bf::BFVertex));
    CHECK(nv == 44, "water: 44 vertices (11 quads * 4 verts)");

    // Unpack helpers.
    auto* V = reinterpret_cast<const bf::BFVertex*>(g_vtx_buf.data());
    auto vx = [](const bf::BFVertex& v){ return int(v.pos_packed & 0x3Fu); };
    auto vy = [](const bf::BFVertex& v){ return int((v.pos_packed >> 6) & 0x3Fu); };
    auto vz = [](const bf::BFVertex& v){ return int((v.pos_packed >> 12) & 0x3Fu); };
    auto vn = [](const bf::BFVertex& v){ return v.normal_uv & 0x7u; };

    // BF_NX_POS=0, BF_NX_NEG=1
    constexpr std::uint32_t NX_POS = 0u;
    constexpr std::uint32_t NX_NEG = 1u;

    // Extract material from vertex (bits 16..31 of normal_uv, or separate field).
    // BFVertex layout: we need to check which face belongs to the solid vs water.
    // We can identify by checking which vertex positions map to the water block's
    // face.  The solid block +X face has face_d=8 (x=8), y in {7,8}, z in {7,8}.
    // The water -X face (if wrongly emitted) would also be at x=8.
    // The water +X face of (8,7,7) vs water(9,7,7): face_d=9 (x=9), same y/z range.

    // Assert: solid block emits a +X face (face at x=8, y∈{7,8}, z∈{7,8}).
    bool solid_plus_x = false;
    for (std::uint32_t i = 0; i < nv; ++i) {
        if (vn(V[i]) != NX_POS) continue;
        if (vx(V[i]) == 8 && vy(V[i]) >= 7 && vy(V[i]) <= 8 && vz(V[i]) >= 7 && vz(V[i]) <= 8) {
            solid_plus_x = true; break;
        }
    }
    CHECK(solid_plus_x, "water: solid block emits +X face into water neighbour");

    // Assert: water-against-water does NOT produce an internal face.
    // The shared face would be at x=9 (face_d for +X of water@8) pointing +X,
    // but the neighbour is water so no face should be there from water@8.
    // More directly: water@9 has its -X face at x=9 pointing -X (NX_NEG).
    // That should NOT appear because its neighbour is water@8 (not air).
    bool water_water_internal = false;
    for (std::uint32_t i = 0; i < nv; ++i) {
        if (vn(V[i]) != NX_NEG) continue;
        // -X face of water@9 would be at x=9, y∈{7,8}, z∈{7,8}.
        if (vx(V[i]) == 9 && vy(V[i]) >= 7 && vy(V[i]) <= 8 && vz(V[i]) >= 7 && vz(V[i]) <= 8) {
            water_water_internal = true; break;
        }
    }
    CHECK(!water_water_internal, "water: water-against-water does not emit internal face");

    // Assert: water does NOT emit a face where it borders the solid block.
    // That would be the -X face of water@8 at x=8 pointing -X (NX_NEG).
    bool water_solid_double = false;
    for (std::uint32_t i = 0; i < nv; ++i) {
        if (vn(V[i]) != NX_NEG) continue;
        // -X face of water@8 would be at x=8, y∈{7,8}, z∈{7,8}.
        if (vx(V[i]) == 8 && vy(V[i]) >= 7 && vy(V[i]) <= 8 && vz(V[i]) >= 7 && vz(V[i]) <= 8) {
            water_solid_double = true; break;
        }
    }
    CHECK(!water_solid_double, "water: water does not double-emit face against solid block");

    // Assert: water surface vs air IS emitted: water@9 +X face at x=10, y/z∈{7,8}.
    bool water_air_surface = false;
    for (std::uint32_t i = 0; i < nv; ++i) {
        if (vn(V[i]) != NX_POS) continue;
        if (vx(V[i]) == 10 && vy(V[i]) >= 7 && vy(V[i]) <= 8 && vz(V[i]) >= 7 && vz(V[i]) <= 8) {
            water_air_surface = true; break;
        }
    }
    CHECK(water_air_surface, "water: water emits surface face against air");
}

// ----------------------------------------------------------------------------
// Test 9: sub-voxel prop block emits NO mesher geometry but stays non-occluding.
//
// A single tall_grass block (id=38) at (4,4,4) in an otherwise-air chunk. Grass
// is now a sub-voxel prop (#52): the renderer draws it as an instanced 3D tuft,
// so the MESHER emits nothing for the plant cell itself.
//
// A solid block at (5,4,4) adjacent to the plant must still emit its -X face
// (the face toward x=4 where the plant is), because the prop is non-opaque. The
// solid block with no other neighbours emits 6 cube faces, so total = 6 quads
// (solid) + 0 (plant) = 36 indices, 24 vertices.
//
// AO: the plant must NOT occlude the AO of its solid neighbour. All 4 AO corners
// of the solid -X face must be 3.
// ----------------------------------------------------------------------------
static void test_cross_plant() {
    bf::GreedyMesher gm;
    FakeChunk chunk;
    chunk.set(4, 4, 4, 38);  // tall_grass (now a sub-voxel prop)
    chunk.set(5, 4, 4, 1);   // solid block adjacent in +X direction

    FakeStore store;
    store.target_coord = {0, 0, 0};
    store.chunk        = &chunk;

    auto r = do_mesh(gm, {0,0,0}, store);
    CHECK(!r.empty, "plant: mesh not empty");

    // 6 solid cube quads + 0 plant quads (prop emits no mesher geometry).
    CHECK(r.index_count == 36, "plant: 36 indices (6 solid quads * 6 idx each)");
    std::uint32_t nv = r.vertex_bytes / static_cast<std::uint32_t>(sizeof(bf::BFVertex));
    CHECK(nv == 24, "plant: 24 vertices (6 quads * 4 verts)");

    // Verify: the prop cell emits NO geometry — zero verts carry material_id 38.
    auto* V = reinterpret_cast<const bf::BFVertex*>(g_vtx_buf.data());
    int plant_verts = 0;
    for (std::uint32_t i = 0; i < nv; ++i) {
        if (V[i].material_id == 38) ++plant_verts;
    }
    CHECK(plant_verts == 0, "plant: prop block emits no mesher geometry (0 verts mat_id=38)");

    // Verify: solid block still emits a face toward the plant.
    // The -X face of solid(5,4,4) has face_d=5 (x=5), normal BF_NX_NEG(=1),
    // corners at y∈{4,5}, z∈{4,5}.
    auto vx = [](const bf::BFVertex& v){ return int(v.pos_packed & 0x3Fu); };
    auto vy = [](const bf::BFVertex& v){ return int((v.pos_packed >> 6) & 0x3Fu); };
    auto vz = [](const bf::BFVertex& v){ return int((v.pos_packed >> 12) & 0x3Fu); };
    auto vn = [](const bf::BFVertex& v){ return v.normal_uv & 0x7u; };

    constexpr std::uint32_t NX_NEG = 1u;
    bool solid_minus_x = false;
    for (std::uint32_t i = 0; i < nv; ++i) {
        if (vn(V[i]) != NX_NEG) continue;
        if (vx(V[i]) == 5 && vy(V[i]) >= 4 && vy(V[i]) <= 5 && vz(V[i]) >= 4 && vz(V[i]) <= 5) {
            solid_minus_x = true; break;
        }
    }
    CHECK(solid_minus_x, "plant: solid block emits -X face into plant neighbour");

    // Verify: plant does not occlude AO of solid neighbour's -X face.
    // All 4 corners of that -X face must have AO=3.
    // The -X face of solid(5,4,4) has vertices at x=5, y∈{4,5}, z∈{4,5}.
    // material_id for the solid block is 1.
    bool neg_x_all_ao3 = true;
    for (std::uint32_t i = 0; i < nv; ++i) {
        const bf::BFVertex& v = V[i];
        if (vn(v) != NX_NEG) continue;
        if (v.material_id != 1) continue;
        if (vx(v) == 5 && vy(v) >= 4 && vy(v) <= 5 && vz(v) >= 4 && vz(v) <= 5) {
            if (vertex_ao(v) != 3) { neg_x_all_ao3 = false; break; }
        }
    }
    CHECK(neg_x_all_ao3, "plant: plant does not occlude AO of adjacent solid block");
}

int main() {
    test_all_air();
    test_single_block();
    test_full_solid();
    test_two_adjacent_blocks();
    test_tiny_buffer_no_overflow();
    test_bounds();
    test_ao_occluded_corners();
    test_water_transparency();
    test_cross_plant();

    if (fails == 0) std::printf("OK: mesher tests\n");
    return fails == 0 ? 0 : 1;
}
