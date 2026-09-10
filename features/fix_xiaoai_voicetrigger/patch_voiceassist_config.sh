#!/usr/bin/env bash
set -Eeuo pipefail

PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PORT_DIR=$(cd -- "$PATCHER_DIR/../.." && pwd -P)
APK_PATCHER="$PORT_DIR/tools/apk_patcher.sh"
ASSET_ENTRY='assets/voiceassist.ai.voice.trigger.config'

log() { printf '[*] %s\n' "$*"; }
fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
WORK_DIR=''
cleanup() {
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		find "$WORK_DIR" -depth -delete >/dev/null 2>&1 || true
	fi
}
rollback_on_exit() {
	local status=$?
	if (( status != 0 )); then
		apk_patcher_rollback "$status" >/dev/null 2>&1 || true
	fi
	cleanup
	return "$status"
}

unset APK_PATCHER_SESSION_DIR
# shellcheck disable=SC1090
source "$APK_PATCHER"

(( $# == 2 )) || fail "用法：$0 <VoiceAssistAndroidT.apk> <device-code>"
APK_PATH=$1
DEVICE_CODE=$2
[[ -f "$APK_PATH" && ! -L "$APK_PATH" ]] || fail "找不到 VoiceAssistAndroidT.apk：$APK_PATH"
[[ "$DEVICE_CODE" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || fail "无效的 Android device token：$DEVICE_CODE"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd -P)/$(basename -- "$APK_PATH")
[[ "$(apk_patcher_entry_count "$APK_PATH" "$ASSET_ENTRY")" == 1 ]] ||
	fail "VoiceAssistAndroidT.apk 中目标资产条目数量异常：$ASSET_ENTRY"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/.voiceassist-apk-patcher.XXXXXX")
trap cleanup EXIT
apk_patcher_open "$WORK_DIR" "$APK_PATH" apk || fail "无法打开 VoiceAssistAndroidT.apk 会话"
apk_patcher_snapshot || fail "无法保存 VoiceAssistAndroidT.apk 补丁快照"
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ASSET_PATH="$SESSION_DECODE_DIR/$ASSET_ENTRY"
[[ -f "$ASSET_PATH" && ! -L "$ASSET_PATH" ]] || fail "解包后的 VoiceAssist 目标资产缺失或是符号链接：$ASSET_ENTRY"
PATCH_RESULT=$(python3 - "$ASSET_PATH" "$DEVICE_CODE" <<'PY'
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

asset_path = Path(sys.argv[1])
device_code = sys.argv[2]

try:
    raw = asset_path.read_text(encoding="utf-8")
    data = json.loads(raw)
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"VoiceAssist 设备准入配置格式非法：{error}")

if not isinstance(data, dict):
    raise SystemExit("VoiceAssist 设备准入配置根节点必须是对象")
cloud_control = data.get("cloudControl")
if not isinstance(cloud_control, list):
    raise SystemExit("VoiceAssist 设备准入配置 cloudControl 必须是数组")

seen = set()
matching = []
for index, item in enumerate(cloud_control):
    if not isinstance(item, dict):
        raise SystemExit(f"cloudControl[{index}] 必须是对象")
    device = item.get("device")
    if not isinstance(device, str) or not device:
        raise SystemExit(f"cloudControl[{index}].device 必须是非空字符串")
    if device in seen:
        raise SystemExit(f"cloudControl 存在重复设备条目：{device}")
    seen.add(device)
    if device == device_code:
        matching.append(item)

expected = {"device": device_code, "os": 9}
if matching:
    if matching[0] != expected:
        raise SystemExit(f"目标设备 {device_code} 已存在但内容冲突")
    print("unchanged")
    raise SystemExit(0)

cloud_control.append(expected)
updated = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", ": ")) + "\n"
file_mode = stat.S_IMODE(asset_path.stat().st_mode)
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="",
        prefix=f".{asset_path.name}.",
        suffix=".tmp",
        dir=asset_path.parent,
        delete=False,
    ) as temporary:
        temporary.write(updated)
        temporary_name = temporary.name
    try:
        os.chmod(temporary_name, file_mode)
        os.replace(temporary_name, asset_path)
    except Exception:
        os.unlink(temporary_name)
        raise
except OSError as error:
    raise SystemExit(f"写入 VoiceAssist 设备准入配置失败：{error}")

print("patched")
PY
) || fail "修改 VoiceAssist 设备准入配置失败"

case "$PATCH_RESULT" in
	unchanged)
		log "SKIP：VoiceAssist 已准入设备 $DEVICE_CODE"
		exit 0
		;;
	patched) ;;
	*) fail "VoiceAssist 设备准入配置未产生预期结果：$PATCH_RESULT" ;;
esac

apk_patcher_record_entry "$ASSET_ENTRY" || fail "无法登记 VoiceAssistAndroidT.apk 目标资产"
apk_patcher_finalize || fail "VoiceAssistAndroidT.apk 最终回编译失败"
log "APPLY：VoiceAssist 已准入设备 $DEVICE_CODE：$APK_PATH"
