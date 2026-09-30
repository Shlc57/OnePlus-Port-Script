# THN31/TMS NFC 桥接（features/fix_nfc_tms_bridge）

供底包自带青藤 THN31（TMS）NFC 栈的机型共用；当前使用机型：一加 Ace 6（`OPAce6_port.sh`）、真我 Neo8（`RealmeNeo8_port.sh`）。适用条件：底包 odm 自带 `android.hardware.nfc-service-tms` + `manifest_nfc_thn31.xml` + `/dev/tms_nfc`（apply.sh 前置校验，不满足即失败）。

## 背景

THN31（青藤微系统）与一加 15（NXP SN220T）、Ace 6T（ST21NFC）都不同。`features/fix_nci_nfc` 是 NXP 专用适配（要求底包提供 `/dev/nq-nci` + `vendor.nxp.nxpnfc_aidl` 服务契约，缺失即失败），**对 TMS 机型不适用**。本补丁因此**替代** `fix_nci_nfc` 出现在 TMS 机型组合中。

为什么不能直接换通用 NfcNci（如 Transsion/OplusNFC）：移植侧 system 是小米 HyperOS，其 `com.android.nfc`（Nfc_st）为 **MIUI 签名**且 `sharedUserId=android.uid.nfc`，NCI 栈（`libnfc_xm_nci_jni.so`）打包在 APK 内部；外部签名的通用 NfcNci 会因 sharedUserId 签名不匹配被 PackageManager 拒装，也无法在不破签的前提下注入外部 NCI 库。所以唯一签名安全的路径是保留小米 Nfc_st，仅做节点别名 + SELinux 桥接。

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

1. **保留底包 odm 的 TMS 栈**：TMS 服务/rc/manifest/NCI 库/配置/固件全在底包 odm 分区，随 odm 刷入即保留。apply.sh 前置校验五件套，底包解包不完整时直接失败。
2. **设备节点别名兜底**：
   - 注入 `odm/etc/ueventd.rc`：`/dev/tms_nfc` 同时建立 `/dev/st21nfc`（小米 NfcNci 期望的 ST 节点）与 `/dev/nq-nci`（小米 NXP 路径）symlink 别名。
   - 新增 `odm/etc/init/nfc_tms_symlink.rc`：`on boot` 阶段二次兜底 symlink，并同步补齐 odm 分区 contexts/fsconfig metadata。
3. **SELinux 最小放行（bundle 机制）**：TMS 服务二进制复用 `hal_nfc_default` / `hal_secure_element_default` domain，通过 `config/selinux_bundle.tsv` 登记交付物，由 `common/fix_vendor_avc` 统一合并：
   - `policy vendor_policy config/selinux_policy.cil.in`：读 `/odm/etc/nfc` 配置/固件、写 `/data/vendor/nfc` 运行时目录、以及小米 `nfc` 域注册/绑定 `mi_nfc`、INfc、SE 服务所需的最小 Binder/service_manager 权限。
   - `contexts vendor/precompiled_file_contexts config/nfc_tms_file_contexts`：TMS 服务二进制 + `/odm/etc/nfc` + THN31 manifest 标签。
   - `contexts vendor/precompiled_service_contexts config/nfc_tms_service_contexts`：`nfc_hal_service.tms.aidl`、`secure_element_hal_service.aidl` 服务名标签。
4. **mi_nfc 服务标签兜底**：`mi_nfc u:object_r:nfc_service:s0` 在 bundle 注册表中已由 `fix_nci_nfc` 静态持有（跨 bundle contexts 键唯一），而 `fix_nci_nfc` 在 Ace 6 组合不激活，因此由本补丁 apply.sh 在运行时按需合并到 `vendor_service_contexts` 与 odm `precompiled_service_contexts`；原包来源合并已提供时幂等跳过。
5. **NFC 兼容属性**：组合入口通过 `NFC_PROPERTIES_FILE`（各机型 `devices/<机型>/config/nfc.props`）提供 `ro.vendor.nfc.*` 小米上层兼容开关，写入 `odm/build.prop`。
6. **属性 SELinux 标签**（运行时幂等合并到 `vendor/etc/selinux/vendor_property_contexts` 与 odm `precompiled_property_contexts`，不进 bundle 注册表）：底包 `property_contexts` 里没有 `ro.vendor.nfc.` 前缀（只有 `vendor.qti.nfc.` 与 `vendor.tms.nfc.`），上一步写入的键会落 `default_prop`，被 `com.android.nfc`（`nfc` 域）读取时静默拒绝（真机痕迹：`Access denied finding property ro.vendor.nfc.mitouch/phonecase`，而 `avc` 里查不到条目，属 `dontaudit`）。本补丁把它们统一标到底包已有的 `vendor_tms_nfc_prop`，并在策略片段里只给 `nfc` 域补读取权限。**为何不走 bundle**：同一键 `ro.vendor.nfc.` 已由 `fix_nci_nfc` 静态持有，而 `common/fix_vendor_avc` 要求跨 bundle 的 contexts 键归属全局唯一（注册表契约测试会直接拒绝），所以沿用第 4 步 `mi_nfc` 的先例改为运行时合并；两条 NFC 路线不会在同一设备共存，运行时不会互相覆盖。目标 rc 里已有其它 `ro.vendor.nfc.` 标签时报错退出，不静默改写。注意这一步补的是第 5 步造出的欠账，不是新的能力。
7. **让 TMS HAL 独占 `INfc/default`（仅在有竞争者时）**：部分底包除 TMS 外还多带一份按其它芯片实现的 NFC HAL（真我 Neo8 的 `vendor/bin/hw/android.hardware.nfc-service-st`，其 rc 声明 `interface aidl android.hardware.nfc.INfc/default`）。原厂它是无害的：芯片不是 ST21 时 `stm_nfc_i2c` 不创建 `/dev/st21nfc`，该 HAL open 失败且 `oneshot` 就退出，不占名字；但本补丁建立的 `/dev/st21nfc → /dev/tms_nfc` 别名让它 open 成功，于是它抢在 TMS 之前注册 `INfc/default`，把 ST 专有命令（甚至 ST 固件下载）发到青藤控制器，并与 TMS HAL 同时读写同一节点。动作：删掉竞争 rc 里的 `INfc/default` 接口声明（只加 `disabled` 不够——init 会把它当 lazy HAL 按需拉起）并补 `disabled`；只在确实禁用了竞争者时，才给 TMS 服务补上 `interface aidl android.hardware.nfc.INfc/default`。无竞争者的机型（如一加 Ace 6）两步都跳过，保持底包原样。
8. **`/dev/thn31` 节点别名**（init rc + ueventd，与 `st21nfc`/`nq-nci` 同机制）：TMS NCI 库在拿不到 `libnfc-tms.conf` 里的 `TMS_NFC_DEV_NODE` 时，会回退到自己写死的默认节点 `/dev/thn31`（库内串 `Invalid nfc device node name keeping the default device node /dev/thn31`），而底包从不创建它 ⇒ 控制器根本打不开。这一行是两根机型共同的必要修复之一。
9. **播种 TMS NCI 运行配置（两台共同根因的直接修法）**：
   - 事实：底包只带 `odm/etc/nfc/<name>_<project>`（裸名 `libnfc-tms.conf`/`libnfc-tms_RF_EC2.conf` **两台都没有**，而 `odm/etc/libnfc-nci.conf` 是裸名 ⇒ “带后缀 = 等上层铺”是 realme 的既定设计）；HAL 候选路径为 `/data/vendor/nfc/`、`/odm/etc/`、`/vendor/etc/libnfc-tms.conf`。realme 原厂由 **system 侧 Oplus `NfcNci.apk`** 用 `copyFile` 铺运行名（dex 里 `/data/vendor/nfc` 命中 29、`_RF_` 62、`hardware.sku`），该 apk 与小米 `Nfc_st` 同包名同 `android.uid.nfc` 且依赖 `com.oplus.accesscard`/`OplusFeatureConfigManager`/`deepthinker`/`nfcvendorlib.jar`，**不能移植**。
   - 本补丁的两个零猜测补位：a) 打包期把 `<name>_<prjname>` 复制成 `/odm/etc/<name>` 裸名；b) 新增 `nfc_tms_seed_config.rc`，在 `on post-fs-data` 把裸名 `copy` 到 `/data/vendor/nfc/`（mkdir/chown nfc:nfc/chmod 0660）。conf 内容逐字照抄底包（含 `NFA_STORAGE="/data/nfc"`），不提前偏离原厂行为。
   - `prjname` 探测：`odm/build.prop` 的 `ro.separate.soft` → 退到 `odm/etc/fingerprint.json` 的 `project`；拿不到只警告并跳过本步骤（两台实测值：Neo8 `25602`、Ace 6 `24851`，补丁内无任何机型硬编码）。
   - 默认只铺基础通路必需的 `libnfc-tms*`；入口设 `NFC_TMS_SEED_ALL_CONFIGS=1` 时连门禁卡/城市/SuperCard 配置一起铺（Neo8 共 23 个、Ace 6 同构）。新增文件同步 odm contexts/fsconfig；配套策略只给 `vendor_init` 读 `system_file`、读写 `vendor_data_file` 3 条。

## 预期与限制（2026-09-30 真机现状，不得记为已修）

- **两台 TMS 机型（一加 Ace 6、真我 Neo8）的 NFC 目测都不通**；Neo8 的回传显示框架自认 `mState=on`、四个 NFC 服务 running、`/dev/tms_nfc`+别名在位，但发现层全线失败：`startRfDiscovery: Wait for completion timeout`、`tech_mask = 00`、`nfc_ncif_cmd_timeout → NFA_DM_NFCC_TIMEOUT_EVT → recovery nfc`、`commitRouting: timeout waiting for NFA_EE_UPDATED_EVT`、`nfaVSCallback: RSP status: 8 to Android proprietary cmd 9`、`RF_INTF_ACTIVATED=0`。
- 上面第 7 步只能消除 **Neo8 独有**的那一层伤害（ST HAL 抢注，且它依赖 `android.hardware.nfc-V2-ndk`，而小米 HyperOS 侧是 V1 客户端：`odm/lib64/android.hardware.nfc-V1-ndk.so`）。**Ace 6 没有 ST HAL 也不通 ⇒ 两台共同根因已由第 8/9 步定位并修复（待真机）：HAL 读不到裸名 `libnfc-tms.conf` ⇒ 设备节点回退到不存在的 `/dev/thn31`，同时 `TMS_NFC_DEV_NODE`/`TMS_NFCEE_PL_*`/`TMS_SET_CONFIG_ALWAYS`/`PWR_OFF_LISTEN_TECH_MASK`/VS 专有配置整体丢失。** 一条根因同时解释四个已观测现象：`nfc_ncif_cmd_timeout → NFA_DM_NFCC_TIMEOUT_EVT → recovery nfc`、`startRfDiscovery: Wait for completion timeout`、`tech_mask = 00`、`commitRouting: timeout waiting for NFA_EE_UPDATED_EVT`、`nfaVSCallback: RSP status: 8`、`RF_INTF_ACTIVATED=0`。**仍不得记为已修**：需一台回传确认下面“验证”里的正例条目。
- 小米钱包/支付/SE 仍为**低概率**（SE 路径契约复杂，需实测迭代）。
- NFC 失败不影响开机（功能缺失而非引导失败）。

## 验证

刷机后（先看名字归属，再看数据链路）：

```bash
service list | grep -i nfc                       # 期望 INfc/default 背后是 TMS 服务
getprop | grep -E 'init.svc.nfc_hal_service|init.svc.nfc_hal_service.tms'  # 期望 ST 那个不再 running
ls -l /vendor/bin/hw | grep -i nfc               # 确认本机底包到底有没有 ST HAL
dumpsys nfc | head -20                           # 期望 state: ON
ls -la /dev/tms_nfc /dev/st21nfc                 # 期望 st21nfc -> tms_nfc
getprop ro.vendor.nfc.mitouch                    # 第 6 步后应能读到（之前 nfc 域读不到）
logcat -s NfcNci NfcService libnfc_nci NfcService  # 查 RSP status 8 / cmd timeout 是否消失
```

更完整的取证用 [`tools/issue_trace.sh`](../../tools/issue_trace.sh) 的 `nfc` 场景（已收录 NFC 传输层硬错、INfc 持有者、`TMS 配置落地` 与 `HAL 配置加载失败` 两组哨兵）。

第 8/9 步的正例判据（两台都要看）：

```bash
ls -l /dev/thn31 /dev/tms_nfc /dev/st21nfc        # thn31 必须存在且指向 tms_nfc
ls -l /odm/etc/libnfc-tms.conf /odm/etc/libnfc-tms_RF_EC2.conf   # 裸名存在（打包期生成）
ls -lZ /data/vendor/nfc/                          # post-fs-data 已铺入，label/权限可读
logcat | grep -E "Cannot open config file|Using default value for all settings"   # 应为空
```

回传后若仍不通，按优先级查三个已预定的候选：

1. `dlopen` 不到 NCI 模块：conf 里 `NCI_HAL_MODULE="nfc_nci.tmsnfc"`，而底包实名为
   `nfc_nci.thn31nfc.tms.so` ⇒ 若日志出现 `nfc_nci.tmsnfc.so not found`，再补同名副本/软链（现在不预补，避免无据改动）。
2. `NFA_STORAGE="/data/nfc"`：逐字照抄了底包；若 avc 出现 `hal_nfc_default`→`nfc_data_file` 拒绝，再评估改写为
   `/data/vendor/nfc`（那时 bundle 已有的 `vendor_data_file` 权限就能用上）。
3. 上层控制面：`ITmsNfc/default`、`nfcExtnsService` 与 Oplus 扩展握手（`dispatch/rules.xml`、各城市门禁卡配置），
   影响的是钱包/门禁而非基础读卡；需要时再把 `NFC_TMS_SEED_ALL_CONFIGS=1` 打开。

**一加 Ace 6 至今没有一份 NFC 回传**：两台同根，它也是验证第 8/9 步最干净的样本（无 ST 干扰），应优先采。

如 HAL 起不来，检查 `adb shell getenforce`（Enforcing 下若有 AVC 拒绝，贴 logcat 迭代补规则）。
