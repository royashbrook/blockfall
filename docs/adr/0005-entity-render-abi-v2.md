# ADR 0005 — Entity render data in the C ABI (ABI v2)

Status: Accepted (M3 / creatures)

## Context
Creatures (passive animals, night mobs, bosses) must be drawn, but the frozen
`bf_render_frame` (ABI v1) only carries chunk-mesh draws — there was no way to
hand per-entity transforms to the renderer.

## Decision
Bump `BF_ABI_VERSION` 1 → 2. Add a POD `bf_entity_draw` and two fields to the
end of `bf_render_frame`:

```c
typedef struct bf_entity_draw {
    bf_vec3  position;   float yaw;
    bf_vec3  color;      float scale;
    uint32_t kind;       // creature archetype (renderer may vary the model)
    float    sat;        // per-region Dim saturation at the entity
    uint32_t _pad;
} bf_entity_draw;
// in bf_render_frame, after `regions`:
const bf_entity_draw* entities;
uint32_t              entity_count;
```

The engine owns the array (like `draws`), borrowed between acquire/end. The
renderer draws a small blocky model (body + head) per entity with a model
matrix built from position/yaw/scale, tinted by `color` and desaturated by
`sat` (so animals in Dim regions are grey too).

## Consequences
- Additive at the struct tail; app + engine rebuild together against the new
  header (build.sh copies it). The ABI-version check rejects a stale mismatch.
- A second tiny render pipeline (unit cube) is added; chunk rendering is
  unchanged.

## Breakage if wrong
If entity counts grow huge, this flat per-frame array would need instancing /
culling; the array form is fine for M3's dozens of creatures and can be
swapped behind the same ABI later.
