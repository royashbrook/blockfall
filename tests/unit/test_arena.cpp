// Track A — arena/pool allocator tests. Framework-free: returns non-zero on
// first failure so CTest reports it. Run under ASan/TSan via ci/check.sh BF_SAN.
#include "blockcore/arena.hpp"

#include <cstdio>
#include <thread>
#include <vector>
#include <set>
#include <cstdint>

static int fails = 0;
#define CHECK(c, m) do { if(!(c)) { std::printf("FAIL: %s\n", m); ++fails; } } while(0)

static int test_linear() {
    bf::LinearArena a(1024);
    void* p1 = a.alloc(64, 16);
    void* p2 = a.alloc(1, 64);
    void* p3 = a.alloc(100, 32);
    CHECK(p1 && p2 && p3, "linear: allocs succeed");
    CHECK((reinterpret_cast<std::uintptr_t>(p2) % 64) == 0, "linear: 64-align honored");
    CHECK((reinterpret_cast<std::uintptr_t>(p3) % 32) == 0, "linear: 32-align honored");
    CHECK(p1 != p2 && p2 != p3, "linear: distinct pointers");
    CHECK(a.high_water() > 0 && a.high_water() <= 1024, "linear: high-water sane");
    CHECK(a.alloc(4096, 16) == nullptr, "linear: over-capacity returns null");
    a.reset();
    CHECK(a.used() == 0, "linear: reset clears");
    void* p4 = a.alloc(64, 16);
    CHECK(p4 == p1, "linear: reset reuses from base");
    return 0;
}

static int test_pool() {
    bf::PoolAllocator pool(48, 4, 16);
    std::set<void*> seen;
    for (int i = 0; i < 4; ++i) {
        void* p = pool.alloc(48, 16);
        CHECK(p != nullptr, "pool: block within count");
        CHECK(seen.insert(p).second, "pool: blocks distinct");
    }
    CHECK(pool.alloc(48, 16) == nullptr, "pool: exhausted returns null");
    void* one = *seen.begin();
    pool.release(one);
    CHECK(pool.alloc(48, 16) == one, "pool: released block reused");
    CHECK(pool.alloc(1000, 16) == nullptr, "pool: oversize rejected");
    pool.reset();
    CHECK(pool.available() == 4, "pool: reset refills");
    return 0;
}

// Concurrent bump allocation must hand out non-overlapping, unique regions.
static int test_linear_threaded() {
    constexpr int kThreads = 8, kPer = 2000;
    bf::LinearArena a(kThreads * kPer * sizeof(int) + 4096);
    std::vector<std::thread> ts;
    std::vector<int*> ptrs(kThreads * kPer, nullptr);
    for (int t = 0; t < kThreads; ++t) {
        ts.emplace_back([&, t] {
            for (int i = 0; i < kPer; ++i) {
                int* p = static_cast<int*>(a.alloc(sizeof(int), alignof(int)));
                if (p) { *p = t * kPer + i; ptrs[size_t(t * kPer + i)] = p; }
            }
        });
    }
    for (auto& th : ts) th.join();
    // Every slot must hold exactly the value its owner wrote (no overlap/tear).
    std::set<int*> uniq;
    int bad = 0;
    for (int i = 0; i < kThreads * kPer; ++i) {
        if (!ptrs[size_t(i)] || *ptrs[size_t(i)] != i) ++bad;
        if (ptrs[size_t(i)]) uniq.insert(ptrs[size_t(i)]);
    }
    CHECK(bad == 0, "linear-threaded: every region holds its own value (no overlap)");
    CHECK(uniq.size() == size_t(kThreads * kPer), "linear-threaded: all pointers unique");
    return 0;
}

int main() {
    test_linear();
    test_pool();
    test_linear_threaded();
    if (fails == 0) std::printf("OK: arena tests\n");
    return fails == 0 ? 0 : 1;
}
