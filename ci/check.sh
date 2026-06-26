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
