#!/usr/bin/env bash
# Blockfall — package.sh : arm64 ad-hoc-signed .dmg, drag-to-Applications
# (spec §4.11 / Track I). arm64-only: no universal binary (both ends are
# Apple Silicon — see docs/adr/0002-arm64-only.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$ROOT/build/Blockfall.app"

echo "==> release build"
"$ROOT/ci/build.sh" release >/dev/null
[ -d "$APP" ] || { echo "ERROR: $APP not found"; exit 1; }

# Verify arm64-only (Track I acceptance: otool shows no external deps beyond
# system frameworks; arch is arm64).
echo "==> arch check"
file "$APP/Contents/MacOS/Blockfall" | grep -q arm64 || { echo "ERROR: not arm64"; exit 1; }
if lipo -archs "$APP/Contents/MacOS/Blockfall" 2>/dev/null | grep -qw x86_64; then
  echo "ERROR: universal binary; spec requires arm64-only"; exit 1
fi

echo "==> ad-hoc sign"
codesign --force --deep --sign - "$APP"

echo "==> stage dmg"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/Blockfall.dmg"
rm -f "$DMG"
hdiutil create -volname "Blockfall" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> dependency check (otool)"
otool -L "$APP/Contents/MacOS/Blockfall" | tail -n +2 | \
  grep -vE '/usr/lib/|/System/Library/' && \
  { echo "WARNING: non-system dynamic dependency present"; } || echo "   only system frameworks ✔"

echo "==> packaged: $DMG"
echo "   On a clean Mac (unsigned-by-cert): right-click Blockfall.app -> Open the first time (Gatekeeper)."
