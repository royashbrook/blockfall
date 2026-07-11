# ADR 0007 — Entity role/action sidecar (ABI v28)

Status: Accepted (#254 villager routines)

## Context

Villager work must be simulation-authored and visibly distinct, but
`bf_entity_draw` is a frozen 44-byte render contract with no profession or
action field. Inferring work from movement would make a stopped, blocked, or
missing-station villager animate falsely.

## Decision

Bump `BF_ABI_VERSION` 27 → 28 and add a separate borrowed sidecar:

```c
typedef struct bf_entity_role_action {
    uint32_t role;
    uint32_t action;   /* 1 idle, 2 travel, 3 work, 4 return home */
    float    progress;
    uint32_t _pad;
} bf_entity_role_action;

typedef struct bf_entity_role_action_view {
    const bf_entity_role_action* entries;
    uint32_t count;
    uint32_t _pad;
} bf_entity_role_action_view;

BF_API bf_result bf_entity_role_actions(
    bf_engine e, bf_entity_role_action_view* out);
```

The array is engine-owned, borrowed through `bf_frame_end`, and index-aligned
with the acquired frame's `entities` array. Non-villager entries are zero.
`bf_entity_draw` and `bf_render_frame` do not change layout.

## Consequences

- Renderer work poses are driven by authoritative routine state and progress.
- Old saves need no migration: creatures are transient and repopulate normally.
- Future professions can use the same sidecar without another draw-layout change.
- Calling the query without an acquired frame returns `BF_ERR_NOT_READY`.

## Breakage if wrong

The sidecar and draw array must always have equal counts and identical ordering;
the engine asserts this while building each frame and parity tests pin both new
POD layouts while retaining the 44-byte draw assertion.
