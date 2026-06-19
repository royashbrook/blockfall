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
    bf::ChunkCoord target_coord{};
    FakeChunk*     chunk{nullptr};

    bf::IChunk* get(bf::ChunkCoord c) override {
        if (c.x == target_coord.x && c.y == target_coord.y && c.z == target_coord.z)
            return chunk;
        return nullptr;
    }
    bf::IChunk* get_or_create(bf::ChunkCoord c) override { return get(c); }
    void        evict(bf::ChunkCoord)              override {}
    bool        is_resident(bf::ChunkCoord c) const override {
        return c.x == target_coord.x && c.y == target_coord.y && c.z == target_coord.z;
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
static bf::MeshResult do_mesh(bf::GreedyMesher& gm, bf::ChunkCoord cc, bf::IChunkStore& store) {
    static std::vector<std::byte> vtx_buf(bf::GreedyMesher::kMaxVertexBytes);
    static std::vector<std::byte> idx_buf(bf::GreedyMesher::kMaxIndexBytes);
    return gm.mesh(cc, store, {vtx_buf.data(), vtx_buf.size()}, {idx_buf.data(), idx_buf.size()}, false);
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
}

// ----------------------------------------------------------------------------
// Test 3: full-solid 16^3 chunk -> 6 quads total (one 16x16 rect per face).
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

int main() {
    test_all_air();
    test_single_block();
    test_full_solid();
    test_two_adjacent_blocks();
    test_tiny_buffer_no_overflow();
    test_bounds();

    if (fails == 0) std::printf("OK: mesher tests\n");
    return fails == 0 ? 0 : 1;
}
