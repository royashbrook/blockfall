# Performance — current state & next steps

Gate: 60 FPS median / <10 GB on an M1 Air. Dev-box smoke (`ci/check.sh --perftest`)
currently ~104 FPS median / ~66 1%-low / ~320 MB at render distance 16.

## Biggest lever: async/threaded chunk pipeline (#25)
Worldgen + flood-lighting + greedy meshing all run **synchronously on the frame
thread** today. At larger render distance (#5) this is the dominant frame cost and
the 1%-low killer (each chunk that streams in stalls the frame). The `jobs.hpp`
work-stealing scheduler exists but is **not wired** to streaming.

Plan:
1. Generation (`TerrainGen::generate`) is a pure function of (seed, coord) → run on
   E-core (Utility QoS) jobs; main thread enqueues, collects finished chunks.
2. Lighting + meshing per chunk → P-core (Interactive QoS) jobs; results uploaded
   to GPU buffers on the main thread (UMA `storageModeShared`).
3. Keep a bounded ring of in-flight jobs; apply finished meshes a few per frame so
   uploads don't spike. Preserve determinism (no shared mutable state in gen).

## Other levers
- **Frustum + distance cull** before enqueuing draws (skip chunks outside the view
  cone). Cheap CPU win that compounds with render distance.
- **LOD / coarser far chunks**: at high render distance, mesh distant chunks at
  reduced detail or merge them. Large win for #5.
- **Greedy-mesh cost**: profile `mesher.cpp`; cache the per-chunk surface/height
  grid (already done in worldgen) and avoid re-meshing chunks whose light only
  changed at interior cells.
- **Light-removal BFS** (see ADRs / lighting.hpp note): the current relight is
  increase-only; a proper two-queue removal avoids redundant relights on edits.
- **Buffer churn**: reuse retired GPU buffers of matching size instead of
  alloc/free each remesh.
- **Per-frame allocations**: keep the draw/entity vectors reserved; avoid
  per-frame heap in hot paths (HUD/craftable already de-churned).

## Watch-outs
- The frame-thread streaming budget (`GEN_BUDGET`/`MESH_BUDGET`) is the current
  knob trading pop-in vs hitch; async meshing should make it far less sensitive.
- Surface height is now 1-Lipschitz via a cone limiter + per-chunk cache + a
  thread-local anchor memo (keep it thread-safe if gen moves off-thread).
