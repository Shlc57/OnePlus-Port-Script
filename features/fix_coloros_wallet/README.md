# features/fix_coloros_wallet

在 HyperOS 移植系统上恢复 ColorOS 钱包能力：把目标机型底包的 ColorOS 钱包五件套
原签名安装回原包 `system`、`system_ext`，并补齐 contexts/fsconfig。完整方案（LSPosed
运行时兼容、NFC eSE 路由、真机验证步骤）见
`docs/designs/2026-09-13-coloros-wallet-port-design.md`。

## 来源与目标

| 分区 | 目标路径 | 来源 |
| --- | --- | --- |
| `system` | `system/system/app/{FinShellWallet,TasWallet,UPTsmService,HeytapHTMS}` | `prebuilt/system/app/...` |
| `system_ext` | `system_ext/app/EidService` | `prebuilt/system_ext/app/EidService` |
| `system_ext` | `system_ext/priv-app/KeKeUserCenterAccount`、`system_ext/etc/permissions/privapp-permissions-keke-usercenter.xml` | `prebuilt/system_ext/...` |
| `system` | `system/system/framework/oplus-osense-stub.jar` | `prebuilt/framework/oplus-osense-stub.jar` |
| `odm` | `odm/etc/init/coloros_wallet_props.rc`、`odm/etc/init/coloros_wallet_nfc_settings.{rc,sh}` | `prebuilt/odm_init/...` |
| 以上各分区 | 新增路径的 contexts/fsconfig 逐文件条目 | 模块内 `merge_*_file` 补丁 |
| `system`、`odm`（改既有） | `init.zygote64.rc` BOOTCLASSPATH 注入、`build.prop` 身份键 | 模块内 awk / `ensure_prop` |

## 使用方法

1. 从目标机型底包 ROM 解出 `system.img`，把以下目录原样复制进 `prebuilt/`（保持
   `app/<App>/<App>.apk` 与 `lib/arm64` 布局，不要改动 APK 签名）：

   ```text
   prebuilt/
   ├── system/app/FinShellWallet/
   ├── system/app/TasWallet/
   ├── system/app/UPTsmService/
   ├── system/app/HeytapHTMS/
   └── system_ext/app/EidService/
   ```

2. 正常执行组合流程即可；预置产物齐全后模块自动生效。

## 行为

- 五件套必须整体就绪：任一目录或 APK 缺失时整体 `warn+skip`，不部分安装。
- 复制走 `copy_tree_missing_only`：只补缺失文件，已存在且内容相同幂等跳过，目标冲突
  （内容不同/类型不符）报错。
- metadata 按复制后的树生成：fsconfig 目录 `0 0 0755`、文件 `0 0 0644`（与原包格式一致）；
  contexts 每个 app 根一条 `<运行时路径>(/.*)? u:object_r:system_file:s0`，经
  `merge_fsconfig_file`/`merge_contexts_file` 原子合并去重，可重复执行。
- 预置来源中不允许出现符号链接。

## 运行时依赖固化（无 LSP 路线，2026-09-13/14 真机诊断后新增）

- **身份键修正（build.prop 加载期）**：第一版 `post-fs-data` rc `setprop` 实测无效——
  init 的 PropertySet 拒绝覆盖**已存在**的 ro. 属性（build.prop 加载早已写入
  Xiaomi 值）。改为直接修正加载期值：`odm/etc/build.prop` 分区键
  `ro.product.odm.brand/manufacturer=OnePlus`（Android 12+ 分区键回填优先于普通键，
  是 Build.BRAND 的最终决定者）+ `system/system/build.prop` 普通键兜底 +
  `ro.product.cuptsm=ONEPLUS|ESE|01|02`、`ro.build.version.oplusrom=V16.1.0`。
  **必须在 `common/fix_device_identity` 之后执行**（其 mi_odm 快照会写 Xiaomi 值）。
  机型真值同样写 odm 分区键（`odm.device=OP6117L1`、`odm.model/name=PLR110`，
  2026-09-16 主系统实测）：钱包 fdid 设备指纹按 (model, device) 校验，残留
  `model=2512BPNDAC/device=nezha` 会报“机型不匹配”导致乘车卡列表空与门禁
  复制 291005。运行时代号由组合入口 `RUNTIME_DEVICE_CODE` 声明，联动机型 XML
  改名与小爱 VoiceAssist 白名单（`XIAOAI_VOICEASSIST_DEVICE_CODE`）；
  `odm.cert.*` 等其余分区键保留 nezha。
- **钱包身份键 rc**：`odm/etc/init/coloros_wallet_props.rc` 保留作为 rc 路径
  兜底（对属性表中不存在的键首次 setprop 有效；cuptsm 实测被 init 加载路径
  丢弃、属性表不存在，机制待查，双写互为保险）。
- **OSense stub jar**：FinShell 解冻 SDK `LongTimeUnfreezeManager extends
  com.oplus.osense.task.BgRunningCallback`，移植系统缺失欧加 OSense 类导致
  `NoClassDefFoundError` 闪退。提供 1.4KB 最小空实现 jar
  （`BgRunningCallback`/`OsenseResEventClient`，方法签名取自 5.47.5 smali 引用）
  并在 `init.zygote64.rc` 的 service zygote 块注入
  `setenv BOOTCLASSPATH <运行值>:/system/framework/oplus-osense-stub.jar`
  （BOOTCLASSPATH 原值存 `config/zygote_bootclasspath.txt`，原包更新后需重新
  从真机 `cat /proc/$(pidof zygote64)/environ` 捕获；HyperOS 新版 rc 已不含
  `setenv BOOTCLASSPATH`，真值改由 `derive_classpath` 生成，也可从
  `/data/system/environ/classpath` 读取）。模块写入前会校验快照中全部
  system/system_ext jar 在目标工程存在，缺失即在打包侧失败，防止 zygote 因
  boot classpath 缺条目崩溃循环（卡二屏）。写入时按快照重写 `service zygote`
  块内的**全部** `setenv BOOTCLASSPATH` 行（历史注入值与原包自带旧版值都会被
  替换，避免 init 按后出现的 setenv 生效而丢弃 stub）；块外的同名 setenv（如
  `service zygote-secondary`）不属于本服务，不做修改。
  曾尝试向 bootclasspath.pb 追加贡献条目做动态化，真机验证钱包仍闪退
  （stub 未进入 BCP），已回退为快照注入。已知限制：**模块不能
  替换 init.zygote64.rc 生效**（init 解析早于 KSU 挂载），必须走镜像重打包刷机；
  `resetprop -p` 对 KSU 版本不落盘，同样不可用。

## 依赖与限制

- 镜像侧不修改任何钱包 APK（签名红线：eSE ARA-M 与 TSM 服务端均校验原始签名）。
- 进程内兼容走**无 LSP 路线**：身份由底包 odm/vendor 原生真值满足（cuptsm/prjname 等），
  NFC eSE 路由与 SecureElement 白名单按需固化进系统 APK（Nfc_st.apk / com.android.se，
  无签名约束），钱包初始化由伴生脚本完成；详见设计文档 §6。
- eID 卡功能为后置项（无 LSP 路线下桥选择依赖平台签名推断，预期不可用）。
- 本模块不改 `odm`/`vendor`；NFC HAL 服务契约由 `features/fix_nci_nfc`（NXP 栈机型）负责。

## 系统 APK 固化与运行时开关（2026-09-15 真机诊断新增）

### 固化补丁（apply.sh 内自动执行，幂等）

- **`patch_secure_element.sh`**：com.android.se（`system/system/app/SecureElement/
  SecureElement.apk`）`Terminal.isPrivilegedApplication` 入口追加钱包包名白名单
  （com.finshell.wallet / com.heytap.tas / com.heytap.htms），命中走
  `ChannelAccess.getPrivilegeAccess`（全 ALLOWED）绕过 ARA-M。修复卡包
  "获取CPLC失败"与乘车/开门"重启设备后重试"。真机已验证生效。依据：底包 eSE
  ARA-M 仅放行银联 UPTsmService 证书（SHA-1 53:6C:79:B9…）与 com.nxp.security，
  钱包证书（FinShell 7F:68:E8:08…、TasWallet BD:AB:01:68…，SHA-256）被拒
  （`AccessControlException: no APDU access allowed`），且 ARA-M 自身仅银联证书
  可更新，镜像侧无法补规则。
- **`patch_settings_nfc_payment.sh`**：MIUI Settings（`system_ext/priv-app/
  Settings/Settings.apk`）新增空壳类 `com.android.settings.nfc.PaymentSettings
  extends DefaultPaymentSettings`。钱包经 `android.settings.NFC_PAYMENT_SETTINGS`
  跳转"感应式支付"页时别名仍指 AOSP 旧类名，`ClassNotFoundException` 导致页面
  只有标题没有内容。真机已验证生效。

### 欢太账号（com.oplus.account，第六依赖，2026-09-15 补）

- 钱包登录与云端 TSM 流程（复制实体门禁卡、乘车卡）要求欢太账号鉴权：缺包时
  `As-TaskGetToken -202`（点击登录无反应）、门禁 `/nfc/door/v1/check-condition`
  返回 99990 用户鉴权失败（"登录取消"）、乘车卡列表为空，两个页面均在 onCreate
  检查阶段自行 finish（真机日志实证，与参考方案同构缺口——参考 LSP 无任何账号
  hook，其"五件套最小集合"结论对登录链路不成立）。
- 底包 ColorOS 16 账号应用位于 `/product/priv-app/KeKeUserCenterAccount`
  （包名 `com.oplus.account`，CN_9.16.106，与 FinShell 5.47.5 同出自 PLR110，
  配套版本；manifest 同时声明 heytap/oppo usercenter 兼容名），原生库内嵌 APK，
  无独立 lib 目录。
- 预置：`prebuilt/system_ext/priv-app/KeKeUserCenterAccount/`（整目录）+
  `prebuilt/system_ext/etc/permissions/privapp-permissions-keke-usercenter.xml`
  （priv-app 白名单；底包 enforce 模式且无该包显式声明，此处仅列账号链路所需
  signature|privileged 权限）。目标落 `system_ext/priv-app/...`，预置缺失时
  warn+skip（不阻塞五件套主流程）。

### 运行时开关（data 分区设置，模块开机自动补写）

HyperOS Nfc_st 不维护欧加钱包依赖的运行时状态。其中 `nfc_multise_active`（钱包
isNfcEseMode 判定，缺失时开门/乘车弹"设为默认NFC应用"对话框并闪退）已由本模块
固化为开机自动补写：`prebuilt/odm_init/coloros_wallet_nfc_settings.rc` 在
`sys.boot_completed=1` 时以 shell 域 `exec_background` 执行同目录 `.sh` 脚本，
写键并延迟广播刷新钱包缓存（小米 Nfc 不发该 Oplus 广播）。镜像侧无法写入
data 分区设置，故采用 init 运行时补写；每次开机幂等覆写同一值。

> 未验证风险：`exec_background u:r:shell:s0` 依赖 init→shell 域转换与 shell 读
> `vendor_configs_file` 的 SELinux 许可，尚未在真机确认（本仓首次使用该机制）。
> 若刷机后 `settings get global nfc_multise_active` 仍为 null，应先查 avc denied；
> 被拒时改走 `common/fake_device_params` 模式（自建 disabled service + 专属 exec
> 上下文 + CIL，经 `config/selinux_bundle.tsv` 交给 `common/fix_vendor_avc` 合并）。

仍需手工执行的开关（仅排障时使用）：

```bash
# 默认支付组件（NfcService 按 Wallet 角色同步，写键后角色自动跟随）
settings put secure nfc_payment_default_component \
  com.finshell.wallet/com.nearme.wallet.nfc.CardService
# 手工补写 eSE 多安全域模式（正常情况下由模块 rc 自动完成）
settings put global nfc_multise_active "Embedded SE"
# 手工通知钱包刷新缓存（正常情况下由模块 rc 延迟广播）
am broadcast -a com.nfc.action.default_pay.changed \
  -n com.finshell.wallet/com.nearme.wallet.nfc.NfcDefaultPayChangedReceiver
```

### 已知未决

- **登录无反应 / 乘车页闪退（卡列表为空）**：钱包依赖欢太账号
  `com.heytap.usercenter`（action `com.heytap.usercenter.account_login`、账号
  token -202），移植系统缺失该包，需从目标机型底包补提取安装。
- **USB 用途弹窗缺 USB 网络共享/MIDI 选项**：内核 configfs 具备
  `midi.gs5`/`gsi.rndis` function，缺失发生在 MIUI 设置判定层，待查。
- **Nfc_st eSE NFCEE 路由**：小米 NFC 包 `OFFHOST_ROUTE_ESE={01}` 寻址不存在的
  0x0401（SN220T 实际 NFCEE 待真机核对），影响非接触刷卡路由，见设计文档 §6-B。
- 伴生脚本尚未入库（设计见 `docs/designs/2026-09-13-coloros-wallet-port-design.md` §6）。
