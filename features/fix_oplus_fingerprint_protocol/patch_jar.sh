#!/usr/bin/env bash
set -Eeuo pipefail

CLASS_PATH='com/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl.smali'

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

# Compare the current input and output archives directly.  No source-package
# hash, size, CRC, or other release-specific identity snapshot is persisted.
# Reading every non-target member still verifies the ZIP CRC for this run.

archive_entry_count() {
	local jar_file=$1
	local requested_entry=$2

	python3 - "$jar_file" "$requested_entry" <<'PY'
import sys
import zipfile


jar_path, requested_entry = sys.argv[1:]
try:
	with zipfile.ZipFile(jar_path) as archive:
		infos = archive.infolist()
		names = [info.filename for info in infos]
		if len(names) != len(set(names)):
			raise ValueError("ZIP contains duplicate member names")
		print(sum(info.filename == requested_entry for info in infos))
except (
	OSError,
	EOFError,
	IndexError,
	MemoryError,
	OverflowError,
	RuntimeError,
	ValueError,
	zipfile.BadZipFile,
	zipfile.LargeZipFile,
) as error:
	print(f"无法读取 JAR 归档：{error}", file=sys.stderr)
	raise SystemExit(1)
PY
}

compare_archive_contract() {
	local before_jar=$1
	local after_jar=$2
	local excluded_entry=${3:-}

	python3 - "$before_jar" "$after_jar" "$excluded_entry" <<'PY'
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
	except (
		OSError,
		EOFError,
		IndexError,
		MemoryError,
		OverflowError,
		RuntimeError,
		ValueError,
		zipfile.BadZipFile,
		zipfile.LargeZipFile,
		zlib.error,
	) as error:
		fail(f"无法读取 {path}: {error}")
	names = [info.filename for info in infos]
	if len(names) != len(set(names)):
		archive.close()
		fail(f"{path} 包含重复 ZIP 条目")
	return archive, infos


def contents_equal(before, before_info, after, after_info):
	try:
		with before.open(before_info) as before_entry, after.open(after_info) as after_entry:
			while True:
				before_chunk = before_entry.read(1024 * 1024)
				after_chunk = after_entry.read(1024 * 1024)
				if before_chunk != after_chunk:
					return False
				if not before_chunk:
					return True
	except (
		EOFError,
		IndexError,
		KeyError,
		MemoryError,
		NotImplementedError,
		OSError,
		OverflowError,
		RuntimeError,
		ValueError,
		zipfile.BadZipFile,
		zipfile.LargeZipFile,
		zlib.error,
	) as error:
		fail(f"条目 {before_info.filename!r} 内容读取失败：{error}")


before = after = None
try:
	before, before_infos = open_archive(before_path)
	after, after_infos = open_archive(after_path)
	if len(before_infos) != len(after_infos):
		fail(f"条目数量变化：{len(before_infos)} -> {len(after_infos)}")
	if excluded_entry:
		before_excluded = [info for info in before_infos if info.filename == excluded_entry]
		after_excluded = [info for info in after_infos if info.filename == excluded_entry]
		if len(before_excluded) != 1 or len(after_excluded) != 1:
			fail(f"目标条目 {excluded_entry!r} 数量异常")

	for index, (before_info, after_info) in enumerate(zip(before_infos, after_infos)):
		if before_info.filename != after_info.filename:
			fail(
				f"条目顺序或名称变化（位置 {index}: "
				f"{before_info.filename!r} -> {after_info.filename!r}）"
			)
		if (
			before_info.filename != excluded_entry
			and before_info.compress_type != after_info.compress_type
		):
			fail(
				f"条目压缩方式变化（{before_info.filename!r}: "
				f"{before_info.compress_type} -> {after_info.compress_type}）"
			)
		if before_info.filename == excluded_entry:
			continue
		if not contents_equal(before, before_info, after, after_info):
			fail(f"非目标条目内容变化：{before_info.filename!r}")
finally:
	if before is not None:
		before.close()
	if after is not None:
		after.close()
PY
}

prepare_dex_entry_metadata() {
	local original_jar=$1
	local dex_entry=$2
	local dex_file=$3

	python3 - "$original_jar" "$dex_entry" "$dex_file" <<'PY'
import datetime
import os
import stat
import sys
import zipfile


jar_path, dex_entry, dex_path = sys.argv[1:]
with zipfile.ZipFile(jar_path) as archive:
    info = archive.getinfo(dex_entry)

if info.compress_type != zipfile.ZIP_STORED:
    raise SystemExit(
        f"[!] 当前版本要求 {dex_entry} 使用 ZIP_STORED，实际为 {info.compress_type}"
    )

timestamp = datetime.datetime(*info.date_time).timestamp()
mode = stat.S_IMODE(info.external_attr >> 16) or 0o644
os.chmod(dex_path, mode)
os.utime(dex_path, (timestamp, timestamp))
PY
}

smali_patch_state() {
	local smali_file=$1
	local mode=$2

	python3 - "$smali_file" "$mode" <<'PY'
import os
import stat
import sys
import tempfile
from pathlib import Path


if len(sys.argv) != 3:
    raise SystemExit("[!] Oplus 指纹 Smali 补丁参数数量无效")

smali_path = Path(sys.argv[1])
mode = sys.argv[2]
if mode not in {"check", "patch"}:
    raise SystemExit(f"[!] 无效的 Smali 操作模式：{mode}")

try:
    original_text = smali_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"[!] 读取 FingerprintServiceStubImpl Smali 失败：{error}")

field_auth_client = (
    ".field private mOplusAuthenticationClient:"
    "Lcom/android/server/biometrics/sensors/AuthenticationClient;"
)
field_finger_down = ".field private volatile mOplusSyntheticFingerDown:Z"
method_is_down = (
    ".method private isOplusKeyguardFingerDown(IILcom/android/server/"
    "biometrics/sensors/BaseClientMonitor;)Z"
)
method_release = ".method private releaseOplusSyntheticFingerDown()V"
down_marker = 'const-string/jumbo v2, "OPLUS_FOD_SYNTHETIC_DOWN"'
up_marker = 'const-string/jumbo v2, "OPLUS_FOD_SYNTHETIC_UP"'
wake_sleep_marker = (
    'const-string/jumbo v1, "OPLUS_FOD_WAKE_GOING_TO_SLEEP"'
)
release_call = (
    "invoke-direct {p0}, Lcom/android/server/biometrics/sensors/fingerprint/"
    "FingerprintServiceStubImpl;->releaseOplusSyntheticFingerDown()V"
)
down_call = (
    "invoke-direct {p0, v3, v4, v0}, Lcom/android/server/biometrics/sensors/"
    "fingerprint/FingerprintServiceStubImpl;->isOplusKeyguardFingerDown"
    "(IILcom/android/server/biometrics/sensors/BaseClientMonitor;)Z"
)


def classify(text):
    counts = {
        "auth_client_field": text.count(field_auth_client),
        "finger_down_field": text.count(field_finger_down),
        "is_down_method": text.count(method_is_down),
        "release_method": text.count(method_release),
        "down_marker": text.count(down_marker),
        "up_marker": text.count(up_marker),
        "wake_sleep_marker": text.count(wake_sleep_marker),
        "release_calls": text.count(release_call),
        "down_calls": text.count(down_call),
    }
    expected = {
        "auth_client_field": 1,
        "finger_down_field": 1,
        "is_down_method": 1,
        "release_method": 1,
        "down_marker": 1,
        "up_marker": 1,
        "wake_sleep_marker": 1,
        "release_calls": 3,
        "down_calls": 1,
    }
    if counts == expected:
        return "patched", counts
    if any(counts.values()):
        return "partial", counts
    return "original", counts


state, counts = classify(original_text)
if state == "patched":
    print("patched 0")
    raise SystemExit(0)
if state == "partial":
    details = ", ".join(f"{name}={value}" for name, value in counts.items())
    raise SystemExit(f"[!] Oplus 指纹 Smali 处于部分补丁状态：{details}")
if mode == "check":
    print("original 0")
    raise SystemExit(0)

fields_anchor = """.field private mNeedSendFingerupToPMS:Z

.field public mOpId:J"""
fields_replacement = """.field private mNeedSendFingerupToPMS:Z

.field private mOplusAuthenticationClient:Lcom/android/server/biometrics/sensors/AuthenticationClient;

.field private volatile mOplusSyntheticFingerDown:Z

.field public mOpId:J"""

constructor_anchor = """    iput v0, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->WAIT_FINISH_GOING_TO_SLEEP_TIMEOUT:I

    return-void
.end method

.method private considerAsAuthFail(II)Z"""
helper_methods = """    iput v0, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->WAIT_FINISH_GOING_TO_SLEEP_TIMEOUT:I

    return-void
.end method

.method private isOplusKeyguardFingerDown(IILcom/android/server/biometrics/sensors/BaseClientMonitor;)Z
    .locals 2
    .param p1, \"acquiredInfo\"    # I
    .param p2, \"vendorCode\"    # I
    .param p3, \"client\"    # Lcom/android/server/biometrics/sensors/BaseClientMonitor;

    iget-boolean v0, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusSyntheticFingerDown:Z

    if-nez v0, :cond_false

    if-nez p1, :cond_false

    if-nez p2, :cond_false

    const-string/jumbo v0, \"persist.vendor.sys.fp.vendor\"

    const-string v1, \"\"

    invoke-static {v0, v1}, Landroid/os/SystemProperties;->get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    const-string/jumbo v1, \"oplus\"

    invoke-virtual {v1, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :cond_false

    invoke-virtual {p3}, Lcom/android/server/biometrics/sensors/BaseClientMonitor;->getContext()Landroid/content/Context;

    move-result-object v0

    invoke-virtual {p3}, Lcom/android/server/biometrics/sensors/BaseClientMonitor;->getOwnerString()Ljava/lang/String;

    move-result-object v1

    invoke-static {v0, v1}, Lcom/android/server/biometrics/Utils;->isKeyguard(Landroid/content/Context;Ljava/lang/String;)Z

    move-result v0

    return v0

    :cond_false
    const/4 v0, 0x0

    return v0
.end method

.method private releaseOplusSyntheticFingerDown()V
    .locals 3

    iget-boolean v0, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusSyntheticFingerDown:Z

    if-eqz v0, :cond_return

    iget-object v0, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusAuthenticationClient:Lcom/android/server/biometrics/sensors/AuthenticationClient;

    const/4 v1, 0x0

    if-eqz v0, :cond_clear

    const/16 v2, 0x65

    invoke-virtual {v0, v2, v1}, Lcom/android/server/biometrics/sensors/AuthenticationClient;->onAcquired(II)V

    invoke-virtual {v0}, Lcom/android/server/biometrics/sensors/AuthenticationClient;->getContext()Landroid/content/Context;

    move-result-object v0

    const-class v2, Landroid/os/PowerManager;

    invoke-virtual {v0, v2}, Landroid/content/Context;->getSystemService(Ljava/lang/Class;)Ljava/lang/Object;

    move-result-object v0

    check-cast v0, Landroid/os/PowerManager;

    const/16 v2, 0x64

    invoke-virtual {v0, v2, v1}, Landroid/os/PowerManager;->extCmdAndArgs(II)V

    :cond_clear
    iput-boolean v1, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mNeedSendFingerupToPMS:Z

    iput-boolean v1, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusSyntheticFingerDown:Z

    const/4 v0, 0x0

    iput-object v0, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusAuthenticationClient:Lcom/android/server/biometrics/sensors/AuthenticationClient;

    const-string v0, \"FingerprintServiceStubImpl\"

    const-string/jumbo v2, \"OPLUS_FOD_SYNTHETIC_UP\"

    invoke-static {v0, v2}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I

    :cond_return
    return-void
.end method

.method private considerAsAuthFail(II)Z"""

clear_anchor = """.method public clearSavedAuthenResult()V
    .locals 1

    .line 147"""
clear_replacement = """.method public clearSavedAuthenResult()V
    .locals 1

    invoke-direct {p0}, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->releaseOplusSyntheticFingerDown()V

    .line 147"""

down_anchor = """    .line 336
    .local p1, \"authenticationClient\":Lcom/android/server/biometrics/sensors/AuthenticationClient;
    invoke-virtual {p0, v3, v4}, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->isFingerDownAcquireCode(II)Z"""
down_replacement = """    .line 336
    .local p1, \"authenticationClient\":Lcom/android/server/biometrics/sensors/AuthenticationClient;
    invoke-direct {p0, v3, v4, v0}, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->isOplusKeyguardFingerDown(IILcom/android/server/biometrics/sensors/BaseClientMonitor;)Z

    move-result p4

    if-eqz p4, :oplus_check_standard_finger_down

    const/4 p5, 0x1

    invoke-virtual {p1, p2, p3}, Lcom/android/server/biometrics/sensors/AuthenticationClient;->onAcquired(II)V

    iput-object p1, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusAuthenticationClient:Lcom/android/server/biometrics/sensors/AuthenticationClient;

    iput-boolean p5, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusSyntheticFingerDown:Z

    invoke-virtual {v1, p2, p5}, Landroid/os/PowerManager;->extCmdAndArgs(II)V

    iput-boolean p5, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mNeedSendFingerupToPMS:Z

    const-string p4, \"FingerprintServiceStubImpl\"

    const-string/jumbo v2, \"OPLUS_FOD_SYNTHETIC_DOWN\"

    invoke-static {p4, v2}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I

    goto :goto_0

    :oplus_check_standard_finger_down
    invoke-virtual {p0, v3, v4}, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->isFingerDownAcquireCode(II)Z"""

auth_result_anchor = """.method public handleAuthResult(Landroid/content/Context;Z)V
    .locals 2
    .param p1, \"context\"    # Landroid/content/Context;
    .param p2, \"success\"    # Z

    .line 268"""
auth_result_replacement = """.method public handleAuthResult(Landroid/content/Context;Z)V
    .locals 2
    .param p1, \"context\"    # Landroid/content/Context;
    .param p2, \"success\"    # Z

    invoke-direct {p0}, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->releaseOplusSyntheticFingerDown()V

    .line 268"""

save_auth_anchor = """.method public saveAuthenticateConfig(JLjava/lang/String;)V
    .locals 0
    .param p1, \"opId\"    # J
    .param p3, \"opPackageName\"    # Ljava/lang/String;

    .line 114"""
save_auth_replacement = """.method public saveAuthenticateConfig(JLjava/lang/String;)V
    .locals 0
    .param p1, \"opId\"    # J
    .param p3, \"opPackageName\"    # Ljava/lang/String;

    invoke-direct {p0}, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->releaseOplusSyntheticFingerDown()V

    .line 114"""

wait_sleep_anchor = """.method public mayWaitFinishGoingToSleep()V
    .locals 6

    .line 83"""
wait_sleep_replacement = """.method public mayWaitFinishGoingToSleep()V
    .locals 6

    iget-boolean v0, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusSyntheticFingerDown:Z

    if-eqz v0, :oplus_wait_finish_going_to_sleep

    invoke-static {}, Lcom/android/server/policy/PhoneWindowManagerStub;->getInstance()Lcom/android/server/policy/PhoneWindowManagerStub;

    move-result-object v0

    invoke-interface {v0}, Lcom/android/server/policy/PhoneWindowManagerStub;->isGoingToSleep()Z

    move-result v0

    if-eqz v0, :oplus_wait_finish_going_to_sleep

    iget-object v0, p0, Lcom/android/server/biometrics/sensors/fingerprint/FingerprintServiceStubImpl;->mOplusAuthenticationClient:Lcom/android/server/biometrics/sensors/AuthenticationClient;

    if-eqz v0, :oplus_wait_finish_going_to_sleep

    invoke-virtual {v0}, Lcom/android/server/biometrics/sensors/AuthenticationClient;->getContext()Landroid/content/Context;

    move-result-object v0

    const-class v1, Landroid/os/PowerManager;

    invoke-virtual {v0, v1}, Landroid/content/Context;->getSystemService(Ljava/lang/Class;)Ljava/lang/Object;

    move-result-object v0

    check-cast v0, Landroid/os/PowerManager;

    invoke-static {}, Landroid/os/SystemClock;->uptimeMillis()J

    move-result-wide v1

    const/4 v3, 0x0

    const-string/jumbo v4, \"android.policy:OPLUS_FOD\"

    invoke-virtual {v0, v1, v2, v3, v4}, Landroid/os/PowerManager;->wakeUp(JILjava/lang/String;)V

    const-string v0, \"FingerprintServiceStubImpl\"

    const-string/jumbo v1, \"OPLUS_FOD_WAKE_GOING_TO_SLEEP\"

    invoke-static {v0, v1}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I

    :oplus_wait_finish_going_to_sleep
    .line 83"""


def replace_once(text, old, new, description):
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"[!] 无法唯一定位 {description}：期望 1 处，实际 {count} 处"
        )
    return text.replace(old, new, 1)


updated_text = original_text
updated_text = replace_once(
    updated_text, fields_anchor, fields_replacement, "Oplus 指纹状态字段"
)
updated_text = replace_once(
    updated_text, constructor_anchor, helper_methods, "Oplus 指纹辅助方法插入点"
)
updated_text = replace_once(
    updated_text, clear_anchor, clear_replacement, "错误与取消状态清理入口"
)
updated_text = replace_once(
    updated_text, down_anchor, down_replacement, "锁屏指纹 acquired 映射入口"
)
updated_text = replace_once(
    updated_text, auth_result_anchor, auth_result_replacement, "认证结果清理入口"
)
updated_text = replace_once(
    updated_text, save_auth_anchor, save_auth_replacement, "新认证会话清理入口"
)
updated_text = replace_once(
    updated_text,
    wait_sleep_anchor,
    wait_sleep_replacement,
    "Oplus 锁屏认证息屏唤醒入口",
)

updated_state, updated_counts = classify(updated_text)
if updated_state != "patched":
    details = ", ".join(
        f"{name}={value}" for name, value in updated_counts.items()
    )
    raise SystemExit(f"[!] 修改后的 Oplus 指纹 Smali 校验失败：{details}")

file_mode = stat.S_IMODE(smali_path.stat().st_mode)
temporary_name = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="",
        prefix=f".{smali_path.name}.",
        suffix=".tmp",
        dir=smali_path.parent,
        delete=False,
    ) as temporary_file:
        temporary_name = temporary_file.name
        temporary_file.write(updated_text)
        temporary_file.flush()
        os.fsync(temporary_file.fileno())
    os.chmod(temporary_name, file_mode)
    os.replace(temporary_name, smali_path)
except OSError as error:
    if temporary_name is not None:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
    raise SystemExit(f"[!] 写入 Oplus 指纹 Smali 失败：{error}")

print("patched 1")
PY
}

(( $# == 1 )) || fail "用法：$0 <miui-services.jar>"
JAR_PATH=$1

for command_name in basename cmp cp dirname find mkdir mktemp mv python3 rm unzip zip; do
	require_command "$command_name"
done
resolve_apktool

[[ -f "$JAR_PATH" ]] || fail "找不到 miui-services.jar：$JAR_PATH"
[[ ! -L "$JAR_PATH" ]] || fail "不支持修改符号链接 JAR：$JAR_PATH"
JAR_PATH=$(cd -- "$(dirname -- "$JAR_PATH")" && pwd)/$(basename -- "$JAR_PATH")
JAR_DIR=$(dirname -- "$JAR_PATH")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fix-oplus-fingerprint-protocol.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR="$WORK_DIR/decoded"
REBUILT_JAR="$WORK_DIR/rebuilt.jar"
DEX_DIR="$WORK_DIR/dex"
PATCHED_JAR="$WORK_DIR/miui-services.jar.patched"

log "读取原 JAR 归档"

log "反编译 miui-services.jar"
"${APKTOOL_COMMAND[@]}" d -j 1 -f -r -o "$DECODE_DIR" "$JAR_PATH"

mapfile -d '' -t CLASS_FILES < <(
	find "$DECODE_DIR" -type f -path "*/$CLASS_PATH" -print0
)
(( ${#CLASS_FILES[@]} == 1 )) ||
	fail "FingerprintServiceStubImpl 类数量异常：期望 1 个，实际 ${#CLASS_FILES[@]} 个"

SMALI_FILE=${CLASS_FILES[0]}
RELATIVE_SMALI_PATH=${SMALI_FILE#"$DECODE_DIR"/}
SMALI_ROOT=${RELATIVE_SMALI_PATH%%/*}
case "$SMALI_ROOT" in
	smali)
		DEX_ENTRY='classes.dex'
		;;
	smali_classes[0-9]*)
		DEX_NUMBER=${SMALI_ROOT#smali_classes}
		[[ "$DEX_NUMBER" =~ ^[0-9]+$ ]] || fail "无法识别 DEX 目录：$SMALI_ROOT"
		DEX_ENTRY="classes${DEX_NUMBER}.dex"
		;;
	*)
		fail "无法从目录识别目标 DEX：$SMALI_ROOT"
		;;
esac

DEX_ENTRY_COUNT=$(archive_entry_count "$JAR_PATH" "$DEX_ENTRY")
(( DEX_ENTRY_COUNT == 1 )) ||
	fail "原 JAR 中 $DEX_ENTRY 数量异常：期望 1 个，实际 $DEX_ENTRY_COUNT 个"

read -r PATCH_STATE _ < <(smali_patch_state "$SMALI_FILE" check)
case "$PATCH_STATE" in
	patched)
		unzip -tq "$JAR_PATH" >/dev/null || fail "已补丁 JAR 完整性校验失败"
		log "SKIP：Oplus 到 Xiaomi 指纹按下/抬起协议映射已存在"
		exit 0
		;;
	original)
		;;
	*)
		fail "无法识别目标 Smali 状态：$PATCH_STATE"
		;;
esac

log "修改 FingerprintServiceStubImpl（目标 DEX：$DEX_ENTRY）"
read -r PATCH_STATE CHANGED_COUNT < <(smali_patch_state "$SMALI_FILE" patch)
[[ "$PATCH_STATE" == patched && "$CHANGED_COUNT" == 1 ]] ||
	fail "修改后的 Smali 状态异常：state=$PATCH_STATE changed=$CHANGED_COUNT"

log "回编译 JAR 以生成新的 $DEX_ENTRY"
"${APKTOOL_COMMAND[@]}" b -j 1 "$DECODE_DIR" -o "$REBUILT_JAR"

mkdir -p -- "$DEX_DIR"
unzip -p "$REBUILT_JAR" "$DEX_ENTRY" > "$DEX_DIR/$DEX_ENTRY" ||
	fail "回编译结果中缺少 $DEX_ENTRY"
[[ -s "$DEX_DIR/$DEX_ENTRY" ]] || fail "生成的 $DEX_ENTRY 为空"
prepare_dex_entry_metadata "$JAR_PATH" "$DEX_ENTRY" "$DEX_DIR/$DEX_ENTRY"

log "仅将 $DEX_ENTRY 增量写入原 JAR 副本"
cp -a -- "$JAR_PATH" "$PATCHED_JAR"
(
	cd -- "$DEX_DIR"
	zip -q -X -0 "$PATCHED_JAR" "$DEX_ENTRY"
)

unzip -tq "$PATCHED_JAR" >/dev/null || fail "更新后的 JAR 完整性校验失败"
cmp -s "$DEX_DIR/$DEX_ENTRY" <(unzip -p "$PATCHED_JAR" "$DEX_ENTRY") ||
	fail "$DEX_ENTRY 未正确写入 JAR"

compare_archive_contract "$JAR_PATH" "$PATCHED_JAR" "$DEX_ENTRY" ||
	fail "更新后 JAR 的非目标归档契约发生变化"

cp --attributes-only --preserve=all -- "$JAR_PATH" "$PATCHED_JAR" ||
	fail "无法恢复原 miui-services.jar 文件属性"

REPLACEMENT_PATH=$(mktemp "$JAR_DIR/.miui-services.jar.patch.XXXXXX")
rm -f -- "$REPLACEMENT_PATH"
cp -a -- "$PATCHED_JAR" "$REPLACEMENT_PATH"
mv -fT -- "$REPLACEMENT_PATH" "$JAR_PATH"
REPLACEMENT_PATH=''

log "APPLY：Oplus 指纹协议补丁完成：$JAR_PATH"
log "已保留目标 DEX 之外的全部 JAR 条目；修改后的 DEX 与原预编译、profile 和完整性元数据不再匹配"
