#!/usr/bin/env bash
set -Eeuo pipefail

patcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
port_dir=$(cd -- "$patcher_dir/../.." && pwd)

exec bash "$port_dir/common/settings_apk_patcher.sh" haptic "$@"
