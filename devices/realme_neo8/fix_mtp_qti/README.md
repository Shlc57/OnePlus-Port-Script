# 真我 Neo8 Qti MTP 适配

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `vendor` | `vendor/build.prop` 的 `vendor.usb.use_ffs_mtp` 由 `1` 置为 `0`。 |
| `system` | `system/system/etc/init/hw/init.usb.configfs.rc` 的 `mtp` 与 `mtp,adb` 两条装配触发器，门从 `ro.boot.ramdump=disable` 改为 `vendor.usb.use_ffs_mtp=0`。 |

两步都是文件内容修改，不改路径/属主/权限，因此无需同步 contexts/fsconfig。

## 为什么是独立模块（不用 `common/fix_mtp`）

`common/fix_mtp` 的机制是“用底包 `init.usb.configfs.rc` 覆盖 system 那份”，对一加 15 / Ace 6/6T（底包本身就用 configfs rc）有效。**Neo8 底包是 Qti USB**：

- 底包 `vendor/build.prop`：`vendor.usb.use_gadget_hal=0`、`vendor.usb.use_ffs_mtp=1`、`vendor.usb.controller=a600000.dwc3`。
- MTP 组合在底包 `vendor/etc/init/hw/init.qcom.usb.rc`，纯 `mtp/mtp,adb/ptp/ptp,adb` 在 `use_ffs_mtp=1` 分支挂 **ffs.mtp**（functionfs，需消费 `/dev/usb-ffs/mtp` 的 Oplus MTP 守护）；底包 vendor 没有 `init.usb.configfs.rc`。
- 移植 `system` 用小米原包 `init.usb.configfs.rc`，同一 `config=mtp && configfs=1` 走 **kernel `mtp.gs0`**。

逐字比对：realme 原厂 `system/etc/init/hw/init.usb.configfs.rc` 与小米原包该文件的
`mtp/ptp/idVendor/os_desc/UDC/...` 关键行**完全一致**。因此单纯用底包 rc 覆盖（`common/fix_mtp`
的机制）对 Neo8 是 **no-op**（而且真机 `/system/etc/init/hw/init.usb.configfs.rc` 在原厂就不存在）。

### 真机复现后的根因修正（必读）

只翻转 `use_ffs_mtp` 不够，真机表现为“**USB 用途只剩仅充电**”，原因是两侧同时失去装配者：

1. 底包 vendor rc 对纯 `mtp`/`mtp,adb` **只写了 `use_ffs_mtp=1` 的 ffs.mtp 分支**（L1921/L1934）；
   `use_ffs_mtp=0` 时只写 idVendor/idProduct（L1910/L1925）。`=0` 的 `mtp.gs0` 分支只存在于
   `mtp,diag*`、`mtp,mass_storage*` 等厂商组合。早期版本“纯 mtp 本就有 =0 分支”的说法是写反的。
2. HyperOS 移植侧（小米原包 system rc）的 `mtp`/`mtp,adb` 装配分支被 MIUI
   `Charger_MIUIChargerFrame` 加了 `&& property:ro.boot.ramdump=disable`（无门行被注释）。
   **Neo8 原系统全量 getprop 里没有 `ro.boot.ramdump`**（只有 `persist.vendor.ssr.enable_ramdumps`），
   所以该分支永不触发；`ptp`/`ptp,adb` 无门（可用作交叉验证：若 PTP 能枚举而 MTP 不能，即同一根因）。

因此本模块必须成对做两件事：置 `use_ffs_mtp=0`（消除与底包 ffs.mtp 抢 `f1`）+ 放开 system rc 的门
（使 HyperOS 侧真正 `symlink mtp.gs0`）。门改成 `vendor.usb.use_ffs_mtp=0` 而不是直接删除，
以保持与第一步的显式配对；`ramdump=enable` 的小米工程分支（含 mass_storage 暴露 ramdump 分区）保持原样。

目标/机制/依赖与 `common/fix_mtp` 都不同（改 vendor 属性 vs 换 system rc），且逻辑只对
Qti `use_ffs_mtp` 机型成立，无法抽象为共享补丁，故作为 Neo8 专属模块。

## 行为

1. `ensure_prop` 把 `vendor.usb.use_ffs_mtp=0` 写入 `vendor/build.prop`（该属性全树仅此一处定义、
   无脚本动态改写）：底包 vendor 的 ffs.mtp 挂接（1921/1934）与 zygote-start 的 functionfs
   `mtp/ptp` 挂载（条件 `=1`）都不再触发。
2. 用单次 awk 整行等值匹配改写 `init.usb.configfs.rc` 的两条触发器（不正则、不模糊匹配），
   写回前校验“新行已全部存在、旧行已全部消失”，再经 `replace_file_if_different` 原子替换并保留
   目标模式。目标 rc 不存在时 `warn` 并只跳过本子步骤；符号链接、非普通文件、或两条触发器
   既非旧形态也非新形态（HyperOS 版本变化）时**失败**，不静默放行。

幂等：属性已是 `0` 只跳过属性子步骤，**不会提前退出**而漏掉第二步；两步均已应用时输出两条
`SKIP`。重复执行得到相同结果（实测：第一次精确改 L50/L62 两行，第二次两步全 SKIP）。

## 执行

```bash
bash port_main.sh devices/realme_neo8/fix_mtp_qti
```

## 验证边界

根因已由“Neo8 原系统真机采集（全量 getprop 无 `ro.boot.ramdump`）+ 底包 vendor rc 与
HyperOS system rc 逐行取证”确定，且本模块已在真实工作树执行并核对：只改 L50/L62 两行、
模式仍 `0644`、重复执行全 SKIP。**但 MTP 能否枚举与读文仍需 DSU 真机确认**（此修复尚未在
真机验证，不得记为已生效）。刷机后应验证：选“传输文件”后 PC 能枚举并可读文件；
`getprop sys.usb.state` 为 `mtp`/`mtp,adb`；`ls -l /config/usb_gadget/g1/configs/b.1/f1`
指向 `mtp.gs0`；`getprop vendor.usb.use_ffs_mtp` 为 `0`；`logcat` 无 gadget/init 失败。
若仍不可用，优先查 `sys.usb.ffs.ready`（`mtp,adb` 分支需要它）与 SELinux denial，而不是改厂商
组合分支或回退成只翻属性。
