# 一加 15 Oplus reserve 块设备 SELinux 标签

## 改动分区

| 分区 | 改动 |
| --- | --- |
| vendor | 合并实际块节点 /dev/block/sdf2 的 file context，并登记 ueventd 的精确创建规则。 |
| odm | 同步合并到 precompiled_file_contexts，供 DSU 的早期策略使用。 |

当前一加 15 实机中，oplusreserve1 指向 /dev/block/sdf2。active precompiled_file_contexts 已有 oplusreserve alias 的 oppo_block_device 规则，但没有实际 sdf2 的精确规则。冷启动 Enforcing 取证证明标签计算已命中 oppo_block_device，但 ueventd 因缺少 blk_file create 被拒绝，导致 /dev/block/sdf2 根本没有创建。本模块因此同时交付实际节点 context 和一条具体类型的 ueventd 到 oppo_block_device 的 blk_file create 规则；目标 rild 原本已有该类型的读取契约，模块不扩大 rild 权限，也不创建不存在的 secinfo。

这是设备专属硬件布局，不能放入通用补丁。若更换机型或分区布局，必须重新核对 ls -lZ /dev/block/by-name/oplusreserve1 /dev/block/<partition> 后再修改配置。

策略由 common/fix_vendor_avc 合并到 normal/debug CIL。规则使用具体的 ueventd、mdm_feature、oppo_block_device 和 tmpfs 类型：补齐 ueventd 对节点的 create/getattr/setattr，补齐 mdm_feature 对节点的 open/read/write，并补齐 oppo_block_device -> tmpfs:filesystem associate。不能使用 oppo_block_device_202504，因为目标平台没有为这个 Oplus 私有类型提供 mapping。截至 2026-08-25，DSU Enforcing 实机已确认 reserve 节点创建链和 IMEI 恢复；SN 仍未恢复，后续需继续追踪 idmanager 的 SN 返回链，不能把本模块视为 SN 修复。

## 执行

    bash port_main.sh devices/oneplus15/fix_oplusreserve_context

完整一加 15 流程会在 common/fix_mi_account 后、common/fix_vendor_avc 前执行本模块。
