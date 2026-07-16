# Blockfall

A Minecraft-faithful voxel sandbox for kids 7–10, built on Apple Silicon.
C++23 core (`blockcore`) + Swift/Metal app shell, talking over a frozen C ABI.

> Mechanics, controls, and feel mirror Minecraft exactly. **All art, names, and
> content are original** — no copied assets, textures, names, or lore.

## Status — M0–M5 ✅ implemented (3 acceptance gates are on-device)

All six milestones are built, integrated, and green on a clean checkout
(`ci/check.sh`: 16 unit tests + content validation + render + perf smoke + lint).

- **M0** contract frozen · **M1** mine/place loop · **M2** procedural streaming
  world + Dim + day/night + save/load + lighting · **M3** inventory/crafting +
  ~40 blocks + survival/creative + animals + quest · **M4** co-op (reliable UDP,
  server-authoritative convergence under loss, Bonjour) · **M5** arm64 `.dmg` +
  perf harness + content volume (9 animals + 2 bosses, 15-quest engine).

**Three gates are inherently real-hardware** and remain to verify on the target:
1. sustained 10-min **≥60 FPS / ≥30 1%-low on an M1 Air** (`--perftest 600`),
2. clean-**M1 Air install** from the `.dmg`,
3. live **2–4 Air LAN co-op**.
The dev-box (M4 Pro) reference perf has large headroom (~2670 FPS median release,
< 700 MB), and the co-op consistency core is proven headlessly at 30% loss.



**M3 — done.** The data-driven sandbox is alive.
- [x] Content registries: **40 blocks, 58 items, 31 recipes** loaded from JSON
- [x] Inventory + hotbar + stacking; **crafting** (shaped/shapeless) from the
      recipe data; survival consumes / creative infinite; mining **drops items**;
      tool-tier mining speed
- [x] **~40 blocks render** (9 hand-tuned terrain + golden-ratio hash for the rest)
- [x] **Animals**: 4 passive types wander, settle with gravity, befriend on
      interact, puff away (no death) on calm — drawn as body+head blocky models
- [x] **Quest** ("Bring back the color"): light a Dim region + befriend an animal
- [x] inventory HUD; **E** inventory · **C** creative/survival · **Q** craft
- ABI v2 (entity render, ADR 0005)

Earlier milestones below.

## (history) M2 — streaming procedural world + Dim + save/load + lighting ✅

**M2 — done.** Procedural streaming world with the color-restoration mechanic,
persistence, and full lighting.
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
- [x] **Track F** lighting: per-voxel sky + block-light flood-fill (caves dark,
      glow casts light, night dims), incremental on edit

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
./ci/package.sh          # -> dist/Blockfall-0.1.0.dmg (arm64, signed + notarized)
./ci/release.sh          # notarize + publish DMG/appcast to GitHub Releases
open build/Blockfall.app # or run the headless boundary test:
build/Blockfall.app/Contents/MacOS/Blockfall --selftest
```

### Prerequisites (build box only)
- Xcode + Apple Clang (C++23), Swift 6.x, macOS 14+ SDK
- CMake ≥ 3.28 (`brew install cmake`)
- For precompiled shaders (Track E): `xcodebuild -downloadComponent MetalToolchain`
  (see `docs/adr/0003-metal-toolchain-prereq.md`). Not needed for M0.

Clients need an Apple Silicon Mac running macOS 14 or newer and the `.dmg`.
See [`docs/RELEASING.md`](docs/RELEASING.md) for Developer ID setup and releases.

## The contract is law

`/contract` beats prose on any conflict. Changing the C ABI, an internal
interface, or a binary/wire/schema format requires an ADR in `docs/adr` and a
`BF_ABI_VERSION` bump where it crosses the boundary. See `docs/adr/0001`.

## License

Blockfall is available under the [MIT License](LICENSE). Bundled dependency
licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
