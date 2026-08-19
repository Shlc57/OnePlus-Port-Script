# 修复 MTP USB 配置

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system` | 替换 `system/system/etc/init/hw/init.usb.configfs.rc`。 |

## 模块说明

模块使用目录内置的底包 `init.usb.configfs.rc` 替换原包目标，使 MTP、PTP 与 ADB 的 configfs 触发器匹配当前底包 USB 栈。MTP 内核函数路径只在 `vendor.usb.use_ffs_mtp=0` 时启用，避免与 vendor rc 的 FunctionFS MTP 路径重复挂接。

执行前会校验必要的 MTP 触发器。替换保留目标文件模式，不修改 contexts 或 fsconfig；目标 RC 不存在时只警告并跳过。更换底包时应同步更新本目录中的来源文件。

## 执行

```bash
bash port_main.sh common/fix_mtp
```
