# 移植补丁模块

需要让多个补丁复用同一 APK/JAR 时，补丁自身可按范围 source `tools/apk_patcher.sh`，使用 apk_patcher_open、apk_patcher_snapshot、apk_patcher_rollback、apk_patcher_record_entry 和 apk_patcher_finalize；公共辅助只管理归档事务，具体 Smali、资源和 DEX 选择仍由调用补丁负责。`OP15_port.sh` 会为组合流程建立共享 Settings 会话，所有已登记 DEX 在流程末尾只回编译、对齐并原子替换一次；单个补丁失败会恢复该补丁快照并继续后续模块。未接入该接口的补丁行为不变。

`port` 目录中的补丁按组织方式和硬件依赖拆分，默认不会自动全部执行。请先确认补丁要求的分区已经解包到工程目录，再根据目标设备显式选择需要的补丁。

目录分类如下：

| 目录 | 适用范围 |
| --- | --- |
| `common/<补丁名>` | 可被大部分机型组合复用的共享补丁、兼容处理与公共流程；仍须检查补丁自身前提。 |
| `features/<补丁名>` | 按目标设备能力显式启用或配置的可复用硬件特性模块；机型参数由组合入口提供。 |
| `devices/<机型>/<补丁名>` | 逻辑或资源本身无法抽象复用、只适用于指定设备的专属补丁。 |

## 分区来源与最终命名

本工程中的“原包”指小米移植原包，“底包”指当前运行设备的原厂包。目录来源固定如下：

| 工程目录 | 来源 | 用途 |
| --- | --- | --- |
| `odm` | 底包 odm | 最终 `odm` 分区工作树；必须保留底包 ODM，不能整体替换为原包 ODM。 |
| `vendor` | 底包 vendor | 最终 `vendor` 分区工作树。 |
| `product` | 原包 product | 最终 `product` 分区工作树。 |
| `system` | 原包 system | 最终 `system` 分区工作树。 |
| `system_ext` | 原包 system_ext | 最终 `system_ext` 分区工作树。 |
| `mi_vendor` | 原包 vendor | 额外取材目录，资源按清单映射到最终 `vendor`，不作为最终分区。 |
| `mi_odm` | 原包 odm | 额外取材目录，资源按清单映射到最终 `odm`，不作为最终分区。 |
| `mi_ext` | 原包 mi_ext | 原包独立分区；由对应模块按真实目标路径合并。 |

最终加载到设备的分区名称必须完全匹配真实设备分区。`mi_vendor`、`mi_odm` 仅用于区分同名原包来源，不能以该名称生成或刷入最终分区；补丁会把 contexts 中的 `/mi_vendor`、`/mi_odm` 同步转换为 `/vendor`、`/odm`。

补丁不会自动解包 `DNA_input/mi_*.img`。使用动态来源补丁前，必须先通过 D.N.A 将对应镜像解包为同名目录；涉及文件搬运的补丁还必须在当前配置目录中保留来源与目标分区的 contexts、fsconfig 文件。

## 使用方式

在 `DNA_hyper/port` 目录执行：

```bash
# 仅列出可用补丁，不执行补丁
bash port_main.sh
bash port_main.sh list

# 对默认工程目录执行通用补丁
bash port_main.sh common/fix_launcher common/fix_device_identity

# 使用补丁目录内置的底包 init.usb.configfs.rc 执行 MTP 修复
bash port_main.sh common/fix_mtp

# 执行可复用的通用兼容补丁
bash port_main.sh features/fix_nci_nfc common/fix_face_unlock \
  common/fix_settings_haptic

# 按目标硬件能力选用特性补丁；超声波指纹还需要机型入口提供参数
bash port_main.sh features/fix_oplus_ltpo \
  features/fix_oplus_fingerprint_protocol

# 执行一加 15 专属补丁与自动刷新率补丁
bash port_main.sh devices/oneplus15/fix_auto_brightness \
  common/fix_boot_refresh_rate

# 单独执行当前一加 15 流程中的通用兼容补丁
bash port_main.sh common/fix_camera_mr common/fix_modem_xts \
  common/fix_mtp

# 统一合并 vendor 来源策略、已启用模块片段和完整 SELinux bundle
bash port_main.sh common/fix_vendor_avc

# 对其他工程目录执行指定补丁
bash port_main.sh --project-dir /path/to/project common/fix_launcher

# 可选指定同目录下的 SKU 附加 prop；文件缺失时弱警告并继续
DEVICE_IDENTITY_PROP=nezha_5.9.9.prop bash port_main.sh common/fix_device_identity

# 可选覆盖原包设备显示名；未设置时沿用 mi_odm 的原包属性
DEVICE_DISPLAY_NAME='OnePlus 15' bash port_main.sh common/fix_device_identity

# 一加 15 当前整套流程
bash OP15_port.sh

# 一加 Ace 6 / Ace 6T 整套流程（说明见 README_ACE6.md）
bash OPAce6_port.sh
bash OPAce6T_port.sh
```

`apply.sh` 是由 `port_main.sh` 管理的补丁模块，不应直接执行。`port_main.sh` 只导入一次 `tools/tools.sh`，再在彼此隔离的子 Shell 中加载各补丁，因此补丁内不再重复导入公共接口，同时不同补丁的严格模式、变量、trap 和 `exit` 不会互相污染。

执行首个补丁前，`init_port_env` 会从尚未修改的分区树识别底包与原包设备，并把同一份身份快照传给全部下游补丁。底包优先读取 `odm/etc/<ro.separate.soft>/build.default.prop`；没有该配置时，只在 `odm/etc/*/build.default.prop` 唯一时采用它，随后再按 `odm/build.prop`、`odm/etc/build.prop`、`vendor/build.prop` 回退。原包优先按 `mi_odm/etc/build.prop`、`mi_odm/build.prop`，再按 `product` 与 `system` 的 build.prop 识别；`mi_vendor` 仅是来源标记目录，不参与设备代号推断。补丁不得自行重读已可能被修改的 ODM 身份，也不得写死原包设备代号。

下游统一使用 `PORT_BASE_DEVICE_CODE`、`PORT_BASE_DEVICE_NAME`、`PORT_BASE_DEVICE_MODEL`、`PORT_BASE_DEVICE_MARKET_NAME` 及对应的 `PORT_SOURCE_DEVICE_*` 变量；原包机型 XML 路径由 `PORT_SOURCE_DEVICE_FEATURE_FILE` 提供。SKU 附加 prop 不属于设备识别结果，也不会按代号自动猜选；需要时由组合入口通过 `DEVICE_IDENTITY_PROP` 明确指定文件名，再交给 `common/fix_device_identity`。指定文件不存在时只输出弱警告并忽略附加配置，`mi_odm/etc/build.prop` 的基础设备标识写入继续执行。`common/fix_device_identity` 只有在显式提供 `DEVICE_DISPLAY_NAME` 时才覆盖 `ro.product.odm.marketname`，未提供时沿用 `mi_odm` 基础属性或附加 prop，其他原包身份和认证字段不受影响。

`tools/tools.sh` 统一管理配置目录、contexts 与 fsconfig 名称模板，只识别工程根目录下的以下两套格式；两者同时存在时优先使用 `DNA_config`：

| 配置目录 | contexts 模板 | fsconfig 模板 |
| --- | --- | --- |
| `DNA_config` | `{part}_contexts.txt` | `{part}_fsconfig.txt` |
| `config` | `{part}_file_contexts` | `{part}_fs_config` |

模板中的 `{part}` 会替换为 `product`、`system` 等分区名。复杂的元数据处理统一由 Python 3 工具 `tools/partition_metadata.py` 完成。特殊 CLI 由 `tools/toolchain.sh` 统一解析：将 `local.properties.example` 复制为未提交的 `local.properties` 后，可显式指定 `apktool`、`zipalign`、`avbtool`、`ddk`、`ndk` 的绝对路径；未指定时，`zipalign` 会从 `ANDROID_SDK`、`ANDROID_SDK_ROOT`、`ANDROID_HOME` 的 `build-tools` 查找，NDK 会依次使用 `NDK_HOME`、`ANDROID_NDK_HOME`、`ANDROID_NDK_ROOT` 或上述 SDK 的 `ndk/`，`avbtool` 依次使用 PATH 命令与工程内置的 `tools/avbtool`（AOSP avbtool 1.3.0）兜底，其它特殊 CLI 只使用同名 PATH 命令。不会扫描 Snap、固定用户目录或其他工程。补丁条目按路径覆盖目标条目，contexts 会忽略正则转义差异进行匹配，目标文件中的重复路径会在每次修改时自动去重；写回 contexts 时会把有效条目的字段间空白统一为单个 ASCII 空格，避免手机版 D.N.A 旧解析器无法识别 Tab 分隔符。文件清单或目录前缀跨分区迁移时，contexts 与 fsconfig 会一起转换，缺少任一来源权限条目都会在复制文件前失败。传入多个补丁时会按参数顺序执行，某个补丁失败后记录失败并继续后续模块，最终以失败状态退出；未显式传入的补丁不会运行。推荐使用完整分类路径；为兼容旧用法，也可使用全局唯一的补丁名，例如 `fix_launcher`。

现有补丁中的 prop 子步骤按可选内容处理：属性来源文件、目标 `build.prop`、属性清单或预期属性条目不存在时，会输出 `WARN` 并只跳过对应 prop 子步骤；同一补丁中的 APK、XML、文件迁移和 metadata 等非 prop 主流程仍继续执行。已经存在但格式无效、属性重复、值冲突或使用不安全符号链接的文件仍会报错退出，不会被静默忽略。

明确用于替换或修补既有文件的子步骤也采用相同的缺失处理：目标文件不存在时输出 `WARN`，只跳过该替换；混合补丁中的独立属性写入、文件迁移或其他可执行步骤继续运行。已经存在但类型错误、版本或校验不受支持、内容冲突或使用不安全符号链接的目标仍会失败。本规则不影响本来就要新增的 Overlay、配置、服务文件、跨分区迁移目标、生成产物及 metadata，公共复制接口仍保留创建这些文件的能力。

## 模块索引

模块的输入、具体行为、限制、验证边界和执行示例已迁移到各模块目录。下表的“改动分区”只列模块直接写入的最终分区工作树及其 metadata；只读来源、条件性目标和由下游统一入口落盘的内容会在模块 README 中单独说明。

### 共享补丁（`common`）

| 模块 | 改动分区 | 用途 |
| --- | --- | --- |
| [`common/disable_odm_imports`](common/disable_odm_imports/README.md) | `odm` | 禁用 ODM 对项目专属和 `my_manifest` 属性文件的外部导入。 |
| [`common/disable_mi_vulkan`](common/disable_mi_vulkan/README.md) | `product` | 禁用不兼容的 Xiaomi Vulkan pipeline cache 属性。 |
| [`common/enable_hyperos_features`](common/enable_hyperos_features/README.md) | `product`、`vendor` | 写入模糊、材质、画质、游戏、声效与相册 XDR 属性。 |
| [`common/fake_device_params`](common/fake_device_params/README.md) | `system`、可选 `system_ext` | 生成 Settings 设备参数缓存与专用 SELinux 域。 |
| [`common/fuck_oplus_hybridzram`](common/fuck_oplus_hybridzram/README.md) | `vendor` | 屏蔽 vendor_dlkm 的 zram/zsmalloc，回退到 system_dlkm 已有版本，并屏蔽底包 Oplus zram/swap 优化模块。 |
| [`common/fix_boot_refresh_rate`](common/fix_boot_refresh_rate/README.md) | `odm`、`product`、`system_ext` | 自动读取底包显示能力，生成刷新率属性、机型刷新率/分辨率列表并修补 Settings 高度计算；多平台底包可通过 `PORT_DISPLAY_TARGET` 按 SoC Target 过滤。 |
| [`common/fix_camera_mr`](common/fix_camera_mr/README.md) | `product` | 禁用不兼容的 CameraMR 特殊输入能力。 |
| [`common/fix_device_identity`](common/fix_device_identity/README.md) | `odm`、`system` | 写入原包设备身份、可选 SKU 属性和可选显示名覆盖。 |
| [`common/fix_face_unlock`](common/fix_face_unlock/README.md) | `product`、`system_ext`、`vendor` | 接入标准 Face HAL 并修复录入进度与完成流程。 |
| [`common/fix_launcher`](common/fix_launcher/README.md) | `odm` | 写入中国区、系统桌面与 APEX 更新属性。 |
| [`common/fix_mi_account`](common/fix_mi_account/README.md) | `odm`、`vendor` | 迁移账号、支付与安全环境资源并登记 SELinux bundle。 |
| [`common/fix_sn`](common/fix_sn/README.md) | `system_ext` | 仅在 Xiaomi Phone SN 为空时，以目标 `ro.serialno` 作为展示 fallback，不改 IMEI、PCB SN 或 Factory ID。 |
| [`common/fix_mi_mtp_kill_self`](common/fix_mi_mtp_kill_self/README.md) | `system` | 将 MTP 服务从 `android.process.media` 隔离。 |
| [`common/fix_modem_xts`](common/fix_modem_xts/README.md) | `system` | 短路不兼容的 Oplus modem/Xiaomi OEM Hook 调用。 |
| [`common/fix_mtp`](common/fix_mtp/README.md) | `system` | 替换匹配底包 USB 栈的 configfs rc。 |
| [`common/fix_oplus_avc`](common/fix_oplus_avc/README.md) | `vendor`、`odm` | 修复实际 Oplus reserve 块设备标签、合并实测最小 AVC，并恢复 mdm_feature 的 SVN/OTA property labels。 |
| [`common/fix_pangu`](common/fix_pangu/README.md) | `product`、`system` | 将 `product/pangu/system` 迁移到最终 system。 |
| [`common/fix_settings_haptic`](common/fix_settings_haptic/README.md) | `system_ext` | 修复 Settings 的触感能力判断。 |
| [`common/fix_vendor_avc`](common/fix_vendor_avc/README.md) | `vendor`、`odm` | 统一合并 vendor 策略、模块片段与 SELinux bundle。 |
| [`common/fix_wechat_safe_mode`](common/fix_wechat_safe_mode/README.md) | `odm` | 删除假的 Camera Extensions 实现。 |
| [`common/merge_mi_ext`](common/merge_mi_ext/README.md) | `product`、`system_ext`、`system`；删除 `mi_ext` 来源 | 将 `mi_ext` 内容映射到真实最终分区。 |

### 硬件特性模块（`features`）

| 模块 | 改动分区 | 用途 |
| --- | --- | --- |
| [`features/fuck_audio_appname`](features/fuck_audio_appname/README.md) | `system_ext` | 定点阻断 HyperOS 私有 `appname` 音频参数，避免 Oplus HAL 拒绝参数后触发输出流 standby。 |
| [`features/fix_linear_haptic`](features/fix_linear_haptic/README.md) | `odm` | 合并目标设备触感属性并设置开机马达类型。 |
| [`features/fix_nci_nfc`](features/fix_nci_nfc/README.md) | `system`、`odm`、`vendor` | 替换 NXP/Xiaomi NFC 应用、写入上层兼容属性并登记最小 SELinux bundle；要求底包提供 NXP 服务契约，不适用于 TMS 栈机型（如一加 Ace 6）。 |
| [`features/oplus_displayfeature_bridge`](features/oplus_displayfeature_bridge/README.md) | `odm`、`vendor` | 将 Xiaomi DisplayFeature 映射到底包 QDCM，并把 mode 20 DC/PWM 转发到 Oplus Panel Feature；同时修复 RGB/色温属性 contexts。 |
| [`features/fix_oplus_lhdc`](features/fix_oplus_lhdc/README.md) | `system` | 向当前 Bluetooth APEX 注入 LHDC V5 编码后端并重建 payload AVB；外层旧签名条目与 APK v2/v3 Signing Block 均保留原始字节，并设置 `log.tag.BTAudioSessionAidl=S`。 |
| [`features/fix_oplus_ltpo`](features/fix_oplus_ltpo/README.md) | `odm` | 补全 MI SurfaceFlinger LTPO 与 Oplus SDM OA/ADFR mode 开关。 |
| [`features/oplus_millet_core_bridge`](features/oplus_millet_core_bridge/README.md) | `system_ext`、`vendor` | 接入 Millet 核心桥预编译 KO、init.rc 和 SELinux bundle；KO 存放在 `system_ext/lib64/modules`，由 `KMI` 选择仓库内 KMI。 |
| [`features/fix_oplus_double_tap_wake`](features/fix_oplus_double_tap_wake/README.md) | `odm`、`vendor` | 通过独立 AIDL bridge 和设备 keylayout 接入 Oplus 双击亮屏；SELinux bundle 由统一入口写入 vendor/ODM 早期策略。 |
| [`features/fix_oplus_fingerprint_protocol`](features/fix_oplus_fingerprint_protocol/README.md) | `system_ext` | 适配 Oplus HAL 与 Xiaomi 锁屏 FOD 触摸协议。 |
| [`features/fix_ultrasonic_fingerprint`](features/fix_ultrasonic_fingerprint/README.md) | `odm`、`vendor` | 换算指纹参数，并登记 Enforcing 下所需的精确指纹 property contexts 与 SystemUI 读取权限；多平台底包可通过 `ultrasonic.fp.target` 按 SoC Target 过滤 PanelResolution。 |

### 一加 15 专属模块（`devices/oneplus15`）

一加 15 的专属模块和传给共享模块的硬件参数见 [`devices/oneplus15/README.md`](devices/oneplus15/README.md)。

| 模块 | 改动分区 | 用途 |
| --- | --- | --- |
| [`devices/oneplus15/fix_auto_brightness`](devices/oneplus15/fix_auto_brightness/README.md) | `odm`、`product` | 适配自动亮度曲线、物理亮度边界和启动亮度。 |
| [`devices/oneplus15/fix_refresh_rate_switch`](devices/oneplus15/fix_refresh_rate_switch/README.md) | `product`、`system_ext` | 保留完整刷新率列表；关闭 Pro 时沿用面板的 60–120Hz DC、144/165Hz PWM，开启 Pro 时请求全局 PWM。 |

启用模块前应根据目标机型和底包确认适用性。不适用的模块不要传给 `port_main.sh`；设备专属模块不得跨机型混用。完整一加 15 组合流程见 [`README_OP15.md`](README_OP15.md)。

### 一加 Ace 6 系列专属模块（`devices/oneplus_ace6`、`devices/oneplus_ace6t`）

一加 Ace 6（PLQ110，Target `sun`，内核 6.6）与 Ace 6T（PLR110，Target `canoe`，内核 android16-6.12）的专属模块和传给共享模块的硬件参数见 [`devices/oneplus_ace6/README.md`](devices/oneplus_ace6/README.md) 与 [`devices/oneplus_ace6t/README.md`](devices/oneplus_ace6t/README.md)。组合流程为 `OPAce6_port.sh` 与 `OPAce6T_port.sh`，与一加 15 流程的差异见 [`README_ACE6.md`](README_ACE6.md)。

| 模块 | 适用机型 | 改动分区 | 用途 |
| --- | --- | --- | --- |
| [`devices/oneplus_ace6/fix_nfc_tms_bridge`](devices/oneplus_ace6/fix_nfc_tms_bridge/README.md) | 仅 Ace 6 | `odm`、`system`、`vendor` | 青藤 THN31（TMS 栈）NFC 桥接：保留底包栈、注入 `/dev/st21nfc` 别名、登记最小 SELinux bundle 并写兼容属性。 |
| [`devices/oneplus_ace6/fix_vendor_selinux_files`](devices/oneplus_ace6/fix_vendor_selinux_files/README.md) | 仅 Ace 6 | `vendor` | 补齐底包缺失的 `plat_sepolicy_vers.txt` 与 `genfs_labels_version.txt`（实测固化为 `202504`）。 |
| [`devices/oneplus_ace6/fix_auto_brightness`](devices/oneplus_ace6/fix_auto_brightness/README.md) | 仅 Ace 6 | `odm`、`product` | P7 面板自动亮度曲线、物理亮度边界与启动亮度。 |
| [`devices/oneplus_ace6/fix_refresh_rate_switch`](devices/oneplus_ace6/fix_refresh_rate_switch/README.md) | 仅 Ace 6 | `product`、`system_ext` | 保留完整刷新率列表；关闭 Pro 时沿用面板的 60–120Hz DC、144/165Hz PWM，开启 Pro 时请求全局 PWM。 |
| [`devices/oneplus_ace6t/fix_auto_brightness`](devices/oneplus_ace6t/fix_auto_brightness/README.md) | 仅 Ace 6T | `odm`、`product` | P7 面板自动亮度曲线、物理亮度边界与启动亮度。 |
| [`devices/oneplus_ace6t/fix_refresh_rate_switch`](devices/oneplus_ace6t/fix_refresh_rate_switch/README.md) | 仅 Ace 6T | `product`、`system_ext` | 保留完整刷新率列表；DC/PWM 策略与 Ace 6 相同。 |

## 鸣谢

本仓库的移植思路、问题定位和补丁实现参考了以下公开资料。感谢各位作者与贡献者分享经验；鸣谢不代表原样采用帖子中的全部做法，实际行为仍以当前仓库实现为准。对于没有独立标题的动态，下表采用正文开头的主题句作为名称。

### 蓝牙与音频方案提供

| 贡献者 | 联系方式 | 提供内容 |
| --- | --- | --- |
| 牢大 | `2806379025` | 蓝牙 LHDC、声音卡顿与 Millet 核心桥方案；本次 `features/oplus_millet_core_bridge` 补丁来源于牢大提供的方案 |

### 主要参考帖子

| 作者 | 帖子 |
| --- | --- |
| Zephiel | [一键移植澎湃脚本](https://www.coolapk.com/feed/71545727?s=MDVjNTk4YjZlNTZiMmFnNmE4MmI1Yzl6a1651) |
| TUSB_5834 | [一加移植澎湃bugs修复教程](https://www.coolapk.com/feed/71466817?s=MTZhNmJhMjNlNTZiMmFnNmE4MmI2ODZ6a1651) |
| 青芜ovo | [黑厂移植澎湃bug修复大全](https://www.coolapk.com/feed/72525211?s=OWZmNjc1ZTZlNTZiMmFnNmE4MmI1Yzl6a1651) |
| 青芜ovo | [欧加移植HyperOS3](https://www.coolapk.com/feed/72977558?s=MmYxOTRiNjVlNTZiMmFnNmE4MmI1Yzl6a1651) |
| 区尼x的 | [第三方机型优雅地开澎湃OS](https://www.coolapk.com/feed/70763978?s=YWRiZmFlZTFlNTZiMmFnNmE4MmI1Yzl6a1651) |
| 区尼x的 | [第三方澎湃OS开机教程](https://www.coolapk.com/feed/71825854?s=OWQyOWNiNTllNTZiMmFnNmE4MmI1Yzl6a1651) |
| 梦想说电脑 | [一加开澎湃修复教程](https://www.coolapk.com/feed/72686563?s=N2JmYTVkY2RlNTZiMmFnNmE4MmI1Yzl6a1651) |
| 默认头像神秘入 | [#ProjectTreble# 黑厂开澎湃保姆级教程，我奶奶看完都会移植了😱](https://www.coolapk.com/feed/72796234?s=ZGY5ZGZkOTBlNTZiMmFnNmE4MmI1Yzl6a1651) |

### 原帖进一步引用的资料

| 作者 | 帖子或资料 |
| --- | --- |
| 荒古圣体迪莫 | [准备0.5w粉了，写个关于怎么补小米账号的图文教程吧](https://www.coolapk.com/feed/66153059?s=OGVhOTE0M2MyMGVjNDE1ZzZhMGFjMmYyega1454&shareUid=34522133&shareFrom=com.coolapk.market_14.5.4) |
| TUSB_5834 | [一加移植澎湃自动亮度修复](https://www.coolapk.com/feed/70984502?s=MWE3ZjcxNGIyMGVjNDE1ZzZhMGFjMmZjega1454&shareUid=34522133&shareFrom=com.coolapk.market_14.5.4) |
| Zephiel | [Android Vendor SELinux 策略合并工具包 / Android Vendor SELinux Policy Merge Toolkit](https://www.coolapk.com/feed/70240015?s=YjZiNGIwYzgxOWEwM2ZjZzY5ZjBjMzU5ega1620) |
| Enmmmmmm | [SELinux audit allow - SELinux 规则生成工具](https://www.coolapk.com/feed/57292580?s=N2ZjN2JjYjAxOWEwM2ZjZzY5ZjBjMzM2ega1620) |
| 东边的何某 | [屏幕分辨率切换添加与修改](https://www.coolapk.com/feed/66835894?s=OTQ5OWJkOTMxOWEwM2ZjZzY5ZjBjNDRlega1620) |
| d2u8_S6h3e | [公开在OS3.0.300使用K70 LyraSdkApp导致信号不定时掉问题](https://www.coolapk.com/feed/69927473?s=YzE3NzAxZDMyMGVjNDE1ZzZhMGFjMjliega1454&shareUid=34522133&shareFrom=com.coolapk.market_14.5.4) |
| d2u8_S6h3e | [公开免去除Lyra（小米互联）修复OS3解锁掉信号方案](https://www.coolapk.com/feed/67009567?s=YTViNWI5OGEyMGVjNDE1ZzZhMGFjMmMwega1454&shareUid=34522133&shareFrom=com.coolapk.market_14.5.4) |
| Enmmmmmm | [如何修改 MIUI / HyperOS 的设备分级](https://www.coolapk.com/feed/68768870?s=OWQ3ZTVkYzAyMGVjNDE1ZzZhMGFjMmQ1ega1454&shareUid=34522133&shareFrom=com.coolapk.market_14.5.4) |
| 秋詞 | [澎湃本地参数仅测试了澎湃3……](https://www.coolapk.com/feed/67021882?s=YWE3N2ZhODcyMGVjNDE1ZzZhMGFjMzEzega1454&shareUid=34522133&shareFrom=com.coolapk.market_14.5.4) |

最后一条动态当前受作者“仅半年内动态可见”设置限制，标题按引用页显示的片段保留，作者根据引用帖正文中对“秋詞的本地参数”的标注整理。

各原帖还明确致谢或注明方案来源于：相见即是缘、已跑路_勿扰、曾晨曦（用户157816783）、江月、孩子i、玫瑰之忆、空白2032、Synecdoche、machruis、AX陳某染、mytiantian_是天天吖、Snownights、閃電Flashh。感谢以上贡献者以及原帖中未能逐一署名的参与者。

## 支持本项目

![微信](donate_wx.png)
![支付宝](donate_alipay.jpg)
