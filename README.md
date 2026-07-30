# Blockfall

**A cartoon-styled voxel adventure about bringing colour back to a world touched
by the Grey.** Explore, mine, build, help villages grow, and face strange
creatures in a living block world.

## Play

[Download Blockfall for macOS](https://github.com/royashbrook/blockfall/releases/latest)

Blockfall currently supports **Apple Silicon Macs running macOS 14 or later**.
Open the DMG, drag Blockfall to Applications, then launch it normally.

## What you can do

- Explore a procedural world of varied biomes, ruins, villages, cities, and
  dangerous landmarks.
- Mine, place, collect, and craft in Survival; switch to Creative to build and
  explore freely.
- Meet animated villagers, trade and donate resources, and help a Village grow
  into a defended City.
- Restore colour and safety to areas claimed by the Grey.
- Encounter friendly animals, roaming monsters, bosses, and nighttime threats.
- Customize your character, follow the world map, and take on quests.

## Controls

| Action | Control |
| --- | --- |
| Move / look | WASD / mouse |
| Jump / descend | Space / Shift |
| Mine / place | Hold left click / right click |
| Hotbar | 1–6 |
| Inventory / crafting | E / Q |
| Survival / Creative | C |
| World map / pause | M / Esc |

Click the game window to capture the mouse. Press Esc to release it or open
the pause menu.

## Updates

Blockfall checks the public GitHub release feed for signed updates. Use
**Blockfall → Check for Updates…** at any time; future releases install from
inside the app.

## Build from source

Developers need an Apple Silicon Mac, Xcode with the macOS and iPadOS SDKs, and
rustup (`brew install rustup`). From a checkout:

```bash
./ci/check.sh
./ci/build.sh debug
open build/Blockfall.app
```

The engine can also be built by itself:

```bash
./ci/build-xcframework.sh
```

That one command produces `app/Artifacts/CBlockcore.xcframework` with macOS,
iPadOS-device, and Apple Silicon iPad-simulator slices. The future iPad app
will consume the same Rust engine artifact; only its native Swift UI shell is
separate. Technical notes and release instructions live in [`docs/`](docs/).

## License

Blockfall is available under the [MIT License](LICENSE). Bundled dependency
licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
