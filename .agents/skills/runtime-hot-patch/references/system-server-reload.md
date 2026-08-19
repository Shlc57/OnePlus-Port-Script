# system_server 与 framework 服务重载

## 1. 先判断是否真的需要 system_server

下列对象需要分别处理：

- App/SystemUI APK：通常只 force-stop 对应 package/process；若资源/共享 UID/特权权限由 PackageManager 缓存，才考虑更大边界。
- 独立 native daemon：重载其 init service，不涉及 system_server。
- `system_server` 内的 Binder service：没有独立 init service；它随 system_server 生命周期创建。
- framework JAR、bootclasspath/system-server classpath、framework resource 或由 system_server 启动时缓存的配置：通常需要重建 framework 进程状态。

先检查目标是否支持 `cmd <service>` reload、配置 observer、package restart、overlay enable/disable 或独立进程重启。能用更小边界时不要重启 framework。

## 2. 正确理解 Android 的重启边界

`system_server` 由 zygote 的 `--start-system-server` 派生，不是名为 `system_server` 的 init service。因此以下命令不是正确模型：

```text
setprop ctl.restart system_server
```

需要重建 system_server 时，优先使用当前构建公开的 ActivityManager userspace restart 接口；先从 help 确认：

```bash
adb shell 'cmd activity help | grep -A1 -B1 "^  restart"'
adb shell 'cmd activity restart'
```

该接口让旧 `system_server` 自行退出。zygote 的 system-server death handling 可能连带重建 zygote；不要预设 PID 变化范围，应实测。命令的 Binder 调用可能因为服务主动退出而以 `Broken pipe`/非零退出，不能单凭退出码判失败或成功。若构建没有这个接口，才对 rc 中确认过的真实 `zygote` init service 执行受控 stop/start。不要猜测 `zygote_secondary`、`zygote64` 等名字；读取 `/system/etc/init/hw/init.zygote*.rc` 和 `init.svc.*`。

重启 zygote/framework 会终止 system_server、SystemUI 和大量 app，短时断开 UI/服务；若 adb 依赖 framework 状态或补丁触及 PackageManager/AMS/WMS，存在启动循环风险。执行前：

1. 确认用户已知晓可见影响，并保存旧 PID、boot-completed 状态与日志基线；
2. 候选文件、idmap、APK/JAR 必须先完成结构/对齐/签名与可读性检查；
3. 确保 bind mount 对 init/zygote 所在 mount namespace 可见；不要在只影响临时 shell 私有 namespace 的挂载上做 framework 重启；
4. 明确恢复方案。对于会被 zygote/system_server 持有的文件，不得先 unlink 旧 inode；资源缓存需要同目录原子替换并保留合法 FD 生命周期。

还要记录 `/proc/sys/kernel/random/boot_id`、`ro.gsid.image_running`、`ro.gsid.dsu_slot` 和近期 persistent app 崩溃。framework restart 可能让潜伏的 persistent app 启动错误进入高速 crash loop，随后触发 RescueParty/硬重启；因此它不能作为无条件 smoke test。执行前应单独确认用户接受 UI 中断和可能掉出 DSU 的风险，并讨论是否预设下一次单次 DSU 启动。

## 3. 执行与有限等待

记录：

```bash
adb shell 'pidof system_server; getprop init.svc.zygote; getprop sys.boot_completed; getprop service.bootanim.exit'
```

使用设备实际支持、且已从 help/rc 验证的 framework restart 接口；不要跨 ROM 假设 `stop`/`start` shell 命令一定存在或行为相同。若使用 init property，则只操作已确认的 zygote init service，并把每一步当作异步请求。

启动后有限等待这些条件：

- system_server 新 PID 出现并持续存活；
- zygote init state 稳定为 running；
- `sys.boot_completed=1` 或目标服务自身 ready 条件恢复；
- PackageManager/ActivityManager/WindowManager/目标 Binder service 可响应；
- SystemUI/launcher 与目标功能可用。

`service check` 必须精确匹配 `Service <name>: found`；不能用宽松的 `grep found`，因为 `not found` 也会命中。

若 PID 连续变化、zygote 为 `restarting`、persistent app crash count 快速增长，或出现 watchdog/PackageManager parse/linker/SELinux 错误，立即停止继续重试。能通过卸载 bind 恢复时先恢复；设备重启是最后手段且须另获同意。adb 一旦断开并重新枚举，先比较 boot ID，并重新确认 `adb devices -l`、`ro.bootmode`、`ro.gsid.image_running=1`；若进入 recovery/原系统，不再执行任何写操作。

## 4. 本项目实测边界

2026-08-19 在已授权的 `nezha` DSU 上：

- `cmd activity restart` 返回 `Broken pipe`，但 zygote `2347 -> 17380`、system_server `4008 -> 17582`，boot ID 起初未变，核心 `activity/package/window` Binder 服务恢复；这确认了不能按命令退出码判定。
- 随后 persistent `com.android.nfc` 因 `mi_nfc` 注册失败进入高频崩溃，产生 ANR，并触发 `RescueParty` 硬重启到 recovery；这确认了核心 Binder 恢复也不代表系统稳定。
- HAL 独立重载没有触发该问题：`vendor.displayfeatureaidl-hal` 按 init stop/start 从 PID `2555` 变为 `17081`，对应 AIDL 实例恢复。

这些结果用于约束风险和验收项，不代表其他设备一定采用相同 PID、服务名或失败模式。

## 5. 交付边界

framework 热重载只证明当前 DSU、当前 namespace 与当前缓存状态下可运行。它不能证明：

- 下次启动选择同一 normal/userdebug SELinux policy；
- APK/JAR 签名、dexpreopt、verity 或 classpath 在冷启动时仍成立；
- 新增文件的 contexts/fsconfig 正确；
- Overlay/idmap 能从空缓存稳定生成。

这些必须在项目补丁和后续冷启动验证中单独记录。
