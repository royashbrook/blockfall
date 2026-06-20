// M4 — co-op consistency. Host + 2 clients, each with its own World, wired
// through lossy in-memory reliable-UDP links. Proves: clients join and gen the
// same world from the seed; a client's edit reaches everyone; and TWO clients
// editing the SAME block converge to one authoritative value — even at 30% loss.
#include "blockcore/session.hpp"
#include "blockcore/net.hpp"
#include "blockcore/world.hpp"
#include "blockcore/mesher.hpp"
#include "blockcore/worldgen.hpp"
#include "blockcore/content.hpp"

#include <cstdio>
#include <cstdlib>
#include <memory>
#include <random>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static bf_gpu_buffer alloc_fn(void*, uint32_t b) {
    void* p = std::malloc(b ? b : 16); bf_gpu_buffer r{};
    r.handle = reinterpret_cast<uint64_t>(p); r.contents = p; r.bytes = b; return r;
}
static void free_fn(void*, uint64_t h) { std::free(reinterpret_cast<void*>(h)); }

using namespace bf;

int main() {
    ContentRegistry content;
    if (!content.load("/Users/roy/gh/blockfall/content")) { std::printf("FAIL: content\n"); return 1; }
    bf_gpu_allocator alloc{}; alloc.alloc = alloc_fn; alloc.free_ = free_fn;

    GreedyMesher hm; TerrainGen hg; World host(hm, &hg);
    GreedyMesher m1; TerrainGen g1; World c1(m1, &g1);
    GreedyMesher m2; TerrainGen g2; World c2(m2, &g2);
    for (World* w : {&host, &c1, &c2}) { w->set_content(&content); w->set_allocator(alloc); }
    host.set_mode(BF_MODE_CREATIVE);
    host.init_world(777);                         // host authoritative

    NetSession hs(host, NetRole::Host), cs1(c1, NetRole::Client), cs2(c2, NetRole::Client);

    // ---- lossy in-memory links between 4 endpoints ----
    // eps: 0=host<->c1 (host side), 1=c1 side, 2=host<->c2 (host side), 3=c2 side
    std::vector<std::unique_ptr<ReliableEndpoint>> eps;
    std::mt19937 rng(12345);
    double loss = 0.30;
    auto link = [&](int dst) -> DatagramSink {
        return [dst, &eps, &rng, &loss](std::span<const std::byte> d) {
            if (loss > 0 && (double(rng() % 1000) / 1000.0) < loss) return;   // drop
            eps[std::size_t(dst)]->on_datagram(d);
        };
    };
    eps.push_back(std::make_unique<ReliableEndpoint>(link(1), 0));
    eps.push_back(std::make_unique<ReliableEndpoint>(link(0), 1));
    eps.push_back(std::make_unique<ReliableEndpoint>(link(3), 0));
    eps.push_back(std::make_unique<ReliableEndpoint>(link(2), 1));
    eps[0]->set_receiver([&](NetChannel ch, std::span<const std::byte> d) { hs.on_payload(1, ch, d); });
    eps[1]->set_receiver([&](NetChannel ch, std::span<const std::byte> d) { cs1.on_payload(0, ch, d); });
    eps[2]->set_receiver([&](NetChannel ch, std::span<const std::byte> d) { hs.on_payload(2, ch, d); });
    eps[3]->set_receiver([&](NetChannel ch, std::span<const std::byte> d) { cs2.on_payload(0, ch, d); });
    hs.set_sender([&](std::uint16_t peer, NetChannel ch, std::span<const std::byte> d) {
        eps[peer == 1 ? 0 : 2]->send(ch, d);
    });
    cs1.set_sender([&](std::uint16_t, NetChannel ch, std::span<const std::byte> d) { eps[1]->send(ch, d); });
    cs2.set_sender([&](std::uint16_t, NetChannel ch, std::span<const std::byte> d) { eps[3]->send(ch, d); });

    double clk = 0.0;
    auto pump = [&](int rounds) {
        for (int i = 0; i < rounds; ++i) {
            clk += 0.05;
            for (auto& e : eps) e->update(clk);
            hs.update(0.05); cs1.update(0.05); cs2.update(0.05);
        }
    };

    hs.on_peer_join(1); hs.on_peer_join(2);
    cs1.on_peer_join(0); cs2.on_peer_join(0);     // clients send HELLO
    pump(40);
    CHECK(cs1.joined() && cs2.joined(), "both clients joined and got the seed");
    CHECK(c1.world_seed() == 777 && c2.world_seed() == 777, "clients gen the host's world");

    // ---- a client edit reaches everyone ----
    IVec3 P{50, 60, 50};                          // air above terrain in all worlds
    c1.debug_edit(P.x, P.y, P.z, GLOW);
    pump(40);
    CHECK(host.debug_block_at(P.x, P.y, P.z) == GLOW, "host got the client's edit");
    CHECK(c2.debug_block_at(P.x, P.y, P.z) == GLOW, "other client got the edit");

    // ---- two clients edit the SAME block: must converge ----
    IVec3 Q{52, 60, 50};
    c1.debug_edit(Q.x, Q.y, Q.z, GLOW);
    c2.debug_edit(Q.x, Q.y, Q.z, STONE);
    pump(80);
    BlockId hb = host.debug_block_at(Q.x, Q.y, Q.z);
    BlockId b1 = c1.debug_block_at(Q.x, Q.y, Q.z);
    BlockId b2 = c2.debug_block_at(Q.x, Q.y, Q.z);
    CHECK(hb != 0, "contested block resolved to a value");
    CHECK(hb == b1 && hb == b2, "all three worlds converged to the host's authoritative value");

    if (fails == 0) std::printf("OK: co-op consistency (join + edit replication + convergence @30%% loss)\n");
    return fails == 0 ? 0 : 1;
}
