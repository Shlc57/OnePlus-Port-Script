# Ace 6 TMS NFC 桥接（devices/oneplus_ace6/fix_nfc_tms_bridge）

## 背景

Ace 6 的 NFC 芯片是**青藤微系统（Tsingteng）THN31**，与一加 15（NXP SN220T）、Ace 6T（ST21NFC）都不同。`features/fix_nci_nfc` 是 NXP 专用适配（要求底包提供 `/dev/nq-nci` + `vendor.nxp.nxpnfc_aidl` 服务契约，缺失即失败），**对 Ace 6 不适用**。本补丁因此**替代** `fix_nci_nfc` 出现在 Ace 6 组合（`OPAce6_port.sh`）中。

## 逆向结论

| 项 | 值 |
| --- | --- |
| 芯片 | Tsingteng THN31（青藤微系统） |
| NFC HAL 服务 | `android.hardware.nfc-service-tms`（标准 `android.hardware.nfc/INfc/default` AIDL v1） |
| SE 服务 | `android.hardware.secure_element-service-tms`（`ISecureElement/eSE1`） |
| 设备节点 | `/dev/tms_nfc`（I2C） |
| 核心库 | `odm/lib64/nfc_nci.thn31nfc.tms.so` |
| 配置 | `odm/etc/nfc/libnfc-tms.conf_<项目ID>`（运行时拷贝到 `/data/vendor/nfc/`） |
| 固件 | `SEC_THN31_FW_VTP.txt.bin_*`（`thn31_fw_D1_1C_00`） |

## 方案

1. **保留底包 odm 的 TMS 栈**：TMS 服务/rc/manifest/NCI 库/配置/固件全在 Ace 6 底包 odm 分区，随 odm 刷入即保留。apply.sh 前置校验五件套，底包解包不完整时直接失败。
2. **设备节点别名兜底**：
   - 注入 `odm/etc/ueventd.rc`：`/dev/tms_nfc` 同时建立 `/dev/st21nfc`（小米 NfcNci 期望的 ST 节点）与 `/dev/nq-nci`（小米 NXP 路径）symlink 别名。
   - 新增 `odm/etc/init/nfc_tms_symlink.rc`：`on boot` 阶段二次兜底 symlink，并同步补齐 odm 分区 contexts/fsconfig metadata。
3. **SELinux 最小放行（bundle 机制）**：TMS 服务二进制复用 `hal_nfc_default` / `hal_secure_element_default` domain，通过 `config/selinux_bundle.tsv` 登记交付物，由 `common/fix_vendor_avc` 统一合并：
   - `policy vendor_policy config/selinux_policy.cil.in`：读 `/odm/etc/nfc` 配置/固件、写 `/data/vendor/nfc` 运行时目录、以及小米 `nfc` 域注册/绑定 `mi_nfc`、INfc、SE 服务所需的最小 Binder/service_manager 权限。
   - `contexts vendor/precompiled_file_contexts config/nfc_tms_file_contexts`：TMS 服务二进制 + `/odm/etc/nfc` + THN31 manifest 标签。
   - `contexts vendor/precompiled_service_contexts config/nfc_tms_service_contexts`：`nfc_hal_service.tms.aidl`、`secure_element_hal_service.aidl` 服务名标签。
4. **mi_nfc 服务标签兜底**：`mi_nfc u:object_r:nfc_service:s0` 在 bundle 注册表中已由 `fix_nci_nfc` 静态持有（跨 bundle contexts 键唯一），而 `fix_nci_nfc` 在 Ace 6 组合不激活，因此由本补丁 apply.sh 在运行时按需合并到 `vendor_service_contexts` 与 odm `precompiled_service_contexts`；原包来源合并已提供时幂等跳过。
5. **NFC 兼容属性**：组合入口通过 `NFC_PROPERTIES_FILE`（`devices/oneplus_ace6/config/nfc.props`）提供 `ro.vendor.nfc.*` 小米上层兼容开关，写入 `odm/build.prop`。

## 预期与限制

- 基础 NFC（读卡/NDEF）**中等概率可用**（TMS 自有栈 + NCI 标准协议层）
- 小米钱包/支付/SE **低概率**（SE 路径契约复杂，需实测迭代）
- NFC 失败不影响开机（功能缺失而非引导失败）

## 验证

刷机后：

```bash
adb shell dumpsys nfc | head -20        # 期望 state: ON
adb shell ls -la /dev/tms_nfc /dev/st21nfc  # 期望 st21nfc -> tms_nfc
adb logcat -s NfcNci NfcService TMS      # 查 NFC 启动日志
```

如 HAL 起不来，检查 `adb shell getenforce`（Enforcing 下若有 AVC 拒绝，贴 logcat 迭代补规则）。
