# Blockfall

A Minecraft-faithful voxel sandbox for kids 7–10, built on Apple Silicon.
C++23 core (`blockcore`) + Swift/Metal app shell, talking over a frozen C ABI.

> Mechanics, controls, and feel mirror Minecraft exactly. **All art, names, and
> content are original** — no copied assets, textures, names, or lore.

## Status — M0 ✅ complete · M1 in progress

**M0 (Phase 0) — done.** Interface contract frozen, stub app runs end to end.
- [x] `/contract` compiles (C ABI + internal C++ interfaces, both clean)
- [x] Format/threading specs written and versioned
- [x] Stub `.app` launches, clears a sky-colored frame, shows a HUD overlay
- [x] `ci/check.sh` GREEN: core build, unit tests, content validation, Swift↔C++
      self-test, lint (0 warnings)

**Toward M1 — landed so far:**
- [x] **Track A** (jobs + memory): work-stealing scheduler with P/E QoS pools,
      DAG deps, help-on-wait; linear + pool arenas. Tested (DAG order, 20k
      fan-out, 200-deep chain, 18k concurrent-submit stress). Fixed a real
      slot-recycle data race found via thread sampling.
- [x] **Track J content** (data): 40 blocks, 58 items, 31 recipes, 11
      creatures, 5 biomes, 5 structures, 13 loot tables, 15 quests, 3 dialogue
      trees — schema-valid, cross-references resolve, no dangling refs.

**Next (M1 critical path):** B chunk storage → D greedy meshing → E renderer,
with G physics/collision alongside. Then: point, hold-to-mine, place, instant
remesh. See `docs/ROADMAP.md`.

## Layout (spec §5)

```
/engine    C++23 core (CMake lib `blockcore`)  — currently a Phase-0 stub
/app       Swift app (SwiftPM), links blockcore via the C ABI, HUD/UI
/shaders   .metal + compiled .metallib step (Track E)
/content   JSON content + schemas (data-driven; schemas frozen in Phase 0)
/contract  engine_c_api.h + internal interfaces + format/threading specs (FROZEN)
/assets    textures, sounds (bundled into the .app)
/tests     unit + integration + perf + content-validation
/ci        build.sh, check.sh, package.sh
/docs/adr  decision records
```

## Build & run

```bash
./ci/build.sh debug      # -> build/Blockfall.app
./ci/check.sh            # the green-bar gate (must pass before anything is "done")
./ci/package.sh          # -> dist/Blockfall.dmg (arm64, ad-hoc signed)
open build/Blockfall.app # or run the headless boundary test:
build/Blockfall.app/Contents/MacOS/Blockfall --selftest
```

### Prerequisites (build box only)
- Xcode + Apple Clang (C++23), Swift 6.x, macOS 14+ SDK
- CMake ≥ 3.28 (`brew install cmake`)
- For precompiled shaders (Track E): `xcodebuild -downloadComponent MetalToolchain`
  (see `docs/adr/0003-metal-toolchain-prereq.md`). Not needed for M0.

Clients (the kids' M1 Airs) need none of this — just the `.dmg`.

## The contract is law

`/contract` beats prose on any conflict. Changing the C ABI, an internal
interface, or a binary/wire/schema format requires an ADR in `docs/adr` and a
`BF_ABI_VERSION` bump where it crosses the boundary. See `docs/adr/0001`.
