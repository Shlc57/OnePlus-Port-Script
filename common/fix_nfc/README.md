# 适配 NXP NFC 系统应用

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system` | 以同平台签名的 NXP/Xiaomi APK 替换现有 `Nfc_st.apk` 内容。 |
| `odm` | 按目标设备白名单写入 Xiaomi NFC 上层兼容属性。 |

`vendor` 与 `system_ext` 只用于检查 NXP HAL 的 SELinux/Framework 契约，不会由本模块直接修改。模块登记的策略片段随后由 `common/fix_vendor_avc` 统一写入 normal/debug vendor CIL。

## 输入与行为

- 模块资源：`prebuilt/XMNfcNci.apk` 及其 SHA-256 清单。
- 目标设备配置：`NFC_PROPERTIES_FILE`。
- 目标 APK：`system/system/app/Nfc_st/Nfc_st.apk`。
- 属性目标：`odm/etc/build.prop`。

原系统 `Nfc_st.apk` 只支持 `/dev/st21nfc`，而目标底包可提供 `/dev/nq-nci` 与 NXP AIDL HAL。模块保留原 APK 路径和 metadata，只替换 APK 内容；NFC 能力属性由目标设备流程显式提供，不再从小米原包推断。一加 15 使用 `devices/oneplus15/config/nfc.props`。

模块还拥有 NXP NFC 的最小 SELinux bundle。它先验证 `nfc-service-nxp.rc`、VINTF、`hal_nfc_default_exec` 标签、init 域转换以及当前 policy API，再登记一条版本化规则：允许 `system_server` 的 ANR 消费线程向 `hal_nfc_default` 发送普通 `signal`。不授予 wildcard、permissive、`dontaudit` 或额外文件权限。`common/fix_vendor_avc` 必须在本模块之后运行，负责把该片段幂等合并到 normal/debug vendor CIL 并清理 stale precompiled policy。

配置或属性目标缺失只跳过属性子步骤，不影响 APK 子步骤；APK 目标缺失也只跳过替换。替换前会校验原 ST APK、内置 APK、NXP HAL manifest 和所需 framework。模块不替换底包 HAL、固件或射频配置，也不携带与目标 boot image 绑定的 oat。

既有一加 15 DSU 测试曾验证 NFC 设置、NXP HAL 初始化、实体卡识别和 Tag Intent 分发。2026-08-19 的 Enforcing DSU 热测中，目标 AVC 在注入前约每 15 秒出现一次；仅临时加入 `system_server_202504 -> hal_nfc_default:process signal` 后连续多个周期增量为 0，NFC HAL 与 `com.android.nfc` 仍在运行且没有新增 NFC AVC。随后重载服务时另观察到 `MiNfcAdapter` 抛出 `UnsupportedOperationException: Doesn't support MI NFC APIs`；这是独立的 Framework/API 兼容问题，本 SELinux 规则不处理，也不能据本轮 AVC 热测宣称 NFC 整体功能已经恢复。固化 CIL 已通过 Android 16 normal/debug 完整 split policy 静态编译与基线 neverallow 对比，仍待下一次未污染 DSU 冷启动确认。

## 执行

```bash
NFC_PROPERTIES_FILE=/path/to/nfc.props \
bash port_main.sh common/fix_nfc common/fix_vendor_avc
```
