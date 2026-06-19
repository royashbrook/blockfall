# ADR 0004 — Per-voxel light stored in the chunk

Status: Accepted (M2 / Track F)

## Context
Lighting (Track F) needs per-voxel sky + block light, and the greedy mesher
(Track D) must read those values to write `sky_light`/`block_light` into each
`BFVertex` (frozen layout, formats.md §4). The mesher only receives an
`IChunkStore` — it has no lighting handle. Options: (a) pass an `ILighting`
into `IMesher::mesh` (changes a frozen signature, ripples to every mesher
caller), or (b) store light in the chunk and read it through `IChunk`.

## Decision
Store light in the chunk. Add three **non-pure** virtuals to `IChunk` with
safe defaults so existing implementations (e.g. test fakes) keep compiling:

```cpp
virtual std::uint8_t sky_light(int,int,int)   const { return 15; } // default: lit
virtual std::uint8_t block_light(int,int,int) const { return 0;  }
virtual void set_light(int,int,int, std::uint8_t sky, std::uint8_t block) {}
```

`PaletteChunk` overrides them with a per-voxel light array (sky nibble + block
nibble packed in one byte). The lighting pass (`FloodLighting`, Track F) writes
into the chunk; the mesher reads the light of the air cell adjacent to each
emitted face and includes (material, sky, block) in the greedy-merge key so a
merged quad has uniform light.

This is an **additive** interface change — `IMesher::mesh`'s frozen signature
is untouched, and no caller breaks.

## Consequences
- A non-uniform chunk carries a 4096-byte light array (one byte/voxel). Uniform
  (air) chunks store none (they don't mesh). Acceptable for the Air budget.
- Greedy merging now also splits on differing light, so lit gradients (cave
  mouths, torch falloff) produce more — but correct — quads. Flat-lit surfaces
  still merge fully.
- Lighting recomputes when a chunk is dirty; boundary changes re-dirty
  neighbors so light bleeds across chunks and settles over a few frames.

## Breakage if wrong
If per-voxel light proves too costly on the Air, the fallback is a coarser
per-column skylight + screen-space block light, which would not need this
storage. The default-valued virtuals mean reverting is localized.
