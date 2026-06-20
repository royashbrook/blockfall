# ADR 0006 — Craftable-recipe list in the HUD (ABI v3)

Status: Accepted (polish pass)

## Context
Crafting worked (Q = craft first available) but was invisible — players had no
way to see what they could make, so it felt broken. The HUD needs the set of
recipes the player can currently craft.

## Decision
Bump `BF_ABI_VERSION` 2 → 3. Add to `bf_hud_state`:

```c
bf_hud_slot craftable[8];   // result item + count for each craftable recipe now
uint8_t     craftable_count;
```

The engine fills this each frame (recipes whose ingredients are in the
inventory, capped at 8). The inventory HUD shows these as result icons; pressing
1–8 while the inventory is open sends `BF_ACT_CRAFT` with `arg_i` = the index,
and the engine crafts that specific recipe (arg_i < 0 keeps the old
"first available" behavior for the Q key).

## Consequences
- Additive at the tail of `bf_hud_state`; app + engine rebuild together.
- Computing craftability each frame is cheap (≤31 recipes × small grids).

## Breakage if wrong
If the recipe set grows large, the cap-8 list would need scrolling/paging; the
flat array is fine for the current ~31 recipes.
