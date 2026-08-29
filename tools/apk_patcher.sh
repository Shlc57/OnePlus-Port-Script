#!/usr/bin/env bash

# 通用 APK/JAR 解包事务辅助。补丁脚本只负责修改 SESSION_DECODE_DIR 中的
# 目标文件；本文件负责一次解包、补丁级快照、失败回滚和最终一次回编译。

APK_PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
APK_PATCHER_SIGNING_TOOL="$APK_PATCHER_DIR/apk_signing_block.py"
# shellcheck source=toolchain.sh
# shellcheck disable=SC1091 # 工具目录由当前脚本的运行时绝对路径定位。
source "$APK_PATCHER_DIR/toolchain.sh"

apk_patcher_fail() {
	printf '[!] %s\n' "$*" >&2
	return 1
}

apk_patcher_require() {
	command -v "$1" >/dev/null 2>&1 || apk_patcher_fail "缺少依赖命令：$1"
}

apk_patcher_entry_count() {
	local archive_path="${1:-}"
	local entry="${2:-}"
	python3 - "$archive_path" "$entry" <<'PY'
import sys
import zipfile

archive_path, entry = sys.argv[1:]
try:
    with zipfile.ZipFile(archive_path) as archive:
        names = [info.filename for info in archive.infolist()]
        if len(names) != len(set(names)):
            raise ValueError("ZIP contains duplicate member names")
        print(sum(name == entry for name in names))
except (OSError, EOFError, IndexError, MemoryError, OverflowError, RuntimeError,
        ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
    print(f"无法读取归档：{archive_path}：{error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

apk_patcher_compare_contract() {
	local before_path="${1:-}"
	local after_path="${2:-}"
	local excluded_entries_file="${3:-}"
	python3 - "$before_path" "$after_path" "$excluded_entries_file" <<'PY'
import sys
import zipfile
import zlib

before_path, after_path, excluded_path = sys.argv[1:]
excluded = set()
if excluded_path:
    try:
        with open(excluded_path, encoding="utf-8") as source:
            excluded = {line.rstrip("\n") for line in source if line.rstrip("\n")}
    except OSError as error:
        print(f"无法读取目标条目清单：{excluded_path}：{error}", file=sys.stderr)
        raise SystemExit(1)

def fail(message):
    print(f"归档契约校验失败：{message}", file=sys.stderr)
    raise SystemExit(1)

def open_archive(path):
    try:
        archive = zipfile.ZipFile(path)
        infos = archive.infolist()
    except (OSError, EOFError, IndexError, MemoryError, OverflowError, RuntimeError,
            ValueError, zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error) as error:
        fail(f"无法读取 {path}: {error}")
    names = [info.filename for info in infos]
    if len(names) != len(set(names)):
        archive.close()
        fail(f"{path} 包含重复 ZIP 条目")
    return archive, infos

def contents_equal(before, before_info, after, after_info):
    try:
        with before.open(before_info) as left, after.open(after_info) as right:
            while True:
                left_chunk = left.read(1024 * 1024)
                right_chunk = right.read(1024 * 1024)
                if left_chunk != right_chunk:
                    return False
                if not left_chunk:
                    return True
    except (EOFError, IndexError, KeyError, MemoryError, NotImplementedError, OSError,
            OverflowError, RuntimeError, ValueError, zipfile.BadZipFile,
            zipfile.LargeZipFile, zlib.error) as error:
        fail(f"条目 {before_info.filename!r} 内容读取失败：{error}")

before, before_infos = open_archive(before_path)
after, after_infos = open_archive(after_path)
try:
    if len(before_infos) != len(after_infos):
        fail(f"条目数量变化：{len(before_infos)} -> {len(after_infos)}")
    for index, (before_info, after_info) in enumerate(zip(before_infos, after_infos)):
        if before_info.filename != after_info.filename:
            fail(f"条目顺序或名称变化（位置 {index}: {before_info.filename!r} -> {after_info.filename!r}）")
        if before_info.filename in excluded:
            continue
        if before_info.compress_type != after_info.compress_type:
            fail(f"条目压缩方式变化：{before_info.filename!r}")
        if not contents_equal(before, before_info, after, after_info):
            fail(f"非目标条目内容变化：{before_info.filename!r}")
finally:
    before.close()
    after.close()
PY
}

apk_patcher_resolve_apktool() {
	toolchain_resolve_apktool || return 1
	APK_PATCHER_APKTOOL_COMMAND=("${PORT_TOOL_APKTOOL_COMMAND[@]}")
}

apk_patcher_resolve_zipalign() {
	toolchain_resolve_zipalign || return 1
	APK_PATCHER_ZIPALIGN_COMMAND="$PORT_TOOL_ZIPALIGN"
}

apk_patcher_open() {
	local session_dir="${1:-}"
	local archive_path="${2:-}"
	local archive_kind="${3:-apk}"
	local absolute_path

	[[ "$archive_kind" == apk || "$archive_kind" == jar ]] || apk_patcher_fail "不支持的归档类型：$archive_kind"
	[[ -n "$session_dir" && -d "$session_dir" ]] || apk_patcher_fail "会话目录不存在：$session_dir"
	[[ -f "$archive_path" && ! -L "$archive_path" ]] || apk_patcher_fail "归档不存在或是符号链接：$archive_path"
	absolute_path=$(cd -- "$(dirname -- "$archive_path")" && pwd -P)/$(basename -- "$archive_path")
	apk_patcher_require cp && apk_patcher_require find && apk_patcher_require mkdir && apk_patcher_require mktemp && apk_patcher_require mv && apk_patcher_require python3 && apk_patcher_require rm && apk_patcher_require unzip && apk_patcher_require zip || return 1
	apk_patcher_resolve_apktool || return 1
	if [[ -f "$session_dir/ready" ]]; then
		[[ "$(<"$session_dir/archive.path")" == "$absolute_path" ]] || apk_patcher_fail "会话归档目标不一致：$absolute_path"
		[[ "$(<"$session_dir/archive.kind")" == "$archive_kind" ]] || apk_patcher_fail "会话归档类型不一致：$archive_kind"
	else
		find "$session_dir" -mindepth 1 -depth -delete >/dev/null 2>&1 || return 1
		printf '%s\n' "$absolute_path" > "$session_dir/archive.path"
		printf '%s\n' "$archive_kind" > "$session_dir/archive.kind"
		cp -a -- "$absolute_path" "$session_dir/original.archive"
		"${APK_PATCHER_APKTOOL_COMMAND[@]}" d -f -r -o "$session_dir/decoded" "$absolute_path" || return 1
		touch "$session_dir/ready"
	fi
	SESSION_DIR="$session_dir"
	SESSION_ARCHIVE_PATH="$absolute_path"
	SESSION_ARCHIVE_KIND="$archive_kind"
	SESSION_DECODE_DIR="$session_dir/decoded"
	export SESSION_DIR SESSION_ARCHIVE_PATH SESSION_ARCHIVE_KIND SESSION_DECODE_DIR
}

apk_patcher_snapshot() {
	local snapshot_dir="$SESSION_DIR/snapshot"
	[[ -d "$SESSION_DECODE_DIR" ]] || apk_patcher_fail '共享解包目录不存在'
	if [[ -e "$snapshot_dir" ]]; then
		find "$snapshot_dir" -depth -delete >/dev/null 2>&1 || return 1
	fi
	cp -a -- "$SESSION_DECODE_DIR" "$snapshot_dir"
	if [[ -f "$SESSION_DIR/changed.entries" ]]; then
		cp -p -- "$SESSION_DIR/changed.entries" "$snapshot_dir.changed.entries"
	else
		rm -f -- "$snapshot_dir.changed.entries"
	fi
	SESSION_SNAPSHOT_DIR="$snapshot_dir"
}

apk_patcher_rollback() {
	local status="${1:-1}"
	[[ -d "${SESSION_SNAPSHOT_DIR:-}" ]] || return "$status"
	find "$SESSION_DECODE_DIR" -depth -delete >/dev/null 2>&1 || true
	mv -- "$SESSION_SNAPSHOT_DIR" "$SESSION_DECODE_DIR" || return "$status"
	if [[ -f "$SESSION_SNAPSHOT_DIR.changed.entries" ]]; then
		mv -- "$SESSION_SNAPSHOT_DIR.changed.entries" "$SESSION_DIR/changed.entries" || return "$status"
	else
		rm -f -- "$SESSION_DIR/changed.entries"
	fi
	return "$status"
}

apk_patcher_record_entry() {
	local entry="${1:-}"
	[[ "$entry" =~ ^[^/]+$ ]] || apk_patcher_fail "无效的归档条目：$entry"
	touch "$SESSION_DIR/changed.entries"
	if ! grep -Fqx -- "$entry" "$SESSION_DIR/changed.entries"; then
		printf '%s\n' "$entry" >> "$SESSION_DIR/changed.entries"
	fi
}

apk_patcher_finalize() {
	local rebuilt="$SESSION_DIR/rebuilt.archive"
	local patched="$SESSION_DIR/patched.archive"
	local aligned="$SESSION_DIR/aligned.archive"
	local entry entry_file entries replacement

	apk_patcher_require grep && apk_patcher_require cmp || return 1
	[[ -f "$SESSION_DIR/ready" ]] || apk_patcher_fail '共享 APK/JAR 会话尚未准备完成'
	[[ ! -f "$SESSION_DIR/finalized" ]] || return 0
	[[ -s "$SESSION_DIR/changed.entries" ]] || return 0
	"${APK_PATCHER_APKTOOL_COMMAND[@]}" b -o "$rebuilt" "$SESSION_DECODE_DIR" || return 1
	cp -a -- "$SESSION_DIR/original.archive" "$patched"
	entries=$(<"$SESSION_DIR/changed.entries")
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		entry_file="$SESSION_DIR/$entry"
		mkdir -p -- "$(dirname -- "$entry_file")"
		unzip -p "$rebuilt" "$entry" > "$entry_file" || return 1
		[[ -s "$entry_file" ]] || apk_patcher_fail "回编译结果中的条目为空：$entry"
		[[ "$(apk_patcher_entry_count "$patched" "$entry")" == 1 ]] ||
			apk_patcher_fail "目标条目数量异常：$entry"
		(cd -- "$(dirname -- "$entry_file")" && zip -q -0 "$patched" "$(basename -- "$entry_file")") || return 1
		cmp -s "$entry_file" <(unzip -p "$patched" "$entry") ||
			apk_patcher_fail "目标条目写回失败：$entry"
	done <<< "$entries"
	apk_patcher_compare_contract "$SESSION_DIR/original.archive" "$patched" \
		"$SESSION_DIR/changed.entries" || return 1
	if [[ "$SESSION_ARCHIVE_KIND" == apk ]]; then
		apk_patcher_resolve_zipalign || return 1
		"$APK_PATCHER_ZIPALIGN_COMMAND" -f -P 16 4 "$patched" "$aligned" || return 1
		mv -- "$aligned" "$patched"
		apk_patcher_compare_contract "$SESSION_DIR/original.archive" "$patched" \
			"$SESSION_DIR/changed.entries" || return 1
		[[ -r "$APK_PATCHER_SIGNING_TOOL" ]] || apk_patcher_fail '找不到 APK Signing Block 工具'
		python3 "$APK_PATCHER_SIGNING_TOOL" extract "$SESSION_DIR/original.archive" "$SESSION_DIR/signing.before" >/dev/null || return 1
		python3 "$APK_PATCHER_SIGNING_TOOL" insert "$patched" "$SESSION_DIR/signing.before" || return 1
	fi
	unzip -tq "$patched" >/dev/null || return 1
	cp --attributes-only --preserve=all -- "$SESSION_ARCHIVE_PATH" "$patched" || return 1
	replacement=$(mktemp "$(dirname -- "$SESSION_ARCHIVE_PATH")/.$(basename -- "$SESSION_ARCHIVE_PATH").patch.XXXXXX") || return 1
	rm -f -- "$replacement"
	if ! cp -a -- "$patched" "$replacement" || ! mv -fT -- "$replacement" "$SESSION_ARCHIVE_PATH"; then
		rm -f -- "$replacement"
		return 1
	fi
	touch "$SESSION_DIR/finalized"
}

if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == "finalize" ]]; then
	(( $# == 2 )) || apk_patcher_fail "用法：$0 finalize <session-dir>"
	apk_patcher_require cmp || exit 1
	apk_patcher_require find || exit 1
	apk_patcher_require grep || exit 1
	apk_patcher_require python3 || exit 1
	apk_patcher_require unzip || exit 1
	apk_patcher_require zip || exit 1
	apk_patcher_resolve_apktool || exit 1
	SESSION_DIR="$2"
	[[ -f "$SESSION_DIR/archive.path" ]] || { apk_patcher_fail "会话不存在：$SESSION_DIR"; exit 1; }
	SESSION_ARCHIVE_PATH=$(<"$SESSION_DIR/archive.path")
	SESSION_ARCHIVE_KIND=$(<"$SESSION_DIR/archive.kind")
	SESSION_DECODE_DIR="$SESSION_DIR/decoded"
	apk_patcher_finalize || exit 1
	exit $?
fi
