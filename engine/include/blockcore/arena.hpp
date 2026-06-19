// ============================================================================
// Blockfall — Track A: memory arenas (engine/include/blockcore/arena.hpp)
// Implements bf::IArena (contract). Per-subsystem arenas + pools; zero
// hot-path heap allocation (spec §9). A LinearArena bump-allocates from one
// up-front reservation and frees everything with reset(); a PoolAllocator
// hands out fixed-size blocks from a free list. Both are thread-safe so
// worker jobs can allocate without a global heap lock.
// ============================================================================
#pragma once
#include "blockcore_interfaces.hpp"

#include <atomic>
#include <cstdlib>
#include <cstddef>
#include <new>
#include <cassert>
#include <mutex>
#include <vector>

namespace bf {

// Single up-front reservation; alloc() bumps a pointer atomically. Frees in
// O(1) via reset(). Never returns memory to the OS until destruction.
class LinearArena final : public IArena {
public:
    explicit LinearArena(std::size_t capacity_bytes)
        : cap_(capacity_bytes) {
        base_ = static_cast<std::byte*>(std::malloc(capacity_bytes));
        // A subsystem arena that can't reserve its budget is a hard error.
        assert(base_ && "LinearArena reservation failed");
    }
    ~LinearArena() override { std::free(base_); }

    LinearArena(const LinearArena&) = delete;
    LinearArena& operator=(const LinearArena&) = delete;

    void* alloc(std::size_t bytes, std::size_t align) override {
        assert((align & (align - 1)) == 0 && "align must be a power of two");
        std::size_t cur = offset_.load(std::memory_order_relaxed);
        std::size_t aligned, next;
        do {
            aligned = (cur + (align - 1)) & ~(align - 1);
            next = aligned + bytes;
            if (next > cap_) return nullptr;  // arena exhausted; caller handles
        } while (!offset_.compare_exchange_weak(cur, next,
                     std::memory_order_acq_rel, std::memory_order_relaxed));
        // Track high-water for budgeting (best-effort, monotone).
        std::size_t hw = high_.load(std::memory_order_relaxed);
        while (next > hw && !high_.compare_exchange_weak(hw, next,
                   std::memory_order_relaxed)) { }
        return base_ + aligned;
    }

    void reset() override { offset_.store(0, std::memory_order_release); }
    std::size_t high_water() const override { return high_.load(std::memory_order_relaxed); }
    std::size_t capacity()  const { return cap_; }
    std::size_t used()      const { return offset_.load(std::memory_order_relaxed); }

private:
    std::byte*               base_{nullptr};
    std::size_t              cap_{0};
    std::atomic<std::size_t> offset_{0};
    std::atomic<std::size_t> high_{0};
};

// Fixed-size block pool with a free list. Hands out one `block_size`-byte slot
// per acquire(); release() returns it. No per-acquire heap allocation after
// construction. Thread-safe via a small mutex (uncontended in steady state).
class PoolAllocator final : public IArena {
public:
    PoolAllocator(std::size_t block_size, std::size_t block_count, std::size_t align = 16)
        : block_(align_up(block_size, align)), count_(block_count) {
        storage_ = static_cast<std::byte*>(std::aligned_alloc(align, block_ * count_));
        assert(storage_ && "PoolAllocator reservation failed");
        free_.reserve(count_);
        for (std::size_t i = count_; i-- > 0; ) free_.push_back(storage_ + i * block_);
    }
    ~PoolAllocator() override { std::free(storage_); }

    PoolAllocator(const PoolAllocator&) = delete;
    PoolAllocator& operator=(const PoolAllocator&) = delete;

    // IArena: `bytes`/`align` must fit the configured block; returns nullptr if full.
    void* alloc(std::size_t bytes, std::size_t /*align*/) override {
        if (bytes > block_) return nullptr;
        std::lock_guard<std::mutex> g(m_);
        if (free_.empty()) return nullptr;
        void* p = free_.back(); free_.pop_back();
        std::size_t live = count_ - free_.size();
        if (live > high_) high_ = live;
        return p;
    }
    void release(void* p) {
        std::lock_guard<std::mutex> g(m_);
        free_.push_back(static_cast<std::byte*>(p));
    }
    void reset() override {
        std::lock_guard<std::mutex> g(m_);
        free_.clear();
        for (std::size_t i = count_; i-- > 0; ) free_.push_back(storage_ + i * block_);
    }
    std::size_t high_water() const override { return high_ * block_; }
    std::size_t block_size() const { return block_; }
    std::size_t available()  const { std::lock_guard<std::mutex> g(m_); return free_.size(); }

private:
    static std::size_t align_up(std::size_t v, std::size_t a) { return (v + a - 1) & ~(a - 1); }

    std::byte*              storage_{nullptr};
    std::size_t             block_{0};
    std::size_t             count_{0};
    std::size_t             high_{0};
    std::vector<std::byte*> free_;
    mutable std::mutex      m_;
};

} // namespace bf
