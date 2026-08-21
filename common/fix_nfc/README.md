# 适配 NXP NFC 系统应用

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system` | 以同平台签名的 NXP/Xiaomi APK 替换现有 `Nfc_st.apk` 内容。 |
| `odm` | 按目标设备白名单写入 Xiaomi NFC 上层兼容属性，并补齐开机加载的 `mi_nfc` service context。 |
| `vendor` | 补齐 `mi_nfc` service context；策略仍由统一入口写入。 |

`system_ext` 只用于检查 NXP HAL 的 Framework 契约。模块登记的策略与 contexts 片段随后由 `common/fix_vendor_avc` 统一写入 normal/debug vendor CIL、vendor service contexts 与 ODM precompiled service contexts。

## 输入与行为

- 模块资源：`prebuilt/XMNfcNci.apk` 及其 SHA-256 清单。
- 目标设备配置：`NFC_PROPERTIES_FILE`。
- 目标 APK：`system/system/app/Nfc_st/Nfc_st.apk`。
- 属性目标：`odm/etc/build.prop`。

原系统 `Nfc_st.apk` 只支持 `/dev/st21nfc`，而目标底包可提供 `/dev/nq-nci` 与 NXP AIDL HAL。模块保留原 APK 路径和 metadata，只替换 APK 内容；NFC 能力属性由目标设备流程显式提供，不再从小米原包推断。一加 15 使用 `devices/oneplus15/config/nfc.props`。

模块还拥有 NXP NFC 的最小 SELinux bundle。它先验证 `nfc-service-nxp.rc`、VINTF、`hal_nfc_default_exec` 标签、init 域转换以及当前 policy API，再登记版本化规则：允许 `system_server` 的 ANR 消费线程向 `hal_nfc_default` 发送普通 `signal`，并恢复原包 `ro.vendor.nfc.*` 的 `vendor_nfc_mi_prop` 类型、HAL/系统消费者读写契约和 property socket 连接。该窄前缀同步写入 vendor 与 precompiled property contexts。小米 NFC 应用还会在自身初始化时注册 `mi_nfc`；目标 service contexts 缺少该键时，servicemanager 会以 `SELinux denied for service` 拒绝注册，随后 `MiNfcAdapter` 因查不到服务而抛出“不支持 MI NFC APIs”。模块仅恢复原包已确认的 `mi_nfc u:object_r:nfc_service:s0`，同步写入 vendor 与 ODM precompiled service contexts，不扩展到尚无运行时证据的 `nfc.wallet` 等服务名，也不使用 `vendor_default_prop`、wildcard、permissive 或 `dontaudit`。`common/fix_vendor_avc` 必须在本模块之后运行，负责幂等合并并清理 stale precompiled policy。

配置或属性目标缺失只跳过属性子步骤，不影响 APK 子步骤；APK 目标缺失也只跳过替换。替换前会校验原 ST APK、内置 APK、NXP HAL manifest 和所需 framework。模块不替换底包 HAL、固件或射频配置，也不携带与目标 boot image 绑定的 oat。

既有一加 15 DSU 测试曾验证 NFC 设置、NXP HAL 初始化、实体卡识别和 Tag Intent 分发。2026-08-19 的 Enforcing DSU 热测中，目标 AVC 在注入前约每 15 秒出现一次；仅临时加入 `system_server_202504 -> hal_nfc_default:process signal` 后连续多个周期增量为 0，NFC HAL 与 `com.android.nfc` 仍在运行且没有新增 NFC AVC。2026-08-22 的 Enforcing 冷启动日志进一步确认：NFC HAL 正常初始化，`com.android.nfc` 在 `ServiceManager.addService` 注册 `mi_nfc` 时收到 `SecurityException: SELinux denied for service`，随后因 `mi_nfc` 不存在进入崩溃循环。新增 property 类型与 service contexts 都由开机阶段加载，仍须下一次未污染 DSU 软重启确认，不能以当前静态结果宣称永久修复已经实机生效。

## 执行

```bash
NFC_PROPERTIES_FILE=/path/to/nfc.props \
bash port_main.sh common/fix_nfc common/fix_vendor_avc
```
