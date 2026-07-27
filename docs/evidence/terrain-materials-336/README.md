# Terrain materials #336 — validation evidence

Captured 2026-07-27 with the release build on the development Mac.

The `--materialshot` fixture uses the shipping packed terrain vertex format and
the shipping `vmain` / `fmain` Metal shaders. It does not depend on asynchronous
world streaming. Pad layout, nearest row first:

| left | middle | right |
| --- | --- | --- |
| grass | dirt | sand |
| gravel | clay | snow |
| ice | swamp dirt + clay | Grey stone + dirt |

Each pad includes exposed side faces. The split swamp and Grey pads exercise
their two constituent materials and the Grey pad uses drained saturation.

## Distance and cel-shading matrix

| | cel shading off | cel shading on |
| --- | --- | --- |
| near | [PNG](near-cel-off.png) | [PNG](near-cel-on.png) |
| middle | [PNG](mid-cel-off.png) | [PNG](mid-cel-on.png) |
| far | [PNG](far-cel-off.png) | [PNG](far-cel-on.png) |

The near view retains material marks. The middle view softens them. The far view
keeps only broad color variation, with no high-frequency motif or generic bump
field left to shimmer.

## Camera-motion comparisons

- Slow yaw: [−4°](yaw-minus-4.png), [0°](near-cel-off.png),
  [+4°](yaw-plus-4.png)
- Parallel strafe: [−1 block](strafe-minus-1.png),
  [0 blocks](near-cel-off.png), [+1 block](strafe-plus-1.png)

All material functions use world position only. Camera position controls only
the smooth near-detail fade, and camera yaw never seeds or selects a pattern.

## Reproduce

From `app/` after a release build:

```bash
BF_MATERIAL_VIEW=near BF_CEL=0 \
  .build/release/BlockfallApp --materialshot /tmp/material-near.png

BF_MATERIAL_VIEW=mid BF_CEL=1 \
  .build/release/BlockfallApp --materialshot /tmp/material-mid-cel.png

BF_MATERIAL_VIEW=near BF_MATERIAL_YAW=4 \
  .build/release/BlockfallApp --materialshot /tmp/material-yaw.png

BF_MATERIAL_VIEW=near BF_MATERIAL_STRAFE=1 \
  .build/release/BlockfallApp --materialshot /tmp/material-strafe.png
```

## Same-machine performance A/B

Normal fixed-camera scene, 15 seconds:

| metric | before | after | change |
| --- | ---: | ---: | ---: |
| median FPS | 284.9 | 282.6 | −0.8% |
| 1%-low FPS | 182.0 | 212.6 | +16.8% |
| median frame | 3.510 ms | 3.538 ms | +0.8% |
| median GPU | 1.198 ms | 1.185 ms | −1.1% |
| ≥33.3 ms frames | 1 | 0 | improved |

Two-times-resolution cel/PBR visual stress, 10 seconds:

| metric | before | after | change |
| --- | ---: | ---: | ---: |
| median FPS | 216.7 | 220.6 | +1.8% |
| 1%-low FPS | 164.7 | 165.4 | +0.4% |
| median frame | 4.617 ms | 4.533 ms | −1.8% |
| median GPU | 2.247 ms | 2.263 ms | +0.7% |
| ≥33.3 ms frames | 0 | 0 | unchanged |

Both `ci/perf_compare.py` comparisons passed. Raw JSON is stored beside the
other evidence as:

- `terrain-material-perf-before-2026-07-27.json`
- `terrain-material-perf-after-2026-07-27.json`
- `terrain-material-stress-before-2026-07-27.json`
- `terrain-material-stress-after-2026-07-27.json`

## Live playtest still required

Keep GitHub issue #336 open until a player confirms:

- grass-to-dirt contacts on cliffs and freshly dug blocks;
- desert dunes, beaches, and shorelines;
- gravel and clay in caves and swamp pockets;
- snow/ice transitions and existing footprints;
- Grey terrain before and after restoration;
- chunk seams while walking, slow turning, and flying;
- cel shading both off (primary look) and on.
