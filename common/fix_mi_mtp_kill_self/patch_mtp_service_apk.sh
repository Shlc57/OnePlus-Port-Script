#!/usr/bin/env bash
set -Eeuo pipefail

CURRENT_PROCESS='android.process.media'
ISOLATED_PROCESS='android.process.mtp'

PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PORT_ROOT=$(cd -- "$PATCHER_DIR/../.." && pwd)
SIGNING_BLOCK_TOOL="$PORT_ROOT/common/apk_signing_block.py"

WORK_DIR=''
REPLACEMENT_PATH=''

log() {
	printf '[*] %s\n' "$*"
}

fail() {
	printf '[!] %s\n' "$*" >&2
	exit 1
}

cleanup() {
	if [[ -n "$REPLACEMENT_PATH" && -e "$REPLACEMENT_PATH" ]]; then
		rm -f -- "$REPLACEMENT_PATH"
	fi
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		find "$WORK_DIR" -depth -delete >/dev/null 2>&1 || true
	fi
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "缺少依赖命令：$1"
}

resolve_apktool() {
	if [[ -n "${APKTOOL_JAR:-}" ]]; then
		[[ -r "$APKTOOL_JAR" ]] || fail "无法读取 APKTOOL_JAR：$APKTOOL_JAR"
		require_command java
		APKTOOL_COMMAND=(java -jar "$APKTOOL_JAR")
	elif [[ -r /snap/apktool/current/apktool.jar ]]; then
		require_command java
		APKTOOL_COMMAND=(java -jar /snap/apktool/current/apktool.jar)
	elif command -v apktool >/dev/null 2>&1; then
		APKTOOL_COMMAND=(apktool)
	else
		fail "缺少 Apktool"
	fi
}

resolve_zipalign() {
	local sdk_root candidate

	if [[ -n "${ZIPALIGN:-}" ]]; then
		[[ -x "$ZIPALIGN" ]] || fail "ZIPALIGN 不可执行：$ZIPALIGN"
		ZIPALIGN_COMMAND=$ZIPALIGN
		return
	fi
	if command -v zipalign >/dev/null 2>&1; then
		ZIPALIGN_COMMAND=$(command -v zipalign)
		return
	fi

	for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "${ANDROID_SDK:-}"; do
		[[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]] || continue
		candidate=$(find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 \
			-type f -name zipalign -perm -u+x -print | LC_ALL=C sort -V | tail -n 1)
		if [[ -n "$candidate" ]]; then
			ZIPALIGN_COMMAND=$candidate
			return
		fi
	done

	fail "缺少 zipalign；可通过 ZIPALIGN 指定可执行文件"
}

compare_archive_contract() {
	local before_apk=$1
	local after_apk=$2
	local excluded_entry=${3:-}

	python3 - "$before_apk" "$after_apk" "$excluded_entry" <<'PY'
import sys
import zipfile
import zlib

before_path, after_path, excluded_entry = sys.argv[1:]


def fail(message):
	print(f"归档契约校验失败：{message}", file=sys.stderr)
	raise SystemExit(1)


def open_archive(path):
	try:
		archive = zipfile.ZipFile(path)
		infos = archive.infolist()
	except (OSError, EOFError, IndexError, MemoryError, OverflowError, RuntimeError,
			ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
		fail(f"无法读取 {path}: {error}")
	names = [info.filename for info in infos]
	if len(names) != len(set(names)):
		archive.close()
		fail(f"{path} 包含重复 ZIP 条目")
	return archive, infos


before, before_infos = open_archive(before_path)
after, after_infos = open_archive(after_path)
try:
	if len(before_infos) != len(after_infos):
		fail(f"条目数量变化：{len(before_infos)} -> {len(after_infos)}")
	if excluded_entry:
		before_excluded = [info for info in before_infos if info.filename == excluded_entry]
		after_excluded = [info for info in after_infos if info.filename == excluded_entry]
		if len(before_excluded) != 1 or len(after_excluded) != 1:
			fail(f"目标条目 {excluded_entry!r} 数量异常")

	for index, (before_info, after_info) in enumerate(zip(before_infos, after_infos)):
		if before_info.filename != after_info.filename:
			fail(f"条目顺序或名称变化（位置 {index}: {before_info.filename!r} -> {after_info.filename!r}）")
		if (
			before_info.filename != excluded_entry
			and before_info.compress_type != after_info.compress_type
		):
			fail(f"条目压缩方式变化（{before_info.filename!r}: {before_info.compress_type} -> {after_info.compress_type}）")
		if before_info.filename == excluded_entry:
			continue
		try:
			before_content = before.read(before_info)
			after_content = after.read(after_info)
		except (EOFError, IndexError, KeyError, MemoryError, NotImplementedError,
			OSError, OverflowError, RuntimeError, ValueError, zipfile.BadZipFile,
			zipfile.LargeZipFile, zlib.error) as error:
			fail(f"条目 {before_info.filename!r} 内容读取失败：{error}")
		if before_content != after_content:
			fail(f"非目标条目内容变化：{before_info.filename!r}")
finally:
	before.close()
	after.close()
PY
}

manifest_state() {
	local manifest=$1
	local mode=$2

	python3 - "$manifest" "$mode" "$CURRENT_PROCESS" "$ISOLATED_PROCESS" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

manifest_path = Path(sys.argv[1])
mode = sys.argv[2]
current_process = sys.argv[3]
isolated_process = sys.argv[4]
android_ns = "http://schemas.android.com/apk/res/android"
process_attr = f"{{{android_ns}}}process"

if mode not in {"check", "patch"}:
    raise SystemExit("[!] 无效的 manifest 操作模式")

try:
    tree = ET.parse(manifest_path)
except (OSError, ET.ParseError) as error:
    raise SystemExit(f"[!] 读取 AndroidManifest.xml 失败：{error}")

application = tree.getroot().find("application")
if application is None:
    raise SystemExit("[!] AndroidManifest.xml 缺少 application")

value = application.get(process_attr)
if value == isolated_process:
    print("patched")
    raise SystemExit(0)
if value != current_process:
    raise SystemExit(
        f"[!] 不支持的 MTP application 进程：{value!r}；"
        f"期望 {current_process!r} 或 {isolated_process!r}"
    )

if mode == "patch":
    ET.register_namespace("android", android_ns)
    application.set(process_attr, isolated_process)
    try:
        tree.write(manifest_path, encoding="utf-8", xml_declaration=True)
    except OSError as error:
        raise SystemExit(f"[!] 写入 AndroidManifest.xml 失败：{error}")

print("original")
PY
}

validate_and_install_apk() {
	python3 "$SIGNING_BLOCK_TOOL" insert "$PATCHED_APK" "$SIGNING_BLOCK_BEFORE"
	python3 "$SIGNING_BLOCK_TOOL" extract "$PATCHED_APK" "$SIGNING_BLOCK_AFTER" >/dev/null
	cmp -s "$SIGNING_BLOCK_BEFORE" "$SIGNING_BLOCK_AFTER" ||
		fail "更新后 APK Signing Block 内容发生变化"
	"$ZIPALIGN_COMMAND" -c -P 16 4 "$PATCHED_APK" ||
		fail "更新后的 APK 未通过 zipalign 校验"
	unzip -tq "$PATCHED_APK" >/dev/null || fail "更新后的 APK 完整性校验失败"
	cmp -s "$MANIFEST_REPLACEMENT" <(unzip -p "$PATCHED_APK" AndroidManifest.xml) ||
		fail "AndroidManifest.xml 未正确写入 APK"

	compare_archive_contract "$APK_PATH" "$PATCHED_APK" AndroidManifest.xml ||
		fail "更新后 APK 的非目标归档契约发生变化"

	cp --attributes-only --preserve=all -- "$APK_PATH" "$PATCHED_APK" ||
		fail "无法恢复原 MtpService.apk 文件属性"
	REPLACEMENT_PATH=$(mktemp "$APK_DIR/.MtpService.apk.patch.XXXXXX")
	cp -a -- "$PATCHED_APK" "$REPLACEMENT_PATH"
	mv -fT -- "$REPLACEMENT_PATH" "$APK_PATH"
	REPLACEMENT_PATH=''

	log "APPLY：MtpService 已迁移至独立进程 $ISOLATED_PROCESS"
	log "已原样保留 Signing Block 与 META-INF 证书材料；AndroidManifest 修改会使 v1/v2/v3 内容完整性签名失效"
}

(( $# == 1 )) || fail "用法：$0 <MtpService.apk>"
APK_PATH=$1

for command_name in cmp cp dirname find java mkdir mktemp mv python3 rm sort tail unzip zip; do
	require_command "$command_name"
done
resolve_apktool
resolve_zipalign
[[ -r "$SIGNING_BLOCK_TOOL" ]] || fail "找不到 Signing Block 工具：$SIGNING_BLOCK_TOOL"
[[ -f "$APK_PATH" ]] || fail "找不到 MtpService.apk：$APK_PATH"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd)/$(basename -- "$APK_PATH")
APK_DIR=$(dirname -- "$APK_PATH")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fix-mi-mtp-kill-self.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR="$WORK_DIR/decoded"
REBUILT_APK="$WORK_DIR/rebuilt.apk"
MANIFEST_DIR="$WORK_DIR/manifest"
MANIFEST_REPLACEMENT="$MANIFEST_DIR/AndroidManifest.xml"
PATCHED_APK="$WORK_DIR/MtpService.apk.patched"
ALIGNED_APK="$WORK_DIR/MtpService.apk.aligned"
SIGNING_BLOCK_BEFORE="$WORK_DIR/apk-signing-block.before"
SIGNING_BLOCK_AFTER="$WORK_DIR/apk-signing-block.after"

log "反编译 MtpService.apk"
# 必须解码 manifest；-r 会原样保留二进制 AndroidManifest.xml。
"${APKTOOL_COMMAND[@]}" d -f -s "$APK_PATH" -o "$DECODE_DIR"
MANIFEST_PATH="$DECODE_DIR/AndroidManifest.xml"
[[ -f "$MANIFEST_PATH" ]] || fail "反编译结果缺少 AndroidManifest.xml"

STATE=$(manifest_state "$MANIFEST_PATH" check)
if [[ "$STATE" == patched ]]; then
	"$ZIPALIGN_COMMAND" -c -P 16 4 "$APK_PATH" >/dev/null 2>&1 ||
		fail "MtpService 已隔离进程，但 APK 未对齐，拒绝静默改写"
	log "SKIP：MtpService 已使用独立进程 $ISOLATED_PROCESS"
	exit 0
fi
[[ "$STATE" == original ]] || fail "MtpService manifest 状态异常：$STATE"

log "记录原 APK 的 Signing Block"
python3 "$SIGNING_BLOCK_TOOL" extract "$APK_PATH" "$SIGNING_BLOCK_BEFORE" >/dev/null

manifest_state "$MANIFEST_PATH" patch >/dev/null
[[ "$(manifest_state "$MANIFEST_PATH" check)" == patched ]] ||
	fail "AndroidManifest.xml 进程隔离写入后校验失败"

log "回编译 APK 以生成新的 AndroidManifest.xml"
"${APKTOOL_COMMAND[@]}" b "$DECODE_DIR" -o "$REBUILT_APK"
mkdir -p "$MANIFEST_DIR"
unzip -p "$REBUILT_APK" AndroidManifest.xml > "$MANIFEST_REPLACEMENT" ||
	fail "回编译结果中缺少 AndroidManifest.xml"
[[ -s "$MANIFEST_REPLACEMENT" ]] || fail "生成的 AndroidManifest.xml 为空"

log "仅将 AndroidManifest.xml 增量写入原 APK 副本"
cp -a -- "$APK_PATH" "$PATCHED_APK"
(
	cd -- "$MANIFEST_DIR"
	zip -q -0 "$PATCHED_APK" AndroidManifest.xml
)

log "重新对齐并回插原 APK Signing Block"
"$ZIPALIGN_COMMAND" -f -P 16 4 "$PATCHED_APK" "$ALIGNED_APK" ||
	fail "zipalign 对齐失败"
mv -- "$ALIGNED_APK" "$PATCHED_APK"
validate_and_install_apk
