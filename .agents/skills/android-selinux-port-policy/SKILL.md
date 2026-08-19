---
name: android-selinux-port-policy
description: 为本 HyperOS 移植工程先热测、再固化和验证永久 Android SELinux 修补。用于从 AVC、原包策略和服务契约恢复独立域，补齐 file/property/service contexts 与分区 metadata，并把已验证的业务策略 bundle 交给统一入口合并；不用于仅做 ksud live policy、全局 Permissive 或原系统写分区。
---

# Android SELinux port policy

目标是得到经过 Enforcing 热测、可重复执行、可冷启动编译，且权限范围与真实服务契约一致的永久策略。运行时绕过只能提供证据，不能代替固化策略、contexts、metadata 与冷启动验证。

## 默认顺序：先热测，再落盘

```text
收集当前 AVC 与服务契约 -> 在工作树外整理最小候选规则
-> 已授权 DSU 上保持 Enforcing 热测 -> 收敛实际必要权限
-> 写入所属补丁的 CIL/contexts/metadata -> 完整策略静态验证 -> 冷启动确认
```

- 修补 allow、标签或服务契约时，默认先不修改仓库中的 CIL、contexts 或 bundle。进入设备步骤时使用 `$runtime-hot-patch`，先完成 adb 授权、DSU、root、Enforcing、工具和恢复边界检查，再用当前 DSU 的 `ksud sepolicy check` 与临时 `patch`/`apply` 验证候选 allow。
- 热测必须复现同一个最小业务操作，确认原 AVC 消失、功能成功且没有新增下游 AVC；每轮只加入当前证据支持的最小规则。live policy 是直到重启的加法状态，若误加宽规则导致测试被污染，不得把后续结果当作最小权限证明。
- 只有热测确认为必要的规则才转成所属业务补丁的 CIL，并补齐 contexts 与 metadata。这里的“落盘”专指修改本项目的永久策略输入并交给统一入口生成，不是写入 KernelSU `profile set-sepolicy`。
- 若没有已授权设备、设备不是 DSU、当前 DSU 缺少可用 `ksud`，或候选涉及无法热加载的新类型/domain transition，记录无法热测的具体原因后才进行静态落盘，并把 Enforcing 热测列为未完成；不得把静态编译结果表述为热测通过。

## 先确定所有权

- 具体服务或功能补丁拥有自己的 CIL、contexts 和启用条件，并在修改工作树前验证完整依赖。例如账号链由 `common/fix_mi_account` 整理 mtd 策略 bundle。
- `common/fix_vendor_avc` 是下游统一事务入口：消费已启用补丁的 bundle，合并 normal/debug vendor CIL，统一写回 contexts 并清理 stale precompiled policy。不要把上游服务名、二进制路径或业务契约再次硬编码到下游。
- `common/selinux_merge` 只负责模板展开、ABI 检查、去重、marker 和确定性写回。不得把设备或业务 allow 放进通用 merger。
- 只有多个补丁都需要且语义稳定的清单解析、安全路径检查或 metadata 操作才进入 `tools.sh`。

修改当前账号链或 bundle 格式时，读取 [references/bundle-contract.md](references/bundle-contract.md)。分析域、标签和规则时，读取 [references/policy-design.md](references/policy-design.md)。准备落盘、编译、设备验证或交付时，读取 [references/validation.md](references/validation.md)。

## 建立完整契约

从真实消费者开始，串起以下链路，缺一项都不能把修复视为完成：

```text
init rc -> executable label -> domain transition -> linker namespace
        -> Binder/AIDL/HIDL service label -> client/server allow
        -> property labels -> property_service/file allow
        -> data/device/firmware labels -> 最小文件与设备权限
```

优先修正错误标签或错误域。不要为了消除 AVC，把 vendor daemon 映射到无关的平台核心域；进程域同时决定 linker namespace 与可见库，错误兼容域可能表现为 `library ... not found`，即使文件实际存在。

规则来源按可信度排序：当前 Enforcing 复现、原包同版本策略与 contexts、init/VINTF/ELF 依赖、目标策略已有类型与 neverallow。仅凭 `audit2allow`、单条 AVC 或进程名猜规则都不够。

## 写入原则

- 在首次写工作树前验证来源文件、目标分区、rc 接口、fragment、context 类型、metadata 与工具。
- 原包 CIL 的 `base_typeattr` ABI 不兼容时，不整包导入；只移植该服务实际需要的类型、属性成员和窄范围规则。
- 引用平台版本化类型时使用 `${API_VERSION}`，由统一 merger 展开；vendor 自有稳定类型不要擅自版本化。
- 新增 executable、数据路径、property 或 service 类型时，同时声明正确的 typeattribute 集合、`roletype object_r` 与对应 contexts。
- 同一路径或键必须以补丁条目覆盖旧值，并在整个目标文件中去重。contexts 比较忽略反斜杠转义差异，写回保留最终选中表达。
- 分区内新增路径同步更新最终分区 contexts/fsconfig；`/data` 等运行时路径只进入实际加载的 file_contexts，不能写入 odm/vendor 打包 metadata。
- 所有输出先生成到 `mktemp` 文件，完成符号、格式、唯一性、幂等和策略编译检查后再原子安装。重复执行必须得到相同结果。

## 设备边界

检测到 adb 设备时遵守项目 `AGENTS.md` 的授权和 DSU 约束。临时 bind mount、标签实验或 ksud 规则统一使用 `$runtime-hot-patch`；未取得授权前只允许探测设备是否存在，不能为了满足热测优先而越过设备授权。始终保持 Enforcing，除非用户明确同意一个有停止条件的诊断窗口；诊断后立即恢复 Enforcing。

不得擅自重启设备。新类型和冷启动 domain transition 通常无法完整热加载进当前内核策略；把“当前 Enforcing 热测可用”和“完整策略冷启动确认”明确分开报告。

## 完成标准

至少满足：可热测的候选规则已在 Enforcing 下验证，或已记录不能热测的具体原因；业务补丁与统一入口职责清晰；normal/debug 策略及所有 context 目标幂等；完整 split CIL 可由当前 `secilc` 编译；Shell/Python/metadata 测试通过；README 写明输入、目标、contexts/fsconfig 行为、风险与实际验证边界。未经冷启动验证，不得宣称永久策略已经实机生效。
