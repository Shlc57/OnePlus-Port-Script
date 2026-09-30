#!/system/bin/sh
# HyperOS 移植现象取证脚本 —— MT 管理器可直接执行，不依赖 adb / 电脑，全程只读
# （唯一写入物是输出目录与压缩包；不 pm disable、不改设置、不重启服务、不 mount、不截图）。
#
# 用途：在移植后的澎湃系统（DSU 或已刷机）上，为四类现场问题抓「能定性」的证据并打包回传：
#   1) audio  声音断断续续（时有时无）
#   2) face   人脸入口 / 录入被拒 / 能录入但解不开
#   3) nfc    NFC 无响应 / 读卡中概率
#   4) xiaoai 小爱免手唤醒不生效 / 误唤醒
#
# 与 tools/device_probe.sh 的分工（不合并的理由）：device_probe 采「原系统静态硬件事实」，
# 快照即够；本脚本采「移植后运行时现象」，必须整段连续 logcat + 周期性状态快照共用同一条
# 时间轴。断续类问题的 HAL/PAL 证据在事后 `logcat -d` 抽样里极易缺失；常驻采集类问题
# （CPU FlexKws 是 6 秒窗口 + 1.5 秒间隔的循环）只能靠时间戳对齐。
#
# 除了日志，本脚本还收录：dmesg 与 /proc/asound 声卡状态、/proc/interrupts、**历史崩溃层**
# （dropbox 崩溃/ANR/Watchdog/上次开机内核日志正文、tombstones 摘要与全文、ANR traces、
# pstore/console-ramoops 的模块关键字命中、ramdump 目录），`dumpsys meminfo` 与 top/进程表、
# 各子系统 dumpsys，以及「补丁落地哨兵」——用来回答「这块镜像到底带了哪些改动」。
# **没有哨兵就不能断"补丁没落地"**：测试者手上经常是较早的包，缺 CPU FlexKws、缺 TEE 覆盖、
# 缺 odm 声学属性都是旧包的正常状态。历史崩溃层独立于 logcat 缓冲，因此“只跑一次也能翻出以前崩过什么”。
#
# 面向远端测试者（默认就是他的用法）：**不需要任何参数，也不需要填任何东西**。
# 把本文件丢进 /sdcard/Download → MT 管理器里长按 → 打开方式 → Shell 执行，等它打印出
# 「回传文件」那一行，把同目录下的 issue_trace_now.zip（设备无 zip 时会是 .tar.gz）发回即可。
# 已在真机（Ace 6T DSU，HyperOS 移植包）跑通：全程约 6-8 分钟，无 zip 时自动退到 tar.gz。
# 默认已包含：自动探针（开 NFC、切 USB、亮/息屏、拉起安全页与小爱、按音量键、开钱包）
# + 历史崩溃层（dropbox 正文、tombstones/ANR 全文、pstore/console-ramoops、ramdump 清单）
# + 补丁落地哨兵 + 声卡/内核/内存/进程快照 + 整段连续 logcat。
# 只有三件事脚本替不了：正对手机解锁、把卡贴背部、开口喊「小爱同学」（没做也不会报错）。
#
# 维护者用的只读模式：`--no-auto`（不触发任何探针、不改设备状态），配合 `--no-pause` 可最速出快照。
#
# MT 管理器执行步骤：
#   1) 把 issue_trace.sh 放到 /sdcard/Download。
#   2) 在 MT「设置 → Root 权限」放行 Root（不放行则 logcat / sysfs / 多数 dumpsys 会为空，
#      脚本会在 00_meta.txt 里明确标注，此时证据不足以定性）。
#   3) 长按本文件 → 「打开方式 → Shell / 脚本执行」（默认即全量自动，不需参数）。
#      或在 MT 内置控制台执行下文的带参命令。
#   4) 中途只需照屏幕提示做上面那三件事（不做也可以），不要拔线不要关机。
#   5) 看到「回传文件: /sdcard/Download/issue_trace_<标签>.zip」（或 .tar.gz）后，把该文件发回维护者。
#
# 等价命令（MT 内置控制台或任意 shell）：
#   sh /sdcard/Download/issue_trace.sh --full               # 远端测试者就用这一条（自动探针+全量，约 5 分钟）
#   sh /sdcard/Download/issue_trace.sh audio                # 只跑声音取证
#   sh /sdcard/Download/issue_trace.sh --only audio,xiaoai  # 只跑指定场景
#   sh /sdcard/Download/issue_trace.sh --secs 60            # 每场景复现窗口 60 秒
#   sh /sdcard/Download/issue_trace.sh --interval 5         # 状态快照间隔 5 秒
#   sh /sdcard/Download/issue_trace.sh --no-heavy           # 跳过 ANR/tombstone/dmesg/meminfo 等重项
#   sh /sdcard/Download/issue_trace.sh --no-pause          # 不做交互复现，只取静态快照（最快）
#   sh /sdcard/Download/issue_trace.sh --auto             # 自动探针模式（远端测试者推荐）
#
# --auto 给远端测试者用：不需要他记住任何流程。能自动触发的由脚本自己做（开 NFC、USB 切“传输文件”、
# 亮/息屏、拉起安全设置页与小爱会话、按音量键、拉起钱包），并在 logcat 里打 `PROBE` 时间戳、
# 把 accept/reject/mState/usb 等关键计数在每个动作前后拍成快照（captures/98_auto_state.txt），
# 因此他只需做两件无法代做的事：**正对手机**与**贴一下卡**（喊小爱同理）。不加 --auto 时本脚本全程只读。
# --auto 会临时改功能状态（NFC 开关、USB 函数），启动时先记下原值，结束时尽量还原（captures/97_probe_log.txt）。
#   sh /sdcard/Download/issue_trace.sh --tag new1           # 区分环境与包（换包后务必换标签）
#   sh /sdcard/Download/issue_trace.sh --pack               # 只重新打包（补完 MANUAL.txt 后）
#
# 产出：captures/ 原始采集、90_logcat_live.txt 整段连续日志、91_ticks.txt 时间轴快照、
#       92_*/93_* 按主题切好的日志、SUMMARY.txt（自动结论，第 [0] 节是落地哨兵）、
#       MANUAL.txt（只剩人眼与手感能定的项）。
#
# 注意：请不要在电脑上用记事本等工具编辑本脚本——Windows 存成 CRLF 后，POSIX sh
# （toybox/dash）会在 `set -u` 一行直接报 "Illegal option" 而无法运行，脚本自身无法可靠
# 自修复换行。测试者只需编辑采集结果里的 MANUAL.txt（其换行格式无影响）。

set -u

# ---- MT 管理器运行环境适配 ----
# 少数 shell 的 PATH 不含 /system/bin，只在探测不到工具时补齐，不覆盖原有 PATH。
if ! command -v -- getprop >/dev/null 2>&1; then
	PATH="${PATH:-}:/system/bin:/system/xbin:/vendor/bin:/sbin"
	export PATH
fi

# 非 root 时先尝试 su 提权（仍然只跑只读命令，可能弹 Root 授权框）；
# --no-root 与 TRACE_SU_TRIES 双保险，避免提权失败时无限递归；仅 Android 环境尝试。
case " $* " in
*" --no-root "*) : ;;
*)
	if [ -e /system/bin/sh ] && [ -z "${TRACE_NO_SU:-}" ] &&
		[ "$(id -u 2>/dev/null)" != "0" ] && command -v su >/dev/null 2>&1 &&
		[ "${TRACE_SU_TRIES:-0}" -lt 1 ]; then
		printf '当前非 root，尝试 su 提权后重新取证（只读命令，请注意 Root 授权弹窗）...\n'
		export TRACE_SU_TRIES=1
		if su -c 'sh "$@" --no-root' su "$0" "$@"; then
			exit 0
		fi
		printf 'su 提权未成功，改以当前权限继续（logcat 等项会标注缺失，不影响打包）。\n' >&2
	fi
	;;
esac

TRACE_VERSION='2026.09.30-7'

# ---------------------------------------------------------------- 参数解析
TAG='now'
PACK_ONLY=0
TRACE_OUT=''
NO_PAUSE=0
# 默认全量自动（面向远端测试者）：能自动触发的都自动触发，不要求任何人记流程。
AUTO=1
USB_PROBE=0
HEAVY=1
SCENARIO_SECS=60
TICK_INTERVAL=5
MAX_LOG_MB=120
FILTER_MAX_LINES=400
GRAB_MAX_KB=2048
ONLY='audio,face,nfc,xiaoai'
ONLY_DEFAULT=1
ON_AUDIO=0
ON_FACE=0
ON_NFC=0
ON_XIAOAI=0
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
		TRACE_OUT="$1"
		;;
	--only | -s)
		shift
		[ "$#" -gt 0 ] || { echo '缺少 --only 参数值' >&2; exit 2; }
		ONLY="$1"
		ONLY_DEFAULT=0
		;;
	--secs)
		shift
		[ "$#" -gt 0 ] || { echo '缺少 --secs 秒数' >&2; exit 2; }
		SCENARIO_SECS="$1"
		;;
	--interval)
		shift
		[ "$#" -gt 0 ] || { echo '缺少 --interval 秒数' >&2; exit 2; }
		TICK_INTERVAL="$1"
		;;
	--max-log-mb)
		shift
		[ "$#" -gt 0 ] || { echo '缺少 --max-log-mb 数值' >&2; exit 2; }
		MAX_LOG_MB="$1"
		;;
	--filter-lines)
		shift
		[ "$#" -gt 0 ] || { echo '缺少 --filter-lines 数值' >&2; exit 2; }
		FILTER_MAX_LINES="$1"
		;;
	--pack)
		PACK_ONLY=1
		;;
	--no-heavy)
		HEAVY=0
		;;
	--no-root)
		# 由 su 提权重启时注入，阻断再次提权的递归标记。
		;;
	--no-pause)
		NO_PAUSE=1
		;;
	--auto)
		AUTO=1
		;;
	--force-usb-probe)
		# 即使在 adbd 会话下也强制切 USB（会掉线，仅维护者知道后果时用）。
		USB_PROBE=1
		;;
	--no-auto)
		# 只读模式：不触发任何探针、不改设备状态（维护者自己跑时用）。
		AUTO=0
		;;
	--full)
		# 远端测试者的一键全量采集：自动探针 + 重项 + 四场景 + 加长窗口。
		AUTO=1
		HEAVY=1
		SCENARIO_SECS=60
		TICK_INTERVAL=5
		ONLY='audio,face,nfc,xiaoai'
		ONLY_DEFAULT=0
		;;
	-h | --help)
		echo '用法: sh issue_trace.sh [--tag 标签] [--out 目录] [--secs 秒] [--interval 秒]'
		echo '                [场景...] [--no-auto] [--no-pause] [--no-heavy] [--max-log-mb N] [--pack]'
		echo '  不加任何参数 = 远端测试者用法：全量自动采集，zip 落在 /sdcard/Download'
		echo '  --no-auto   只读模式（不触发探针、不改设备状态）'
		echo '  --force-usb-probe  adbd 会话下也强制切 USB（会重启 adbd 并可能杀死采集）'
		echo '  --no-pause  跳过复现窗口，只取静态快照（最快）'
		echo '  --no-heavy  跳过 ANR / tombstone / dmesg / meminfo / top 等重项'
		echo '  --pack      只把上次结果与已编辑的 MANUAL.txt 重新打包'
		echo '  场景       audio|face|nfc|xiaoai（可逗号分隔或写成位置参数）'
		exit 0
		;;
	-*)
		echo "未知选项: $1" >&2
		exit 2
		;;
	*)
		# 位置参数也是场景名：只有用户没显式指定过场景时才覆盖默认的全集。
		if [ "$ONLY_DEFAULT" -eq 1 ]; then ONLY="$1"; else ONLY="$ONLY,$1"; fi
		ONLY_DEFAULT=0
		;;
	esac
	shift
done

case "$ONLY" in *audio*) ON_AUDIO=1 ;; esac
case "$ONLY" in *face*) ON_FACE=1 ;; esac
case "$ONLY" in *nfc*) ON_NFC=1 ;; esac
case "$ONLY" in *xiaoai*) ON_XIAOAI=1 ;; esac
if [ "$ON_AUDIO" -eq 0 ] && [ "$ON_FACE" -eq 0 ] && [ "$ON_NFC" -eq 0 ] && [ "$ON_XIAOAI" -eq 0 ]; then
	echo 'FAIL: --only 里没有可识别场景（audio/face/nfc/xiaoai）。' >&2
	exit 2
fi

# 数值参数兜底：越界或非法一律回到安全默认，不接受空串参与算术。
num_or() {
	case "$1" in
	'' | *[!0-9]*) printf '%s\n' "$2" ;;
	*) printf '%s\n' "$1" ;;
	esac
}
SCENARIO_SECS=$(num_or "$SCENARIO_SECS" 60)
[ "$SCENARIO_SECS" -gt 0 ] || SCENARIO_SECS=5
[ "$SCENARIO_SECS" -le 600 ] || SCENARIO_SECS=600
TICK_INTERVAL=$(num_or "$TICK_INTERVAL" 5)
[ "$TICK_INTERVAL" -ge 2 ] || TICK_INTERVAL=5
[ "$TICK_INTERVAL" -le 60 ] || TICK_INTERVAL=60
MAX_LOG_MB=$(num_or "$MAX_LOG_MB" 120)
[ "$MAX_LOG_MB" -ge 20 ] || MAX_LOG_MB=20
FILTER_MAX_LINES=$(num_or "$FILTER_MAX_LINES" 400)
[ "$FILTER_MAX_LINES" -ge 20 ] || FILTER_MAX_LINES=400

# 标签只允许安全字符，并去掉开头的 - . 等，避免拼成选项或隐藏路径。
TAG_CLEAN=$(printf '%s' "$TAG" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//')
[ -n "$TAG_CLEAN" ] || TAG_CLEAN='now'

# 候选输出位置：优先上次取证目录，再退到测试者最容易回传的 Download 目录。
# HOME 在部分 root shell 里未设置（set -u 会直接中断），因此先条件拼接。
# 输出候选：下载目录优先（让测试者不用找文件），其次设备内公共目录；不再用 $PWD/HOME，
# 避免包落在 /data/local/tmp 之类他找不到的地方。
TRACE_CANDIDATES="/sdcard/Download /storage/emulated/0/Download /data/local/tmp /tmp"
trace_home="${HOME:-}"
HOME_CANDIDATES=''
[ -n "$trace_home" ] && HOME_CANDIDATES="$trace_home/Downloads $trace_home"

# 取证目录定位：MARKER_NAME 区分本脚本生成的目录；POINTER_NAME 记下上次绝对路径，
# 让第二次只带 --pack（忘了 --out）也能打到同一个包。
MARKER_NAME='.trace_dir'
POINTER_NAME=".issue_trace_${TAG_CLEAN}.last"
LAST_DIR=''
for trace_base in "${TRACE_OUT:-}" "$PWD" $HOME_CANDIDATES $TRACE_CANDIDATES; do
	[ -n "$trace_base" ] || continue
	[ -f "$trace_base/$POINTER_NAME" ] || continue
	guess=$(head -n 1 -- "$trace_base/$POINTER_NAME" 2>/dev/null)
	[ -n "$guess" ] && [ -f "$guess/$MARKER_NAME" ] || continue
	LAST_DIR="$guess"
	break
done
if [ -z "$LAST_DIR" ]; then
	for trace_base in "${TRACE_OUT:-}" "$PWD" $HOME_CANDIDATES $TRACE_CANDIDATES; do
		[ -n "$trace_base" ] || continue
		guess="$trace_base/issue_trace_${TAG_CLEAN}"
		[ -f "$guess/$MARKER_NAME" ] || continue
		LAST_DIR="$guess"
		break
	done
fi

if [ "$PACK_ONLY" -eq 1 ]; then
	if [ -z "$LAST_DIR" ]; then
		echo 'FAIL: 没找到可打包的取证目录。请先不带 --pack 跑一次，' >&2
		echo '      或用与首次一致的 --out 目录重试：sh issue_trace.sh --out /sdcard/Download --pack' >&2
		exit 1
	fi
	TRACE_DIR="$LAST_DIR"
	# --pack 也要给 CAP 赋值：下面几个路径变量是无条件展开的，set -u 下不能留空。
	CAP="$TRACE_DIR/captures"
else
	ensure_dir() {
		[ -n "$TRACE_DIR" ] && return 0
		[ -n "$1" ] || return 0
		mkdir -p -- "$1" 2>/dev/null || return 0
		touch -- "$1/.trace_write_test" 2>/dev/null || return 0
		rm -f -- "$1/.trace_write_test" 2>/dev/null
		TRACE_DIR="$1"
		return 0
	}
	TRACE_DIR=''
	ensure_dir "${LAST_DIR:-${TRACE_OUT:-/sdcard/Download}/issue_trace_${TAG_CLEAN}}"
	for cand in $TRACE_CANDIDATES; do
		[ -n "$TRACE_DIR" ] && break
		ensure_dir "$cand/issue_trace_${TAG_CLEAN}"
	done
	[ -n "$TRACE_DIR" ] || { echo 'FAIL: 找不到可写输出目录，请用 --out 指定。' >&2; exit 1; }
	printf '%s\n' "$(basename -- "$TRACE_DIR")" >"$TRACE_DIR/$MARKER_NAME" 2>/dev/null
	# 在采集目录的上级与手机端 Download 留一份绝对路径指针（写不了就跳过，不影响采集）；
	# 不写 $PWD，避免维护者在仓库里试跑时把指针文件留在工作树根目录。
	for pointer_base in "$(dirname -- "$TRACE_DIR")" /sdcard/Download; do
		[ -d "$pointer_base" ] && [ -w "$pointer_base" ] || continue
		printf '%s\n' "$TRACE_DIR" >"$pointer_base/$POINTER_NAME" 2>/dev/null
	done

	CAP="$TRACE_DIR/captures"
	mkdir -p -- "$CAP"
fi

LIVE_LOG="$CAP/90_logcat_live.txt"
TICKS="$CAP/91_ticks.txt"
STOP_FLAG="$CAP/.stop_ticks"
LOG_PID=''
TICK_PID=''
PROBE_STATE_SAVED=''
PROBE_NFC_ORIG=''
PROBE_USB_ORIG=''
PROBE_USB_SWITCHED=0

# ---------------------------------------------------------------- 采集原语
has() {
	command -v -- "$1" >/dev/null 2>&1
}

now_ts() {
	if has date; then date '+%m-%d %H:%M:%S'; else printf '时间不可用\n'; fi
}

# 交互窗口前的提示：--no-pause 或秒数为 0 时返回 1，调用方降级为单次快照。
pause_for() {
	[ "$NO_PAUSE" -eq 1 ] && return 1
	[ "$SCENARIO_SECS" -gt 0 ] || return 1
	printf '%s\n' "$1"
	has sleep || return 1
	sleep "$SCENARIO_SECS"
	return 0
}

# 把一扇窗口拆成两段（一个场景里要先后做两件事时用）；--no-pause 时同样返回 1。
sleep_for() {
	secs="$1"
	[ "$NO_PAUSE" -eq 0 ] || return 1
	[ "$secs" -gt 0 ] || return 1
	printf '%s\n' "$2"
	has sleep || return 1
	sleep "$secs"
	return 0
}

# ---- 自动探针（仅 --auto）----
# 向 logcat 打一条带 PROBE 标记的时间线，方便事后把现象与动作对齐（没有 log 命令时只记文件）。
probe_mark() {
	printf '%s PROBE %s\n' "$(now_ts)" "$*" >>"$CAP/97_probe_log.txt" 2>/dev/null
	if has log; then
		log -p i -t ISSUE_TRACE "PROBE $*" 2>/dev/null
	fi
	printf '  [%s] %s\n' "$(now_ts)" "$*"
}

# 执行一条探针动作并记录结果；命令缺失不会让整个取证失败。
probe_do() {
	probe_mark "do: $*"
	# 不用 timeout 包裹：toybox timeout 超时会向子进程所在**进程组**发信号，而后台任务与本脚本同组，
	# 实测会把整个采集自杀（EXIT trap 收到 rc=143）。需要阻塞防护时只能避开会卡死的命令。
	"$@" >/dev/null 2>&1 || probe_mark "skip(命令失败或缺失): $*"
}

# 探针类取数统一走这两个入口，便于集中控制“哪些命令允许在探针里跑”。
# 已确认禁用：`svc usb setFunctions`（USB 重配期间永久阻塞）、`cmd usb set-functions`（本 ROM 未实现）。
dsys() {
	dumpsys "$@" 2>/dev/null
}

qset() {
	settings "$@" 2>/dev/null
}

# 第一次需要改状态时记下原值，结束时尽量还原。
probe_save_state() {
	[ "$AUTO" -eq 1 ] || return 0
	[ -n "${PROBE_STATE_SAVED:-}" ] && return 0
	PROBE_STATE_SAVED=1
	PROBE_NFC_ORIG=$(settings get secure nfc_on 2>/dev/null)
	PROBE_USB_ORIG=$(getprop sys.usb.config 2>/dev/null)
	{
		printf 'nfc_on=%s\nusb_config=%s\n' "${PROBE_NFC_ORIG:-null}" "${PROBE_USB_ORIG:-空}"
	} >>"$CAP/97_probe_log.txt" 2>/dev/null
	probe_mark "save nfc_on=${PROBE_NFC_ORIG:-null} usb=${PROBE_USB_ORIG:-空}"
}

probe_restore_state() {
	[ "$AUTO" -eq 1 ] || return 0
	[ -n "${PROBE_STATE_SAVED:-}" ] || return 0
	probe_mark "restore begin"
	if [ "${PROBE_NFC_ORIG:-}" = "1" ]; then
		probe_do svc nfc enable
	elif [ "${PROBE_NFC_ORIG:-}" = "0" ]; then
		probe_do svc nfc disable
	fi
	# 只有真的切换过 USB 才需要还原；没切过就去 set-functions/reset 反而会改变用户原有状态。
	if [ "${PROBE_USB_SWITCHED:-0}" = "1" ]; then
		# 还原到原功能列表本身（sys.usb.config 是逗号列表，set-functions 要空格分隔的多个参数）；
		# 以前只拍成 adb，会让测试者丢掉 MTP 直到重启。
		if [ -n "${PROBE_USB_ORIG:-}" ]; then
			# 直接写回原逗号列表（实测 setprop 可用，不需要拆成多个参数）。
			probe_do setprop sys.usb.config "$PROBE_USB_ORIG"
		else
			probe_do cmd usb reset
		fi
	else
		probe_mark 'skip usb restore：本次未切换过 USB'
	fi
	probe_mark "restore done"
}

# 把关键计数拍成快照（远端测试者不会报数字，accept/reject 等只差靠前后两次快照相减）。
probe_snapshot() {
	[ "$AUTO" -eq 1 ] || return 0
	{
		printf '\n===== PROBE SNAPSHOT %s @ %s =====\n' "$1" "$(now_ts)"
		printf 'face: %s\n' "$(dsys face | grep -a -m1 -a prints | tr -d '\r')"
		printf 'bio_last: %s\n' "$(dsys biometric | grep -a -E 'authEnded' | tail -n 3 | tr '\n' '|')"
		printf 'nfc: %s | reader=%s | secure=%s\n' \
			"$(dsys nfc | grep -a -m1 -aE '^mState=')" \
			"$(qset get secure nfc_on)" \
			"$(qset get secure nfc_payment_confirm_mode)"
		printf 'usb: state=%s config=%s mtp_proc=%s\n' \
			"$(getprop sys.usb.state)" "$(getprop sys.usb.config)" "$(pidof com.android.mtp 2>/dev/null)"
		printf 'audio_svc: audioserver=%s audio_hal=%s iorapd=%s qguard=%s\n' \
			"$(pidof_one 'audioserver')" "$(pidof_one 'android.hardware.audio.service-aidl android.hardware.audio.service audiohalservice.qti')" \
			"$(getprop init.svc.iorapd 2>/dev/null)" "$(getprop init.svc.qguard 2>/dev/null)"
		printf 'vt: pid=%s dt2w=%s\n' "$(pidof_one 'com.miui.voicetrigger')" "$(qset get secure double_tap_to_wake)"
		true
	} >>"$CAP/98_auto_state.txt" 2>&1
}

# 由 qguard 链接失败与 syshealthmon SIGSYS 的时间戳算重拉间隔：固定周期（如 5s）即崩溃环。
crash_loop_analysis() {
	grep -a -E 'CANNOT LINK EXECUTABLE .*/vendor/bin/qguard|syshealthmon-service.*SIGSYS' "$LIVE_LOG" 2>/dev/null |
		awk '
			{
				split($2, t, ":")
				s = t[1] * 3600 + t[2] * 60 + t[3]
				if (prev != "") {
					d = s - prev
					if (d >= 0 && d < 240) { n++; sum += d; if (mn == 0 || d < mn) mn = d; if (d > mx) mx = d }
				}
				prev = s
			}
			END {
				if (n) printf "崩溃重拉 %d 个间隔样本，均值 %.1fs 最小 %ds 最大 %ds（≈固定周期重启环）", n, sum / n, mn, mx
				else print "未采到两次以上样本（窗口太短或环已停）"
			}
		'
}

# 某关键字在本窗口内的“每分钟命中节律”：固定秒级周期（如 10-12 次/分钟）就是循环重试，
# 单看总次数会把“窗口短”误读成“没问题”。
# 注意：90_logcat_live.txt 开头是环形缓冲里的历史（实测可比本次窗口早一小时），因此必须按
# tick 首尾时间限窗计数，否则会出现“460 次/分”这种荒谬值。
tick_time_of() {
	# 从第一个/最后一个 TICK 头里取 HH:MM:SS。
	grep -a -E '^===== TICK' "$TICKS" 2>/dev/null | awk -v want="$1" 'NR==1{k=$0} END{if(want=="last")print $0; else print k}' | awk '{print $(NF-1)}'
}

count_in_window() {
	ciw_pat="$1"
	ciw_from="${TICK_FROM:-}"
	if [ -z "$ciw_from" ]; then
		count_of "$ciw_pat" "$LIVE_LOG"
		return
	fi
	ciw_n=$(awk -v from="$ciw_from" 'NF >= 3 && $2 >= from' "$LIVE_LOG" 2>/dev/null |
		grep -a -v -E 'adbd|issue_trace' | grep -a -c -E -- "$ciw_pat")
	printf '%s\n' "${ciw_n:-0}"
}

loop_cadence() {
	lc_pattern="$1"
	lc_minutes="${TICK_MINUTES:-1}"
	lc_hits=$(count_in_window "$lc_pattern")
	[ "${lc_minutes:-0}" -gt 0 ] || lc_minutes=1
	awk -v h="$lc_hits" -v m="$lc_minutes" 'BEGIN{printf "%s 次/%d 分钟窗口内（%.1f 次/分）", h, m, h / m}'
}

# 判断本脚本是否跑在 adbd 派生的 shell 里：切换 USB 功能会重启 adbd，并连带杀死采集进程，
# 因此 adb 会话下默认跳过 USB 探针（MT 本地执行不受影响）。
under_adbd() {
	ua_pid=$$
	ua_i=0
	while [ -n "$ua_pid" ] && [ "$ua_pid" != "1" ] && [ "$ua_i" -lt 12 ]; do
		ua_cmd=$(tr '\0' ' ' <"/proc/$ua_pid/cmdline" 2>/dev/null)
		case "$ua_cmd" in
		*adbd*) return 0 ;;
		esac
		ua_ppid=$(sed -n 's/^.*) [A-Za-z] \([0-9]*\).*/\1/p' "/proc/$ua_pid/stat" 2>/dev/null)
		[ -n "$ua_ppid" ] || break
		ua_pid="$ua_ppid"
		ua_i=$((ua_i + 1))
	done
	return 1
}

# 执行命令并把 stdout+stderr 记进采集文件；命令缺失时明确标注，不静默跳过。
cap() {
	out="$CAP/$1"
	shift
	printf '\n===== [%s] $ %s =====\n' "$(now_ts)" "$*" >>"$out"
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
	printf '\n===== [%s] $ %s (前 %s 行) =====\n' "$(now_ts)" "$*" "$n" >>"$out"
	if has "$1"; then
		"$@" 2>>"$out" | head -n "$n" >>"$out" 2>&1
	else
		printf '===== [MISSING] %s 不存在 =====\n' "$1" >>"$out"
	fi
}

# 在已采集文件里按扩展正则筛行。必须限行：对几十 MB 连续日志跑宽正则（如 PAL:）会生成
# 几百 MB 中间文件，既吃光 /sdcard 也会被 zip 漏掉，这里只留前 N 行并给出总命中数。
capfilter() {
	pattern="$1"
	src="$CAP/$2"
	dst="$CAP/$3"
	printf '\n===== 过滤 /%s/ 自 %s（前 %s 行）=====\n' "$pattern" "$2" "$FILTER_MAX_LINES" >>"$dst"
	if has grep && [ -f "$src" ]; then
		total=$(grep -a -c -E -i -- "$pattern" "$src" 2>/dev/null)
		printf 'FILTER_TOTAL_MATCHES=%s\n' "${total:-0}" >>"$dst"
		grep -E -i -- "$pattern" "$src" 2>/dev/null | head -n "$FILTER_MAX_LINES" >>"$dst" 2>&1
		[ "${total:-0}" -gt 0 ] || printf '(无匹配行)\n' >>"$dst"
	else
		printf '===== [SKIP] 缺少 grep 或源文件 =====\n' >>"$dst"
	fi
}

# 从已采集的 getprop 全文里取一个属性值（SUMMARY 用）。
prop_val() {
	grep -m1 -E "^\\[$1\\]:" "$CAP/01_getprop.txt" 2>/dev/null | sed 's/^[^:]*: //' | tr -d '[]'
}

# 只在取值非空时打印一行，避免 SUMMARY 里堆一排「未读到」噪声。
prop_line() {
	v=$(prop_val "$1")
	[ -n "$v" ] || return 0
	printf '%s %s = %s\n' "${2:-}" "$1" "$v"
}

count_of() {
	# 在文件里数一个 ERE 的命中行数，无匹配/缺文件都返回 0。
	# 先去掉 adbd 行：本脚本若被 adb shell 驱动，adbd 会把整条命令回显进日志，带关键字的自回显会造假命中。
	if has grep && [ -f "$2" ]; then
		n=$(grep -a -v -E '(^|[^[:alnum:]])adbd([[:space:]]|:|$)' "$2" 2>/dev/null | grep -a -c -E -- "$1")
		printf '%s\n' "${n:-0}"
	else
		printf '0\n'
	fi
}

# 把设备上的诊断文件收进 captures/（zz_ 前缀，只在 --no-heavy 未指定时做）。
# 超大文件只取尾部——ANR 与 tombstone 的有效信息通常在头尾。
grab_file() {
	name="$1"
	src="$2"
	[ "$HEAVY" -eq 1 ] || return 0
	[ -n "$src" ] && [ -r "$src" ] || return 0
	out="$CAP/zz_${name}"
	size=$(wc -c <"$src" 2>/dev/null)
	[ -n "$size" ] || size=0
	{
		printf '##### 来源 %s（%s 字节）#####\n' "$src" "$size"
		if [ "$size" -gt $((GRAB_MAX_KB * 1024)) ]; then
			printf '##### 超过 %s KB，只取尾部 #####\n' "$GRAB_MAX_KB"
			tail -c $((GRAB_MAX_KB * 1024)) -- "$src"
		else
			cat -- "$src"
		fi
		true
	} >>"$out" 2>&1
}

# 记录路径存在性与权限；目录额外列条目。
# shellcheck disable=SC2012 # 下面的路径都是设备上的固定系统目录，不含任意用户输入文件名。
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

# /proc/<pid>/stat 的 14+15 字段（utime+stime，单位 jiffies）。
# 只对进程名不含空格的系统进程与包名进程使用；comm 含空格时字段会整体偏移（取不到就标 N/A）。
cpu_jiffies() {
	pid="$1"
	[ -n "$pid" ] || { printf 'N/A\n'; return; }
	[ -r "/proc/$pid/stat" ] || { printf 'N/A\n'; return; }
	awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || printf 'N/A\n'
}

rss_kb() {
	pid="$1"
	[ -n "$pid" ] || { printf 'N/A\n'; return; }
	[ -r "/proc/$pid/status" ] || { printf 'N/A\n'; return; }
	awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || printf 'N/A\n'
}

pidof_one() {
	# pidof 在多进程名时返回多个，取第一个；都取不到时用 ps 兜底。
	names="$1"
	# shellcheck disable=SC2086 # $names 是本脚本内写死的空格分隔进程名列表，故意展开为多项。
	for n in $names; do
		if has pidof; then
			p=$(pidof "$n" 2>/dev/null | tr ' ' '\n' | head -n 1)
			[ -n "$p" ] && { printf '%s\n' "$p"; return; }
		fi
	done
	# 兜底用固定串匹配（进程名里的点不能当正则元字符），取第一个命中行的 PID。
	# shellcheck disable=SC2009 # toybox 上 pgrep 不一定可用，ps -A 是唯一稳定兜底。
	for n in $names; do
		# shellcheck disable=SC2086
		p=$(ps -A 2>/dev/null | grep -a -F -- "$n" | awk 'NR==1{print $1}')
		[ -n "$p" ] && { printf '%s\n' "$p"; return; }
	done
	printf '\n'
}

# ---------------------------------------------------------------- 连续取证引擎
log_start() {
	: >"$LIVE_LOG"
	if ! has logcat; then
		printf '[MISSING] logcat 不存在（多半是非 root），无法连续取证。\n' >>"$LIVE_LOG"
		return 1
	fi
	printf '启动连续 logcat（全部 buffer，threadtime）...\n'
	# 缓冲区现状先记一笔：如果 log buffer 被 ROM 调小，事后取样会自相矛盾，这里能看出来。
	cap 00_meta.txt sh -c 'logcat -g 2>&1 | head -n 20'
	logcat -b all -v threadtime >"$LIVE_LOG" 2>>"$CAP/99_notes.txt" &
	LOG_PID=$!
	return 0
}

# 回收后台进程：本机实测——主 shell 直接 kill 自己的同组后台子进程（无论内建 kill 还是 /system/bin/kill）
# 都会让主脚本自己收到 SIGTERM 而退出，“Terminated”后收尾全部作废。
# 因此：① tick 循环靠 STOP_FLAG 自行退出（不杀）；② 必须杀的（logcat）交给 setsid 脱离的 helper 执行，
# 主进程只做有界等待，绝不 wait、也不从自身发信号。
stop_pid() {
	sp_pid="${1:-}"
	[ -n "$sp_pid" ] || return 0
	if has setsid; then
		setsid sh -c "kill -TERM $sp_pid 2>/dev/null; sleep 2; kill -9 $sp_pid 2>/dev/null" >/dev/null 2>&1 &
		sp_i=0
		while [ "$sp_i" -lt 4 ]; do
			sleep 1
			sp_i=$((sp_i + 1))
		done
		return 0
	fi
	# 没有 setsid 时的退化路径（仍有自杀风险，但至少能回收进程）。
	kill -TERM "$sp_pid" 2>/dev/null
	sleep 2
	kill -9 "$sp_pid" 2>/dev/null || true
	return 0
}

log_stop() {
	[ -n "$LOG_PID" ] || return 0
	stop_pid "$LOG_PID"
	LOG_PID=''
}

tick_stop() {
	[ -n "$TICK_PID" ] || return 0
	# 先只置标志位让它自己退出（实测这一步不会伤到主脚本），再兼顾兜底回收。
	touch -- "$STOP_FLAG" 2>/dev/null
	sp_i=0
	while [ "$sp_i" -lt 7 ]; do
		sleep 1
		sp_i=$((sp_i + 1))
	done
	stop_pid "$TICK_PID"
	TICK_PID=''
	rm -f -- "$STOP_FLAG" 2>/dev/null
}

# 任何退出路径都要回收两个后台进程，避免残留 logcat 持续吃 CPU。
cleanup() {
	log_stop
	tick_stop
	# 收尾阶段被信号打断时也要把已写出的 SUMMARY/zip 留在原地，不重试清理。
	return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 一次时间轴快照：所有行都带同一时间戳，便于与 90_logcat_live.txt 对齐。
tick() {
	which="$1"
	ts=$(now_ts)
	af=$(pidof_one 'audioserver')
	hal=$(pidof_one 'android.hardware.audio.service-aidl android.hardware.audio.service audiohalservice.qti audio-hal')
	st=$(pidof_one 'android.hardware.soundtrigger@2.0-service android.hardware.soundtrigger@2.1_2.3-service vendor.qti.hardware.AGMIPC audiohalservice.qti')
	vt=$(pidof_one 'com.miui.voicetrigger')
	as=$(pidof_one 'com.miui.voiceassist')
	ss=$(pidof_one 'system_server')
	load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
	log_kb=$(wc -c <"$LIVE_LOG" 2>/dev/null)
	[ -n "$log_kb" ] || log_kb=0
	log_mb=$((log_kb / 1024 / 1024))
	{
		printf '\n===== TICK[%s] %s =====\n' "$which" "$ts"
		printf 'TICK load=%s log_mb=%s\n' "${load:-不可读}" "$log_mb"
		printf 'TICK pid audioserver=%s audio_hal=%s soundtrigger=%s system_server=%s\n' \
			"${af:-无}" "${hal:-无}" "${st:-无}" "${ss:-无}"
		printf 'TICK pid voicetrigger=%s voiceassist=%s\n' "${vt:-无}" "${as:-无}"
		printf 'TICK cpu_jiffies voicetrigger=%s voiceassist=%s (100 jiffies≈1 秒 CPU)\n' \
			"$(cpu_jiffies "$vt")" "$(cpu_jiffies "$as")"
	# 取证干扰自测：load 高时先查这一行，别把脚本自己的 grep/dumpsys 当成系统负载。
	printf 'TICK self trace_procs=%s top3=%s\n' \
		"$(ps -A -o NAME 2>/dev/null | grep -a -c -E '^(grep|dumpsys|top|logcat|tombstoned)$')" \
		"$(top -b -n 1 -m 6 2>/dev/null | awk 'NR>7 && $9+0>0 {printf "%s:%s ", $NF, $9}' | head -c 120)"
		printf 'TICK rss_kb voicetrigger=%s audioserver=%s\n' \
			"$(rss_kb "$vt")" "$(rss_kb "$af")"
		# shellcheck disable=SC2009 # 这里要的是 pid 与进程名的对应关系（发现服务重启），pgrep 不一定可用。
		procs=$(ps -A -o PID,NAME 2>/dev/null | grep -a -i audio | awk '{printf "%s:%s ", $1, $2}' | head -c 300)
		# shellcheck disable=SC2009 # 同上，-o 取不到时的兜底列布局。
		[ -n "$procs" ] || procs=$(ps -A 2>/dev/null | grep -a -i audio | awk '{printf "%s:%s ", $1, $NF}' | head -c 300)
		printf 'TICK audio_procs=%s\n' "${procs:-无}"
		if has dumpsys; then
			# 关键三点：pid 是否变化（服务重启）、underrun 是否增长（供数不足）、audio mode/路由是否被改写。
			dumpsys media.audio_flinger 2>/dev/null |
				grep -a -i -E 'underrun|noise|standby|mInputTh|HAL |mScreenOnState|mLastAudible|out of sync|BUFFER TIMEOUT' |
				head -n 12
			dumpsys audio 2>/dev/null |
				grep -a -i -E 'mode=|mMode|mDevice|device |Available devices|players|AudioDeviceInventory|setPhoneState|mAudioSystemReady' |
				head -n 12
		fi
		# 声卡是否在跑：pcm 状态里同时出现 RUNNING/PREPARED 说明放音与采集并发。
		for f in /proc/asound/card*/pcm*p/sub*/status /proc/asound/card*/pcm*c*/sub*/status; do
			[ -r "$f" ] || continue
			printf 'TICK PCM %s : %s\n' "$f" "$(head -n 2 "$f" 2>/dev/null | tr '\n' ' ')"
		done
	} >>"$TICKS" 2>&1
	# 日志体积兜底：超限就提前收尾，别把 /sdcard 写满。
	if [ "$log_mb" -ge "$MAX_LOG_MB" ]; then
		printf '\n[TRUNCATED] 连续日志超过 %s MB，停止写入；后续场景改用设备缓冲区增量取。\n' "$MAX_LOG_MB" >>"$LIVE_LOG"
		log_stop
	fi
}

ticks_start() {
	: >"$TICKS"
	rm -f -- "$STOP_FLAG" 2>/dev/null
	if ! has sleep; then
		printf '[SKIP] 设备上没有 sleep，无法做周期采样。\n' >>"$TICKS"
		return 1
	fi
	printf '启动周期性状态快照（每 %s 秒一次）...\n' "$TICK_INTERVAL"
	(
		i=0
		while [ ! -f "$STOP_FLAG" ]; do
			i=$((i + 1))
			tick "s$i"
			sleep "$TICK_INTERVAL"
		done
	) &
	TICK_PID=$!
	return 0
}

# 从当前连续日志里取「窗口内新增」部分，按标签筛，并给出定量行。
# 用法：sample_window <目标文件> <标签> <正则> <说明> <窗口前行数> <窗口起始时间>
# 连续采集还在跑时按行数取增量；一旦被体积上限提前关掉（LOG_PID 已空），改从设备缓冲区
# 按起始时间取，后面的场景不会因为日志提前截断而拿到空窗口。
sample_window() {
	dst="$CAP/$1"
	label="$2"
	pattern="$3"
	hint="$4"
	before="$5"
	start_ts="$6"
	{
		printf '\n===== [%s] %s =====\n' "$(now_ts)" "$hint"
		tmp="$CAP/.win.tmp"
		src=''
		if ! has logcat; then
			printf '%s_SAMPLE unavailable（设备上没有 logcat，确认是否 root）\n' "$label"
		elif [ -n "$LOG_PID" ] && has tail; then
			tail -n "+$((before + 1))" -- "$LIVE_LOG" >"$tmp" 2>/dev/null
			src=live_tail
		else
			if logcat -d -T "$start_ts" >"$tmp" 2>/dev/null; then
				src=buffer_since
			else
				logcat -d >"$tmp" 2>/dev/null
				src=buffer_full
			fi
			printf '%s_SAMPLE 备注：连续采集已提前停止（撞体积上限），改取设备缓冲区增量\n' "$label"
		fi
		if [ -n "$src" ]; then
			new=$(wc -l <"$tmp" 2>/dev/null | tr -d ' ')
			hits=$(grep -a -i -E -- "$pattern" "$tmp" 2>/dev/null | head -n 300)
			printf '%s_SAMPLE src=%s new_lines=%s baseline=%s hits=%s\n' \
				"$label" "$src" "${new:-0}" "$before" "$(printf '%s' "$hits" | grep -c .)"
			printf '%s\n' "$hits"
			rm -f -- "$tmp"
		fi
	} >>"$dst" 2>&1
}

# 单趟 awk 把连续日志切成五个主题桶（每桶限行）：对几十 MB 日志跑 6 遍 grep 在手机上有
# 分钟级开销，曾经因此让尾段没跑完就被回传。切片总命中数同时写入每桶开头。
slice_log() {
	if ! has awk || [ ! -s "$LIVE_LOG" ]; then
		printf '%s\n' '[SKIP] 缺少 awk 或连续日志为空，未生成主题切片。' >>"$CAP/92_audio_log.txt"
		return 0
	fi
	awk -v cap="$FILTER_MAX_LINES" -v dir="$CAP" '
		BEGIN {
			audio_n = kws_n = face_n = nfc_n = avc_n = bad_n = 0
			audio_w = kws_w = face_w = nfc_w = avc_w = bad_w = 0
			audio = "appname=|Bad parameter|BAD_VALUE|underrun|out of sync|BUFFER TIMEOUT|AudioFlinger|audioserver|audiohal|audio-hal|HAL instance died|HAL driver died|PAL:|AGM:|StreamHal|EffectsFactoryHalAidl|could not create effect|parseAndSetVendorParameters|checkAndSetVolume|MiSound|Spatializer|ctl.interface_start"
			kws = "STHAL|SoundTrigger|LOAD_PHRASE_MODEL|START_RECOGNITION|status = -22|createMmapBuffer|gsl_|set_custom_config|nonpersist|AudioFlow|FlexKws|voiceassist|voicetrigger|get tags from gkv"
			face = "FaceService|FaceManager|Biometric|AuthSession|oiface|oplusoiface|miface|face_hal|setAuthenticator|resetAuthentication|wasSuccessful|hal_face_oplus"
			nfc = "NfcService|NfaNfc|nfc_nci|nci_rx|nci_tx|rfintf|NfcTag|NfcDispatcher|SecureElement|secure_element|getMIID|tms_nfc|st21nfc|startRfDiscovery|enableDiscovery|setReaderMode"
			bad = "Fatal signal|beginning of crash|libc +:|DEBUG +:|tombstone|SIGSEGV|SIGABRT|SIGSYS|CANNOT LINK|updatable_crashing|has died|qguard|syshealthmon|Watchdog|ANR |received SIGKILL"
		}
		{
			line = $0
			# 不用 [[:space:]]：mawk 与部分 toybox awk 不识别 POSIX 字符类，会静默漏判 avc 桶。
			if (line ~ /avc:[ \t]*[Dd]enied/) {
				avc_n++
				if (avc_w < cap) { print line > (dir "/93_avc_log.txt"); avc_w++ }
			}
			if (line ~ audio) { audio_n++; if (audio_w < cap) { print line > (dir "/92_audio_log.txt"); audio_w++ } }
			if (line ~ kws) { kws_n++; if (kws_w < cap) { print line > (dir "/92_xiaoai_log.txt"); kws_w++ } }
			if (line ~ face) { face_n++; if (face_w < cap) { print line > (dir "/92_face_log.txt"); face_w++ } }
			if (line ~ nfc) { nfc_n++; if (nfc_w < cap) { print line > (dir "/92_nfc_log.txt"); nfc_w++ } }
			if (line ~ bad) { bad_n++; if (bad_w < cap) { print line > (dir "/94_crash_log.txt"); bad_w++ } }
			# 所有桶都写满就提前退出：几十 MB 日志全扫一遍会让收尾超过测试者耐心。
			if (audio_w >= cap && kws_w >= cap && face_w >= cap && nfc_w >= cap && bad_w >= cap && avc_w >= cap) { early = 1; exit }
		}
		END {
			printf "SLICE_TOTALS audio=%s xiaoai=%s face=%s nfc=%s avc=%s crash=%s early_exit=%s\n", \
				audio_n, kws_n, face_n, nfc_n, avc_n, bad_n, (early ? "yes" : "no") > (dir "/92_slice_totals.txt")
		}
	' "$LIVE_LOG" 2>>"$CAP/99_notes.txt"
	{
		printf '===== 主题切片总量（每桶另写前 %s 行）=====\n' "$FILTER_MAX_LINES"
		cat "$CAP/92_slice_totals.txt" 2>/dev/null
	} >"$CAP/.avc_head.tmp" 2>&1
	# 先去重写出汇总，再拼到原始 denied 之前：避免在同一管道里读写同一个文件。
	{
		cat "$CAP/.avc_head.tmp" 2>/dev/null
		printf '\n===== 去重后的 denied（按源/目标/类，前 60 条）=====\n'
		grep -a 'avc:[[:space:]]*[Dd]enied' "$CAP/93_avc_log.txt" 2>/dev/null |
			sed -E 's/.*avc:[[:space:]]*[Dd]enied[[:space:]]*//; s/; comm=[^ ]*//; s/  +/ /g' |
			sort | uniq -c | sort -rn | head -n 60
		printf '\n===== 按源域统计 denied 前 20 =====\n'
		grep -a 'avc:[[:space:]]*[Dd]enied' "$CAP/93_avc_log.txt" 2>/dev/null |
			sed -E 's/.*scontext=([A-Za-z0-9_:.-]+).*/\1/' | sort | uniq -c | sort -rn | head -n 20
		printf '\n===== 原始 denied 行（前 %s 行）=====\n' "$FILTER_MAX_LINES"
		cat "$CAP/93_avc_log.txt" 2>/dev/null
		true
	} >"$CAP/.avc_all.tmp" 2>&1
	mv -f -- "$CAP/.avc_all.tmp" "$CAP/93_avc_log.txt"
	rm -f -- "$CAP/.avc_head.tmp" "$CAP/.avc_all.tmp" 2>/dev/null
	return 0
}

baseline_lines() {
	if [ -s "$LIVE_LOG" ]; then
		wc -l <"$LIVE_LOG" 2>/dev/null | tr -d ' '
	else
		printf '0\n'
	fi
}

# ---------------------------------------------------------------- 静态基线
# shellcheck disable=SC2016 # 采集块里大量 sh -c '<字面脚本>' 是故意不展开的，要在设备 toybox sh 里才展开。
if [ "$PACK_ONLY" -eq 0 ]; then
	# 重复执行要得到相同结果：不清空会在同一文件里不断追加；MANUAL.txt 在上级目录，不受影响。
	for stale in "$CAP"/*.txt "$CAP"/zz_*; do
		[ -f "$stale" ] && rm -f -- "$stale"
	done

	META='00_meta.txt'
	{
		printf '# HyperOS 移植现象取证 %s\n' "$TRACE_VERSION"
		printf '# tag=%s out=%s 场景=%s secs=%s interval=%s heavy=%s auto=%s no_pause=%s max_log_mb=%s\n' \
			"$TAG_CLEAN" "$TRACE_DIR" "$ONLY" "$SCENARIO_SECS" "$TICK_INTERVAL" "$HEAVY" "$AUTO" "$NO_PAUSE" "$MAX_LOG_MB"
		printf '\n===== 身份与权限 =====\n'
	} >"$CAP/$META"
	if has id; then id >>"$CAP/$META" 2>&1; fi
	if has uname; then uname -a >>"$CAP/$META" 2>&1; fi
	if has getenforce; then
		printf 'SELinux: %s\n' "$(getenforce 2>&1)" >>"$CAP/$META"
	fi
	printf '\n===== 工具可用性 =====\n' >>"$CAP/$META"
	for t in logcat dumpsys getprop settings pidof ps top sleep grep awk sed tail wc zip tar timeout find sha256sum pm service setsid; do
		if has "$t"; then printf 'YES  %s\n' "$t"; else printf 'NO   %s\n' "$t"; fi
	done
	if [ "$(id -u 2>/dev/null)" != "0" ]; then
		printf '\n警告: 当前不是 root（uid=%s）。logcat / sysfs / 多数 dumpsys 预计为空，\n' "$(id -u 2>/dev/null)" >>"$CAP/$META"
		printf '      请在 MT 管理器「设置 → Root 权限」放行后重跑，否则证据不足以定性。\n' >>"$CAP/$META"
	fi

	# ---- 01 全量属性与主题筛选
	cap 01_getprop.txt getprop
	capfilter 'audio|sound|bt|a2dp|lhdc|ldac|voice|voicetrigger|pal|agm|alsa' 01_getprop.txt 11_audio_props.txt
	capfilter 'face|struct|ir_' 01_getprop.txt 21_face_props.txt
	capfilter 'nfc' 01_getprop.txt 31_nfc_props.txt
	capfilter 'soundtrigger|voiceassist|voicetrigger|xiaoai' 01_getprop.txt 41_xiaoai_props.txt
	capfilter 'init\.svc\.|updatable_crashing|boot_completed|boottime\.' 01_getprop.txt 11b_svc_state.txt

	# ---- 02 settings（人脸/NFC/唤醒/音量的开关状态，全量另存一份）
	# settings 服务在部分 root shell 下会整库失败（`cmd: Failure calling service settings: Failed transaction`），
	# 因此失败时改读磁盘上的 XML 兼底。
	cap 02b_settings_full.txt sh -c '
		for store in secure global system; do
			echo "===== settings list $store ====="
			settings list "$store" 2>&1
		done
		if settings list secure 2>&1 | grep -q -i "Failure calling service settings"; then
			echo "===== 兼底：直读 /data/system/users/0/settings_*.xml ====="
			for x in /data/system/users/0/settings_secure.xml /data/system/users/0/settings_global.xml /data/system/users/0/settings_system.xml; do
				[ -r "$x" ] || { echo "ABSENT $x"; continue; }
				echo "-- $x"
				sed -e "s/^[ \t]*//" "$x" | grep -a -E "name=" | head -n 300
			done
		fi
		true
	'
	capfilter 'face|nfc|voice|assist|sound|spatial|dnd|vibrat|wakeup|dt2w|screen_off' 02b_settings_full.txt 02_settings.txt

	# ---- 03 包列表（定“跑的是哪套系统”的硬判据：移植侧有一批 com.miui.* 与 /product 专产）
	cap 03_packages.txt sh -c '
		echo "miui_pkg_count=$(pm list packages 2>/dev/null | grep -c -E "^package:com\\.miui\\.")"
		echo "coloros_pkg_count=$(pm list packages 2>/dev/null | grep -c -E "^package:com\\.(coloros|oplus)\\.")"
		echo "voice_trigger=$(pm path com.miui.voicetrigger 2>/dev/null | head -n 1)"
		echo "launcher=$(getprop ro.home_app 2>/dev/null)"
		true
	'

	# ---- 05 内核与声卡（声音问题的硬件侧证据）
	cap 05_kernel.txt sh -c '
		echo "===== uname -r / /proc/version ====="
		uname -r 2>&1; head -c 400 /proc/version 2>&1; echo
		echo "===== /proc/asound/cards ====="
		cat /proc/asound/cards 2>&1
		echo "===== PCM 子流状态（放音/录音是否在跑）====="
		for f in /proc/asound/card*/pcm*p/sub*/status /proc/asound/card*/pcm*c*/sub*/status; do
			[ -r "$f" ] && { printf "%s : " "$f"; head -n 3 "$f" | tr "\n" " "; echo; }
		done
		echo "===== PCM 硬件参数（采样率/通道，判 16k 采集与 48k 放音是否冲突）====="
		for f in /proc/asound/card*/pcm*p/sub*/hw_params /proc/asound/card*/pcm*c*/sub*/hw_params; do
			[ -r "$f" ] && { printf "----- %s\n" "$f"; cat "$f"; }
		done
		echo "===== /proc/interrupts 里与音频/ADSP 相关的行 ====="
		grep -i -E "sound|audio|adsp|spf|lpass|wcd|wsa|mi2s|q6" /proc/interrupts 2>&1 | head -n 20
		echo "===== /proc/meminfo 关键项 ====="
		head -n 8 /proc/meminfo 2>&1
		grep -E "MemAvailable|SwapTotal|SwapFree|Zram|Dirty" /proc/meminfo 2>&1
		true
	'
	if [ "$HEAVY" -eq 1 ] && has dmesg; then
		capn 05b_dmesg.txt 400 dmesg
	else
		printf '%s\n' '[SKIP] --no-heavy 或设备上没有 dmesg（Android 常因 dmesg_restrict 读不到）。' >"$CAP/05b_dmesg.txt"
	fi

	# ---- 06 崩溃与 ANR 现场（声音/人脸/HAL 的硬证据，整文件收进包）
	# shellcheck disable=SC2012,SC2010 # 这些都是系统固定目录与系统生成的条目名，不含任意用户输入文件名。
	{
		printf '\n===== /data/anr =====\n'
		ls -l /data/anr 2>&1
		printf '\n===== /data/tombstones（按时间倒序前 20）=====\n'
		ls -lt /data/tombstones 2>&1 | head -n 21
		printf '\n===== /data/system/dropbox（只列条目名，前 40）=====\n'
		ls -1 /data/system/dropbox 2>&1 | head -n 40
		printf '\n===== dropbox 里与音频/人脸/崩溃相关的条目名 =====\n'
		ls -1 /data/system/dropbox 2>/dev/null | grep -i -E 'audio|crash|face|biometric|anr|tombstone|system_server|watchdog' | head -n 40
		# 每个 tombstone 先给一行摘要（谁崩、什么信号、栈顶）与时间戳，免得在几 MB 正文里找。
		printf '\n===== tombstone 摘要（最新 4 个）=====\n'
		for t in $(ls -1t /data/tombstones 2>/dev/null | grep -v '\\.pb$' | head -n 4); do
			tb="/data/tombstones/$t"
			printf '%s\n' "--- $tb"
			grep -a -m1 -E '^Timestamp' "$tb" 2>/dev/null | cut -c1-60
			grep -a -m1 -E '^Cmdline' "$tb" 2>/dev/null | cut -c1-120
			grep -a -m1 -E '^pid:' "$tb" 2>/dev/null | cut -c1-120
			grep -a -m1 -E '^signal|^Abort message' "$tb" 2>/dev/null | cut -c1-140
			grep -a -m3 '#0[0-2] pc' "$tb" 2>/dev/null | cut -c1-130
		done
		true
	} >"$CAP/06_crash_evidence.txt" 2>&1
	# 最新的 ANR trace 与 tombstone 直接收进包（超大只取尾部）。
	for src in /data/anr/anr_* /data/anr/traces.txt /data/tombstones/tombstone_0? /data/tombstones/tombstone_0?.pb; do
		[ -f "$src" ] || continue
		grab_file "06c_$(basename -- "$src")" "$src"
	done

	# ---- 07 进程与内存（判「CPU 抢占导致 underrun」还是「HAL 重启环」）
	capn 07_procs.txt 60 sh -c 'ps -A -o PID,PPID,RSS,NAME 2>/dev/null | sort -k3 -n -r | head -n 45'
	if [ "$HEAVY" -eq 1 ]; then
		capn 07b_top.txt 60 top -b -n 1 -m 25
		cap 07c_meminfo.txt sh -c '
			for t in audioserver system_server com.miui.voicetrigger com.miui.voiceassist; do
				echo "===== dumpsys meminfo $t ====="
				dumpsys meminfo "$t" 2>&1 | head -n 22
			done
			true
		'
		capn 07d_cpuinfo.txt 40 dumpsys cpuinfo
	else
		printf '%s\n' '[SKIP] --no-heavy：跳过 top / meminfo / cpuinfo。' >"$CAP/07b_top.txt"
	fi

	# ---- 50 补丁落地哨兵（先回答「这块镜像带了什么」，再谈「补丁有没有失效」）
	capn 50_landing.txt 200 sh -c '
		echo "===== 镜像身份 ====="
		for p in ro.build.date ro.build.date.utc ro.build.display.id ro.build.version.incremental \
			ro.build.fingerprint ro.product.device ro.product.model ro.vendor.oplus.market.name; do
			printf "%s = %s\n" "$p" "$(getprop $p 2>/dev/null)"
		done
		echo "===== 运行时代号与机型特征 XML（改名是否到位、TEE 真值）====="
		dev=$(getprop ro.product.device)
		echo "RUNTIME_DEVICE=$dev"
		ls -1 /product/etc/device_features 2>/dev/null
		for f in /product/etc/device_features/*.xml; do
			[ -f "$f" ] || continue
			flat=$(tr -d "\n\r\t" < "$f" | tr -s " ")
			printf "SENTINEL_TEE[%s]=%s\n" "$f" "$(printf "%s" "$flat" | grep -o -E "support_tee_face_unlock\">[^<]*" | head -n 1)"
			printf "SENTINEL_REGION[%s]=%s\n" "$f" "$(printf "%s" "$flat" | grep -o -E "support_face_unlock_region_dom\">.{0,120}" | head -n 1)"
		done
		echo "===== 各模块产物在位性（按当前 Neo8 组合实际写入的路径）====="
		for f in /odm/etc/init/xiaoai_wakeup_props.rc /odm/etc/init/disable_hyperos_preread.rc \
			/odm/etc/init/disable_oplus_crash_loop.rc \
			/odm/etc/init/coloros_wallet_props.rc /odm/etc/init/coloros_wallet_nfc_settings.rc \
			/odm/etc/init/nfc_tms_symlink.rc /odm/etc/ueventd.rc /vendor/etc/init/init.millet_core.rc \
			/system_ext/lib64/modules/millet_core.ko; do
			if [ -e "$f" ]; then printf "SENTINEL_RC[%s]=FOUND\n" "$f"; else printf "SENTINEL_RC[%s]=ABSENT\n" "$f"; fi
		done
		printf "SENTINEL_MODEL=%s\n" "$(ls -1 /odm/etc 2>/dev/null | grep -i -E "xiaoaitongxue|sva_model|sound_model" | tr "\n" " ")"
		printf "SENTINEL_MILLET_LOADED=%s\n" "$(grep -a -c "^millet_core" /proc/modules 2>/dev/null)"
		printf "SENTINEL_NODE_ALIAS=%s\n" "$(for n in /dev/st21nfc /dev/nq-nci /dev/tms_nfc; do [ -e "$n" ] && printf "%s " "$n"; done)"
		echo "===== 声学属性的 SELinux 标签（写了但无 label 时 init 根本 set 不进去）====="
		for f in /odm/etc/selinux/odm_property_contexts /vendor/etc/selinux/vendor_property_contexts \
			/system_ext/etc/selinux/system_ext_property_contexts; do
			[ -r "$f" ] || continue
			printf "PROPCTX[%s]=%s\n" "$f" "$(grep -h -E "vendor_audio_prop|support_record_type|voiceassist" "$f" 2>/dev/null | tr "\n" ";" | cut -c1-220)"
		done
		echo "===== MTP 哨兵（common/fix_mtp gate 模式的翻转项）====="
		printf "SENTINEL_MTP=use_ffs_mtp=%s configfs=%s state=%s usbconfig=%s\n" \
			"$(getprop vendor.usb.use_ffs_mtp)" "$(getprop sys.usb.configfs)" \
			"$(getprop sys.usb.state)" "$(getprop sys.usb.config)"
		# configfs 实读故意不带 2>/dev/null：被 SELinux 拒读时必须把失败暴露出来，
		# 不能伪装成“节点不存在”（上一版就是这么误判过一次）。
		echo "===== MTP 装配面实读（legacy mtp.gs0 是否可用 vs ffs.mtp）====="
		for n in /config/usb_gadget/g1/functions/mtp.gs0 /config/usb_gadget/g1/functions/ffs.mtp \
			/dev/usb-ffs/mtp /dev/mtp_usb /config/usb_gadget/g1/configs/b.1/f1; do
			printf "MTPNODE %s -> " "$n"; ls -ld "$n" 2>&1 | tr "\n" " "; echo
		done
		printf "MTP_FFS_LS=%s\n" "$(ls -laZ /dev/usb-ffs/mtp/ 2>&1 | tr "\n" ";" | cut -c1-260)"
		printf "MTP_GADGET_FUNCS=%s\n" "$(ls /config/usb_gadget/g1/functions/ 2>&1 | tr "\n" " " | cut -c1-260)"
		echo "===== NFC HAL 阵营与 INfc/default 归属（两台 TMS 机型都不通，靠本行分清层级）====="
		printf "NFC_HAL_BINS=%s\n" "$(ls -1 /vendor/bin/hw /odm/bin/hw 2>/dev/null | grep -i nfc-service | tr "\n" " ")"
		printf "NFC_IFACE_DECL=%s\n" "$(grep -h -R "interface aidl android.hardware.nfc.INfc" /vendor/etc/init /odm/etc/init 2>/dev/null | tr "\n" ";")"
		printf "NFC_INFC_OWNER=%s\n" "$(service list 2>/dev/null | grep -i -a nfc | tr "\n" ";" | cut -c1-240)"
		printf "NFC_SVC_STATE=%s\n" "$(getprop | grep -a -o -E "init\\.svc\\.[a-zA-Z_.]*nfc[a-zA-Z_.]*.: \\[[a-z]*\\]" | tr "\n" ";")"
		echo "===== NFC 兼容属性标签（无 label 时 nfc 域读不到，只会在 libc 留 Access denied）====="
		printf "NFC_PROPVAL=%s\n" "$(getprop | grep -a -o -E "ro\\.vendor\\.nfc\\.[a-z_]*.: \\[[^]]*\\]" | tr "\n" ";")"
		printf "NFC_PROPCTX=%s\n" "$(grep -h -R "ro.vendor.nfc" /vendor/etc/selinux/vendor_property_contexts /odm/etc/selinux/precompiled_property_contexts 2>/dev/null | tr "\n" ";")"
		echo "===== TMS NCI 运行配置是否已播种（两台共同根因的直接判据）====="
		printf "TMS_RUN_CONF=%s\n" "$(ls -l /data/vendor/nfc/ 2>&1 | grep -a -E "libnfc|total|No such|denied" | tr "\n" ";" | cut -c1-240)"
		printf "TMS_SEED_SRC=%s\n" "$(ls -1 /odm/etc/libnfc-tms.conf /odm/etc/libnfc-tms_RF_EC2.conf /odm/etc/nfc/ 2>&1 | grep -aE "libnfc-tms|No such" | tr "\n" ";" | cut -c1-220)"
		printf "TMS_SEED_RC=%s\n" "$(ls -l /odm/etc/init/nfc_tms_seed_config.rc /odm/etc/init/nfc_tms_symlink.rc 2>&1 | tr "\n" ";" | cut -c1-220)"
		printf "TMS_NODE_ALIAS=%s\n" "$(ls -l /dev/thn31 /dev/tms_nfc /dev/st21nfc 2>&1 | tr "\n" ";" | cut -c1-220)"
		printf "TMS_SKU_PROP=sku=%s product_sku=%s configFile=%s\n" \
			"$(getprop ro.boot.hardware.sku)" "$(getprop ro.boot.product.hardware.sku)" \
			"$(getprop persist.vendor.nfc.configFile_name)"
		echo "===== TMS 控制面与 SE 侧（影响钱包/门禁，也影响 NFCEE 路由提交）====="
		printf "TMS_SERVICES=%s\n" "$(service list 2>/dev/null | grep -a -i -E "tms|secure_element|nfc" | tr "\n" ";" | cut -c1-260)"
		printf "SE_SVC_STATE=%s\n" "$(getprop | grep -a -o -E "init\\.svc\\.[a-z_.]*se[a-z_.]*.: \\[[a-z]*\\]" | tr "\n" ";" | cut -c1-200)"
		printf "TMS_SUBDIRS=%s\n" "$(for d in /data/vendor/nfc /data/vendor/nfc/dispatch /data/vendor/nfc/feature /data/vendor/nfc/param /data/vendor/nfc_socket /data/nfc; do ls -ld $d 2>&1 | tr "\n" " "; echo "|"; done | cut -c1-320)"
		printf "TMS_FW_FILES=%s\n" "$(ls -1 /odm/etc/nfc/ 2>/dev/null | grep -a -c -E "SEC_THN31|bin_")"
		printf "TMS_TDT=%s\n" "$(ls -l /odm/etc/nfc/tdt/ /data/vendor/nfc/param/ 2>&1 | tr "\n" ";" | cut -c1-240)"
		echo "===== 小爱 rc 与声学属性落点实读（用来区分“包旧”与“product 没刷新”）====="
		if [ -r /odm/etc/init/xiaoai_wakeup_props.rc ]; then
			echo "-- /odm/etc/init/xiaoai_wakeup_props.rc 正文:"
			sed -n "1,24p" /odm/etc/init/xiaoai_wakeup_props.rc 2>/dev/null
		else
			echo "SENTINEL_RC_BODY=UNREADABLE"
		fi
		prj=$(getprop ro.boot.prjname)
		printf "SENTINEL_RO_BOOT_PRJNAME=%s\n" "${prj:-空}"
		srt=ro.vendor.audio.soundtrigger.support_record_type
		printf "SENTINEL_SRT_RUNTIME=%s\n" "$(getprop "$srt")"
		printf "SENTINEL_SRT_ODM=%s\n" "$(grep -h -o -E "$srt=[^ ]*" /odm/etc/build.prop 2>/dev/null | head -n 2 | tr "\n" " ")"
		printf "SENTINEL_SRT_GSI=%s\n" "$(grep -h -o -E "$srt=[^ ]*" /odm/etc/"$prj"/build.gsi.prop 2>/dev/null | head -n 2 | tr "\n" " ")"
		printf "SENTINEL_SRT_VENDOR=%s\n" "$(grep -h -o -E "$srt=[^ ]*" /vendor/build.prop 2>/dev/null | head -n 2 | tr "\n" " ")"
		echo "===== CPU FlexKws 植入哨兵（VoiceTrigger.apk 里找新增类，注意 dex 在包里是压缩的）====="
		apk=/product/app/VoiceTrigger/VoiceTrigger.apk
		if [ ! -f "$apk" ]; then
			echo "SENTINEL_CPU_KWS=ABSENT_APK"
		elif ! command -v unzip >/dev/null 2>&1; then
			echo "SENTINEL_CPU_KWS=NO_UNZIP"
		else
			ls -l "$apk"; sha256sum "$apk" 2>/dev/null
			for d in classes.dex classes2.dex classes3.dex classes4.dex; do
				if unzip -l "$apk" "$d" >/dev/null 2>&1; then
					n=$(unzip -p "$apk" "$d" 2>/dev/null | grep -a -c PortCpuKws)
					printf "SENTINEL_CPU_KWS[%s]=%s\n" "$d" "${n:-0}"
				fi
			done
		fi
		echo "===== 声学属性载体目录实读（只用 ro.boot.prjname 推导，不写死任何机型代号）====="
		for f in /odm/etc/init/hw/init.qcom.usb.rc /vendor/etc/init/hw/init.qcom.usb.rc \
			/system/etc/init/hw/init.usb.configfs.rc; do
			if [ -f "$f" ]; then printf "SENTINEL_USB_RC[%s]=FOUND\n" "$f"; else printf "SENTINEL_USB_RC[%s]=ABSENT\n" "$f"; fi
		done
		if [ -n "${prj:-}" ] && [ -d /odm/etc/"$prj" ]; then
			printf "SENTINEL_PRJDIR[/odm/etc/%s]=%s\n" "$prj" "$(ls -1 /odm/etc/"$prj" 2>/dev/null | tr "\n" " ")"
		else
			printf "SENTINEL_PRJDIR[/odm/etc/%s]=ABSENT\n" "${prj:-无prjname}"
		fi
		echo "===== appname 定点修补的两个库（判补丁是否进镜像）====="
		for f in /system_ext/lib64/libaudiopolicymanagerimpl.so /system_ext/lib64/libmiaudiopolicymanager.so; do
			if [ -f "$f" ]; then
				printf "SENTINEL_APPNAME[%s]=%s\n" "$f" "$(sha256sum "$f" 2>/dev/null | cut -c1-16)"
			else
				printf "SENTINEL_APPNAME[%s]=ABSENT\n" "$f"
			fi
		done
		echo "===== 底包 PAL 并发采集与 LHDC 产物 ====="
		for f in /odm/etc/resourcemanager.xml /vendor/etc/resourcemanager.xml; do
			[ -f "$f" ] && printf "%s : %s\n" "$f" "$(grep -o -E "concurrent_capture=\"[^\"]*\"" "$f" 2>/dev/null | head -n 2 | tr "\n" " ")"
		done
		printf "SENTINEL_LHDC=%s\n" "$(ls -1 /apex/com.android.bt/lib64 2>/dev/null | grep -i -E "lhdc|ldac" | tr "\n" " ")"
		true
	'

	# ---- 52 硬件参数真机核对（把只能真机判定的项一次抓齐：运行时身份 / SELinux 版本标记 /
	#      显示原生分辨率与刷新档 + Display ID / 超声波指纹落点 / 双击触控 / Millet vermagic）。
	#      对应 Ace 6 交付时仍标「估算 / 沿用 / 待实机」的参数，回传后直接比对定值。
	capn 52_hw_params.txt 500 sh -c '
		echo "===== 运行时身份与 ColorOS/钱包关键 prop（核对 odm.device、cuptsm、oplusrom 是否按真值落地）====="
		for p in ro.product.device ro.product.model ro.product.name ro.product.brand ro.product.manufacturer \
			ro.product.marketname ro.vendor.oplus.market.name ro.vendor.oplus.market.enname \
			ro.build.version.oplusrom ro.build.version.oplusrom.display ro.product.cuptsm \
			ro.vendor.oplus.regionmark ro.boot.prjname ro.separate.soft; do
			printf "%s = %s\n" "$p" "$(getprop $p 2>/dev/null)"
		done
		echo "===== SELinux 版本标记实值（genfs 必须与 plat 同值，否则 init 解析 policy 起不来）====="
		for f in /vendor/etc/selinux/plat_sepolicy_vers.txt /vendor/etc/selinux/genfs_labels_version.txt \
			/odm/etc/selinux/plat_sepolicy_vers.txt /odm/etc/selinux/genfs_labels_version.txt; do
			if [ -r "$f" ]; then printf "%s = %s\n" "$f" "$(tr -d "\n\r\t " < "$f")"; else printf "%s = ABSENT\n" "$f"; fi
		done
		echo "===== 显示：原生分辨率与刷新档、物理 Display ID（核对 1270 还是 1272、是否 165Hz 五档、uniqueId）====="
		dumpsys display 2>&1 | grep -a -E "uniqueId|Display Info|[0-9]{4}x[0-9]{4}|modeId|refreshRate|Physical|Controller" | head -n 50
		echo "-- 底包 sdm 面板分辨率（本机 Target 的真实原生尺寸，指纹换算基线）--"
		for x in /odm/etc/sdm_display_resolution_extn.xml /vendor/etc/sdm_display_resolution_extn.xml; do
			[ -r "$x" ] || continue
			printf "----- %s\n" "$x"
			grep -a -o -E "Target name=\"[^\"]*\"|PanelResolution width=\"[0-9]+\" height=\"[0-9]+\"" "$x" 2>/dev/null | head -n 20
		done
		echo "===== 超声波指纹落点（读回补丁写入的 fod 坐标 + 框架可见位置）====="
		getprop 2>/dev/null | grep -a -E "fp\.fod|persist\.vendor\.sys\.fp|ro\.hardware\.fp"
		echo "-- dumpsys fingerprint 里的 fod/sensor/location/position --"
		dumpsys fingerprint 2>&1 | grep -a -i -E "fod|sensor|location|ultrasonic|position|displayId|width|height" | head -n 40
		echo "===== 双击亮屏 / 触控（touchfeature 运行时值、生成的 keylayout 是否含 WAKE 键）====="
		printf "ro.vendor.touchfeature.type = %s\n" "$(getprop ro.vendor.touchfeature.type 2>/dev/null)"
		for kl in /odm/usr/keylayout/touchpanel.kl /vendor/usr/keylayout/touchpanel.kl /odm/usr/keylayout/*.kl; do
			[ -r "$kl" ] || continue
			if grep -a -q "WAKE" "$kl" 2>/dev/null; then
				printf "KL_WAKE[%s]=%s\n" "$kl" "$(grep -a -E "WAKE" "$kl" 2>/dev/null | tr "\n" ";" | cut -c1-200)"
			fi
		done
		true
	'
	lsglob 52_hw_params.txt '/proc/touchpanel*' '/proc/touch*' '/sys/devices/platform/*touch*' '/sys/class/input/*' '/dev/input/*'
	# getevent -pl 只读、打印各输入设备名与支持的能力位后即退出（核对 touchpanel 设备是否存在、scan code 是否可用）。
	capn 52_hw_params.txt 240 getevent -pl
	capn 52_hw_params.txt 8 sh -c '
		echo "uname_r=$(uname -r 2>&1)"
		echo "millet_core_module=$(grep -a "^millet_core" /proc/modules 2>/dev/null | head -n 1)"
		true
	'

	# ---- 10 音频现场（策略、路由、流状态、声卡）
	cap 10_audio_static.txt dumpsys media.audio_flinger
	cap 10_audio_static.txt dumpsys audio
	cap 10_audio_static.txt dumpsys media.audio_policy
	capn 10_audio_static.txt 60 dumpsys audio_policy_service
	capn 10_audio_static.txt 40 dumpsys media_session
	capn 10_audio_static.txt 40 sh -c 'dumpsys -l 2>/dev/null | grep -i -E "audio|sound|media"'
	capn 10_audio_static.txt 80 sh -c '
		echo "===== 声效声明与声学属性真值（realme 底包未必有实现）====="
		getprop | grep -i -E "ro\.vendor\.audio\.|pal_concurrent|persist\.sys\.stability" 2>/dev/null
		echo "===== iorap / qguard / zram 造成的 CPU 抖动前提 ====="
		echo "PrereadEnable=$(getprop persist.sys.stability.PrereadEnable) iorapd=$(getprop init.svc.iorapd)"
		echo "updatable_crashing=$(getprop sys.init.updatable_crashing) 进程=$(getprop sys.init.updatable_crashing_process_name)"
		echo "qguard=$(getprop init.svc.qguard) 启动时刻=$(getprop ro.boottime.qguard)"
		true
	'
	lsglob 10_audio_static.txt '/apex/com.android.bt/lib64/*' '/vendor/lib64/*lhdc*' '/odm/etc/audio*' '/vendor/etc/audio*'

	# ---- 20 人脸现场（框架 feature、服务、HAL 与 VINTF 声明）
	capn 20_face_static.txt 200 dumpsys face
	capn 20_face_static.txt 150 dumpsys biometric
	capn 20_face_static.txt 120 dumpsys oiface
	capn 20_face_static.txt 120 dumpsys oplusoiface
	cap 20_face_static.txt sh -c '
		echo "===== 入口级判据：框架 feature 与 face 服务 ====="
		printf "FACE_PM_FEATURES=%s\n" "$(pm list features 2>/dev/null | grep -i -E "face|biometric" | tr "\n" " ")"
		printf "FACE_SERVICES=%s\n" "$(service list 2>/dev/null | grep -i face | tr "\n" " ")"
		echo "===== 人脸模板持久化与 TEE 通道（定 501 是“没模板”还是“比对不过”的唯一硬判据）====="
		printf "FACE_STORE=%s\n" "$(for d in /data/vendor_de/0/facedata /data/vendor_ce/0/facedata /data/vendor_de/0/faceunlock /data/vendor_de/0/faceunlock_ori /data/system/face; do ls -lR "$d" 2>&1 | tr "\n" " "; echo "|"; done | cut -c1-320)"
		printf "FACE_TEE_NODES=%s\n" "$(ls -lZ /dev/smcinvoke /dev/rgaut* /dev/qseecom* /dev/smcink 2>&1 | tr "\n" ";" | cut -c1-240)"
		printf "FACE_HAL_BINS=%s\n" "$(ls -1 /vendor/bin/hw /odm/bin/hw 2>/dev/null | grep -a -i -E "face|uff" | tr "\n" ";")"
		printf "FACE_BACKEND_SVC=%s\n" "$(service list 2>/dev/null | grep -a -i -E "face|osense|uah|dccs|dcs" | tr "\n" ";" | cut -c1-240)"
		printf "CAMERA_SVC=%s\n" "$(getprop | grep -a -o -E "init\\.svc\\.[a-z_.]*camera[a-z_.]*.: \\[[a-z]*\\]" | tr "\n" ";" | cut -c1-160)"
		echo "===== 人脸 HAL 与 VINTF 声明 ====="
		ls -1 /vendor/bin/hw 2>/dev/null | grep -i face
		ls -1 /odm/bin/hw 2>/dev/null | grep -i face
		grep -h -R -o -E "biometrics[^\"<]*face[^\"<]*" /vendor/etc/vintf/manifest.xml /odm/etc/vintf/manifest*.xml 2>/dev/null | head -n 10
		echo "===== vendor 侧人脸硬件特性声明（fix_face_unlock 迁移产物）====="
		ls -l /vendor/etc/permissions/android.hardware.biometrics.face.xml 2>&1
		true
	'
	probe_path 20_face_static.txt /vendor/bin/hw /odm/bin/hw /product/etc/device_features /vendor/etc/permissions

	# ---- 30 NFC 现场（阵营、服务、节点、开关）
	cap 30_nfc_static.txt dumpsys nfc
	capn 30_nfc_static.txt 45 sh -c 'dumpsys nfc 2>&1 | sed -n "1,40p"'
	cap 30_nfc_static.txt sh -c '
		echo "== NFC 开关（secure）=="; settings get secure nfc_on 2>&1
		echo "== /dev 下的 NFC 节点 =="; ls -l /dev 2>/dev/null | grep -i nfc
		echo "== NFC 相关进程 =="; ps -A 2>/dev/null | grep -i nfc
		echo "== 已装的 NFC 包 =="; pm list packages 2>/dev/null | grep -i -E "nfc|Nfc"
		true
	'
	# SUMMARY 只抽这几行带标签的结论，避免从大段 dump 里拼行拼到噪声。
	capn 30_nfc_static.txt 40 sh -c '
		printf "NFC_NODES=%s\n" "$(ls -1 /dev 2>/dev/null | grep -i nfc | tr "\n" " ")"
		printf "NFC_INIT_SVC=%s\n" "$(getprop 2>/dev/null | grep -i "init.svc.*nfc" | tr "\n" " ")"
		printf "NFC_PKG=%s\n" "$(pm list packages 2>/dev/null | grep -i nfc | tr "\n" " ")"
		printf "NFC_INIT_DEF=%s\n" "$(grep -h -R -o -E "service [^ ]*nfc[^ ]*|/dev/[a-z0-9_]*nfc[a-z0-9_]*" /vendor/etc/init /odm/etc/init 2>/dev/null | sort -u | tr "\n" " ")"
		printf "NFC_SE=%s\n" "$(ls -1 /dev 2>/dev/null | grep -i -E "ese|se|smc|tms" | tr "\n" " ")"
		echo "===== TMS 运行时目录与服务（与 50_landing 互相印证，缺哪层一眼看出）====="
		printf "NFC_TMS_STATE=%s\n" "$(getprop | grep -a -o -E "(init\\.svc\\.[a-z_.]*(tms|nfc|secure_element)[a-z_.]*|ro\\.vendor\\.nfc\\.[a-z_]*): \\[[^]]*\\]" | tr "\n" ";" | cut -c1-260)"
		printf "NFC_DATA_TREE=%s\n" "$(find /data/vendor/nfc /data/nfc -maxdepth 2 2>&1 | head -n 40 | tr "\n" ";" | cut -c1-300)"
		true
	'
	lsglob 30_nfc_static.txt '/dev/*nfc*' '/odm/etc/vintf/manifest/*nfc*' '/vendor/etc/vintf/manifest/*nfc*' \
		'/odm/etc/nfc/*' '/vendor/etc/nfc/*'
	capn 30_nfc_static.txt 60 sh -c 'grep -h -R -E "tms_nfc|st21nfc|nq-nci|nfc_hal_service" /vendor/etc/init /odm/etc/init 2>/dev/null | head -n 40'

	# ---- 40 小爱唤醒现场（路线、节奏、进程、模型、SoundTrigger 服务）
	capn 40_xiaoai_static.txt 90 sh -c '
		echo "===== 唤醒路线与节奏真值 ====="
		getprop | grep -E "xiaoai|cpu_kws|soundtrigger|voiceassist" 2>/dev/null
		echo "===== VT / 小爱进程与包状态 ====="
		ps -A 2>/dev/null | grep -i -E "voicetrigger|voiceassist"
		dumpsys package com.miui.voicetrigger 2>/dev/null | grep -E "versionName|codePath|enabled|stopped|disabled" | head -n 12
		dumpsys package com.miui.voiceassist 2>/dev/null | grep -E "versionName|enabled|stopped" | head -n 8
		echo "===== 唤醒开关（用户设置里的免手唤醒）====="
		for k in voice_assist_wakeup_checked voice_assist_long_press_enabled voice_assist_active_wakeup enable_headset_wakeup; do
			echo "$k = $(settings get secure $k 2>/dev/null)"
		done
		echo "===== CPU 模型文件是否就位 ====="
		ls -l /data/user/0/com.miui.voicetrigger/files/flexkws/*/ 2>/dev/null | head -n 20
		true
	'
	cap 40_xiaoai_static.txt dumpsys soundtrigger_middleware_service
	cap 40_xiaoai_static.txt dumpsys soundtrigger_hidl_service
	cap 40_xiaoai_static.txt dumpsys media.sound_trigger_hw
	capn 40_xiaoai_static.txt 60 sh -c 'dumpsys -l 2>/dev/null | grep -i -E "soundtrigger|voice"'
	capn 40_xiaoai_static.txt 40 sh -c '
		echo "===== SoundTrigger HAL 与 VINTF 声明 ====="
		ls -1 /vendor/bin/hw /odm/bin/hw 2>/dev/null | grep -i -E "soundtrigger|sound_trigger"
		grep -h -R -o -E "soundtrigger[^\"<]*" /vendor/etc/vintf/manifest.xml /odm/etc/vintf/manifest*.xml 2>/dev/null | head -n 10
		true
	'

	# ---- 60 其它子系统（亮度/刷新率/USB/传感器/马达，供交叉对照）
	capn 60_misc.txt 120 dumpsys display
	capn 60_misc.txt 60 dumpsys usb
	capn 60_misc.txt 120 dumpsys sensorservice
	capn 60_misc.txt 60 dumpsys vibrator_manager
	capn 60_misc.txt 60 sh -c 'dumpsys -l 2>/dev/null | head -n 200'

	# ---- 65 深度核查项（本轮在 6T 上手工逐条敲过的东西，全部自动化）
	capn 65_deep_state.txt 200 sh -c '
		echo "===== 运行侧身份（定“跑的是哪套系统”的硬判据）====="
		for p in ro.build.display.id ro.build.version.incremental ro.miui.ui.version.name \
			ro.product.device ro.product.brand ro.product.brand_for_attestation \
			ro.product.device_for_attestation ro.vendor.oplus.market.name; do
			printf "%-38s %s\n" "$p" "$(getprop $p)"
		done
		printf "miui_pkg=%s coloros_pkg=%s\n" "$(pm list packages 2>/dev/null | grep -c -E "^package:com\\.miui\\.")" "$(pm list packages 2>/dev/null | grep -c -E "^package:com\\.(coloros|oplus)\\.")"
		for f in /product/etc/device_features /product/app/VoiceTrigger /system_ext/lib64/libmiaudiopolicymanager.so /system/app/UPTsmService /system_ext/app/EidService /system_ext/priv-app/KeKeUserCenterAccount; do
			[ -e "$f" ] && echo "FOUND  $f" || echo "ABSENT $f"
		done
		# 在盘上不等于已注册：把安装路径与包名对应关系直接采下来（不用 <() 进程替换，toybox sh 不支持）。
		printf "WALLET_REGISTERED=%s\n" "$(pm list packages -f 2>/dev/null | grep -a -iE "FinShell|TasWallet|HTMS|UPTsm|EidService|KeKeUserCenter" | tr "\n" " " | cut -c1-260)"
		pkgs=$(pm list packages -f 2>/dev/null)
		printf "IN_DISK_NOT_REGISTERED=%s\n" "$(for d in /system/app/FinShellWallet /system/app/TasWallet /system/app/HeytapHTMS /system/app/UPTsmService /system_ext/app/EidService /system_ext/priv-app/KeKeUserCenterAccount; do
			[ -d "$d" ] || continue
			printf "%s\n" "$pkgs" | grep -a -qs "$d" || printf "%s " "$d"
		done)"
		echo "===== 人脸深度（能力/服务/HAL/计数）====="
		printf "IFace_registered=%s\n" "$(service list 2>/dev/null | grep -a -c "android.hardware.biometrics.face.IFace/default")"
		printf "face_hal_svc=%s\n" "$(getprop | grep -a -o -E "init\\.svc\\.[a-z_.]*face[a-z_.]*.: \\[[a-z]*\\]" | tr "\n" " ")"
		printf "stface_lib=%s\n" "$(ls -1 /vendor/lib64 /odm/lib64 2>/dev/null | grep -a -c stfaceunlockocl)"
		printf "miface_props=%s\n" "$(getprop | grep -a -i miface | tr "\n" ";" | cut -c1-180)"
		dumpsys face 2>/dev/null | grep -a -E "prints|Accept Count|Reject Count|Total Error" | head -4
		dumpsys biometric 2>/dev/null | grep -a -E "ID\\(4\\)|authEnded" | tail -3
		echo "===== NFC 深度（开关/轮询掩码/发现链）====="
		dumpsys nfc 2>/dev/null | grep -a -E "mState|pollTech|listenTech|mIsReaderOptionEnabled|mScreenState" | head -6
		printf "nfc_svc=%s\n" "$(getprop | grep -a -o -E "init\\.svc\\.[a-zA-Z_.]*nfc[a-zA-Z_.]*.: \\[[a-z]*\\]" | tr "\n" " ")"
		echo "===== MTP 前提（不切模式也能看的部分）====="
		printf "usb: state=%s config=%s use_ffs_mtp=%s ramdump=%s\n" "$(getprop sys.usb.state)" "$(getprop sys.usb.config)" "$(getprop vendor.usb.use_ffs_mtp)" "$(getprop ro.boot.ramdump)"
		printf "ffs_mtp_dir=%s gadget_mtp=%s mtp_proc=%s\n" "$(ls -d /dev/usb-ffs/mtp 2>/dev/null)" "$(ls -d /config/usb_gadget/g1/functions/mtp.gs0 2>/dev/null)" "$(pidof com.android.mtp 2>/dev/null)"
		echo "===== MTP 装配明细（故意不屏蔽 stderr：区分“不存在”与“被拒”）====="
		printf "USB_FFS_LS=%s\n" "$(ls -laZ /dev/usb-ffs/ /dev/usb-ffs/mtp/ 2>&1 | tr "\n" ";" | cut -c1-300)"
		printf "USB_GADGET_TREE=%s\n" "$(ls -l /config/usb_gadget/g1/ /config/usb_gadget/g1/configs/b.1/ /config/usb_gadget/g1/functions/ 2>&1 | tr "\n" ";" | cut -c1-300)"
		printf "USB_SVC=%s\n" "$(getprop | grep -a -o -E "init\\.svc\\.(usbd|vendor\\.usb[a-z-]*|[a-z_.]*gadget[a-z_.]*): \\[[^]]*\\]" | tr "\n" ";")"
		printf "USB_STRINGS=%s\n" "$(cat /config/usb_gadget/g1/configs/b.1/strings/0x409/configuration /config/usb_gadget/g1/UDC 2>&1 | tr "\n" ";")"
		echo "===== 显示/亮度/刷新率 ====="
		dumpsys display 2>/dev/null | grep -a -o -E "local:[0-9]+|supportedRefreshRates \\[[^]]*\\]|defaultModeId [0-9-]+|brightnessDefault [0-9.]+" | head -6
		printf "dt2w=%s\n" "$(settings get secure double_tap_to_wake 2>/dev/null)"
		echo "===== 音频硬件侧与抖动统计 ====="
		dumpsys media.audio_flinger 2>/dev/null | grep -a -i -E "jitter|frame count|buffer size|underrun" | head -6
		for f in /proc/asound/card*/pcm*p/sub*/status; do [ -r "$f" ] && printf "PCM %s: %s\n" "$f" "$(head -n 1 "$f")"; done | head -4
		echo "===== 底包侧环境（zram / millet / 预读）====="
		grep -a -c "millet_core" /proc/modules 2>/dev/null | sed "s/^/millet_loaded=/"
		grep -a -o -E "^(zram|zsmalloc|oplus_bsp_hybridswap_zram|oplus_bsp_zram_opt|oplus_bsp_fg_protect)" /proc/modules 2>/dev/null | tr "\n" " " | sed "s/^/modules=/"
		echo
		cat /proc/swaps 2>/dev/null | tail -n +1 | head -3
		true
	'

	# ---- 09 历史崩溃取证（dropbox / pstore / ramdump / tombstones / anr）
	# 当前 logcat 缓冲只能存几十分钟，真正的“产生过的崩溃”必须从这些持久目录里翻。
	capn 09_history_crash.txt 400 sh -c '
		echo "===== dropbox 索引（各 tag 条数）====="
		dumpsys dropbox 2>&1 | head -n 45
		echo "===== dropbox 文件清单（名字/大小/时间）====="
		ls -l /data/system/dropbox 2>&1 | tail -n 45
		echo "===== 关键条目正文摘录（崩溃/ANR/Watchdog/上次开机内核日志）====="
		for f in /data/system/dropbox/*crash* /data/system/dropbox/*ANR* /data/system/dropbox/*anr* /data/system/dropbox/*Watchdog* /data/system/dropbox/*SYSTEM_BOOT* /data/system/dropbox/*SYSTEM_LAST_KMSG*; do
			[ -f "$f" ] || continue
			size=$(wc -c <"$f" 2>/dev/null)
			printf "----- %s（%s 字节）\n" "$f" "${size:-0}"
			head -c 6000 "$f" 2>/dev/null | head -n 50
		done
		echo "===== pstore / 异常重启证据（console-ramoops 里搜模块相关关键字）====="
		for d in /sys/fs/pstore /data/pstore /proc/last_kmsg; do
			[ -e "$d" ] && ls -l "$d" 2>&1 | head -n 8
		done
		for f in /sys/fs/pstore/console-ramoops* /sys/fs/pstore/dmesg-ramoops* /proc/last_kmsg; do
			[ -r "$f" ] || continue
			printf "----- %s 命中：\n" "$f"
			grep -a -i -E "qguard|libbase|millet|zram|hybridswap|iorap|avc:|audioserver|audio.hal|soundtrigger|nfc|face|panic|Oops|BUG:|watchdog" "$f" 2>/dev/null | head -n 12
		done
		echo "===== tombstones / ANR / ramdump 清单 ====="
		ls -l /data/tombstones 2>&1 | tail -n 20
		ls -l /data/anr 2>&1 | tail -n 10
		ls -l /data/vendor/ramdump 2>&1 | head -n 8
		ls -l /data/Log 2>&1 | head -n 8
		echo "===== 其他日志目录探测（DSU 与原系统不共享 data，看不到原系统日志属正常）====="
		for d in /data/adb/ksu/log /data/adb /data/misc/logd /data/misc/bluetooth/logs; do
			if [ -d "$d" ]; then echo "FOUND  $d"; else echo "ABSENT $d"; fi
		done
		true
	'
	# 崩溃类 dropbox 条目正文直接收进包（每条上限 GRAB_MAX_KB，超出只留尾部）。
	for dropbox_src in /data/system/dropbox/*crash* /data/system/dropbox/*ANR* /data/system/dropbox/*anr* \
		/data/system/dropbox/*Watchdog* /data/system/dropbox/*SYSTEM_LAST_KMSG*; do
		[ -f "$dropbox_src" ] || continue
		grab_file "09d_$(basename -- "$dropbox_src")" "$dropbox_src"
	done

	printf '\n'
fi

# ---------------------------------------------------------------- 复现窗口
if [ "$PACK_ONLY" -eq 0 ]; then
	printf '== 启动连续取证引擎 ==\n'
	printf '共 %d 个场景窗口，每窗约 %d 秒，全程约 %d 分钟（含静态基线与收尾）；期间会自动触发探针并尽量还原。\n' \
		"$(printf '%s' "$ONLY" | awk -F, '{print NF}')" "$SCENARIO_SECS" \
		"$(( ($(printf '%s' "$ONLY" | awk -F, '{print NF}') * SCENARIO_SECS + 240) / 60 ))"
	printf '**中途不要关闭执行窗口、不要拔线、不要关机**；只有打印出「回传文件: …zip」才算完成。\n'
	log_start
	ticks_start || tick "solo"
	if [ "$AUTO" -eq 1 ]; then
		probe_save_state
		printf '\n>> 自动探针模式已开启：接下来你**只需正常用机**（想听歌就放、想解锁就解锁、有卡就贴几下），\n'
		printf '>> 脚本会自己开 NFC、切 USB、亮/息屏、拉起小爱与钱包，并在日志里打 PROBE 标记。\n'
	fi

# 每窗开头报进度：远端测试者容易把最后一个探针当成“跑完了”就关掉执行窗口。
WIN_TOTAL=$(printf '%s' "$ONLY" | awk -F, '{print NF}')
WIN_INDEX=0
win_head() {
	WIN_INDEX=$((WIN_INDEX + 1))
	printf '\n---------- 第 %d/%d 个场景：%s ----------\n' "$WIN_INDEX" "$WIN_TOTAL" "$1"
	printf '（现在关掉执行窗口 = 没有 SUMMARY.txt 也没有 zip，本轮作废；\n'
	printf '  只有看到最后一行「回传文件: …zip」才是真的跑完。）\n'
}

	# ---- 声音断续
	if [ "$ON_AUDIO" -eq 1 ]; then
		win_head '声音断续'
		if [ "$AUTO" -eq 1 ]; then
			printf '\n[自动 audio] %s 秒：脚本在按音量键并尝试起播，你放首歌更好。\n' "$SCENARIO_SECS"
			probe_snapshot pre_audio
			probe_do input keyevent 24
			probe_do input keyevent 25
			probe_do cmd media_session dispatch play
		else
			printf '\n[场景 audio] 接下来 %s 秒：\n' "$SCENARIO_SECS"
			printf '  用任意 App 连续播放音乐或视频（默认外放），听到断续时【不要暂停】，一直放完；\n'
			printf '  若手边有有线耳机或蓝牙耳机，请在窗口后半段插上或切换一次，看断续形态是否改变；\n'
			printf '  结束后在 MANUAL.txt 写清：通路、大约每几秒一次、是否随小爱唤醒开关变化。\n'
		fi
		base=$(baseline_lines)
		win_start=$(now_ts)
		if pause_for "播放中..."; then
			:
		else
			printf '  （本次跳过交互窗口，只留静态快照。）\n'
		fi
		sample_window 10_audio_static.txt AUDIO \
			'appname=|Bad parameter|BAD_VALUE|underrun|out of sync|BUFFER TIMEOUT|AudioFlinger|audioserver|audiohal|audio-hal|HAL instance died|PAL:|AGM:|StreamHal|EffectsFactoryHalAidl|could not create effect|MiSound|Spatializer|gsl|STHAL' \
			'AUDIO 复现窗口' "$base" "$win_start"
		printf 'UNDERRUN_COUNT_total=%s standby_audio=%s hal_died=%s\n' \
			"$(count_of 'underrun|out of sync|BUFFER TIMEOUT' "$LIVE_LOG")" \
			"$(count_of '(AudioFlinger|AudioTrack|StreamHal|PAL:).{0,60}standby' "$LIVE_LOG")" \
			"$(count_of 'HAL instance died' "$LIVE_LOG")" >>"$CAP/10_audio_static.txt" 2>&1
		probe_snapshot post_audio
	fi

	# ---- 人脸录入与解锁
	if [ "$ON_FACE" -eq 1 ]; then
		win_head '人脸录入与解锁'
		if [ "$AUTO" -eq 1 ]; then
			printf '\n[自动 face] %s 秒：脚本会拉起安全设置页并做两次亮/息屏，**请把手机正对自己的脸**。\n' "$SCENARIO_SECS"
			probe_snapshot pre_face
			probe_do am start -a android.settings.SECURITY_SETTINGS
		else
			printf '\n[场景 face] 接下来 %s 秒（目标：抓到被拒那一刻的拒绝原因）：\n' "$SCENARIO_SECS"
			printf '  1) 前半段：进「设置 → 密码与安全（或指纹与解锁）→ 人脸解锁」，一路走到被拒/走不下去的那一步并停住，\n'
			printf '     屏上文案逐字抄进 MANUAL.txt（本脚本不截图，只要文字）；\n'
			printf '  2) 后半段：若仍有人脸数据，按电源键锁屏再用脸解锁 2-3 次，失败也照常再试，最后用指纹/密码进桌面。\n'
		fi
		face_before=$(dumpsys face 2>/dev/null | grep -m1 -a 'prints' | tr -d '\r')
		base=$(baseline_lines)
		win_start=$(now_ts)
		face_half=$((SCENARIO_SECS / 2))
		[ "$face_half" -ge 1 ] || face_half=1
		if [ "$AUTO" -eq 1 ]; then
			# 自动制造两次“亮屏待解锁”机会（需有人正对手机，脚本无法代替脸）。
			sleep_for "$face_half" "打开人脸页并正对手机..." && sleep_for 3 "息屏"
			probe_do input keyevent 26
			probe_do input keyevent 224
			sleep_for "$((SCENARIO_SECS - face_half))" "再正对手机一次..."
			probe_do input keyevent 26
			probe_do input keyevent 224
		elif sleep_for "$face_half" "走进录入页并停在报错处..."; then
			sleep_for "$((SCENARIO_SECS - face_half))" "锁屏→人脸解锁中..."
		else
			printf '  （本次跳过交互窗口。）\n'
		fi
		sample_window 20_face_static.txt FACE \
			'FaceService|FaceManager|Biometric|AuthSession|FaceProvider|miface|oiface|oplusoiface|face_hal|setAuthenticator|resetAuthentication|FeatureParser|hasFeature|FaceSettings|face_unlock|Keyguard|Can.t find service|ERROR_|unable to process|wasSuccessful|reject|not supported|unsupported' \
			'FACE 复现窗口（录入+解锁）' "$base" "$win_start"
		{
			printf '\nFACE_PRINTS_before=%s\n' "${face_before:-未读到}"
			printf 'FACE_PRINTS_after=%s\n' "$(dumpsys face 2>/dev/null | grep -m1 -a 'prints' | tr -d '\r')"
		} >>"$CAP/20_face_static.txt" 2>&1
		probe_snapshot post_face
	fi

	# ---- NFC 贴卡
	if [ "$ON_NFC" -eq 1 ]; then
		win_head 'NFC 刷卡与钱包'
		nfc_state=$(dumpsys nfc 2>/dev/null | grep -m1 -aE '^mState=' | tr -d '\r')
		printf '  当前 %s\n' "${nfc_state:-mState 未读到}"
		if [ "$AUTO" -eq 1 ]; then
			probe_snapshot pre_nfc
			probe_do svc nfc enable
			probe_do input keyevent 224
			printf '[自动 nfc] %s 秒：脚本已自动打开 NFC 并亮屏，请把卡贴背面停几秒（这一步只能你动手）。\n' "$SCENARIO_SECS"
		else
			printf '\n[场景 nfc] 接下来 %s 秒：\n' "$SCENARIO_SECS"
			printf '  若为 off/turning_on，请先在「设置 → 连接与共享/NFC」里手动打开（不加 --auto 时本脚本不改设置）；\n'
			printf '  然后把一张公交卡/门禁卡贴在背部 NFC 区保持几秒，再拿开重贴 2-3 次。\n'
		fi
		base=$(baseline_lines)
		win_start=$(now_ts)
		if pause_for "贴卡中..."; then
			:
		else
			printf '  （本次跳过贴卡窗口，只留静态快照。）\n'
		fi
		sample_window 30_nfc_static.txt NFC \
			'NfcService|NfcTag|NfaNfc|nfc_nci|nci_rx|nci_tx|rfintf|NfcDispatcher|NfcDiscovery|IsoDep|Felica|TechAPollingLostEvent|RoutingTable|AidRouting|NfcEnabled|secure_element|SecureElement|tms|st21nfc|THN31|nqnfcinfo|APDU|SELECT|getMIID' \
			'NFC 贴卡窗口' "$base" "$win_start"
		{
			printf '\n===== 采样后 dumpsys nfc 头部 =====\n'
			dumpsys nfc 2>&1 | sed -n '1,30p'
		} >>"$CAP/30_nfc_static.txt" 2>&1
		probe_snapshot post_nfc
	fi

	# ---- 小爱免手唤醒
	if [ "$ON_XIAOAI" -eq 1 ]; then
		win_head '小爱唤醒'
		if [ "$AUTO" -eq 1 ]; then
			printf '\n[自动 xiaoai] %s 秒：脚本会发一次 ASSIST 拉起小爱（测投递链），**喊「小爱同学」仍需你开口**。\n' "$SCENARIO_SECS"
			probe_snapshot pre_xiaoai
			probe_do input keyevent 224
			probe_do am start -a android.intent.action.ASSIST
		else
			printf '\n[场景 xiaoai] 接下来 %s 秒：\n' "$SCENARIO_SECS"
			printf '  1) 先按电源键熄屏，等 3 秒；\n'
			printf '  2) 对着手机正常音量喊「小爱同学」，等它应答，再喊一次；共 3 次；\n'
			printf '  3) 若完全不应答，亮屏后进「设置 → 语音助手」确认免手唤醒是否仍开着，并在 MANUAL.txt 记录。\n'
		fi
		base=$(baseline_lines)
		win_start=$(now_ts)
		if pause_for "喊唤醒词中..."; then
			:
		else
			printf '  （本次跳过唤醒窗口，只留静态快照。）\n'
		fi
		sample_window 40_xiaoai_static.txt XIAOAI \
			'AudioFlow|FlexKws|flexkws|VoiceTrigger|voicetrigger|SoundTrigger|soundtrigger|onRecognition|onEnoughData|LoadSoundModel|ParseSoundModel|LOAD_PHRASE_MODEL|START_RECOGNITION|WakeupInfo|voiceassist|VA_|status = -22|createMmapBuffer|create mmap buffer|gsl_|set_custom_config|nonpersist|SecurityException|PermissionVoiceService' \
			'XIAOAI 唤醒窗口' "$base" "$win_start"
		{
			printf '\n===== 采样后 VT 进程状态 =====\n'
			# shellcheck disable=SC2009 # toybox 上 pgrep 不一定可用，ps -A 是唯一稳定兜底。
			ps -A 2>/dev/null | grep -i -E 'voicetrigger|voiceassist'
			vt=$(pidof_one 'com.miui.voicetrigger')
			printf 'vt_cpu_jiffies=%s vt_rss_kb=%s\n' "$(cpu_jiffies "$vt")" "$(rss_kb "$vt")"
			true
		} >>"$CAP/40_xiaoai_static.txt" 2>&1
		probe_snapshot post_xiaoai
	fi

	# ---- 自动探针附加项（仅 --auto）：USB/MTP 切换与钱包拉起
	if [ "$AUTO" -eq 1 ]; then
		# 切换 USB 功能会重启 adbd；如果当前会话靠 adb 维持而切换后不再包含 adb，采集进程会整棵被杀
		# （实测：setsid 也挡不住）。因此优先把 adb 一起列入新配置使会话不断；只有无法保留 adb
		# 且发现自己跑在 adbd 子树里时，才完全跳过这个探针。
		usb_current_cfg=$(getprop sys.usb.config 2>/dev/null)
		probe_usb_keep_adb=0
		case "$usb_current_cfg" in *adb*) probe_usb_keep_adb=1 ;; esac
		if [ "$USB_PROBE" -eq 0 ] && [ "$probe_usb_keep_adb" -eq 0 ] && under_adbd; then
			printf '\n[自动 usb/wallet] **已跳过 USB 切换探针**：原配置不含 adb，切换会重启 adbd 并断开采集会话。\n'
			printf '  钱包探针照常执行；要强制切换请加 --force-usb-probe。\n'
			printf 'SKIP_USB_PROBE=当前 sys.usb.config 不含 adb，切换会断开采集会话\n' >>"$CAP/99_notes.txt"
			probe_mark 'skip usb probe：切换会断开 adbd 会话'
			probe_snapshot pre_usb
			probe_do monkey -p com.finshell.wallet -c android.intent.category.LAUNCHER 1
			sleep_for 10 "钱包首页停留中..." || true
			probe_do input keyevent 3
			probe_snapshot post_usb
		else
			printf '\n[自动 usb/wallet] 20 秒：脚本切一次 USB“传输文件”并拉起钱包，保持插线别拔。\n'
			probe_snapshot pre_usb
			# 切换只用 setprop（实测本 ROM 可用且能保留 adb 不拆会话）；
			# `cmd usb set-functions` 在这台 ROM 上是 "No shell command implementation"，
			# `svc usb setFunctions` 会在重配期间永久阻塞，因此不再依赖它们。
			if [ "$probe_usb_keep_adb" -eq 1 ]; then
				printf '  （原配置含 adb，切到 mtp,adb 以保证会话不断）\n'
				probe_do setprop sys.usb.config mtp,adb
			else
				probe_do setprop sys.usb.config mtp
			fi
			PROBE_USB_SWITCHED=1
			sleep_for 8 "等 USB 重新枚举..." || true
			printf '  切换后：config=%s state=%s\n' "$(getprop sys.usb.config 2>/dev/null)" "$(getprop sys.usb.state 2>/dev/null)"
			probe_do monkey -p com.finshell.wallet -c android.intent.category.LAUNCHER 1
			sleep_for 10 "钱包首页停留中..." || true
			probe_do input keyevent 3
			probe_snapshot post_usb
		fi
	fi

	printf '\n== 停止连续取证引擎 ==\n'
	tick_stop
	log_stop
	probe_restore_state

	# 注意：切片放到 SUMMARY/MANUAL 之后——远端测试者经常在收尾未完时就把目录打包带走，
	# 先写出 SUMMARY 才能保证“哪怕中途被抓，关键结论也已在包里”。

	# ---- 95 收尾状态（与静态基线对比，看复现过程是否改变了服务/路由）
	capn 95_post_state.txt 140 dumpsys audio
	capn 95_post_state.txt 140 sh -c 'dumpsys media.audio_flinger 2>&1 | grep -i -E "underrun|noise|standby|BUFFER TIMEOUT|Input thread|Output thread|HAL "'
	# shellcheck disable=SC2016 # 下面整段在设备 toybox sh 里才应展开。
	capn 95_post_state.txt 60 sh -c '
		echo "pid audioserver=$(pidof audioserver 2>/dev/null)"
		echo "pid audio_hal=$(pidof android.hardware.audio.service-aidl android.hardware.audio.service 2>/dev/null)"
		echo "pid voicetrigger=$(pidof com.miui.voicetrigger 2>/dev/null)"
		echo "updatable_crashing=$(getprop sys.init.updatable_crashing) 进程=$(getprop sys.init.updatable_crashing_process_name)"
		echo "init.svc.iorapd=$(getprop init.svc.iorapd) init.svc.qguard=$(getprop init.svc.qguard)"
		echo "dumpsys nfc mState=$(dumpsys nfc 2>/dev/null | grep -m1 -aE "^mState=")"
		echo "dumpsys face prints=$(dumpsys face 2>/dev/null | grep -m1 -a prints)"
		true
	'

	# ---- SUMMARY
	zz_count=0
	for z in "$CAP"/zz_*; do
		[ -e "$z" ] || continue
		zz_count=$((zz_count + 1))
	done
	# 采集窗口的真实起止（由 tick 首尾时间得出）：日志开头含环形缓冲历史，不能拿总行数当窗口。
	TICK_FROM=$(tick_time_of first)
	TICK_TO=$(tick_time_of last)
	win_minutes=$(awk -v a="${TICK_FROM:-00:00:00}" -v b="${TICK_TO:-00:00:00}" '
		BEGIN {
			split(a, x, ":"); split(b, y, ":")
			s = (y[1] * 3600 + y[2] * 60 + y[3]) - (x[1] * 3600 + x[2] * 60 + x[3])
			if (s < 0) s = 0
			m = int(s / 60); if (m < 1) m = 1
			print m
		}')
	[ -n "$win_minutes" ] || win_minutes=1
	TICK_MINUTES="$win_minutes"
	{
		printf '# 移植后现象取证关键结论（%s，tag=%s）\n' "$TRACE_VERSION" "$TAG_CLEAN"
		printf '# 本节全部由脚本自动提取；只有本节里没有的项才需要填 MANUAL.txt。\n'
		printf '# 读之前先看 [0]：如果哨兵与你预期的包不一致（例如回传的是旧包），后面所有"没生效"的结论都要作废。\n\n'

		printf '[运行的是哪套系统]\n'
		printf '型号/品牌/代号  : %s / %s / %s\n' \
			"$(prop_val 'ro\.product\.model')" "$(prop_val 'ro\.product\.brand')" "$(prop_val 'ro\.product\.device')"
		printf 'ROM 标识        : %s\n' "$(prop_val 'ro\.build\.display\.id')"
		printf '构建时间        : %s\n' "$(prop_val 'ro\.build\.date')"
		printf '小米侧包名版本    : %s\n' "$(prop_val 'ro\.build\.version\.incremental')"
		printf 'MIUI UI 版本      : %s\n' "$(prop_val 'ro\.miui\.ui\.version\.name')"
		printf 'com.miui.* 包数   : %s\n' "$(grep -a -m1 -o -E 'miui_pkg_count=[0-9]+' "$CAP/03_packages.txt" 2>/dev/null)"
		printf '底包(Oplus)证据   : %s\n' "$(prop_val 'ro\.vendor\.oplus\.market\.name')"
		printf 'SELinux         : %s\n' "$(getenforce 2>/dev/null)"
		printf '判定提示        : 上行 incremental 形如 OS*.*.*.*（小米包名）且 com.miui.* 包数 > 0 = 跑的是移植后的\n'
		printf '                  澎湃系统（DSU 或已刷机）；两个都为零而只有 Oplus 证据 = 跑的是原系统，本脚本的\n'
		printf '                  补丁相关结论一律不可用（ro.miui.os.version 在这两台上都是空，不能作为判据）。\n\n'

		printf '[0. 这块镜像到底带了什么（补丁落地哨兵）]\n'
		printf 'CPU FlexKws DEX 植入 : %s\n' "$(grep -a -E '^SENTINEL_CPU_KWS' "$CAP/50_landing.txt" 2>/dev/null | tr '\n' ' ')"
		printf '  全为 0 = 这块包不含 CPU 前端（旧包或 product 未刷新），ADSP 热唤醒仍跑属必然，不是新缺陷。\n'
		printf '各模块产物在位性   : %s\n' \
			"$(grep -a -E '^SENTINEL_RC' "$CAP/50_landing.txt" 2>/dev/null | sed -E 's/^SENTINEL_RC\[([^]]*)\]/\1/' | tr '\n' ' ' | cut -c1-420)"
		printf '唤醒模型/millet/节点 : %s\n' \
			"$(grep -a -E '^SENTINEL_(MODEL|MILLET_LOADED|NODE_ALIAS)' "$CAP/50_landing.txt" 2>/dev/null | tr '\n' ' ' | cut -c1-260)"
		printf '声学属性 SELinux 标签 : %s\n' \
			"$(grep -a -E '^PROPCTX' "$CAP/50_landing.txt" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
		printf '  参考：本模块只给 ro.vendor.audio.* 那批键定义 label（见 config/xiaoai_property_contexts），构建期键本来就没 label，\n'
		printf '  所以这一行为空或只列原厂键都是正常的，不参与判定。\n'
		printf '构建期开关不落 runtime : xiaoai_cpu_kws / pal_concurrent_capture / odm.prjname 是 apply.sh 自己消费的输入键，\n'
		printf '  getprop 查不到它们属正常，**不能当哨兵用**（上一版这里写错了，已修正）。\n'
		printf '小爱 rc 与 ro.键     : %s\n' \
			"$(grep -a -E '^SENTINEL_(RO_BOOT_PRJNAME|SRT_RUNTIME|SRT_ODM|SRT_GSI|SRT_VENDOR|RC_BODY)' "$CAP/50_landing.txt" 2>/dev/null | tr '\n' ' ' | cut -c1-320)"
		printf '  区分办法：rc 正文里没有我们那些 setprop，或 support_record_type 在三份 build.prop 里都不是 -1，就是包旧；\n'
		printf '  rc 正文有 setprop 但 runtime 仍取不到值，才是“载体失效”（ro. 键一旦先被写入，rc 里的 setprop 会被拒）。\n'
		printf 'appname 目标库哈希 : %s\n' \
			"$(grep -a -E '^SENTINEL_APPNAME' "$CAP/50_landing.txt" 2>/dev/null | tr '\n' ' ')"
		printf '底包 PAL 并发采集  : %s\n' \
			"$(grep -a -o -E 'concurrent_capture="[^"]*"' "$CAP/50_landing.txt" 2>/dev/null | head -n 4 | tr '\n' ' ')"
		printf '人脸 XML 与 TEE    : %s\n' \
			"$(grep -a -E '^RUNTIME_DEVICE=|^SENTINEL_TEE\[|^SENTINEL_REGION\[' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-160 | tr '\n' ' ')"
		printf 'MTP 翻转项         : %s\n' "$(grep -a -m1 '^SENTINEL_MTP=' "$CAP/50_landing.txt" 2>/dev/null)"
		printf 'MTP 装配面实读     : %s\n' "$(grep -a -E '^MTPNODE |^MTP_FFS_LS=|^MTP_GADGET_FUNCS=' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-150 | tr '\n' ';')"
		printf '  本行故意保留 ls 的失败输出：出现 Permission denied 是 SELinux 拒读，不等于节点不存在。\n'
		printf 'NFC HAL 阵营       : %s\n' "$(grep -a -E '^NFC_HAL_BINS=|^NFC_IFACE_DECL=|^NFC_SVC_STATE=' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-170 | tr '\n' ';')"
		printf 'LHDC/蓝牙 APEX     : %s\n' "$(grep -a -m1 '^SENTINEL_LHDC=' "$CAP/50_landing.txt" 2>/dev/null)"

		printf '\n[1. 声音断续]\n'
		printf '音频服务重启环     : 窗口内 audioserver 不同 pid=%s audio_hal 不同 pid=%s（理想各 1；>3 即每轮销毁重建播放流=时有时无）\n' \
			"$(grep -a '^TICK pid ' "$TICKS" 2>/dev/null | grep -a -o -E 'audioserver=[0-9]+' | sort -u | grep -c .)" \
			"$(grep -a '^TICK pid ' "$TICKS" 2>/dev/null | grep -a -o -E 'audio_hal=[0-9]+' | sort -u | grep -c .)"
		printf '  只数 ^TICK pid 行（91_ticks.txt 另有 rss_kb 行也叫 audioserver=…，那是内存不是 pid）。\n'
		printf '  audio_hal=0 先别当成 HAL 没跑：本行已按 audioserver/audiohalservice.qti 等名字探测，仍需看 98_auto_state 的 audio_procs 清单。\n'
		printf '崩溃周期分析       : %s\n' "$(crash_loop_analysis)"
		printf '  上面间隔接近整数秒（如 5s）就是 init 退避周期的崩溃环；崩溃环停止后本行应变成“未采到两次以上样本”。\n'
		printf 'HAL 实例死亡次数   : %s  (“HAL instance died, audio server is restarting”)\n' \
			"$(count_of 'HAL instance died' "$LIVE_LOG")"
		printf '崩溃环驱动者       : LOAD_PHRASE_MODEL=%s STHAL_-22=%s gsl=%s（与上面的环同周期即真凶；旧包走 ADSP 路线属预期）\n' \
			"$(count_of 'LOAD_PHRASE_MODEL' "$LIVE_LOG")" \
			"$(count_of 'status = -22' "$LIVE_LOG")" "$(count_of 'gsl_' "$LIVE_LOG")"
		printf '米音/空间声效果    : could not create effect=%s UUID不在HAL=%s MiSound行=%s\n' \
			"$(count_of 'could not create effect' "$LIVE_LOG")" \
			"$(count_of 'getHalDescriptorWithImplUuid UUID not found' "$LIVE_LOG")" \
			"$(count_of 'MiSound' "$LIVE_LOG")"
		printf '循环节律（重）     : 创建效果失败 %s；qguard 链接失败 %s；ADSP 重试 %s\n' \
			"$(loop_cadence 'could not create effect' "$win_minutes")" \
			"$(loop_cadence 'CANNOT LINK EXECUTABLE .*/vendor/bin/qguard' "$win_minutes")" \
			"$(loop_cadence 'LOAD_PHRASE_MODEL' "$win_minutes")"
		printf '  超过 ~6 次/分 即为固定周期的循环重试（别拿“总次数少”当“没问题”，窗口短时会漏判）。\n'
		printf '音量曲线与 vendor 参数 : checkAndSetVolume 越界=%s parseAndSetVendorParameters 失败=%s\n' \
			"$(count_of 'checkAndSetVolume invalid volume index' "$LIVE_LOG")" \
			"$(count_of 'parseAndSetVendorParameters' "$LIVE_LOG")"
		printf '  这两族与包新旧无关：HyperOS 下发的按设备音量曲线与 vendor 参数底包 HAL 不认，是独立的卡顿诱因。\n'
		printf '效果族细分         : 请求方=%s QcomEffectPresenter=%s 空间声属性被拒=%s\n' \
			"$(grep -a 'could not create effect' "$LIVE_LOG" 2>/dev/null | grep -a -o -E 'timeLow [0-9a-f]{8}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sort | uniq -c | sort -rn | head -2 | tr '\n' ';')" \
			"$(count_of 'QcomEffectPresenter' "$LIVE_LOG")" \
			"$(count_of 'Access denied finding property .persist\.vendor\.audio\.spatial|Access denied finding property .ro\.vendor\.audio\.fweffect' "$LIVE_LOG")"
		printf 'HAL 死法与底包崩溃环 : audio-hal 自 SIGKILL=%s lazy 拉起失败=%s qguard 链接失败=%s syshealthmon SIGSYS=%s\n' \
			"$(count_of 'Service .vendor.audio-hal.*received SIGKILL' "$LIVE_LOG")" \
			"$(count_of 'ctl\.interface_start.*(soundtrigger3|audio\.core\.IConfig|bluetooth\.audio)' "$LIVE_LOG")" \
			"$(count_of 'CANNOT LINK EXECUTABLE .\/vendor\/bin\/qguard' "$LIVE_LOG")" \
			"$(count_of 'Service .syshealthmon-service.*SIGSYS' "$LIVE_LOG")"
		printf '  后三项非 0 且 [0] 里 disable_oplus_crash_loop.rc 不是 FOUND 时，就是底包服务在每 5 秒重拉吃 CPU。\n'
		printf 'appname 音频下发   : %s  (只看音频上下文；>0 才说明 appname 定点修补未进镜像或另有发送点)\n' \
			"$(count_of 'appname=[+-]|setParameters.{0,40}appname' "$LIVE_LOG")"
		printf 'underrun/供数不足  : %s  (BUFFER TIMEOUT / out of sync 命中，配合 load 看是否 CPU 抢占)\n' \
			"$(count_of 'underrun|out of sync|BUFFER TIMEOUT' "$LIVE_LOG")"
		printf '音频侧 standby     : %s  (已排除 haptic/NFC 同名噪声)\n' \
			"$(count_of '(AudioFlinger|AudioTrack|StreamHal|PAL:).{0,60}standby' "$LIVE_LOG")"
		printf '真正信号崩溃       : %s  (Fatal signal/SIGSEGV/SIGABRT；0 表示是 binder 死亡而非段错误重启)\n' \
			"$(count_of 'Fatal signal|SIGSEGV|SIGABRT' "$LIVE_LOG")"
		printf 'init 惩罚态        : updatable_crashing=%s 进程=%s qguard=%s\n' \
			"$(prop_val 'sys\.init\.updatable_crashing')" \
			"$(prop_val 'sys\.init\.updatable_crashing_process_name')" "$(prop_val 'init\.svc\.qguard')"
		printf 'load average 轨迹  : %s\n' \
			"$(grep -a -o -E '^TICK load=[0-9.]+ [0-9.]+ [0-9.]+' "$TICKS" 2>/dev/null | awk '{printf "%s ", $2}' | head -c 400)"
		printf 'VT 常驻采集        : AudioFlow=%s onEnoughData=%s pid=%s cpu_jiffies=%s rss_kb=%s\n' \
			"$(count_of 'AudioFlow' "$LIVE_LOG")" "$(count_of 'onEnoughData' "$LIVE_LOG")" \
			"$(pidof_one 'com.miui.voicetrigger')" \
			"$(cpu_jiffies "$(pidof_one 'com.miui.voicetrigger')")" \
			"$(rss_kb "$(pidof_one 'com.miui.voicetrigger')")"
		printf 'tick 快照次数      : %s  (91_ticks.txt 的时间戳可与 90_logcat_live.txt 对齐)\n' \
			"$(count_of '^===== TICK' "$TICKS")"
		printf '连续日志总行数     : %s\n' "$(wc -l <"$LIVE_LOG" 2>/dev/null | tr -d ' ')"
		printf '日志窗口与重启     : 起=%s 止=%s 本次窗口分钟=%s 开机进度行=%s（>0 表示窗口跨过一次完整开机）\n' \
			"$(head -n 3 "$LIVE_LOG" 2>/dev/null | grep -a -o -E '^[0-9-]+ [0-9:]+' | head -n 1)" \
			"$(tail -n 2 "$LIVE_LOG" 2>/dev/null | grep -a -o -E '[0-9-]+ [0-9:]+\.[0-9]+' | tail -n 1)" \
			"$win_minutes" \
			"$(count_of 'boot_progress_start|Zygote64Timing|beginning of crash' "$LIVE_LOG")"
		printf '  注意：日志开头是环形缓冲里的历史（可比本次窗口早很多）；[1] 的“次/分”已按 tick 时间限窗，其余计数含历史。\n'

		printf '\n[2. 人脸]\n'
		printf '框架 face feature    : %s\n' "$(grep -a -m1 '^FACE_PM_FEATURES=' "$CAP/20_face_static.txt" 2>/dev/null | cut -c1-200)"
		printf 'face 服务            : %s\n' "$(grep -a -m1 '^FACE_SERVICES=' "$CAP/20_face_static.txt" 2>/dev/null | cut -c1-200)"
		printf 'vendor 特性声明在位  : %s\n' "$(grep -a -m1 'android.hardware.biometrics.face.xml' "$CAP/20_face_static.txt" 2>/dev/null | cut -c1-160)"
		printf '人脸数据条数(前/后)  : %s\n' "$(grep -a -E '^FACE_PRINTS_' "$CAP/20_face_static.txt" 2>/dev/null | cut -c1-200 | tr '\n' ' ')"
		printf '认证失败命中         : %s  (wasSuccessful=false / reject 相关行)\n' \
			"$(count_of 'wasSuccessful=false|"reject":[1-9]|reject=[1-9]' "$CAP/20_face_static.txt")"
		printf 'oiface 不可用命中    : %s  (非 0 说明 system 侧 Oplus 人脸服务确实不存在)\n' \
			"$(count_of "Can't find service|Can.t find service" "$CAP/92_face_log.txt")"
		printf '复现窗口命中日志     : %s\n' "$(grep -a -m1 'FACE_SAMPLE' "$CAP/20_face_static.txt" 2>/dev/null)"
		printf 'HAL 比对链         : 比对命令=%s errno501=%s ta_status失败=%s UNLOCK_FAILED=%s\n' \
			"$(count_of 'FACE_TA_CMD_FACECORE_AUTHENTICATE_COMPARE' "$LIVE_LOG")" \
			"$(count_of 'faceReeCompare] exit. errno=501' "$LIVE_LOG")" \
			"$(count_of 'QseeCa_dmabuf.*ta->status' "$LIVE_LOG")" \
			"$(count_of 'auth status UNLOCK FAILED' "$LIVE_LOG")"
		printf '  比对命令>0 而 errno501 接近相等 ⇒ HAL 已跑到 TA 比对，卡在 TA 而不是入口/权限/摄像头。\n'
		printf 'SmcInvoke 内存对象   : memobj_not_found=%s invalid_handle=%s（指纹侧同报但指纹能过 ⇒ 本族不是人脸 501 的根因）\n' \
			"$(count_of 'SmcInvoke_MinkDescriptor: mem obj.*not found' "$LIVE_LOG")" \
			"$(count_of 'SmcInvoke_MinkDescriptor: Invalid handle' "$LIVE_LOG")"
		printf '框架↔HAL 错码对齐   : InvalidErrorMessage=%s Authenticated日志行=%s（与 accept 计数矛盾时要拓 6T 基线对拍）\n' \
			"$(count_of 'FaceManager: Invalid error message' "$LIVE_LOG")" \
			"$(count_of 'BiometricLogger: Authenticated! Modality: face' "$LIVE_LOG")"
		printf '模板持久化与 TEE   : %s\n' "$(grep -a -E '^FACE_(STORE|TEE_NODES|BACKEND_SVC|HAL_BINS)=' "$CAP/20_face_static.txt" 2>/dev/null | cut -c1-165 | tr '\n' ';')"
		printf '  FACE_STORE 为空/不存在 ⇒ 模板没落地（“没模板”）；有文件仍 501 ⇒ TA 比对本身失败。\n'
		printf '后端缺失与权限     : osense=%s dcs=%s uad=%s face相关avc=%s camera服务=%s\n' \
			"$(count_of "could not get service\(osensemanager\)" "$LIVE_LOG")" \
			"$(count_of "can't get the commondcsservice" "$LIVE_LOG")" \
			"$(count_of 'setUadthread.*ret = -1' "$LIVE_LOG")" \
			"$(count_of 'avc.*hal_face' "$CAP/93_avc_log.txt")" \
			"$(grep -a -m1 '^CAMERA_SVC=' "$CAP/20_face_static.txt" 2>/dev/null | cut -c1-120)"

		printf '\n[3. NFC]\n'
		printf 'mState(前/后)        : %s\n' "$(grep -a -o -E 'mState=[a-z_]+' "$CAP/30_nfc_static.txt" 2>/dev/null | head -n 3 | tr '\n' ' ')"
		printf '节点/服务/包         : %s\n' "$(grep -a -E '^NFC_(NODES|INIT_SVC|PKG|SE)=' "$CAP/30_nfc_static.txt" 2>/dev/null | cut -c1-190 | tr '\n' ' ')"
		printf 'init 里的 HAL 定义   : %s\n' "$(grep -a -m1 '^NFC_INIT_DEF=' "$CAP/30_nfc_static.txt" 2>/dev/null | cut -c1-220)"
		printf '贴卡窗口命中         : %s\n' "$(grep -a -m1 'NFC_SAMPLE' "$CAP/30_nfc_static.txt" 2>/dev/null)"
		printf 'NFC 发现层定量     : startRfDiscovery 超时=%s enableDiscovery=%s setReaderMode=%s\n' \
			"$(count_of 'startRfDiscovery: Wait for completion timeout' "$LIVE_LOG")" \
			"$(count_of 'nfcManager_enableDiscovery' "$LIVE_LOG")" \
			"$(count_of 'setReaderMode' "$LIVE_LOG")"
		printf 'NFC 相关 avc         : %s\n' "$(count_of 'avc.*(nfc|Nfc|nci|tms)' "$CAP/93_avc_log.txt")"
		printf 'NFC 传输层硬错     : cmd_timeout=%s NFCC_TIMEOUT=%s recovery=%s 看门狗=%s VS命令status8=%s EE路由超时=%s\n' \
			"$(count_of 'nfc_ncif_cmd_timeout' "$LIVE_LOG")" \
			"$(count_of 'NFA_DM_NFCC_TIMEOUT_EVT' "$LIVE_LOG")" \
			"$(count_of 'toggle NFC state to recovery' "$LIVE_LOG")" \
			"$(count_of 'NfcService: run: Watchdog triggered' "$LIVE_LOG")" \
			"$(count_of 'nfaVSCallback: RSP status' "$LIVE_LOG")" \
			"$(count_of 'commitRouting: timeout' "$LIVE_LOG")"
		printf '  任一项非 0 就是控制器/传输层不响应，不是发现层配置问题；RF_INTF_ACTIVATED=%s（=0 表示从未真正贴过卡）。\n' \
			"$(count_of 'RF_INTF_ACTIVATED' "$LIVE_LOG")"
		printf 'INfc 归属与 HAL 阵营 : owner=%s bins=%s\n' \
			"$(grep -a -m1 '^NFC_INFC_OWNER=' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-170)" \
			"$(grep -a -m1 '^NFC_HAL_BINS=' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-150)"
		printf 'INfc 接口声明(rc)    : %s\n' "$(grep -a -m1 '^NFC_IFACE_DECL=' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-200)"
		printf '  非目标厂商的 HAL 抢注 INfc/default 时，owner 会不是 tms；修复后 owner 应包含 nfc-service-tms。\n'
		printf 'NFC 属性与标签       : %s\n' "$(grep -a -E '^NFC_PROP(VAL|CTX)=' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-190 | tr '\n' ' ')"
		printf 'TMS 配置落地       : %s\n' "$(grep -a -E '^TMS_(RUN_CONF|SEED_SRC|SEED_RC|NODE_ALIAS|SKU_PROP)=' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-175 | tr '\n' ';')"
		printf '  正例：/data/vendor/nfc/ 下有 libnfc-tms.conf 与 _RF_EC2.conf，/dev/thn31 是指向 tms_nfc 的软链。\n'
		printf 'TMS 控制面与 SE    : %s\n' "$(grep -a -E '^(TMS_SERVICES|TMS_SUBDIRS|TMS_TDT|SE_SVC_STATE|NFC_DATA_TREE)=' "$CAP/50_landing.txt" "$CAP/30_nfc_static.txt" 2>/dev/null | cut -c1-160 | tr '\n' ';')"
		printf 'NCI 模块加载         : NCI_HAL_MODULE期望=%s dlopen失败=%s conf读取失败=%s\n' \
			"$(grep -a -m1 '^TMS_RUN_CONF=' "$CAP/50_landing.txt" 2>/dev/null | cut -c1-140)" \
			"$(count_of 'dlopen.*nfc_nci|nfc_nci\.tmsnfc\.so' "$LIVE_LOG")" \
			"$(count_of 'Cannot open config file|Using default value for all settings' "$LIVE_LOG")"
		printf 'HAL 配置加载失败       : CannotOpenConfig=%s UsingDefault=%s dlopen失败=%s（非 0 即 conf 没读到或模块名不对）\n' \
			"$(count_of 'Cannot open config file' "$LIVE_LOG")" \
			"$(count_of 'Using default value for all settings' "$LIVE_LOG")" \
			"$(count_of 'dlopen.*nfc_nci|nfc_nci.*not found' "$LIVE_LOG")"

		printf '\n[4. 小爱免手唤醒]\n'
		printf '构建期开关          : %s（xiaoai_cpu_kws/hold/gap/window 是 apply.sh 消费的输入键，getprop 查不到属正常，不参与判定，见 [0]）\n' \
			"xiaoai_cpu_kws=$(prop_val 'xiaoai_cpu_kws') hold=$(prop_val 'xiaoai_cpu_kws_hold_ms') gap=$(prop_val 'xiaoai_cpu_kws_gap_ms') window=$(prop_val 'xiaoai_cpu_kws_window_sec')"
		printf '唤醒窗口命中日志     : %s\n' "$(grep -a -m1 'XIAOAI_SAMPLE' "$CAP/40_xiaoai_static.txt" 2>/dev/null)"
		printf 'ADSP 死路命中        : -22=%s set_custom_config=%s nonpersist=%s（非 0 说明仍在走 ADSP 路线）\n' \
			"$(count_of 'status = -22' "$LIVE_LOG")" \
			"$(count_of 'set_custom_config' "$LIVE_LOG")" "$(count_of 'nonpersist' "$LIVE_LOG")"
		printf '投递入口命中         : %s  (ACTION_VOICE_TRIGGER_START_VOICEASSIST / PermissionVoiceService)\n' \
			"$(count_of 'ACTION_VOICE_TRIGGER_START_VOICEASSIST|PermissionVoiceService' "$LIVE_LOG")"
		printf 'ASR 文本样本         : %s\n' "$(grep -a -o -E '\"text\":\"[^\"]{0,24}\"' "$LIVE_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | tr '\n' ';')"
		printf '唤醒真值（关键）     : 比对通过=%s wakeup_real行=%s 投递VA成功=%s\n' \
			"$(count_of 'isVoconWakeupPassed=true' "$LIVE_LOG")" \
			"$(count_of 'type=wakeup_real' "$LIVE_LOG")" \
			"$(count_of 'startFromVoiceTrigger' "$LIVE_LOG")"
		printf '  只有“比对通过>0 且 投递成功>0”才能说唤醒链路真通了；suspect 计数只反映窗口空转，不是故障。\n'
		printf 'CPU 前端引擎与节律   : 会话数=%s 采集start=%s 采集close=%s 失败日志=%s\n' \
			"$(count_of 'audioflow new handle' "$LIVE_LOG")" \
			"$(count_of 'startInput input .* source = 1999' "$LIVE_LOG")" \
			"$(count_of 'closeInput' "$LIVE_LOG")" \
			"$(count_of 'PortCpuKws|cpu kws re-arm failed|notify voiceassist failed' "$LIVE_LOG")"
		printf '  会话数≈分钟数×(60/(window+gap))；每会话都在重建 PAL 采集图，并发播放时是额外噪声。\n'
		printf 'ASR 回结果         : final行=%s 非空文本=%s（全为空或只等于唤醒词时要区分“只喊了唤醒词”与“指令被截”）\n' \
			"$(count_of '"is_final":true' "$LIVE_LOG")" \
			"$(grep -a -c -E '"is_final":true.*"text":"[^"]' "$LIVE_LOG")"
		printf 'VT 包与开关          : %s\n' "$(grep -a -m1 -E 'codePath|versionName' "$CAP/40_xiaoai_static.txt" 2>/dev/null | cut -c1-160)"
		printf 'odm 唤醒产物         : %s\n' \
			"$(grep -a -E '^SENTINEL_RC\[[^]]*xiaoai_wakeup_props\.rc\]|^SENTINEL_MODEL' "$CAP/50_landing.txt" 2>/dev/null | tr '\n' ' ')"

		printf '\n[5. 崩溃 / ANR / SELinux 收录]\n'
		printf 'avc denied 合计      : %s\n' "$(count_of 'avc:[[:space:]]*[Dd]enied' "$LIVE_LOG")"
		printf 'avc 归属分类         : %s\n' "$(grep -a -o -E 'scontext=u:r:[a-z_0-9]+' "$CAP/93_avc_log.txt" 2>/dev/null | sort | uniq -c | sort -rn | head -6 | tr '\n' ';')"
		printf '  只看移植侧域（hal_*/system_server/cameraserver/nfc）；untrusted_app 与 ksu 不算移植缺陷。\n'
		printf '取证干扰自测         : %s\n' "$(grep -a '^TICK self ' "$TICKS" 2>/dev/null | tail -n 2 | cut -c1-150 | tr '\n' ';')"
		printf '崩溃与退避命中     : %s  (Fatal signal/SIGSEGV/SIGABRT/SIGSYS/CANNOT LINK/received SIGKILL/has died/Watchdog/ANR/updatable_crashing)\n' \
			"$(count_of 'Fatal signal|SIGSEGV|SIGABRT|SIGSYS|CANNOT LINK|received SIGKILL|has died|Watchdog|ANR |updatable_crashing' "$LIVE_LOG")"
		printf 'ANR / tombstone 清单 : 见 06_crash_evidence.txt；正文收录在 captures/zz_*\n'
		printf 'zz_ 收录文件数       : %s\n' "$zz_count"
		printf '历史崩溃层         : dropbox 正文摘录=%s 条（条目名见 09_history_crash.txt），全部收录正文见 captures/zz_*\n' \
			"$(count_of '^----- /data/system/dropbox/' "$CAP/09_history_crash.txt")"
		printf '  若本行与 tombstone/ANR 清单全为空，说明开机至今没发生过 native 崩溃；非空则逐条对照日志时间轴。\n'
		printf '\n[6. 本次采集覆盖度自检]\n'
		printf '重项与模式         : 交互窗口=%s，重项=%s，自动探针=%s（auto=1 会临时改 NFC/USB 状态并尽量还原）\n' \
			"$([ "$NO_PAUSE" -eq 1 ] && echo '否（--no-pause，只有静态快照）' || echo '是')" \
			"$([ "$HEAVY" -eq 1 ] && echo '是（含 ANR/tombstone/dmesg/top/meminfo）' || echo '否（--no-heavy）')" \
			"$([ "$AUTO" -eq 1 ] && echo 1 || echo 0)"
		printf 'uid                  : %s（非 0 时多数证据会缺失）\n' "$(id -u 2>/dev/null)"
		printf '下一步定位顺序建议   : 91_ticks.txt（时间轴）→ 92_audio_log.txt / 92_xiaoai_log.txt（同一时刻对齐）→\n'
		printf '                      06_crash_evidence.txt 与 captures/zz_*（硬证据）→ 50_landing.txt（包版本）→ 05_kernel.txt。\n'
		true
	} >"$TRACE_DIR/SUMMARY.txt" 2>&1

	# ---- 自动探针结果追加到 SUMMARY（--auto / --full 时才有内容）
	if [ "$AUTO" -eq 1 ]; then
		{
			printf '\n[7. 自动探针与前后快照]\n'
			printf '探针动作       : %s\n' "$(grep -a 'PROBE ' "$CAP/97_probe_log.txt" 2>/dev/null | sed -E 's/^[0-9-]+ [0-9:]+ //' | head -n 40 | tr '\n' '|' | cut -c1-360)"
			printf '原始状态       : %s\n' "$(grep -a -m1 -E '^nfc_on=' "$CAP/97_probe_log.txt" 2>/dev/null)"
			printf '人脸计数轨迹   : %s\n' "$(grep -a -E '^face:|^bio_last:' "$CAP/98_auto_state.txt" 2>/dev/null | cut -c1-150 | uniq | tr '\n' ' ' | cut -c1-500)"
			printf 'NFC/VT 轨迹    : %s\n' "$(grep -a -E '^nfc:|^vt:' "$CAP/98_auto_state.txt" 2>/dev/null | cut -c1-140 | uniq | tr '\n' ' ' | cut -c1-500)"
			printf 'USB/MTP 轨迹   : %s\n' "$(grep -a -E '^usb:|^audio_svc:' "$CAP/98_auto_state.txt" 2>/dev/null | cut -c1-150 | uniq | tr '\n' ' ' | cut -c1-500)"
			printf '深度核查       : captures/65_deep_state.txt（身份硬判据 / 人脸服务 / NFC 轮询掩码 / MTP 前提 / 显示档位 / 音频抖动 / 底包环境）\n'
			printf '探针明细       : captures/97_probe_log.txt、快照明细 captures/98_auto_state.txt\n'
			true
		} >>"$TRACE_DIR/SUMMARY.txt" 2>&1
	fi

	# ---- MANUAL：只留机器抓不到的项（填完再跑一次 --pack 即可回传）
	MANUAL="$TRACE_DIR/MANUAL.txt"
	if [ ! -f "$MANUAL" ]; then
		cat >"$MANUAL" <<MANUAL_EOF
# 人工补填表（完全可选，不填也不影响取证；维护者主要看 SUMMARY.txt）
# 只填机器抓不到的主观/手感/界面项；数值与状态已由 SUMMARY.txt 自动给出。
# 如果你能确认一下包版本更好：本轮回传是新包还是旧包？（不确认也行，SUMMARY [0] 节会自己说）

包标签与版本(新包/旧包/不确定；不确定就写不确定) =

[声音]
断续发生在哪条通路(外放/听筒/有线耳机/蓝牙耳机) =
断续形态(约每几秒一次规律卡顿 | 随机 | App 起停瞬间 | 全程细碎爆音) =
自己数 1 分钟内出现几次 = ____ 次
断续时是否也在录音(语音输入/通话/扫码/小爱正在听) =
熄屏后有断续吗(熄屏播放 1 分钟观察) =
外放/耳机/蓝牙 三者里唯一没问题的是 =
把设置里的「空间音频/米音/音质音效」全部关掉后，断续是否消失 =

[人脸]
入口是否存在(设置→密码与安全 里有没有「人脸解锁」这一项) =
录入走到哪一步被拒(点入口就被拒/开始采集就被拒/采集完保存时报错) =
被拒时屏上的确切文案(逐字抄，别概述) =
之前录的那条人脸数据现在还在吗(被清空了/提示已存在/没有) =
解锁时屏幕提示的确切文案 =
按压指纹能否解锁(用来排除电源键与屏下指纹通路问题) =

[NFC]
设置里 NFC 开关能否打开(打开后是否自动回弹关闭) =
贴卡时有无震动/提示音/弹窗 =
贴的是哪种卡(公交/门禁/身份证/银行卡) =
「触碰与支付」里的默认支付应用设成了什么 =

[小爱]
免手唤醒开关当前状态(开/关/灰色不可开) =
喊「小爱同学」的实际反应(完全无声/应答音但不识别/识别后卡在"我在听") =
长按电源键唤起小爱能否正常听与答 =
熄屏时与亮屏时表现是否不同 =

[其它]
本次取证时系统在 DSU 还是已刷机(不确定就填「不确定」) =
问题从哪次刷机/哪次改动后开始出现 =
MANUAL_EOF
		printf '已生成人工填写表: %s\n' "$MANUAL"
	else
		printf '保留已存在的人工填写表(未覆盖): %s\n' "$MANUAL"
	fi

	printf '\n'
fi

# ---------------------------------------------------------------- 打包
printf '切片与 avc 汇总（最后一步）...\n'
if [ "$PACK_ONLY" -eq 0 ]; then
	printf '（每桶只留前 %s 行，写满即停扫；总数已写进 SUMMARY）\n' "$FILTER_MAX_LINES"
	slice_log
fi
BASENAME="issue_trace_${TAG_CLEAN}"
PARENT=$(dirname -- "$TRACE_DIR")
ARCHIVE=''
# 设备上的 zip / tar 选项子集不一，只用最基础的 -q -r / -czf；失败自然退到下一档。
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
printf '取证目录: %s\n' "$TRACE_DIR"
printf '关键结论: %s/SUMMARY.txt\n' "$TRACE_DIR"
printf '人工补填（可以不填）: %s/MANUAL.txt\n' "$TRACE_DIR"
if [ -n "$ARCHIVE" ]; then
	# 保证回传文件就在下载目录：采集目录落到非下载位置时，再复制一份到 Download。
	FINAL_ARCHIVE="$ARCHIVE"
	case "$ARCHIVE" in
	/sdcard/Download/*|/storage/emulated/0/Download/*) : ;;
	*)
		for dl in /sdcard/Download /storage/emulated/0/Download; do
			[ -d "$dl" ] && [ -w "$dl" ] || continue
			if cp -f -- "$ARCHIVE" "$dl/" 2>/dev/null && [ -f "$dl/$(basename -- "$ARCHIVE")" ]; then
				FINAL_ARCHIVE="$dl/$(basename -- "$ARCHIVE")"
				printf '已复制到下载目录: %s\n' "$FINAL_ARCHIVE"
				break
			fi
		done
		;;
	esac
	printf '回传文件: %s\n' "$FINAL_ARCHIVE"
	# shellcheck disable=SC2012 # FINAL_ARCHIVE 是本脚本自己生成的固定路径。
	printf '大小   : %s\n' "$(ls -lh -- "$FINAL_ARCHIVE" 2>/dev/null | awk '{print $5}')"
	printf '\n只需把上面这个 zip 文件发给维护者（就在「下载」目录里，不需要填任何东西）。\n'
	printf '若想补充人工结论（可选）：在 MT 管理器里编辑 %s/MANUAL.txt，再执行:\n' "$TRACE_DIR"
	printf '  sh %s --tag %s --pack\n' "$0" "$TAG_CLEAN"
else
	printf '设备上没有 zip/tar，未自动生成压缩包。\n'
	printf '请在 MT 管理器里长按目录 %s → 「压缩」为 zip 后发回。\n' "$TRACE_DIR"
fi

# 控制台直接印出关键结论，方便不便传文件时先拍屏回传。
if [ -f "$TRACE_DIR/SUMMARY.txt" ] && [ "${TRACE_NO_PRINT:-0}" -eq 0 ]; then
	printf '\n---------------- SUMMARY(前 110 行) ----------------\n'
	head -n 110 -- "$TRACE_DIR/SUMMARY.txt" 2>/dev/null
fi
printf '\n提醒: 先核对 SUMMARY 的 [0] 哨兵再下"补丁没落地"的结论；旧包缺 CPU 前端/属性属正常。\n'
