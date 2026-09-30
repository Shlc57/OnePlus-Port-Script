# 一加 Ace 6 系列修补脚本使用说明

本说明适用于 `OPAce6_port.sh`（一加 Ace 6）与 `OPAce6T_port.sh`（一加 Ace 6T）。脚本会直接修改已经解包的分区目录，不负责解包、打包或刷机。一加 15 的流程见 [`README_OP15.md`](README_OP15.md)。

## 机型与移植来源

| 机型 | 型号 | 处理平台 / Target | 屏幕 | 电池 | 内核 |
| --- | --- | --- | --- | --- | --- |
| 一加 Ace 6 | PLQ110 / OP6113 | 骁龙 8 至尊版 / `sun` | 6.83″ 1.5K 165Hz 五档屏（60/90/120/144/165，LTPS），1272×2800（底包 sdm sun）；全亮度类 DC + 低亮度纯 DC，>1920Hz 高频 PWM | 7800mAh / 120W | 6.6 |
| 一加 Ace 6T | PLR110 / OP6117 | 第五代骁龙 8（SM8845）/ `canoe` | 6.83″ 1.5K 165Hz 五档屏（60/90/120/144/165，LTPS），1272×2800；调光方案与 Ace 6 相同 | 8300mAh / 100W | `android16-6.12` |

两款机型均运行 ColorOS 16（Android 16）。移植原包使用小米 17 系列澎湃 OS 4 包（Android 16），与一加 15 流程同源；原包与底包的 Target/内核差异不影响本流程，因为最终 `odm`、`vendor` 仍以底包为准，原包只提供 `product`、`system`、`system_ext`。

与一加 15 流程的差异：

- **NFC 方案不同**：Ace 6 的 NFC 芯片是青藤 THN31（TMS 栈），NXP 专用的 `features/fix_nci_nfc` 对其会失败，组合改用 [`features/fix_nfc_tms_bridge`](features/fix_nfc_tms_bridge/README.md)（与真我 Neo8 共用）；Ace 6T 仍使用 `features/fix_nci_nfc`，依赖底包提供 NXP 服务契约。
- **SELinux 基建**：Ace 6 底包 vendor 缺 SELinux 版本标记（DNA_ace6 实测 `plat_sepolicy_vers.txt`=202404 **已存在**、`genfs_labels_version.txt` **缺失**），组合在 `common/fix_vendor_avc` 之前加入 [`devices/oneplus_ace6/fix_vendor_selinux_files`](devices/oneplus_ace6/fix_vendor_selinux_files/README.md) 补齐——缺失的一方按已存在的一方同值写入，两者都缺才回退内置默认 202504（不写死版本，以适应不同 ColorOS 构建）；Ace 6T 底包不缺，无需该模块。
- **Millet 核心桥**：Ace 6T 内核与一加 15 相同（`android16-6.12`），直接用仓库预编译 KO；Ace 6 内核为 6.6（SM8750），组合入口以 `KMI=android15-6.6` 选择本仓库用 `features/oplus_millet_core_bridge/build.sh` 编译的 6.6 KO（vermagic 6.6），两款机型都接入 millet。
- **ColorOS 钱包 / 运行时代号链**：Ace 6 与 Ace 6T、真我 Neo8 一致接入 `features/fix_coloros_wallet`，并声明 `RUNTIME_DEVICE_CODE`（Ace 6=OP6113L1），`fix_device_identity` 把原包机型 XML 改名为运行时代号，`fix_face_unlock` 相应排在 `fix_device_identity` 之后；钱包身份真值由 `devices/oneplus_ace6/config/wallet_identity.props` 提供（device=OP6113L1、model=PLQ110、cuptsm=ONEPLUS\|ESE\|01\|27、oplusrom=V16.1.0 均取自 DNA_ace6 底包；运行时代号取自底包 fingerprint.json，boot 后需复核）。
- **崩溃环守护**：与 Neo8 一致引入 `common/disable_oplus_crash_loop`（只读预检，服务不存在则整体跳过）。
- **多平台 Target 过滤**：两款机型的底包 `sdm_display_resolution_extn.xml` 含多个平台 Target（Ace 6 还包含 `anorak 7104x3840`），组合入口通过 `PORT_DISPLAY_TARGET`（`sun`/`canoe`）让 `common/fix_boot_refresh_rate` 只收集本机 Target 的 PanelResolution，`fingerprint.props` 中的 `ultrasonic.fp.target` 对指纹模块起同样作用。
- **不包含 `devices/oneplus15/*` 专属模块**：自动亮度、刷新率开关补丁按机型分别移植为 `devices/oneplus_ace6*/` 下的同名模块（P7 面板亮度表、实测 Display ID）。
- **`common/fix_mtp` 按 rc 形态自适应**：小米原包 rc 会覆盖底包 `init.usb.configfs.rc`。两款机型的底包 rc 均走 `mtp.gs0` 纯触发器（无 `use_ffs_mtp`），且两者逐字节一致；真底包文件分别放在 `devices/oneplus_ace6/config/init.usb.configfs.rc` 与 `devices/oneplus_ace6t/config/init.usb.configfs.rc`，各入口通过 `FIX_MTP_SOURCE_RC` 传入本机型文件，模块按来源形态校验并替换。
- **不包含 `features/fix_oplus_ltpo`**：Ace 6 系列两款机型面板均为 1.5K 165Hz 五档屏（60/90/120/144/165，LTPS；全亮度类 DC + 低亮度纯 DC，>1920Hz 高频 PWM），没有 Oplus ADFR/LTPO 链路；该模块的一加 15 专属资产（ADFR RUS XML、Apollo panel-nit）同样不适用，组合中已移除。
- **`DEVICE_IDENTITY_PROP` 未启用**：参考流程在澎湃 OS 4 原包上未启用该 SKU 附加配置；如需启用，取消入口脚本中的注释并确认原包内存在同名 prop 文件。

## 准备工作

1. 工具要求与一加 15 流程一致，见 [`README_OP15.md`](README_OP15.md) 的依赖清单。
2. 使用 D.N.A 解包好分区，目录结构与一加 15 相同（`odm`、`vendor` 来自 Ace 底包；`product`、`system`、`system_ext`、`mi_odm`、`mi_vendor`、`mi_ext` 来自小米原包；`DNA_config` 或 `config/` 保留各分区 metadata，两种目录名与两套文件命名均可组合识别）。
3. 首次执行前建议核对的底包实测参数（详见 [`devices/oneplus_ace6/README.md`](devices/oneplus_ace6/README.md) 与 [`devices/oneplus_ace6t/README.md`](devices/oneplus_ace6t/README.md)）：
   - `config/fingerprint.props`：传感器中心坐标属换算估算值，指纹位置不对时实机量取后修改并重跑；
   - `config/double_tap_wake.props`：沿用一加 15 触控栈值，双击不生效或误触时用 `getevent` 校准；
   - 显示、NFC、触感策略文件的初始值沿用一加 15 流程，实机验证前请视为待核对，不能当作已确认生效。
4. MTP 修复默认启用，底包 `init.usb.configfs.rc` 已随仓库提供（见上文差异说明）；更换底包时需重新提取并核对该文件。

## 使用方法

```bash
# 一加 Ace 6 整套流程
bash OPAce6_port.sh

# 一加 Ace 6T 整套流程
bash OPAce6T_port.sh
```

也可以通过 `port_main.sh` 单独执行某个模块，例如：

```bash
bash port_main.sh common/fix_boot_refresh_rate
```

脚本遇到错误会立即停止；根据终端提示补齐缺失文件或工具后，重新执行同一条命令即可。所有补丁可重复执行。

## 验证边界

本流程来自参考工程的机型适配与逆向结论，经静态检查与临时工程集成测试验证，**尚未在真实 Ace 6 / Ace 6T 解包分区上完整执行**：

- 刷新率属性、分辨率列表由 `common/fix_boot_refresh_rate` 从底包显示栈自动生成并按 Target 过滤；Ace 6 与 Ace 6T 实测均为 165Hz 五档屏（60/90/120/144/165），两款机型的 `fix_refresh_rate_switch` 与一加 15 共用同一套 144/165Hz 互斥策略、patcher 三处逐字节一致；面板 DC/PWM 的实际观感仍需实机确认。
- 超声波指纹坐标、双击亮屏参数属估算/沿用值，实机确认前不能当作已确认生效。
- Ace 6 的 TMS NFC 桥接：基础 NFC 中等概率可用，小米钱包/SE 路径低概率，需实机迭代。
- 不要把本文档中未经设备验证的描述当作已经确认生效的行为。
