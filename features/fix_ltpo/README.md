# 启用 MI SurfaceFlinger LTPO 能力

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 向 `odm/etc/build.prop` 写入 `ro.vendor.mi_sf.ltpo.support=true`。 |

## 模块说明

模块只开放 MI SurfaceFlinger 上层 LTPO 策略，不提供面板、HWC 或 DynFPS 命令序列。仅应在目标设备底层确实支持 LTPO 时启用，实际工作状态仍以运行时面板与显示栈为准。

目标属性文件不存在时只警告并跳过。

## 执行

```bash
bash port_main.sh features/fix_ltpo
```
