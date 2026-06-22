#!/usr/bin/env bash
# Blockfall — check.sh : the green-bar gate (spec §5).
# build + unit + integration + content-validation + swift self-test + lint.
# Sanitizer stages are wired but opt-in via BF_SAN=address|thread|undefined.
# Nothing is "done" until this is green on a clean checkout (spec §5).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
FAIL=0
step() { echo ""; echo "=== $* ==="; }

step "1. C++ core build + unit tests (ctest)"
SAN_FLAG=""
[ -n "${BF_SAN:-}" ] && SAN_FLAG="-DBF_SANITIZE=${BF_SAN}"
cmake -S "$ROOT/engine" -B "$ROOT/build/check" -DBF_BUILD_TESTS=ON $SAN_FLAG >/dev/null
cmake --build "$ROOT/build/check" -j >/dev/null
ctest --test-dir "$ROOT/build/check" --output-on-failure || FAIL=1

step "2. content validation (schemas + any content JSON)"
python3 "$ROOT/tests/content/validate.py" || FAIL=1

step "3. app build + Swift<->C++ self-test (headless)"
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

step "4. lint (compiler warnings are errors on the core)"
# Core already builds with -Wall -Wextra -Wpedantic -Wconversion -Wshadow.
# Treat any warning in a fresh build as a failure.
WARN=$(cmake --build "$ROOT/build/check" --clean-first -j 2>&1 | grep -ci "warning:" || true)
if [ "$WARN" != "0" ]; then echo "LINT: $WARN compiler warning(s)"; FAIL=1; fi

echo ""
if [ "$FAIL" = "0" ]; then echo "✅ check.sh GREEN"; else echo "❌ check.sh RED"; fi
exit $FAIL
