# fix_xiaoai_dsp_wakeup

修复 HyperOS 移植后小爱同学 DSP 唤醒不可用的问题。

## 原理

小爱语音唤醒链路依赖三方配合：

1. `VoiceTrigger`（原包 `product`，自带 FlexKws L2 与语音印资产）。
2. 高通 DSP 声学模型：原包 `mi_odm/etc/` 下的
   `XiaoAiTongXueMi.udm`（官方唤醒词 L1）与 `UserDefinedMi.udm`（自定义唤醒词）。
   移植后 `odm` 使用底包工作树，缺少这些文件，VoiceTrigger 无法加载 DSP 模型。
3. 底包 PAL 配置 `odm/etc/resourcemanager.xml` 的
   `concurrent_capture`：底包默认 `false`，DSP 唤醒会话与普通录音并发时
   VoiceTrigger 反复重启并可能拖垮音频 HAL。
4. `ro.vendor.audio.soundtrigger.*` / `ro.vendor.audio.voiceassist.*`
   声学属性（wakeupword、permian、sva 版本等）只在原包 odm 存在。

本模块完成：

- 迁移 `mi_odm/etc/*.udm|*.uim` 声学模型到 `odm/etc/`，并补齐 odm
  contexts（`vendor_configs_file`）与 fsconfig（`0 0 0644`）。
- 把原包 odm 声学属性合并进底包 `odm/etc/build.prop`。
- 将底包 PAL `concurrent_capture` 改为 `true`（可在参数中关闭）。
- 可选预装 LSPosed 识别修复 hook `local.mio.xiaoairecognitionhook` 到
  `system_ext/app/`，并写入其运行时阈值属性 `persist.sys.xiaoai.*`。

## hook 的定位（默认关闭）

对一加 Ace 6T 原包（SM8845）VoiceTrigger 的静态反编译结论：

- 官方唤醒词模型由 app 原生直读 `/odm/etc/XiaoAiTongXueMi.udm`，
  自定义词读 `/odm/etc/UserDefinedMi(V3).udm`，无 hook 必要。
- hook 的模型注入逻辑以 SM8750 的 `/odm/etc/XiaoAiTongXue.uim` 为目标，
  在 `.udm` 一代（SM8845/SM8850）上会替换掉正确的模型数据，
  **默认关闭，SM8845/SM8850 组合不应开启**。
- DSP/启动去重、FlexKws 错误自动重初始化、启动桥（含
  `startForegroundService` 拉起小爱）原包均已内建且更完整；hook 主要
  价值是 SM8750 移植机上的置信度/LAB/窗口调优与看门狗，这些值在
  SM8845 原包为硬编码（置信度 0x45、L2 窗口 3s、wake lock 800ms），
  无属性或资源通道，只有改 APK 才能调整——需真机验证确认确有必要
  再评估。

机型代际与模型形态：

| 机型 | SoC | 原包声学模型 | hook |
| --- | --- | --- | --- |
| 一加 13、Ace 6 | SM8750 | `.uim`（PDK） | 同代，可在验证后 `recognition_hook=true` |
| Ace 6T | SM8845 | `XiaoAiTongXueMi.udm` 等原生 odm 直读 | 不应开启 |
| 一加 15 | SM8850 | 以其原包实际内容为准（模块自动适配） | 不应开启 |

## 来源与目标分区

- 来源：`mi_odm`（原包 odm：声学模型与声学属性）。
- 目标：`odm`（模型、属性、PAL 配置）、`system_ext`（hook APK 与 metadata）。

## 参数

机型组合入口可通过 `XIAOAI_WAKEUP_PROPERTIES_FILE` 提供可选 `.props`：

| 键 | 取值 | 说明 |
| --- | --- | --- |
| `pal_concurrent_capture` | `true`/`false` | 是否把底包 PAL `concurrent_capture` 改为 `true`，默认 `true` |
| `recognition_hook` | `true`/`false` | 是否预装 LSPosed 识别修复 hook，默认 `false`（`.udm` 一代不需要且不应开启） |
| `persist.sys.xiaoai.*` | 数值 | 覆盖 hook 阈值默认值 |
| `ro.vendor.audio.soundtrigger.*` | 数值 | 覆盖从原包迁移的声学属性 |

## 验证边界

- 模型迁移与属性对齐来自原包数据，属于确定性迁移。
- `concurrent_capture=true` 与 hook 阈值在 OnePlus 13 (SM8750) 移植上
  实测调优；Ace 6（SM8750）、Ace 6T（SM8845）、一加 15（SM8850）
  尚未真机验证，唤醒行为与并发录音稳定性需刷机后确认。
- 静态分析（Ace 6T 原包 VoiceTrigger 反编译）表明 SM8845 唤醒链路的关键
  前提在系统层：odm 模型文件、`sva-7.0`/`support_record_type` 与底包
  DSP 实际麦克风路数一致、`device_provisioned=1`、小爱
  （com.miui.voiceassist）已装且持 RECORD_AUDIO。真机验证失败时按
  失败环节再评估是否需要 APK 层补丁。
- 原包未提供声学模型（无 `mi_odm/etc/*.udm|*.uim` 或缺少
  `XiaoAiTongXue` 主模型）时模块整体安全跳过。
- 未迁移 `mi_odm/etc/acdbdata` 声学校准；底包保留自身校准数据，
  如真机出现 DSP 校准类错误再评估。
