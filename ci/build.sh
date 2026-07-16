#!/usr/bin/env bash
# Blockfall — build.sh : produce a runnable Blockfall.app (spec §5).
# Steps: build the Rust engine staticlib (libbfcore.a) -> copy the frozen C ABI
# header into the Swift interop module -> build the Swift app -> assemble the
# .app bundle. The C++ engine was retired (#101); the engine is now Rust (bfcore).
# arm64-only (spec §2/§4.11).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"          # debug | release
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-100}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: VERSION must look like 0.1.0"; exit 1;
}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "ERROR: BUILD_NUMBER must be an integer"; exit 1;
}

# Self-install the commit hook (require a #issue ref on every commit). Idempotent;
# this is how the hook gets enforced on a fresh clone without a manual step.
git -C "$ROOT" config core.hooksPath .githooks 2>/dev/null || true
BUILD="$ROOT/build"
APP_OUT="$BUILD/Blockfall.app"
export PATH="/opt/homebrew/bin:$PATH"

echo "==> [1/4] Rust engine (bfcore staticlib, release)"
# The app links libbfcore.a. Always release: a debug build of the engine is too slow
# so a debug build is too slow to be usable, and the C ABI is identical either way.
( cd "$ROOT/engine-rs/bfcore" && cargo build --release >/dev/null )
LIB_DIR="$ROOT/engine-rs/bfcore/target/release"
[ -f "$LIB_DIR/libbfcore.a" ] || { echo "ERROR: libbfcore.a missing"; exit 1; }

echo "==> [2/4] sync frozen C ABI header into Swift interop module"
cp "$ROOT/contract/engine_c_api.h" \
   "$ROOT/app/Sources/CBlockcore/include/engine_c_api.h"

echo "==> [3/4] Swift app ($CONFIG)"
SWIFT_FLAGS=()
[ "$CONFIG" = release ] && SWIFT_FLAGS+=(-c release)
# Silence the benign "object file built for newer macOS version" ld warnings. They come
# from Rust's PRECOMPILED std (std/core/alloc/compiler_builtins/backtrace) bundled into
# libbfcore.a, stamped with the host SDK min-version; our own code targets 14.0 via
# engine-rs/bfcore/.cargo/config.toml. Retargeting std would need nightly -Z build-std.
SWIFT_FLAGS+=(-Xlinker -w)
( cd "$ROOT/app" && BLOCKCORE_LIB_DIR="$LIB_DIR" swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} )
BIN="$ROOT/app/.build/$CONFIG/BlockfallApp"
SPARKLE="$ROOT/app/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -f "$BIN" ] || { echo "ERROR: app binary missing at $BIN"; exit 1; }
[ -d "$SPARKLE" ] || { echo "ERROR: Sparkle.framework missing at $SPARKLE"; exit 1; }

echo "==> [4/4] assemble $APP_OUT"
rm -rf "$APP_OUT"
mkdir -p "$APP_OUT/Contents/MacOS" "$APP_OUT/Contents/Resources" "$APP_OUT/Contents/Frameworks"
cp "$BIN" "$APP_OUT/Contents/MacOS/Blockfall"
ditto "$SPARKLE" "$APP_OUT/Contents/Frameworks/Sparkle.framework"
# Bundle content (data-driven; spec §4.10) and assets.
cp -R "$ROOT/content" "$APP_OUT/Contents/Resources/content"
[ -d "$ROOT/assets" ] && cp -R "$ROOT/assets" "$APP_OUT/Contents/Resources/assets" || true
cat > "$APP_OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Blockfall</string>
  <key>CFBundleDisplayName</key><string>Blockfall</string>
  <key>CFBundleIdentifier</key><string>com.blockfall.game</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>Blockfall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>https://github.com/royashbrook/blockfall/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>7tBlyVffiHJNDDc76Chm2CZ7Y61/xfUVk3sPWvC9dm8=</string>
</dict></plist>
PLIST
plutil -lint "$APP_OUT/Contents/Info.plist" >/dev/null

# Ad-hoc sign (spec §4.11). Real .dmg signing happens in package.sh.
codesign --force --deep --sign - "$APP_OUT" >/dev/null 2>&1 || \
  echo "   (codesign skipped/failed; ad-hoc sign happens in package.sh)"

echo "==> built: $APP_OUT"
