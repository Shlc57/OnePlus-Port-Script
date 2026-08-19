# 移植补丁模块

`port` 目录中的补丁按组织方式和硬件依赖拆分，默认不会自动全部执行。请先确认补丁要求的分区已经解包到工程目录，再根据目标设备显式选择需要的补丁。

目录分类如下：

| 目录 | 适用范围 |
| --- | --- |
| `common/<补丁名>` | 可被不同移植流程组合调用的共享补丁。位于 `common` 不代表对所有设备都适用，应以补丁说明和设备流程为准。 |
| `devices/<机型>/<补丁名>` | 依赖指定设备显示、传感器或硬件配置的专属补丁。不得用于其他机型。 |

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
bash auto_port.sh
bash auto_port.sh list

# 对默认工程目录执行通用补丁
bash auto_port.sh common/fix_launcher common/fix_device_identity

# 使用补丁目录内置的底包 init.usb.configfs.rc 执行 MTP 修复
bash auto_port.sh common/fix_mtp

# 执行一加 15 专属补丁
bash auto_port.sh devices/oneplus15/fix_auto_brightness \
  devices/oneplus15/fix_refresh_rate_switch \
  devices/oneplus15/fix_fingerprint \
  devices/oneplus15/fix_linear_haptic

# 单独执行当前一加 15 流程中位于 common 的兼容性补丁
bash auto_port.sh common/fix_camera_mr common/fix_modem_xts \
  common/fix_mtp common/fix_oplus_fingerprint_protocol

# 统一合并 vendor 来源策略、补丁片段和已确认 AVC 规则；DisplayFeature
# 已安装时会自动带入 common/fix_displayfeature_bridge 的 SELinux 片段
bash auto_port.sh common/fix_vendor_avc

# 对其他工程目录执行指定补丁
bash auto_port.sh --project-dir /path/to/project common/fix_launcher

# 设备标识默认读取 mi_odm/etc/build.prop；可指定同目录下的机型 prop 覆盖
DEVICE_IDENTITY_PROP=nezha_5.9.9.prop bash auto_port.sh common/fix_device_identity

# 一加 15 当前整套流程
bash 1+15_port.sh
```

`apply.sh` 是由 `auto_port.sh` 管理的补丁模块，不应直接执行。`auto_port.sh` 只导入一次 `tools.sh`，再在彼此隔离的子 Shell 中加载各补丁，因此补丁内不再重复 `source tools.sh`，同时不同补丁的严格模式、变量、trap 和 `exit` 不会互相污染。

`tools.sh` 统一管理配置目录、contexts 与 fsconfig 名称模板，只识别工程根目录下的以下两套格式；两者同时存在时优先使用 `DNA_config`：

| 配置目录 | contexts 模板 | fsconfig 模板 |
| --- | --- | --- |
| `DNA_config` | `{part}_contexts.txt` | `{part}_fsconfig.txt` |
| `config` | `{part}_file_contexts` | `{part}_fs_config` |

模板中的 `{part}` 会替换为 `product`、`system` 等分区名。复杂的元数据处理统一由 Python 3 工具 `partition_metadata.py` 完成：补丁条目按路径覆盖目标条目，contexts 会忽略正则转义差异进行匹配，目标文件中的重复路径会在每次修改时自动去重；写回 contexts 时会把有效条目的字段间空白统一为单个 ASCII 空格，避免手机版 D.N.A 旧解析器无法识别 Tab 分隔符。文件清单或目录前缀跨分区迁移时，contexts 与 fsconfig 会一起转换，缺少任一来源权限条目都会在复制文件前失败。传入多个补丁时会按参数顺序执行，任一补丁失败后立即停止；未显式传入的补丁不会运行。推荐使用完整分类路径；为兼容旧用法，也可使用全局唯一的补丁名，例如 `fix_launcher`。

现有补丁中的 prop 子步骤按可选内容处理：属性来源文件、目标 `build.prop`、属性清单或预期属性条目不存在时，会输出 `WARN` 并只跳过对应 prop 子步骤；同一补丁中的 APK、XML、文件迁移和 metadata 等非 prop 主流程仍继续执行。已经存在但格式无效、属性重复、值冲突或使用不安全符号链接的文件仍会报错退出，不会被静默忽略。

明确用于替换或修补既有文件的子步骤也采用相同的缺失处理：目标文件不存在时输出 `WARN`，只跳过该替换；混合补丁中的独立属性写入、文件迁移或其他可执行步骤继续运行。已经存在但类型错误、版本或校验不受支持、内容冲突或使用不安全符号链接的目标仍会失败。本规则不影响本来就要新增的 Overlay、配置、服务文件、跨分区迁移目标、生成产物及 metadata，公共复制接口仍保留创建这些文件的能力。

## 共享补丁（`common`）

| 补丁路径 | 主要输入 | 最终修改分区 | 作用与重要说明 |
| --- | --- | --- | --- |
| `common/fix_vendor_avc` | 【规则依据】当前一加 15 DSU 起点 `dmesg.log`、`logcat.log` 中的 AVC/服务拒绝及 Enforcing 热补丁复测；【原包】`mi_vendor/etc/selinux`；【底包】`vendor/etc/selinux`、`system/system/etc/selinux`、`system_ext/etc/selinux`、`odm/etc/selinux`；【可选片段】已安装 DisplayFeature rc 与 `common/fix_displayfeature_bridge/config/selinux_policy.cil.in` | `vendor`、`odm` metadata | 由 `common/selinux_merge` 统一合并原包 vendor 策略（版本/ABI 不兼容时只导入底包已有类型可承载的 contexts）、本补丁 17 条受控策略语句（16 条基于当前证据的 `allow`、1 条 QSPM client 属性扩展），以及已启用 DisplayFeature 的 3 条精确 allow 和 1 条 client 属性扩展；普通与 debug vendor CIL 使用同一托管块并保持幂等。规则内容不放在通用接口中。原有 AVC 规则、MI-SF/DFPS 的 8 条精确 `vendor_display_prop` context、qguard/BSG 标签和 ODM precompiled metadata 清理保持不变；固化后的完整开机策略仍需下次 DSU 启动复核。 |
| `common/disable_mi_vulkan` | 【原包】`product` | `product` | 注释小米 8 Elite 上可能导致卡首屏的 Vulkan pipeline cache 属性。 |
| `common/disable_odm_imports` | 【底包】`odm` | `odm` | 禁用两份 ODM build.prop 对项目专属及 `my_manifest` build.prop 的外部导入。 |
| `common/enable_hyperos_features` | 【原包】`product`；【底包】`vendor` | `product`、`vendor` | 将教程第四部分的 32 项全局模糊、高级材质、画质、游戏及声效属性统一写入 `product/etc/build.prop`，并向最终 `vendor/build.prop` 写入 `persist.vendor.XDRVersion=2.0`，共 33 项。XDR 属性用于通过小米相册的 `isXdrSupport` 私有能力门控，只适用于底层标准 HDR 已确认正常的设备；本补丁不补充缺失的硬件驱动、媒体算法或 DisplayFeature 能力。当前已由 `1+15_port.sh` 显式纳入一加 15 整套流程。 |
| `common/fix_boot_refresh_rate` | 【原包取材】`mi_odm`、`mi_vendor`；【底包目标】`odm`、`vendor` | `odm`、`vendor` | 从当前小米原包动态提取教程第 6 项对应的显示、刷新率与触控属性（含 MI SurfaceFlinger 的 LTPO 能力标志），写入底包真实分区路径，并补充 `enable_frame_rate_override=false` 与 MI SurfaceFlinger idle timer。不会替换 ODM/vendor 文件树，也不会复制无关音频属性；缺少的来源文件、目标文件或单项属性会警告后跳过，其余可用属性继续处理。该标志只开放 MIUI 上层策略，不补充 Oplus 面板/HWC 的 DynFPS 命令序列；是否实际进入 LTPO 仍以运行时面板状态为准。 |
| `common/fix_camera_mr` | 【原包】`product` | `product` | 将 `product/etc/cust_features/device_features.xml` 中的 `input_support_camera_mr` 和 `cust_features.xml` 中的 `settings_is_support_camera_mr_function` 唯一设为 `false`，避免一加 15 活动识别传感器被误作小米 CameraMR 输入并引发开机窗口焦点初始化崩溃。两份配置必须配套修改；任一目标不存在时警告并跳过本补丁。需要 Python 3；当前为一加 15 兼容性补丁。 |
| `common/fix_face_unlock` | 【原包】`product`、`system_ext`、`mi_vendor`；【目标工作树】`product`、`system_ext`、`vendor` | `product`、`system_ext`、`vendor` | 修改 `product/etc/device_features/nezha.xml`：当 `support_face_unlock_region_dom` 不包含 `ALL` 时，将其中所有 `item` 设为 `ALL`；当 `support_tee_face_unlock` 不为 `true` 时将其设为 `true`。从 `mi_vendor` 迁移 `android.hardware.biometrics.face.xml` 到最终 `vendor` 后，Settings 会走标准 `FaceManager`；补丁会在有效 Surface 上正式启动录入时先进入小米原有 acquired `19` 步骤路径，使相机预览就绪后及时结束加载提示，再将 `remaining>0` 的标准录入进度映射到同一路径，并把五段圆环节奏调整到当前标准回调间隔，只在 `remaining=0` 时进入成功流程。若底层只上报最终回调，仍会跳过无结束监听器的第 0 个圆环，避免模板已保存但录入页停住。人脸特性 XML 或 Settings.apk 缺失时，这两个配套文件子步骤会警告后一起跳过，但硬件特性声明迁移仍继续。无需安装 `PearlBiometric.apk`：已在 nezha DSU 上移除用户 0 的 `com.miui.face`、确认进程与 `miui.face.FaceService` 均不存在后，实测录入、成功页退出和人脸解锁全部正常。Settings 仅替换目标 DEX 并保留其他归档条目、Signing Block 与 META-INF 证书材料，同时清理来源 oat。需要 Apktool、Java、`zipalign`、Python 3 与 `zip`/`unzip`；Settings DEX 改动后 v1/v2/v3 内容完整性签名必然失效，只适用于已确认系统扫描绕过完整性校验的移植环境。当前已由 `1+15_port.sh` 纳入一加 15 整套流程。 |
| `common/fix_device_identity` | 【原包取材】`mi_odm`；【目标工作树】`odm`、`system` | `odm`、`system` | 默认从 `mi_odm/etc/build.prop` 动态读取设备标识与版本属性，写入 `odm/build.prop`、`odm/etc/build.prop`，并同步系统侧品牌、厂商、型号与产品名。设置 `DEVICE_IDENTITY_PROP` 后，优先使用 `mi_odm/etc/<文件名>` 中的同名身份属性，并把该文件的全部有效属性合并到两份目标 ODM build.prop。 |
| `common/fix_launcher` | 【底包】`odm` | `odm` | 写入中国区、系统桌面包名及 APEX 可更新属性。 |
| `common/fix_mtp` | 【补丁内置底包配置】`common/fix_mtp/init.usb.configfs.rc`；【原包目标】`system` | `system` | 使用补丁目录内置的底包 `init.usb.configfs.rc` 替换 `system/system/etc/init/hw/init.usb.configfs.rc`，使 MTP/PTP/ADB configfs 触发器与当前底包 USB 栈保持一致。MTP 内核函数路径仅在 `vendor.usb.use_ffs_mtp=0` 时启用，避免与 vendor rc 的 FunctionFS MTP 路径重复挂接；补丁会校验必要的 MTP 触发器，保留目标文件权限，且不改动 fsconfig/file_contexts；目标 RC 不存在时警告并跳过替换，更换底包时应同步更新内置来源文件。 |
| `common/fix_mi_mtp_kill_self` | 【原包目标】`system` | `system` | 精确修改 `system/system/priv-app/MtpService/MtpService.apk` 的 application 进程名：将与 `DownloadProvider` 共用的 `android.process.media` 改为 `android.process.mtp`。用于规避小米 DownloadProvider 启动期 `BootHelper` 在空闲状态调用 `XCrashlytics.killSelf()` 时杀掉同 PID 的 MTP 服务。补丁只回写二进制 `AndroidManifest.xml`，原样保留其他归档条目、Signing Block 和 META-INF 证书材料，并清理 MtpService 的 oat、profile 及 fs-verity 元数据和对应 contexts/fsconfig；需要 Java、Apktool、Python 3、`zip`/`unzip` 与 Android SDK `zipalign`。Manifest 修改后 v1/v2/v3 内容完整性签名必然失效，仅适用于已确认允许系统包回退加载且绕过完整性校验的移植环境。 |
| `common/fix_nfc` | 【补丁资源】同平台签名的 NXP/Xiaomi `XMNfcNci.apk`；【原包取材】`mi_odm`；【原包目标】`system`；【底包目标】`odm` | `system`、`odm` | 当前系统 `Nfc_st.apk` 只支持 `/dev/st21nfc`，而一加底包实际提供 `/dev/nq-nci` 与 NXP AIDL HAL。补丁在保留既有 `system/system/app/Nfc_st/Nfc_st.apk` 路径及 metadata 的前提下，仅替换 APK 内容，并从 `mi_odm/etc/build.prop` 动态提取五项 Xiaomi NFC 功能开关写入 `odm/etc/build.prop`；prop 来源、目标或单项属性缺失时只警告并跳过属性写入，不影响 APK 主流程，反之目标 NFC APK 缺失时也只跳过 APK 替换并继续可用的属性写入。执行 APK 子步骤前校验原 ST APK、内置 APK、NXP HAL manifest 及所需 framework；不替换底包 HAL、固件或射频配置，也不携带与目标系统 boot image 绑定的 oat。内置包 versionCode 为 36，原 ST 包为 37，但两者平台签名证书一致；已在一加 15 DSU 上通过 framework 重扫并验证 NFC 设置、NXP HAL 初始化、实体卡识别和 Tag Intent 分发。 |
| `common/fix_displayfeature_bridge` | 【原包取材】`mi_vendor`；【底包目标】`odm`、`vendor`；【补丁资源】轻量 DisplayFeature HAL | `odm`、`vendor` | 保留 Xiaomi AIDL DisplayFeature 服务与接口库，用轻量 legacy HAL 桥替换完整 Xiaomi 显示 HAL，并将小米自适应、鲜艳、原色模式分别映射到底包 QDCM 的 `DefaultSRGB`、`EnhanceSRGB`、`StandardSRGB` RenderIntent。基础模式请求携带的 `value=1/2/3` 会同步映射为暖色、中性、冷色 RGB/PCC，并与独立色温及护眼 PCC 合成后交给 SurfaceFlinger；纸张纹理及其他未映射特性仍明确返回不支持。桥复用底包 `libqservice.so`、`libsdmclient.so`、`libsdm-disp-vndapis.so` 和 QTI Display Color SELinux 域；补丁只验证底包已有的 Display Color 能力，并把版本化 `system_server`、servicemanager 回调 HAL 及桥访问 SurfaceFlinger 的 4 条规则登记到本补丁片段，最终由 `common/fix_vendor_avc` 统一合并普通及 debug vendor CIL。补丁还会迁移清单文件的 contexts/fsconfig，显式补齐桥库 `0644` 权限，移除 rc 中不存在的 Xiaomi sysfs 与 `/vendor/bin/displayfeature` 引用，且在底包缺少所需显示栈、面板调色数据或策略权限时于修改前失败。桥库已在一加 15 DSU 上通过 tmpfs 热替换验证三档 RGB/PCC 与 RenderIntent 切换；上层权限链已用 KSU 临时规则在 Enforcing 下验证，固化 CIL 仍需下次启动确认。 |
| `common/fake_device_params` | 【原包】`system`，存在 userdebug plat policy 时同时处理 `system_ext`；环境变量 `DEVICE_PARAMS_SPOOF_JSON`，可选 `DEVICE_PARAMS_SPOOF_JSON_ENUS` | `system`、可选 `system_ext` | 把 `devInfoNew` 与 `allparamInfo` 的完整伪装响应生成到 Settings 的 `device_params_pref` 缓存模板，并定义最小化的 `fake_device_params` SELinux 域。开机后 init 以 `system:system` 启动专用脚本，只允许读取 system 模板和写 `system_app_data_file`，不依赖 Magisk、KSU、`su`、adbd 或其他固定 root 域。可选 enUS 模板会在系统语言为 en-US 时自动选用，语言变更后也会重新同步缓存。支持处理器、电池、相机、屏幕、分辨率、安全芯片及 `Mishop`/扩展 JSON 字段；启用基础参数卡片时会自动插入索引 5，让 Settings 本地检测并展示真实运行内存。补丁不修改 `Build.MODEL`、`ro.product.*` 或其他 prop，也不替换 HTMLViewer.apk。需要 Python 3。 |
| `common/fix_mi_account` | 【原包取材】`mi_odm`、`mi_vendor`；【目标工作树】`odm`、`vendor` | `odm`、`vendor` | 按清单从小米原包动态提取账号、支付及安全环境资源，并把源 contexts 与 fsconfig 转换为真实目标路径。缺少来源目录、文件、contexts 或 fsconfig 权限条目时在修改前失败，不回退到补丁内二进制载荷。DisplayFeature 显示链由独立桥补丁处理。 |
| `common/fix_modem_xts` | 【原包】`system` | `system` | 保留小米 `qcrilmsgtunnel` 的短信接收链路，精准修改 `TeleService.apk` 目标 DEX：跳过 `XtsApp` 不兼容的一加 modem 版本查询、固定报告 XTS 不受支持，并短路 `MiRilHook.onHookNotifyScreenStatusSync` 发送的小米 `0x802AA/0x1B` 屏幕状态 OEM 命令，避免电话线程每次亮灭屏阻塞 5 秒及 `QcrilOemhookMsgTunnel` 长时间持有 wakelock。`TeleService.apk` 不存在时警告并跳过。需要 Java、Apktool、Python 3、`zip`/`unzip` 与 Android SDK `zipalign`；仅替换目标 DEX，原样保留其他 APK 条目、Signing Block 与 `META-INF` 证书材料，并同步清理已删除 oat 目录的 contexts/fsconfig，但 DEX 改动后内容完整性签名必然失效。当前为一加 15 兼容性补丁，只适用于已确认系统扫描允许该产物的移植环境。 |
| `common/fix_oplus_fingerprint_protocol` | 【原包】`system_ext` | `system_ext` | 精准修改 `MiuiSystemUI.apk` 的 `MiuiGxzwIconView.onTouch` 与 `miui-services.jar` 的 `FingerprintServiceStubImpl` 所在 DEX，为明确设置 `persist.vendor.sys.fp.vendor=oplus` 的锁屏认证补齐 Oplus HAL 缺失的小米 FOD 触摸协议。SystemUI 直接消费 `gxzw_touch` 窗口收到的原始 `ACTION_DOWN/UP/CANCEL`，使 `fod_animation_enabled=1` 时能在 HAL 认证结果到达前启动识别动画；服务端仍在首次 `ACQUIRED_GOOD(0,0)` 合成 acquired `100` 作为按下兜底，并在认证成功、失败、HAL 错误或下一会话开始时合成 acquired `101` 释放状态。认证成功若撞上 `goingToSleep`，服务端会先以 `android.policy:OPLUS_FOD` 主动唤醒，再保留原轮询确认，避免成功结果被 SystemUI 吞掉。非 Oplus 属性不受影响。两部分已在一加 15 root DSU 热加载实机验证：亮屏锁屏按压先命中 `OPLUS_FOD_RAW_TOUCH_DOWN` 并执行 `startRecognizingAnim`，设置开关恢复生效；服务端稳定上报 acquired `100/101`，息屏竞态还可命中主动唤醒。息屏状态沿用系统自身的图标/解锁表现，不额外强制显示完整识别动画。补丁只替换两个目标 DEX，保留其他 JAR/APK 条目、APK Signing Block 与 `META-INF` 证书材料，重复执行会安全跳过；两者必须成对更新，任一目标不存在时警告并整体跳过，避免只写入半套协议；同时清理两者不匹配的 profile、FS-Verity 元数据和预编译产物及其 contexts/fsconfig。需要 Java、Apktool、Python 3、`zip`/`unzip` 与 Android SDK `zipalign`；DEX 修改后内容完整性与预编译产物必然失效，只适用于已确认可从 DEX 回退加载且允许系统包内容变化的移植环境。当前已由 `1+15_port.sh` 纳入一加 15 整套流程。 |
| `common/fix_pangu` | 【原包】`product`、`system` | `product`、`system` | 将 `product/pangu/system` 合并到 system，同步转换 contexts/fsconfig 并从 product 元数据移除源路径；成功后删除源目录。 |
| `common/fix_settings_haptic` | 【原包】`system_ext` | `system_ext` | 通过共享的 `common/settings_apk_patcher.sh` 修改 Settings，使设置界面触感能力判定返回支持；`Settings.apk` 不存在时警告并跳过。需要 Apktool、Java、`zipalign`、Python 3、`zip`/`unzip`；可分别用 `APKTOOL_JAR`、`ZIPALIGN` 指定工具。补丁只将目标 DEX 写回原 APK，原样保留其他归档条目、Signing Block 与 META-INF 证书材料，并同步清理已删除 oat 目录的 contexts/fsconfig；DEX 改动后 v1/v2/v3 内容完整性签名必然失效，只适用于已确认系统扫描绕过完整性校验的 ROM。 |
| `common/fix_wechat_safe_mode` | 【底包】`odm` | `odm` | 移除假的 Camera Extensions 实现，并同步删除对应 contexts/fsconfig 条目，修复微信安全模式问题。 |
| `common/merge_mi_ext` | 【原包】`mi_ext`、`product`、`system_ext`、`system` | `product`、`system_ext`、`system` | 将 mi_ext 中的 product、system_ext、system 与 etc 内容合并到真实目标路径，并迁移 contexts、fsconfig 和属性；同时迁移 CustFeatureResolve 启用属性，建立 `/mi_ext/product -> /product` 兼容路径；成功后删除 `mi_ext` 源目录。 |

### Settings 设备参数伪装补丁

`common/fake_device_params` 只生成 Settings 原生读取的两个缓存值：`basic_info_key` 与 `camera_info_key`。缓存语言同时写入 `device_params_last_lang`，更新时间固定到 2100 年，使当前语言下不再触发 8 小时云端刷新。补丁不修改任何 prop，也不需要破坏 HTMLViewer.apk 的接口地址或签名。

默认参数通过 `DEVICE_PARAMS_SPOOF_JSON` 传入。`basic` 是 `devInfoNew` 的完整响应对象，`camera` 是 `allparamInfo` 的完整响应对象；补丁会保留其中未识别的扩展字段，并校验 Settings 实际使用的字段：

```bash
DEVICE_PARAMS_SPOOF_JSON='{
  "language": "zhCN",
  "basic": {
    "Mishop": {
      "RightValue": "",
      "ShowRedDot": "false",
      "Url": ""
    },
    "BasicInfoToggle": 1,
    "BasicItems": [
      {"Title": "处理器", "Summary": "第一代骁龙®8+移动平台", "Index": 0},
      {"Title": "电池容量", "Summary": "4800mAh(典型值)", "Index": 1},
      {"Title": "后置摄像头", "Summary": "50MP+8MP+2MP", "Index": 2},
      {"Title": "屏幕尺寸", "Summary": "6.7″", "Index": 3},
      {"Title": "分辨率", "Summary": "2412×1080", "Index": 4},
      {"Title": "安全芯片", "Summary": "独立安全芯片", "Index": 7}
    ]
  },
  "camera": {
    "status": true,
    "data": {
      "BasicInfoToggle": 1,
      "camera": {
        "front_camera": "16MP",
        "rear_camera": "50MP+8MP+2MP"
      }
    }
  }
}' bash auto_port.sh common/fake_device_params
```

`language` 必须与目标系统当前 `Locale.getLanguage()+Locale.getCountry()` 一致，例如简体中文为 `zhCN`、美式英语为 `enUS`。如需同时提供英文模板，可额外设置 `DEVICE_PARAMS_SPOOF_JSON_ENUS`，其 `language` 必须严格为 `enUS`；运行时在 `persist.sys.locale=en-US` 时自动选择该模板，其他语言仍回退到默认模板。`BasicItems[].Index` 当前只允许 `0`、`1`、`2`、`3`、`4`、`7`，且不能重复；分别对应处理器、电池、相机、屏幕尺寸、分辨率和安全芯片。启用 `BasicInfoToggle=1` 时，补丁会自动追加空的索引 `5` 占位项，触发 Settings 以本机硬件自动检测运行内存；用户无需、也不能在 JSON 中填写该项。型号（索引 `6`）仍由 Settings 在本地生成，不能由接口缓存覆盖。

补丁生成以下 system 文件，并同步写入 system contexts/fsconfig：

```text
system/system/etc/device_params/device_params_pref.xml
system/system/etc/device_params/device_params_pref.enUS.xml（设置 `DEVICE_PARAMS_SPOOF_JSON_ENUS` 时）
system/system/etc/device_params/fake_device_params.sh
system/system/etc/init/fake_device_params.rc
```

补丁还会以固定边界标记管理专用域规则，并动态定位当前平台限制 native domain 写 `system_app_data_file` 的 neverallow 属性，只把 `fake_device_params` 加入该属性的例外集合，不依赖会随版本变化的 `base_typeattr_*` 编号。规则始终写入 `system/system/etc/selinux/plat_sepolicy.cil`；如果存在 `system_ext/etc/selinux/userdebug_plat_sepolicy.cil`，也会同步补丁，确保解锁设备设置 `INIT_FORCE_DEBUGGABLE=true` 后选择 userdebug policy 时仍包含该域。`plat_file_contexts` 会把脚本标记为 `fake_device_params_exec`，并更新 `plat_sepolicy_and_mapping.sha256` 标记，使 init 放弃旧的 normal/debug `precompiled_sepolicy`、按当前 split CIL 重新编译策略。脚本 metadata 权限为 `0755`。

开机完成后，以及 `persist.sys.locale` 发生变更时，oneshot 服务由 init 自动转换到 `u:r:fake_device_params:s0`，并以 Android `system` UID/GID 运行。策略只额外允许该域读取 system 模板、执行 shell/toybox，以及访问 `system_app_data_file`；不授予 root UID、DAC 绕过或任意 root 管理器域权限。脚本等待 `/data/user_de/0/com.android.settings` 由 installd 创建，再在目标目录内原子替换 `shared_prefs/device_params_pref.xml`。新文件天然由 `system` 用户创建并继承 `system_app_data_file`，因此不需要 `chown` 或 `restorecon`。当前只处理 user 0；修改参数后应重新执行补丁并重启。运行时缓存格式及专用域权限已在一加 15 DSU 上通过临时加载候选策略、UID/GID 1000 和短时 Enforcing 写入验证；init 从 rc 自动完成开机转换仍需在下一次 DSU 启动后确认。

### HyperOS 特性属性补丁

`common/enable_hyperos_features` 将教程末尾第四部分中粘连的属性还原为 32 个独立条目并写入 `product/etc/build.prop`，同时向 `vendor/build.prop` 写入 1 项小米相册 XDR 能力属性，共 33 项。重复执行会更新同名属性并移除两份目标文件内的重复定义，不修改 `system` 或 `system_ext` 分区；任一目标文件不存在时会警告并独立跳过该分区，另一分区仍可继续处理。

| 分类 | 目标文件 | 属性及目标值 |
| --- | --- | --- |
| 全局模糊 | `product/etc/build.prop` | `ro.config.low_ram.threshold_gb=`<br>`ro.config.low_ram.middle.threshold_gb=`<br>`ro.miui.backdrop_sampling_enabled=true`<br>`ro.config.low_ram.support_miuilite_plus=false`<br>`persist.sys.background_blur_supported=true` |
| 高级材质与转场 | `product/etc/build.prop` | `persist.sys.background_blur_status_default=false`<br>`persist.sys.background_blur_mode=0`<br>`ro.surface_flinger.supports_background_blur=1`<br>`ro.launcher.blur.appLaunch=1`<br>`ro.sf.blurs_are_expensive=0`<br>`persist.sys.add_blurnoise_supported=true`<br>`persist.sys.hyper_transition=true`<br>`persist.sys.hyper_transition_v=2`<br>`persist.sys.element_transition_supported=true`<br>`ro.miui.shell_anim_enable_fcb=true` |
| 画质增强 | `product/etc/build.prop` | `debug.config.media.video.frc.support=true`<br>`debug.config.media.video.ais.support=true`<br>`debug.config.media.video.aie.support=true`<br>`persist.sys.support_ultra_hdr=true` |
| 相册 Ultra HDR | `vendor/build.prop` | `persist.vendor.XDRVersion=2.0` |
| 游戏视频与性能 | `product/etc/build.prop` | `debug.game.video.support=true`<br>`debug.game.video.speed=true`<br>`debug.performance.tuning=1`<br>`video.accelerate.hw=1` |
| 空间音频与声效 | `product/etc/build.prop` | `ro.vendor.audio.surround.headphone.only=false`<br>`ro.vendor.audio.videobox.switch=true`<br>`ro.vendor.audio.feature.spatial=7`<br>`ro.vendor.audio.game.effect=true`<br>`ro.vendor.audio.sfx.earadj=true`<br>`ro.vendor.audio.sfx.scenario=true`<br>`ro.vendor.audio.sfx.harmankardon=true`<br>`ro.vendor.audio.surround.support=true`<br>`ro.vendor.audio.scenario.support=true` |

原教程没有给出 `ro.config.low_ram.threshold_gb` 与 `ro.config.low_ram.middle.threshold_gb` 的数值，因此补丁保留为空值，不猜测设备阈值。

这些属性主要用于能力声明和功能入口判断。HyperOS 版本、SoC、显示栈或音频 HAL 不支持时，对应功能可能不生效；尤其是画质算法和空间音频，不能仅靠属性补齐底层实现。`persist.vendor.XDRVersion=2.0` 只解除小米相册的私有 XDR 门控，不会创建 HDR 显示能力；应先确认第三方应用能够正常显示 HDR。一加 15 已通过临时 `setprop` 实机验证相册恢复 Ultra HDR。当前 `1+15_port.sh` 已显式调用本补丁；其他设备流程应先评估硬件支持，如需单独执行：

```bash
bash auto_port.sh common/enable_hyperos_features
```

## 一加 15 设备补丁（`devices/oneplus15`）

| 补丁路径 | 主要输入 | 最终修改分区 | 作用与重要说明 |
| --- | --- | --- | --- |
| `devices/oneplus15/fix_auto_brightness` | 【底包】`odm`、`vendor`；【原包】`product` | `odm`、`product` | 禁用一加 15 高 PWM RGB 传感器属性，把底包 vendor 显示配置补入原包 product，并用最大配置适配实机 Display ID `4630946903293830803`。补丁同步写入这些显示配置和启动 Overlay 的 product contexts/fsconfig 权限。保留 `1..1060` 的小米逻辑 nit 上限，从真机 P3 表扩展高段：普通/HBM 分界为 1400 nit，HBM 末端为 1800 nit；当前预编译 `MiuiFrameworkResOverlay.apk` 的 `config_defaultLogicalCurve` 为 `0→2、30→40、600→70、5000→1060`，仅校准环境光到逻辑 nit 的室内映射，不把物理 P3 nit 写入逻辑坐标。`test_hot_reload.sh` 可在已授权 DSU 上先通过私有 mount namespace 生成候选 idmap，再原子替换 resource-cache 中的 idmap，最后挂载测试 Overlay 并重启 framework；不得删除既有 idmap，否则 zygote 会因继承到失效文件描述符而循环崩溃。另加入只覆盖 `config_screenBrightnessSettingDefaultFloat` 的 135 nit 启动亮度 Overlay。写入曲线 Overlay 前会调用 Android SDK `zipalign` 检查 4 字节边界；若预编译 APK 未对齐，先生成并复验临时对齐副本，避免 PackageManager 解析 `resources.arsc` 时导致 system_server 启动循环。曲线 Overlay 是预编译资源 APK，已移除原签名材料；仅适用于已确认移植系统允许该 Overlay 重新生成并绕过原包完整性校验的环境。该对齐修复已在一加 15 DSU 上确认正常完成开机。 |
| `devices/oneplus15/fix_refresh_rate_switch` | 【底包】`odm`；【原包】`product`、`system_ext` | `product`、`system_ext` | 按当前设备代号修改 `product/etc/device_features/<device>.xml`：最高智能刷新率设为 165Hz，刷新率列表设为 165/144/120/90/60Hz；从底包 `odm/etc/sdm_display_resolution_extn.xml` 动态读取 `PanelResolution width` 和 `ScalingResolution w` 生成 `screen_resolution_supported`。同时复用 `common/settings_apk_patcher.sh` 修正旧 `ScreenResolutionManager.calculateHeightFromWidth()`：优先从 `Display.getSupportedModes()` 返回目标宽度对应的真实高度，找不到时才按比例并用 `Math.round()` 回退；当前一加 15 的 1080 宽模式因此使用 2354 高度，不再自动截断为 2353。机型 XML 与 Settings.apk 任一缺失时只警告并跳过对应子步骤，另一项仍可继续。需要 Apktool、Java、Python 3、`zip`/`unzip` 与 Android SDK `zipalign`；Settings 仅替换目标 DEX 并保留其他归档条目、Signing Block 与 META-INF 证书材料，同时清理 oat 目录及其 contexts/fsconfig，但 DEX 修改后内容完整性签名必然失效。 |
| `devices/oneplus15/fix_fingerprint` | 【底包】`odm` | `odm` | 向 `odm/build.prop` 写入超声波屏下指纹能力、`persist.vendor.sys.fp.vendor=oplus` 协议选择、位置、尺寸、识别区域与按下延迟属性；协议属性由 `common/fix_oplus_fingerprint_protocol` 使用。以一加 15 实机 HAL 报告的原生面板 `1272x2772`、传感器中心 `636,2048` 和图标尺寸 `195` 为基准，并按底包 `sdm_display_resolution_extn.xml` 中唯一的原生 `PanelResolution` 分别缩放 X/Y；超声波识别区保持一加 13 示例相对图标的扩大比例。当前配置会得到图标 `539,1951`、尺寸 `195,195`、识别区域 `526,1927,746,2169`。需要 Python 3。 |
| `devices/oneplus15/fix_linear_haptic` | 【原包取材】`mi_odm`；【底包目标】`odm` | `odm` | 从小米原包动态提取 `sys.haptic.*` 触感映射并合并到最终 ODM，但删除静态的 `sys.haptic.motor` 与 `sys.haptic.version`；在底包震动服务 RC 中按教程于 `sys.boot_completed=1` 后设置 `sys.haptic.motor=linear`。保留一加 15 原有 AWINIC/RichTap HAL 与效果资源；属性编号和实际震感是否完全匹配仍需刷机后验证。 |

启用补丁前应根据目标机型和底包确认其适用性。重复教程只保留一个对应补丁，不适用的补丁不要传给 `auto_port.sh`。设备专属补丁必须通过对应机型流程调用，不得混用。`1+15_port.sh` 会按固定顺序组合 `common` 与 `devices/oneplus15` 模块；不要仅根据本节表格推断整套流程。


## 鸣谢

本仓库的移植思路、问题定位和补丁实现参考了以下公开资料。感谢各位作者与贡献者分享经验；鸣谢不代表原样采用帖子中的全部做法，实际行为仍以当前仓库实现为准。对于没有独立标题的动态，下表采用正文开头的主题句作为名称。

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
