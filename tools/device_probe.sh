#!/system/bin/sh
# 原系统（realme ColorOS）硬件事实采集脚本 —— 手机端独立运行，不依赖 adb，全程只读。
#
# 用途：为 OnePlus-Port-Script 的真我 Neo8 移植采集只能从真机读取的物理事实，产出
#       一个压缩包（zip，无 zip 时退化为 tar.gz）供测试者直接回传给维护者。
#       它不验证任何补丁效果：补丁验证与 Display ID 必须在移植后的澎湃 DSU 上做，
#       本脚本在 DSU 上重复运行只是用于交叉对照，不能替代 DSU 验证。
#
# 用法（推荐在 root shell 里跑，否则 getevent/sysfs/部分 dumpsys 会是空）：
#   su
#   sh /sdcard/Download/device_probe.sh            # 默认标签 stock
#   sh /sdcard/Download/device_probe.sh dsu         # 指定标签，便于区分环境
#   sh /sdcard/Download/device_probe.sh --pack      # 只做打包（编辑完 MANUAL.txt 后二次运行）
#   sh /sdcard/Download/device_probe.sh --out /sdcard/Download stock   # 指定输出目录
#
# 采集边界：只执行读取类命令（getprop / dumpsys / cat / ls / getevent -p / logcat -d），
# 不写设备系统分区、不 mount、不重启、不改设置；唯一写入物是输出目录与其压缩包。

set -u

PROBE_VERSION='2026.09.23-1'

# ---------------------------------------------------------------- 参数解析
TAG='stock'
PACK_ONLY=0
PROBE_OUT=''
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
	-h | --help)
		echo '用法: sh device_probe.sh [--tag stock|dsu|...] [--out 目录] [--pack]'
		echo '  --pack  只把上次采集结果与已编辑的 MANUAL.txt 打包'
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

# 标签只允许安全字符，避免拼进路径时引入意外行为。
TAG_CLEAN=$(printf '%s' "$TAG" | tr -c 'A-Za-z0-9._-' '_')
[ -n "$TAG_CLEAN" ] || TAG_CLEAN='stock'

# 优先沿用上次采集目录，保证 --tag X --pack 能对上。
STAMP_FILE=''
LAST_DIR=''
for probe_out in "${PROBE_OUT:-}" /data/local/tmp "$HOME/Downloads" "$HOME" /tmp "$PWD"; do
	[ -n "$probe_out" ] || continue
	guess="$probe_out/device_probe_${TAG_CLEAN}"
	[ -d "$guess" ] || continue
	if [ -z "$STAMP_FILE" ]; then
		STAMP_FILE="$guess/.probe_dir"
		[ -f "$STAMP_FILE" ] || STAMP_FILE=''
	fi
	[ -z "$LAST_DIR" ] && [ -f "$guess/.probe_dir" ] && LAST_DIR="$guess"
done

if [ "$PACK_ONLY" -eq 1 ]; then
	if [ -z "$LAST_DIR" ]; then
		echo 'FAIL: 没有找到可打包的采集目录，请先不带 --pack 运行一次采集。' >&2
		exit 1
	fi
	PROBE_DIR="$LAST_DIR"
	RESULT_DIR="$PROBE_DIR"
else
	STAMP_DIR="${LAST_DIR:-${PROBE_OUT:-/data/local/tmp}/device_probe_${TAG_CLEAN}}"
	STAMP_FILE="$STAMP_DIR/.probe_dir"

	# 输出目录：先试上次路径，再依次探测可写位置。
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
	ensure_dir "$STAMP_DIR"
	for cand in /data/local/tmp "$HOME/Downloads" "$HOME" /tmp "$PWD"; do
		[ -n "$PROBE_DIR" ] && break
		ensure_dir "$cand/device_probe_${TAG_CLEAN}"
	done
	[ -n "$PROBE_DIR" ] || { echo 'FAIL: 找不到可写输出目录，请用 --out 指定。' >&2; exit 1; }
	STAMP_DIR="$PROBE_DIR"
	printf '%s\n' "$(basename -- "$PROBE_DIR")" >"$STAMP_FILE" 2>/dev/null

	CAP="$PROBE_DIR/captures"
	mkdir -p -- "$CAP"
fi

# ---------------------------------------------------------------- 采集原语
has() {
	command -v -- "$1" >/dev/null 2>&1
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

# 直接抓文件内容（不存在/不可读都写清状态）。
catfile() {
	out="$CAP/$1"
	shift
	for p in "$@"; do
		printf '\n----- %s -----\n' "$p" >>"$out"
		if [ -d "$p" ]; then
			printf '[目录] 见 lsglob 结果\n' >>"$out"
		elif [ -e "$p" ]; then
			if [ -r "$p" ]; then
				head -c 4000 -- "$p" >>"$out" 2>&1
			else
				printf '[NOT READABLE] 权限或 SELinux 拒绝\n' >>"$out"
			fi
		else
			printf '[NOT FOUND]\n' >>"$out"
		fi
	done
}

# 记录路径是否存在；目录额外列出条目。
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

# 受控 glob 列目录（未展开的 * 视为无匹配）。
lsglob() {
	out="$CAP/$1"
	shift
	for p in "$@"; do
		printf '\n----- %s -----\n' "$p" >>"$out"
		case "$p"
		*
		*\**)
			case "$p" in
			*\**) : ;;
			*) printf '(不是 glob，跳过)\n' >>"$out"; continue ;;
			esac
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

say() {
	printf '%s\n' "$*"
}

# ---------------------------------------------------------------- 采集流程
if [ "$PACK_ONLY" -eq 0 ]; then
	# ---- 00 元信息
	META='00_meta.txt'
	: >"$CAP/$META"
	printf '# Neo8 真机采集 %s\n' "$PROBE_VERSION" >>"$CAP/$META"
	printf '# tag=%s out=%s\n' "$TAG_CLEAN" "$PROBE_DIR" >>"$CAP/$META"
	printf '\n===== 身份与只读前提 =====\n' >>"$CAP/$META"
	if has id; then id >>"$CAP/$META" 2>&1; fi
	if has uname; then uname -a >>"$CAP/$META" 2>&1; fi
	printf '\n===== /proc/version =====\n' >>"$CAP/$META"
	[ -r /proc/version ] && head -c 800 /proc/version >>"$CAP/$META" 2>&1
	printf '\n===== 工具可用性 =====\n' >>"$CAP/$META"
	for t in toybox getevent dumpsys settings getprop screencap su zip tar timeout sed awk find grep head; do
		if has "$t"; then printf 'YES  %s\n' "$t" >>"$CAP/$META"; else printf 'NO   %s\n' "$t" >>"$CAP/$META"; fi
	done
	[ "$(id -u 2>/dev/null)" = "0" ] ||
		printf '\n警告: 当前不是 root（uid=%s）。getevent / sysfs / 部分 dumpsys 预计为空，\n建议在 root shell 里重跑一次。\n' "$(id -u 2>/dev/null)" >>"$CAP/$META"

	# ---- 01 全量属性 + 身份摘要
	cap 01_getprop.txt getprop
	capfilter 'ro\.(product|build|vendor\.oplus|oplus)\.' 01_getprop.txt 01b_identity.txt
	capfilter 'haptic|vibrator|motor' 01_getprop.txt 09b_haptic_props.txt
	capfilter 'nfc' 01_getprop.txt 07b_nfc_props.txt
	capfilter 'usb' 01_getprop.txt 08b_usb_props.txt
	capfilter 'display|lcd|brightness|fps|refresh|hdr|ltpo|lcdc' 01_getprop.txt 03b_display_props.txt
	capfilter 'fp|fingerprint|ultrasonic' 01_getprop.txt 06b_fp_props.txt

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

	# ---- 04 亮度与自动亮度表
	cap 04_brightness.txt sh -c '
		for k in screen_brightness screen_brightness_mode automatic_brightness video_enable_luminance; do
			printf "settings secure %s = " "$k"; settings get secure "$k" 2>&1
		done
		for k in minimum_brightness; do
			printf "settings system %s = " "$k"; settings get system "$k" 2>&1
		done
	'
	probe_path 04_brightness.txt /sys/class/backlight /sys/class/lcd /sys/devices/platform/vendor背光
	lsglob 04_brightness.txt '/sys/class/backlight/*' '/sys/class/lcd/*'
	capn 04_brightness.txt 60 sh -c 'for f in /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness /sys/class/backlight/*/bl_power; do [ -e "$f" ] && { printf "%s = " "$f"; cat "$f" 2>&1; }; done'
	# 底包缺 multimedia_display_brightness_config.xml 才导致 autoBrightness 不生成，这里复核真机上是否存在。
	capfilter 'multimedia_display_brightness_config|display_brightness_config' 15_partitions.txt 04b_brightness_table.txt
	cap 04_brightness.txt sh -c 'ls -1 /vendor/etc 2>/dev/null | grep -i -E "brightness|lux" ; echo "--- odm"; ls -1 /odm/etc 2>/dev/null | grep -i -E "brightness|lux"'

	# ---- 05 触控：HBP 节点、scan code、双击亮屏参数
	cap 05_touch.txt getevent -p
	capn 05_touch.txt 200 cat /proc/bus/input/devices
	probe_path 05_touch.txt /dev/input /sys/class/input /sys/devices/virtual/input
	lsglob 05_touch.txt '/dev/input/*' '/sys/class/input/*'
	cap 05_touch.txt sh -c 'ls -l /dev/input 2>&1'
	# Oplus HBP：4100/4101 配置节点 + sec_touch 目录 + touchfeature 能力位。
	capfilter 'Input|input' 00_meta.txt 05b_touch_note.txt
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
	capn 05_touch.txt 80 sh -c '
		if command -v timeout >/dev/null 2>&1; then
			timeout 25 find /sys -maxdepth 5 -name "sec_touch" -o -maxdepth 5 -name "410*" -o -maxdepth 5 -name "*tap2wake*" 2>/dev/null | head -n 60
		else
			find /sys/class/input /sys/devices/virtual/input -maxdepth 3 \( -name "sec_touch" -o -name "410*" -o -name "*tap2wake*" \) 2>/dev/null | head -n 60
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

	# ---- 07 NFC：THN31/TMS 阵营的运行时确认（静态三判据已在底包做过）
	cap 07_nfc.txt dumpsys nfc
	cap 07_nfc.txt sh -c 'ls -l /dev 2>/dev/null | grep -i nfc; echo "--- ps"; ps -A 2>/dev/null | grep -i nfc'
	lsglob 07_nfc.txt '/dev/*nfc*' '/vendor/etc/vintf/manifest/*nfc*' '/odm/etc/vintf/manifest/*nfc*' '/odm/etc/nfc/*' '/vendor/etc/nfc/*'
	capfilter 'nfc' 15_partitions.txt 07c_nfc_files.txt
	# 三判据之一：init 实际启动的 HAL 服务名与设备节点。
	capn 07_nfc.txt 60 sh -c 'grep -h -R -E "tms_nfc|st21nfc|nq-nci|nfc_hal_service" /vendor/etc/init /odm/etc/init 2>/dev/null | head -n 40'

	# ---- 08 USB / MTP
	cap 08_usb.txt dumpsys usb
	lsglob 08_usb.txt '/dev/usb-ffs/*' '/sys/class/udc/*'
	capn 08_usb.txt 60 sh -c '
		for f in /sys/class/udc/*/state /sys/class/android_usb/android0/f1 /sys/class/android_usb/android0/state /sys/class/android_usb/android0/functions; do
			[ -e "$f" ] && { printf "%s = " "$f"; cat "$f" 2>&1; }
		done
		getprop | grep -i -E "sys\.usb|vendor\.usb|ffs" 2>&1
	'
	capfilter 'usb' 15_partitions.txt 08c_usb_files.txt

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

	# ---- 10 人脸：区分 2D / 结构光（底包只给了弱结论）
	cap 10_face.txt dumpsys face
	cap 10_face.txt sh -c 'getprop | grep -i -E "face|ir_|struct"'
	lsglob 10_face.txt '/vendor/bin/hw/*face*' '/odm/bin/hw/*face*' '/vendor/etc/vintf/manifest/*face*' '/odm/etc/vintf/manifest/*face*'

	# ---- 11 传感器与功耗（辅助判断自动亮度/双击依赖）
	capn 11_sensors.txt 240 dumpsys sensorservice

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

	# ---- 13 音频 / LHDC 前提
	cap 13_audio.txt sh -c 'getprop | grep -i -E "bt|a2dp|lhdc|ldac|audio"'
	lsglob 13_audio.txt '/vendor/lib64/*lhdc*' '/vendor/lib/*lhdc*' '/apex/com.android.bt/lib64/*'

	# ---- 14 SELinux / avc（原系统仅作参考，真值要在 DSU 采）
	cap 14_avc.txt sh -c 'getenforce'
	capn 14_avc.txt 400 sh -c 'logcat -d -v brief 2>/dev/null | grep -i "avc:" | head -n 300'
	capn 14_avc.txt 40 sh -c 'logcat -d -v brief 2>/dev/null | grep -i -c "avc:"'

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
		$T find /vendor /odm /product /system /my_product -maxdepth 6 -name "multimedia_display_brightness_config*" -o -maxdepth 6 -name "display_brightness_config*" 2>/dev/null | head -n 60
		echo "== nfc_fw_ref 内容 =="
		for f in /odm/etc/nfc/nfc_fw_ref /vendor/etc/nfc/nfc_fw_ref; do [ -r "$f" ] && { echo "-- $f"; head -c 1500 "$f"; echo; }; done
		true
	'

	# ---- 16 截图（唯一非纯文本证据，失败不影响打包）
	if has screencap; then
		screencap -p "$PROBE_DIR/screen_main.png" >/dev/null 2>&1 || printf '截图失败（可能无显示权限）\n' >"$CAP/16_screencap_fail.txt"
		settings put system screen_brightness 100 >/dev/null 2>&1
	fi

	# ---- MANUAL：需要人工填写/观察的项（编辑后再次运行 --pack 即可回传）
	MANUAL="$PROBE_DIR/MANUAL.txt"
	if [ ! -f "$MANUAL" ]; then
		cat >"$MANUAL" <<MANUAL_EOF
Neo8 真机人工确认表（tag=$TAG_CLEAN）
维护者：$PROBE_VERSION
说明：本文件由采集脚本生成，请直接在等号后填写，然后运行
      sh device_probe.sh --tag $TAG_CLEAN --pack
      把生成的压缩包发回。看不清/找不到的写 unknown，不要留空。

[屏幕与亮度]
官方宣传分辨率(如 2800x1272)=
官方宣传尺寸(如 6.83 英寸)=
设置里可选的刷新率档位(逐项照抄名称与数值)=
面板最高刷新率是否 165Hz(yes/no/unknown)=
调光方式(高频PWM/低频PWM/类DC 的具体档位名称)=
是否出现低频PWM护眼提示或闪屏感(yes/no)=
自动亮度开关是否存在、跟随是否自然(ok/no/unknown)=

[超声波指纹]
解锁时手指应按的位置:距屏幕底边约 __ mm / 距左右边 __ mm =
解锁图标在设置里是否显示、位置是否与实际感应区一致(ok/偏移)=
是否支持湿手解锁(yes/no/unknown)=
录入指纹时是否每次都要重新按压同一区域(yes/no)=

[双击亮屏]
设置里是否有双击亮屏开关(名称照抄)=
实测双击能否亮屏(ok/no/偶尔失灵)=
不打扰场景下是否会误触亮屏(yes/no)=

[触感]
振动马达类型(线性/转子/unknown)=
键盘/返回/滑动 三档触感强弱是否可明显区分(ok/偏弱/偏散)=
是否有「打字振动手感」类开关，名称照抄=

[NFC]
贴公交卡/门禁卡是否有反应(yes/no)=
系统里能否打开 NFC 开关(ok/报错/无开关)=
贴 Android 手机背面能否读出对方卡号(yes/no/unknown)=

[USB/MTP]
连上电脑默认弹出的 USB 用途(文件传输/传输照片/仅充电/其他)=
选择「文件传输」后电脑能否看到并读取内部存储(ok/看不到/能看到但读不出)=
是否还会自动断开/重连(yes/no)=

[人脸]
设置里是否可录入面部(可/不可/需遮挡前置)=
录入界面是否提示结构光/3D 或仅 2D(照抄文案)=
暗光下能否解锁(ok/no)=

[小爱与语音]
说「小爱同学」能否唤醒(原系统实测，ok/no)=
唤醒是否需要先亮屏(yes/no/unknown)=

[钱包/支付]
设置里是否有「钱包」应用、能否打开(ok/闪退/无应用)=
钱包内能否进入刷卡/门卡页面(yes/no)=
是否有 eSE/安全芯片相关说明(照抄)=

[音频]
蓝牙音频编码列表里是否有 LHDC/L2HC(照抄看到的项目)=

[Settings 设备参数]
关于本机里显示的处理器完整名称(照抄)=
电池容量宣传值(如 8300mAh)=
后置摄像头像素组合(如 50MP+8MP)=
前置摄像头像素=
屏幕分辨率(系统展示值)=

[其他异常]
原系统上任何值得注意的异常(发热/闪屏/传感器缺失/无信号等)=
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
if has zip; then
	(
		cd -- "$PARENT" || exit 1
		rm -f -- "$BASENAME.zip" 2>/dev/null
		zip -q -r -X -- "$BASENAME.zip" "$BASENAME"
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
if [ -n "$ARCHIVE" ]; then
	printf '回传文件: %s\n' "$ARCHIVE"
	printf '大小   : %s\n' "$(ls -lh -- "$ARCHIVE" 2>/dev/null | awk '{print $5}')"
	printf '\n请把上面这个文件直接发给维护者。若还要补充人工结论：\n'
	printf '  1) 编辑 %s\n' "$PROBE_DIR/MANUAL.txt"
	printf '  2) 再执行 sh %s --tag %s --pack\n' "$0" "$TAG_CLEAN"
else
	printf '警告: 设备上没有 zip/tar，未生成压缩包。\n'
	printf '请手动把整个目录压缩后发回: %s\n' "$PROBE_DIR"
fi
printf '\n提醒: 本脚本只采集原系统硬件事实，不验证补丁效果；\n'
printf '      Display ID / 冷启动 avc / 崩溃日志必须以 DSU 环境为准。\n'
