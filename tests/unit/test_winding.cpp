// Track D — winding regression test. The greedy mesher's face-count tests did
// NOT catch that {-X,+Y,-Z} faces were emitted back-facing (winding bug found
// when the flat field vanished from a top-down view). This checks, geometrically,
// that EVERY emitted triangle's normal points outward (CCW-from-outside), so
// back-face culling keeps exactly the visible faces.
#include "blockcore/mesher.hpp"
#include "blockcore/chunk.hpp"
#include "blockcore/vertex.hpp"

#include <cstdio>

using namespace bf;

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static void normalVec(std::uint32_t code, float& x, float& y, float& z) {
    const float t[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
    x = t[code][0]; y = t[code][1]; z = t[code][2];
}

int main() {
    ChunkStore store;
    auto* ch = static_cast<PaletteChunk*>(store.get_or_create(ChunkCoord{0,0,0}));
    // A few blocks so all 6 face directions appear, including merged faces.
    ch->set(8, 8, 8, 3);
    ch->set(4, 4, 4, 1); ch->set(5, 4, 4, 1);   // a merged pair
    GreedyMesher m;
    std::vector<std::byte> vb(m.max_vertex_bytes()), ib(m.max_index_bytes());
    MeshResult r = m.mesh(ChunkCoord{0,0,0}, store, vb, ib, false);
    CHECK(!r.empty && r.index_count > 0, "produced geometry");

    auto* V = reinterpret_cast<BFVertex*>(vb.data());
    auto* I = reinterpret_cast<std::uint32_t*>(ib.data());
    auto px = [](BFVertex v){ return float(v.pos_packed & 0x3f); };
    auto py = [](BFVertex v){ return float((v.pos_packed >> 6) & 0x3f); };
    auto pz = [](BFVertex v){ return float((v.pos_packed >> 12) & 0x3f); };

    int wrong = 0;
    for (std::uint32_t t = 0; t < r.index_count; t += 3) {
        BFVertex a = V[I[t]], b = V[I[t+1]], c = V[I[t+2]];
        float e1[3] = { px(b)-px(a), py(b)-py(a), pz(b)-pz(a) };
        float e2[3] = { px(c)-px(a), py(c)-py(a), pz(c)-pz(a) };
        float g[3] = { e1[1]*e2[2]-e1[2]*e2[1], e1[2]*e2[0]-e1[0]*e2[2], e1[0]*e2[1]-e1[1]*e2[0] };
        float nx, ny, nz; normalVec(a.normal_uv & 7, nx, ny, nz);
        if (g[0]*nx + g[1]*ny + g[2]*nz <= 0) ++wrong;
    }
    CHECK(wrong == 0, "every triangle is front-facing (CCW from outside)");

    if (fails == 0) std::printf("OK: mesh winding (%u triangles all outward)\n", r.index_count/3);
    return fails == 0 ? 0 : 1;
}
