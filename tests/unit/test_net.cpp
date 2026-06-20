// Track H — ReliableEndpoint tests: in-memory lossy link, no real sockets.
// Framework-free (return non-zero on failure; same style as test_chunk.cpp).
//
// BF_NO_SOCKETS suppresses POSIX headers in net.hpp / net.cpp so this
// test compiles and runs without socket sandbox access.
#define BF_NO_SOCKETS
#include "blockcore/net.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <span>
#include <vector>

static int fails = 0;
#define CHECK(c, m) do { \
    if (!(c)) { std::printf("FAIL: %s\n", m); ++fails; } \
} while(0)

// ===========================================================================
// In-memory lossy link
//
// Two ReliableEndpoints are wired through a LossyLink that:
//   - buffers queued datagrams
//   - on deliver(), feeds each datagram to the destination endpoint after
//     optionally dropping (deterministic PRNG) or reordering (also PRNG-driven)
// ===========================================================================
struct LossyLink {
    explicit LossyLink(std::uint32_t seed, double drop_rate,
                       double reorder_rate = 0.0)
        : rng_(seed), drop_dist_(0.0, 1.0),
          drop_rate_(drop_rate), reorder_rate_(reorder_rate) {}

    void enqueue(std::vector<std::byte> dg, bf::ReliableEndpoint* dest) {
        pending_.push_back({std::move(dg), dest});
    }

    void deliver() {
        std::vector<Pending> batch = std::move(pending_);
        pending_.clear();
        for (auto& item : batch) {
            if (drop_dist_(rng_) < drop_rate_)    continue;   // drop
            if (drop_dist_(rng_) < reorder_rate_) {           // delay one round
                pending_.push_back(std::move(item));
                continue;
            }
            item.dest->on_datagram(
                std::span<const std::byte>(item.dg.data(), item.dg.size()));
        }
    }

    void set_lossless() { drop_rate_ = 0.0; reorder_rate_ = 0.0; }

private:
    struct Pending { std::vector<std::byte> dg; bf::ReliableEndpoint* dest; };
    std::mt19937 rng_;
    std::uniform_real_distribution<double> drop_dist_;
    double drop_rate_;
    double reorder_rate_;
    std::vector<Pending> pending_;
};

// ---------------------------------------------------------------------------
// pump — one round: deliver both directions, call update() on both ends.
// ---------------------------------------------------------------------------
static void pump(bf::ReliableEndpoint& a, bf::ReliableEndpoint& b,
                 LossyLink& ab, LossyLink& ba,
                 double& clock, double dt = 0.050)
{
    clock += dt;
    ab.deliver();
    ba.deliver();
    a.update(clock);
    b.update(clock);
    // Deliver any standalone acks emitted by update().
    ab.deliver();
    ba.deliver();
}

// ===========================================================================
// Test 1 — ReliableOrdered: 200 messages A->B, 30% drop + 30% reorder.
//           B must receive ALL 200 in the exact send order.
// ===========================================================================
static void test_reliable_ordered()
{
    constexpr int    kMsgs        = 200;
    constexpr double kDropRate    = 0.30;
    constexpr double kReorderRate = 0.30;

    LossyLink link_ab(0xDEAD'BEEFu, kDropRate, kReorderRate);
    LossyLink link_ba(0xCAFE'BABEu, kDropRate, kReorderRate);

    bf::ReliableEndpoint* ptr_b = nullptr;
    bf::ReliableEndpoint* ptr_a = nullptr;

    bf::ReliableEndpoint ep_b(
        [&link_ba, &ptr_a](std::span<const std::byte> dg) {
            std::vector<std::byte> buf(dg.begin(), dg.end());
            link_ba.enqueue(std::move(buf), ptr_a);
        }, 2);
    ptr_b = &ep_b;

    bf::ReliableEndpoint ep_a(
        [&link_ab, &ptr_b](std::span<const std::byte> dg) {
            std::vector<std::byte> buf(dg.begin(), dg.end());
            link_ab.enqueue(std::move(buf), ptr_b);
        }, 1);
    ptr_a = &ep_a;

    std::vector<int> received;
    received.reserve(kMsgs);
    ep_b.set_receiver([&received](bf::NetChannel, std::span<const std::byte> pl) {
        if (pl.size() >= 4) {
            int v = 0;
            std::memcpy(&v, pl.data(), 4);
            received.push_back(v);
        }
    });

    for (int i = 0; i < kMsgs; ++i) {
        std::array<std::byte, 4> pl{};
        std::memcpy(pl.data(), &i, 4);
        ep_a.send(bf::NetChannel::ReliableOrdered,
                  std::span<const std::byte>(pl.data(), pl.size()));
    }

    double clock = 0.0;
    constexpr int kMaxRounds = 2000;
    for (int r = 0; r < kMaxRounds &&
                    static_cast<int>(received.size()) < kMsgs; ++r) {
        pump(ep_a, ep_b, link_ab, link_ba, clock);
    }

    CHECK(static_cast<int>(received.size()) == kMsgs,
          "ReliableOrdered: all 200 messages received");

    bool in_order = true;
    for (std::size_t i = 0; i < received.size(); ++i) {
        if (received[i] != static_cast<int>(i)) { in_order = false; break; }
    }
    CHECK(in_order, "ReliableOrdered: messages delivered in exact send order");
}

// ===========================================================================
// Test 2 — ReliableUnordered: 30% drop; all 100 eventually arrive;
//           none delivered twice.
// ===========================================================================
static void test_reliable_unordered()
{
    constexpr int    kMsgs    = 100;
    constexpr double kDropRate = 0.30;

    LossyLink link_ab(0x1234'5678u, kDropRate, 0.0);
    LossyLink link_ba(0x8765'4321u, kDropRate, 0.0);

    bf::ReliableEndpoint* ptr_b = nullptr;
    bf::ReliableEndpoint* ptr_a = nullptr;

    bf::ReliableEndpoint ep_b(
        [&link_ba, &ptr_a](std::span<const std::byte> dg) {
            std::vector<std::byte> buf(dg.begin(), dg.end());
            link_ba.enqueue(std::move(buf), ptr_a);
        }, 2);
    ptr_b = &ep_b;

    bf::ReliableEndpoint ep_a(
        [&link_ab, &ptr_b](std::span<const std::byte> dg) {
            std::vector<std::byte> buf(dg.begin(), dg.end());
            link_ab.enqueue(std::move(buf), ptr_b);
        }, 1);
    ptr_a = &ep_a;

    std::vector<int> received;
    received.reserve(kMsgs);
    ep_b.set_receiver([&received](bf::NetChannel, std::span<const std::byte> pl) {
        if (pl.size() >= 4) {
            int v = 0;
            std::memcpy(&v, pl.data(), 4);
            received.push_back(v);
        }
    });

    for (int i = 0; i < kMsgs; ++i) {
        std::array<std::byte, 4> pl{};
        std::memcpy(pl.data(), &i, 4);
        ep_a.send(bf::NetChannel::ReliableUnordered,
                  std::span<const std::byte>(pl.data(), pl.size()));
    }

    double clock = 0.0;
    constexpr int kMaxRounds = 2000;
    for (int r = 0; r < kMaxRounds &&
                    static_cast<int>(received.size()) < kMsgs; ++r) {
        pump(ep_a, ep_b, link_ab, link_ba, clock);
    }

    CHECK(static_cast<int>(received.size()) == kMsgs,
          "ReliableUnordered: all 100 messages eventually received");

    std::vector<int> sorted = received;
    std::sort(sorted.begin(), sorted.end());
    bool no_dups = true;
    for (std::size_t i = 1; i < sorted.size(); ++i) {
        if (sorted[i] == sorted[i - 1]) { no_dups = false; break; }
    }
    CHECK(no_dups, "ReliableUnordered: no message delivered twice");
}

// ===========================================================================
// Test 3 — Unreliable: 40% drop; B receives a subset; NEVER delivers an
//           older seq after a newer one (newest-wins monotone).
// ===========================================================================
static void test_unreliable()
{
    constexpr int    kMsgs    = 150;
    constexpr double kDropRate = 0.40;

    LossyLink link_ab(0xFEED'FACEu, kDropRate, 0.0);

    // B does not need to send back acks for Unreliable test — no unacked set.
    // We give it a no-op sink.
    bf::ReliableEndpoint* ptr_b = nullptr;

    bf::ReliableEndpoint ep_b(
        [](std::span<const std::byte>) {}, 2);
    ptr_b = &ep_b;

    bf::ReliableEndpoint ep_a(
        [&link_ab, &ptr_b](std::span<const std::byte> dg) {
            std::vector<std::byte> buf(dg.begin(), dg.end());
            link_ab.enqueue(std::move(buf), ptr_b);
        }, 1);

    std::vector<int> received;
    received.reserve(kMsgs);
    bool monotone = true;
    int  last_val = -1;

    ep_b.set_receiver([&](bf::NetChannel, std::span<const std::byte> pl) {
        if (pl.size() >= 4) {
            int v = 0;
            std::memcpy(&v, pl.data(), 4);
            received.push_back(v);
            if (v < last_val) monotone = false;
            last_val = v;
        }
    });

    for (int i = 0; i < kMsgs; ++i) {
        std::array<std::byte, 4> pl{};
        std::memcpy(pl.data(), &i, 4);
        ep_a.send(bf::NetChannel::Unreliable,
                  std::span<const std::byte>(pl.data(), pl.size()));
    }

    double clock = 0.0;
    for (int r = 0; r < 30; ++r) {
        clock += 0.050;
        link_ab.deliver();
        ep_a.update(clock);
        ep_b.update(clock);
    }

    int n = static_cast<int>(received.size());
    CHECK(n > 0,        "Unreliable: at least some messages delivered");
    CHECK(n < kMsgs,    "Unreliable: not all messages delivered (drops expected)");
    CHECK(monotone,     "Unreliable: delivered sequence is monotonically non-decreasing (newest-wins)");
}

// ===========================================================================
// Test 4 — Acks clear unacked set: after convergence on a lossless link the
//           sender's unacked_count() returns to 0 (no infinite resend).
// ===========================================================================
static void test_acks_clear_unacked()
{
    constexpr int    kMsgs    = 50;
    constexpr double kDropRate = 0.30;

    LossyLink link_ab(0x9999'AAAAu, kDropRate, 0.0);
    LossyLink link_ba(0xBBBB'CCCCu, kDropRate, 0.0);

    bf::ReliableEndpoint* ptr_b = nullptr;
    bf::ReliableEndpoint* ptr_a = nullptr;

    bf::ReliableEndpoint ep_b(
        [&link_ba, &ptr_a](std::span<const std::byte> dg) {
            std::vector<std::byte> buf(dg.begin(), dg.end());
            link_ba.enqueue(std::move(buf), ptr_a);
        }, 2);
    ptr_b = &ep_b;

    bf::ReliableEndpoint ep_a(
        [&link_ab, &ptr_b](std::span<const std::byte> dg) {
            std::vector<std::byte> buf(dg.begin(), dg.end());
            link_ab.enqueue(std::move(buf), ptr_b);
        }, 1);
    ptr_a = &ep_a;

    ep_b.set_receiver([](bf::NetChannel, std::span<const std::byte>) {});

    for (int i = 0; i < kMsgs; ++i) {
        std::array<std::byte, 4> pl{};
        std::memcpy(pl.data(), &i, 4);
        ep_a.send(bf::NetChannel::ReliableOrdered,
                  std::span<const std::byte>(pl.data(), pl.size()));
    }

    double clock = 0.0;
    // Phase 1: lossy convergence
    for (int r = 0; r < 500; ++r) {
        pump(ep_a, ep_b, link_ab, link_ba, clock);
    }

    // Phase 2: lossless — drain remaining unacked
    link_ab.set_lossless();
    link_ba.set_lossless();
    for (int r = 0; r < 500 && ep_a.unacked_count() > 0; ++r) {
        pump(ep_a, ep_b, link_ab, link_ba, clock);
    }

    CHECK(ep_a.unacked_count() == 0,
          "Acks: after lossless convergence sender unacked_count == 0");
}

// ===========================================================================
// main
// ===========================================================================
int main()
{
    test_reliable_ordered();
    test_reliable_unordered();
    test_unreliable();
    test_acks_clear_unacked();

    if (fails == 0) std::printf("OK: net reliability tests\n");
    return fails == 0 ? 0 : 1;
}
