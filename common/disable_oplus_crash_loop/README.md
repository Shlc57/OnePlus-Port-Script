# 停掉底包崩溃环服务（qguard / syshealthmon-service）

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 新增 `odm/etc/init/disable_oplus_crash_loop.rc`：`on early-init` 里 `disable`，`on property:sys.boot_completed=1` 里 `stop`；同步该路径的 contexts（`vendor_configs_file`）与 fsconfig（`0 0 0644`）。 |

本补丁不修改 `vendor`、不删除任何二进制、不补库、不改 SELinux 策略。

## 模块说明

真机取证（2026-09-30 真我 Neo8，移植侧系统）抓到两个从开机早期就无限重启的底包服务：

```text
F linker: CANNOT LINK EXECUTABLE "/vendor/bin/qguard": library "libbase.so" not found: needed by main executable
init    : Service 'qguard' (pid 6036) exited with status 1                      → init.svc.qguard=restarting
init    : Service 'syshealthmon-service' (pid 5227) received SIGSYS from uid 1000 → init.svc.syshealthmon-service=restarting
```

- `qguard`（`/vendor/bin/qguard`）：链接阶段就失败，`CANNOT LINK EXECUTABLE ...: library "libbase.so" not found: needed by main executable`，
  退出码 1。**注意根因尚未定性**：真机历史上见过 `/vendor/lib64/libbase.so` 实际存在的情况，所以不能断定为
  “文件缺失”，更可能是 vendor linker namespace 解析不到（`ld.config` 路径与 DSU 挂载布局不匹配）。两种情况的
  处置结果相同：这个进程在本组合下从未跨过动态链接，**一条自己的日志都没打过**。
- `syshealthmon-service`（`/vendor/bin/vendor.qti.syshealthmon-service`）：自带 minijail 日志，能直接看到死因：
  `libminijail[...] logging seccomp filter failures` → `libminijail[...] **blocked syscall: lseek**` → 进
  程收 `SIGSYS` 被杀。即 QTI 自带的 seccomp 策略不允许这个二进制实际用到的 `lseek`，它在当前组合下启动即死。
- 两者的重启都被 init 记账：`process with updatable components 'qguard' exited 4 times in 4 minutes`（本回传 45 次）、
  同一句的 `syshealthmon-service` 版也 45 次，并且 `sys.init.updatable_crashing_process_name` 就是 `syshealthmon-service`；
  所以它们还会把其他可更新服务（包括 audio）的重拉带进指数退避。

职责边界（为什么停它们不弄坏移植侧功能）：`qguard` 是 Oplus/realme 自己的 vendor 守护进程（看护其他 Oplus
进程并上报异常）；`syshealthmon-service` 是 QTI 的用户态健康监控 HAL（向 diag/上层上报子系统健康与 SSR 类事件）。
两者在本组合下**从未成功运行过一步**，因此不存在“停掉后失去已有能力”；HyperOS 框架也不引用它们。ADSP/modem
的掉电恢复与 SSR 通知本身在内核侧（`qcom_sysmon`、`qcom_pd_mapper`、`qcom_va_minidump` 模块仍在），
**不受本补丁影响**；丢的只是 Oplus/QTI 那一层本就没跑起来的上报代理。

两者都会被 init 按退避节奏每 5 秒重拉一次，只贡献 CPU 抖动（同一台机器 1 分钟 load 平均 9.3、峰值 11.2，且上一轮 `sys.init.updatable_crashing_process_name` 就是 `syshealthmon-service`），不参与 HyperOS 侧任何功能链路。修复遵循最小侵入：不下发新的 so、不改底包 rc、不动策略，只用 init 原生的 `disable` + `stop` 把这两个服务从启动集合里摘掉。

`disable` 只对 `class_start` 生效，因此额外在 `sys.boot_completed=1` 补一次 `stop`，覆盖别处用 `start`/`ctl.start` 显式拉起的情况。

## 前提与降级

- 底包 `vendor/etc/init`、`odm/etc/init` 里**没有** `service qguard` / `service syshealthmon-service` 定义时，只警告并跳过该服务；两个都没有时整体 `skip_print` 退出，不写工作树、不改 metadata。
- 服务已定义但可执行文件不在预期路径时仍下发 `disable`（`disable` 只依赖服务注册，不依赖文件存在），并在输出里警告以便真机复核。
- 重复执行安全：rc 内容一致时只同步 metadata，不重复写文件；metadata 条目由 `merge_*` 接口按路径去重。

## 执行

```bash
bash port_main.sh common/disable_oplus_crash_loop
# 当前由真我 Neo8 组合流程引入（RealmeNeo8_port.sh）
bash RealmeNeo8_port.sh
```

## 真机核对命令（根因定性与回滚）

```sh
ls -l /vendor/lib64/libbase.so /system/lib64/libbase.so      # 存在→namespace 问题；缺失→依赖缺失
cat /vendor/etc/init/*qguard*.rc                             # 看 class/user/socket/seclabel 与服务依赖
strings /vendor/bin/qguard 2>/dev/null | grep -iE 'watchdog|restart|service|prop' | head
cat /sys/fs/selinux/policy >/dev/null 2>&1; getenforce
```

回滚：删除 `/odm/etc/init/disable_oplus_crash_loop.rc` 并重启即可完全恢复（本补丁不删二进制、不改原包 rc）。

## 验证边界

真机判据来自 [`tools/issue_trace.sh`](../../tools/issue_trace.sh) 的回传：`captures/11b_svc_state.txt`
里 `init.svc.qguard` / `init.svc.syshealthmon-service` 应为 `stopped` 或空，`captures/00_meta.txt`
与 SUMMARY 的 `各模块产物在位性` 应显示 `/odm/etc/init/disable_oplus_crash_loop.rc` 为 `FOUND`，
`91_ticks.txt` 的 load 轨迹应显著下降。**尚未在真机复验**：本轮结论来自旧包（不含本补丁）的取证，
效果需下一次带本补丁的包回传后确认。
