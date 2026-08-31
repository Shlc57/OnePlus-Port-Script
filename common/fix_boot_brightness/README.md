# 机型启动默认亮度 Overlay

按机型 Profile 分发的共享模块。每个 Profile 只做两件事：

1. 安装仅覆盖 `config_screenBrightnessSettingDefaultFloat` 的启动亮度 Overlay
   （`profiles/<机型>/prebuilt/`，SHA-256 校验）并同步 product contexts/fsconfig；
2. 按 Profile 声明移除旧自动亮度曲线 Overlay `MiuiFrameworkResOverlay.apk`。

自动亮度曲线不再由本模块处理：所有机型 Profile 都声明移除小米曲线 Overlay，
环境光曲线与物理亮度边界改由 [`common/coloros_display`](../coloros_display/README.md)
按底包 `my_product` 官方表生成原生 `autoBrightness` 配置。

## 机型 Profile

| Profile | 识别值 | 启动 Overlay |
| --- | --- | --- |
| `oneplus15` | 入口显式指定 | `OnePlus15BootBrightnessOverlay.apk`（0.390222547） |
| `ace6` | Target `sun`、市场名 `OnePlus Ace 6`（设备代号待实测） | `Ace6BootBrightnessOverlay.apk`（0.394047439） |
| `ace6t` | 代号 `nezha`、Target `canoe`、市场名 `OnePlus Ace 6T` | `Ace6TBootBrightnessOverlay.apk`（0.394047439） |

Profile 识别顺序：显式 `BOOT_BRIGHTNESS_PROFILE` 优先；否则按底包设备代号、市场名
或显示 Target 自动匹配 `profiles/*/profile.props`；无法匹配时报错并列出可用 Profile。
每个 Profile 目录包含 `profile.props`、`prebuilt/` 启动 Overlay 与校验文件、
`boot_brightness_overlay/` 生成源（配合 `gen_boot_overlay.py` 在默认亮度变化时重新生成）。

## 执行

```bash
bash port_main.sh common/fix_boot_brightness
# 或显式指定机型
BOOT_BRIGHTNESS_PROFILE=ace6t bash port_main.sh common/fix_boot_brightness
```
