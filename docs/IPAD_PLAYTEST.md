# iPad playtest

Blockfall's native iPad shell runs the same Rust engine and Metal renderer as
the Mac app. The first test target is an M1-or-newer iPad running iPadOS 17 or
later.

## Build validation

From the repository root:

```bash
./ci/build-ipad.sh Release
```

This creates and validates unsigned arm64 apps for both Apple Silicon iPad
Simulator and a generic iPadOS device. It does not need access to anyone's
signing account.

## Simulator cleanup

Always shut down the simulated device and quit Simulator immediately after
playtesting so Blockfall's audio does not remain connected to hearing devices:

```bash
xcrun simctl shutdown all
osascript -e 'tell application "Simulator" to quit'
```

## Install on your iPad

1. Run the release build above, then open `ipad/BlockfallPad.xcodeproj` in
   Xcode.
2. Select the **BlockfallPad** project, then the **BlockfallPad** target.
3. Under **Signing & Capabilities**, enable **Automatically manage signing**
   and choose your Apple Developer team. If Xcode reports that
   `com.blockfall.game` is unavailable, change the bundle identifier to a
   unique reverse-DNS value owned by your team.
4. Connect the iPad by USB, unlock it, accept the trust/pairing prompt, and
   enable **Settings → Privacy & Security → Developer Mode** if Xcode asks.
5. Select the physical iPad as the run destination and press **Run**.
6. Accept Blockfall's local-network prompt when testing family multiplayer.

The Xcode run is a development install. It launches directly and is the fastest
way to start device testing; it is not a public App Store/TestFlight build.

## Controls

- Left thumb joystick: move; push it far to sprint.
- Drag an empty part of the world: look.
- Tap the world: place, open, use, or talk at the crosshair.
- Press and hold the world: mine or attack until you release.
- Hold **JUMP** / **▼**: jump or fly up / descend or sneak.
- Tap hotbar slots to equip them. **PACK** opens inventory, crafting, and
  armor controls.
- **Ⅱ** pauses. The pause card can change touch-control size, switch modes,
  or host/join a LAN game.
- An Xbox/PlayStation-style controller is also supported: sticks move/look,
  A/B jump/descend, triggers mine/use, Y opens the pack, D-pad changes slots,
  and Menu pauses.

## Device acceptance pass

Use a fresh iPad World and check each item:

1. **Launch/render:** the loading card disappears into a playable world; no
   black frame, missing content, or clipped controls appears in either
   landscape orientation.
2. **Touch:** walk, turn, sprint, jump, mine a block, place/use a block, and
   change hotbar slots. Verify that a quick world tap uses but does not mine,
   a hold mines continuously and stops immediately on release, and a look drag
   performs neither action. Repeat while holding the movement joystick with
   the other thumb. Try all three touch-control sizes from the pause card.
3. **Interfaces:** open/close the pack, craft an available item, equip armor,
   open/take from/close a loot barrel, and finish a villager dialogue without
   trapping input.
4. **Pause:** pause while villagers or monsters are visible. World simulation
   and held actions must stop; Resume must restore input once.
5. **Save/suspend:** move somewhere recognizable and change the world. Swipe
   Home, wait at least ten seconds, reopen Blockfall, then force-quit and
   relaunch. Position, inventory, time, quests, villages, explored map data, and
   edited blocks must survive.
6. **Audio/lifecycle:** backgrounding stops music and sound; returning resumes
   them once. Test with the silent switch, another audio app, an interruption,
   and Bluetooth headphones. Gameplay must continue even if audio is
   unavailable.
7. **Controller:** connect a controller before launch and repeat move/look,
   mine/use, hotbar, pack, and pause.
8. **LAN:** put a Mac and iPad on the same non-guest Wi-Fi. Host on one, join
   nearby on the other, then confirm both players can move and see the same
   block edit.
9. **Stability:** play for 20 minutes while flying quickly through several
   biomes. Watch for thermal warnings, memory termination, long hitches,
   unloaded chunks, or sustained frame-rate trouble. Repeat once at an
   8-chunk render distance if the device is under pressure.

Record the iPad model, iPadOS version, free storage, controller model, and any
reproduction seed/coordinates with every failure.

## Current test-shell scope

This first device build opens one automatic world named **iPad World**. It is
meant to validate the engine, renderer, touch/controller play, saving, audio,
and LAN multiplayer on real hardware. The Mac world picker, full map screen,
character editor, graphics/options panels, and in-app updater have not yet been
ported to the iPad shell.

## TestFlight after the device pass

Once the direct install is healthy:

1. Create the app record in App Store Connect with the final bundle ID.
2. In Xcode, choose **Product → Archive** using **Any iOS Device (arm64)**.
3. In Organizer choose **Distribute App → App Store Connect → Upload** and
   keep automatic signing enabled.
4. Add the processed build to an internal TestFlight group first. After its
   smoke pass, add external testers and submit the beta build for review.

Increment `CURRENT_PROJECT_VERSION` for every uploaded build. TestFlight
handles future beta updates; the Mac Sparkle/GitHub updater is not used on
iPadOS.
