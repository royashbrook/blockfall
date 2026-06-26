#!/usr/bin/env bash
# Blockfall — build.sh : produce a runnable Blockfall.app (spec §5).
# Steps: build the Rust engine staticlib (libbfcore.a) -> copy the frozen C ABI
# header into the Swift interop module -> build the Swift app -> assemble the
# .app bundle. The C++ engine was retired (#101); the engine is now Rust (bfcore).
# arm64-only (spec §2/§4.11).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"          # debug | release

# Self-install the commit hook (require a #issue ref on every commit). Idempotent;
# this is how the hook gets enforced on a fresh clone without a manual step.
git -C "$ROOT" config core.hooksPath .githooks 2>/dev/null || true
BUILD="$ROOT/build"
APP_OUT="$BUILD/Blockfall.app"
export PATH="/opt/homebrew/bin:$PATH"

echo "==> [1/4] Rust engine (bfcore staticlib, release)"
# The app links libbfcore.a. Always release: the engine does synchronous streaming,
# so a debug build is too slow to be usable, and the C ABI is identical either way.
( cd "$ROOT/rust-spike/bfcore" && cargo build --release >/dev/null )
LIB_DIR="$ROOT/rust-spike/bfcore/target/release"
[ -f "$LIB_DIR/libbfcore.a" ] || { echo "ERROR: libbfcore.a missing"; exit 1; }

echo "==> [2/4] sync frozen C ABI header into Swift interop module"
cp "$ROOT/contract/engine_c_api.h" \
   "$ROOT/app/Sources/CBlockcore/include/engine_c_api.h"

echo "==> [3/4] Swift app ($CONFIG)"
SWIFT_FLAGS=()
[ "$CONFIG" = release ] && SWIFT_FLAGS+=(-c release)
( cd "$ROOT/app" && BLOCKCORE_LIB_DIR="$LIB_DIR" swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} )
BIN="$ROOT/app/.build/$CONFIG/BlockfallApp"
[ -f "$BIN" ] || { echo "ERROR: app binary missing at $BIN"; exit 1; }

echo "==> [4/4] assemble $APP_OUT"
rm -rf "$APP_OUT"
mkdir -p "$APP_OUT/Contents/MacOS" "$APP_OUT/Contents/Resources"
cp "$BIN" "$APP_OUT/Contents/MacOS/Blockfall"
# Bundle content (data-driven; spec §4.10) and assets.
cp -R "$ROOT/content" "$APP_OUT/Contents/Resources/content"
[ -d "$ROOT/assets" ] && cp -R "$ROOT/assets" "$APP_OUT/Contents/Resources/assets" || true
cat > "$APP_OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Blockfall</string>
  <key>CFBundleDisplayName</key><string>Blockfall</string>
  <key>CFBundleIdentifier</key><string>com.blockfall.game</string>
  <key>CFBundleVersion</key><string>0.0.1</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleExecutable</key><string>Blockfall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# Ad-hoc sign (spec §4.11). Real .dmg signing happens in package.sh.
codesign --force --deep --sign - "$APP_OUT" >/dev/null 2>&1 || \
  echo "   (codesign skipped/failed; ad-hoc sign happens in package.sh)"

echo "==> built: $APP_OUT"
