// ============================================================================
// Blockfall — Track A: work-stealing job system (engine/include/blockcore/jobs.hpp)
// Implements bf::IJobScheduler (contract). Two QoS pools map to the M-series
// topology: Interactive -> P-cores (mesh/render-prep/sim), Utility -> E-cores
// (gen/I-O/net/AI), tagged via pthread QoS (spec §4.8/§10). Dependencies form
// a DAG; a job runs only after all its deps complete. wait() help-executes so
// calling it from a worker thread cannot deadlock.
//
// Correctness model: all slot state transitions (register-dependent / mark-
// done) are serialized by a per-slot mutex; `remaining` and `done` are atomics
// for lock-free fast paths. Designed to be TSan-clean (Track A exit gate).
// ============================================================================
#pragma once
#include "blockcore_interfaces.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

namespace bf {

// Detect P/E core counts on Apple Silicon (falls back gracefully elsewhere).
struct CoreTopology { unsigned p_cores; unsigned e_cores; };
CoreTopology detect_core_topology();

class JobScheduler final : public IJobScheduler {
public:
    // capacity = max in-flight jobs (fixed pool; no hot-path heap alloc).
    JobScheduler(unsigned p_workers, unsigned e_workers, unsigned capacity = 8192);
    ~JobScheduler() override;

    JobScheduler(const JobScheduler&) = delete;
    JobScheduler& operator=(const JobScheduler&) = delete;

    JobHandle submit(JobFn fn, void* user, JobQoS qos,
                     std::span<const JobHandle> deps = {}) override;
    void      wait(JobHandle h) override;
    bool      is_done(JobHandle h) const override;
    unsigned  worker_count(JobQoS qos) const override;

private:
    struct Job {
        JobFn                 fn{nullptr};
        void*                 user{nullptr};
        JobQoS                qos{JobQoS::Interactive};
        std::atomic<int>      remaining{0};   // unmet deps (+1 guard during submit)
        std::atomic<bool>     done{false};
        std::atomic<uint32_t> gen{0};         // handle generation (recycle guard)
        std::mutex            mtx;             // serializes dependents/done
        std::vector<uint32_t> dependents;     // slot indices to notify on finish
    };

    struct Pool {
        std::vector<std::thread>          workers;
        std::vector<std::deque<uint32_t>> queues; // one deque per worker
        std::vector<std::unique_ptr<std::mutex>> qlocks;
        std::mutex                        m;
        std::condition_variable           cv;
        std::atomic<int>                  pending{0};
        std::atomic<unsigned>             rr{0};    // round-robin enqueue cursor
    };

    static JobHandle make_handle(uint32_t idx, uint32_t gen) {
        return JobHandle{ (uint64_t(gen) << 32) | idx };
    }
    static uint32_t handle_index(JobHandle h) { return uint32_t(h.id & 0xFFFFFFFFu); }
    static uint32_t handle_gen(JobHandle h)   { return uint32_t(h.id >> 32); }

    uint32_t alloc_slot();
    void     free_slot(uint32_t idx);
    void     enqueue(uint32_t idx);
    void     worker_main(Pool& pool, int worker_index);
    bool     try_run_one();          // help-execute (used by wait)
    void     run_job(uint32_t idx);

    Pool& pool_for(JobQoS q) { return q == JobQoS::Interactive ? p_pool_ : e_pool_; }

    std::vector<Job>        jobs_;
    std::vector<uint32_t>   free_list_;
    std::mutex              free_m_;
    Pool                    p_pool_;
    Pool                    e_pool_;
    std::condition_variable done_cv_;          // global completion signal
    std::mutex              done_m_;
    std::atomic<bool>       stop_{false};
    unsigned                p_count_{0}, e_count_{0};
};

} // namespace bf
