#!/usr/bin/env bash
# Rebuild the engine + app, then launch the latest build.
#
# ALWAYS use this to playtest. Do NOT run "open build/Blockfall.app" on its own:
# that launches the last BUILT app, not the latest source, so you can silently
# test stale code after new commits land. This rebuilds first, every time.
#
#   ./play.sh            # debug build (fast to compile), then launch
#   ./play.sh release    # release build (faster runtime), then launch
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
"$ROOT/ci/build.sh" "${1:-debug}"
echo "==> launching $ROOT/build/Blockfall.app"
open "$ROOT/build/Blockfall.app"
