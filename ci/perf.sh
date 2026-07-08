#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_SAMPLES="${BF_PERF_SAMPLES:-5}"
METAL_SECONDS="${BF_METAL_PERF_SECONDS:-20}"
METAL_JSON="${BF_METAL_PERF_JSON:-/tmp/blockfall_perf.json}"
METAL_SAVE_DIR="${BF_PERF_SAVE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/blockfall-perf.XXXXXX")}"
BASELINE_JSON="${BF_PERF_BASELINE_JSON:-}"

if [ -n "$BASELINE_JSON" ]; then
  export BF_PERF_CAMERA="${BF_PERF_CAMERA:-32597,23,28441,5.497787,-0.35}"
  export BF_PERF_SETTLE="${BF_PERF_SETTLE:-600}"
fi

echo "== rust cpu perf =="
cd "$ROOT/engine-rs/bfcore"
cargo build --release
BF_PERF_SAMPLES="$RUST_SAMPLES" cargo test --release perf_meshing_render_baseline -- --ignored --nocapture

echo "== metal headless perf =="
cd "$ROOT/app"
mkdir -p "$ROOT/app/.build/clang-module-cache" "$ROOT/app/.build/swiftpm-home"
export CLANG_MODULE_CACHE_PATH="$ROOT/app/.build/clang-module-cache"
export SWIFTPM_HOME="$ROOT/app/.build/swiftpm-home"
BLOCKCORE_LIB_DIR="$ROOT/engine-rs/bfcore/target/release" \
BF_PERF_SAVE_DIR="$METAL_SAVE_DIR" \
BF_METAL_PERF_JSON="$METAL_JSON" \
swift run -c release BlockfallApp --perftest "$METAL_SECONDS"

echo "metal json: $METAL_JSON"
echo "perf save: $METAL_SAVE_DIR"

if [ -n "$BASELINE_JSON" ]; then
  echo "== perf compare =="
  "$ROOT/ci/perf_compare.py" "$BASELINE_JSON" "$METAL_JSON"
fi
