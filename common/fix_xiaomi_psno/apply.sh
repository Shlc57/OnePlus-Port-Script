#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "补齐 Xiaomi 电话 SN 展示 fallback"
std_print "仅在 Xiaomi PSNO 为空时，将目标 ro.serialno 复制到 Phone SN 字段"
std_print

check_part_exists system_ext

# shellcheck disable=SC2154 # project_dir 由 init_port_env/tools.sh 导出。
target_rc="${project_dir}/system_ext/etc/init/init.miui.ext.rc"
# shellcheck disable=SC2154 # project_dir 由 init_port_env/tools.sh 导出。
property_contexts="${project_dir}/system_ext/etc/selinux/system_ext_property_contexts"
fallback_block="${patcher_dir}/config/init_psno_fallback.rc"
temporary_rc=""

cleanup() {
	if [[ -n "$temporary_rc" ]]; then
		rm -f -- "$temporary_rc"
	fi
}
trap cleanup EXIT

for required_file in "$target_rc" "$property_contexts" "$fallback_block"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" || ! -f "$required_file" ]]; then
		err_print "Phone SN fallback 输入必须是普通文件：$required_file"
		exit 1
	fi
done

if ! grep -Eq '^ro\.ril\.oem\.psno[[:space:]]+u:object_r:sno_prop:s0[[:space:]]*$' "$property_contexts"; then
	err_print "system_ext property contexts 缺少 ro.ril.oem.psno 的 sno_prop 契约"
	exit 1
fi

temporary_rc="$(mktemp "${target_rc}.tmp.XXXXXX")"
if ! PYTHONDONTWRITEBYTECODE=1 python3 - "$target_rc" "$fallback_block" "$temporary_rc" <<'PY'
import sys
from pathlib import Path


target_path = Path(sys.argv[1])
block_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])
begin = "# BEGIN common xiaomi psno fallback"
end = "# END common xiaomi psno fallback"
canonical_block = """# BEGIN common xiaomi psno fallback
# Display fallback for Xiaomi DeviceInfoQR Phone SN.
# It only fills an empty Xiaomi Phone SN field after boot from the target
# serial number; it does not claim a Xiaomi OEM NV PSNO and does not alter
# IMEI, PCB SN, or Factory ID.
on property:sys.boot_completed=1 && property:ro.ril.oem.psno=
    setprop ro.ril.oem.psno ${ro.serialno}
# END common xiaomi psno fallback"""

try:
    target_text = target_path.read_bytes().decode("utf-8")
    template_text = block_path.read_bytes().decode("utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"读取 Phone SN fallback 输入失败：{error}")

if template_text.rstrip("\r\n") != canonical_block:
    raise SystemExit(f"Phone SN fallback 模板内容不符合固定契约：{block_path}")

newline = "\r\n" if "\r\n" in target_text else "\n"
expected_block = canonical_block.replace("\n", newline)
begin_count = target_text.count(begin)
end_count = target_text.count(end)

if begin_count or end_count:
    if begin_count != 1 or end_count != 1:
        raise SystemExit(
            "Phone SN fallback 标记数量应各为 0 或 1："
            f"begin={begin_count}, end={end_count}"
        )
    begin_index = target_text.index(begin)
    end_index = target_text.index(end, begin_index) + len(end)
    if target_text[begin_index:end_index] != expected_block:
        raise SystemExit("已有 Phone SN fallback 与固定契约不一致，拒绝覆盖")
    updated = target_text
else:
    trigger = "on property:sys.boot_completed=1 && property:ro.ril.oem.psno="
    assignment = "    setprop ro.ril.oem.psno ${ro.serialno}"
    if trigger in target_text or assignment in target_text:
        raise SystemExit("发现未标记的 Phone SN fallback，拒绝生成第二份规则")
    separator = "" if target_text.endswith(("\n", "\r")) else newline
    updated = target_text + separator + newline + expected_block + newline

try:
    output_path.write_bytes(updated.encode("utf-8"))
except OSError as error:
    raise SystemExit(f"写入临时 Phone SN fallback rc 失败：{error}")
PY
then
	err_print "生成 Phone SN fallback rc 失败"
	exit 1
fi

expected_assignment='    setprop ro.ril.oem.psno $'"{ro.serialno}"
if ! grep -Fqx 'on property:sys.boot_completed=1 && property:ro.ril.oem.psno=' "$temporary_rc" || \
	! grep -Fqx "$expected_assignment" "$temporary_rc"; then
	err_print "生成结果缺少固定 Phone SN fallback action"
	exit 1
fi

_install_generated_file "$temporary_rc" "$target_rc"
temporary_rc=""

std_print "✅ 已登记 Phone SN 展示 fallback；仅冷启动 DSU 后可验证"
