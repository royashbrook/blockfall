#!/usr/bin/env bash
# Blockfall — check.sh : the green-bar gate (spec §5).
# Rust engine tests + content validation + app build + Swift self-test + lint.
# The engine is Rust (bfcore); the C++ engine was retired (#101). Nothing is
# "done" until this is green on a clean checkout (spec §5).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
"$BIN" --selftest || FAIL=1
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
# "wipe"). Guards the cascade-union fix so a future change can't silently bring the wipe back.
# Needs a Metal device; self-skips (returns 0) where none is present.
if "$BIN" --shadowstabilitytest; then :; else
  FAIL=1; echo "   (SHADOW-STABILITY regression: cast shadows wipe with player position, #115)"
fi
# Shadow camera-yaw regression: on a fixed-seed REAL-terrain region (single process), boot
# the engine, reconstruct a fixed set of ground world-points, and measure each point's cast
# shadow against the full two-cascade pipeline at camera yaws N/E/S/W. FAILS if a fixed
# point's shadow drifts with camera facing (the reported "shadows vanish when turning toward
# E/W"). The shipped path is view-free so the spread is ~0; the gate catches any future
# view-dependent shadow term. Needs a Metal device; self-skips (returns 0) where none present.
if "$BIN" --shadowyawtest; then :; else
  FAIL=1; echo "   (SHADOW-YAW regression: cast shadows wipe with camera yaw toward E/W)"
fi
# Ground-night regression (#117): at night the water sky-reflection was not day/night gated,
# so water surfaces over the terrain washed pale toward the sun's E/W azimuth as the camera
# turned (the player's view-direction-dependent night "ground" wash). Renders a fixed night
# water view with the real shader vs the reflection forced off and FAILS if they differ at
# night (the wash) or MATCH at day (daytime reflection lost). Needs a Metal device; self-skips.
if "$BIN" --groundnighttest; then :; else
  FAIL=1; echo "   (GROUND-NIGHT regression: night water reflection washes the ground by view direction, #117)"
fi
# Long-view shadow-sweep regression (#118): perch HIGH over fixed-seed real terrain and render a
# long vista at several yaws through the full two-cascade pipeline. FAILS if the shadow-coverage
# fade forms a perceptible post-fog ring (the boundary that swept across the land when turning).
# The fix pushes the coverage to the render edge and dissolves the fade into the distance haze.
# Needs a Metal device; self-skips (returns 0) where none is present.
if "$BIN" --vistatest; then :; else
  FAIL=1; echo "   (VISTA regression: long-view shadow coverage edge sweeps across the vista when turning, #118)"
fi
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
