#!/bin/bash
# 行为测试：安全文件替换接口的权限与幂等语义。
# replace_file_if_different 替换已存在的普通文件时必须保留目标模式（来源常是
# mktemp 的 0600，直接 cp -a 会把 0644/0755 降级）；新增文件没有可参照的目标
# 模式，沿用来源模式；同内容不得改写文件。
set -euo pipefail

tools_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tools.sh
source "$tools_dir/tools.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_mode() {
	local path="$1" expected="$2" label="$3" actual
	actual="$(stat -c '%a' "$path")"
	[[ "$actual" == "$expected" ]] || fail "$label：期望模式 $expected，实际 $actual"
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

make_pair() {
	# $1=来源模式 $2=目标模式（none 表示目标不存在）
	local case_dir="$tmp/$3"
	mkdir -p "$case_dir"
	printf 'new content\n' >"$case_dir/source"
	chmod "$1" "$case_dir/source"
	if [[ "$2" != "none" ]]; then
		printf 'old content\n' >"$case_dir/target"
		chmod "$2" "$case_dir/target"
	fi
	printf '%s\n' "$case_dir"
}

# 用例 1：目标 0644 + 来源 0600 → 保留 0644，内容已替换。
case_dir="$(make_pair 0600 0644 existing_0644)"
replace_file_if_different "$case_dir/source" "$case_dir/target"
expect_mode "$case_dir/target" 644 "替换 0644 目标后模式"
grep -q '^new content$' "$case_dir/target" || fail "替换 0644 目标后内容未更新"

# 用例 2：目标 0755 → 执行位不被降级。
case_dir="$(make_pair 0644 0755 existing_0755)"
replace_file_if_different "$case_dir/source" "$case_dir/target"
expect_mode "$case_dir/target" 755 "替换 0755 目标后模式"

# 用例 3：目标 0640 → 保留组可读位。
case_dir="$(make_pair 0600 0640 existing_0640)"
replace_file_if_different "$case_dir/source" "$case_dir/target"
expect_mode "$case_dir/target" 640 "替换 0640 目标后模式"

# 用例 4：目标不存在 → 沿用来源模式，预置可执行文件的执行位不能丢。
case_dir="$(make_pair 0755 none new_file)"
replace_file_if_different "$case_dir/source" "$case_dir/target"
expect_mode "$case_dir/target" 755 "新增文件模式"

# 用例 5：同内容不写（幂等，mtime 与模式都不动）。
case_dir="$tmp/identical"
mkdir -p "$case_dir"
printf 'same\n' >"$case_dir/source"
chmod 0600 "$case_dir/source"
printf 'same\n' >"$case_dir/target"
chmod 0640 "$case_dir/target"
mtime_before="$(stat -c '%Y' "$case_dir/target")"
sleep 1
replace_file_if_different "$case_dir/source" "$case_dir/target"
[[ "$(stat -c '%Y' "$case_dir/target")" == "$mtime_before" ]] || fail "同内容仍被改写"
expect_mode "$case_dir/target" 640 "同内容替换后模式"

# 用例 6：目标是符号链接时保持原语义——替换链接本身，不按引用对象改模式。
case_dir="$tmp/symlink_target"
mkdir -p "$case_dir"
printf 'new content\n' >"$case_dir/source"
chmod 0600 "$case_dir/source"
printf 'referent\n' >"$case_dir/referent"
ln -s "$case_dir/referent" "$case_dir/target"
replace_file_if_different "$case_dir/source" "$case_dir/target"
if [[ -L "$case_dir/target" ]]; then
	fail "符号链接目标未被替换"
fi
grep -q '^new content$' "$case_dir/target" || fail "符号链接目标内容不符"
grep -q '^referent$' "$case_dir/referent" || fail "符号链接引用对象被误改"

# 用例 7：不安全输入必须失败，且不留下临时文件。
mkdir -p "$tmp/a_directory"
if replace_file_if_different "$tmp/identical/source" "$tmp/a_directory" 2>/dev/null; then
	fail "目标是目录时应失败"
fi
if replace_file_if_different "$tmp/does-not-exist" "$tmp/identical/target" 2>/dev/null; then
	fail "来源不存在时应失败"
fi
leftover="$(find "$tmp" -name '.*.tmp.*' | wc -l | tr -d '[:space:]')"
[[ "$leftover" == "0" ]] || fail "遗留 $leftover 个临时文件"

printf '安全文件替换行为测试通过\n'
