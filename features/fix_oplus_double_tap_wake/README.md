# Oplus 双击亮屏兼容桥

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 安装 TouchFeature bridge、rc、VINTF manifest、设备专属 keylayout，写入属性及 ODM metadata。 |
| `vendor`（下游） | 本模块只登记 SELinux bundle；后续 `common/fix_vendor_avc` 才会把策略和早期 contexts 写入 vendor/ODM SELinux 文件。 |

本模块执行时只直接修改 `odm`。`vendor`、`system` 与 `system_ext` 在本模块中只作为底包契约和 ABI 输入读取。

## 模块说明

模块提供独立的 AIDL bridge，把 Xiaomi `ITouchFeature` mode 14 请求转发到底包 Oplus `IOplusTouch` HBP 服务。双击手势的输入事件通过目标设备专属 keylayout 映射为 `F4 WAKE`，不会修改全局 `Generic.kl`。

模块安装以下 ODM 产物：

```text
odm/bin/hw/vendor.dna.hardware.touchfeature-oplus-bridge
odm/etc/init/vendor.dna.hardware.touchfeature-oplus-bridge.rc
odm/etc/vintf/manifest/vendor.dna.hardware.touchfeature-oplus-bridge.xml
odm/usr/keylayout/<input_device_name>.kl
```

同时向 `odm/etc/build.prop` 写入 `ro.vendor.touchfeature.type`，并补齐目标文件的 contexts 与 fsconfig。bridge 只通过 `IOplusTouch` 调用底包触控服务，不直接访问 `/dev/hbp`、touchpanel proc 或 sysfs 节点。

## 目标设备参数

组合入口必须通过 `OPLUS_DOUBLE_TAP_PROPERTIES_FILE` 提供且只提供以下七项：

```properties
oplus.double_tap.panel_id=
oplus.double_tap.gesture_cfg_node=
oplus.double_tap.gesture_enable_node=
oplus.double_tap.gesture_cfg_value=
oplus.double_tap.input_device_name=
oplus.double_tap.scan_code=
oplus.double_tap.touchfeature_type=
```

模块校验数值范围、节点不重复、安全的 keylayout 文件名以及 `touchfeature.type` 的双击能力位。它还会验证底包 Oplus Touch AIDL V2 HBP 服务、精确 service context、客户端策略、所需 NDK 库，以及预编译 bridge 的输入哈希、arm64 PIE、16K 对齐和动态依赖。

一加 15 的硬件快照位于 `devices/oneplus15/config/double_tap_wake.props`，由 `OP15_port.sh` 显式传入；参数不会从小米原包推断。

## 运行时证据与验证边界

本轮先在一加 15 底包原系统取证，再在一加 15 DSU、root adb、SELinux `Enforcing` 环境完成以下热测：

- 息屏双击后 HBP 输出 `Gesture ID=1` 与 `detect double tap gesture`。
- 取证时输入设备为 `touchpanel`（当次枚举为 `/dev/input/event7`），上报 scan code `62` / Linux `KEY_F4`；event 编号可能随开机重新枚举，因此补丁按设备名生成 `touchpanel.kl`。
- 原系统 `Generic.kl` 只有 `key 62 F4`，没有 `WAKE` flag；这解释了内核已经识别双击、framework 却不能据此亮屏的现象。
- 底包 Oplus Touch AIDL 接口使用 transaction `4` 写 HBP 节点；一加 15 实测参数为 `gesture_cfg=4100 -> 2`、`gesture_en=4101 -> 1/0`。bridge 仍只调用该 AIDL 接口，不直接打开内核节点。
- HyperOS 消费端以 `ro.vendor.touchfeature.type & 1` 判断能力，并通过 Xiaomi TouchFeature transaction `9` 发送 `(touchId=0, mode=14, value)`。
- 当前进程无法热刷新已经缓存的 VINTF 清单，因此热测使用只位于 tmpfs 的测试 shim 跳过 `AIBinder_markVintfStability`，成功注册临时 Xiaomi TouchFeature service。transaction `9` 的 value `1/0` 均被 bridge 正确转发，Oplus HAL 日志分别确认 `4100=2`、`4101=1/0`。
- 重载底包 init service `vendor.touch-aidl-2` 后，Oplus service 重新注册，bridge 在下一次请求时自动丢弃死亡 Binder 并重连成功；没有观察到新增的 bridge 相关 AVC。
- `system_app` 是息屏指纹解锁补丁的 bridge 调用方；已在 Enforcing 下验证其到 bridge 的 `binder call` 最小权限，bundle 仅固化该单向调用，不额外授予 Binder transfer 或 service 查找权限。
- 把相同的 `key 62 F4 WAKE` 候选内容提供给新枚举的虚拟输入设备后，系统从 `Dozing` 记录 `WAKE_REASON_WAKE_KEY, details=android.policy:KEY`，证明该 WAKE 映射可以唤醒 framework。
- 真实 `/dev/input/event7` 在热挂载前已由 InputReader 打开并缓存旧 keylayout；实际双击仍同时出现 `detect double tap gesture` 与 `KEY_F4`，但 framework 没有收到 `KEYCODE_F4`，因此没有亮屏。单文件 bind mount 不能刷新已打开输入设备，这不是 bridge 转发失败。

上述热测确认了 Binder ABI、节点参数、HAL death 后重连以及 `F4 WAKE` 行为，但临时 bridge 运行在 `su` 域，且虚拟输入设备使用的是热挂载候选文件，不能替代永久独立域与设备专属 `/odm/usr/keylayout/touchpanel.kl` 的开机加载。完整 CIL、VINTF 缓存、独立域、真实触控设备 keylayout 选择和最终双击亮屏仍须在应用固化补丁后的干净 DSU 冷启动确认；未经冷启动不能宣称永久补丁已实机生效。

## SELinux 与执行顺序

本模块的 CIL、file/property/service contexts 以 bundle 形式登记。安装完成后必须执行 `common/fix_vendor_avc`，由其统一合并 normal/debug CIL 和早期 contexts：

```bash
OPLUS_DOUBLE_TAP_PROPERTIES_FILE=/path/to/double_tap_wake.props \
bash port_main.sh features/fix_oplus_double_tap_wake common/fix_vendor_avc
```

当前目录包含静态契约测试。静态检查与上述受限热测均不等同于固化产物的冷启动确认。
