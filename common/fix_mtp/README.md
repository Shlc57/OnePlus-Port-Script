# 修复 MTP USB 配置

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system` | `replace` 模式：替换 `system/system/etc/init/hw/init.usb.configfs.rc`；`gate` 模式：只改写其中 `mtp` 与 `mtp,adb` 两条装配触发器的属性门。 |
| `vendor` | 仅 `gate` 模式：`vendor/build.prop` 的 `vendor.usb.use_ffs_mtp` 收敛到 `FIX_MTP_FFS_VALUE`。 |

两种模式都是文件内容修改，不改路径/属主/权限，因此无需同步 contexts/fsconfig。

## 模式选择

由机型组合入口通过 `FIX_MTP_MODE` 选择（缺省 `replace`，未显式设置的机型行为不变）：

- `replace`（一加 15、一加 Ace 6、一加 Ace 6T）：用底包 `init.usb.configfs.rc` 覆盖原包目标，使
  MTP、PTP 与 ADB 的 configfs 触发器匹配当前底包 USB 栈。内置的 `init.usb.configfs.rc` 来自一加 15
  底包；其他底包由入口通过 `FIX_MTP_SOURCE_RC` 指定本机型的底包 rc 绝对路径。MTP 内核函数路径
  （`mtp.gs0`）只在 `vendor.usb.use_ffs_mtp=0` 时启用，避免与 vendor rc 的 FunctionFS MTP 路径重复挂接。
  执行前会校验必要的 MTP 触发器；替换保留目标文件模式；目标 RC 不存在时只警告并跳过；来源与底包
  USB 栈不一致会导致错误的 MTP 触发器，更换底包时必须核对。
- `gate`（真我 Neo8，Qti `use_ffs_mtp` 机型）：**不覆盖整份 rc**，只把 `mtp`/`mtp,adb` 两条装配分支的
  门收敛到 `property:vendor.usb.use_ffs_mtp=${FIX_MTP_FFS_VALUE}`，并把该属性写成同一个值。必须由入口
  显式提供 `FIX_MTP_FFS_VALUE=0|1`，缺失即失败——模式本身不含任何机型硬编码。

## gate 模式的成因（真我 Neo8，真机否证过程）

Neo8 底包是 Qti USB：`vendor/build.prop` 原值 `vendor.usb.use_gadget_hal=0`、`vendor.usb.use_ffs_mtp=1`。
MTP 组合在底包 `vendor/etc/init/hw/init.qcom.usb.rc` 里：纯 `mtp`/`mtp,adb` 只有 `use_ffs_mtp=1` 分支挂
`ffs.mtp`（`:1921`/`:1934`），`=0` 时只写 idVendor/idProduct（`:1910`/`:1925`）；`:197-201` 也只在 `=1`
时 `mkdir functions/ffs.mtp` + `mount functionfs mtp /dev/usb-ffs/mtp`。底包 `=1` 分支**不写 UDC**，
起 UDC 是 system 侧职责；真机日志已证明 vendor 的 mtp action 先于 system 的 mtp action 执行。

小米原包 `system/etc/init/hw/init.usb.configfs.rc` 的 `mtp`/`mtp,adb` 装配分支被 MIUI
`Charger_MIUIChargerFrame` 加了 `&& property:ro.boot.ramdump=disable`，Neo8 真机没有该属性，永不触发。

**上一版把属性置 0 并把门改成 `=0` 已被真机否证**：门确实生效，init 执行到 `write UDC`，但内核报

```
E : Config b/1 of g1 needs at least one function.
E udc a600000.dwc3: failed to start g1: -22
```

原因是 HyperOS 分支体内挂的是 kernel `mtp.gs0`，而本机 `vendor_dlkm/lib/modules` 里 `usb_f_*` 只有
`ccid/cdev/gsi/qdss`，**没有 `usb_f_mtp.ko`**（小米 17U 原包同样只有这四个），`mtp.gs0` 实例挂不上；
底包 `=0` 分支又不挂任何 function，于是 config 为空。

现行 gate 方案维持底包原值 `1`：底包挂 `ffs.mtp → b.1/f1`，system 分支负责 `write configuration` +
`write UDC`。分支体内的 `symlink mtp.gs0` **保持不动**：它在必失败，但 init 不因单条命令失败中断后续
`write UDC`，只留日志噪声，属对原厂文件的最小侵入。`ramdump=enable` 的小米工程分支（含 mass_storage
暴露 ramdump 分区，即救砖通路）保持原样，不会与本分支并存触发——这也是不能沿用覆盖模式的原因：
拿一加 15 那份 rc 覆盖会丢掉这些 MIUI 分支。

## 行为与幂等（gate 模式）

1. `ensure_prop` 写 `vendor.usb.use_ffs_mtp=${FIX_MTP_FFS_VALUE}` 并回读校验；`vendor/build.prop`
   缺失时 `warn_print` 只跳过属性子步骤，不提前退出（否则属性已正确的工作树会漏掉第二步）。
2. 单次 awk **整行等值**匹配改写两条装配门（不正则、不模糊）。每个目标分支接受两条待改旧门：
   原厂 `property:ro.boot.ramdump=disable` 与属性为反值时的 `property:vendor.usb.use_ffs_mtp=<反值>`
   （上一版补丁形态），所以原厂 / 上一版 / 已是目标三种起始形态都收敛到同一结果。
3. 写回前校验“目标行已全部存在、旧门行已全部消失”，再经 `replace_file_if_different` 原子替换并保留
   目标模式。目标 rc 不存在时 `warn` 并只跳过该子步骤；符号链接、非普通文件、或某条分支既非目标形态
   也找不到任何旧门（HyperOS 版本变化）时**失败**，不静默放行。

属性已正确时只 `SKIP` 属性子步骤；两步都已应用时输出 `SKIP`，重复执行得到相同结果。

## 执行

```bash
bash port_main.sh common/fix_mtp
```

## 验证边界

- 已定部分：`replace` 模式对一加 15/Ace 6/Ace 6T 有效且真机可用；Neo8 的 `=0` 失败链路由真机
  `-22` 日志 + 两侧 rc 取证 + `vendor_dlkm` 模块清单确定；gate 模式的三种起始形态与幂等已在临时工程实测。
- **gate 模式（Neo8）仍未真机验证**：`ffs.mtp` 挂上后能否被 PC 枚举、能否读写文件尚未确认。
  FunctionFS 需要用户态 open 端点——已确认 HyperOS 原包 `system/lib64/libandroid_servers.so` 内含
  `/dev/usb-ffs/mtp/ep0` 字符串（framework 侧就是消费者），数据面存在；但 `/dev/usb-ffs/mtp/ep0`
  在 `plat_file_contexts`/`vendor_file_contexts` 里都**没有 label 条目**，打开时可能被 SELinux 拒绝
  （这类 denial 常被 `dontaudit` 吞掉）。
- 真机核对清单：选“传输文件”后 PC 能枚举并读写；`getprop vendor.usb.use_ffs_mtp` 与入口提供的
  `FIX_MTP_FFS_VALUE` 一致；`ls -l /config/usb_gadget/g1/configs/b.1/f1` 指向 `functions/ffs.mtp`
  （不是 `mtp.gs0`）；`ls -Z /dev/usb-ffs/mtp/` 看端点存在与其 label；`logcat` 里不应再出现
  `Config b/1 of g1 needs at least one function` 与 `failed to start g1: -22`，`symlink .../mtp.gs0`
  的单条失败属预期噪声。若已枚举但不能读写，优先查 FFS 端点的 SELinux label 与 `sys.usb.ffs.ready`，
  不要改厂商组合分支，也不要回退成只翻属性。
