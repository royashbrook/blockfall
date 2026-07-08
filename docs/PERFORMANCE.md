# Performance

Target gate: sustained 10-minute run at 60 FPS median / 30 FPS 1%-low on a base M1 Air.

Current dev-box stress camera, M4 Pro, render distance 24, forest/village:

| mode | median FPS | 1%-low FPS | frame ms | engine ms | encode ms | GPU ms | notes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| default | 305.1 | 217.6 | 3.277 | 0.641 | 0.750 | 1.277 | God Rays off, shadow march 8 |
| props disabled | 295.8 | 183.6 | 3.381 | 0.676 | 0.758 | 1.045 | GPU lower, total frame not better |
| shadows disabled | 261.9 | 159.4 | 3.819 | 0.681 | 0.821 | 1.484 | not a useful default cut |

The last big win was removing default God Rays and shortening the terrain shadow march:

| before | after |
| ---: | ---: |
| 182.8 FPS median | 305.1 FPS median |
| 124.2 FPS 1%-low | 217.6 FPS 1%-low |
| 3.11 ms GPU | 1.28 ms GPU |

## Current Structure

- Rust engine streams generation and meshing on worker threads.
- Main thread collects generated chunks, uploads finished mesh buffers, builds draw lists, and encodes Metal.
- Chunk size is back to 16^3. The tested 64^3/32^3 path was slower and created too much visible/work granularity.
- Streaming is surface-first: far columns generate the visible surface band, near/player columns keep the full stack for digging and caves.
- Props are GPU-instanced and row-batched by model shape. They still cost memory/GPU, but disabling them is no longer a clear frame-time win.
- World-space voxel shadows stay enabled by default, but the march distance is tight. `BF_MARCH_DIST` is the quality/perf override.
- God Rays are a quality toggle, not a default. `BF_GODRAYS=1` / `BF_GODRAY_STR=...` are opt-in test paths.

## Next Real Work

1. Use the fatal perf-regression comparator before merging heavy content/rendering branches.
   `ci/check.sh` still has a non-fatal smoke for "unplayable"; `ci/perf_compare.py` catches material same-machine regressions.

2. Fix God Ray artifacts before re-enabling them.
   They are visually blocky in motion, and they are also expensive. Keep them off until the artifact issue is fixed.

3. Profile on a base M1 Air before cutting more visuals.
   On the current M4 Pro numbers, props-off and shadows-off did not improve total frame time. More cuts here would be speculative without M1 evidence.

## Repro Commands

```bash
BF_PERF_CAMERA=32597,23,28441,5.497787,-0.35 \
BF_PERF_SETTLE=600 \
BF_METAL_PERF_SECONDS=8 \
BF_METAL_PERF_JSON=/tmp/blockfall_perf_default.json \
./ci/perf.sh
```

Compare two same-machine runs:

```bash
ci/perf_compare.py /tmp/blockfall_perf_main.json /tmp/blockfall_perf_branch.json
```

Or run + compare in one command after saving a baseline from `main`:

```bash
BF_PERF_BASELINE_JSON=/tmp/blockfall_perf_main.json \
BF_METAL_PERF_JSON=/tmp/blockfall_perf_branch.json \
BF_METAL_PERF_SECONDS=8 \
./ci/perf.sh
```

Compare mode defaults to the forest/village stress camera and `BF_PERF_SETTLE=600`.
Override `BF_PERF_CAMERA` only when the baseline was recorded from the same alternate camera.

```bash
BF_PERF_CAMERA=32597,23,28441,5.497787,-0.35 \
BF_PERF_SETTLE=600 \
BF_METAL_PERF_SECONDS=8 \
BF_METAL_PERF_JSON=/tmp/blockfall_perf_godrays.json \
BF_GODRAYS=1 \
BF_GODRAY_STR=0.5 \
./ci/perf.sh
```
