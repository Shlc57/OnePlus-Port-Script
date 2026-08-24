---
name: runtime-hot-patch
description: 在 Android DSU 上规划和验证临时运行时热修补，包括文件替换、HAL/init 服务重载、framework 边界判断和临时 SELinux 规则。适合需要快速获得运行时证据、随后再整理为永久补丁的调试工作。
---

# Runtime hot patch

把热修补当作可回收的实验：建立基线，缩小变更和重载范围，复现目标行为，记录证据，再决定是否固化到仓库补丁。

## 工作方法

1. 先确认设备、DSU 状态、Enforcing 状态和目标文件/服务的基线（路径、hash、context、PID、接口和日志）。涉及真实设备时按项目授权流程操作。
2. 根据消费者选择最小边界：配置 reload、单个 HAL/init 服务、应用进程，或确需重建时的 zygote/system_server。init service、进程名和 Binder/HIDL 实例要分别确认。若重载 Composer/HWC，必须同步重载 SurfaceFlinger；只重载 Composer 时，SurfaceFlinger 不会自动对接到新 Composer。
3. 候选文件放在设备 tmpfs，再对解析后的单个目标做 bind mount；替换后重载真正读取它的消费者，并用 mountinfo、hash 和 context 复核。
4. 遇到 AVC 时优先做 SELinux 热修补：从 `scontext/tcontext/tclass/permission` 和真实操作建立一组有边界的较大候选规则，先检查语法，再临时注入并重放同一操作；确认可用后逐步收敛成小规则。无法等价重放的早期拒绝，再转为静态策略分析。
5. 验证新 PID/启动时间、接口注册、真实功能、日志稳定性和新增 AVC；实验结束时卸载精确挂载、恢复服务状态，并记录哪些结论只对当前运行时有效。

## 参考资料

- HAL 或独立 init 服务：`references/hal-reload.md`
- system_server/framework：`references/system-server-reload.md`
- ksud 临时 SELinux：`references/ksud-selinux.md`
