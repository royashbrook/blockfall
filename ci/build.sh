#!/usr/bin/env bash
# Blockfall — build.sh : produce a runnable Blockfall.app (spec §5).
# Steps: build the C++ core (CMake) -> copy the frozen C ABI header into the
# Swift interop module -> build the Swift app -> assemble the .app bundle.
# arm64-only (spec §2/§4.11).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"          # debug | release
BUILD="$ROOT/build"
APP_OUT="$BUILD/Blockfall.app"
export PATH="/opt/homebrew/bin:$PATH"

echo "==> [1/4] C++ core (blockcore, $CONFIG)"
CMAKE_BT=$([ "$CONFIG" = release ] && echo Release || echo Debug)
cmake -S "$ROOT/engine" -B "$BUILD/engine" \
      -DCMAKE_BUILD_TYPE="$CMAKE_BT" -DBF_BUILD_TESTS=ON >/dev/null
cmake --build "$BUILD/engine" -j >/dev/null
LIB_DIR="$BUILD/engine"
[ -f "$LIB_DIR/libblockcore.a" ] || { echo "ERROR: libblockcore.a missing"; exit 1; }

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
echo '<?xml version="1.0"?>' > /dev/null

# Ad-hoc sign (spec §4.11). Real .dmg signing happens in package.sh.
codesign --force --deep --sign - "$APP_OUT" >/dev/null 2>&1 || \
  echo "   (codesign skipped/failed; ad-hoc sign happens in package.sh)"

echo "==> built: $APP_OUT"
