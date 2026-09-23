# 真我 Neo8 Qti MTP 适配

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `vendor` | 把 `vendor/build.prop` 的 `vendor.usb.use_ffs_mtp` 由 `1` 置为 `0`（仅属性内容，不改 contexts/fsconfig）。 |

## 为什么是独立模块（不用 `common/fix_mtp`）

`common/fix_mtp` 的机制是“用底包 `init.usb.configfs.rc` 覆盖 system 那份”，对一加 15 / Ace 6/6T（底包本身就用 configfs rc）有效。**Neo8 底包是 Qti USB**：

- 底包 `vendor/build.prop`：`vendor.usb.use_gadget_hal=0`、`vendor.usb.use_ffs_mtp=1`、`vendor.usb.controller=a600000.dwc3`。
- MTP 组合在底包 `vendor/etc/init/hw/init.qcom.usb.rc`，纯 `mtp/mtp,adb/ptp/ptp,adb` 在 `use_ffs_mtp=1` 分支挂 **ffs.mtp**（functionfs，需消费 `/dev/usb-ffs/mtp` 的 Oplus MTP 守护）；底包 vendor 没有 `init.usb.configfs.rc`。
- 移植 `system` 用小米原包 `init.usb.configfs.rc`，同一 `config=mtp && configfs=1` 走 **kernel `mtp.gs0`**。

逐字比对：realme 原厂 `system/etc/init/hw/init.usb.configfs.rc` 与小米原包该文件的
`mtp/ptp/idVendor/os_desc/UDC/...` 关键行**完全一致**。因此换 system rc（`common/fix_mtp`）
对 Neo8 是 **no-op**，真正的分歧只在 **ffs.mtp（vendor）vs mtp.gs0（system/HyperOS 框架）**：
HyperOS 框架与其自带 system rc 都按 kernel `mtp.gs0` 驱动 MTP、不对接 Oplus ffs.mtp 契约，
两条 init 触发器对同一属性双触发、f1 最终落到无人消费的 ffs.mtp → MTP 不可用。

目标/机制/依赖与 `common/fix_mtp` 都不同（改 vendor 属性 vs 换 system rc），且逻辑只对
Qti `use_ffs_mtp` 机型成立，无法抽象为共享补丁，故作为 Neo8 专属模块。

## 行为

`ensure_prop` 把 `vendor.usb.use_ffs_mtp=0` 写入 `vendor/build.prop`（该属性全树仅此一处定义、
无脚本动态改写）：

- 底包 vendor 的 ffs.mtp 挂接（1921/1934/1949/1964 行）与 zygote-start 的 functionfs
  `mtp/ptp` 挂载（条件 `=1`）都不再触发；
- system 那份 kernel `mtp.gs0` 成为唯一 MTP 组合者，与 HyperOS 框架一致；
- 厂商 `mtp,diag`/`rndis` 等组合本就有 `use_ffs_mtp=0` 的 `mtp.gs0` 分支，不受影响。

幂等：已是 `0` 时 `skip_print` 并退出；重复执行得到相同结果。`vendor/build.prop`
不存在时 `warn` 并只跳过本 prop 子步骤；为符号链接或非普通文件时失败。仅改属性内容，
不动路径/属主/权限，无需同步 contexts/fsconfig。

## 执行

```bash
bash port_main.sh devices/realme_neo8/fix_mtp_qti
```

## 验证边界

根因与修法均由底包分区（`vendor/build.prop` + `init.qcom.usb.rc` + 两份 system rc 逐字比对）
静态确定，**尚未在真机确认**。刷机后应验证：选“传输文件(MTP)”后 PC 能枚举设备且可读文件、
`getprop sys.usb.state` 为 `mtp`/`mtp,adb`、`/config/usb_gadget/g1/configs/b.1/f1` 指向
`mtp.gs0`、`logcat` 无 MTP/gadget 相关失败。若真机仍异常（例如 HyperOS 侧另有 ffs 期望或
SELinux 拒绝），再按实际证据补最小 allow/属性，而非回退到 rc 替换。
