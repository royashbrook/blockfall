#!/usr/bin/env bash
# Verify the generated Apple engine artifact has exactly the supported slices
# and exports the frozen Blockfall ABI (#344).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK="${1:-$ROOT/app/Artifacts/CBlockcore.xcframework}"
INFO="$XCFRAMEWORK/Info.plist"

[ -f "$INFO" ] || {
  echo "ERROR: XCFramework Info.plist missing: $INFO" >&2
  exit 1
}

python3 - "$XCFRAMEWORK" "$ROOT/tests/ffi/xcframework_smoke.c" <<'PY'
import pathlib
import plistlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
smoke_source = pathlib.Path(sys.argv[2])
with (root / "Info.plist").open("rb") as f:
    libraries = plistlib.load(f).get("AvailableLibraries", [])

expected = {
    ("macos", None),
    ("ios", None),
    ("ios", "simulator"),
}
link_targets = {
    ("macos", None): ("macosx", "arm64-apple-macos14.0"),
    ("ios", None): ("iphoneos", "arm64-apple-ios17.0"),
    ("ios", "simulator"): ("iphonesimulator", "arm64-apple-ios17.0-simulator"),
}
found = {
    (entry.get("SupportedPlatform"), entry.get("SupportedPlatformVariant"))
    for entry in libraries
}
if found != expected or len(libraries) != len(expected):
    raise SystemExit(f"unexpected XCFramework platforms: {sorted(found, key=str)}")

for entry in libraries:
    identifier = entry["LibraryIdentifier"]
    if entry.get("SupportedArchitectures") != ["arm64"]:
        raise SystemExit(
            f"{identifier}: expected arm64, got {entry.get('SupportedArchitectures')}"
        )
    library = root / identifier / entry["LibraryPath"]
    headers = root / identifier / entry["HeadersPath"]
    if not library.is_file():
        raise SystemExit(f"{identifier}: missing {library}")
    for name in ("engine_c_api.h", "module.modulemap"):
        if not (headers / name).is_file():
            raise SystemExit(f"{identifier}: missing header artifact {name}")
    archs = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
    if archs != ["arm64"]:
        raise SystemExit(f"{identifier}: expected arm64 archive, got {archs}")

    # Link a real ABI consumer with Apple's linker. This verifies both the
    # exported symbol and that the Rust archive is consumable by the target SDK;
    # Apple's nm may reject newer LLVM metadata embedded in Rust std objects.
    platform = (entry.get("SupportedPlatform"), entry.get("SupportedPlatformVariant"))
    sdk, target = link_targets[platform]
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True
    ).strip()
    with tempfile.TemporaryDirectory(prefix=f"bf-{identifier}-") as tmp:
        executable = pathlib.Path(tmp) / "abi-smoke"
        subprocess.check_call([
            "xcrun", "--sdk", sdk, "clang",
            "-target", target,
            "-isysroot", sdk_path,
            "-I", str(headers),
            str(smoke_source),
            str(library),
            "-o", str(executable),
        ])
        if platform == ("macos", None):
            subprocess.check_call([str(executable)])

print("XCFramework verified: macOS + iPadOS device + iPad simulator (arm64)")
PY
