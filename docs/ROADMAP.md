# Blockfall — Roadmap & Track Fan-out

The contract (`/contract`) is frozen (M0). Parallel tracks now build against it.
Each track owns its interface + tests and keeps `ci/check.sh` green (spec §7).

## Milestones (spec §9)

| # | Goal | Tracks | State |
|---|---|---|---|
| **M0** | Contract frozen + stub `.app` clears a frame + HUD | Phase 0 | ✅ done |
| **M1** | Mine & place one block, single chunk, greedy mesh, instant remesh | A+B+D+E+G | ▶ next |
| M2 | Streaming themed world: gen, save/load, day/night, Dim desat | +C+F | |
| M3 | Sandbox alive: inventory/hotbar/crafting, ~40 blocks, modes, animals, 1 quest | +J | |
| M4 | Co-op: host + Bonjour + 2–4 Airs sharing live edits | +H | |
| M5 | Installable & full: `.dmg` on clean Air, boss, ~12 quests, perf gate met | +I | |

## Track dependency order (what to fan out, in what order)

```
A (jobs+memory) ──┬─▶ B (chunk storage) ──┬─▶ D (meshing) ──▶ E (renderer) ──▶ M1
                  │                        │
                  └─▶ C (worldgen) ────────┘    G (ECS/physics/AI) ──▶ M1
                                              F (lighting) ──▶ remesh on edit
H (networking) builds on B+G snapshots   ·  J (gameplay/content) builds on B+G+E
I (packaging)  validated continuously    ·  Integration agent owns check.sh
```

**Track A is built first — everything depends on the job system + arenas.**

## Model-tier routing for the fan-out (spec §3)

| Track | Tier | Why |
|---|---|---|
| A Jobs & memory | **Opus** | threading/sync correctness cascades everywhere |
| B Chunk storage | Sonnet | impl against frozen `IChunkStore` |
| C Worldgen | Sonnet | deterministic gen against `IWorldGen` |
| D Meshing | Opus design → Sonnet impl | greedy mesh perf is load-bearing |
| E Renderer | Opus design → Sonnet impl | forward+ on the Air; art direction |
| F Lighting | Sonnet | flood-fill against `ILighting` |
| G ECS/physics/AI | Sonnet | systems against frozen handles |
| H Networking | **Opus** | reconciliation/consistency is subtle |
| I Packaging | Sonnet impl, Haiku scripts | mostly mechanical |
| J Gameplay+content | Sonnet systems, **Haiku** content JSON | author data cheaply |
| Integration | Sonnet (continuous) | owns `check.sh`, catches contract drift |

Content (blocks/items/recipes/creatures/quests/dialogue) is authored as data
via Haiku and validated by `tests/content/validate.py` against the frozen
schemas — never hand-written with expensive tiers (spec §3).

## M1 definition of done

Single chunk you can fly around (free-fly + AABB collision), point at a block,
hold to mine → it breaks and drops, select a block, click to place → instant
greedy remesh, stylized blocky material. The core loop, proven on M1-Air-class
behavior. Tests: input→tri-count, remesh latency budget, collision vs known
geometry, TSan-clean job stress.
