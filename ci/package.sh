#!/usr/bin/env bash
# Blockfall — package.sh : arm64 Developer ID signed + notarized .dmg.
# (spec §4.11 / Track I). arm64-only: no universal binary (both ends are
# Apple Silicon — see docs/adr/0002-arm64-only.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$ROOT/build/Blockfall.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-100}"
NOTARY_PROFILE="${NOTARY_PROFILE:-blockfall-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F\" '/Developer ID Application/ { print $2; exit }')"
fi
[ -n "$SIGN_IDENTITY" ] || {
  echo "ERROR: no Developer ID Application identity found in Keychain"
  echo "       Install the certificate/private key, then retry."
  exit 1
}

echo "==> release build"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/ci/build.sh" release >/dev/null
[ -d "$APP" ] || { echo "ERROR: $APP not found"; exit 1; }

# Verify arm64-only (Track I acceptance: otool shows no external deps beyond
# system frameworks; arch is arm64).
echo "==> arch check"
file "$APP/Contents/MacOS/Blockfall" | grep -q arm64 || { echo "ERROR: not arm64"; exit 1; }
if lipo -archs "$APP/Contents/MacOS/Blockfall" 2>/dev/null | grep -qw x86_64; then
  echo "ERROR: universal binary; spec requires arm64-only"; exit 1
fi

echo "==> Developer ID sign"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> stage dmg"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/Blockfall-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Blockfall" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

echo "==> notarize + staple"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "==> dependency check (otool)"
otool -L "$APP/Contents/MacOS/Blockfall" | tail -n +2 | \
  grep -vE '/usr/lib/|/System/Library/' && \
  { echo "WARNING: non-system dynamic dependency present"; } || echo "   only system frameworks ✔"

echo "==> packaged: $DMG"
echo "   version $VERSION ($BUILD_NUMBER), signed + notarized"
