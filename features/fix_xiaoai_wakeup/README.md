# features/fix_xiaoai_wakeup

HyperOS 小爱同学唤醒修复（由 `fix_xiaoai_dsp_wakeup` 与 `fix_xiaoai_voicetrigger`
于 2026-09-16 合并而成，执行顺序与合并前一致：odm/vendor 声学迁移在前，
product 分区 APK 静态补丁在后）。

- **声学迁移（原 dsp_wakeup）**：迁移原包 Qualcomm 声学唤醒模型到底包 odm，
  对齐声学属性与 PAL 并发采集配置（自 2026-09-29 起不再合并非 RAW PAL 片段与
  改指 usecaseKv 图键，原因见下文《已移除的历史能力》）。
- **APK 静态补丁（原 voicetrigger）**：VoiceAssistAndroidT.apk 设备准入
  （cloudControl.device 白名单）+ VoiceTrigger.apk 静态植入（给小米互联绑定的
  失败加 `SecurityException` 兜底，属已真机确认必需项），
  由 `XIAOAI_VOICETRIGGER_PATCH=true` 显式启用。
- **CPU FlexKws 前端**：把"小爱同学"免手唤醒从 ADSP 热唤醒改到原包 VoiceTrigger.apk
  自带的 CPU 唤醒栈（`AudioRecord` + `libflexkws` + `xatx` 模型 + 声纹判定），由机型参数
  `xiaoai_cpu_kws=true` 显式启用。见下方《CPU FlexKws 前端子步骤》。

环境变量：`XIAOAI_WAKEUP_PROPERTIES_FILE`、
`XIAOAI_VOICETRIGGER_PATCH`、`XIAOAI_VOICEASSIST_DEVICE_CODE`、`XIAOAI_CPU_KWS`、
`XIAOAI_CPU_KWS_HOLD_MS`、`XIAOAI_CPU_KWS_GAP_MS`、`XIAOAI_CPU_KWS_WINDOW_SEC`（后三个
由机型 `.props` 的节奏键注入，`apply.sh` 校验后透传给 `patch_voicetrigger.sh`）。

**产物哨兵（仅 `xiaoai_cpu_kws=true` 时生效）**：`patch_voicetrigger.sh` 返回后，`apply.sh` 会读回
`product/app/VoiceTrigger/VoiceTrigger.apk` 里全部 `classes*.dex`，确认存在 `PortCpuKws`，否则硬失败。
立论是 2026-09-30 Neo8 真机回传：`/odm/etc/init/xiaoai_wakeup_props.rc` 与唤醒模型都在位，但四个 dex 的
`PortCpuKws` 计数全为 0，VT 因此仍跑 ADSP 热唤醒并每 5 秒把 audio HAL 打死。ADSP 路线的机型（一加 15 /
Ace 6）不走这个分支，行为不变；读不到 dex（无 python3 或包内无 classes*.dex）也按失败处理，不静默跳过。

---

## ⚠️ 当前状态结论（2026-09-29，Ace 6T / SM8845 底包真机）

**小爱 CUSTOM1 唤醒在当前组合判为不可达**，端到端始终无法检出。这是经过完整真机
定位后的结论，不是未验证：

- 三段链已全部打通并刷机确认（历史结论，对应的非 RAW 片段、图键改指与插件替换已于
  同日作为过时产物移除）：`LOAD_PHRASE_MODEL("…3f1b") -> 0`、
  `ParseSoundModel status 0`、`LoadSoundModel status 0` 均正常。
- 卡在下发非持久校准：标准 CUSTOM 图 `gsl_graph_send_nonpersist_cal … failed 2` →
  `graph open for single gkv failed 2` → 外层 `Failed to create mmap buffer, status = -22`。
- 已逐个否证（均真机或离线取证，详见下文“DSU 真机”节）：`out_channels`/`low_power`
  三变体、注入的 LAB `RecognitionConfig.data`、`customva_plugin.so` 版本（底包原版与
  小米版对录入模型都 `ParseSoundModel status 0`）、SELinux（音频/ST/DSP 路径 0 条 AVC）、
  以及 **换/重制 ACDB**（底包 odm 与小米 alor MTP 两份 ACDB 的 `Stream_Config_CUSTOM` 均 46、
  CUSTOM_NS/CUSTOM_ECNS 子图名逐字相同，换库补不出新图，冷启镜像与 QACT 均无意义）。
- 试图改走 BREENO 图（`0xBC000012` + `RAW_LPI` + ch2）能让 `StartRecognition` 返回
  `status 0`、拿到 mmap buffer，但紧接 `gsl_set_custom_config failed 10` +
  `CustomVA Unsupported param id …`：小米模型的 custom config 编不进小布 custom
  module，引擎空跑、零检出。两堵墙同源：**Oplus SM8845 的 ADSP 固件里 CUSTOM VA
  匹配模块不接受小米 CUSTOM1 模型**（DSP 侧模块在 ADSP 固件，不在本移植可改的 odm/vendor/product）。

保留可用部分：声学模型与属性迁移、VoiceAssist 设备准入、`SecurityException` 互联兜底
（已真机确认修复“进程 3.5s 自杀”）、PAL `concurrent_capture`，以及新增的 CPU FlexKws 前端。
原“DEX 补丁保留三项（置信度、wake lock、互联兜底）”已收缩为**只保留互联兜底**：
前两项只存在于已废弃的 ADSP L1 路径（原因见《已移除的历史能力》）。若未来换机型/换
底包且其 ADSP 带小米配套模块，需重评整条路线。

已真机验证的边界（重要）：**小爱助手本体可用**——长按电源/助手手势能唤起小爱并正常“能听能答”
（会话走普通 AudioRecord，不依赖坏掉的 ADSP 热唤醒）；`am start -a android.intent.action.ASSIST`
能把它拉到前台。ADSP 热唤醒本身不可达。

**已落地（2026-09-29，Ace 6T DSU 真机）**：免手唤醒词改由下面的 CPU FlexKws 前端提供，
端到端可用：亮屏与**熄屏**都能喊醒、指令能识别并正常结束会话、可连续重复唤醒、
全程不再出现 `-22` 与 audioserver/HAL 受伤，误唤醒已清零。

---

## CPU FlexKws 前端子步骤（`xiaoai_cpu_kws`）

把免手唤醒词从“ADSP 热唤醒”改到“CPU 常驻检出”，不引入任何外部引擎或模型：
原包 `product/app/VoiceTrigger/VoiceTrigger.apk` 自带完整 CPU 唤醒栈，只是缺启动点。

### 原理与定位链（2026-09-29 静态反编译 + DSU 真机交叉确认）

- `wakeup/c`：`AudioRecord`（`AudioAttributes` 内部预置 `0x7cf` = `VOICE_COMMUNICATION`，
  16kHz；采样格式与通道数由 `v0/K` 从 `ro.vendor.audio.soundtrigger.support_record_type`
  推导：`-1` → `K.f()=1`、`K.u()=false` → **单声道 int16**，与资源里
  `assets/flexkws/xatx/1ch_flexkws.json5`（`channel_num:1, sample_type:int16, frame_ms:10`）
  完全对齐；读环在 `c$b` 按 320 字节分帧喂 `libflexkws`）。
- 词表：`v0/E.k(context)` 在官方词下返回 `XIAOAITONGXUE`；模型已预先拷到
  `/data/user/0/com.miui.voicetrigger/files/flexkws/V2.23_08_24/{xatx,custom}`，
  声纹不注册也能过（`wakeup/v.b()` 把声纹 init 推迟到 start）。
- 唯一缺口：`wakeup/c.K()` 只被 `wakeup/u.k()` 调用，而 `u.k()` 只被 DSP L1 命中回调
  `wakeup/F.onRecognition()` 调用——所以只需补启动点与重启环。
- 投递出口：`wakeup/s.e(result)` 仅在 KWS 与声纹**双通过**时进入；原生把 L2 bundle 交给
  小爱会让它等 `oneshot_messenger` 喂流，而喂流的总闸 `c.v()`/`H.j()` 又被多声道门 `K.w()`
  关着（单声道下永不能送），因此会永远卡在“我在听”。本模块改为在双通过分支里走原生
  唤醒入口投递（带齐 extras、**不带** `oneshot_messenger`），小爱像长按电源那样自己开麦。

### 六处 Smali 改动（均由 `cpu_kws_edits.py` 精确锚点植入）

1. `wakeup/F.o(true)`：不再调用 `r.g()`（establishSvaSession，就是产生 `-22` 打死音频的那步），
   改为登记参数并立即排队一轮 CPU 采集；`.locals` 由 4 扩到 6 以承载 `long` 参数。
2. `wakeup/F.o(false)`：清 `enabled`，已排队的重开自然失效（关闭开关就停止监听）。
3. `wakeup/F.S()`（`s.b()` onStopAudio 的唯一出口）：原本重启 ADSP 识别，改为延时后重排一轮。
4. `wakeup/H.k(passed=true)`：补打 `WakeupInfoBean.setL1WakeupTime(now)`（不经 `onRecognition` 时
   `level1.finish` 会是 0，小爱会拿到 `wakeupCostTime=Long.MAX` 的非法时序），并压一个让麦
   窗口（默认 5 秒）。
5. `wakeup/s.e(result)`：双通过分支后改投 `ACTION_VOICE_TRIGGER_START_VOICEASSIST` →
   `com.miui.voiceassist/.PermissionVoiceService`，extras 与原生一致但去掉 `oneshot_messenger`。
6. `wakeup/t.b`：CPU 检出窗口由原包 3s 改为机型参数指定的秒数（默认 6s；单声道
   32000 B/s，默认即 `0x2ee00`），监听占空比由 ~54% 提到 ~80%。

### 节奏参数（三个常量已参数化）

让麦、无检出重开间隔与检出窗口都不再写死在脚本里，由机型 `.props` 注入：

| `.props` 键 | 默认 | 落点 |
| --- | --- | --- |
| `xiaoai_cpu_kws_hold_ms` | 5000 | `wakeup/H.k()` 的 `armStored(...)` 与 `PortCpuKws.onWakeup()` 各写一份，两处永远同值 |
| `xiaoai_cpu_kws_gap_ms` | 1500 | `wakeup/F.S()` 重排下一轮采集的 `postDelayed` 延时 |
| `xiaoai_cpu_kws_window_sec` | 6 | `wakeup/t.b` 的字节数 = 秒 × 32000（单声道 int16/16kHz） |

- 取值范围：让麦 100~60000ms、间隔 0~60000ms、窗口 1~600s；越界或不是十进制整数
  一律硬失败，不会静默取默认值。
- 超过 32767 的毫秒值会自动改用 `const-wide/32` 编码（仍占同一寄存器对）。
- 重复执行幂等；把让麦/间隔改成新值可在已植入的树上原位收敛。**改窗口值例外**：
  `wakeup/t.b` 的 `<clinit>` 按条件写两次（原包另一支是 `0x184c0`），DEX 里没有标记就
  无法区分“上轮植入用的另一个窗口”与“别的写入”，因此脚本会拒绝盲目改写并提示先从
  `INPUT` 母本取回 `VoiceTrigger.apk` 重打。
- 这三个键只在 `xiaoai_cpu_kws=true` 时生效；其它路线下带节奏键只警告不失败。

另有新增资源 `config/PortCpuKws.smali`（`com.miui.voicetrigger.wakeup.PortCpuKws`）：由
`cpu_kws_edits.py` 从这份原文安装到解包目录（并写入机型让麦时长），`patch_voicetrigger.sh`
不再自己 `cp`，以免两处值走偏。该类实现 `Runnable` 的重启环，用 `v0/N.d()`（`Work-thread`
Handler）做 `removeCallbacks + postDelayed`，`deadline` 取最大值保证“短延时不会把长让麦
提前”，并在启动前用 `c.E()` 判“已在录则不叠加”；整个 `run()` 包在 `catchall` 里，失败只
记日志不影响宿主进程。

### 代价、风险与验证边界

- **为什么必须改 DEX**：本路径没有任何属性、资源或配置通道能选择“不经 L1 直接起 L2 会话”，
  而 L1 在底包 ADSP 上结构性不可达（见顶部结论）；这属于“补齐无法，只能组件修改”的例外。
  只改启动/投递/时长分支，不改任何安全判定（KWS+声纹双通过仍是必要条件）。
- **签名/完整性**：与同模块其他 DEX 项一致，只保留原 APK Signing Block 字节，未重新签名；
  预置在 `product/app` 下不走安装验签，但任何依赖 v2/v3 摘要校验的组件会认为该包已改。
- **常驻代价**：DSU 实测 `com.miui.voicetrigger` 约 12% 单核（累计 CPU 时间 / 墙钟时间）、
  RSS ~276M；熄屏 Doze 下仍能检出（已真机验证）。
- **已真机验证（Ace 6T，DSU 热替换 + 刷机后开机）**：亮屏/熄屏唤醒、指令识别与会话结束、
  连续重复唤醒、误唤醒清零、无 `-22`、audioserver/HAL 未受伤。开机持久性有仪器证据：
  刷入后 `bind` 残留 0、生效 APK md5 与仓库产物一致、VT 进程在开机后约 65 秒自启
  并持续跑 `AudioFlow: start → onEnoughData 192000`（即 6 秒窗口）循环 50 分钟以上。
- **尚未验证**：真我 Neo8（已置 `xiaoai_cpu_kws=true`，属同栈推导，需真机跑一轮确认
  误唤醒与二次唤醒节奏；节奏不合适就改上面的三个键）；一加 15 / Ace 6 为 SM8750
  （Target `sun`）平台，两个入口已按 ADSP 基线接入（声学迁移 + 互联兜底，不启用 CPU
  前端），依据是一加 13 同平台的历史实测，本仓库尚未在这两台上刷机确认。若真机拍到
  `-22` / `set_custom_config failed 10` / 零检出，就把该机型 `.props` 的
  `xiaoai_cpu_kws=true` 与 `pal_concurrent_capture=true` 打开整组切到 CPU 前端。
- **幂等与测试**：`cpu_kws_edits.py check|patch <解包目录> [--hold-ms N --gap-ms N
  --window-sec N --class-source FILE]` 逐项判定 `patched/original/stale/unknown`，锚点不是
  恰好一份就拒绝修改；行为测试 `test_cpu_kws_edits.py` 覆盖默认节奏、机型节奏落点、
  `const-wide/32` 编码、让麦/间隔改值收敛、窗口改值必须重取母本、锚点漂移拒绝与缺资源拒绝。

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
- 把原包 odm 声学属性写入最终 `odm/etc/build.prop`、`vendor/build.prop`、
  ODM import 目标（配置 `odm.prjname` 时）及 `odm/etc/init/xiaoai_wakeup_props.rc`。
  七个目标属性在 `vendor_property_contexts` 与 `precompiled_property_contexts` 中
  精确标记为底包原生 `vendor_audio_prop`，并恢复 `platform_app` 对该标签的只读权限。
- 将底包 PAL `concurrent_capture` 改为 `true`（机型参数开启；CPU 前端的常驻
  采集需要与其它 App 的录音并发）。

以下四项已从本模块移除（曾经用于推进 ADSP 路线，现在这条路线已定层为不可达，
CPU 前端也不读这些表）：非 RAW PAL 片段合并与 `capture_profile` 的 devicePP 名单校验、
`CUSTOM1 Instance=1` 图键改指标准 CUSTOM 图、小米版 `customva_plugin.so` 替换、
`r.c()` DSP L1 置信度与 `v0/h.k()` 回调保活两项 DEX 修改。理由与历史结论见下文
《已移除的历史能力》。

### 已移除的历史能力（2026-09-29）

以下九项已从本模块删除，不要再默认加回来；括号里是当时的用途与删除理由：

- **LSPosed 识别修复 hook 预装分支**（`prebuilt/XiaoAiRecognitionHook.apk` +
  `config/hook.props` + `recognition_hook` 开关 + `system_ext` 写入）。四个机型入口
  都没有启用过它（死代码）；它调优的是 SM8750/PDK 路线，而 PDK 路线已确认无 `.uim/.lat`
  载体；真机日志还拍到它在 SM8845 代包上 `hook install failed: Cannot hook abstract
  methods … wakeup.q.onRecognition`，装不上只会添噪声。SM8845/SM8850 本就不应开启。
- **小米 alor ACDB 精确迁移**（`mi_vendor/etc/acdbdata/alor_mtp_wcd9378/` 两个文件）。
  它的立论是“底包缺 CUSTOM VA 图、需要小米 ACDB 补图”，已被 2026-09-29 取证否证：
  底包 `odm/etc/acdbdata/acdb_cal.acdb` 本就有 46 张 `..._Stream_Config_CUSTOM` 图，
  而且真机加载的就是 odm 这份；`vendor/etc/acdbdata/alor_mtp_wcd9378/` 是补丁自己造的
  目录（未打补丁底包只有 `canoe_mtp`/`canoe_qrd`），放进去后没有任何消费者。
- **`udk/UdkSettingActivitySuper` 薄壳类植入**。当时推断“语音唤醒设置页必崩是因为
  Manifest 声明了该组件而 DEX 缺类”；2026-09-29 证明那是旧镜像把 SM8750（versionCode
  2026020321）代 VoiceTrigger 混进 `/product` 造成的，干净原包（2036082721）不声明该
  组件且页面正常。注：上一次打包产物里已植入该类，对当前组合惰性无害（PMS 不认识它），
  重新解包 `product` 后即消失。
- **`wakeup/s.smali` `e(w)` 的 XATX/UDK 声纹门放行**。用户真实录入后
  `files/voiceprint_model/xatx.udm` 存在，该门本可自然通过；放行属于放宽安全边界，
  GKV 打通后保留它只会混淆后续失败归因。
- **LAB 前视缓冲注入**（`r.e()` 的 20 字节 `RecognitionConfig.data`、辅类
  `config/PortWakeupHooks.smali` 与 `persist.sys.xiaoai.lab_history_ms`/`lab_preroll_ms` 两个
  阈值）。2026-09-29 刷机对比已证实它与唯一阻塞 `mmap -22` 无关（卸除后
  `gsl_graph_send_nonpersist_cal … failed 2` 逐字重现），而小米原生在该参数上就是传 `null`；
  保留一项无已证实效果、却改变二进制行为的 DEX 改动不符合最小侵入原则。
- **非 RAW PAL 片段合并与 devicePP 名单校验**（`config/xiaoai_pal_config.xml` +
  `xiaoai_pal_config.py` + 其测试）。它们只服务 ADSP 的 `CUSTOM_VOICE_UI` usecase；
  而 2026-09-29 已定层：即使图键、devicePP、UUID 全部自洽，底包 ADSP 仍不吃小米
  CUSTOM1 模型（`-22` 与 `set_custom_config failed 10` 两堵墙）。CPU 前端走普通
  `VOICE_COMMUNICATION` 输入，不查这张表，因此整组无消费者。
- **`CUSTOM1 Instance=1` 图键改指**（`xiaoai_usecase_kv.py` + 其测试 + 它在机型
  `.props` 里的配套说明）。同上，只影响 ADSP 图选择；且改指会抢走底包小布的
  BREENO 图，风险无收益。
- **小米版 `customva_plugin.so` 替换**（`config/mi_vendor_lib_sources.tsv` +
  `test_mi_vendor_lib_sources.sh` + `xiaoai_customva_plugin` 开关）。它是 DSP 声音模型
  解析插件；2026-09-29 对照实验已证对运行时真正加载的录入 `.udm` 两个版本等价
  （底包版 `7607f7b7` 与小米版 `fc9d4182` 都 `ParseSoundModel status 0`、失败点逐字相同），
  无可观测收益却换掉 vendor HAL 组件，是本模块侵入最高的一项。
- **`wakeup/r.c()` DSP L1 置信度 0x45→0x23 与 `v0/h.k()` 回调 wake lock 800→7000ms**。
  两个值都只在 ADSP L1 路径上生效：`r.c()` 是 private且仅被 `r.g()`/`r.k()` 调用，
  `h.k(Context)` 全 dex 唯一调用点在 `F.onRecognition()`；而 `xiaoai_cpu_kws=true` 后
  这两条入口永不被执行。保留它们只会掩盖后续失败的归因。

### 来源与目标分区

- 来源：`mi_odm`（原包 odm：声学模型与声学属性）。自 2026-09-29 起不再使用 `mi_vendor`
  作为来源分区（小米版 `customva_plugin.so` 替换已移除）。
- 目标：`odm`（模型、属性载体、PAL `concurrent_capture` 与 metadata）与 `vendor`
  （属性载体）。本模块不再写 `system_ext`。
- SELinux bundle 只写最终 `vendor_property_contexts` 与 `precompiled_property_contexts`，
  并清理可选 `odm_property_contexts` 中七个目标键遗留的 `vendor_default_prop exact` 条目。

### 参数

机型组合入口可通过 `XIAOAI_WAKEUP_PROPERTIES_FILE` 提供可选 `.props`：

| 键 | 取值 | 说明 |
| --- | --- | --- |
| `odm.prjname` | 纯数字（底包 `ro.boot.prjname`） | 非空时额外把声学属性写入 import 链目标 `/odm/etc/<prjname>/build.gsi.prop`；未提供就只走 build.prop 与 init rc 载体 |
| `pal_concurrent_capture` | `true`/`false` | 是否把底包 PAL `concurrent_capture` 改为 `true`，共享模块默认 `false`；CPU 前端的常驻采集需要它才能与其它 App 录音并发 |
| `xiaoai_cpu_kws` | `true`/`false` | 免手唤醒是否改走 CPU FlexKws 前端（默认 `false`，即保持 ADSP 路线） |
| `xiaoai_cpu_kws_hold_ms` | 100~60000，默认 5000 | 唤醒后让麦时长；同时写入 `H.k()` 与 `PortCpuKws.onWakeup()` |
| `xiaoai_cpu_kws_gap_ms` | 0~60000，默认 1500 | 一轮无检出后重开下一轮的间隔 |
| `xiaoai_cpu_kws_window_sec` | 1~600，默认 6 | CPU 检出窗口秒数，按 32000 B/s 换算成 `t.b` 字节数 |
| 七个 bundle 目标 `ro.vendor.audio.soundtrigger.*` / `ro.vendor.audio.voiceassist.support_record_type` 键 | 属性值 | 覆盖从原包迁移的声学属性；不接受目标集合外的音频属性 |

`VoiceAssist` 的 `cloudControl.device` 白名单必须等于运行时 `Build.DEVICE`，取值优先级为
`XIAOAI_VOICEASSIST_DEVICE_CODE` → `RUNTIME_DEVICE_CODE` → `init_port_env` 的原包身份快照
（`PORT_SOURCE_DEVICE_CODE`）。未启用钱包等会改写 `odm.device` 的身份修正时（如一加 15、
Ace 6），入口不需要再重复写死代号；声明了 `RUNTIME_DEVICE_CODE` 的组合（Neo8、Ace 6T）会
自动跟过去。

### 验证边界

- 模型迁移与属性对齐来自原包数据，属于确定性迁移。
- `concurrent_capture=true` 沿用 OnePlus 13 (SM8750) 移植上的实测值；Ace 6T（SM8845）
  真机已确认可开启并发不崩溃，其他机型尚未逐项验证。
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
- Ace 6T 真机日志曾为 `Input vendor uuid : 61696d69-30f2-11e6-b0ac-40a8f03d3f1e`、
  `Failed to get sound model platform info`、`PAL -22`、`SoundTrigger INTERNAL_ERROR`，随后音频 HAL
  持续重启。补齐该 UUID 的 stream_config 可解除 platform info 失败；本模块不迁移整个
  XML、PAL 库、`audio_module_config`，只合并片段并校验 `usecaseKvManager.xml` 的 devicePP 映射。
- **2026-09-24 DSU 热修补复核（临时 bind mount，未写入分区）**：在 Ace 6T DSU 上把补齐该 UUID
  stream_config 的 `resourcemanager.xml` 暂存于设备 tmpfs 并 bind mount 到
  `/odm/etc/resourcemanager.xml`，`audiohalservice.qti` 每轮失败后换 PID 并重新解析 XML。结果：
  `Failed to get sound model platform info` 消失，失败下推到
  `PAL: SessionAlsaPcm: getMIID: Failed to get tag info c0000008, status = -19`（ENODEV），中间件仍为
  `LOAD_PHRASE_MODEL ... INTERNAL_ERROR (code 5)`。卸载后回到 platform info 失败，说明该子步骤
  确实是之前的唯一缺失项。`0xC0000008` 即片段里 `load_sound_model_ids`/`buffering_config_ids`/`engine_reset_ids`
  的模块 tag，属 ACDB/AGM 图层面。本次实验证据在卸载后即失效，只对当时的 DSU 运行时成立。
- **2026-09-24 第二层取证（同样为临时 bind mount，已全部卸载）**：逐项验证底包→小米侧的必要前提，
  均未写入仓库补丁：
  - 换用小米版 `customva_plugin.so`（`fc9d4182…`，底包版为 `7607f7b7…`）后，
    `PAL: CustomVA: ParseSoundModel: Exit, status 0` 成立，即 `XiaoAiTongXueMi.udm` 可被解析，
    失败点后移到 `SoundTriggerEngineGsl` 创建。
  - 底包 `usecaseKvManager.xml` 的 `CUSTOM1 Instance=1` 指向小布的 `0xBC000012`；改为
    小米两份发包都使用的 `0xBC000004` 后，`PayloadBuilder` 拼出 `0xbc000004/0xb1000003/0xab000001`
    且 `SessionAlsaPcm: open: Exit status 0`（会话可打开）。
  - 上述两项同时生效后，仍为 `ACDB: AcdbGetUsecaseSubgraphList: Unable to find the graph key vector`
    → `gsl_graph_get_tags_with_module_info ... 19` → `getMIID ... c0000008, status = -19`。
  - 当时结论为“否证底包 ACDB 缺图”：把加载的 `/odm/etc/acdbdata/acdb_cal.acdb`（`74442b4d…`）换成
    小米 alor 侧 `MTP_alor_wcd9378_acdb_cal.acdb`（`bb2200e6…`）后，同一 GKV 仍查不到。
    **2026-09-28 静态取证修正：这两份 ACDB 都不含 `CUSTOM_*_RAW` 子图，换库必然同样失败；
    含 RAW 子图的是小米 `mi_odm/etc/acdbdata/Mi/Mi_acdb_cal.acdb`，本模块不迁移它。**
  - **9p 与 17U 等价**：两发包的 `XiaoAiTongXueMi.udm`、`mi_vendor/lib64/customva_plugin.so`、
    `mi_vendor/etc/acdbdata/alor_mtp_wcd9378/MTP_alor_wcd9378_acdb_cal.acdb` md5 逐项相同，
    `usecaseKvManager` 的 `CUSTOM1` 映射也相同，因此改换小米 Pad 9 Pro 作为米侧数据源不会带来差异。
    设备声卡名为 `alor-mtp-wcd9378-snd-card`（`ro.soc.model=SM8845`）。
  - `PayloadBuilder: retrieveKVs: No KVs found for the stream type/dev id: 43` 日志当时被归因为
    “整套换成小米 `usecaseKvManager.xml`”才能验证的变量；2026-09-28 已证明真因在同一组
    KV 的 devicePP 维（见下条），无需换整份文件。
  - `PAL: STUtils: voiceuiDmgrManagerInit: dlopen failed for voiceui dmgr ... libvui_dmgr_client.so` 在两
    个小米发包中都不存在该库，属可选路径，不视为移植缺件。
- **2026-09-28 静态取证：`getMIID c0000008 -19` 的真因是 devicePP 图键取不到，不是底包缺图**。
  PAL 用 `resourcemanager.xml` 的 capture_profile 名去 `usecaseKvManager.xml` 的
  `DevicePPType=` 名单反查 `0xAD000000`，再与 stream_config/STREAMTX/INSTANCE 拼 GKV：
  - Oplus SM8845 底包（Ace 6T 与 Neo8 实测一致）只有 `DEVICEPP_TX_CUSTOM_NS`(0xAD000026)
    与 `DEVICEPP_TX_CUSTOM_ECNS`(0xAD000025)，**没有**小米侧才有的
    `DEVICEPP_TX_CUSTOM_NS_RAW` / `DEVICEPP_TX_CUSTOM_ECNS_RAW`。
  - 底包 `odm/etc/acdbdata/acdb_cal.acdb` 实际含 46 张
    `..._Stream_Config_CUSTOM` 图（`DevicePP_Tx_CUSTOM_NS`/`CUSTOM_ECNS`/`RAW_LPI` 均在），
    只是没有任何 `CUSTOM_*_RAW` 子图；小米 `Mi_acdb_cal.acdb` 有 52 张含 8 条 RAW。
  - 早期片段按小米 `…3f1e` 原样引用 `*_CUSTOM_NS_RAW`/`*_CUSTOM_ECNS_RAW`，因此无论
    选底包还是 `MTP_alor` ACDB，devicePP 维永远查不到 → 固定停在 GKV 失败。当时
    “底包没有任何 CUSTOM VA 图”“AMDB 未注册该 CAPI 模块”的推论均不成立；
    `Processor ID(2)/(5) does not exist in database` 应视为连带噪声。两侧
    `libcapiv2udk7vendor/svacnn/svarnnvendor.so` 逐字节相同，ADSP 侧 CAPI 模块不是差异源。
- **app 侧 UUID 选择链（原包 VoiceTrigger 反编译）**：`com/miui/voicetrigger/wakeup/r` 的静态初始化
  从 `ro.vendor.audio.soundtrigger.support_record_type`（`SystemProperties.getInt(..., -1)`）取通道数：
  值为 `0x0022`（原包取值，低四位与次四位都是 2）时按 4 通道选官方词 `…3f1e`、自定义词 `…3f11`；
  取不到数值（属性缺失或 `-1`）时按单通道选 `…3f1b` / `…3f1d`。小米原包同一份 XML 里两组条目
  都在，因此本组合用机型 `xiaoai_wakeup.props` 将该属性覆盖为 `-1`，并只补齐非 RAW 两组条目。
- **上述 ADSP 修复的历史取证（保留以免重复踩坑，对应代码已于同日移除）**：非 RAW 条目的 GKV 能否命中、
  `XiaoAiTongXueMi.udm`（eai2/eNPU 2.6.2）在单通道非 RAW 配置下能否被 ADSP 接受，当时只由
  静态取证推导——后来真机证实：非 RAW 片段与图键改指全部生效后，仍卡在
  `gsl_graph_send_nonpersist_cal … failed 2` → `createMmapBuffer -22`，因此整组已移除。
  当前唯一保留的路线是《CPU FlexKws 前端子步骤》，`support_record_type=-1` 因它仍需要
  单声道 int16 而保留。
- **2026-09-29 刷机后真机判据（本模块修复项逐项得到确认，并定位出最后一个变量）**：
  重新打包刷入后，DSU 日志按顺序拍到：
  - `StreamSoundTrigger: ProcessEvent: Input vendor uuid : 61696d69-30f2-11e6-b0ac-40a8f03d3f1b`
    —— 非 RAW 片段与 `support_record_type=-1` 同时生效；
  - `CustomVA: ParseSoundModel: 460: Exit, status 0` —— **小米版 `customva_plugin.so` 替换生效**（此前需临时挂插件才能拿到）；
  - `SessionAlsaPcm: open: 482: Exit status 0` —— 会话可开；
  - `PayloadBuilder: findKVs: key: 0xad000000 value: 0xad000026` —— **RAW→非 RAW 修正生效**，devicePP 图键已能解析（早期这里是 `No KVs found`）；
  - 但同一行 `key: 0xbc000000 value: 0xbc000012` 说明 stream config 仍指向小布 BREENO 图，
    于是 `ACDB: AcdbGetUsecaseSubgraphList: Unable to find the graph key vector` →
    `getMIID c0000008 -19` → `LoadSoundModel status -19` → STHAL `INTERNAL_ERROR (code 5)`。
  因此上一轮“devicePP 是唯一变量”的推断只对了前半：真正的完整链是**三段**——
  capture_profile → devicePP 图键（已修）、CUSTOM1 Instance 的 stream config 图键（本次补上）、
  ACDB 内存在该组合的图（已用字符串证实存在 `..._DevicePP_Tx_CUSTOM_NS_..._Stream_Config_CUSTOM`）。
  同时修正：“VoiceTrigger 设置页必崩”与 `UdkSettingActivitySuper` 缺类是上一轮镜像里
  `/product` 混入了 SM8750（versionCode 2026020321）那代 APK 造成的；干净原包
  （2036082721）只声明 `.udk.UdkSettingActivity` 且能正常进入训练页。
  **改指后的 GKV 是否真正命中仍未验证**（需再一次打包刷机）。
- **app 侧使能位与加载前提（真机确认）**：唤醒总开关是 VoiceTrigger 自己的
  `shared_prefs/com.miui.voicetrigger.PREF_VOICETRIGGER.xml` 里的
  `com.miui.voicetrigger.PREF_KEY_VOICETRIGGER_ENABLED`；且必须存在录入产物
  `files/voiceprint_model/xatx.udm`，否则 app 在 `ATTACH` 后直接不发起
  `LOAD_PHRASE_MODEL` 并把使能位写回 false（日志
  `VT_VoiceWakeupBean: XATX isModelAvailable = ...:false`）。
- 静态分析（Ace 6T 原包 VoiceTrigger 反编译）表明 ADSP 唤醒链路的系统层前提：odm 模型文件、
  `sva-7.0`、`device_provisioned=1`、小爱（com.miui.voiceassist）已装且持 RECORD_AUDIO。
  其中 odm 模型文件只属于已废弃的 ADSP 路线；CPU 前端的词模型在 APK assets 内。
- 原包未提供声学模型（无 `mi_odm/etc/*.udm|*.uim` 或缺少 `XiaoAiTongXue` 主模型）时，
  **只跳过声学模型迁移**，属性、设备准入、互联兜底与 CPU FlexKws 前端照常执行
  （2026-09-29 修正：旧行为是整模块 `exit 0`，会让 `xiaoai_cpu_kws` 静默失效）。
- **2026-09-12 五组实验矩阵的历史结论已部分失效**：当时「底包 / mi_dsp 三件套 ×
  原包 / 混合 resourcemanager × 原生 UUID / 借用原生 UUID」全部停在
  `getMIID: Failed to get tag info`、`StartCapture failed 10` 与零检出。
  2026-09-24 先修正为一层：至少一组实际停在更早的 `Failed to get sound model platform info`；
  2026-09-28 再修正为二层：当时能达到的所有配置都引用了 `*_CUSTOM_*_RAW` profile，
  而底包 `usecaseKvManager.xml` 没有对应的 devicePP 映射，因此“矩阵全部失败”只能证明
  “RAW 变体在底包不可用”，不能证明“任何可达配置都失败”，更不能证明“ADSP 拒收模型”。
  同理，“小米侧不存在 SM8845 机型、`XiaoAiTongXueMi.udm` 按 SM8850 训练因此结构性不兼容”
  也不成立：小米 9p/17U 发包本身就是 alor（SM8845，声卡 `alor-mtp-wcd9378-snd-card`），
  该 `.udm` 就是给 SM8845 设备预置的（`mi_odm/etc/acdbdata/Mi/` 下的 `*.eai` 名字里的
  `8850` 只是训练集命名）。
  在当前修复（非 RAW 条目 + `support_record_type=-1`）真机验证前，不再把“DSP 唤醒已封闭”
  或“必须改走 CPU 软件 KWS”当作结论；CPU KWS（原包 VoiceTrigger.apk 自带的 FlexKws
  `libflexkws.so` + `kws_ma62_xatx_*` tflite + `1ch`/`qcom_1mic1ref` json5）仅作为
  真机失败时的备选路线记录，本模块不实现也不依赖它。

---

## VoiceAssist / VoiceTrigger 准入修补子步骤（历史模块名 `fix_xiaoai_voicetrigger`）

修复小爱同学的 VoiceAssist 设备准入和 VoiceTrigger DSP 唤醒链路。模块默认关闭，
只有组合入口显式设置 `XIAOAI_VOICETRIGGER_PATCH=true` 才会执行；开关只接受
`true`/`false`。启用时还必须通过 `XIAOAI_VOICEASSIST_DEVICE_CODE` 提供安全的
Android device token。

### 精确根因

Ace 6T 运行日志曾为 `device support:false, voice trigger:true`。静态检查
`product/priv-app/VoiceAssistAndroidT/VoiceAssistAndroidT.apk` 已确认：
`assets/voiceassist.ai.voice.trigger.config` 的 `cloudControl.device` 会与
`Build.DEVICE` 精确比较，原配置不含本机的运行时代号，因此 VoiceTrigger 能力已开启
但 VoiceAssist 仍拒绝该设备。

运行时代号由钱包身份修正后的 `OP6117L1` 提供（不是原包代号 `nezha`），因为
`fix_coloros_wallet` 把 `odm.device` 改为真值后 `Build.DEVICE` 随之变为 `OP6117L1`，
准入名单必须与它一致。

Ace 6T 组合入口明确设置（与 `RUNTIME_DEVICE_CODE` 同源）：

```bash
XIAOAI_VOICETRIGGER_PATCH=true
XIAOAI_VOICEASSIST_DEVICE_CODE=OP6117L1
```

**2026-09-29 真机复核**：Ace 6T DSU 上 `Build.DEVICE=OP6117L1`，且镜像内
`VoiceAssistAndroidT.apk` 的 `cloudControl` 已含 `OP6117L1`（全名单唯一 `OP` 开头条目），
说明本准入子步骤在打包产物中已正确生效；但唤醒仍不可用，卡在 app 层阻塞（其中
设置页崩溃一项的归因已于同日修正，见下）。

### 2026-09-29 DSU 真机：app 层阻塞

1. **语音唤醒设置页必崩（已修正归因：不是当前组合的固有缺陷）**：当时 voiceassist 启动
   `com.miui.voicetrigger/.udk.UdkSettingActivitySuper`，而那代 DEX 只有
   `udk/UdkSettingActivity`（Manifest 两者都声明，`…Super` 类不存在）→
   `ClassNotFoundException` 闪退。2026-09-29 后续取证确认：那是旧镜像把 SM8750
   （versionCode 2026020321）代 VoiceTrigger 混进 `/product` 的结果；干净原包
   （2036082721）不声明该组件，页面可正常进入 `WakeTrainingActivity` 并完成录入。
   当时临时加的薄壳类已删除（见「已移除的历史能力」）。
   **保留的有效结论**：录入产物 `/data/user/0/com.miui.voicetrigger/files/voiceprint_model/xatx.udm`
   是发起加载的硬前提，缺失时 app 根本不请求 `LOAD_PHRASE_MODEL`。
2. **VoiceTrigger 启动约 3.5s 后自杀**：`com.xiaomi.continuity.infra.ServiceConnector` 绑定
   `com.xiaomi.mi_connect_service/com.xiaomi.continuity.ContinuityServiceManagerService` 抛未捕获
   `SecurityException: Not allowed to bind to service` → `RuntimeInit$KillApplicationHandler` 发
   SIG 9。`com.xiaomi.mi_connect_service` 实际已安装且 `installed=true hidden=false enabled=DEFAULT`，
   但 `dumpsys package` 的服务表里看不到 `ContinuityServiceManagerService` 组件（只看到同包的
   `NetworkingService`，其 `permission=com.xiaomi.permission.BIND_CONTINUITY_SERVICE`）→ 应是组件/版本
   错位或包可见性问题，尚未定位到确切原因。
3. **唤醒总使能位的真实来源**：不是 `Settings` 的 `voice_trigger_enabled`/`global_voice_trigger_enabled`，
   也不是 voiceassist 的 `key_ai_voice_trigger`，而是 VoiceTrigger 自己的
   `shared_prefs/com.miui.voicetrigger.PREF_VOICETRIGGER.xml` 里的
   `com.miui.voicetrigger.PREF_KEY_VOICETRIGGER_ENABLED`（默认 false）；把它置 true 后
   `VT_AutoStart` 立即报 `voiceTriggerEnabled=true, shouldEnabled=true` 并拿到 `openAutoStart`，
   随后因上述第 2 条崩溃被复位。
4. 同时真机确认音频栈本身健康：`LIST_MODULE` 返回 `{Id: 0, Implementor: QUALCOMM Technologies, Inc,
   Version: 259}`，合并后的非 RAW XML 能被 PAL 正常解析且 HAL 不崩；因此本文件的 devicePP 修复
   方案仍**未经验证**（app 在到达 `LOAD_PHRASE_MODEL` 前就被杀）。
5. 设备端噪声：预装的 `local.mio.xiaoairecognitionhook` 在这代包上报
   `hook install failed: Cannot hook abstract methods … wakeup.q.onRecognition`，与本文“SM8845 不应
   开启 hook”的结论一致，验证时应先禁用该 hook。

以上 1、2 两项未实现任何修复：本模块不修改 voiceassist 的 Intent 目标，也不打算吞掉
continuity 绑定异常；需要先定位再按最小侵入原则决定补丁形态。

其他机型入口不启用本模块，也不从原包或运行中属性推断目标设备代码。

### 2026-09-29 DSU 真机：阻塞下移到 ADSP 拒收非持久校准

刷机后三段链已全部确认：GKV 命中（`findKVs 0xbc000000→0xbc000004`、
`0xad000000→0xad000026`）、`LoadSoundModel Exit status = 0`、`LOAD_PHRASE_MODEL("…3f1b") -> 0`。
当时的剩余唯一阻塞在 `StartRecognition`：`Failed to create mmap buffer, status = -22`，并连带
`Underlying HAL driver died` 与音频 HAL 重启环。

同日在 DSU 上用 tmpfs bind 对 `odm/etc/resourcemanager.xml` 做了三个单变量热验证（每轮都以
“哨兵日志”证明新 XML 确实被 HAL 解析、并核对 `/proc/1/root/<目标>` 排除命名空间假象后才判读）：

| 变体 | 改动 | 生效证据 | 结果 |
| --- | --- | --- | --- |
| V1 | 两条 `CUSTOM_VOICE_UI` 的 `out_channels` 1→2 | `populateStreamCkv: stream channels 2`、`CreateBuffer buf size` 由 128000 变 256000 | 仍 `-22` |
| V2 | `low_power` 换底包原生 `DUAL_MIC_16KHZ_16BIT_RAW_LPI`（high_performance 保持 `CUSTOM_ECNS`） | `cap_prof DUAL_MIC_16KHZ_16BIT_RAW_LPI: chs=2, snd_name=va-mic-dmic-lpi` | 仍 `-22` |
| V3 | V1+V2 | 上述两条同时命中 | 仍 `-22` |

因此**“stream 通道与 devicePP 通道不一致导致 -22”的假设已被否证**，纯 XML 配置路线在该点已穷尽。
失败点实际位于更深层：`createMmapBuffer` 打开 VA 采集图（AIF 37 / `va-mic-dmic-lpi`）时，ADSP 对
下发非持久校准的命令返回错误：

```
gsl: gsl_graph_send_nonpersist_cal:903 send non-perist cal failed 2
gsl: graph open for single gkv failed 2
AGM: graph: graph_open: 799 Failed to open the graph with error -22
```

同一次失败的 AGM metadata 打印显示 GKV 五个键全部可解析（`0xbc000000=0xbc000004`、
`0xad000000=0xad000026` 或 `0xad00000c` 等），即 ACDB 里图存在、子图能列出，不是早先的
“取不到 graph key vector”。后续取证方向相应转为 ACDB 归属与该自定义模块的非持久校准内容，
不再新增同类 XML 变体。

本轮已排除另一个 app 侧假设：**注入的 LAB custom data 不是元凶**。做法是把只卸除
LAB 注入（其余 DEX 项逐字保留）的实验版重打包成 `product.img` 并刷入 DSU，重新录入
唤醒词后日志仍为：`LOAD_PHRASE_MODEL("…3f1b") -> 0`、`LoadSoundModel: Exit, status = 0`、
`createMmapBuffer: … channels 1`，随后依旧 `gsl_graph_send_nonpersist_cal … failed 2` → `-22`。
因此原 DEX 修改 2（`r.e()` 注入 20 字节前视缓冲与辅类 `PortWakeupHooks`）已于 2026-09-29
撤除；同时验证了去掉它不影响录入与模型加载链路。

另一次 ACDB 对照（把小米 `MTP_alor_wcd9378_acdb_cal.acdb` bind 覆盖
`/odm/etc/acdbdata/acdb_cal.acdb`）未取得判定：AGM 打印 `Load file:` 与 `Last Modified: Mon Jan 12
14:25:47 2026` 证明新 DB 已生效，但脚本的 `force-stop` 触发 Oplus 后台限速
（`filterByRateLimit … cooldownMs=600000`），整轮没有 `LoadSoundModel`；且该 DB 报
`Processor ID(5) does not exist in database for VM-0`，与本平台拓扑不匹配。

上述 XML 与 ACDB 结论来自 DSU 运行时热验证（实验结束已 `umount` 并核对目标哈希回到基线）；
LAB 对比则已经过一次真实刷机。仓库当前产物与设备一致（均为不含 LAB 与声纹门放行的形态）。

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
与 2026-09-29 DSU 真机取证确认以下行为硬编码在 app 内，无属性或资源通道：

| 位置 | 修改 |
| --- | --- |
| `wakeup/r.smali` `c()` | DSP L1 置信度 `0x45`（69）改为 `0x23`（35） |
| `v0/h.smali` `k()` | DSP 回调 wake lock 从 800ms 延长到 7000ms；原位常量寄存器可能随 ROM 版本漂移（SM8845/SM8850 使用不同寄存器），补丁已适配寄存器无关检测与替换 |
| `com/xiaomi/continuity/infra/ServiceConnector$Impl.smali` `bindService(ServiceConnection)` | 给 SDK>=29 的 `Context.bindService` 直调加 `SecurityException` 兜底，异常时返回 false（见下） |

补丁逐方法核对指令结构；版本形态不符时拒绝盲目修改。

### continuity 绑定兜底的不可避免原因（2026-09-29 真机取证）

它在 app 代码内部，没有任何配置、属性或资源通道可改变，因此属于最小侵入原则的例外
（只能改 DEX）：线程 `continuity-service-manager-connector` 抛未捕获
`SecurityException: Not allowed to bind to service
com.xiaomi.mi_connect_service/com.xiaomi.continuity.ContinuityServiceManagerService`，
由 `RuntimeInit$KillApplicationHandler` 发 SIG 9。互联服务已安装（17U 预置版
versionCode 60004241），但 `dumpsys package` 里该组件声明数为 0；17U 与 9p 两版
`mi_connect_service.apk` 都是“DEX 有类名、Manifest 无声明”，小米真机靠应用更新补齐
→ 移植侧无“对的 APK”可拿，只能让这次 bind 失败不致命（SDK<29 的反射路径已有 try，
因此只改 SDK>=29 直调分支，正常成功路径行为不变）。

验证情况：已在真机拉回的 VoiceTrigger.apk 副本上验证增量植入、二次执行正确 SKIP（重新解码
仍能识别 `.catch Ljava/lang/SecurityException;` 位于目标方法块内）、`unzip -t` 与
`zipalign -c -P 16` 通过；**2026-09-29 刷机后真机已确认修复生效**：拉起
`VoiceTriggerService` 后 12 秒进程仍存活，采集里没有任何 `SecurityException`、
`FATAL EXCEPTION` 或 `Underlying HAL driver died`（修复前必然约 3.5 秒自杀）。

置信度与 wake lock 两项仍**未获得真机反证**（唤醒至今未成功过一次）。

原“`wakeup/s.smali` `e(w)` XATX/UDK 声纹门放行”一项已于 2026-09-29 撤除：用户完成录入后
`files/voiceprint_model/xatx.udm` 真实存在，该门本可自然通过，而放行它属于放宽安全边界；GKV
打通后再保留它只会混淆后续失败归因。撤除后 VoiceTrigger DEX 修改为四项。

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
- VoiceTrigger 可通过反编译结果、四项修改与注入类、重复执行和 ZIP 完整性做静态验证。
- 当前结论仅覆盖已分析的 SM8845 原包，只有 Ace 6T 组合入口显式启用。
- 尚未完成刷机后真机闭环。仍需在 Ace 6T 验证日志不再出现
  `device support:false, voice trigger:true`，并确认两个 APK 通过平台校验正常加载，
  以及亮屏/熄屏唤醒、连续触发和录音并发稳定性。静态回编译、`unzip -t` 与 Signing
  Block 字节保留不能替代这些真机证据。

VoiceTrigger DEX 修补属于最小侵入原则的例外：其阈值与回调保活没有
系统层配置通道。VoiceAssist 准入则仅修改其配置资产，不扩大到 DEX。
