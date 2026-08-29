#!/usr/bin/env bash
set -Eeuo pipefail

# Build-time JAR patcher for the OnePlus ADFR RUS loader.  It also removes the
# exact Full-AOD init replay emitted by the superseded revision.
patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$patcher_dir/patch_miui_services_adfr.py" "$@"
