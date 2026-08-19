# 禁用不兼容的 Xiaomi Vulkan pipeline cache

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product` | 注释 `product/etc/build.prop` 中的 `persist.sys.enhance_vkpipelinecache.enable`。 |

## 模块说明

该特性在 Xiaomi 8 Elite 等原包中可能使不兼容的目标 GPU 或驱动卡在首屏。模块只注释已存在的属性，不会新增属性或禁用 Vulkan 本身。

仅应在目标 GPU/驱动已确认无法兼容该 pipeline cache 特性时启用。属性不存在时只警告并跳过，已注释时安全跳过。

## 执行

```bash
bash port_main.sh features/disable_mi_vulkan
```
