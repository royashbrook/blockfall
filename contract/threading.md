# Blockfall — Threading & Data-Flow Model (FROZEN, Phase 0)

ABI v1. Every sync point below is load-bearing on the M1 Air (4P+4E, 16 GB
UMA). If you add a fence, name it here and justify why it is unavoidable
(spec §10).

## Threads & ownership

| Thread | Cores (QoS) | Owns | Never touches |
|---|---|---|---|
| **Main** (Swift) | 1 P, Interactive | Window, `NSEvent`, `MTLCommandQueue`, render encode, HUD draw | World state, chunk bytes |
| **Sim** | 1 P, Interactive | Authoritative world: fixed 20 Hz step, block edits, ECS, physics | MTLBuffers, GPU encode |
| **Mesh/render-prep workers** | P-cores, Interactive | Greedy meshing → shared GPU buffers, frame draw-list build | World mutation (read snapshot only) |
| **Gen / I-O / Net / AI workers** | E-cores, Utility | Worldgen, save/load, UDP socket, pathfinding | GPU buffers, MTLDevice |

The job scheduler (Track A) is the only thing that creates worker threads.
QoS tags map P→`Interactive`, E→`Utility`; verify the split in Instruments
(spec §10). The 4P+4E topology is identical on M1/M2 — the split holds.

## The one unavoidable sync per resource

1. **Sim → render snapshot.** Sim publishes a double-buffered, immutable world
   snapshot at the end of each 20 Hz tick. The main thread reads the latest
   published snapshot lock-free (atomic pointer swap — `g_snapshot_swap`).
   *Why unavoidable:* the GPU must not read a chunk mid-edit. The swap is the
   single hand-off; rendering interpolates between the two newest snapshots
   using `interp_alpha`.

2. **Mesh write → GPU read (triple buffer).** Dynamic GPU buffers
   (mesh/uniform/HUD) are triple-buffered. A worker writes frame N+1's bytes
   only into a buffer the GPU is **not** reading for frame N. Gate:
   `g_inflight_sema` (counting semaphore, value 3) — `wait` before CPU writes,
   `signal` in the command-buffer completion handler. *Why unavoidable:* UMA
   shared memory means CPU and GPU alias the same bytes; without the fence the
   CPU overwrites pixels the GPU is sampling (spec §10).

3. **Allocator free.** `bf_gpu_allocator.free_` is only called after the
   completion handler that owns that buffer's frame has fired — same semaphore
   as (2). No buffer is freed while the GPU may read it.

## A block edit's full path (spec §6.4 requirement)

```
[Main] click  ──bf_input_action(MINE_STOP/PLACE)──▶ action queue (lock-free MPSC)
                                                        │
[Sim] next 20 Hz tick: drain queue                     ▼
  ├─ IWorldProvider::set_block()  (authoritative)
  ├─ IChunk::set() → chunk.revision()++                ── marks dirty
  ├─ ILighting::on_block_changed() → incremental reflood (this + neighbour chunks)
  ├─ enqueue remesh job (JobQoS::Interactive) for dirty chunk(s)
  ├─ emit BF_EVT_BLOCK_BROKEN/PLACED  → [Main] particles + SFX
  ├─ [HOST] queue ReliableOrdered net packet (block-edit replication)
  └─ mark chunk dirty for save (coalesced; flushed on E-core I-O worker)
       │
[Mesh worker] greedy remesh dirty chunk ──writes──▶ Swift-allocated shared GPU buffer
       │   (must feel instant — remesh latency budget in Track D tests)
       ▼
[Sim] publish next snapshot (atomic swap) ──▶ [Main] picks it up next frame ──▶ draw
```

Co-op variant: a **client** edit is *predicted* locally (same path, flagged
provisional) and sent to the host; the host authoritative result snaps back via
reconcile (Track H). Two clients editing the same area converge because the
host serializes edits on its Sim thread — there is exactly one authority.

## Chunk lifecycle path (gen → mesh → GPU → draw)

```
[E-core] IWorldGen::generate(coord) → IChunk (palette-packed)
   → [E-core] IChunkStore residency + (if saved) deserialize overrides
   → [P-core] IMesher::mesh() → shared GPU buffer (alloc via bf_gpu_allocator)
   → [Sim] add to snapshot draw set
   → [Main] bf_frame_acquire_render → encode draw
```

## Frame loop (Main)

```
bf_frame_begin(in, dt)       // sample continuous input, advance camera/interp
bf_frame_acquire_render(&f)  // borrow draw list + HUD + dim state (snapshot)
g_inflight_sema.wait()       // triple-buffer gate
encode draws + HUD from f    // write uniforms into ring buffer slot
commit(completion: g_inflight_sema.signal())
bf_frame_end()               // release borrow
```

No steady-state staging copies: mesh/uniform/HUD are written once into
`storageModeShared` and read in place (spec §10). The only justified copy is
the initial content/texture-atlas upload at load (one-time, not hot path).
