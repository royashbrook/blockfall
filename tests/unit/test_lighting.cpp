// Track F — lighting: sky light with hard shadow under a roof, and block light
// spreading from an emitter. Single-chunk (cross-chunk bleed is exercised by
// the streaming World; here we pin down the core flood-fill values).
#include "blockcore/lighting.hpp"
#include "blockcore/chunk.hpp"

#include <cstdio>

using namespace bf;

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static constexpr BlockId STONE = 3, GLOW = 7;   // mirror M1Block ids

int main() {
    ChunkStore store;
    auto* ch = static_cast<PaletteChunk*>(store.get_or_create(ChunkCoord{0,0,0}));
    // Floor: solid stone y=0..6, air above.
    for (int x = 0; x < 16; ++x) for (int z = 0; z < 16; ++z)
        for (int y = 0; y <= 6; ++y) ch->set(x, y, z, STONE);
    // A full roof slab at y=12 -> everything between floor and roof is shadowed.
    for (int x = 0; x < 16; ++x) for (int z = 0; z < 16; ++z) ch->set(x, 12, z, STONE);
    // A glow block sitting on the floor.
    ch->set(4, 7, 4, GLOW);

    FloodLighting::light_chunk(ChunkCoord{0,0,0}, store);

    // Sky: an air cell above the roof, open to sky, is fully lit.
    CHECK(ch->sky_light(8, 14, 8) == 15, "open air above roof is full skylight");
    // Sky: air under the full roof gets no direct sun (hard shadow).
    CHECK(ch->sky_light(8, 9, 8) == 0, "roofed air is in shadow (sky 0)");
    // Block light: the air cell directly above the glow block is bright.
    CHECK(ch->block_light(4, 8, 4) >= 13, "air above glow is brightly block-lit");
    // Block light falls off with distance.
    std::uint8_t near_b = ch->block_light(5, 8, 4);
    std::uint8_t far_b  = ch->block_light(9, 8, 4);
    CHECK(near_b > far_b, "block light attenuates with distance");
    CHECK(far_b < near_b && far_b <= 13, "distant block light is dimmer");

    if (fails == 0) std::printf("OK: lighting (sky shadow + block falloff)\n");
    return fails == 0 ? 0 : 1;
}
