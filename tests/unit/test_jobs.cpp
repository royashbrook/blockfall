// Track A — job scheduler tests: DAG ordering, fan-out under contention,
// dependency chains, and a concurrent-submit stress run (TSan target).
// Framework-free: non-zero exit on failure.
#include "blockcore/jobs.hpp"

#include <atomic>
#include <cstdio>
#include <thread>
#include <vector>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

// ---- DAG ordering: C depends on A and B; C must run after both -------------
struct DagCtx {
    std::atomic<int> clock{0};
    std::atomic<int> a{-1}, b{-1}, c{-1};
};
static void dagA(void* u) noexcept { auto* x = static_cast<DagCtx*>(u); x->a = x->clock.fetch_add(1); }
static void dagB(void* u) noexcept { auto* x = static_cast<DagCtx*>(u); x->b = x->clock.fetch_add(1); }
static void dagC(void* u) noexcept { auto* x = static_cast<DagCtx*>(u); x->c = x->clock.fetch_add(1); }

static void test_dag(bf::JobScheduler& js) {
    DagCtx ctx;
    auto ha = js.submit(dagA, &ctx, bf::JobQoS::Interactive);
    auto hb = js.submit(dagB, &ctx, bf::JobQoS::Utility);
    bf::JobHandle deps[2] = { ha, hb };
    auto hc = js.submit(dagC, &ctx, bf::JobQoS::Interactive, std::span<const bf::JobHandle>(deps, 2));
    js.wait(hc);
    CHECK(ctx.a >= 0 && ctx.b >= 0 && ctx.c >= 0, "dag: all ran");
    CHECK(ctx.c > ctx.a && ctx.c > ctx.b, "dag: C ran after both deps");
}

// ---- Fan-out under contention: N independent jobs all complete -------------
static void inc(void* u) noexcept { static_cast<std::atomic<int>*>(u)->fetch_add(1, std::memory_order_relaxed); }

static void test_fanout(bf::JobScheduler& js) {
    constexpr int N = 20000;
    std::atomic<int> counter{0};
    std::vector<bf::JobHandle> hs;
    hs.reserve(N);
    for (int i = 0; i < N; ++i)
        hs.push_back(js.submit(inc, &counter,
                     (i & 1) ? bf::JobQoS::Interactive : bf::JobQoS::Utility));
    for (auto h : hs) js.wait(h);
    CHECK(counter.load() == N, "fanout: every job ran exactly once");
}

// ---- Dependency chain: step i must run exactly when the shared counter is i.
// A single shared counter + per-node expected index proves strict sequencing
// through the dependency edges (and that each step sees the prior's write).
struct ChainNode { std::atomic<int>* counter; int idx; std::atomic<int>* bad; };
static void chainStep(void* u) noexcept {
    auto* n = static_cast<ChainNode*>(u);
    int got = n->counter->fetch_add(1, std::memory_order_acq_rel);
    if (got != n->idx) n->bad->fetch_add(1, std::memory_order_relaxed);
}

static void test_chain(bf::JobScheduler& js) {
    constexpr int LEN = 200;
    std::atomic<int> counter{0};
    std::atomic<int> bad{0};
    std::vector<ChainNode> nodes(LEN);
    bf::JobHandle prev{0};
    for (int i = 0; i < LEN; ++i) {
        nodes[size_t(i)] = ChainNode{ &counter, i, &bad };
        bf::JobHandle deps[1] = { prev };
        prev = js.submit(chainStep, &nodes[size_t(i)], bf::JobQoS::Interactive,
                         i == 0 ? std::span<const bf::JobHandle>{}
                                : std::span<const bf::JobHandle>(deps, 1));
    }
    js.wait(prev);
    CHECK(counter.load() == LEN, "chain: all steps ran");
    CHECK(bad.load() == 0, "chain: strict sequential ordering held");
}

// ---- Concurrent submit stress (TSan target) --------------------------------
static void test_stress(bf::JobScheduler& js) {
    constexpr int THREADS = 6, PER = 3000;
    std::atomic<int> done_count{0};
    std::vector<std::thread> producers;
    for (int t = 0; t < THREADS; ++t) {
        producers.emplace_back([&] {
            std::vector<bf::JobHandle> local;
            for (int i = 0; i < PER; ++i) {
                bf::JobQoS q = (i & 1) ? bf::JobQoS::Interactive : bf::JobQoS::Utility;
                // Chain every 4th job onto the previous to exercise deps concurrently.
                if (!local.empty() && (i % 4 == 0)) {
                    bf::JobHandle d[1] = { local.back() };
                    local.push_back(js.submit(inc, &done_count, q, std::span<const bf::JobHandle>(d, 1)));
                } else {
                    local.push_back(js.submit(inc, &done_count, q));
                }
            }
            for (auto h : local) js.wait(h);
        });
    }
    for (auto& p : producers) p.join();
    CHECK(done_count.load() == THREADS * PER, "stress: all concurrent jobs completed");
}

int main() {
    auto topo = bf::detect_core_topology();
    std::printf("topology: %u P-core(s), %u E-core(s)\n", topo.p_cores, topo.e_cores);
    bf::JobScheduler js(topo.p_cores, topo.e_cores);
    CHECK(js.worker_count(bf::JobQoS::Interactive) == topo.p_cores, "worker_count P");
    CHECK(js.worker_count(bf::JobQoS::Utility) == topo.e_cores, "worker_count E");

    test_dag(js);
    test_fanout(js);
    test_chain(js);
    test_stress(js);

    if (fails == 0) std::printf("OK: job scheduler tests\n");
    return fails == 0 ? 0 : 1;
}
