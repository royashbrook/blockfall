#!/usr/bin/env bash
# Build the Rust engine for every supported Apple target and package the
# archives + frozen C ABI as one Swift/Xcode-consumable XCFramework (#344).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/engine-rs/bfcore"
OUT="${BF_XCFRAMEWORK_OUT:-$ROOT/app/Artifacts/CBlockcore.xcframework}"
HEADERS="$ROOT/build/xcframework-headers"
TOOLCHAIN="${BF_RUST_TOOLCHAIN:-1.96.0}"
TARGETS=(
  aarch64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
)

RUSTUP="${RUSTUP:-$(command -v rustup 2>/dev/null || true)}"
if [ -z "$RUSTUP" ] && [ -x /opt/homebrew/opt/rustup/bin/rustup ]; then
  RUSTUP=/opt/homebrew/opt/rustup/bin/rustup
fi
if [ -z "$RUSTUP" ]; then
  cat >&2 <<'EOF'
ERROR: rustup is required for the iPadOS cross-compilation targets.

One-time setup on Apple Silicon:
  brew install rustup
  /opt/homebrew/opt/rustup/bin/rustup toolchain install 1.96.0 --profile minimal

Then rerun ./ci/build-xcframework.sh. The script installs any missing target
standard libraries declared in rust-toolchain.toml.
EOF
  exit 1
fi

if ! "$RUSTUP" toolchain list | awk '{print $1}' | grep -qx "$TOOLCHAIN-aarch64-apple-darwin"; then
  "$RUSTUP" toolchain install "$TOOLCHAIN" --profile minimal
fi

for target in "${TARGETS[@]}"; do
  if ! "$RUSTUP" target list --installed --toolchain "$TOOLCHAIN" | grep -qx "$target"; then
    "$RUSTUP" target add "$target" --toolchain "$TOOLCHAIN"
  fi
done

# Homebrew installs rustup keg-only beside its host-only Rust formula, without
# command shims. `rustup run cargo` would therefore still find Homebrew rustc
# through PATH and miss the iOS standard libraries. Put the selected toolchain's
# real bin directory first so Cargo and rustc always come from the same sysroot.
TOOLCHAIN_BIN="$(dirname "$("$RUSTUP" which rustc --toolchain "$TOOLCHAIN")")"
CARGO="$TOOLCHAIN_BIN/cargo"

echo "==> Rust engine slices"
for target in "${TARGETS[@]}"; do
  echo "    $target"
  (
    cd "$ENGINE"
    PATH="$TOOLCHAIN_BIN:$PATH" "$CARGO" build --locked --release --target "$target"
  )
done

rm -rf "$HEADERS" "$OUT"
mkdir -p "$HEADERS" "$(dirname "$OUT")"
cp "$ROOT/contract/engine_c_api.h" "$HEADERS/"
cp "$ROOT/contract/module.modulemap" "$HEADERS/"

echo "==> CBlockcore.xcframework"
xcodebuild -create-xcframework \
  -library "$ENGINE/target/aarch64-apple-darwin/release/libbfcore.a" \
  -headers "$HEADERS" \
  -library "$ENGINE/target/aarch64-apple-ios/release/libbfcore.a" \
  -headers "$HEADERS" \
  -library "$ENGINE/target/aarch64-apple-ios-sim/release/libbfcore.a" \
  -headers "$HEADERS" \
  -output "$OUT"

"$ROOT/ci/verify-xcframework.sh" "$OUT"
echo "==> built: $OUT"
