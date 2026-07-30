#!/usr/bin/env bash
# Build the native iPad application against the shared Rust-engine XCFramework.
# The default is unsigned so CI and any Apple Silicon developer Mac can prove
# both simulator and device compilation without provisioning credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/ipad/BlockfallPad.xcodeproj"
DERIVED="$ROOT/build/ipad-derived"
CONFIG="${1:-Debug}"

"$ROOT/ci/build-xcframework.sh"

if [ "${BF_REGENERATE_XCODEPROJ:-0}" = 1 ]; then
  command -v xcodegen >/dev/null || {
    echo "ERROR: xcodegen is required only when BF_REGENERATE_XCODEPROJ=1" >&2
    exit 1
  }
  xcodegen generate --spec "$ROOT/ipad/project.yml"
fi

[ -d "$PROJECT" ] || {
  echo "ERROR: missing committed Xcode project: $PROJECT" >&2
  echo "Regenerate it with: BF_REGENERATE_XCODEPROJ=1 $0" >&2
  exit 1
}

COMMON=(
  -project "$PROJECT"
  -scheme BlockfallPad
  -configuration "$CONFIG"
  -derivedDataPath "$DERIVED"
  CODE_SIGNING_ALLOWED=NO
  COMPILER_INDEX_STORE_ENABLE=NO
)

echo "==> iPad simulator app"
xcodebuild "${COMMON[@]}" \
  -sdk iphonesimulator \
  -destination "generic/platform=iOS Simulator" \
  build

echo "==> generic iPad device compilation"
xcodebuild "${COMMON[@]}" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  build

SIM_APP="$DERIVED/Build/Products/$CONFIG-iphonesimulator/Blockfall.app"
DEVICE_APP="$DERIVED/Build/Products/$CONFIG-iphoneos/Blockfall.app"
for app in "$SIM_APP" "$DEVICE_APP"; do
  [ -d "$app" ] || { echo "ERROR: app missing: $app" >&2; exit 1; }
  [ -f "$app/content/blocks/terrain.json" ] || {
    echo "ERROR: bundled content missing from $app" >&2
    exit 1
  }
  lipo -archs "$app/Blockfall" | grep -qw arm64 || {
    echo "ERROR: $app is missing arm64" >&2
    exit 1
  }
done

echo "==> simulator: $SIM_APP"
echo "==> device:    $DEVICE_APP"
