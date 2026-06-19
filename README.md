# Blockfall

A Minecraft-faithful voxel sandbox for kids 7–10, built on Apple Silicon.
C++23 core (`blockcore`) + Swift/Metal app shell, talking over a frozen C ABI.

> Mechanics, controls, and feel mirror Minecraft exactly. **All art, names, and
> content are original** — no copied assets, textures, names, or lore.

## Status — M0 ✅ · M1 ✅ · M2 ◑ (streaming procedural world + Dim + save/load)

**M2 — mostly done.** Procedural streaming world with the color-restoration
mechanic and persistence.
- [x] **Track C** deterministic worldgen: value-noise fBm terrain, 3 biomes
      (plains/hills/desert), water + sand beaches, 3D-noise caves; seam-free,
      hash-verified deterministic
- [x] **Streaming**: generate chunks around the player (budgeted, nearest-first),
      evict distant ones; tight per-chunk GPU allocation (Air memory budget)
- [x] **Dim mechanic**: per-region saturation → luminance-preserving shader
      desaturation; grey unrestored regions bloom to color when restored (spawn,
      or place a glow block)
- [x] **Day/night** sun-driven shading; **save/load** (edits + player + regions
      persist; procedural chunks regen from seed)
- [ ] **Track F** incremental lighting (sun + block-light flood-fill) — the
      remaining M2 piece

**M0 — done.** Interface contract frozen, app runs end to end.
**M1 — done.** Mine & place blocks in a greedy-meshed voxel world, rendered.
- [x] **Track A** jobs + memory: work-stealing scheduler (P/E QoS pools), DAG
      deps, help-on-wait; linear + pool arenas. (Fixed a slot-recycle data race
      found via thread sampling.)
- [x] **Track B** palette-compressed chunk storage + lossless save/load round-trip
- [x] **Track D** greedy meshing → UMA buffers. (Fixed a face-winding bug — back
      faces were culled — now guarded by a geometric winding test.)
- [x] **Track E** Metal forward renderer: runtime-compiled stylized shader,
      depth-tested chunk draws, day/night sky, deferred buffer frees
- [x] **Track G** player free-fly + mouse-look, voxel raycast, hold-to-mine /
      click-to-place, hotbar
- [x] **Track J content** (data): 40 blocks, 58 items, 31 recipes, 11 creatures,
      5 biomes, 5 structures, 13 loot tables, 15 quests, 3 dialogue trees

`ci/check.sh` GREEN: 7 unit tests (incl. job stress + mesh winding), the
headless mine/place integration test, an offscreen **render test (95% of pixels
are terrain)**, content validation, and lint (0 warnings).

**Controls:** click to capture mouse · WASD move · mouse look · space/shift up
/down · left-hold mine · right-click place · 1–6 hotbar · Esc release mouse.

**Next — M2:** streaming procedural world (Track C), save/load to disk,
incremental lighting (Track F), day/night, Dim desaturation. See `docs/ROADMAP.md`.

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
