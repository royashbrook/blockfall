# Constructed materials #337 — validation evidence

Captured 2026-07-27 from the optimized release build on the development Mac.

The `--materialshot` courtyard uses Blockfall's shipping packed terrain vertex
format and shipping `vmain` / `fmain` Metal shaders. It is deterministic and does
not depend on world streaming. With `BF_MATERIAL_SET=constructed`, its nine pads
cover the real material IDs emitted by village, city, ruin, tower, castle, bed,
door, loot-barrel, gate, social-prop, and artisan-workstation meshes.

Screen layout, nearest row first:

| screen left | screen middle | screen right |
| --- | --- | --- |
| oak + birch boards | pine log + oak boards | oak + birch logs |
| mossy stone + remaining brick | stone + clay brick | raw stone + laid cobble |
| door + crafting wood | loot-barrel oak + worked iron | wool + stitched quilt |

Each pad has a floor and four-block upright surface. This exercises end grain,
bark direction, board courses and joins, masonry scale, mortar, chips, moss,
weave, quilting, barrel staves, door panels, and forged-metal response.

## Lighting, distance, and cel matrix

Cel Shading off is the primary look. Cel Shading on remains a secondary
regression mode.

### Daylight

| distance | cel off | cel on |
| --- | --- | --- |
| near | [PNG](day-near-cel-off.png) | [PNG](day-near-cel-on.png) |
| middle | [PNG](day-mid-cel-off.png) | [PNG](day-mid-cel-on.png) |
| far | [PNG](day-far-cel-off.png) | [PNG](day-far-cel-on.png) |

### Dusk

| distance | cel off | cel on |
| --- | --- | --- |
| near | [PNG](dusk-near-cel-off.png) | [PNG](dusk-near-cel-on.png) |
| middle | [PNG](dusk-mid-cel-off.png) | [PNG](dusk-mid-cel-on.png) |
| far | [PNG](dusk-far-cel-off.png) | [PNG](dusk-far-cel-on.png) |

### Interior light

| distance | cel off | cel on |
| --- | --- | --- |
| near | [PNG](interior-near-cel-off.png) | [PNG](interior-near-cel-on.png) |
| middle | [PNG](interior-mid-cel-off.png) | [PNG](interior-mid-cel-on.png) |
| far | [PNG](interior-far-cel-off.png) | [PNG](interior-far-cel-on.png) |

### Grey saturation

| distance | cel off | cel on |
| --- | --- | --- |
| near | [PNG](grey-near-cel-off.png) | [PNG](grey-near-cel-on.png) |
| middle | [PNG](grey-mid-cel-off.png) | [PNG](grey-mid-cel-on.png) |
| far | [PNG](grey-far-cel-off.png) | [PNG](grey-far-cel-on.png) |

The materials remain distinguishable by value, scale, and motif when hue is
drained. Fine marks fade with distance while the broader board, brick, cobble,
and fabric structures remain readable. Cel mode disables the old generic fake
bump that previously snapped into dark worm-like toon contours; authored colour
motifs remain.

## Camera-motion comparisons

- Slow yaw: [−4°](yaw-minus-4.png), [0°](day-near-cel-off.png),
  [+4°](yaw-plus-4.png)
- Parallel strafe: [−1 block](strafe-minus-1.png),
  [0 blocks](day-near-cel-off.png), [+1 block](strafe-plus-1.png)

All choices derive from world position and stable material-cell identity.
Camera yaw never seeds, selects, or remeshes a pattern.

## Reproduce

From the repository root after a release build:

```bash
BF_MATERIAL_SET=constructed BF_MATERIAL_LIGHT=day \
BF_MATERIAL_VIEW=near BF_CEL=0 \
  app/.build/release/BlockfallApp \
  --materialshot /tmp/constructed-day-near.png

BF_MATERIAL_SET=constructed BF_MATERIAL_LIGHT=grey \
BF_MATERIAL_VIEW=far BF_CEL=1 \
  app/.build/release/BlockfallApp \
  --materialshot /tmp/constructed-grey-far-cel.png

BF_MATERIAL_SET=constructed BF_MATERIAL_LIGHT=day \
BF_MATERIAL_VIEW=near BF_MATERIAL_YAW=4 BF_CEL=0 \
  app/.build/release/BlockfallApp \
  --materialshot /tmp/constructed-yaw.png
```

`BF_MATERIAL_LIGHT` accepts `day`, `dusk`, `interior`, or `grey`.
`BF_MATERIAL_VIEW` accepts `near`, `mid`, or `far`.

## Same-machine performance A/B

Normal fixed-camera scene, 15 seconds:

| metric | before | after | change |
| --- | ---: | ---: | ---: |
| median FPS | 296.7 | 294.2 | −0.8% |
| 1%-low FPS | 222.5 | 223.5 | +0.4% |
| median frame | 3.371 ms | 3.399 ms | +0.8% |
| median GPU | 1.278 ms | 1.228 ms | −3.9% |
| ≥33.3 ms frames | 0 | 0 | unchanged |

Two-times-resolution cel/PBR visual stress, 10 seconds:

| metric | before | after | change |
| --- | ---: | ---: | ---: |
| median FPS | 220.3 | 221.9 | +0.7% |
| 1%-low FPS | 175.0 | 177.9 | +1.7% |
| median frame | 4.540 ms | 4.508 ms | −0.7% |
| median GPU | 2.298 ms | 2.203 ms | −4.1% |
| ≥33.3 ms frames | 0 | 0 | unchanged |

Both `ci/perf_compare.py` comparisons passed. Raw JSON is stored in this
directory as `bf337-before-normal.json`, `bf337-after-normal.json`,
`bf337-before-stress.json`, and `bf337-after-stress.json`.

## Automated validation

`./ci/check.sh` passed after the final shader optimization:

- 181 Rust unit tests passed, 6 ignored;
- coop, map, network, and 82 world integration tests passed;
- all 36 content files passed schema validation;
- the release app, Swift/Rust self-test, dialogue probe, render probe,
  washout/night probes, headless perf gate, and Rust lint passed.

## Live playtest still required

Keep GitHub issue #337 open until a player confirms:

- logs, planks, roofs, stone, cobble, and brick across a village, city, ruin,
  tower, and castle in daylight and dusk;
- doors while opening/closing, beds, benches, broom stands, every artisan
  workstation, filled/empty loot barrels, and iron gates;
- the same locations after walking away, chunk reload, save/load, and nearby
  block edits;
- cel shading off first, then on, including indoor and Grey lighting;
- slow yaw, pitch, strafe, walking, and flying at near/middle/far distances;
- no shimmer, angle-dependent marks, obvious repeated noise, z-fighting, or
  interaction/collision regressions.
