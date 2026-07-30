# iPad lifecycle evidence — issue #348

Validated July 30, 2026 with the iPad Pro 11-inch (M5), iPadOS 26.5
Simulator and the Debug iPad target.

1. Launched Blockfall with an empty `iPad World` save directory.
2. Used Simulator's Home control to produce a real
   `sceneWillResignActive` / `sceneDidEnterBackground` transition.
3. Confirmed the app wrote `world.meta`, `player.dat`, `map.dat`,
   `villages.dat`, `chests.dat`, and edited chunk files.
4. Read the checkpointed player position as
   `(31769.5, 20.60038, 1530.5)`.
5. Hard-terminated Blockfall, relaunched it, and confirmed the HUD loaded at
   the same rounded coordinates `(31770, 21, 1531)` with a healthy world frame.

`checkpoint-relaunch.png` is the inspected post-relaunch frame.

Fresh unsigned Release simulator and generic iPad-device builds completed
successfully. The device bundle validated as arm64, iPad-only
(`UIDeviceFamily [2]`), iPadOS 17+, with production content present.

The full repository check was green: Rust unit/integration/network/map/world
tests, content validation, Swift/Rust self-tests, render and lighting probes,
lint, and the performance gate (104.9 median FPS, 51.8 FPS 1%-low, 780 MB
peak on the development Mac).

Physical-device signing and the manual acceptance pass remain the playtester's
steps because they require choosing an Apple Developer team and a connected
iPad.
