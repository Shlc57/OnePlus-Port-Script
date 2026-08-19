# HAL 与独立 init 服务重载

## 1. 从消费者回溯真实服务

先区分四个名字：

- init service name：`service <name> <executable>` 中的 `<name>`，这是 `ctl.stop/start/restart` 使用的值；
- Linux process/executable；
- AIDL instance，例如 `android.hardware.power.IPower/default`；
- HIDL instance，例如 `vendor.foo@1.0::IFoo/default`。

这些名字经常不同。用目标二进制/库、rc 和接口交叉确认，不要根据文件名猜 init service：

```bash
adb shell 'grep -R -n -F "/vendor/bin/hw/example-service" /vendor/etc/init /odm/etc/init /system/etc/init 2>/dev/null'
adb shell 'getprop init.svc.<init-service>; pidof <process-name>; ps -A -Z | grep -F <process-name>'
adb shell 'service list | grep -F <aidl-instance>; lshal 2>/dev/null | grep -F <hidl-instance>'
```

还要读取完整 rc stanza，确认 `class`、`user`、`group`、`seclabel`、`interface`、`disabled`、`oneshot`、`critical`、`reboot_on_failure`、socket 与依赖触发器。`critical`、存储/电源/显示/输入/无线电等关键 HAL 的风险高于普通服务；若无法隔离恢复，先请求用户确认测试窗口。

## 2. 替换与重载顺序

1. 记录旧 PID、`init.svc.<name>`、接口实例、目标 hash/context 和日志基线。
2. 把候选放在 tmpfs 并 bind mount 到真实目标。若替换的是服务直接加载的 `.so`，必须重启加载它的进程；重启其客户端不能让旧进程重新 `dlopen`。
3. 优先显式 `stop` -> 等待 `stopped`/旧 PID 消失 -> `start` -> 等待 `running`/新 PID，而不是只发 `ctl.restart` 后假定成功：

   ```bash
   adb shell 'setprop ctl.stop <init-service>'
   adb shell 'getprop init.svc.<init-service>; pidof <process-name>'
   adb shell 'setprop ctl.start <init-service>'
   adb shell 'getprop init.svc.<init-service>; pidof <process-name>'
   ```

   `stop`/`start` 都是异步请求；要有限时轮询并在 crash/restarting/timeout 时停止，不做无限重试。若原状态是 stopped/disabled，验证后恢复原状态。
4. 先确认服务成功注册，再重启仍缓存旧 binder/death state 的最小客户端。多数 Binder 客户端能通过 death recipient 重连；只有证据显示不会重连时才扩大重启范围。

`kill -9` 仅用于确认 init supervision 或无 ctl 权限时的诊断，不是默认重载方式。它可能绕过服务清理，并由 init 立即拉起导致竞态。

## 3. 验证服务真的换新

仅看到 `running` 不够。至少确认：

- PID 或 `/proc/<pid>/stat` start time 已变化；
- `/proc/<pid>/maps` 中库路径/挂载与预期相符（若替换 `.so`）；
- AIDL `service check`/`service list` 或 HIDL `lshal` 实例已恢复；
- 目标接口的真实调用成功，而非只有注册成功；
- `logcat`、`dmesg` 无 linker namespace、missing symbol、VINTF、SELinux、tombstone 或反复重启错误。

不要为了“刷新”单个 HAL 重启 `servicemanager`/`hwservicemanager`/`vndservicemanager`。注册中心重启会影响大量无关服务，且不能保证消费者正确重连。

判断 `service check` 时必须匹配完整成功结果（例如 `^Service <name>: found$`）；字符串 `not found` 也包含 `found`，宽松 grep 会制造假阳性。

## 4. 恢复

停止目标服务，卸载精确 bind target，确认底层 hash/context 恢复，再按实验前状态启动。若无法卸载（busy）或客户端持续崩溃，停止扩大操作并报告；设备重启需要用户明确同意。
