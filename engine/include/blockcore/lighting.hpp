// ============================================================================
// Blockfall — Track F: lighting (engine/include/blockcore/lighting.hpp)
// Flood-fill sky + block light for one chunk, seeded from neighbour chunks so
// light bleeds across boundaries (the World re-dirties neighbours when a
// boundary value changes, so it settles over a few frames — incremental on
// edit). Writes per-voxel light into the chunk (ADR 0004); the mesher reads
// the air cell adjacent to each face. See contract/blockcore_interfaces.hpp.
//
// Sky light falls straight down at 15 through air until it hits an opaque
// block (hard shadow), then spreads horizontally at -1 per step. Block light
// BFS-spreads from emitters (e.g. glow blocks). Transparent blocks (water)
// pass light.
// ============================================================================
#pragma once
#include "blockcore_interfaces.hpp"
#include "blockcore/chunk.hpp"

#include <cstdint>
#include <vector>
#include <array>

namespace bf {

// Block ids relevant to lighting (mirror M1Block; kept local to avoid a
// circular include with world.hpp).
inline constexpr BlockId LIGHT_AIR = 0, LIGHT_WATER = 9, LIGHT_GLOW = 7;

// Sub-voxel props (flowers 36/37, tall grass 38, mushroom 39, color crystal 40,
// pebble 41, berry bush 42) are little models, not solid cubes — light passes
// through them so their cell stays lit and the block beneath/beside isn't black.
// Props (36-47) plus tree TRUNKS (oak 21, birch 22) are light-transparent here so a
// trunk base does not black out the ground block it sits on (#62, same fix as pebbles).
// Leaves stay opaque so the canopy still casts dappled shade.
inline bool light_plant(BlockId b) { return (b >= 36 && b <= 47) || b == 21 || b == 22 || b == 49; }
// Glass (25, 26) is see-through, so light passes through it too (#68).
inline bool light_glass(BlockId b) { return b == 25 || b == 26; }
inline bool light_opaque(BlockId b) { return b != LIGHT_AIR && b != LIGHT_WATER && !light_glass(b) && !light_plant(b); }
// Block light emitters (values mirror content/blocks/*.json light_emit). Without
// torch/beacon/lamp here, placing a torch underground did nothing — light blocks
// were purely decorative. (Ids: glow_block 7, torch 32, beacon_block 34, lamp 35.)
inline std::uint8_t light_emit(BlockId b) {
    switch (b) {
        case LIGHT_GLOW: return std::uint8_t(14);   // glow_block (id 7)
        case 32:         return std::uint8_t(14);   // torch
        case 34:         return std::uint8_t(15);   // beacon_block
        case 35:         return std::uint8_t(15);   // crystal_lamp
        case 40:         return std::uint8_t(8);    // color_crystal (was emitting 0 — content says 8)
        default:         return std::uint8_t(0);
    }
}

class FloodLighting {
public:
    // Recompute light for chunk `cc` (must be resident). Returns true if any
    // boundary light value changed vs the chunk's previous light (so the World
    // knows to re-dirty neighbours for cross-chunk propagation).
    //
    // KNOWN LIMITATION (light *removal* latency): this is an increase-only
    // flood-fill — it re-seeds a chunk from its own sources plus neighbours'
    // CURRENT stored light. When a light source is removed (or sky is newly
    // blocked) right at a chunk seam, the neighbour's still-stale boundary value
    // gets re-injected, so the pair converges to the correct (darker) result over
    // ~8 dirty cycles (~130 ms at 60fps) rather than instantly. It always reaches
    // the correct value and is purely cosmetic. A one-pass fix needs a store-level
    // removal BFS (Minecraft's two-queue add/remove) that crosses chunk
    // boundaries — deliberately deferred as a careful, separately-tested change
    // rather than a risky rewrite of the core propagation here.
    // Returns a 6-bit mask of which BOUNDARY FACES changed (bit order matches the
    // {+x,-x,+y,-y,+z,-z} neighbour dirs). The caller re-dirties only the neighbours
    // across changed faces — re-dirtying all 6 on any change caused a 6x churn that
    // never let the light wave settle. (#5)
    static std::uint8_t light_chunk(ChunkCoord cc, IChunkStore& store) {
        IChunk* chunk = store.get(cc);
        if (!chunk) return 0;
        constexpr int N = kChunkDim;

        std::array<std::uint8_t, kChunkVol> sky{};   // 0-init
        std::array<std::uint8_t, kChunkVol> blk{};
        auto idx = [](int x, int y, int z) { return x + N * (y + N * z); };

        // ---- sky: direct vertical sunlight + hard shadow --------------------
        std::vector<int> q; q.reserve(512);
        for (int x = 0; x < N; ++x)
        for (int z = 0; z < N; ++z) {
            std::uint8_t s = column_open(cc, x, z, store) ? std::uint8_t(15) : std::uint8_t(0);
            for (int y = N - 1; y >= 0; --y) {
                BlockId b = chunk->get(x, y, z);
                if (light_opaque(b)) s = 0;
                else { sky[std::size_t(idx(x, y, z))] = s; if (s > 1) q.push_back(idx(x, y, z)); }
            }
        }
        seed_neighbours(cc, store, sky, /*is_sky=*/true, q, idx);
        bfs(chunk, sky, q, idx);

        // ---- block light: emitters + neighbour bleed ------------------------
        q.clear();
        for (int x = 0; x < N; ++x) for (int y = 0; y < N; ++y) for (int z = 0; z < N; ++z) {
            std::uint8_t e = light_emit(chunk->get(x, y, z));
            if (e > 0) { blk[std::size_t(idx(x, y, z))] = e; q.push_back(idx(x, y, z)); }
        }
        seed_neighbours(cc, store, blk, /*is_sky=*/false, q, idx);
        bfs(chunk, blk, q, idx);

        // ---- write back, detect boundary change -----------------------------
        std::uint8_t changedFaces = 0;
        for (int x = 0; x < N; ++x) for (int y = 0; y < N; ++y) for (int z = 0; z < N; ++z) {
            std::size_t i = std::size_t(idx(x, y, z));
            if (on_boundary(x, y, z)) {
                if (chunk->sky_light(x, y, z) != sky[i] || chunk->block_light(x, y, z) != blk[i]) {
                    if (x == N-1) changedFaces |= std::uint8_t(1u << 0);   // +x
                    if (x == 0)   changedFaces |= std::uint8_t(1u << 1);   // -x
                    if (y == N-1) changedFaces |= std::uint8_t(1u << 2);   // +y
                    if (y == 0)   changedFaces |= std::uint8_t(1u << 3);   // -y
                    if (z == N-1) changedFaces |= std::uint8_t(1u << 4);   // +z
                    if (z == 0)   changedFaces |= std::uint8_t(1u << 5);   // -z
                }
            }
            chunk->set_light(x, y, z, sky[i], blk[i]);
        }
        return changedFaces;
    }

private:
    static bool on_boundary(int x, int y, int z) {
        return x == 0 || y == 0 || z == 0 || x == kChunkDim-1 || y == kChunkDim-1 || z == kChunkDim-1;
    }

    // Is the world column above (x,z) of chunk cc clear of opaque blocks
    // (i.e. open to the sky)? Walks up through resident chunks.
    static bool column_open(ChunkCoord cc, int x, int z, IChunkStore& store) {
        for (int cy = cc.y + 1; cy <= cc.y + 8; ++cy) {
            IChunk* above = store.get(ChunkCoord{cc.x, cy, cc.z});
            if (!above) return true;                 // nothing resident above -> sky
            for (int y = 0; y < kChunkDim; ++y)
                if (light_opaque(above->get(x, y, z))) return false;
        }
        return true;
    }

    // Seed this chunk's boundary cells from already-lit neighbour chunks: a
    // neighbour's edge light enters at -1, so light bleeds across the seam.
    template <class Idx>
    static void seed_neighbours(ChunkCoord cc, IChunkStore& store,
                                std::array<std::uint8_t, kChunkVol>& lvl,
                                bool is_sky, std::vector<int>& q, Idx idx) {
        constexpr int N = kChunkDim;
        const IVec3 dirs[6] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
        for (auto d : dirs) {
            IChunk* nb = store.get(ChunkCoord{cc.x + d.x, cc.y + d.y, cc.z + d.z});
            if (!nb) continue;
            for (int a = 0; a < N; ++a) for (int b = 0; b < N; ++b) {
                int x, y, z, nx, ny, nz;     // our boundary cell + neighbour's adjacent cell
                if (d.x != 0)      { x = d.x > 0 ? N-1 : 0; nx = d.x > 0 ? 0 : N-1; y = ny = a; z = nz = b; }
                else if (d.y != 0) { y = d.y > 0 ? N-1 : 0; ny = d.y > 0 ? 0 : N-1; x = nx = a; z = nz = b; }
                else               { z = d.z > 0 ? N-1 : 0; nz = d.z > 0 ? 0 : N-1; x = nx = a; y = ny = b; }
                std::uint8_t nv = is_sky ? nb->sky_light(nx, ny, nz) : nb->block_light(nx, ny, nz);
                if (nv > 1) {
                    std::size_t i = std::size_t(idx(x, y, z));
                    std::uint8_t want = std::uint8_t(nv - 1);
                    if (want > lvl[i]) { lvl[i] = want; q.push_back(idx(x, y, z)); }
                }
            }
        }
    }

    template <class Idx>
    static void bfs(IChunk* chunk, std::array<std::uint8_t, kChunkVol>& lvl,
                    std::vector<int>& q, Idx idx) {
        constexpr int N = kChunkDim;
        const int dx[6] = {1,-1,0,0,0,0}, dy[6] = {0,0,1,-1,0,0}, dz[6] = {0,0,0,0,1,-1};
        std::size_t head = 0;
        while (head < q.size()) {
            int packed = q[head++];
            int x = packed % N, y = (packed / N) % N, z = packed / (N * N);
            std::uint8_t l = lvl[std::size_t(idx(x, y, z))];
            if (l <= 1) continue;
            for (int k = 0; k < 6; ++k) {
                int nx = x + dx[k], ny = y + dy[k], nz = z + dz[k];
                if (nx < 0 || ny < 0 || nz < 0 || nx >= N || ny >= N || nz >= N) continue;
                if (light_opaque(chunk->get(nx, ny, nz))) continue;
                std::size_t ni = std::size_t(idx(nx, ny, nz));
                if (lvl[ni] < l - 1) { lvl[ni] = std::uint8_t(l - 1); q.push_back(idx(nx, ny, nz)); }
            }
        }
    }
};

} // namespace bf
