// M2 — save/load round-trip. Edit a procedural world, save, load into a fresh
// World, and verify edits + player state survive (only edited chunks persist;
// procedural chunks regen from the seed).
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"
#include "blockcore/worldgen.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static bf_gpu_buffer alloc_fn(void*, uint32_t b) {
    void* p = std::malloc(b ? b : 16);
    bf_gpu_buffer r{}; r.handle = reinterpret_cast<uint64_t>(p); r.contents = p; r.bytes = b; return r;
}
static void free_fn(void*, uint64_t h) { std::free(reinterpret_cast<void*>(h)); }

int main() {
    std::string dir = (std::filesystem::temp_directory_path() / "bf_saveload_test").string();
    std::filesystem::remove_all(dir);

    bf_gpu_allocator alloc{}; alloc.alloc = alloc_fn; alloc.free_ = free_fn;

    // --- session 1: generate, edit at known spots, save ---
    {
        bf::GreedyMesher mesher; bf::TerrainGen gen; bf::World world(mesher, &gen);
        world.set_allocator(alloc);
        world.init_world(424242);
        world.debug_edit(3, 70, 3, bf::GLOW);       // high up: air -> GLOW
        world.debug_edit(4, 70, 3, bf::BRICK);
        world.debug_edit(3, 70, 4, bf::AIR);        // a dug-out edit (air override)
        CHECK(world.save(dir), "save succeeded");
    }

    // --- session 2: load into fresh world, verify ---
    {
        bf::GreedyMesher mesher; bf::TerrainGen gen; bf::World world(mesher, &gen);
        world.set_allocator(alloc);
        CHECK(world.load(dir), "load succeeded");
        CHECK(world.debug_block_at(3, 70, 3) == bf::GLOW,  "edited GLOW persisted");
        CHECK(world.debug_block_at(4, 70, 3) == bf::BRICK, "edited BRICK persisted");
        CHECK(world.debug_block_at(3, 70, 4) == bf::AIR,   "dug-out edit persisted");
        // The spawn region restoration persisted (sat == 1 at region 0,0).
        CHECK(world.debug_region_sat(0, 0) > 0.9f, "restored spawn region persisted");
        // The world is deterministic: regenerate the same seed in a 3rd world and
        // confirm a sampled procedural column matches (edits aside).
        bf::GreedyMesher m3; bf::TerrainGen g3; bf::World w3(m3, &g3);
        w3.set_allocator(alloc); w3.init_world(424242);
        bf_frame_input zero{};
        for (int i = 0; i < 20; ++i) { w3.update(zero, 0.016); world.update(zero, 0.016); }
        int matches = 0, total = 0;
        for (int x = 0; x < 8; ++x) for (int z = 0; z < 8; ++z) {
            for (int y = 0; y < 20; ++y) {
                ++total;
                if (w3.debug_block_at(x, y, z) == world.debug_block_at(x, y, z)) ++matches;
            }
        }
        CHECK(matches == total, "loaded procedural terrain matches a fresh same-seed gen");
    }

    std::filesystem::remove_all(dir);
    if (fails == 0) std::printf("OK: save/load round-trip\n");
    return fails == 0 ? 0 : 1;
}
