#!/usr/bin/env bash
# Build, notarize, Sparkle-sign, and publish a Blockfall GitHub Release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-100}"
REPO="royashbrook/blockfall"
TAG="v$VERSION"
DMG="$ROOT/dist/Blockfall-$VERSION.dmg"
APPCAST_TOOL="$ROOT/app/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: VERSION must look like 0.1.0"; exit 1;
}
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
  echo "ERROR: BUILD_NUMBER must be an integer"; exit 1;
}

if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
  echo "ERROR: commit tracked changes before publishing"; exit 1
fi
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse '@{upstream}')" ] || {
  echo "ERROR: push the release commit before publishing"; exit 1;
}
[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" = PUBLIC ] || {
  echo "ERROR: $REPO must be public so installed apps can read the update feed"; exit 1;
}
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && {
  echo "ERROR: GitHub Release $TAG already exists"; exit 1;
}

VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/ci/package.sh"
[ -x "$APPCAST_TOOL" ] || { echo "ERROR: generate_appcast is missing"; exit 1; }

RELEASE_DIR="$(mktemp -d)"
trap 'rm -rf "$RELEASE_DIR"' EXIT
cp "$DMG" "$RELEASE_DIR/"
"$APPCAST_TOOL" --account blockfall \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO/releases/tag/$TAG" \
  "$RELEASE_DIR"

gh release create "$TAG" --repo "$REPO" --target "$(git -C "$ROOT" rev-parse HEAD)" \
  --title "Blockfall $VERSION" --generate-notes --latest \
  "$DMG" "$RELEASE_DIR/appcast.xml"

echo "==> published: https://github.com/$REPO/releases/tag/$TAG"
