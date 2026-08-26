# 一加 15 Oplus reserve 块设备 SELinux 标签

## 改动分区

| 分区 | 改动 |
| --- | --- |
| vendor | 合并实际块节点 /dev/block/sdf2 的 file context，并登记实测的 Oplus reserve、gameopt、HAL 与守护进程 AVC 规则。 |
| odm | 同步合并到 precompiled_file_contexts，供 DSU 的早期策略使用。 |

当前一加 15 实机中，oplusreserve1 指向 /dev/block/sdf2。active precompiled_file_contexts 已有 oplusreserve alias 的 oppo_block_device 规则，但没有实际 sdf2 的精确规则。冷启动 Enforcing 取证证明标签计算已命中 oppo_block_device，但 ueventd 因缺少 blk_file create 被拒绝，导致 /dev/block/sdf2 根本没有创建。本模块因此同时交付实际节点 context 和具体类型的 ueventd 创建规则；目标 rild 原本已有该类型的读取契约，模块不扩大 rild 权限，也不创建不存在的 secinfo。

这是设备专属硬件布局，不能放入通用补丁。若更换机型或分区布局，必须重新核对 ls -lZ /dev/block/by-name/oplusreserve1 /dev/block/<partition> 后再修改配置。

策略由 common/fix_vendor_avc 合并到 normal/debug CIL。原 Oplus policy 将多个 reserve 客户端授权给 `oppo_block_device_202504`，但当前移植实际节点使用无法映射的 `oppo_block_device`。本模块因此只补齐日志中出现的 6 个 HAL/daemon 对该具体类型的 `blk_file open/read`。Engineer HAL 的 SN 查询实测需要 `open` 与 `read`，且会检索 reserve 挂载根目录，因而额外获得该具体目录类型的 `search`；不授予 `write`。gameopt 仅获得 `domain:dir search` 和 `domain:file read`，用于枚举 `/proc/<pid>` 并读取 `comm`，不获得进程控制权限。reserve 挂载链只补齐实际 `vendor_init` AVC 的 `relabelfrom`、`read`、`search`、`getattr`、`setattr`，标签限定为 reserve 根、system、media、system/config 与 media/log。Composer 仅获得 `vendor_smmu_proxy_device:chr_file` 的 `0x5500` 精确 ioctl xperm，不开放通用 ioctl。qsguard、wlchg、URCC、sensor-calibrate、cameramind 和两个 Oplus vendor app 同样只包含各自 AVC 中的精确 class/权限；cameramind 的域来自 system_ext，bundle 显式验证其 CIL 输入后才启用 Binder `call` 与 zygote socket `getopt`。不能使用 oppo_block_device_202504，因为目标平台没有为这个 Oplus 私有类型提供 mapping；不使用 permissive、dontaudit、通配类型或 rild allow。

2026-08-26 的一加 15 DSU Enforcing 取证确认了以上 AVC。规则尚未在包含本次改动的 DSU 冷启动镜像上验证，下一次冷启动后应重新采集 AVC，并检查 reserve 节点、gameopt 和充电/传感器服务没有新增拒绝。

## 执行

    bash port_main.sh devices/oneplus15/fix_oplusreserve_context

完整一加 15 流程会在 common/fix_mi_account 后、common/fix_vendor_avc 前执行本模块。
