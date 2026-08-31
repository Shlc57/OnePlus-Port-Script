# 机型化 ColorOS displayconfig 接入

按机型 Profile 分发的共享模块，把底包 ColorOS 显示取材接入移植后的
`product`/`vendor` 双路径。所有 Profile 共享同一套主流程，机型差异全部来自
`profiles/<机型>/`（`profile.props` + `config/display_rro_files.tsv` +
`config/fusionlight_files.tsv`）。

## 目的与行为

- 先将底包取材分区 `my_product/vendor/etc` 覆盖合并到最终 `vendor/etc`，再以
  `vendor/etc/displayconfig` 为基础完整同步到 `product/etc/displayconfig`，并为
  `PORT_TARGET_DISPLAY_ID` 补齐物理 Display ID 别名。`my_product` 不会作为最终
  运行时分区保留。
- 删除原包 `product/etc/displayconfig` 中旧的 Xiaomi 配置再复制底包 vendor 目录，
  避免两套 DisplayDeviceConfig 同时被扫描。
- 用 Profile 指定的 `my_product/vendor/etc` 面板表（OP15 为 P_3，Ace 6/6T 为 P_7）
  和 expressiveness lux 表生成包含完整物理亮度表、`autoBrightness` lux map 与 HBM
  门限的 DisplayDeviceConfig，写入最终 `vendor`/`product`。
- 生成时按 Profile 执行可选的暗端锚点重映射（profile.props 的 `dark_anchor_value`，
  传入生成器 `--min-visible-value`；未设置的 Profile 传 `--no-dark-anchor` 保留
  上游曲线）：ColorOS 面板表的暗端 nit 标定与真实面板节点不符（Ace 6T 实测
  level 2/3 节点不可见，而 HyperOS nit 模型在 0 lux 请求 2 nit，会驱动到全黑
  节点），重映射把首个可见 nit 点抬到锚点背光值（0.0055，节点约 22），暗端
  过渡区间（至 1.5 倍首个可见 nit）线性承接，其余区间原样保留。锚点值来自
  Ace 6T 真机可见性阶梯实测（节点 3 不可见、节点 9 勉强可见、节点 20 可见）；
  Ace 6 跟随 Ace 6T（同款 P_7 表），OnePlus 15 不启用、跟随上游。面板表首个
  可见点或暗端过渡段本身不比锚点更细时自动跳过并打印 `DARK_ANCHOR_SKIPPED=...`
  原因（此时 2 nit 请求已落在可见节点）。
- 按 Profile manifest 迁移 `my_product/etc/fusionlight_profile` 到最终
  `system_ext/etc/fusionlight_profile`，并把 `my_product/overlay` 的 display RRO
  原名迁到最终 `product/overlay`（OP15 为 android+oplus 两份 24831，Ace 6T 仅
  android 24851）。
- `disable_high_pwm_rgb=1` 的 Profile（Ace 6/6T）会注释底包 odm 的
  `ro.vendor.oplus.sensor.high_pwm_rgb`；目标缺失或已禁用时仅警告跳过。
- 底包 Dolby visual/decoder 配置、qti-testscripts 禁用、CWB 原生链保留、SELinux
  bundle 登记等流程与机型无关，对所有 Profile 一致。

模块不复制其他机型的面板、QDCM、Demura 或 `hals.conf`；底包 vendor/odm 的显示
库与传感器注册关系保持原样。

## 机型 Profile

| Profile | 识别值 | 面板表 | RRO / FusionLight | high_pwm_rgb |
| --- | --- | --- | --- | --- |
| `oneplus15` | 入口显式指定 | `display_brightness_config_P_3.xml` | 24831 android+oplus；Main_1_A、Main_2_A | 保留 |
| `ace6t` | 入口显式指定；兜底 Target `canoe`、市场名 `OnePlus Ace 6T`（真机实测底包代号 `nezha`） | `display_brightness_config_P_7.xml` | 24851 android；Main_2_3（取自实包） | 禁用 |
| `ace6` | Target `sun`、市场名 `OnePlus Ace 6`（代号待实测） | `display_brightness_config_P_7.xml` | 暂按 ace6t 模板，待实机 `my_product` 核实 | 禁用 |

Profile 识别顺序：显式 `COLOROS_DISPLAY_PROFILE` 优先；否则按底包设备代号、市场名
或显示 Target 自动匹配；无法匹配时报错并列出可用 Profile。

## 执行

```bash
PORT_TARGET_DISPLAY_ID=4630946903293830803 \
  bash port_main.sh common/coloros_display
# 或显式指定机型
COLOROS_DISPLAY_PROFILE=ace6t PORT_TARGET_DISPLAY_ID=4630946700822127507 \
  bash port_main.sh common/coloros_display
```

模块要求 `my_product` 已解包且当前配置目录含其 contexts/fsconfig；`vendor`、
`product`、`system_ext` 分区必须存在。Ace 6/6T 自动亮度此前依赖的
`MiuiFrameworkResOverlay.apk` 曲线 Overlay 由 [`common/fix_boot_brightness`](../fix_boot_brightness/README.md)
按 Profile 移除，环境光曲线改由本模块生成的 `autoBrightness` 配置承担；该切换在
真实设备上的亮度跟随表现仍需刷机验证。
