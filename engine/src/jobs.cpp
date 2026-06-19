// ============================================================================
// Blockfall — Track A: work-stealing job system implementation.
// See jobs.hpp for the correctness model.
// ============================================================================
#include "blockcore/jobs.hpp"

#include <chrono>

#ifdef __APPLE__
#  include <pthread/qos.h>
#  include <sys/sysctl.h>
#endif

namespace bf {

namespace {
// Which pool/worker the current thread belongs to (for LIFO locality on
// self-submit). Compared by address against the scheduler's pools.
thread_local const void* tl_pool   = nullptr;
thread_local int         tl_worker = -1;

unsigned sysctl_uint(const char* name, unsigned fallback) {
#ifdef __APPLE__
    unsigned v = 0; size_t sz = sizeof(v);
    if (sysctlbyname(name, &v, &sz, nullptr, 0) == 0 && v > 0) return v;
#endif
    (void)name; return fallback;
}
} // namespace

CoreTopology detect_core_topology() {
    // Apple Silicon exposes per-perf-level logical CPU counts.
    unsigned total = std::max(2u, std::thread::hardware_concurrency());
    unsigned p = sysctl_uint("hw.perflevel0.logicalcpu", 0);
    unsigned e = sysctl_uint("hw.perflevel1.logicalcpu", 0);
    if (p == 0) { p = std::max(1u, total / 2); e = total - p; }
    if (e == 0) e = 1;
    return CoreTopology{ p, e };
}

JobScheduler::JobScheduler(unsigned p_workers, unsigned e_workers, unsigned capacity)
    : jobs_(capacity), p_count_(p_workers), e_count_(e_workers) {
    free_list_.reserve(capacity);
    for (uint32_t i = capacity; i-- > 0; ) free_list_.push_back(i);

    auto start_pool = [this](Pool& pool, unsigned n) {
        pool.queues.resize(n);
        pool.qlocks.reserve(n);
        for (unsigned i = 0; i < n; ++i) pool.qlocks.push_back(std::make_unique<std::mutex>());
        for (unsigned i = 0; i < n; ++i)
            pool.workers.emplace_back([this, &pool, i] { worker_main(pool, int(i)); });
    };
    start_pool(p_pool_, p_workers);
    start_pool(e_pool_, e_workers);
}

JobScheduler::~JobScheduler() {
    stop_.store(true, std::memory_order_release);
    p_pool_.cv.notify_all();
    e_pool_.cv.notify_all();
    for (auto& t : p_pool_.workers) if (t.joinable()) t.join();
    for (auto& t : e_pool_.workers) if (t.joinable()) t.join();
}

unsigned JobScheduler::worker_count(JobQoS qos) const {
    return qos == JobQoS::Interactive ? p_count_ : e_count_;
}

uint32_t JobScheduler::alloc_slot() {
    for (;;) {
        {
            std::lock_guard<std::mutex> g(free_m_);
            if (!free_list_.empty()) { uint32_t idx = free_list_.back(); free_list_.pop_back(); return idx; }
        }
        // Pool saturated with in-flight jobs: help drain rather than fail.
        if (!try_run_one()) std::this_thread::yield();
    }
}

void JobScheduler::free_slot(uint32_t idx) {
    std::lock_guard<std::mutex> g(free_m_);
    free_list_.push_back(idx);
}

void JobScheduler::enqueue(uint32_t idx) {
    Pool& pool = pool_for(jobs_[idx].qos);
    int w;
    if (tl_pool == &pool && tl_worker >= 0 && tl_worker < int(pool.queues.size())) {
        w = tl_worker;                          // self-submit -> own deque (locality)
    } else {
        w = int(pool.rr.fetch_add(1, std::memory_order_relaxed) % pool.queues.size());
    }
    {
        std::lock_guard<std::mutex> g(*pool.qlocks[size_t(w)]);
        pool.queues[size_t(w)].push_back(idx);
    }
    pool.pending.fetch_add(1, std::memory_order_release);
    pool.cv.notify_one();
}

void JobScheduler::run_job(uint32_t idx) {
    Job& j = jobs_[idx];
    if (j.fn) j.fn(j.user);

    std::vector<uint32_t> deps;
    {
        std::lock_guard<std::mutex> g(j.mtx);
        deps.swap(j.dependents);
        j.done.store(true, std::memory_order_release);
    }
    for (uint32_t d : deps) {
        if (jobs_[d].remaining.fetch_sub(1, std::memory_order_acq_rel) == 1)
            enqueue(d);
    }
    free_slot(idx);
    done_cv_.notify_all();   // wake any waiters
}

bool JobScheduler::try_run_one() {
    Pool* pools[2] = { &p_pool_, &e_pool_ };
    for (Pool* pool : pools) {
        for (size_t q = 0; q < pool->queues.size(); ++q) {
            uint32_t idx = 0; bool got = false;
            {
                std::lock_guard<std::mutex> g(*pool->qlocks[q]);
                if (!pool->queues[q].empty()) { idx = pool->queues[q].front(); pool->queues[q].pop_front(); got = true; }
            }
            if (got) { pool->pending.fetch_sub(1, std::memory_order_acq_rel); run_job(idx); return true; }
        }
    }
    return false;
}

void JobScheduler::worker_main(Pool& pool, int worker_index) {
#ifdef __APPLE__
    pthread_set_qos_class_self_np(
        (&pool == &p_pool_) ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_UTILITY, 0);
#endif
    tl_pool = &pool;
    tl_worker = worker_index;
    const size_t nq = pool.queues.size();

    while (!stop_.load(std::memory_order_acquire)) {
        uint32_t idx = 0; bool got = false;

        // Own deque first (LIFO -> cache locality on freshly-spawned work).
        {
            std::lock_guard<std::mutex> g(*pool.qlocks[size_t(worker_index)]);
            auto& dq = pool.queues[size_t(worker_index)];
            if (!dq.empty()) { idx = dq.back(); dq.pop_back(); got = true; }
        }
        // Steal from siblings (FIFO -> oldest work).
        if (!got) {
            for (size_t s = 1; s < nq && !got; ++s) {
                size_t v = (size_t(worker_index) + s) % nq;
                std::lock_guard<std::mutex> g(*pool.qlocks[v]);
                auto& dq = pool.queues[v];
                if (!dq.empty()) { idx = dq.front(); dq.pop_front(); got = true; }
            }
        }

        if (got) {
            pool.pending.fetch_sub(1, std::memory_order_acq_rel);
            run_job(idx);
        } else {
            std::unique_lock<std::mutex> lk(pool.m);
            pool.cv.wait_for(lk, std::chrono::milliseconds(2), [&] {
                return stop_.load(std::memory_order_acquire) ||
                       pool.pending.load(std::memory_order_acquire) > 0;
            });
        }
    }
}

JobHandle JobScheduler::submit(JobFn fn, void* user, JobQoS qos,
                               std::span<const JobHandle> deps) {
    uint32_t idx = alloc_slot();
    Job& j = jobs_[idx];
    // Re-initialize the slot ATOMICALLY under its own mutex. A concurrent
    // dependency check (below, under d.mtx) must never observe a half-recycled
    // slot — e.g. gen==old while done==false — or it could register a dependent
    // that the recycling submit's clear() then drops, losing the job forever.
    uint32_t g;
    {
        std::lock_guard<std::mutex> lk(j.mtx);
        j.fn = fn; j.user = user; j.qos = qos;
        j.dependents.clear();
        j.done.store(false, std::memory_order_relaxed);
        g = j.gen.fetch_add(1, std::memory_order_acq_rel) + 1;  // new identity
        // +1 guard so the job can't be enqueued mid-registration.
        j.remaining.store(int(deps.size()) + 1, std::memory_order_relaxed);
    }
    JobHandle handle = make_handle(idx, g);

    for (const JobHandle dh : deps) {
        if (dh.id == 0) { j.remaining.fetch_sub(1, std::memory_order_acq_rel); continue; }
        uint32_t di = handle_index(dh);
        Job& d = jobs_[di];
        bool already_done = false;
        {
            std::lock_guard<std::mutex> dg(d.mtx);
            if (d.gen.load(std::memory_order_acquire) != handle_gen(dh) ||
                d.done.load(std::memory_order_acquire)) {
                already_done = true;            // dep finished (or recycled) already
            } else {
                d.dependents.push_back(idx);
            }
        }
        if (already_done) j.remaining.fetch_sub(1, std::memory_order_acq_rel);
    }

    // Release the guard; if that was the last hold, the job is runnable now.
    if (j.remaining.fetch_sub(1, std::memory_order_acq_rel) == 1)
        enqueue(idx);
    return handle;
}

bool JobScheduler::is_done(JobHandle h) const {
    if (h.id == 0) return true;
    uint32_t idx = handle_index(h);
    if (idx >= jobs_.size()) return true;
    const Job& j = jobs_[idx];
    if (j.gen.load(std::memory_order_acquire) != handle_gen(h)) return true; // recycled
    return j.done.load(std::memory_order_acquire);
}

void JobScheduler::wait(JobHandle h) {
    if (h.id == 0) return;
    while (!is_done(h)) {
        if (!try_run_one()) {                   // help-execute: no deadlock from workers
            std::unique_lock<std::mutex> lk(done_m_);
            done_cv_.wait_for(lk, std::chrono::milliseconds(1), [&] { return is_done(h); });
        }
    }
}

} // namespace bf
