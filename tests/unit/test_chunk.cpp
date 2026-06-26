// Track B — palette chunk + store tests: round-trip, palette growth, uniform
// fast path, lossless serialize/deserialize. Framework-free.
#include "blockcore/chunk.hpp"

#include <cstdio>
#include <vector>
#include <random>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

using namespace bf;

static void test_uniform() {
    PaletteChunk ch(ChunkCoord{0,0,0}, 0);
    CHECK(ch.is_uniform(), "fresh air chunk is uniform");
    CHECK(ch.get(3,4,5) == 0, "uniform reads fill");
    ch.set(1,1,1, 0);   // setting fill keeps uniform
    CHECK(ch.is_uniform(), "set-to-fill stays uniform");
    ch.set(2,2,2, 7);
    CHECK(!ch.is_uniform(), "non-fill set leaves uniform");
    CHECK(ch.get(2,2,2) == 7, "reads back set block");
    CHECK(ch.get(0,0,0) == 0, "neighbors still air");
}

static void test_palette_growth() {
    PaletteChunk ch(ChunkCoord{1,2,3}, 0);
    // Write 300 distinct block ids -> palette must cross 1->2->4->8->16 bits.
    for (int i = 0; i < 300; ++i) {
        int x = i % 16, y = (i / 16) % 16, z = (i / 256) % 16;
        ch.set(x, y, z, BlockId(i + 1));
    }
    int bad = 0;
    for (int i = 0; i < 300; ++i) {
        int x = i % 16, y = (i / 16) % 16, z = (i / 256) % 16;
        if (ch.get(x, y, z) != BlockId(i + 1)) ++bad;
    }
    CHECK(bad == 0, "palette growth preserves all values across bit-width changes");
    CHECK(ch.bits_per_index() >= 8, "bits grew to hold 300 palette entries");
}

static void test_roundtrip() {
    PaletteChunk ch(ChunkCoord{-5, 7, 12}, 0);
    std::mt19937 rng(42);
    for (int n = 0; n < 1000; ++n) {
        int x = int(rng() % 16), y = int(rng() % 16), z = int(rng() % 16);
        ch.set(x, y, z, BlockId(rng() % 40));
    }
    std::vector<std::byte> buf(64 * 1024);
    std::size_t n = ch.serialize(buf);
    CHECK(n > 0, "serialize succeeds");
    auto restored = PaletteChunk::deserialize(std::span<const std::byte>(buf.data(), n));
    CHECK(restored != nullptr, "deserialize succeeds");
    int bad = 0;
    for (int z = 0; z < 16; ++z) for (int y = 0; y < 16; ++y) for (int x = 0; x < 16; ++x)
        if (ch.get(x,y,z) != restored->get(x,y,z)) ++bad;
    CHECK(bad == 0, "serialize->deserialize is lossless (byte-identical world)");
    CHECK(restored->revision() == ch.revision(), "revision survives round-trip");

    // Serialize the restored copy and compare bytes: must be identical.
    std::vector<std::byte> buf2(64 * 1024);
    std::size_t n2 = restored->serialize(buf2);
    CHECK(n2 == n && std::memcmp(buf.data(), buf2.data(), n) == 0, "byte-identical re-serialize");
}

static void test_store() {
    ChunkStore store;
    CHECK(store.get(ChunkCoord{0,0,0}) == nullptr, "empty store: not resident");
    auto* c = static_cast<PaletteChunk*>(store.get_or_create(ChunkCoord{0,0,0}));
    c->set(8,0,8, 3);
    CHECK(store.is_resident(ChunkCoord{0,0,0}), "created chunk resident");
    // Round-trip via the chunk's own serialize/deserialize (the path the save uses).
    std::vector<std::byte> buf(64 * 1024);
    std::size_t n = c->serialize(buf);
    CHECK(n > 0, "chunk serialize");
    auto c2 = PaletteChunk::deserialize(std::span<const std::byte>(buf.data(), n));
    CHECK(c2 && c2->get(8,0,8) == 3, "chunk round-trip value");
    store.evict(ChunkCoord{0,0,0});
    CHECK(!store.is_resident(ChunkCoord{0,0,0}), "evict removes");
}

int main() {
    test_uniform();
    test_palette_growth();
    test_roundtrip();
    test_store();
    if (fails == 0) std::printf("OK: chunk storage tests\n");
    return fails == 0 ? 0 : 1;
}
