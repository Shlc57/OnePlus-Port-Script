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
bash auto_port.sh common/fix_camera_mr common/fix_modem_xts common/fix_mtp

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
| `DNA_config` | `{part}_file_contexts` | `{part}_fsconfig.txt` |
| `config` | `{part}_contexts.txt` | `{part}_fs_config` |

模板中的 `{part}` 会替换为 `product`、`system` 等分区名。复杂的元数据处理统一由 Python 3 工具 `partition_metadata.py` 完成：补丁条目按路径覆盖目标条目，contexts 会忽略正则转义差异进行匹配，目标文件中的重复路径会在每次修改时自动去重。文件清单或目录前缀跨分区迁移时，contexts 与 fsconfig 会一起转换，缺少任一来源权限条目都会在复制文件前失败。传入多个补丁时会按参数顺序执行，任一补丁失败后立即停止；未显式传入的补丁不会运行。推荐使用完整分类路径；为兼容旧用法，也可使用全局唯一的补丁名，例如 `fix_launcher`。

## 共享补丁（`common`）

| 补丁路径 | 必须已解包的输入 | 最终修改分区 | 作用与重要说明 |
| --- | --- | --- | --- |
| `common/disable_mi_vulkan` | 【原包】`product` | `product` | 注释小米 8 Elite 上可能导致卡首屏的 Vulkan pipeline cache 属性。 |
| `common/disable_odm_imports` | 【底包】`odm` | `odm` | 禁用两份 ODM build.prop 对项目专属及 `my_manifest` build.prop 的外部导入。 |
| `common/enable_hyperos_features` | 【原包】`product` | `product` | 将教程第四部分的 32 项全局模糊、高级材质、画质、游戏及声效属性统一写入 `product/etc/build.prop`。只写入功能开关，不补充缺失的硬件驱动、媒体算法或音频实现；当前已由 `1+15_port.sh` 显式纳入一加 15 整套流程。 |
| `common/fix_boot_refresh_rate` | 【原包取材】`mi_odm`、`mi_vendor`；【底包目标】`odm`、`vendor` | `odm`、`vendor` | 从当前小米原包动态提取教程第 6 项对应的显示、刷新率与触控属性，写入底包真实分区路径，并补充 `enable_frame_rate_override=false` 与 MI SurfaceFlinger idle timer。不会替换 ODM/vendor 文件树，也不会复制无关音频属性；任一必需来源属性缺失时在修改前失败。 |
| `common/fix_camera_mr` | 【原包】`product` | `product` | 将 `product/etc/cust_features/device_features.xml` 中的 `input_support_camera_mr` 和 `cust_features.xml` 中的 `settings_is_support_camera_mr_function` 唯一设为 `false`，避免一加 15 活动识别传感器被误作小米 CameraMR 输入并引发开机窗口焦点初始化崩溃。需要 Python 3；当前为一加 15 兼容性补丁。 |
| `common/fix_device_identity` | 【原包取材】`mi_odm`；【目标工作树】`odm`、`system` | `odm`、`system` | 默认从 `mi_odm/etc/build.prop` 动态读取设备标识与版本属性，写入 `odm/build.prop`、`odm/etc/build.prop`，并同步系统侧品牌、厂商、型号与产品名。设置 `DEVICE_IDENTITY_PROP` 后，优先使用 `mi_odm/etc/<文件名>` 中的同名身份属性，并把该文件的全部有效属性合并到两份目标 ODM build.prop。 |
| `common/fix_launcher` | 【底包】`odm` | `odm` | 写入中国区、系统桌面包名及 APEX 可更新属性。 |
| `common/fix_mtp` | 【补丁内置底包配置】`common/fix_mtp/init.usb.configfs.rc`；【原包目标】`system` | `system` | 使用补丁目录内置的底包 `init.usb.configfs.rc` 替换 `system/system/etc/init/hw/init.usb.configfs.rc`，使 MTP/PTP/ADB configfs 触发器与当前底包 USB 栈保持一致。补丁会校验必要的 MTP 触发器，保留目标文件权限，且不改动 fsconfig/file_contexts；更换底包时应同步更新该内置文件。 |
| `common/fix_nfc` | 【原包取材】`mi_odm`；【底包目标】`odm` | `odm` | 从 `mi_odm/etc/build.prop` 动态提取 `repair`、`wallet_fusion`、`secure_display_optim`、`mitouch`、`phonecase` 五项 Xiaomi NFC 功能开关并写入 `odm/etc/build.prop`。任一来源属性缺失、重复或值为空时在修改前失败；不替换底包 NFC HAL、固件或射频配置。 |
| `common/fix_displayfeature_bridge` | 【原包取材】`mi_vendor`；【底包目标】`odm`、`vendor`；【补丁资源】轻量 DisplayFeature HAL | `odm`、`vendor` | 保留 Xiaomi AIDL DisplayFeature 服务与接口库，用轻量 legacy HAL 桥替换完整 Xiaomi 显示 HAL，并将小米自适应、鲜艳、原色模式分别映射到底包 QDCM 的 `DefaultSRGB`、`EnhanceSRGB`、`StandardSRGB` RenderIntent。桥复用底包 `libqservice.so`、`libsdmclient.so`、`libsdm-disp-vndapis.so` 和 QTI Display Color SELinux 域；当前只映射三种基础色彩模式，色温等级及其他 DisplayFeature 特性不会伪装为已支持。补丁会同步迁移清单文件的 contexts/fsconfig，显式补齐桥库 `0644` 权限，移除 rc 中不存在的 Xiaomi sysfs 与 `/vendor/bin/displayfeature` 引用，且在底包缺少所需显示栈、面板调色数据或策略权限时于修改前失败。 |
| `common/fix_mi_account` | 【原包取材】`mi_odm`、`mi_vendor`；【目标工作树】`odm`、`vendor` | `odm`、`vendor` | 按清单从小米原包动态提取账号、支付及安全环境资源，并把源 contexts 与 fsconfig 转换为真实目标路径。缺少来源目录、文件、contexts 或 fsconfig 权限条目时在修改前失败，不回退到补丁内二进制载荷。DisplayFeature 显示链由独立桥补丁处理。 |
| `common/fix_modem_xts` | 【原包】`system` | `system` | 保留小米 `qcrilmsgtunnel` 的短信接收链路，精准修改 `TeleService.apk` 中 `com.android.phone.XtsApp` 所在 DEX：跳过不兼容的一加 modem 版本查询，并固定报告 XTS 不受支持，避免电话主线程 OEM Hook 超时和循环 ANR。需要 Java、Apktool、Python 3、`zip`/`unzip` 与 Android SDK `zipalign`；仅替换目标 DEX，原样保留其他 APK 条目、Signing Block 与 `META-INF` 证书材料，并同步清理已删除 oat 目录的 contexts/fsconfig，但 DEX 改动后内容完整性签名必然失效。当前为一加 15 兼容性补丁，只适用于已确认系统扫描允许该产物的移植环境。 |
| `common/fix_pangu` | 【原包】`product`、`system` | `product`、`system` | 将 `product/pangu/system` 合并到 system，同步转换 contexts/fsconfig 并从 product 元数据移除源路径；成功后删除源目录。 |
| `common/fix_settings_haptic` | 【原包】`system_ext` | `system_ext` | 修改 Settings，使设置界面触感能力判定返回支持。需要 Apktool、Java、`zipalign`、Python 3、`zip`/`unzip`；可分别用 `APKTOOL_JAR`、`ZIPALIGN` 指定工具。补丁会原样保留 Signing Block 与 META-INF 证书材料，并同步清理已删除 oat 目录的 contexts/fsconfig，但 DEX 改动后 v1/v2/v3 内容完整性签名必然失效，只适用于已确认系统扫描绕过完整性校验的 ROM。 |
| `common/fix_wechat_safe_mode` | 【底包】`odm` | `odm` | 移除假的 Camera Extensions 实现，并同步删除对应 contexts/fsconfig 条目，修复微信安全模式问题。 |
| `common/merge_mi_ext` | 【原包】`mi_ext`、`product`、`system_ext`、`system` | `product`、`system_ext`、`system` | 将 mi_ext 中的 product、system_ext、system 与 etc 内容合并到真实目标路径，并迁移 contexts、fsconfig 和属性；同时迁移 CustFeatureResolve 启用属性，建立 `/mi_ext/product -> /product` 兼容路径；成功后删除 `mi_ext` 源目录。 |

### HyperOS 特性属性补丁

`common/enable_hyperos_features` 将教程末尾第四部分中粘连的属性还原为 32 个独立条目，并统一写入 `product/etc/build.prop`。重复执行会更新同名属性并移除目标文件内的重复定义，不修改 `system`、`system_ext` 或 `vendor` 分区。

| 分类 | 目标文件 | 属性及目标值 |
| --- | --- | --- |
| 全局模糊 | `product/etc/build.prop` | `ro.config.low_ram.threshold_gb=`<br>`ro.config.low_ram.middle.threshold_gb=`<br>`ro.miui.backdrop_sampling_enabled=true`<br>`ro.config.low_ram.support_miuilite_plus=false`<br>`persist.sys.background_blur_supported=true` |
| 高级材质与转场 | `product/etc/build.prop` | `persist.sys.background_blur_status_default=false`<br>`persist.sys.background_blur_mode=0`<br>`ro.surface_flinger.supports_background_blur=1`<br>`ro.launcher.blur.appLaunch=1`<br>`ro.sf.blurs_are_expensive=0`<br>`persist.sys.add_blurnoise_supported=true`<br>`persist.sys.hyper_transition=true`<br>`persist.sys.hyper_transition_v=2`<br>`persist.sys.element_transition_supported=true`<br>`ro.miui.shell_anim_enable_fcb=true` |
| 画质增强 | `product/etc/build.prop` | `debug.config.media.video.frc.support=true`<br>`debug.config.media.video.ais.support=true`<br>`debug.config.media.video.aie.support=true`<br>`persist.sys.support_ultra_hdr=true` |
| 游戏视频与性能 | `product/etc/build.prop` | `debug.game.video.support=true`<br>`debug.game.video.speed=true`<br>`debug.performance.tuning=1`<br>`video.accelerate.hw=1` |
| 空间音频与声效 | `product/etc/build.prop` | `ro.vendor.audio.surround.headphone.only=false`<br>`ro.vendor.audio.videobox.switch=true`<br>`ro.vendor.audio.feature.spatial=7`<br>`ro.vendor.audio.game.effect=true`<br>`ro.vendor.audio.sfx.earadj=true`<br>`ro.vendor.audio.sfx.scenario=true`<br>`ro.vendor.audio.sfx.harmankardon=true`<br>`ro.vendor.audio.surround.support=true`<br>`ro.vendor.audio.scenario.support=true` |

原教程没有给出 `ro.config.low_ram.threshold_gb` 与 `ro.config.low_ram.middle.threshold_gb` 的数值，因此补丁保留为空值，不猜测设备阈值。

这些属性主要用于能力声明和功能入口判断。HyperOS 版本、SoC、显示栈或音频 HAL 不支持时，对应功能可能不生效；尤其是画质算法和空间音频，不能仅靠属性补齐底层实现。当前 `1+15_port.sh` 已显式调用本补丁；其他设备流程应先评估硬件支持，如需单独执行：

```bash
bash auto_port.sh common/enable_hyperos_features
```

## 一加 15 设备补丁（`devices/oneplus15`）

| 补丁路径 | 必须已解包的输入 | 最终修改分区 | 作用与重要说明 |
| --- | --- | --- | --- |
| `devices/oneplus15/fix_auto_brightness` | 【底包】`odm`、`vendor`；【原包】`product` | `odm`、`product` | 禁用一加 15 高 PWM RGB 传感器属性，把底包 vendor 显示配置补入原包 product，并用最大配置适配实机 Display ID `4630946903293830803`。补丁同步写入这些显示配置和启动 Overlay 的 product contexts/fsconfig 权限。保留原版低中亮度曲线，从真机 P3 表扩展高段：普通/HBM 分界为 1400 nit，HBM 末端为 1800 nit；保留两份原厂亮度 Overlay，并额外加入只覆盖 `config_screenBrightnessSettingDefaultFloat` 的 135 nit 启动亮度 Overlay，不改动自动亮度曲线及 HyperOS 原生策略。 |
| `devices/oneplus15/fix_refresh_rate_switch` | 【底包】`odm`；【原包】`product` | `product` | 按当前设备代号修改 `product/etc/device_features/<device>.xml`：最高智能刷新率设为 165Hz，刷新率列表设为 165/144/120/90/60Hz；从底包 `odm/etc/sdm_display_resolution_extn.xml` 动态读取 `PanelResolution width` 和 `ScalingResolution w` 生成 `screen_resolution_supported`。当前一加 15 配置会得到 `1272/1080`，不写死教程中的 `3000/2120`。需要 Python 3。 |
| `devices/oneplus15/fix_fingerprint` | 【底包】`odm` | `odm` | 向 `odm/build.prop` 写入超声波屏下指纹能力、厂商、位置、尺寸、识别区域与按下延迟属性。以一加 15 实机 HAL 报告的原生面板 `1272x2772`、传感器中心 `636,2048` 和图标尺寸 `195` 为基准，并按底包 `sdm_display_resolution_extn.xml` 中唯一的原生 `PanelResolution` 分别缩放 X/Y；超声波识别区保持一加 13 示例相对图标的扩大比例。当前配置会得到图标 `539,1951`、尺寸 `195,195`、识别区域 `526,1927,746,2169`。需要 Python 3。 |
| `devices/oneplus15/fix_linear_haptic` | 【原包取材】`mi_odm`；【底包目标】`odm` | `odm` | 从小米原包动态提取 `sys.haptic.*` 触感映射并合并到最终 ODM，但删除静态的 `sys.haptic.motor` 与 `sys.haptic.version`；在底包震动服务 RC 中按教程于 `sys.boot_completed=1` 后设置 `sys.haptic.motor=linear`。保留一加 15 原有 AWINIC/RichTap HAL 与效果资源；属性编号和实际震感是否完全匹配仍需刷机后验证。 |

启用补丁前应根据目标机型和底包确认其适用性。重复教程只保留一个对应补丁，不适用的补丁不要传给 `auto_port.sh`。设备专属补丁必须通过对应机型流程调用，不得混用。`1+15_port.sh` 会按固定顺序组合 `common` 与 `devices/oneplus15` 模块；不要仅根据本节表格推断整套流程。


## 鸣谢

- TODO
