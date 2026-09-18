# features/fix_xiaoai_wakeup

HyperOS 小爱同学唤醒修复（由 `fix_xiaoai_dsp_wakeup` 与 `fix_xiaoai_voicetrigger`
于 2026-09-16 合并而成，执行顺序与合并前一致：odm/vendor 声学迁移在前，
product 分区 APK 静态补丁在后）。

- **声学迁移（原 dsp_wakeup）**：迁移原包 Qualcomm 声学唤醒模型到底包 odm，
  对齐声学属性与 PAL 并发采集配置，可选预装小爱识别修复 LSPosed hook；
  原包缺声学模型时安全跳过。
- **APK 静态补丁（原 voicetrigger）**：VoiceAssistAndroidT.apk 设备准入
  （cloudControl.device 白名单）+ VoiceTrigger.apk 静态植入（DSP L1 置信度、
  LAB 前视缓冲、XATX/UDK 声纹门与回调保活，等价 LSPosed hook，无需 LSP）；
  由 `XIAOAI_VOICETRIGGER_PATCH=true` 显式启用。

环境变量：`XIAOAI_PAL_CONFIG_FILE`、`XIAOAI_WAKEUP_PROPERTIES_FILE`、
`XIAOAI_VOICETRIGGER_PATCH`、`XIAOAI_VOICEASSIST_DEVICE_CODE`。

---

## DSP 唤醒链路子步骤（历史模块名 `fix_xiaoai_dsp_wakeup`）

修复 HyperOS 移植后小爱同学 DSP 唤醒不可用的问题。

### 原理

小爱语音唤醒链路依赖三方配合：

1. `VoiceTrigger`（原包 `product`，自带 FlexKws L2 与语音印资产）。
2. 高通 DSP 声学模型：原包 `mi_odm/etc/` 下的
   `XiaoAiTongXueMi.udm`（官方唤醒词 L1）与 `UserDefinedMi.udm`（自定义唤醒词）。
   移植后 `odm` 使用底包工作树，缺少这些文件，VoiceTrigger 无法加载 DSP 模型。
3. 底包 PAL 配置 `odm/etc/resourcemanager.xml` 的
   `concurrent_capture`：底包默认 `false`，DSP 唤醒会话与普通录音并发时
   VoiceTrigger 反复重启并可能拖垮音频 HAL；Ace 6T 真机另证实小爱 PAL
   缺少指定 vendor UUID 的 stream_config 及其四个 capture_profile。
4. `ro.vendor.audio.soundtrigger.*` / `ro.vendor.audio.voiceassist.*`
   声学属性（wakeupword、permian、sva 版本等）只在原包 odm 存在。

本模块完成：

- 迁移 `mi_odm/etc/*.udm|*.uim` 声学模型到 `odm/etc/`，并补齐 odm
  contexts（`vendor_configs_file`）与 fsconfig（`0 0 0644`）。
- Ace 6T 从 `mi_vendor/etc/acdbdata/alor_mtp_wcd9378/` 精确补齐
  `MTP_alor_wcd9378_acdb_cal.acdb` 与 `MTP_alor_wcd9378_workspaceFileXml.qwsp` 到
  `vendor/etc/acdbdata/alor_mtp_wcd9378/`，同步迁移对应 contexts/fsconfig；不整体复制音频目录。
- 把原包 odm 声学属性写入最终 `odm/etc/build.prop`、`vendor/build.prop`、
  ODM import 目标（配置 `odm.prjname` 时）及 `odm/etc/init/xiaoai_wakeup_props.rc`。
  七个目标属性在 `vendor_property_contexts` 与 `precompiled_property_contexts` 中
  精确标记为底包原生 `vendor_audio_prop`，并恢复 `platform_app` 对该标签的只读权限。
- 将底包 PAL `concurrent_capture` 改为 `true`（可在参数中关闭）。
- Ace 6T 由 `XIAOAI_PAL_CONFIG_FILE` 传入 `mi_odm/etc/audio/sku_canoe/resourcemanager_canoe_mtp.xml`，仅提取 vendor UUID
  `61696d69-30f2-11e6-b0ac-40a8f03d3f1e` 的唯一 `stream_config` 及其四个缺失 profile，合并到
  `odm/etc/resourcemanager.xml`；不迁移整份 XML 或 PAL 二进制/音频配置。
- 可选预装 LSPosed 识别修复 hook `local.mio.xiaoairecognitionhook` 到
  `system_ext/app/`，并写入其运行时阈值属性 `persist.sys.xiaoai.*`。

### hook 的定位（默认关闭）

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

### 来源与目标分区

- 来源：`mi_odm`（原包 odm：声学模型与声学属性）；Ace 6T ACDB 来源为
  `mi_vendor/etc/acdbdata/alor_mtp_wcd9378/`，并要求来源 `mi_vendor` metadata
  含两个文件的目录与文件条目。
- 目标：`odm`（模型、属性载体、PAL 配置与 metadata）、`vendor`（属性载体及 Ace 6T
  两个 alor ACDB 文件与 metadata）、`system_ext`（仅在启用 hook 时写入 APK 与 metadata）。
- `mi_vendor` 仅作为 ACDB 来源，不作为最终目标分区；ACDB 仅按清单精确迁移，目标文件
  已存在且内容相同则幂等跳过，内容不同则失败。SELinux bundle 只写最终
  `vendor_property_contexts` 与 `precompiled_property_contexts`，并清理可选
  `odm_property_contexts` 中七个目标键遗留的 `vendor_default_prop exact` 条目。

### 参数

机型组合入口可通过 `XIAOAI_WAKEUP_PROPERTIES_FILE` 提供可选 `.props`：

| 键 | 取值 | 说明 |
| --- | --- | --- |
| `pal_concurrent_capture` | `true`/`false` | 是否把底包 PAL `concurrent_capture` 改为 `true`，共享模块默认 `false`；需要测试的组合入口显式开启 |
| `XIAOAI_PAL_CONFIG_FILE` | project_dir 相对路径 | 可选 PAL 来源 XML；缺失时仅跳过 UUID/profile 子步骤，Ace 6T 由入口传入实测 `mi_odm/etc/audio/sku_canoe/resourcemanager_canoe_mtp.xml` |
| `recognition_hook` | `true`/`false` | 是否预装 LSPosed 识别修复 hook，默认 `false`（`.udm` 一代不需要且不应开启） |
| `persist.sys.xiaoai.*` | 数值 | 覆盖 hook 阈值默认值 |
| 七个 bundle 目标 `ro.vendor.audio.soundtrigger.*` / `ro.vendor.audio.voiceassist.support_record_type` 键 | 属性值 | 覆盖从原包迁移的声学属性；不接受目标集合外的音频属性 |

### 验证边界

- 模型迁移与属性对齐来自原包数据，属于确定性迁移。
- `concurrent_capture=true` 与 hook 阈值在 OnePlus 13 (SM8750) 移植上
  实测调优；Ace 6（SM8750）、Ace 6T（SM8845）、一加 15（SM8850）
  尚未真机验证，唤醒行为与并发录音稳定性需刷机后确认。
- **odm/etc/build.prop 属性位置**：底包该文件头部是 Oplus 私有
  `import` 链（`/odm/etc/${ro.boot.prjname}/...`，目标文件在移植镜像
  中不存在）。真机实测 Ace 6T：HyperOS init 解析 import 之后紧跟的
  属性段会被跳过（约第 19 行起恢复）。本模块因此把声学属性**追加到
  odm/etc/build.prop 末尾**（追加区标记下）并**兜底合并一份到
  vendor/build.prop**（init 属性先到先得，两处取值一致无冲突）。
  其他模块经 `merge_prop_file` 写入 odm build.prop 头部的属性同样
  受此问题影响（如 `ro.vendor.touchfeature.type`、`ro.vendor.nfc.*`），
  需各自模块按同样方式处理。
- **七属性已在 root 真机确认存在**：普通 shell 读取为空反映读取侧权限限制，
  不是属性注入失败。`VoiceTrigger` 与 `VoiceAssistAndroidT` 真机进程均运行在
  `platform_app_36`，两个 APK 都会直接读取这些
  `ro.vendor.audio.soundtrigger.*` / `ro.vendor.audio.voiceassist.*` 属性。
  本模块的最小 SELinux bundle 保持属性标签为底包原生 `vendor_audio_prop`，
  只恢复 `platform_app_${API_VERSION}` 的 `read/getattr/map/open` 权限；底包
  `vendor_init` 原有 set 权限不变。该结论确认属性存在与读取契约，DSP 唤醒
  整体行为仍需刷入最终策略后验证。
- Ace 6T 真机日志链为 `Input vendor uuid : 61696d69-30f2-11e6-b0ac-40a8f03d3f1e`、
  `Failed to get sound model platform info`、`PAL -22`、`SoundTrigger INTERNAL_ERROR`，随后音频 HAL
  持续重启。此次最小修复只补齐来源 XML 中该 UUID 的唯一 stream_config 与四个 capture_profile；
  不迁移整个 XML、PAL 库、`usecaseKvManager` 或 `audio_module_config`，刷机后仍需复核 HAL 稳定性。
- 静态分析（Ace 6T 原包 VoiceTrigger 反编译）表明 SM8845 唤醒链路的关键
  前提在系统层：odm 模型文件、`sva-7.0`/`support_record_type` 与底包
  DSP 实际麦克风路数一致、`device_provisioned=1`、小爱
  （com.miui.voiceassist）已装且持 RECORD_AUDIO。真机验证失败时按
  失败环节再评估是否需要 APK 层补丁。
- 原包未提供声学模型（无 `mi_odm/etc/*.udm|*.uim` 或缺少
  `XiaoAiTongXue` 主模型）时模块整体安全跳过。
- 未迁移 `mi_odm/etc/acdbdata` 声学校准；底包保留自身校准数据，
  如真机出现 DSP 校准类错误再评估。

---

## VoiceAssist / VoiceTrigger 准入修补子步骤（历史模块名 `fix_xiaoai_voicetrigger`）

修复小爱同学的 VoiceAssist 设备准入和 VoiceTrigger DSP 唤醒链路。模块默认关闭，
只有组合入口显式设置 `XIAOAI_VOICETRIGGER_PATCH=true` 才会执行；开关只接受
`true`/`false`。启用时还必须通过 `XIAOAI_VOICEASSIST_DEVICE_CODE` 提供安全的
Android device token。

### 精确根因

Ace 6T 运行日志为 `device support:false, voice trigger:true`。静态检查
`product/priv-app/VoiceAssistAndroidT/VoiceAssistAndroidT.apk` 已确认：
`assets/voiceassist.ai.voice.trigger.config` 的 `cloudControl.device` 会与
`Build.DEVICE` 精确比较，原配置不含 Ace 6T 的 `nezha`，因此 VoiceTrigger 能力已开启
但 VoiceAssist 仍拒绝该设备。

Ace 6T 组合入口明确设置：

```bash
XIAOAI_VOICETRIGGER_PATCH=true
XIAOAI_VOICEASSIST_DEVICE_CODE=nezha
```

其他机型入口不启用本模块，也不从原包或运行中属性推断目标设备代码。

### 两个 APK 子步骤

#### VoiceAssistAndroidT.apk 设备准入

目标为 `product/priv-app/VoiceAssistAndroidT/VoiceAssistAndroidT.apk`，只替换
`assets/voiceassist.ai.voice.trigger.config` ZIP 条目，不修改任何 DEX。

补丁使用 Python `json` 标准库解析配置，验证根节点、`cloudControl` 数组和每个设备
条目，拒绝非法格式、重复设备和同名冲突。目标设备不存在时追加
`{"device": <code>, "os": 9}`；完全一致时安全跳过。序列化格式固定，保留原有根结构、
字段和既有数组顺序。

#### VoiceTrigger.apk 唤醒链路

目标为 `product/app/VoiceTrigger/VoiceTrigger.apk`。对 SM8845 原包的静态反编译
确认以下行为硬编码在 app 内，无属性或资源通道：

| 位置 | 修改 |
| --- | --- |
| `wakeup/r.smali` `c()` | DSP L1 置信度 `0x45`（69）改为 `0x23`（35） |
| `wakeup/r.smali` `e()` | 注入 20 字节 LAB 前视缓冲；history 2500ms / preroll 1000ms，可由 `persist.sys.xiaoai.lab_*_ms` 覆盖 |
| `wakeup/s.smali` `e(w)` | XATX/UDK 命令下放行声纹门，保留关键词门 |
| `v0/h.smali` `k()` | DSP 回调 wake lock 从 800ms 延长到 7000ms | 原位常量寄存器可能随 ROM 版本漂移（SM8845/SM8850 使用不同寄存器），补丁已适配寄存器无关检测与替换 |

新增注入类 `com/miui/voicetrigger/wakeup/PortWakeupHooks` 仅构造 LAB，失败路径
使用默认值。补丁逐方法核对指令结构；版本形态不符时拒绝盲目修改。

### 事务、缺失与元数据

两个 APK 分别使用 `tools/apk_patcher.sh` 的独立事务会话，具有补丁快照、失败回滚、
目标条目登记、非目标条目内容校验、`zipalign -P 16` 和原子替换。VoiceAssist 事务只
允许目标资产变化；VoiceTrigger 事务只允许目标 DEX 变化。

任一 APK 缺失时按“替换既有文件”规则警告并只跳过对应子步骤，另一个子步骤继续。
目标是符号链接、不是普通文件、ZIP 条目重复、目标条目数量异常、JSON 格式非法、
设备条目重复或目标设备内容冲突时失败。两个目标都只修改 product 分区中的既有文件
内容，不改路径、所有者或权限，无需新增 contexts/fsconfig。

### 签名风险

事务会把原 APK Signing Block 字节原样回插，但资产或 DEX 字节变化都会使其中覆盖
APK 内容的 v2/v3 摘要存在失效风险。Signing Block 字节保留不代表内容签名有效，
也不能证明无需重新签名。若需要重签名，还必须评估平台授权、共享 UID 和签名级权限
影响。

### 验证边界

- VoiceAssist 可在真实 Ace 6T 原包 APK 的临时副本上静态验证：目标设备只添加一次、
  重复执行幂等、非目标 ZIP 条目内容不变且 `unzip -t` 通过。
- VoiceTrigger 可通过反编译结果、四项方法修改、重复执行和 ZIP 完整性做静态验证。
- 当前结论仅覆盖已分析的 SM8845 原包，只有 Ace 6T 组合入口显式启用。
- 尚未完成刷机后真机闭环。仍需在 Ace 6T 验证日志不再出现
  `device support:false, voice trigger:true`，并确认两个 APK 通过平台校验正常加载，
  以及亮屏/熄屏唤醒、连续触发和录音并发稳定性。静态回编译、`unzip -t` 与 Signing
  Block 字节保留不能替代这些真机证据。

VoiceTrigger DEX 修补属于最小侵入原则的例外：其阈值、LAB、声纹门和回调保活没有
系统层配置通道。VoiceAssist 准入则仅修改其配置资产，不扩大到 DEX。
