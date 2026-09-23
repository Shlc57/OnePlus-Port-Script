#!/system/bin/sh
# 原系统（realme ColorOS）硬件事实采集脚本 —— MT 管理器可直接执行，不依赖 adb / 电脑，全程只读。
#
# 用途：为 OnePlus-Port-Script 的真我 Neo8 移植采集只能从真机读取的物理事实，产出
#       一个压缩包（zip，无 zip 时退化为 tar.gz）供测试者直接回传给维护者。
#       它不验证任何补丁效果：补丁验证与 Display ID 必须在移植后的澎湃 DSU 上做，
#       本脚本在 DSU 上重复运行只是用于交叉对照，不能替代 DSU 验证。
#
# MT 管理器执行步骤：
#   1) 把 device_probe.sh 放到 /sdcard/Download（Download 里方便直接回传）。
#   2) 建议在 MT 管理器「设置 → Root 权限」里放行 Root；非 root 时 getevent/sysfs/多数 dumpsys 会是空。
#   3) 长按本文件 → 「打开方式 → Shell / 脚本执行」（或在 MT 内置控制台里执行下面的命令）。
#   4) 结束后按提示把 device_probe_stock.zip（或 .tar.gz）发给维护者。要补充人工结论时，
#      先编辑 device_probe_stock/MANUAL.txt，再带 --pack 重跑一次即可重新打包。
#
# 等价命令（MT 内置控制台或任意 shell）：
#   sh /sdcard/Download/device_probe.sh              # 默认标签 stock
#   sh /sdcard/Download/device_probe.sh dsu          # 指定标签，便于区分环境
#   sh /sdcard/Download/device_probe.sh --pack       # 只重新打包（编辑完 MANUAL.txt 后）
#   sh /sdcard/Download/device_probe.sh --no-pause   # 跳过 NFC 贴卡 / USB 模式切换两项交互采样
#   sh /sdcard/Download/device_probe.sh --out /sdcard/Download stock
#
# 产出：captures/ 下的原始采集、SUMMARY.txt（脚本自动提炼的关键结论）、MANUAL.txt（只剩
# 机器抓不到、必须人眼看/手的项）。
#
# 采集边界：只执行读取类命令（getprop / dumpsys / cat / ls / getevent -p / logcat -d），
# 不写系统分区、不 mount、不重启、不改设置、不安装任何东西；唯一写入物是输出目录与其压缩包。
#
# 注意：请不要在电脑上用记事本等工具编辑本脚本——Windows 存成 CRLF 后，POSIX sh（toybox/dash）
# 会直接在 `set -u` 一行报 "Illegal option" 而无法运行（脚本自身无法可靠自修复）。测试者只需要
# 编辑采集结果里的 MANUAL.txt，换行格式对其无影响。若确实改坏了，重新取一份 LF 格式的本文件即可。

set -u

# ---- MT 管理器运行环境适配 ----
# 少数 shell 的 PATH 不含 /system/bin，只在探测不到工具时补齐，不覆盖原有 PATH。
if ! command -v -- getprop >/dev/null 2>&1; then
	PATH="${PATH:-}:/system/bin:/system/xbin:/vendor/bin:/sbin"
	export PATH
fi

# 非 root 时先尝试 su 提权（仍然只跑只读命令，可能弹出 Root 授权框）；
# --no-root 与 PROBE_SU_TRIES 双保险，避免提权失败时无限递归；仅 Android 环境尝试。
case " $* " in
*" --no-root "*) : ;;
*)
	if [ -e /system/bin/sh ] && [ -z "${PROBE_NO_SU:-}" ] &&
		[ "$(id -u 2>/dev/null)" != "0" ] && command -v su >/dev/null 2>&1 &&
		[ "${PROBE_SU_TRIES:-0}" -lt 1 ]; then
		printf '当前非 root，尝试 su 提权后重新采集（只读命令，请注意 Root 授权弹窗）...\n'
		export PROBE_SU_TRIES=1
		if su -c 'sh "$@" --no-root' su "$0" "$@"; then
			exit 0
		fi
		printf 'su 提权未成功，改以当前权限继续采集（部分项会标注缺失，不影响打包）。\n' >&2
	fi
	;;
esac

PROBE_VERSION='2026.09.23-4'

# ---------------------------------------------------------------- 参数解析
TAG='stock'
PACK_ONLY=0
PROBE_OUT=''
NO_PAUSE=0
PAUSE_SECS=15
while [ "$#" -gt 0 ]; do
	case "$1" in
	--tag | -t)
		shift
		[ "$#" -gt 0 ] || { echo '缺少 --tag 参数值' >&2; exit 2; }
		TAG="$1"
		;;
	--out | -o)
		shift
		[ "$#" -gt 0 ] || { echo '缺少 --out 参数值' >&2; exit 2; }
		PROBE_OUT="$1"
		;;
	--pack)
		PACK_ONLY=1
		;;
	--no-root)
		# 由 su 提权重启时注入，阻断再次提权的递归标记。
		;;
	--no-pause)
		NO_PAUSE=1
		;;
	--pause)
		shift
		[ "$#" -gt 0 ] || { echo '缺少 --pause 秒数' >&2; exit 2; }
		PAUSE_SECS="$1"
		;;
	-h | --help)
		echo '用法: sh device_probe.sh [--tag stock|dsu|...] [--out 目录] [--pack] [--no-pause] [--pause 秒]'
		echo '  --pack       只把上次采集结果与已编辑的 MANUAL.txt 打包'
		echo '  --no-pause   跳过需要手配合的采样等待（NFC 贴卡、USB 用途切换）'
		exit 0
		;;
	-*)
		echo "未知选项: $1" >&2
		exit 2
		;;
	*)
		TAG="$1"
		;;
	esac
	shift
done

# 标签只允许安全字符，并去掉开头的 - . 等，避免拼成选项或隐藏路径。
TAG_CLEAN=$(printf '%s' "$TAG" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//')
[ -n "$TAG_CLEAN" ] || TAG_CLEAN='stock'

# 候选输出位置：优先上次采集目录，再退到测试者最容易回传的 Download 目录。
# HOME 在部分 root shell 里未设置（set -u 会直接中断），因此先条件拼接。
PROBE_CANDIDATES="/sdcard/Download /storage/emulated/0/Download /data/local/tmp /tmp"
probe_home="${HOME:-}"
HOME_CANDIDATES=''
[ -n "$probe_home" ] && HOME_CANDIDATES="$probe_home/Downloads $probe_home"

# 采集目录定位：MARKER_NAME 区分本脚本生成的目录与测试者同名目录；POINTER_NAME 记下
# 上次采集目录的绝对路径，让测试者第二次只带 --pack（忘了 --out）也能打到同一个包。
MARKER_NAME='.probe_dir'
POINTER_NAME=".device_probe_${TAG_CLEAN}.last"
LAST_DIR=''
for probe_base in "${PROBE_OUT:-}" "$PWD" $HOME_CANDIDATES $PROBE_CANDIDATES; do
	[ -n "$probe_base" ] || continue
	[ -f "$probe_base/$POINTER_NAME" ] || continue
	guess=$(head -n 1 -- "$probe_base/$POINTER_NAME" 2>/dev/null)
	[ -n "$guess" ] && [ -f "$guess/$MARKER_NAME" ] || continue
	LAST_DIR="$guess"
	break
done
if [ -z "$LAST_DIR" ]; then
	for probe_base in "${PROBE_OUT:-}" "$PWD" $HOME_CANDIDATES $PROBE_CANDIDATES; do
		[ -n "$probe_base" ] || continue
		guess="$probe_base/device_probe_${TAG_CLEAN}"
		[ -f "$guess/$MARKER_NAME" ] || continue
		LAST_DIR="$guess"
		break
	done
fi

if [ "$PACK_ONLY" -eq 1 ]; then
	if [ -z "$LAST_DIR" ]; then
		echo 'FAIL: 没找到可打包的采集目录。请先不带 --pack 运行一次采集，' >&2
		echo '      或用与首次一致的 --out 目录重试：sh device_probe.sh --out /sdcard/Download --pack' >&2
		exit 1
	fi
	PROBE_DIR="$LAST_DIR"
else
	# 输出目录：先试上次采集目录或 --out，再依次探测可写位置。
	ensure_dir() {
		[ -n "$PROBE_DIR" ] && return 0
		[ -n "$1" ] || return 0
		mkdir -p -- "$1" 2>/dev/null || return 0
		touch -- "$1/.probe_write_test" 2>/dev/null || return 0
		rm -f -- "$1/.probe_write_test" 2>/dev/null
		PROBE_DIR="$1"
		return 0
	}
	PROBE_DIR=''
	ensure_dir "${LAST_DIR:-${PROBE_OUT:-/data/local/tmp}/device_probe_${TAG_CLEAN}}"
	for cand in "$PWD" $HOME_CANDIDATES $PROBE_CANDIDATES; do
		[ -n "$PROBE_DIR" ] && break
		ensure_dir "$cand/device_probe_${TAG_CLEAN}"
	done
	[ -n "$PROBE_DIR" ] || { echo 'FAIL: 找不到可写输出目录，请用 --out 指定。' >&2; exit 1; }
	printf '%s\n' "$(basename -- "$PROBE_DIR")" >"$PROBE_DIR/$MARKER_NAME" 2>/dev/null
	# 在采集目录的上级与当前目录留一份绝对路径指针（写不了就跳过，不影响采集）。
	for pointer_base in "$(dirname -- "$PROBE_DIR")" "$PWD" /sdcard/Download; do
		[ -d "$pointer_base" ] && [ -w "$pointer_base" ] || continue
		printf '%s\n' "$PROBE_DIR" >"$pointer_base/$POINTER_NAME" 2>/dev/null
	done

	CAP="$PROBE_DIR/captures"
	mkdir -p -- "$CAP"
fi

# ---------------------------------------------------------------- 采集原语
has() {
	command -v -- "$1" >/dev/null 2>&1
}

# 交互采样前的等待：--no-pause / --pause 0 时返回 1，调用方降级为单次采样。
pause_for() {
	[ "$NO_PAUSE" -eq 1 ] && return 1
	[ "$PAUSE_SECS" -gt 0 ] || return 1
	printf '%s\n' "$1"
	has sleep || return 1
	sleep "$PAUSE_SECS"
	return 0
}

# 从已采集的 getprop 全文里取一个属性值（SUMMARY 用）。
prop_val() {
	grep -m1 -E "^\\[$1\\]:" "$CAP/01_getprop.txt" 2>/dev/null | sed 's/^[^:]*: //' | tr -d '[]'
}

# 从 17_settings.txt 里取一个 settings 值（SUMMARY 用）。
setting_val() {
	grep -m1 -E "^$1=" "$CAP/17_settings.txt" 2>/dev/null | sed "s/^$1=//"
}

# 执行命令并把 stdout+stderr 记进采集文件；命令缺失时明确标注，不静默跳过。
cap() {
	out="$CAP/$1"
	shift
	printf '\n===== $ %s =====\n' "$*" >>"$out"
	if has "$1"; then
		"$@" >>"$out" 2>&1
		rc=$?
		[ "$rc" -eq 0 ] || printf '===== [exit=%s] =====\n' "$rc" >>"$out"
	else
		printf '===== [MISSING] %s 不存在 =====\n' "$1" >>"$out"
	fi
}

# 同上，但只保留前 N 行（第 2 个参数是行数）。
capn() {
	out="$CAP/$1"
	n="$2"
	shift 2
	printf '\n===== $ %s (前 %s 行) =====\n' "$*" "$n" >>"$out"
	if has "$1"; then
		"$@" 2>>"$out" | head -n "$n" >>"$out" 2>&1
	else
		printf '===== [MISSING] %s 不存在 =====\n' "$1" >>"$out"
	fi
}

# 在已采集文件里按扩展正则筛行（不回落 grep -i，保持只读语义明确）。
capfilter() {
	pattern="$1"
	src="$CAP/$2"
	dst="$CAP/$3"
	printf '\n===== 过滤 /%s/ 自 %s =====\n' "$pattern" "$2" >>"$dst"
	if has grep && [ -f "$src" ]; then
		grep -E -i -- "$pattern" "$src" >>"$dst" 2>&1
		rc=$?
		[ "$rc" -eq 0 ] || printf '(无匹配行)\n' >>"$dst"
	else
		printf '===== [SKIP] 缺少 grep 或源文件 =====\n' >>"$dst"
	fi
}

# 记录路径是否存在；目录额外列出条目。
# SC2012: 下面 ls 的路径都是本脚本里写死的设备目录，不处理任意用户输入文件名。
# shellcheck disable=SC2012
probe_path() {
	out="$CAP/$1"
	shift
	for p in "$@"; do
		if [ -e "$p" ]; then
			printf 'FOUND    %s\n' "$p" >>"$out"
			[ -d "$p" ] && ls -1 -- "$p" 2>>"$out" | sed 's/^/    | /' >>"$out"
		else
			printf 'ABSENT   %s\n' "$p" >>"$out"
		fi
	done
}

# 受控 glob 列目录（只接受含 * 的模式；未展开的 * 保持原样，视为无匹配）。
lsglob() {
	out="$CAP/$1"
	shift
	for p in "$@"; do
		printf '\n----- %s -----\n' "$p" >>"$out"
		case "$p" in
		*\**) : ;;
		*)
			printf '(不是通配路径，跳过)\n' >>"$out"
			continue
			;;
		esac
		found=0
		for m in $p; do
			[ -e "$m" ] || continue
			found=1
			ls -ld -- "$m" >>"$out" 2>&1
		done
		[ "$found" -eq 1 ] || printf '(无匹配)\n' >>"$out"
	done
}

# ---------------------------------------------------------------- 采集流程
# SC2016: 采集块里大量 sh -c '<字面脚本>' 是故意不展开的（要在设备 toybox sh 里才展开）。
# shellcheck disable=SC2016
if [ "$PACK_ONLY" -eq 0 ]; then
	# 重复执行要得到相同结果，不清空会在同一文件里不断追加；MANUAL.txt 在上级目录，不受影响。
	for stale in "$CAP"/*.txt; do
		[ -f "$stale" ] && rm -f -- "$stale"
	done
	# ---- 00 元信息
	META='00_meta.txt'
	{
		printf '# Neo8 真机采集 %s\n' "$PROBE_VERSION"
		printf '# tag=%s out=%s\n' "$TAG_CLEAN" "$PROBE_DIR"
		printf '\n===== 身份与只读前提 =====\n'
	} >"$CAP/$META"
	if has id; then id >>"$CAP/$META" 2>&1; fi
	if has uname; then uname -a >>"$CAP/$META" 2>&1; fi
	printf '\n===== /proc/version =====\n' >>"$CAP/$META"
	[ -r /proc/version ] && head -c 800 /proc/version >>"$CAP/$META" 2>&1
	{
		printf '\n===== 工具可用性 =====\n'
		for t in toybox getevent dumpsys settings getprop screencap su zip tar timeout sed awk find grep head; do
			if has "$t"; then printf 'YES  %s\n' "$t"; else printf 'NO   %s\n' "$t"; fi
		done
	} >>"$CAP/$META"
	if [ "$(id -u 2>/dev/null)" != "0" ]; then
		printf '\n警告: 当前不是 root（uid=%s）。getevent / sysfs / 部分 dumpsys 预计为空，\n请在 MT 管理器里放行 Root 后重跑一次。\n' "$(id -u 2>/dev/null)" >>"$CAP/$META"
	fi

	# ---- 01 全量属性 + 身份摘要
	cap 01_getprop.txt getprop
	capfilter 'ro\.(product|build|vendor\.oplus|oplus)\.' 01_getprop.txt 01b_identity.txt
	capfilter 'haptic|vibrator|motor' 01_getprop.txt 09b_haptic_props.txt
	capfilter 'nfc' 01_getprop.txt 07b_nfc_props.txt
	capfilter 'usb' 01_getprop.txt 08b_usb_props.txt
	capfilter 'display|lcd|brightness|fps|refresh|hdr|ltpo|lcdc' 01_getprop.txt 03b_display_props.txt
	capfilter 'fp|fingerprint|ultrasonic' 01_getprop.txt 06b_fp_props.txt

	# ---- 01b 关键 settings（双击亮屏/指纹位置/刷新率/亮度/人脸全部在这）
	# 只存过滤后的行：ColorOS 的 settings 全量里有几百 KB 的白名单，不能整存。
	: >"$CAP/17_settings.txt"
	cap 17_settings.txt sh -c '
		for uri in secure system global; do
			echo "===== settings list $uri ====="
			settings list $uri 2>&1 | grep -i -E "fingerprint|face_|facelock|tap|wake|doze|brightness|refresh|frame_rate|nfc|haptic|vibrat|dc_|pwm|display|animation_scale"
		done
	'

	# ---- 02 内核 / KMI / 模块
	cap 02_kernel.txt sh -c 'uname -r; cat /proc/version'
	probe_path 02_kernel.txt /vendor/lib/modules /odm/lib/modules /sys/module
	lsglob 02_kernel.txt '/vendor/lib/modules/*millet*' '/vendor/lib/modules/*.ko' '/sys/module/*millet*'
	capn 02_kernel.txt 200 cat /proc/modules

	# ---- 03 显示：Display ID 参考、分辨率、刷新率档位
	cap 03_display.txt dumpsys display
	lsglob 03_display.txt '/sys/class/graphics/fb0' '/sys/class/drm/*' '/sys/class/drm/card0-DSI-1/modes'
	if has cat && [ -r /sys/class/drm/card0-DSI-1/modes ]; then
		cat -- /sys/class/drm/card0-DSI-1/modes >>"$CAP/03_display.txt" 2>&1
	fi
	probe_path 03_display.txt /vendor/etc/displayconfig /odm/etc/displayconfig
	for d in /vendor/etc/displayconfig /odm/etc/displayconfig; do
		if [ -d "$d" ]; then
			printf '\n===== display_id 出现在哪些候选文件 =====\n' >>"$CAP/03_display.txt"
			if has grep; then
				grep -R -h -o -E 'display_id_[0-9]+' "$d" >>"$CAP/03_display.txt" 2>&1 | sort -u >>"$CAP/03_display.txt" 2>&1
			fi
		fi
	done
	cap 03_display.txt wm size
	cap 03_display.txt wm density
	capn 03_display.txt 300 dumpsys SurfaceFlinger
	# 刷新率档位与面板关键值：实测可从 dumpsys display / settings 直接得到，不需人工照抄。
	capfilter 'peak_refresh_rate|customize_screen_refresh_rate|multi_device_reduce_refresh_rate|min_refresh_rate|user_selected|frame_rate' 17_settings.txt 03c_refresh_settings.txt
	{
		printf '# supportedModes 里出现过的 fps（去重升序）与分辨率组合\n'
		grep -o -E 'fps=[0-9.]+' "$CAP/03_display.txt" 2>/dev/null | sed 's/fps=//' | sort -g -u | tr '\n' ' '
		printf '\n'
		grep -o -E 'width=[0-9]+, height=[0-9]+' "$CAP/03_display.txt" 2>/dev/null | sort -u
	} >"$CAP/03e_fps_modes.txt" 2>&1
	capfilter 'mPWMBacklightSupport|mSinglePulseDimmingSupport|mSupportEdr|refreshRateOverlay|thermalRefreshRateThrottling|backlightType' 03_display.txt 03d_panel_flags.txt

	# ---- 04 亮度与自动亮度表
	cap 04_brightness.txt sh -c '
		for k in screen_brightness screen_brightness_mode automatic_brightness video_enable_luminance; do
			printf "settings secure %s = " "$k"; settings get secure "$k" 2>&1
		done
		for k in minimum_brightness; do
			printf "settings system %s = " "$k"; settings get system "$k" 2>&1
		done
	'
	probe_path 04_brightness.txt /sys/class/backlight /sys/class/lcd /sys/class/drm/card0-DSI-1 /sys/class/msm_drm
	lsglob 04_brightness.txt '/sys/class/backlight/*' '/sys/class/lcd/*'
	capn 04_brightness.txt 60 sh -c 'for f in /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness /sys/class/backlight/*/bl_power; do [ -e "$f" ] && { printf "%s = " "$f"; cat "$f" 2>&1; }; done'
	cap 04_brightness.txt sh -c 'ls -1 /vendor/etc 2>/dev/null | grep -i -E "brightness|lux" ; echo "--- odm"; ls -1 /odm/etc 2>/dev/null | grep -i -E "brightness|lux"'
	# 高频 PWM / 调光方式：原机靠 oplus 传感器与 vendor prop 就能定，不靠人眼看眼睛累不累。
	capfilter 'high_pwm|pwm|dimming|flicker|dcss|cabc|dark_light|oled' 01_getprop.txt 04c_pwm_props.txt
	capfilter 'pwm|dimming|flicker|dcss' 17_settings.txt 04d_pwm_settings.txt

	# ---- 05 触控：HBP 节点、scan code、双击亮屏参数
	cap 05_touch.txt getevent -p
	capn 05_touch.txt 200 cat /proc/bus/input/devices
	probe_path 05_touch.txt /dev/input /sys/class/input /sys/devices/virtual/input
	lsglob 05_touch.txt '/dev/input/*' '/sys/class/input/*'
	cap 05_touch.txt sh -c 'ls -l /dev/input 2>&1'
	# Oplus HBP：4100/4101 配置节点 + sec_touch 目录 + 双击亮屏开关节点。
	probe_path 05_touch.txt /sys/class/input/input1 /sys/devices/virtual/input/input1
	capn 05_touch.txt 120 sh -c '
		for d in /sys/class/input/* /sys/devices/virtual/input/*; do
			[ -d "$d" ] || continue
			for n in sec_touch gesture 4100 4101 tap2wake double_tap; do
				[ -e "$d/$n" ] && { printf "PATH %s/%s\n" "$d" "$n"; ls -1 "$d/$n" 2>&1 | sed "s/^/    | /"; for f in "$d/$n"/*; do [ -f "$f" ] && [ -r "$f" ] && { printf "  %s = " "$f"; head -c 200 "$f"; echo; }; done; }
			done
			[ -e "$d/name" ] && { printf "NAME %s = " "$d"; head -c 120 "$d/name"; echo; }
			[ -e "$d/id" ] && { printf "ID   %s = " "$d"; od -An -tx1 "$d/id" 2>&1 | head -n 3; }
		done
	'
	# 整个 input 目录逐层列录：不靠猜节点名（Oplus 新版触控栈可能已不用 sec_touch/4100）。
	capn 05_touch.txt 240 sh -c '
		for d in /sys/class/input/input* /sys/devices/virtual/input/input*; do
			[ -d "$d" ] || continue
			resolved=$(readlink -f "$d" 2>/dev/null)
			echo "===== $d -> $resolved ====="
			if command -v timeout >/dev/null 2>&1; then
				timeout 10 find "$d" -maxdepth 2 2>/dev/null | head -n 60
			else
				find "$d" -maxdepth 2 2>/dev/null | head -n 60
			fi
		done
		for base in /sys/devices/virtual/input /sys/class/input; do
			[ -d "$base" ] || continue
			echo "===== $base 下任意深度的手势/双击相关节点 ====="
			if command -v timeout >/dev/null 2>&1; then
				timeout 30 find "$base" -maxdepth 8 \( -iname "*sec_touch*" -o -iname "41[0-9][0-9]" -o -iname "*tap*" -o -iname "*gesture*" -o -iname "*tp_*" \) 2>/dev/null | head -n 80
			else
				find "$base" -maxdepth 8 -iname "*sec_touch*" 2>/dev/null | head -n 80
			fi
		done
		true
	'
	capn 05_touch.txt 80 sh -c '
		if command -v timeout >/dev/null 2>&1; then
			timeout 40 find /sys -maxdepth 8 \( -name "sec_touch" -o -name "41[0-9][0-9]" -o -name "*tap2wake*" \) 2>/dev/null | head -n 60
		else
			find /sys/class/input /sys/devices/virtual/input -maxdepth 4 \( -name "sec_touch" -o -name "41[0-9][0-9]" -o -name "*tap2wake*" \) 2>/dev/null | head -n 60
		fi
	'
	capn 05_touch.txt 40 sh -c '
		for f in /proc/touchpanel/* /proc/thp/* /proc/bootloader/*touch* ; do
			[ -f "$f" ] && [ -r "$f" ] && { printf "== %s\n" "$f"; head -c 400 "$f"; echo; }
		done
		true
	'

	# ---- 06 指纹：类型已由底包确认为超声波，这里校准传感器位置与协议
	cap 06_fingerprint.txt dumpsys fingerprint
	lsglob 06_fingerprint.txt '/dev/*fp*' '/dev/*uff*' '/vendor/lib64/*fingerprint*' '/vendor/bin/hw/*fingerprint*'
	cap 06_fingerprint.txt sh -c 'getprop | grep -i -E "fp|fingerprint|ultrasonic" 2>&1'
	capn 06_fingerprint.txt 40 sh -c '
		for f in /sys/class/fingerprint/*/* /sys/devices/virtual/misc/*/*; do
			[ -f "$f" ] && [ -r "$f" ] && { printf "== %s = " "$f"; head -c 120 "$f"; echo; }
		done
		true
	'
	# 传感器位置与图标参数：实测可由原厂属性与 settings 直接读出（位置不靠尺子量）。
	capfilter 'fingerprint|fp_' 17_settings.txt 06c_fp_settings.txt
	cap 06_fingerprint.txt sh -c 'getprop | grep -E "persist\.vendor\.fingerprint|ro\.vendor\.fp\.|sensor_location|sensorlocation"'

	# ---- 07 NFC：THN31/TMS 阵营的运行时确认（静态三判据已在底包做过）
	cap 07_nfc.txt dumpsys nfc
	cap 07_nfc.txt sh -c 'ls -l /dev 2>/dev/null | grep -i nfc; echo "--- ps"; ps -A 2>/dev/null | grep -i nfc'
	lsglob 07_nfc.txt '/dev/*nfc*' '/vendor/etc/vintf/manifest/*nfc*' '/odm/etc/vintf/manifest/*nfc*' '/odm/etc/nfc/*' '/vendor/etc/nfc/*'
	# 三判据之一：init 实际启动的 HAL 服务名与设备节点。
	capn 07_nfc.txt 60 sh -c 'grep -h -R -E "tms_nfc|st21nfc|nq-nci|nfc_hal_service" /vendor/etc/init /odm/etc/init 2>/dev/null | head -n 40'
	# dumpsys nfc 开头就是 mState/pollTech，比翻 100KB 有用得多。
	capn 07_nfc.txt 45 sh -c '
		echo "===== dumpsys nfc 头部状态 ====="
		dumpsys nfc 2>&1 | sed -n "1,40p"
	'
	# 贴卡实照：采基线→提示贴卡→只取新增 logcat 行，能自动判“有没有反应”。
	{
		printf '\n===== NFC 贴卡采样 =====\n'
		if has logcat; then
			# 采样前先确认 NFC 开关：off/turning 状态下贴卡不会产生任何链路日志，先记下来避免无效回传。
			nfc_state=$(dumpsys nfc 2>/dev/null | grep -m1 -aE '^mState=' | tr -d '\r')
			printf 'NFC_TAP_PRECHECK %s\n' "${nfc_state:-mState 未读到}"
			before=$(logcat -d 2>/dev/null | wc -l | tr -d ' ')
			if pause_for "请把一张公交卡/门禁卡贴在背面 NFC 区（$PAUSE_SECS 秒，没卡可忽略）..."; then
				if has tail; then
					logcat -d 2>/dev/null | tail -n "+$((before + 1))" >"$CAP/.nfc_new_log.tmp"
				else
					logcat -d >"$CAP/.nfc_new_log.tmp" 2>/dev/null
				fi
				new=$(wc -l <"$CAP/.nfc_new_log.tmp" 2>/dev/null | tr -d ' ')
				# 只留真正的 NFC 链路日志。短词（AID/TAG/TECH/ROUTE）实测会误命中
				# servicetrackeraidl、NetworkMetricsController 等无关日志，必须用完整标签名。
				hits=$(grep -a -i -E 'NfcService|NfcTag|NfaNfc|nfc_nci|nci_rx|nci_tx|rfintf|NfcDispatcher|NfcDiscovery|IsoDep|Felica|TechAPollingLostEvent|RoutingTable|AidRouting|NfcEnabled|secure_element' "$CAP/.nfc_new_log.tmp" 2>/dev/null | head -n 150)
				printf 'NFC_TAP_SAMPLE new_lines=%s baseline=%s nfc_hits=%s\n' "${new:-0}" "${before:-0}" "$(printf '%s' "$hits" | grep -c . )"
				printf '%s\n' "$hits"
				rm -f -- "$CAP/.nfc_new_log.tmp"
			else
				printf 'NFC_TAP_SAMPLE skipped (--no-pause 或无 sleep)\n'
			fi
		else
			printf 'NFC_TAP_SAMPLE unavailable (no logcat; 确认是否 root)\n'
		fi
	} >>"$CAP/07_nfc.txt"

	# ---- 08 USB / MTP
	cap 08_usb.txt dumpsys usb
	lsglob 08_usb.txt '/dev/usb-ffs/*' '/sys/class/udc/*'
	capn 08_usb.txt 60 sh -c '
		for f in /sys/class/udc/*/state /sys/class/android_usb/android0/f1 /sys/class/android_usb/android0/state /sys/class/android_usb/android0/functions; do
			[ -e "$f" ] && { printf "%s = " "$f"; cat "$f" 2>&1; }
		done
		getprop | grep -i -E "sys\.usb|vendor\.usb|ffs" 2>&1
	'
	# USB 用途切换采样：期间请测试者在下拉通知里把 USB 用途改成「文件传输」，
	# 可直接拿到原厂到底走 ffs.mtp 还是 kernel mtp.gs0，不依赖事后回忆。
	{
		printf '\n===== USB 模式采样（每 3 秒一次）=====\n'
		if pause_for "现在开始：请在通知栏把 USB 用途改为「文件传输」（$PAUSE_SECS 秒）..."; then
			samples=$((PAUSE_SECS / 3))
			[ "$samples" -gt 0 ] || samples=1
		else
			samples=1
		fi
		i=0
		mtp_seen=0
		while [ "$i" -lt "$samples" ]; do
			printf '[%02d] config=%s state=%s use_ffs_mtp=%s\n' "$i" \
				"$(getprop sys.usb.config 2>/dev/null)" \
				"$(getprop sys.usb.state 2>/dev/null)" \
				"$(getprop vendor.usb.use_ffs_mtp 2>/dev/null)"
			# gadget/function 列表很长，只用 glob 取 MTP 相关那几项，否则 SUMMARY 会被注水。
			mtp_ffs=''
			for f in /dev/usb-ffs/*mtp* /dev/usb-ffs/*ptp*; do
				[ -e "$f" ] && mtp_ffs="$mtp_ffs${f##*/} "
			done
			gadget_mtp=''
			for f in /config/usb_gadget/g1/functions/*mtp*; do
				[ -e "$f" ] && gadget_mtp="$gadget_mtp${f##*/} "
			done
			printf '      ffs=[%s] gadget=[%s]\n' "$mtp_ffs" "$gadget_mtp"
			case "$(getprop sys.usb.config 2>/dev/null)$(getprop sys.usb.state 2>/dev/null)" in
			*mtp*) mtp_seen=1 ;;
			esac
			i=$((i + 1))
			[ "$i" -lt "$samples" ] && has sleep && sleep 3
		done
		# 明确记一笔“这次到底有没有观察到 MTP 组合”，避免拿着只有 adb 的包当作 MTP 证据。
		if [ "$mtp_seen" -eq 1 ]; then
			printf 'USB_SAMPLE mtp_observed=yes\n'
		else
			printf 'USB_SAMPLE mtp_observed=no （本次采样期间从未进入“文件传输”，MTP 结论无效，请重跑并在提示时切换 USB 用途）\n'
		fi
	} >>"$CAP/08_usb.txt"
	# Type-C 角色与内核侧 gadget 日志：用于判断“只有仅充电”到底是 composition 没挂上，
	# 还是 Oplus 的 typec/充电状态机与 HyperOS 框架不匹配（dumpsys usb 里表现为
	# power_role=no-power / data_role=no-data / usb_charging=false 与反复 DISCONNECTED）。
	capn 08_usb.txt 80 sh -c '
		echo "===== Type-C 角色（dumpsys usb 的 port 状态源头）====="
		for d in /sys/class/typec/*; do
			[ -d "$d" ] || continue
			echo "-- ${d##*/}"
			for n in data_role power_role vconn_source preferred_role usb_typec_connector_state state \
				supported_accessory_modes_source port_type port_number; do
				[ -e "$d/$n" ] && { printf "    %s = " "$n"; cat "$d/$n" 2>&1; }
			done
		done
		echo "===== usb HAL / Oplus USB 策略服务 ====="
		dumpsys -l 2>/dev/null | grep -i -E "usb|typec|charger"
		echo "-- init 里的 usb 服务状态"
		getprop 2>/dev/null | grep -i -E "vendor\\.usb|init\\.svc\\..*usb|ro\\.usb|usb\\.hal|gadget"
		echo "-- Oplus USB/充电相关私有属性"
		getprop 2>/dev/null | grep -i -E "oplus.*usb|usb.*oplus|persist\\.vendor\\.usb|typec|pd_|ufcs" | head -n 40
		echo "===== UDC 绑定与速度 ====="
		for f in /sys/class/udc/*/state /sys/class/udc/*/max_speed /sys/class/udc/*/current_speed; do
			[ -e "$f" ] && { printf "%s = " "$f"; cat "$f" 2>&1; }
		done
		echo "===== 充电侧 USB 供电状态 ====="
		for f in /sys/class/power_supply/usb/online /sys/class/power_supply/usb/type /sys/class/power_supply/usb/voltage_max /sys/class/power_supply/battery/status /sys/class/power_supply/battery/charge_type; do
			[ -e "$f" ] && { printf "%s = " "$f"; cat "$f" 2>&1; }
		done
		echo "===== gadget 实际绑定（b.1 下到底挂了什么）====="
		for f in /config/usb_gadget/g1/configs/b.1/f1 /config/usb_gadget/g1/configs/b.1/f2 /config/usb_gadget/g1/UDC /config/usb_gadget/g1/idVendor /config/usb_gadget/g1/idProduct; do
			[ -e "$f" ] || continue
			printf "%s = " "$f"
			if [ -L "$f" ]; then readlink "$f" 2>&1; else cat "$f" 2>&1; fi
		done
		echo "===== 可用 function 目录 ====="
		for f in /config/usb_gadget/g1/functions/*; do
			[ -e "$f" ] && printf "%s " "${f##*/}"
		done
		echo
		echo "===== dmesg 里的 gadget/dwc3/typec 尾部 40 条 ====="
		dmesg 2>/dev/null | grep -i -E "dwc3|android_usb|configfs|gadget|typec|tcpm|f_mtp|mtp" | tail -n 40
	'

	# ---- 09 触感 / 线性马达
	cap 09_haptic.txt dumpsys vibrator
	cap 09_haptic.txt sh -c 'getprop | grep -i -E "haptic|vib|motor"'
	lsglob 09_haptic.txt '/sys/class/*haptic*' '/sys/devices/virtual/*haptic*' '/vendor/firmware/*aw8697*' '/odm/firmware/*aw8697*'
	capn 09_haptic.txt 40 sh -c '
		for d in /sys/class/input/* /sys/devices/virtual/input/* /sys/class/*haptic*/*; do
			[ -d "$d" ] || continue
			ls -1 "$d" 2>/dev/null | grep -i -E "haptic|effect|wave|aw869" | sed "s|^|$d/|"
		done
		true
	'
	# ColorOS 没有 vibrator 服务（dumpsys 会报 Can\'t find service），真名是 vibrator_manager。
	cap 09_haptic.txt dumpsys vibrator_manager
	cap 09_haptic.txt sh -c 'dumpsys -l 2>/dev/null | grep -i -E "vib|hapt"'
	# 马达谐振频率等参数常直接写在固件名里（aw8697_*_162Hz 等），能定线性/转子。
	lsglob 09_haptic.txt '/odm/firmware/aw8697*.bin' '/vendor/firmware/aw8697*.bin'
	capfilter 'haptic|vibrat' 17_settings.txt 09c_haptic_settings.txt

	# ---- 10 人脸：区分 2D / 结构光（底包只给了弱结论）
	cap 10_face.txt dumpsys face
	cap 10_face.txt sh -c 'getprop | grep -i -E "face|ir_|struct"'
	lsglob 10_face.txt '/vendor/bin/hw/*face*' '/odm/bin/hw/*face*' '/vendor/etc/vintf/manifest/*face*' '/odm/etc/vintf/manifest/*face*'
	# ColorOS 的人脸服务叫 oiface / oplusoiface，判 2D 还是结构光要看这两个与阈值 settings。
	capn 10_face.txt 120 dumpsys oiface
	capn 10_face.txt 120 dumpsys oplusoiface
	capfilter 'face' 17_settings.txt 10b_face_settings.txt
	# 认证实照：提示锁屏后用人脸解一次，只取新增日志里的 face 链路，拿得到 HAL/框架的失败码。
	{
		printf '\n===== 人脸认证采样 =====\n'
		if has logcat; then
			face_before=$(logcat -b all -d 2>/dev/null | wc -l | tr -d ' ')
			if pause_for "请现在锁屏，然后用人脸解锁一次（$PAUSE_SECS 秒）..."; then
				if has tail; then
					logcat -b all -d 2>/dev/null | tail -n "+$((face_before + 1))" >"$CAP/.face_new_log.tmp"
				else
					logcat -b all -d >"$CAP/.face_new_log.tmp" 2>/dev/null
				fi
				face_new=$(wc -l <"$CAP/.face_new_log.tmp" 2>/dev/null | tr -d ' ')
				face_hits=$(grep -a -i -E 'FaceService|FaceManager|BiometricAuth|miface|oiface|face_hal|AuthSession|FaceProvider|setAuthenticator|registration\.scenes|ERROR_|unable to process' "$CAP/.face_new_log.tmp" 2>/dev/null | head -n 150)
				printf 'FACE_AUTH_SAMPLE new_lines=%s baseline=%s hits=%s\n' "${face_new:-0}" "${face_before:-0}" "$(printf '%s' "$face_hits" | grep -c . )"
				printf '%s\n' "$face_hits"
				rm -f -- "$CAP/.face_new_log.tmp"
			else
				printf 'FACE_AUTH_SAMPLE skipped (--no-pause 或无 sleep)\n'
			fi
			# 解完一次再看录入/接受/拒绝计数，能直接判断是否仍 reject。
			printf '采样后人脸计数: %s\n' "$(dumpsys face 2>/dev/null | grep -m1 -a 'prints' | tr -d '\r')"
		else
			printf 'FACE_AUTH_SAMPLE unavailable (no logcat; 确认是否 root)\n'
		fi
	} >>"$CAP/10_face.txt"

	# ---- 11 传感器与功耗（辅助判断自动亮度/双击依赖）
	capn 11_sensors.txt 240 dumpsys sensorservice
	# 高频 PWM / Flicker 传感器是否存在（自动亮度与调光依赖它）。
	capfilter 'Flicker|High_pwm|als|proximity|pwm' 11_sensors.txt 11b_sensor_pwm.txt

	# ---- 12 摄像头 / 电池：官方宣传参数回填依据
	capn 12_specs.txt 200 dumpsys media.camera
	cap 12_specs.txt sh -c 'getprop | grep -i -E "camera"'
	lsglob 12_specs.txt '/sys/class/power_supply/*'
	capfilter 'Camera information|Camera id|device_id|facing|available' 12_specs.txt 12b_camera_ids.txt
	capn 12_specs.txt 60 sh -c '
		for f in /sys/class/power_supply/battery/capacity /sys/class/power_supply/battery/charge_full_design /sys/class/power_supply/battery/energy_full_design /sys/class/power_supply/Battery/capacity /sys/class/power_supply/battery/voltage_min_now; do
			[ -e "$f" ] && { printf "%s = " "$f"; cat "$f" 2>&1; }
		done
		true
	'
	cap 12_specs.txt dumpsys battery
	# 官方宣传参数其实写在 prop 里（实测 Ace6T：backCamSize=50MP+8MP、market.name 等）。
	cap 12_specs.txt sh -c 'getprop | grep -i -E "oplus\.market|camera\.back|camera\.front|CamSize|soc\.model|soc\.manufacturer|marketname|product\.model|product\.device|product\.brand|product\.manufacturer"'
	# 本ROM 到底有哪些 dumpsys 服务（决定后续能不能拓更多采集，也能反证 NFC 残留服务）。
	capn 12_specs.txt 400 dumpsys -l
	capn 12_specs.txt 40 sh -c 'for f in /sys/class/power_supply/*/charge_full_design /sys/class/power_supply/*/energy_full_design /sys/class/power_supply/*/voltage_now /sys/class/power_supply/*/temp; do [ -e "$f" ] && { printf "%s = " "$f"; cat "$f" 2>&1; }; done'

	# ---- 13 音频 / LHDC 前提
	cap 13_audio.txt sh -c 'getprop | grep -i -E "bt|a2dp|lhdc|ldac|audio"'
	lsglob 13_audio.txt '/vendor/lib64/*lhdc*' '/vendor/lib/*lhdc*' '/apex/com.android.bt/lib64/*'

	# ---- 14 SELinux / avc（DSU 冷启动后应尽早跑，本项是 P0）
	cap 14_avc.txt sh -c 'getenforce'
	{
		printf '\n===== avc 汇总 =====\n'
		all_log=''
		if has logcat; then
			# 默认 buffer 不含 vendor/crash，avc 常在 vendor 或内核审计里；采全部 buffer。
			all_log=$(logcat -b all -d 2>/dev/null)
		fi
		deny_count=$(printf '%s\n' "$all_log" | grep -a -c 'avc:[[:space:]]*[Dd]enied' 2>/dev/null)
		perm_count=$(printf '%s\n' "$all_log" | grep -a -c 'avc:[[:space:]]*permissive=1' 2>/dev/null)
		dmesg_deny=''
		if has dmesg; then
			dmesg_deny=$(dmesg 2>/dev/null | grep -a -c 'avc:[[:space:]]*[Dd]enied' 2>/dev/null)
		fi
		printf 'AVC_SUMMARY logcat_all_buffer_denied=%s permissive=%s dmesg_denied=%s\n' \
			"${deny_count:-0}" "${perm_count:-0}" "${dmesg_deny:-不可读}"
		printf '\n===== 去重后的 denied（按源/目标/类）=====\n'
		printf '%s\n' "$all_log" | grep -a 'avc:[[:space:]]*[Dd]enied' \
			| sed -E 's/.*avc:[[:space:]]*[Dd]enied[[:space:]]*//; s/  +/ /g' \
			| sort | uniq -c | sort -rn | head -n 60
		printf '\n===== 原始 denied 前 200 行 =====\n'
		printf '%s\n' "$all_log" | grep -a 'avc:[[:space:]]*[Dd]enied' | head -n 200
	} >>"$CAP/14_avc.txt"

	# ---- 15 关键分区文件存在性（静态取证与真机互证）
	probe_path 15_partitions.txt \
		/system/etc/permissions \
		/vendor/etc/permissions \
		/odm/etc/permissions \
		/product/etc/permissions \
		/my_product/etc/permissions \
		/odm/etc/nfc/nfc_fw_ref \
		/vendor/etc/nfc/nfc_fw_ref \
		/odm/etc/vintf/manifest/manifest_nfc_thn31.xml \
		/odm/etc/init/hw/init.qcom.usb.rc \
		/vendor/etc/init/hw/init.qcom.usb.rc \
		/system/etc/init/hw/init.usb.configfs.rc \
		/vendor/etc/displayconfig \
		/product/etc/device_features \
		/vendor/firmware \
		/odm/firmware
	lsglob 15_partitions.txt \
		'/odm/etc/permissions/*ultrasonic*' \
		'/odm/etc/permissions/*fingerprint*' \
		'/vendor/etc/permissions/*ultrasonic*' \
		'/product/etc/device_features/*.xml' \
		'/odm/firmware/aw8697*' \
		'/vendor/firmware/aw8697*' \
		'/odm/etc/nfc/*' \
		'/odm/etc/vintf/manifest/*' \
		'/vendor/etc/media_*' \
		'/odm/etc/media_*'
	capn 15_partitions.txt 200 sh -c '
		echo "== 整树找自动亮度 lux 表（可能慢，最多 60 秒）=="
		if command -v timeout >/dev/null 2>&1; then T="timeout 60"; else T=""; fi
		# 只保留绝对路径结果，否则后续 capfilter 会把回显的命令行也算成命中。
		$T find /vendor /odm /product /system /my_product -maxdepth 6 -name "multimedia_display_brightness_config*" -o -maxdepth 6 -name "display_brightness_config*" 2>/dev/null | grep -a "^/" | head -n 60
		echo "== nfc_fw_ref 内容 =="
		for f in /odm/etc/nfc/nfc_fw_ref /vendor/etc/nfc/nfc_fw_ref; do [ -r "$f" ] && { echo "-- $f"; head -c 1500 "$f"; echo; }; done
		true
	'
	# 关键装配文件的实际内容与哈希：用于判定“仓库里的修改到底没没进到镜像”。
	# 之前只探文件存在性，拿不到这个就只能猜镜像新旧。
	capn 15_partitions.txt 200 sh -c '
		echo "===== /system/etc/init/hw/init.usb.configfs.rc（HyperOS 侧装配源）====="
		for f in /system/etc/init/hw/init.usb.configfs.rc /system/system/etc/init/hw/init.usb.configfs.rc; do
			[ -f "$f" ] || { echo "ABSENT $f"; continue; }
			sha256sum "$f" 2>/dev/null
			grep -n -E "^on property:sys\.usb\.config=(mtp|mtp,adb)|setprop sys\.usb\.state|symlink .*mtp\.gs0|ffs\.mtp|UDC" "$f" 2>/dev/null | head -n 40
		done
		echo "===== vendor 侧 USB 栈与属性真值 ====="
		for f in /vendor/etc/init/hw/init.qcom.usb.rc /vendor/etc/init/hw/init.usb.rc; do
			[ -f "$f" ] && { echo "-- $f"; sha256sum "$f" 2>/dev/null; grep -c -E "sys\.usb\.config=mtp" "$f" 2>/dev/null; }
		done
		for p in vendor.usb.use_ffs_mtp vendor.usb.use_gadget_hal sys.usb.configfs ro.boot.ramdump; do
			printf "getprop %s = %s\n" "$p" "$(getprop $p 2>/dev/null)"
		done
		echo "-- 镜像里的 build.prop 装配开关真值"
		grep -h -E "^vendor\.usb\.use_ffs_mtp=|^ro\.vendor\.oplus\.sensor\.high_pwm_rgb" /vendor/build.prop /odm/build.prop /odm/etc/build.prop 2>/dev/null
		echo "===== 钱包五件套是否在位 ====="
		pm list packages 2>/dev/null | grep -i -E "finshell|taswallet|uptsm|heytap.htms|eidservice|com.android.nfc" | head -8
		true
	'
	# 上面已探完关键分区文件，这里从 15_partitions.txt 派生三项专项结论。
	# 底包缺 multimedia_display_brightness_config.xml 才会不生成 autoBrightness，真机复核；
	# NFC / USB 则用于确认残留文件与实际 init 脚本的阵营归属。
	capfilter 'brightness_config|lux' 15_partitions.txt 04b_brightness_table.txt
	capfilter 'nfc' 15_partitions.txt 07c_nfc_files.txt
	capfilter 'usb' 15_partitions.txt 08c_usb_files.txt

	# ---- 16 截图（唯一非纯文本证据，失败不影响打包）
	if has screencap; then
		screencap -p "$PROBE_DIR/screen_main.png" >/dev/null 2>&1 ||
			printf '截图失败：非 root / 无显示服务权限，可忽略。\n' >"$CAP/16_screencap_fail.txt"
	fi

	# ---- SUMMARY：机器能自己得出的关键结论集中一页，测试者不必读原始 dump
	{
		printf '# 真机自动采集关键结论（%s，tag=%s）\n' "$PROBE_VERSION" "$TAG_CLEAN"
		printf '# 本节全部由脚本自动提取；只有本节里没有的填法才需要写 MANUAL.txt。\n\n'
		printf '[身份与官方参数]\n'
		printf '市场名            : %s\n' "$(prop_val 'ro\.vendor\.oplus\.market\.name')"
		printf '型号/代号/品牌    : %s / %s / %s\n' "$(prop_val 'ro\.product\.model')" "$(prop_val 'ro\.product\.device')" "$(prop_val 'ro\.product\.brand')"
		printf 'SoC               : %s (%s)\n' "$(prop_val 'ro\.soc\.model')" "$(prop_val 'ro\.soc\.manufacturer')"
		printf 'ROM 版本          : %s\n' "$(prop_val 'ro\.build\.version\.oplusrom')"
		printf '内核              : %s\n' "$(prop_val 'ro\.kernel\.version')"
		printf '摄像头(官方宣传)  : 后置 %s / 前置 %s\n' "$(prop_val 'ro\.vendor\.oplus\.camera\.backCamSize')" "$(prop_val 'ro\.vendor\.oplus\.camera\.frontCamSize')"
		cfd=$(grep -m1 -o -E 'charge_full_design = [0-9]+' "$CAP/12_specs.txt" 2>/dev/null | awk '{print $3}')
		mah=$(awk -v v="${cfd:-0}" 'BEGIN{printf "%d", v / 1000}')
		if [ -n "$cfd" ]; then
			battery_info="$cfd µAh ≈ $mah mAh"
		else
			battery_info='未读到（看 captures/12_specs.txt）'
		fi
		printf '电池设计容量      : %s\n' "$battery_info"

		printf '\n[面板]\n'
		res=$(grep -m1 -o -E 'Physical size: [0-9]+x[0-9]+' "$CAP/03_display.txt" 2>/dev/null | awk -F': ' '{print $2}')
		dpi_line=$(grep -m1 -o -E '[0-9]+\.[0-9]+ x [0-9]+\.[0-9]+ dpi' "$CAP/03_display.txt" 2>/dev/null)
		printf '物理分辨率        : %s\n' "${res:-未读到}"
		printf '密度/dpi          : sdk %s | %s\n' "$(prop_val 'ro\.product\.build\.version\.sdk')" "$dpi_line"
		inches=$(awk -v r="$res" -v d="$dpi_line" 'BEGIN{
			split(r, a, "x"); split(d, b, " ")
			if (a[1] + 0 <= 0 || b[1] + 0 <= 0 || b[3] + 0 <= 0) { print "无法计算（看 captures/03_display.txt 的 dpi 行）"; exit }
			printf "%.2f 英寸", sqrt((a[1] / b[1]) ^ 2 + (a[2] / b[3]) ^ 2)
		}')
		printf '屏幕对角英寸      : %s\n' "$inches"
		printf '出现过的刷新率    : %s\n' "$(sed -n '2p' "$CAP/03e_fps_modes.txt" 2>/dev/null)"
		printf 'peak_refresh_rate : %s\n' "$(setting_val 'peak_refresh_rate')"
		printf '当前 modeId/默认   : %s\n' "$(grep -m1 -o -E 'modeId [0-9]+, renderFrameRate [0-9.]+' "$CAP/03_display.txt" 2>/dev/null)"
		printf '亮度区间/默认    : %s\n' "$(grep -m1 -o -E 'brightnessMinimum [0-9.]+, brightnessMaximum [0-9.]+, brightnessDefault [0-9.]+' "$CAP/03_display.txt" 2>/dev/null)"
		printf 'HDR 亮度能力      : %s\n' "$(grep -m1 -o -E 'mMaxLuminance=[0-9.]+, mMaxAverageLuminance=[0-9.]+, mMinLuminance=[0-9.]+' "$CAP/03_display.txt" 2>/dev/null)"
		printf '高频PWM 证据      : prop high_pwm_rgb=%s | 传感器=%s\n' "$(prop_val 'ro\.vendor\.oplus\.sensor\.high_pwm_rgb')" "$(grep -m1 -o -E '[A-Za-z_]*High_pwm[^|]*' "$CAP/11_sensors.txt" 2>/dev/null | head -1)"
		printf '调光相关面板位    : %s\n' "$(grep -h -m2 -E 'mPWMBacklightSupport|mSinglePulseDimmingSupport' "$CAP/03_display.txt" 2>/dev/null | tr -s ' ' | tr '\n' '|')"
		printf 'Display ID(仅参考) : %s\n' "$(grep -m1 -o -aE 'local:[0-9]+' "$CAP/03_display.txt" 2>/dev/null)"
		printf '                       ↑ 该值原系统不等价于 DSU，PORT_TARGET_DISPLAY_ID 必须在 DSU 上取。\n'

		printf '\n[指纹]\n'
		printf '传感器类型        : %s\n' "$(prop_val 'persist\.vendor\.fingerprint\.sensor_type')"
		printf '传感器中心坐标    : %s\n' "$(prop_val 'persist\.vendor\.fingerprint\.optical\.sensorlocation')"
		printf '图标尺寸/底边距    : %s / %s\n' "$(setting_val 'fingerprint_pressed_icon_size')" "$(setting_val 'fingerprint_icon_margin_bottom')"
		printf '其余指纹相关 prop : %s\n' "$(grep -c -E '^\[(persist\.vendor\.fingerprint|ro\.vendor\.fp\.)' "$CAP/01_getprop.txt" 2>/dev/null) 条，详见 captures/06b_fp_props.txt 与 06c_fp_settings.txt"

		printf '\n[触控与双击亮屏]\n'
		printf 'double_tap_to_wake: %s\n' "$(setting_val 'double_tap_to_wake')"
		printf 'doze_tap_gesture  : %s\n' "$(setting_val 'doze_tap_gesture')"
		printf '触摸设备名        : %s\n' "$(grep -a -m6 -E '^NAME .*= ' "$CAP/05_touch.txt" 2>/dev/null | sed 's|^NAME [^=]*= *||' | tr '\n' '|')"

		printf '\n[NFC / USB]\n'
		printf 'NFC 开关状态      : %s\n' "$(grep -m1 -a -E '^mState=' "$CAP/07_nfc.txt" 2>/dev/null)"
		printf 'NFC 能力位        : %s\n' "$(grep -a -m3 -E '^mIsSecureNfcEnabled=|^mIsReaderOptionEnabled=|^pollTech=' "$CAP/07_nfc.txt" 2>/dev/null | tr '\n' ' ')"
		printf 'NFC 上层 support  : %s\n' "$(grep -a -c -E '^\[ro\.vendor\.nfc\.' "$CAP/01_getprop.txt" 2>/dev/null) 条，详见 captures/07b_nfc_props.txt"
		printf '贴卡采样结果      : %s\n' "$(grep -m1 -aE 'NFC_TAP_SAMPLE' "$CAP/07_nfc.txt" 2>/dev/null)"
		printf '贴卡前 NFC 开关   : %s\n' "$(grep -m1 -aE 'NFC_TAP_PRECHECK' "$CAP/07_nfc.txt" 2>/dev/null)"
		printf '人脸认证采样      : %s\n' "$(grep -m1 -aE 'FACE_AUTH_SAMPLE' "$CAP/10_face.txt" 2>/dev/null)"
		printf '采样后人脸计数    : %s\n' "$(grep -m1 -a '采样后人脸计数' "$CAP/10_face.txt" 2>/dev/null | sed 's/^采样后人脸计数: //')"
		printf 'MTP 是否被观察到  : %s\n' "$(grep -m1 -aE 'USB_SAMPLE' "$CAP/08_usb.txt" 2>/dev/null)"
		printf 'avc 汇总          : %s\n' "$(grep -m1 -aE 'AVC_SUMMARY' "$CAP/14_avc.txt" 2>/dev/null)"
		printf '原厂 NFC HAL      : %s\n' "$(prop_val 'init\.svc\.vendor\.nfc_hal_service')"
		printf 'sys.usb.config    : %s\n' "$(prop_val 'sys\.usb\.config')"
		printf 'sys.usb.state     : %s (configfs=%s, use_ffs_mtp=%s)\n' "$(prop_val 'sys\.usb\.state')" "$(prop_val 'sys\.usb\.configfs')" "$(prop_val 'vendor\.usb\.use_ffs_mtp')"
		printf 'USB 采样轨迹      :\n'
		grep -a -E '^\[[0-9]+\] config=' "$CAP/08_usb.txt" 2>/dev/null | sed 's/^/    /'

		printf '\n[触感 / 人脸]\n'
		printf 'vibrator 服务名    : %s\n' "$(grep -a -E 'vibrator|vib' "$CAP/12_specs.txt" 2>/dev/null | head -6 | tr -s ' \n' ' ')"
		printf 'sys.haptic.* 条数  : %s（原机已有的映射，可作为 Neo8 参数参考）\n' "$(grep -a -c -E '^\[sys\.haptic\.' "$CAP/01_getprop.txt" 2>/dev/null)"
		printf 'aw8697 固件频率    : %s\n' "$(grep -a -o -E '_[0-9]{3}Hz' "$CAP/09_haptic.txt" 2>/dev/null | sort -u | tr '\n' ' ')"
		printf '人脸 dumpsys      : %s\n' "$(grep -a -m1 -E 'Dumping for sensorId|Can.t find service' "$CAP/10_face.txt" 2>/dev/null)"
		printf '人脸服务清单      : %s\n' "$(grep -a -iE 'oiface|face' "$CAP/12_specs.txt" 2>/dev/null | head -6 | tr -s ' \n' ' ')"
		printf '人脸阈值 settings  : %s\n' "$(grep -a -m6 -E '^facelock|^face_unlock' "$CAP/10b_face_settings.txt" 2>/dev/null | tr '\n' ' ')"

		printf '\n[自动亮度表（影响 coloros_display Profile）]\n'
		printf 'lux/亮度表命中    : %s\n' "$(grep -a -c -E 'brightness_config' "$CAP/04b_brightness_table.txt" 2>/dev/null) 条（为 0 则与原包静态结论一致：不生成 autoBrightness）"
	} >"$PROBE_DIR/SUMMARY.txt" 2>&1

	# ---- MANUAL：只留机器抓不到的项（填完再跑一次 --pack 即可回传）
	MANUAL="$PROBE_DIR/MANUAL.txt"
	if [ ! -f "$MANUAL" ]; then
		cat >"$MANUAL" <<MANUAL_EOF
真机人工确认表（tag=$TAG_CLEAN，脚本 $PROBE_VERSION）

这一版已经把能自动抓的都抓了，结论写在 SUMMARY.txt（分辨率/刷新率/尺寸/电池/摄像头市
场名/高频PWM 证据/指纹位置与类型/双击开关值/NFC 开关/USB 当前用途等）。
本表只保留三类机器拿不到的：主观观感、需要外部条件（卡/电脑/耳机/暗光）、界面文案。
请在等号后直接填写，看不清/没条件的写 unknown，然后运行：
      sh device_probe.sh --tag $TAG_CLEAN --pack

[观感]
低亮度下是否觉得闪眼/发胀(无/轻微/明显)=
自动亮度跟随是否自然(自然/偏慢/过冲/不跟随)=
开机默认亮度观感(偏暗/合适/偏亮)=

[触感]
键盘·返回·滑动 三档强弱能否明显区分(ok/偏弱/偏散)=
是否有「打字/输入振动手感」类开关，名称照抄=

[指纹]
如有尺子：解锁时按压处距屏幕底边大约 __ mm（与 SUMMARY 里的 prop 坐标互校）=
湿手能不能解锁(ok/no)=
解锁时要不要每次都按在同一个点(yes/no)=

[双击亮屏]
实测双击能否亮屏、是否容易误触(照实描述)=
设置里该开关的名字照抄=

[NFC]（脚本已采样贴卡日志，如果没贴卡请在这里补上）
刚才贴卡时手机有无提示/有无反应(有/无/未测试)=
两台手机互读能否读到对方卡号(yes/no/未测试)=

[USB/MTP]
选「文件传输」后电脑能否看到并读出内部存储(ok/看不到/能看到但读不出)=
传输过程中是否会自动断开重连(yes/no)=

[人脸]
设置里能否录入面部(可/不可)=
录入页是否写到 3D/结构光/2D（照抄文案）=
暗光（遮黑前置）能否解锁(ok/no)=

[小爱与语音]
说「小爱同学」能否唤醒(原系统实测 ok/no)=
唤醒是否要求先亮屏(yes/no/unknown)=

[钱包]
原机「钱包」能否打开、能否进入刷卡/门卡页(ok/闪退/无应用/未测试)=

[音频]
连上支持 LHDC 的耳机后，「音频编解码」里看到的项目（照抄）=

[界面文案]
刷新率下拉里可选档位的显示名称（照抄，数值已在 SUMMARY）=
「高刷/自适应/标准」之类选项是否存在=

[其他]
原系统上其他值得注意的异常(发热/闪屏/传感器缺失/无信号等)=
MANUAL_EOF
		printf '已生成人工填写表: %s\n' "$MANUAL"
	else
		printf '保留已存在的人工填写表(未覆盖): %s\n' "$MANUAL"
	fi

	printf '\n采集完成，开始打包...\n'
fi

# ---------------------------------------------------------------- 打包
BASENAME="device_probe_${TAG_CLEAN}"
PARENT=$(dirname -- "$PROBE_DIR")
ARCHIVE=''
# 设备上的 zip / tar 选项子集不一，这里只用最基础的 -q -r / -czf；失败自然退到下一档。
if has zip; then
	(
		cd -- "$PARENT" || exit 1
		rm -f -- "$BASENAME.zip" 2>/dev/null
		zip -q -r "$BASENAME.zip" "$BASENAME"
	) && ARCHIVE="$PARENT/$BASENAME.zip"
fi
if [ -z "$ARCHIVE" ] && has tar; then
	(
		cd -- "$PARENT" || exit 1
		rm -f -- "$BASENAME.tar.gz" 2>/dev/null
		tar -czf "$BASENAME.tar.gz" "$BASENAME"
	) && ARCHIVE="$PARENT/$BASENAME.tar.gz"
fi

printf '\n================ 结果 ================\n'
printf '采集目录: %s\n' "$PROBE_DIR"
printf '关键结论: %s/SUMMARY.txt\n' "$PROBE_DIR"
printf '人工补填: %s/MANUAL.txt\n' "$PROBE_DIR"
if [ -n "$ARCHIVE" ]; then
	printf '回传文件: %s\n' "$ARCHIVE"
	# shellcheck disable=SC2012 # ARCHIVE 是本脚本自己生成的固定路径。
	printf '大小   : %s\n' "$(ls -lh -- "$ARCHIVE" 2>/dev/null | awk '{print $5}')"
	printf '\n把这个文件直接发给维护者即可。若要补充人工结论：\n'
	printf '  1) 在 MT 管理器里编辑 %s\n' "$PROBE_DIR/MANUAL.txt"
	printf '  2) 长按本脚本再执行一次，或在控制台运行: sh %s --tag %s --pack\n' "$0" "$TAG_CLEAN"
else
	printf '设备上没有 zip/tar，未自动生成压缩包。\n'
	printf '请在 MT 管理器里长按目录 %s → 「压缩」为 zip 后发回。\n' "$PROBE_DIR"
fi
printf '\n提醒: 本脚本只采集原系统硬件事实，不验证补丁效果；\n'
printf '      Display ID / 冷启动 avc / 崩溃日志必须以 DSU 环境为准。\n'
