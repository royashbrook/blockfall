# Backlog validation guide — 2026-07-11

This guide validates the finished-furniture, detailed-structure, settlement,
villager-routine, creature-model, road, and caravan backlog completed in the
July 11 pass.

Changed worldgen layouts only appear in never-generated chunks. Use a new world
for the main playtest. Existing bed/station/prop block meshes and entity models
update when an old world reloads/remeshes, so an old save remains useful for the
save-compatibility checks.
Before opening an old world, duplicate its folder under
`~/Library/Application Support/Blockfall/worlds/` and test only the copy;
opening and saving it with this build upgrades its persisted data.

## Playtest follow-up repairs

### July 12 gait and frame-hitch follow-up

- Villager animation identity now includes the per-person stable clothing hash.
  Repeated names in the same home/role can no longer share one gait-history slot.
- Ambient tree regrowth uses resident chunks only. Its five-second maintenance
  tick can no longer synchronously generate missing vertical chunks on the frame thread.
- The performance harness reports p99/max frame, engine-update, and acquire times,
  plus the number of frames over 33.3 ms; median FPS alone hid the original stalls.

Manual validation:

1. Follow several villagers through a city, especially two ordinary residents walking
   near each other. Arms and legs must keep a continuous phase with no trembling or snap.
2. Roam continuously for at least two minutes, crossing chunk boundaries and turning at
   random. Repeat with effects disabled and minimum render distance. There should be no
   periodic whole-game halt around the five-second regrowth cadence.
3. Run `build/Blockfall.app/Contents/MacOS/Blockfall --perftest 20`. The `HITCH` and
   `ENGINE PHASES` lines must remain bounded. The accepted moving run reduced worst engine
   time from `250–505 ms` to `7.01 ms`; worst total frame was `35.09 ms`, with no quality
   switches and a passing same-machine perf comparison.

The first live pass found four follow-up defects, now covered by this build:

- Solo pause and the world map hold simulation state completely. Villager comic
  chatter uses the same paused clock instead of continuing on wall time.
- Pause-menu typography uses the same 1–2x multiplier and comparable base sizes
  as the HUD. The Text Size control no longer rebuilds its own view while tracking;
  title/actions stay pinned and compact windows use scrollable responsive columns.
- `world.meta` now preserves the automatic world clock. A pre-fix save has no time
  trailer and therefore still opens at the legacy dawn fallback once; save it with
  this build before testing the next reload.
- A villager walks to the clear cell west of the communal bench for collision and
  pathfinding, but the seated render pose is aligned on the seat, faces back toward
  the room, and omits the otherwise floating full-voxel contact shadow.

Communal benches and artisan workstations are villager routine props, not player
crafting interfaces. Players can inspect, hold, place, and break them; their active
use is intentionally shown by the matching resident.

### Follow-up manual regression

1. Wait for a two-line villager comic bubble, press `Esc`, and leave the game paused
   for at least 10 seconds. The speaker/line, world clock, villagers, creatures, sun,
   and caravan must not advance. Resume and confirm they continue normally. Repeat
   once from the world map. Multiplayer intentionally does not pause the shared world.
2. In the pause menu, try Text Size at `1.0x`, `1.5x`, and `2.0x`. At each size,
   close/reopen the menu, click the slider track, drag the knob, and resize down to
   the 560×440 minimum. Text Size and all four action buttons must remain visible or
   vertically reachable; fonts must not grow again per reopen or jump during tracking.
3. Let automatic time reach a clearly non-dawn phase, use **Save & Go to Menu**, then
   reload. The HUD must return to the same phase/time, not 06:00 dawn. Perform the
   first save with this build so the optional `BFTM` trailer exists.
4. Observe an Elder/resident use the communal bench. The collision body approaches
   from the west, but the visible body must sit on the wooden seat facing outward;
   it must not squat beside the bench or cast a floating shadow above it.

## July 12 visual and menu follow-up

The next live pass repaired six more presentation regressions:

- The full-screen pause dimmer now contains a bounded panel centered on both axes.
  Its scroll document is top-origin, so a rebuild at `2.0x` opens on **Effects** and
  **Text Size**, never at the bottom of the options.
- Generated doors count shaped timber jambs when inferring their wall axis. A closed
  door covers and blocks the opening; its open state swings to the side and is passable.
- Closed City wall runs keep two solid stone courses. Shaped timber is now the cap/trim,
  not a three-block-high see-through wall column.
- Rendered creatures carry a stable animation identity. Villager gait no longer swaps
  half-block position history, and the walk adds eased stride echo, body lift/squash,
  delayed elbows/wrists, and rounded elbow joins.
- Villager heads and eye whites use the targeted smoother primitive; eyes, noses, and
  mouths are shallower and embedded against the curved face instead of floating out.
- Large leaf and berry-bush spheres use a smoother silhouette. Berries sit on three
  outer sides of the clump, and the fixed-position yaw sweep keeps tree detail attached
  to the same world crown.

### July 12 manual regression

1. Open pause at `1.0x`, `1.6x`, and `2.0x`. The dark panel—not just its buttons—must
   remain centered. At `2.0x`, **Effects** and **Text Size** must be visible immediately;
   scroll to reach the remaining effects while all four action buttons stay pinned.
   Zoom/resize the window, close/reopen pause, and repeat.
2. In a new seed-11 world, approach homes whose door walls face different compass
   directions. Before interaction, the plank slab must visibly cover the doorway and
   block walking. Interact once: it must lie against a jamb and allow passage. Interact
   again: it must cover/block the doorway. Test both the upper and lower door half.
3. Visit the starting City and walk the full inside and outside wall perimeter. Rounded
   timber may appear as corner, gate, cap, or tower detail, but every closed wall run
   must have a continuous solid lower wall plane with no full-height log-only gaps.
4. Follow at least three villagers while they cross several block boundaries and pass
   one another. Arms must not tremble or reset phase. Look for broad eased arm/leg arcs,
   a small whole-body bounce/squash on steps, delayed forearm/wrist motion, and rounded
   elbows without a visible hinge gap. Idle villagers must settle rather than walk in place.
5. Inspect villagers front-on and at a three-quarter angle, including several hair/face
   variants. Heads and eye whites should be round; pupils, nose, mouth, cheeks/freckles,
   and moustache must remain on the facial surface rather than floating in front of it.
6. Stand still near a leafy tree and berry bushes. Turn in one- or two-degree increments
   across roughly 15 degrees. Lighting/detail must remain attached to the same leaf masses;
   berries must not flicker from zero to several because of overlapping geometry. Do this
   in one live session after the view has settled: separate `--shot` processes have separate
   async mesh residency and are not a valid yaw comparison.
7. Customize two players with deliberately different skin, shirt, hair style/colour,
   eyes/colour, nose, mouth, head, and body. Host a LAN game and join from the second
   Mac. Each remote body must match its owner's editor portrait while the local arm
   matches its skin/shirt. Save a different look while connected; the other player
   must see it update without reconnecting. Add a third player if available: both
   clients must see each other, not only the host. Missing/old appearance data must
   fall back to the normal default avatar rather than corrupt geometry.

Deterministic visual/performance fixtures for the character and foliage parts:

```bash
OUT="$PWD/artifacts/playtest-2026-07-12"
BIN="$PWD/build/Blockfall.app/Contents/MacOS/Blockfall"

BF_VILLAGERS=1 BF_CEL=1 "$BIN" --critters "$OUT/villagers.png"
BF_AVATARS=1 BF_CEL=1 "$BIN" --critters "$OUT/player-avatars.png"
BF_CRITTER_MOTION=1 BF_CRITTER_KIND=20 BF_CEL=1 \
  "$BIN" --critters "$OUT/villager-motion.png"

# One deterministic reference frame. Use the live-session turn above for yaw stability.
BF_SHOT_SEED=10 BF_SHOT_RENDER_DISTANCE=8 \
  BF_SHOT_POS="170,13,62,3.22886,-0.12" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/foliage-reference.png"

BF_ENTITY_STRESS=1 BF_ENTITY_SHAPE=box \
  BF_METAL_PERF_JSON="$OUT/entity-box.json" \
  BF_PERF_SAVE_DIR="$OUT/save-box" "$BIN" --perftest 60
BF_ENTITY_STRESS=1 \
  BF_METAL_PERF_JSON="$OUT/entity-model.json" \
  BF_PERF_SAVE_DIR="$OUT/save-model" "$BIN" --perftest 60
python3 ci/perf_compare.py "$OUT/entity-box.json" "$OUT/entity-model.json"
```

The accepted same-machine result was `246.7 -> 244.5` median FPS (`-0.9%`),
`114.4 -> 102.1` 1%-low (`-10.8%`), frame time `+0.9%`, and GPU time
`+5.9%`; the comparator passed with 26,920 shaped entity triangles.

## July 13 visual-stability and tree-support follow-up

Use one settled live session for slow-turn comparisons. Separate `--shot` processes can
have different asynchronous terrain residency and are not evidence of view instability.

### God-ray occlusion (#274, #299)

1. Load the latest save near `(32333, 13, 767)`, face northeast at dawn, and also inspect
   the roof/tree edges around `(32337, 12, 779)`.
2. Disable Clouds and Lens Flare. Test God Rays at both 50% and 100% while turning slowly
   enough to move the sun behind trunks, leaves, and roof edges.
3. Pass when every bright shaft visibly converges on the sun, there is no square ray
   volume, increasing occlusion never creates a brighter line, blockers only carve dark
   corridors through rays, and fully blocked paths do not add a broad sky wash.

Run the deterministic rectangular-edge gate after a fresh release build:

```bash
BIN="$PWD/build/Blockfall.app/Contents/MacOS/Blockfall"
OUT="$PWD/artifacts/playtest-2026-07-12"
BF_SHOT_SEED=480181 \
  BF_SHOT_POS="32385,15,32671,-2.552,0.50" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_TOD=0 BF_SHOT_HELD=0 BF_GODRAY_STR=1 \
  BF_SHOT_NOFLARE=1 BF_CLOUDS=0 BF_CEL=0 \
  BF_SHOT_RENDER_DISTANCE=8 BF_SHOT_AB=1 BF_GR_EDGE_TEST=1 \
  "$BIN" --shot "$OUT/godray-edge.png"
```

The command also writes `godray-edge_off.png`. Both axis scores must be below `0.20`
and visible ray signal must exceed `0.05`; the accepted #299 follow-up is vertical
`0.047`, horizontal `0.023`, signal `0.313`. Setting `BF_GODRAY_STR=0` is the negative control:
it must fail with signal `0.000`. The headless A/B catches coherent rectangles and a
disabled ray path; live slow turning remains the decisive inverse-shadow check.

For an unambiguous maximum-strength source check, face the deterministic low sun from
an open camera. Every visible band must meet the sun instead of beginning at foliage:

```bash
BF_SHOT_SEED=11 BF_SHOT_POS="31034,38,88,-2.552,0.22" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_TOD=0 BF_SHOT_HELD=0 BF_GODRAY_STR=1 \
  BF_SHOT_NOFLARE=1 BF_CLOUDS=0 BF_CEL=0 BF_SHOT_RENDER_DISTANCE=8 \
  "$BIN" --shot "$OUT/godray-sun-authored-after.png"
```

### God-ray clear-gap occlusion (#299)

The #274 mixed-visibility gate still emitted light behind blockers because it treated
any mixture of sky and silhouette as a shaft. The replacement compares each sunward
path with two neighbouring paths. Only the clearer center gap emits; a darker center
path is clamped to zero.

1. Use the #274 deterministic command above after a fresh build. The accepted #299
   result is vertical `0.089`, horizontal `0.097`, signal `0.359`; the old shader fails
   the same current-world fixture at vertical `0.381`.
2. For the representative maximum-strength visual A/B, run:

```bash
BIN="$PWD/build/Blockfall.app/Contents/MacOS/Blockfall"
OUT="$PWD/artifacts/playtest-2026-07-12"
BF_SHOT_SEED=11 \
  BF_SHOT_POS="32411,13,11098,-2.552,0.05" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_HELD=0 \
  BF_SHOT_TOD=0 BF_GODRAY_STR=1 BF_SHOT_NOFLARE=1 BF_CLOUDS=0 BF_CEL=1 \
  BF_SHOT_RENDER_DISTANCE=12 BF_SHOT_AB=1 \
  "$BIN" --shot "$OUT/godray-clear-gap-after.png"
```

This also writes `godray-clear-gap-after_off.png`. Pass when the enabled image has
translucent rays through open gaps, solid silhouettes and their downstream paths stay
dark, clear sky is not washed white, and no black/invalid reconstruction patches appear.

### Berries and cel canopy definition (#265, #279)

1. Stand near `(32340, 13, 762)`, facing northeast in the daytime forest.
2. After streaming settles, turn one or two degrees at a time through about 15 degrees,
   first with Cel Shading on and then off.
3. Pass when the exposed berry count does not blink, canopy mass and shading remain
   attached to the same tree, and cel mode retains restrained rounded definition rather
   than becoming a flat green cutout or flashing facets.
4. Run `"$BIN" --selftest` for the deterministic canopy-shell geometry gate, and keep the
   earlier foliage reference command for a fixed visual comparison.

### Loot-barrel depth and state (#276, #277)

1. In seed 11, visit the treasure-hall barrel at `(6621, 18, 30886)`.
2. Continuously orbit all four sides from low, eye-level, and slightly high views, in
   daylight and dusk. The lower, middle, and upper hoops must never penetrate the bowed
   oak shell, swap depth ownership, cross a glowing stud, or flicker.
3. A filled barrel's crest lights must remain bright. Remove the final item to turn them
   fully off, then deposit one item to relight them. Save/reload both states and break one
   barrel to confirm existing inventory behavior remains intact.
4. Run the focused mesh gates:

```bash
cargo test --manifest-path engine-rs/bfcore/Cargo.toml \
  loot_barrel_hoops_are_closed_bands
cargo test --manifest-path engine-rs/bfcore/Cargo.toml \
  loot_barrel_hoops_swell_from_inset_edges_to_rounded_crowns
```

### Sinkhole trees and support felling (#280, #281)

Worldgen changes only affect never-generated chunks. Use a new seed-76099 world, or
chunks that the old build never generated; an existing floating tree is not repaired
retroactively.

1. Revisit the reported sinkhole around `(32470, 23, 912)` and deterministic root
   `(32501, 883)`. No trunk may begin over the carved cave opening; ordinary supported
   trees nearby must remain. Swamps deliberately keep supported trees where entrance
   noise exists but no entrance is carved.
2. Break the grass or dirt directly beneath a natural oak, birch, pine, and giant oak.
   The entire matching trunk and branches must enter the existing falling-debris path,
   the canopy must clear, and no upper crown may hover.
3. As a control, break the support below a structural log post with no matching nearby
   canopy. It must remain standing. This is guarded tree felling, not generic gravity for
   every timber used by a building.
4. Run the focused gates:

```bash
cargo test --manifest-path engine-rs/bfcore/Cargo.toml \
  no_tree_roots_over_cave_entrances
cargo test --manifest-path engine-rs/bfcore/Cargo.toml \
  swamp_tree_keeps_support_when_entrance_noise_is_present
cargo test --manifest-path engine-rs/bfcore/Cargo.toml \
  breaking_tree_support_fells_matching_canopy
cargo test --manifest-path engine-rs/bfcore/Cargo.toml \
  breaking_support_fells_max_generated_tree_log_budget
cargo test --manifest-path engine-rs/bfcore/Cargo.toml \
  breaking_support_leaves_structural_logs_standing
```

A compact oak appearing on loaded, restored grass can be intentional ambient regrowth:
the first maintenance pass occurs after three seconds, then every five seconds, and can
add up to two trees within 48 blocks. It must persist after turning away and back. A tall
biome tree that changes only with camera angle, disappears again, or does not persist is
still a streaming/render defect.

### Ambient birds (#278)

Use the live checklist below and also confirm birds are absent in caves, underwater, and
at night. `BF_SELFTEST_BIRDS=1` now renders a centered, terrain-independent three-bird
fixture in cruise, perched, and landing-flare poses. The same run exercises the
client-only state machine through cruise, elevated approach, shallow landing, exact
perch contact, and threat-driven flee transitions. Live play validates sparse density,
world perches, support removal, terrain clearance, and dusk disappearance. The fixture
fails if any expected colored bird area is missing or projected offscreen.

## What changed

- Beds are one coherent low furniture mesh with legs, rails, quilt, pillow, and
  headboard instead of two cubes.
- Settlement homes have pitched roofs, eaves, and inset timber beams.
- Woodcutters, masons, blacksmiths, herbalists, and builders have finished
  physical stations, readable held items, and distinct work shifts.
- Villagers look, gesture, greet, chat in mutual pairs, sit on a communal bench,
  and sweep with a finished broom prop. Due work shifts take priority.
- New worlds start at a dry, clear, finished walled City with detailed corner
  towers, gates, a civic landmark, shops, stations, and six professions.
- Villages promote visibly to Town and City, gain residents and open shops, and
  show the correct class in the HUD, minimap, and world map.
- Developed settlements gain deterministic graded gravel/cobble roads and plank
  boardwalks. Roads preserve player solids and rebuild from settlement state.
- One nearby deterministic caravan travels a route, completes deliveries, and
  changes bounded destination trade stock. Progress and stock survive save/load.
- Ruins, keeps, and towers have irregular rubble, broken arches, buttresses,
  weathering, shaped crowns, and restrained material variation.
- Villagers and the passive/hostile creature rosters use rounded low-poly parts,
  clearer faces, eased joint lag, and floppy follow-through while retaining their
  silhouettes and palettes.

## Final automated evidence

Run from the repository root:

```bash
cd /Users/roy/gh/blockfall
./ci/check.sh
./ci/build.sh release
./build/Blockfall.app/Contents/MacOS/Blockfall --selftest
python3 tests/content/validate.py
```

Required signals:

- `✅ check.sh GREEN`
- `==> built: .../build/Blockfall.app`
- the fresh release binary reports
  `OK: swift<->c++ self-test (5 frames, hud populated)`
- content validation reports all files valid
- `bf_entity_draw` remains 44 bytes and ABI v28 sidecar parity passes
- no Rust warnings

The standalone release Rust gate used during development is:

```bash
cd /Users/roy/gh/blockfall/engine-rs/bfcore
cargo test --release
```

Expected suite totals at this feature head:

- library: 170 passed, 6 manual/diagnostic tests ignored
- co-op: 2 passed
- map: 12 passed
- network: 4 passed
- perf: 0 passed, 1 manual probe ignored
- world integration: 60 passed

## Fast manual smoke test

Allow 30–45 minutes.

1. Run `./play.sh` and create a fresh world. Use seed `11` if the world screen
   exposes a seed field.
2. Confirm spawn is dry and collision-clear inside a walled City. Before spending
   several minutes in town, look along the nearest City route for the cart starting
   at its HOME endpoint; if it has already left the 128-block draw radius, wait for
   its return or use the deterministic caravan gallery below.
3. Walk one circuit of the City. Check four open gates, four detailed towers,
   the civic landmark, pitched roofs, open shops, stations, bench, and broom
   stand. Large surfaces should have beams, trim, material breaks, or shaped
   profiles rather than reading as plain Lego boxes.
4. Enter two homes. Each bed should read as one bed, not two blocks. Check legs,
   headboard, pillow/quilt, low height, and correct orientation against a wall.
5. Observe villagers for several minutes. Look for work travel and visible tool
   use, plus look/gesture/greet/chat/sit/sweep actions. Pair chats must face each
   other and end cleanly; a sitting villager must be visibly on the bench seat.
6. Press `M`, then zoom all the way out. HOME should be centred in the full-planet
   view; Town and City use distinct icons. A dashed route appears once at least two
   developed settlements have been discovered.
7. Follow a developed road out through a cardinal gate. The protected gate/core is
   stone brick; beyond it, confirm a graded three-wide cobble City route.
8. Press `T` until `[ALWAYS NIGHT]` appears (normally twice: auto → day → night).
   Check forge glow, hostile emissive parts, readable silhouettes, and floppy
   animation.
9. At a clearly non-dawn time, save, leave to the title screen, and reload. Confirm
   the same time-of-day phase, then recheck settlement class, stations, props, road,
   caravan progress, and trade availability.
10. Press backslash during useful world views. Screenshots land in
    `~/blockfall-shots/`. Use a macOS screenshot for map/dialogue/trade overlays.

## Detailed fresh-world playtest

### 1. Starter City and building detail

Create a fresh world and inspect before placing or mining anything.

- Spawn must be on dry ground with no collision or suffocation.
- The perimeter must be continuous except for four readable cardinal gates.
- Each corner tower needs a shaped roof/crown, timber or carved-stone detail, and
  a silhouette that differs from a solid rectangular column.
- The civic landmark must be visible from the central area.
- Houses need pitched multi-level roofs, one-block eaves, and inset timber beams.
- Beds need legs, rails, a headboard, quilt and pillow. The cross-chunk ownership
  edge case is automated by
  `paired_bed_across_x_chunk_seam_is_emitted_by_low_owner`; orientation is gated by
  `paired_bed_z_rotates_and_puts_headboard_against_wall`.
- Open artisan shelters must not be closed box huts. Their posts, roof pitch,
  station, and clear west work cell should be readable.
- Confirm these stations are present and visually distinct:
  - woodcutter chopping block with stump, split logs, and embedded axe
  - mason bench
  - blacksmith forge with warm light
  - herbalist table
  - builder sawbench
- Confirm the communal bench has a back/seat/legs and the broom stand has a
  leaning broom/dustpan silhouette. Neither should look like a placeholder cube.
- Press `C`, then `E`, and inspect the Creative icons/tooltips for Chopping Block,
  Mason Bench, Blacksmith Forge, Herbalist Table, Builder Sawbench, Communal Bench,
  and Broom Stand. Put each in the hotbar: its held silhouette must be authored,
  not a generic cube. Place and break each once; the correct item should return.

### 2. Villager population, work, and social life

The City should maintain six stable professions: Woodcutter, Elder, Stone Mason,
Builder, Blacksmith, and Herbalist.

Observe long enough to see:

- Woodcutter walks to the chopping block, faces it, chops, and returns.
- Mason uses a mallet at the mason bench.
- Blacksmith hammers at the forge.
- Herbalist uses a pestle/herb motion.
- Builder saws at the sawbench.
- Elder greets other residents.
- Idle residents look around, gesture, greet, pause face-to-face for pair chat,
  sit, and sweep.
- Chat pairing is mutual: one villager must not be claimed by two partners.
- Villagers remain within the settlement tether and do not freeze permanently.
- When a profession shift becomes due, the resident stops social activity and
  goes to work.

Do every non-destructive visual and routine check first. Each failure check below
edits the world; use a disposable duplicate/new seed-11 world for each one, or
restore the exact prop/station and blocker in Creative before continuing.

Failure checks:

1. Mine one station while its worker is travelling or working. The worker must
   cancel safely and return home without a false work pose.
2. Block a station’s west work cell. The worker must not walk through the block
   or work from the wrong place.
3. Mine the bench while a resident is travelling to sit. The sit action and old
   path must clear.
4. Block the broom work path. Sweep must cancel without leaving stale movement.
5. Save/reload after each kind of cancellation. No resident should remain stuck
   in a missing action.

### 3. Village → Town → City progression

Use a non-HOME Village so the natural starter City does not short-circuit
donations. This discovery is exploratory in live play; deterministic class and
persistence coverage comes from the automated tests. Press `C`, then `E`, to use
the Creative picker for test materials.

1. Visit the Village and open `M`; it should appear as a Village marker.
2. Select/hold oak logs, right-click the Woodcutter, and click
   `Donate held items to the village`. Repeat until 124 logs have been accepted;
   each click accepts at most 8 logs and each wall cell costs 2. The 62-cell
   palisade completes and HUD reads `Walled Village · Tier 1/3`.
3. Hold stone, stone brick, or cobblestone; right-click the Stone Mason and use
   the same donation button until 16 accepted items are donated. HUD changes to
   `Town · Tier 2/3`; population rises from 3 to 5; Builder and Blacksmith appear;
   open shops materialize; a one-wide gravel road appears.
4. Hold raw iron or iron ingots; right-click the Blacksmith and donate 8 accepted
   items. HUD changes to
   `City · Tier 3/3`; population rises to 6; Herbalist appears; the route upgrades
   to a three-wide cobble road.
5. Open `M` at every tier. Village, Town, and City labels/icons must agree with
   the HUD and minimap.
6. Save/reload at Town and again at City. Class, raw donation tier, population,
   shops, map marker, road material, and offers must remain correct.

The exact future-shop-cell preservation check is automated by
`artisan_growth_preserves_player_blocks_through_promotion_and_load`; there is no
stable bounded live-play coordinate before a Village anchor is known.

### 4. Roads and boardwalks

Follow a route from a settlement’s cardinal gate.

- Beyond the protected stone-brick settlement gate/core, a Town route is one block
  wide and gravel.
- Beyond the protected stone-brick settlement gate/core, a City route is three
  blocks wide and cobble.
- Adjacent centreline heights differ by at most one block.
- Hills may be cut and valleys filled, but the route needs full two-block
  headroom and must stay walkable.
- Water crossings use oak-plank boardwalks. Exact wet-route selection is
  deterministic but not exposed as a bounded live coordinate; the unit gate is
  `wet_road_cells_become_boardwalk`.
- The route takes the short direction across the torus seam. Validate the exact
  seam geometry with `route_uses_the_short_torus_image_deterministically` and the
  generated `map_route_seam.png` fixture.
- It must not overwrite unrelated buildings, ruins, or player solids.
- A player edit in a road column must survive a tier refresh/reload.
- No `roads.dat` should be created; road geometry is derived from seed and class.

### 5. Caravan delivery and trade stock

Stay near one developed route. Only one route is actively simulated at a time.

- The cart has a mule, cargo, awning, wheels, and moving legs/wheels.
- It follows the graded road rather than cutting across terrain.
- It reverses at endpoints and faces the direction of travel through bends.
- When the cart itself is outside the nearby draw radius, it disappears cleanly;
  the selected nearby route can still progress and complete a delivery.
- Remove several consecutive road cells immediately ahead of the cart; it must hide
  without a crash or walking through structure masonry. Unloaded-cell safety is
  automated by `exactly_one_nearby_intact_route_runs_and_bad_road_hides` because
  unloaded residency is not directly visible in live play.

At a route endpoint:

1. On a fresh HOME endpoint before its first delivery, the local route starts with
   three units of stock. With no coins, click a visible coin-buy offer; it must fail
   without removing the offer.
2. Add more coins than the offer price, fill all 36 slots, and ensure no slot
   already holds the purchased item. Click again; the full-inventory purchase must
   fail without removing the offer. Otherwise spending the last coin stack can
   legitimately free a slot for the purchase.
3. Free one slot and make exactly three successful coin-buys. Sell offers remain,
   while all coin-buy offers disappear. This proves both failures left the initial
   stock untouched.
4. Follow or wait for a delivery. Settlement spacing makes a one-way leg typically
   at least five minutes at 1.5 road cells/second; replenishing the endpoint where
   the cart started can take a full ten-minute round trip. Coin-buy offers return
   after delivered stock increases, capped by the bounded route stock. Use the
   deterministic road/map tests when a shorter manual session cannot cover this.
5. Save/reload mid-route. The visible cart position/direction and trade stock must
   continue without an obvious reset. Exact fractional timing is covered by
   `caravan_progress_is_frame_partition_independent` and the BFT1 round-trip test.
6. Pre-caravan/old/truncated save behavior is automated-only because no legacy
   fixture ships with the repo. It is covered by
   `caravan_trailer_roundtrips_and_old_or_truncated_maps_are_safe`, including a
   reused-World stale-state regression.

### 6. Ruins, keeps, towers, and rare boss landmarks

Seed `10` has a deterministic ruin centred near `(184, 10, 76)`.

- Look from north and south. Walls need chipped height variation, mixed stone/moss,
  buttresses, an open broken doorway/arch, and irregular low rubble piles.
- Rubble must be persistent shaped geometry with solid, visually legible collision;
  it must not become a full invisible cube or disappear at prop distance.
- Walk through the broken arch and around the site. The damage pass must remain
  traversable.
- Confirm the danger marker/defenders still work. Defeat the fixed band; the site
  clears, grants its reward once, and does not immediately refill while you stay.
- Keeps and tall towers should use restrained accents rather than noisy decoration:
  carved caps, a broken/profiled crown, and a few weathered shaft patches. This
  guide does not promise live coordinates for those sparse procedural structures;
  deterministic coverage is
  `keeps_and_ruins_have_supported_shaped_stone_profiles` and
  `tall_tower_has_restrained_weathered_shaft_and_shaped_crown`.

Seed `11` also has two fixed rare-landmark fixtures. World coordinates wrap, so
negative `(x,z)` values are equivalent to their canonical `0–32767` values.

- Boss castle: anchor `(6621, 17, -1888)`, canonical z `30880`. Approach through
  the three-wide south gate. Confirm the open boss courtyard, three enterable rooms,
  four beacon towers, climbable east curtain walk, and two high-tier chests. In
  Survival it spawns one hostile scale-2 content boss; in Hard Creative the same boss
  appears but cannot hunt or damage the observer.
- Those containers now read as **Loot Barrels**: bowed octagonal oak casks with three
  iron hoops and a lock crest on every cardinal face. A barrel containing anything has
  bright emissive crest lights; take its final item and they must turn fully off, then
  deposit one item and they must relight. The treasure-hall barrel is at
  `(6621, 18, 30886)`. Save/reload both an empty and non-empty barrel, and break one;
  all existing chest inventory and persistence behavior must remain intact. Slowly orbit
  all four faces at daylight and dusk: lock plates, lower/middle/upper hoops, and lights
  must stay depth-stable with no flicker where their edges meet.
- Grand tower: anchor `(-1243, 19, 3048)`, canonical x `31525`. Enter the south door,
  follow all 24 supported steps through both landings, and open the summit chest.
  Its encounter is the existing bounded three-defender danger band.
- Fly between several regions. Rare landmarks must remain at least 2048 blocks apart;
  the common/landmark/settlement seed-11 regression remains exactly `1155/505/19`,
  proving these replace old landmarks instead of increasing structure density.

### 7. Character and creature models

Check villagers first:

- Eight gallery variants retain stable clothing, height, head style, and identity.
- Faces vary in eye proportions, brows, nose, and mouth without face parts showing
  through the back of the head.
- Head/body/limbs are rounded low-poly forms.
- Walk phases show eased stride, hand/foot follow-through, child-joint lag, and
  restrained squash; they should feel floppy, not rubbery.

Then inspect `BF_AVATARS=1`:

- It renders ten remote-player models using the character editor's actual palettes
  and named styles (Bald through Bun), not generated villager identities.
- Every row choice must visibly alter the intended feature: skin, shirt, hair and
  eye colour, hair/eye/nose/mouth style, and head/body silhouette.
- Hair must match the editor label (especially Side Part, Long, Ponytail, Spiky,
  Mohawk, Curly, and Bun); face parts stay seated on the head.

Passive roster to inspect: `0–3, 7–10, 12–14, 18–19, 21`.

Hostile roster to inspect: `4, 5, 11, 15–17, 23–26`.

For easy observation, select **Hard**, toggle into Creative, and pin night. A fresh
world may spawn the hostile roster immediately without completing the first quest.
They must animate and wander but never hunt or damage the Creative observer. Normal
Creative remains peaceful, and switching to Easy removes hostile creatures.

For each representative species, confirm its original size, palette, face, gait,
and silhouette still read immediately. At night, emissive eyes/cores must remain
visible. Slime keeps its existing squash baseline.

### Slow-turn sky and distance check

Use one loaded live session and turn one or two degrees at a time. The large sky
patches are the cloud layer; they should have rounded, feathered boundaries rather
than axis-aligned square cells. The horizontal anamorphic bar is Lens Flare, not a
god ray, and should disappear when Lens Flare is disabled. With clouds and Lens Flare
off, enable God Rays at render distances 8 and 24 and test both 50% and 100% intensity
(0% is not a ray test): shafts must continue smoothly beyond the finite shadow volume,
never exposing its ceiling or sides as a moving rectangular plane. The issue-274 live
before/after references are `artifacts/playtest-2026-07-12/godray-tiles-live-before.png`
and `godray-tiles-live-after.png`; `godray-shafts-visible-after.png` separately proves
that the rectangle-free path still carves visible shafts through a treeline. Distant roof
trim and foliage should lose cel ink gradually from 192–290 blocks instead of blinking
as sub-pixel outlines. If comparing headless frames, use `BF_SHOT_REQUIRE_STABLE=1`
with a bounded `BF_SHOT_RENDER_DISTANCE` (4 is enough for close prop fixtures); the
gate fails rather than saving a partial visible scene when it cannot settle before
`BF_SHOT_STREAM_TIMEOUT`.

The deterministic `--critters` harness below deliberately normalizes non-villager
scale and cycles toy review colours; `BF_SHOT_TESTCREATURE` also uses a fixed
review colour/scale. Those fixtures validate geometry, silhouette, pose, part
budget, and emissive placement. Validate gameplay-authored size and palette from
live natural spawns.

### Ambient sky birds

Stand outdoors in full daylight for 60 seconds and look across, then above, the
treeline. At most three sparse birds should cross at varied heights and speeds, normally
42 blocks or more from the player rather than crowding the camera. Each
must read as one plump cartoon animal—rounded body and head, oversized eye, beak,
tail, and overlapping floppy wings—not the old faint V mark or detached shapes.
They should steer on curved paths instead of snapping to a new velocity. Before landing,
each bird must fly to an elevated waypoint, make a shallow final glide, flare its wings
and feet while keeping its body roughly level, then place its feet on—never through—the
loaded roof, wall, or treetop surface. It must not dive vertically, fly through an
intervening surface, or pop upward on takeoff. Perched birds tuck their wings, hop, and
move an idle eye.

Approach a perched bird to within roughly 10 blocks: it must take off before contact.
Mining, placing, or attacking nearby must also send it fleeing. Remove its support and
it must leave rather than float. Pause must freeze every bird. Birds must disappear
behind terrain and be absent at night, underwater, and in caves; at night, confirm the
existing fireflies still glow and bloom. Flying far away may locally recycle a bird;
there is deliberately no bird persistence, collision, loot, or network state.

For a fixed three-bird geometry check, run:

```bash
BF_SELFTEST_BIRDS=1 "$BIN" --screenshot "$OUT/ambient-bird-modes-after.png"
```

This fixture renders cruise, perched, and landing-flare silhouettes and first runs a
deterministic state test proving the elevated approach, shallow level-bodied landing,
exact contact, default three-bird budget, and subsequent threat-driven flee. Live play
remains the terrain-clearance, world-perch, support-removal, occlusion, density, pause,
and dusk gate.

## Deterministic headless visual checks

After a fresh release build:

```bash
cd /Users/roy/gh/blockfall
set -euo pipefail
OUT="$(mktemp -d /private/tmp/blockfall-backlog-validation.XXXXXX)"
BIN=./build/Blockfall.app/Contents/MacOS/Blockfall
echo "visual evidence: $OUT"
```

This pass generated and inspected the complete 52-file canonical set at
`/private/tmp/blockfall-backlog-validation.GFpYtJ`. Occluded first attempts were
replaced, then the City, tower, roof, work, social, rear-view, and night fixtures
were independently re-audited from the final release binary.

### Map and tier HUD

```bash
"$BIN" --mapshot "$OUT/map.png"
"$BIN" --villageshot "$OUT/village-tiers.png"
```

Mapshot also writes confirmation, planet, route-seam, and minimap fixtures. Check
the Town/City icons, dashed route, HOME-centred planet view, and seam route drawn
against chart edges rather than across the world.

### City and ruin

```bash
BF_SHOT_SEED=11 BF_SHOT_POS="31034,38,88,0.785398,-0.30" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/city-0.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31134,38,88,5.497787,-0.30" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/city-90.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31134,38,188,3.926991,-0.30" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/city-180.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31034,38,188,2.356194,-0.30" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/city-270.png"

BF_SHOT_SEED=10 BF_SHOT_POS="184,13,58,0,-0.05" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/ruin-north.png"
BF_SHOT_SEED=10 BF_SHOT_POS="184,13,94,3.14159,-0.05" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/ruin-south.png"

BF_SHOT_SEED=11 BF_SHOT_POS="2928.5,10.2,-5.5,0,0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/keep-profile.png"
BF_SHOT_SEED=11 BF_SHOT_POS="3931.5,18,-10,0,0.03" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/tall-tower-profile.png"
```

### Rare boss-landmark fixtures

`BF_SHOT_DIFFICULTY=0` suppresses encounters so the architecture is unobstructed;
repeat live on Hard to validate the boss and defender behavior.

```bash
BF_SHOT_SEED=11 BF_SHOT_DIFFICULTY=0 \
  BF_SHOT_POS="6580,34,30835,0.739,-0.13" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/boss-castle-exterior.png"
BF_SHOT_SEED=11 BF_SHOT_DIFFICULTY=0 \
  BF_SHOT_POS="6625,20,30875,-0.349,-0.02" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/boss-castle-courtyard.png"

BF_SHOT_SEED=11 BF_SHOT_DIFFICULTY=0 \
  BF_SHOT_POS="31490,42,3010,0.744,-0.12" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/grand-tower-exterior.png"
BF_SHOT_SEED=11 BF_SHOT_DIFFICULTY=0 \
  BF_SHOT_POS="31525.5,30,3048.5,0.75,-0.35" \
  BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 \
  BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/grand-tower-interior.png"
```

### Finished building, bed, station, and communal-prop close-ups

These seed-11 cameras pin safe views in and around the starter City:

```bash
BF_SHOT_SEED=11 BF_SHOT_POS="31100,19,124,0.7854,-0.08" BF_SHOT_FREEZE_CAMERA=1 BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/home-pitched-roof.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31116.5,14.2,140.5,0.588,-0.44" BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/bed-finished.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31077.5,15.2,142.5,1.5708,-0.45" BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/station-mason.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31077.5,14.2,134.5,1.5708,-0.45" BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/station-forge.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31085.5,15.2,134.5,1.5708,-0.45" BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/station-herbalist.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31087.5,14.2,144.5,1.5708,-0.45" BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/station-builder.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31085.5,14.2,142.5,1.5708,-0.45" BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/station-chopping.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31081.5,15.2,144.5,1.5708,-0.45" BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/prop-bench.png"
BF_SHOT_SEED=11 BF_SHOT_POS="31081.5,14.2,132.5,1.5708,-0.45" BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/prop-broom.png"
```

### Full creature gallery and motion strips

```bash
BF_CEL=1 "$BIN" --critters "$OUT/critters.png"
BF_VILLAGERS=1 BF_CEL=1 "$BIN" --critters "$OUT/villagers.png"
BF_ENTITY_SHAPE=box BF_CEL=1 "$BIN" --critters "$OUT/critters-box.png"
BF_VILLAGERS=1 BF_ENTITY_SHAPE=box BF_CEL=1 \
  "$BIN" --critters "$OUT/villagers-box.png"

BF_CRITTER_MOTION=1 BF_CRITTER_KIND=20 BF_CEL=1 \
  "$BIN" --critters "$OUT/villager-motion.png"
BF_CRITTER_MOTION=1 BF_CRITTER_KIND=10 BF_CEL=1 \
  "$BIN" --critters "$OUT/passive-deer-motion.png"
BF_CRITTER_MOTION=1 BF_CRITTER_KIND=5 BF_CEL=1 \
  "$BIN" --critters "$OUT/hostile-motion.png"
BF_CRITTER_MOTION=1 BF_CRITTER_KIND=15 BF_CEL=1 \
  "$BIN" --critters "$OUT/slime-motion.png"
BF_CRITTER_MOTION=1 BF_CRITTER_KIND=27 BF_CEL=1 \
  "$BIN" --critters "$OUT/caravan-motion.png"
```

The full gallery should print `critter gallery: 27 kinds`. Caravan motion should
report four entities, 128 body-part draws, and no more than 2,600 triangles.
Compare each default gallery with its `-box` control: the model build should have
rounded sub-block masses while retaining the same readable species/identity.

Verify villager facial parts do not leak through the back of the rounded head:

```bash
BF_SHOT_SEED=10 BF_SHOT_POS="170,13,62,3.14159,-0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_TESTCREATURE=20 \
  BF_SHOT_TCFACEAWAY=1 BF_SHOT_TCDIST=5 BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/villager-back.png"
```

Representative injected passive close-ups and a fixed-view 32-villager visual A/B:

```bash
BF_SHOT_SEED=10 BF_SHOT_POS="170,13,62,3.14159,-0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_TESTCREATURE=10 \
  BF_SHOT_TOD=0.25 BF_SHOT_TCDIST=4 BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/passive-deer-close.png"
BF_SHOT_SEED=10 BF_SHOT_POS="170,13,62,3.14159,-0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_TESTCREATURE=14 \
  BF_SHOT_TOD=0.25 BF_SHOT_TCDIST=4 BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/passive-frog-close.png"

BF_ENTITY_STRESS=1 BF_ENTITY_SHAPE=box BF_SHOT_SEED=10 \
  BF_SHOT_POS="170,13,62,3.14159,-0.12" BF_SHOT_NOWALK=1 \
  BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/entity-stress-box.png"
BF_ENTITY_STRESS=1 BF_SHOT_SEED=10 \
  BF_SHOT_POS="170,13,62,3.14159,-0.12" BF_SHOT_NOWALK=1 \
  BF_SHOT_PITCH=0 BF_SHOT_HELD=0 BF_CEL=1 \
  "$BIN" --shot "$OUT/entity-stress-model.png"
```

These are deterministic review injections, not natural spawns; live play remains
the palette, authored-scale, AI, and combat gate.

For complete roster coverage, repeat the motion command for every passive and
hostile kind listed above, changing the output filename for every kind.

### Work and social poses

Work roles: `2 builder`, `3 herbalist`, `4 woodcutter`, `5 mason`, `6 blacksmith`.

```bash
BF_SHOT_SEED=10 BF_SHOT_POS="170,13,62,3.14159,-0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 \
  BF_SHOT_TESTCREATURE=20 BF_SHOT_TCDIST=4 BF_SHOT_VILLAGER_WORK=1 \
  BF_SHOT_WORK_ROLE=4 BF_SHOT_WORK_PROGRESS=0.166667 BF_CEL=1 \
  "$BIN" --shot "$OUT/work-woodcutter.png"
```

Repeat with roles `2–6` and progress `0`, `0.083333`, `0.166667`, `0.25`, and
`0.333333`, changing the output filename for each role/progress pair. These are
raised, mid-swing, contact, return, and raised poses for the three-stroke shift.
Roles 4–6 must travel overhead to the station-facing contact point; role 2's saw
must lie forward across its work instead of hanging vertically.

Social actions: `5 look`, `6 gesture`, `7 greet`, `8 chat`, `9 sit`, `10 sweep`.

```bash
BF_SHOT_SEED=10 BF_SHOT_POS="170,13,62,3.14159,-0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_HELD=0 \
  BF_SHOT_TESTCREATURE=20 BF_SHOT_TCDIST=4 BF_SHOT_SOCIAL_ROLE=1 \
  BF_SHOT_SOCIAL_ACTION=10 BF_SHOT_SOCIAL_PROGRESS=0.65 BF_CEL=1 \
  "$BIN" --shot "$OUT/social-sweep.png"
```

Repeat actions `5–10` at progress `0.20` and `0.65`, changing the output filename
for each action/progress pair. Action 8 validates the pose; live play validates
mutual partner selection and facing.

### Night hostile close-ups

```bash
BF_SHOT_SEED=10 BF_SHOT_POS="170,13,62,3.14159,-0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_TESTCREATURE=5 BF_SHOT_TOD=0.75 \
  BF_SHOT_TCDIST=5 BF_SHOT_HELD=81 BF_SHOT_SWING=0.55 BF_CEL=1 \
  "$BIN" --shot "$OUT/hostile-5-night-combat.png"
BF_SHOT_SEED=10 BF_SHOT_POS="170,13,62,3.14159,-0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_TESTCREATURE=11 BF_SHOT_TOD=0.75 \
  BF_SHOT_TCDIST=5 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/hostile-11-night.png"
BF_SHOT_SEED=10 BF_SHOT_POS="170,13,62,3.14159,-0.12" \
  BF_SHOT_NOWALK=1 BF_SHOT_PITCH=0 BF_SHOT_TESTCREATURE=15 BF_SHOT_TOD=0.75 \
  BF_SHOT_TCDIST=5 BF_SHOT_HELD=0 BF_CEL=1 "$BIN" --shot "$OUT/slime-night.png"
```

The first close-up validates combat framing and the held swing only. Natural AI,
hit response, gameplay scale, and gameplay palette still require live combat.

## Performance comparison

Run from the repository root. Keep `OUT` from the visual-check terminal, or create
a new evidence directory here:

```bash
cd /Users/roy/gh/blockfall
BIN=./build/Blockfall.app/Contents/MacOS/Blockfall
OUT="${OUT:-$(mktemp -d /private/tmp/blockfall-backlog-perf.XXXXXX)}"
```

A/B measurements in this session use a 14-core M4 Pro MacBook Pro with 48 GB
memory on macOS 26.5.2. They catch regressions but do not replace the final M1
Air sustained gate below.
Never compare the saved M4 Pro baseline against an M1 or any other machine; collect
a same-machine baseline instead.

A pre-change 20-second reference run on this machine recorded:

- median: 148.9 FPS
- 1% low: 38.4 FPS
- median frame: 6.716 ms
- median encode: 3.188 ms
- median GPU: 2.708 ms
- peak memory: 1,678 MB

The durable saved reference is
`docs/evidence/backlog-perf-before-2026-07-11.json`. Copy it to the comparator
path before running the commands below:

```bash
cp docs/evidence/backlog-perf-before-2026-07-11.json \
  /private/tmp/blockfall-backlog-before.json
```

Run the same post-change scene:

```bash
BF_METAL_PERF_JSON=/private/tmp/blockfall-backlog-after.json \
BF_PERF_SAVE_DIR=/private/tmp/blockfall-perf-after \
  "$BIN" --perftest 20

python3 ci/perf_compare.py \
  /private/tmp/blockfall-backlog-before.json \
  /private/tmp/blockfall-backlog-after.json
```

Expected result: `perf compare OK`.

The accepted post-change run from this pass is saved at
`docs/evidence/backlog-perf-after-2026-07-11.json` and recorded:

- median: 181.8 FPS (`+22.1%`)
- 1% low: 75.6 FPS (`+96.9%`)
- median frame: 5.502 ms (`-18.1%`)
- median engine: 0.920 ms
- median encode: 1.057 ms
- median GPU: 3.042 ms (`+12.3%`)
- peak memory: 1,698 MB; `pass_mem: true`

The same-machine comparator passed. During validation it also caught and drove a
real fix: natural City growth is no longer redundantly overlaid during streaming,
and L-shaped roads cull chunks against their two actual segments instead of their
large filled bounding rectangle.

A July 13 moving-scene smoke run under heavy host CPU contention still passed the
absolute gate at 125.8 FPS median, 43.8 FPS 1% low, 2.626 ms GPU, and zero frames
over 33.3 ms. It was not accepted as a replacement A/B: the legacy moving harness
rendered 5–10% more geometry than the saved reference and its median comparator
failed (`-15.5%`) while GPU time and 1% low improved. Keep the persisted July 11
same-machine comparison above as the accepted normal-scene evidence.

Then run the deterministic 32-villager stress A/B with the same current binary:

```bash
BF_ENTITY_STRESS=1 BF_ENTITY_SHAPE=box \
BF_METAL_PERF_JSON="$OUT/entity-box.json" \
BF_PERF_SAVE_DIR="$OUT/save-box" "$BIN" --perftest 60

BF_ENTITY_STRESS=1 \
BF_METAL_PERF_JSON="$OUT/entity-model.json" \
BF_PERF_SAVE_DIR="$OUT/save-model" "$BIN" --perftest 60

python3 ci/perf_compare.py "$OUT/entity-box.json" "$OUT/entity-model.json"
```

Required stress signals:

- scene is `entity-stress(32 villagers)`
- entity count is 32
- `entity_shape` is `box` in the control JSON and `model` in the candidate JSON
- body-part and triangle metrics are populated
- comparator passes: median FPS drop ≤12%, 1% low drop ≤25%, frame-time rise
  ≤20%, and GPU-time rise ≤30%

The final fixed-camera result is persisted in
`docs/evidence/entity-stress-box-2026-07-11.json` and
`docs/evidence/entity-stress-model-2026-07-11.json`:

- box control: 200.2 FPS median, 136.4 FPS 1% low, 4.995 ms frame,
  2.346 ms GPU, 10,380 entity triangles
- shaped model: 194.0 FPS median, 134.1 FPS 1% low, 5.156 ms frame,
  2.429 ms GPU, 20,520 entity triangles
- delta: median `-3.1%`, 1% low `-1.7%`, frame `+3.2%`, GPU `+3.5%`;
  `perf compare OK`

The July 13 final visual-follow-up rerun is persisted in
`docs/evidence/entity-stress-box-2026-07-13.json` and
`docs/evidence/entity-stress-model-2026-07-13.json`:

- box control: 167.7 FPS median, 111.8 FPS 1% low, 5.965 ms frame,
  1.859 ms GPU, 10,344 entity triangles
- shaped model: 160.3 FPS median, 115.0 FPS 1% low, 6.240 ms frame,
  1.980 ms GPU, 35,680 entity triangles
- delta: median `-4.4%`, 1% low `+2.9%`, frame `+4.6%`, GPU `+6.5%`;
  `perf compare OK`, with zero frames over 33.3 ms in either run

The final M1 Air gate is a 10-minute run with median ≥60 FPS, 1% low ≥30 FPS,
and no sustained memory growth:

```bash
BF_PERF_CAMERA=32597,23,28441,5.497787,-0.35 \
BF_PERF_SETTLE=600 BF_METAL_PERF_SECONDS=600 \
BF_METAL_PERF_JSON="$OUT/m1-final.json" \
BF_PERF_SAVE_DIR="$OUT/m1-save" ./ci/perf.sh

python3 -m json.tool "$OUT/m1-final.json"
```

The perf process exits nonzero for the memory cap, but does not enforce the FPS
threshold. The JSON must explicitly report `seconds: 600`, `pass_fps: true`, and
`pass_mem: true`. While it runs, record the Blockfall process memory once per
minute in Activity Monitor; fail the gate if the samples show a continuing upward
trend rather than settling. The JSON records peak memory only, not that trend.

## Reporting failures

For any visual or play failure, record:

- fresh or old world
- seed and world position
- exact action/state (tier, profession, creature kind, time of day)
- screenshot from `~/blockfall-shots/` or macOS for overlays
- whether save/reload changes it

Do not reuse already-generated chunks to judge a worldgen change.
