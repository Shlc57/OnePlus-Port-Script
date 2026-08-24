---
name: android-selinux-port-policy
description: 分析 HyperOS 移植中的 Android SELinux 拒绝，并把结论整理为可维护的策略、contexts 和 metadata 修改。适合需要区分运行时证据与静态/冷启动证据的策略移植工作。
---

# Android SELinux port policy

用“现象 → 服务契约 → 热修补确认 → 规则收敛 → 分级验证”的方法处理策略问题，优先获取 SELinux 热修补证据。

## 工作方法

1. 从 AVC、进程域、文件/服务/property 标签、init rc 和接口注册状态开始，确认实际失败链路。先修正明显的 executable、domain transition 或 context 错误，再考虑 allow。
2. 优先判断能否在当前启动中重放并进行 SELinux 热修补。能重放时，先按 AVC 和服务契约注入覆盖面较大的、但限定源域/目标域/class 的候选规则；确认功能恢复后，再逐步删除权限和目标，收敛成小规则。不能重放时，以原包策略、init/VINTF/ELF 契约和完整 split policy 编译为主，并把冷启动保留为后续证据。
3. 从消费者反推出完整契约：`init → executable → domain → linker namespace → Binder/AIDL/HIDL → property/data/device`。每条规则都尽量关联到契约、原包策略或当前 AVC。
4. 让业务补丁拥有自己的 CIL、contexts 和启用条件；统一入口只负责 bundle 合并、去重和确定性写回。新增分区路径时一并检查最终分区的 contexts/fsconfig。
5. 先在临时文件中生成和检查结果，再原子写回；重复执行应保持稳定。必要时读取 `references/` 中的 bundle、策略设计和验证说明。

## 结果表达

把结果分成静态检查、Enforcing 热测、热测不适用和冷启动确认。不要把局部运行时成功或打包成功直接等同于永久策略已在设备上生效。
