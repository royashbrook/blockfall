//! A tiny std-only worker thread pool, ported in spirit from the retired C++
//! JobScheduler (engine/src/jobs.cpp). The C++ version had a work-stealing,
//! dependency-DAG, dual-QoS scheduler; Blockfall's streaming only ever submits
//! independent CPU jobs (generate a chunk, mesh a snapshot) and collects their
//! results on the frame thread, so this is deliberately much simpler:
//!
//!   - One fixed pool of std::thread workers sharing a single mpsc job queue.
//!   - A job is a `Box<dyn FnOnce() + Send>`; the closure does the CPU work and
//!     sends its result down a channel the caller owns. The pool never touches
//!     World, the chunk store, or the GPU allocator (those stay on the frame
//!     thread). Everything a job captures must be Send (PaletteChunk, TerrainGen,
//!     the stateless mesher, plain coords) which it is.
//!   - On Drop the pool drops the job sender (closing the queue), which makes
//!     every worker's recv() return Err; the workers exit and we join them.
//!
//! There is no unsafe here. Safety of the streaming integration rests entirely on
//! the Send bounds the standard library enforces on the closures we submit.

use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

/// A unit of CPU work to run on a worker thread.
type Job = Box<dyn FnOnce() + Send + 'static>;

/// A fixed-size pool of worker threads draining a shared queue.
pub struct WorkerPool {
    // Wrapped in Option so Drop can take it, close the channel, and join.
    tx: Option<Sender<Job>>,
    workers: Vec<JoinHandle<()>>,
}

impl WorkerPool {
    /// Build a pool with `n` workers (clamped to at least 1). The recommended
    /// size for streaming is `recommended_workers()`.
    pub fn new(n: usize) -> WorkerPool {
        let n = n.max(1);
        // A single shared receiver behind a mutex: each worker locks, pops one
        // job, unlocks, then runs the job OUTSIDE the lock so jobs run in
        // parallel. (mpsc::Receiver is not Sync, so it is shared via Arc<Mutex>.)
        let (tx, rx) = mpsc::channel::<Job>();
        let rx = Arc::new(Mutex::new(rx));
        let mut workers = Vec::with_capacity(n);
        for _ in 0..n {
            let rx = Arc::clone(&rx);
            workers.push(thread::spawn(move || worker_main(rx)));
        }
        WorkerPool {
            tx: Some(tx),
            workers,
        }
    }

    /// Enqueue a job. If the pool is shutting down (sender gone) the job is
    /// silently dropped, which is fine: streaming re-derives its backlog every
    /// frame from the resident set, so nothing is permanently lost.
    pub fn submit<F: FnOnce() + Send + 'static>(&self, job: F) {
        if let Some(tx) = self.tx.as_ref() {
            let _ = tx.send(Box::new(job));
        }
    }

    /// Number of worker threads.
    pub fn worker_count(&self) -> usize {
        self.workers.len()
    }
}

impl Drop for WorkerPool {
    fn drop(&mut self) {
        // Close the queue: workers' recv() returns Err and they exit.
        self.tx.take();
        for w in self.workers.drain(..) {
            let _ = w.join();
        }
    }
}

// Worker loop: take the lock only long enough to pop one job, then run it
// unlocked so the other workers can pop concurrently. recv() blocks until a job
// arrives or the sender is dropped (Err -> exit).
fn worker_main(rx: Arc<Mutex<Receiver<Job>>>) {
    loop {
        let job = {
            let guard = match rx.lock() {
                Ok(g) => g,
                // A panicking worker could poison the lock; recover and keep
                // serving so one bad job does not wedge the whole pool.
                Err(p) => p.into_inner(),
            };
            guard.recv()
        };
        match job {
            Ok(job) => job(),
            Err(_) => break, // channel closed: shut down
        }
    }
}

/// Pick a worker count for streaming: leave one core for the frame thread, cap
/// the pool so a many-core machine does not oversubscribe. Mirrors the C++
/// intent (P-cores minus the render thread, plus the E-cores) without the QoS
/// split, which std threads do not expose portably.
pub fn recommended_workers() -> usize {
    let total = thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);
    // total-1 keeps a core free for the frame/render thread; clamp to [2, 8].
    total.saturating_sub(1).clamp(2, 8)
}
