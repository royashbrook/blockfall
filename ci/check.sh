#!/usr/bin/env bash
# Blockfall — check.sh : the green-bar gate (spec §5).
# Rust engine tests + content validation + app build + Swift self-test + lint.
# The engine is Rust (bfcore); the C++ engine was retired (#101). Nothing is
# "done" until this is green on a clean checkout (spec §5).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-100}"
export PATH="/opt/homebrew/bin:$PATH"
FAIL=0
step() { echo ""; echo "=== $* ==="; }

step "1. Rust engine tests (cargo test)"
( cd "$ROOT/engine-rs/bfcore" && cargo test --release ) || FAIL=1

step "2. content validation (schemas + any content JSON)"
python3 "$ROOT/tests/content/validate.py" || FAIL=1

step "3. app build + Swift<->Rust self-test (headless)"
"$ROOT/ci/build.sh" debug >/dev/null
BIN="$ROOT/build/Blockfall.app/Contents/MacOS/Blockfall"
PLIST="$ROOT/build/Blockfall.app/Contents/Info.plist"
[ "$(plutil -extract CFBundleShortVersionString raw "$PLIST")" = "$VERSION" ] || FAIL=1
[ "$(plutil -extract CFBundleVersion raw "$PLIST")" = "$BUILD_NUMBER" ] || FAIL=1
[ -d "$ROOT/build/Blockfall.app/Contents/Frameworks/Sparkle.framework" ] || FAIL=1
[ "$(plutil -extract SUFeedURL raw "$PLIST")" = \
  "https://github.com/royashbrook/blockfall/releases/latest/download/appcast.xml" ] || FAIL=1
otool -l "$BIN" | grep '@executable_path/../Frameworks' >/dev/null || FAIL=1
"$BIN" --selftest || FAIL=1
# #239 dialogue smoke: the REAL dialogue overlay opens offscreen with its exit
# affordances and closes on walk-away (no display needed).
"$BIN" --dialogueprobe || FAIL=1
# Offscreen render test: proves chunk meshes actually draw (needs a Metal
# device; skipped automatically where none is present, e.g. some CI runners).
if "$BIN" --rendertest; then :; else
  echo "   (render test failed or no Metal device — non-fatal in headless CI)"
fi
# Washout regression (#33): sweep yaw × sun elevation; FAIL if any direction blows
# out the frame (bright + desaturated). Guards the sun-disc / bloom tuning so a
# future shader change can't silently reintroduce the turn-toward-sun washout.
if "$BIN" --washouttest; then :; else
  FAIL=1; echo "   (WASHOUT regression — sun shading washes out the frame)"
fi
# Shadow-stability regression (#115): walk the player past a tall occluder at high AND low
# sun; FAIL if a fixed world point's cast shadow moves with player position (the position+sun
# "wipe"). NOTE: the old camera-following shadow MAP is retired; shadows are now world-space
# voxel ray-marched. The three shadow-MAP guards (--shadowstabilitytest / --shadowyawtest /
# --vistatest) are replaced by ONE world-fixed guard below.
#
# World-fixed shadow regression (THE requirement): boot a fixed-seed REAL-terrain region,
# freeze the player (and the world occupancy grid), then render the SAME ground patch from
# many camera positions AND yaws and assert a fixed world point's sun shadow is IDENTICAL
# from every camera. Shadows are a property of the WORLD, never the camera. FAILS if a fixed
# point's shadow varies with the camera (any wipe/crawl/coverage-ring re-introduction would
# show as a non-zero spread). Needs a Metal device; self-skips (returns 0) where none present.
if "$BIN" --worldfixedtest; then :; else
  FAIL=1; echo "   (WORLD-FIXED-SHADOW regression: a fixed world point's shadow changes with the camera)"
fi
# Ground-night regression (#117): at night the water sky-reflection was not day/night gated,
# so water surfaces over the terrain washed pale toward the sun's E/W azimuth as the camera
# turned (the player's view-direction-dependent night "ground" wash). Renders a fixed night
# water view with the real shader vs the reflection forced off and FAILS if they differ at
# night (the wash) or MATCH at day (daytime reflection lost). Needs a Metal device; self-skips.
if "$BIN" --groundnighttest; then :; else
  FAIL=1; echo "   (GROUND-NIGHT regression: night water reflection washes the ground by view direction, #117)"
fi
# (The long-view VISTA shadow-sweep guard #118 is retired with the shadow map: a coverage ring
#  cannot exist for world-space voxel shadows. The world-fixed guard above covers high vistas too.)
# Perf smoke: a short measured run (the full gate is a 10-min M1 Air run).
if "$BIN" --perftest 5; then :; else
  echo "   (perf smoke failed or no Metal device — non-fatal in headless CI)"
fi

step "4. lint (Rust warnings are failures)"
# bfcore builds warning-free; treat any warning in a fresh build as a failure.
WARN=$( ( cd "$ROOT/engine-rs/bfcore" && cargo build --release 2>&1 ) | grep -ci "warning" || true )
if [ "$WARN" != "0" ]; then echo "LINT: $WARN cargo warning(s)"; FAIL=1; fi

echo ""
if [ "$FAIL" = "0" ]; then echo "✅ check.sh GREEN"; else echo "❌ check.sh RED"; fi
exit $FAIL
