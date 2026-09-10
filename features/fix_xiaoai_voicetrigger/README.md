# fix_xiaoai_voicetrigger

修复小爱同学的 VoiceAssist 设备准入和 VoiceTrigger DSP 唤醒链路。模块默认关闭，
只有组合入口显式设置 `XIAOAI_VOICETRIGGER_PATCH=true` 才会执行；开关只接受
`true`/`false`。启用时还必须通过 `XIAOAI_VOICEASSIST_DEVICE_CODE` 提供安全的
Android device token。

## 精确根因

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

## 两个 APK 子步骤

### VoiceAssistAndroidT.apk 设备准入

目标为 `product/priv-app/VoiceAssistAndroidT/VoiceAssistAndroidT.apk`，只替换
`assets/voiceassist.ai.voice.trigger.config` ZIP 条目，不修改任何 DEX。

补丁使用 Python `json` 标准库解析配置，验证根节点、`cloudControl` 数组和每个设备
条目，拒绝非法格式、重复设备和同名冲突。目标设备不存在时追加
`{"device": <code>, "os": 9}`；完全一致时安全跳过。序列化格式固定，保留原有根结构、
字段和既有数组顺序。

### VoiceTrigger.apk 唤醒链路

目标为 `product/app/VoiceTrigger/VoiceTrigger.apk`。对 SM8845 原包的静态反编译
确认以下行为硬编码在 app 内，无属性或资源通道：

| 位置 | 修改 |
| --- | --- |
| `wakeup/r.smali` `c()` | DSP L1 置信度 `0x45`（69）改为 `0x23`（35） |
| `wakeup/r.smali` `e()` | 注入 20 字节 LAB 前视缓冲；history 2500ms / preroll 1000ms，可由 `persist.sys.xiaoai.lab_*_ms` 覆盖 |
| `wakeup/s.smali` `e(w)` | XATX/UDK 命令下放行声纹门，保留关键词门 |
| `v0/h.smali` `k()` | DSP 回调 wake lock 从 800ms 延长到 7000ms |

新增注入类 `com/miui/voicetrigger/wakeup/PortWakeupHooks` 仅构造 LAB，失败路径
使用默认值。补丁逐方法核对指令结构；版本形态不符时拒绝盲目修改。

## 事务、缺失与元数据

两个 APK 分别使用 `tools/apk_patcher.sh` 的独立事务会话，具有补丁快照、失败回滚、
目标条目登记、非目标条目内容校验、`zipalign -P 16` 和原子替换。VoiceAssist 事务只
允许目标资产变化；VoiceTrigger 事务只允许目标 DEX 变化。

任一 APK 缺失时按“替换既有文件”规则警告并只跳过对应子步骤，另一个子步骤继续。
目标是符号链接、不是普通文件、ZIP 条目重复、目标条目数量异常、JSON 格式非法、
设备条目重复或目标设备内容冲突时失败。两个目标都只修改 product 分区中的既有文件
内容，不改路径、所有者或权限，无需新增 contexts/fsconfig。

## 签名风险

事务会把原 APK Signing Block 字节原样回插，但资产或 DEX 字节变化都会使其中覆盖
APK 内容的 v2/v3 摘要存在失效风险。Signing Block 字节保留不代表内容签名有效，
也不能证明无需重新签名。若需要重签名，还必须评估平台授权、共享 UID 和签名级权限
影响。

## 验证边界

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
