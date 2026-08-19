# 统一合并 vendor SELinux 策略

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `vendor` | 合并原包 vendor SELinux 文件、normal/debug CIL、file/property/service contexts 及 vendor metadata contexts。 |
| `odm` | 更新 precompiled file/property/service contexts 与 ODM metadata，并删除 stale precompiled policy 及其 metadata。 |

`mi_vendor`、`system` 与 `system_ext` 只提供策略输入和 ABI 校验依据，不会被本模块写入。

## 模块说明

这是 SELinux 的下游统一落盘入口。模块通过 `common/selinux_merge` 合并原包 vendor 策略；版本或 ABI 不兼容时，只导入底包原生类型可以承载的 contexts。随后统一加入本模块基于当前一加 15 DSU AVC、服务拒绝和 Enforcing 热补丁复测整理的受控规则，以及已启用模块提供的策略片段与完整 SELinux bundle。

当前可选输入包括：

- 已安装的 `features/fix_displayfeature_bridge` 服务及其策略片段。
- `common/fix_mi_account` 完整交付的 mtd 策略与 contexts bundle。
- `common/fix_nfc` 验证过 NXP HAL 契约后交付的 ANR signal 策略 bundle。
- `features/fix_oplus_double_tap_wake` 完整交付的 TouchFeature bridge bundle。

bundle 注册表只声明可消费模块；目录和清单必须使用安全相对路径，并在解析后仍位于当前 `port` 与对应 bundle 目录内。只有 requirement 完整满足时才会启用。半套 requirement、未知 contexts 目标、缺失类型、同一逻辑目标内跨 bundle 的重复 key（转义形式视为同一 key）、非幂等结果或 normal/debug 结果不一致都会在落盘前失败。业务策略归各模块所有，不会下沉到通用 merger。

模块还会精确重标 MI-SF/DFPS 的 `vendor_display_prop` contexts，保留 qguard/BSG 标签处理，并同步 vendor/ODM 早期 contexts。删除 ODM 中旧 `precompiled_sepolicy*` 会迫使 init 基于当前 split CIL 重新编译完整策略。

当前 normal/debug 完整 split CIL 已按 Android 16 init 的开机参数静态编译通过；NFC 候选相对各自基线均只新增一条 signal allow，二次合并字节一致。额外启用 neverallow 的基线/候选对照只命中移植前已经存在的跨分区冲突，加入 NFC 片段前后的规范化诊断完全一致，也未命中账号或 TouchFeature bridge 新类型。账号、TouchFeature bridge 等新增独立域是否实际进入仍须在下一次 DSU 冷启动复核，不能仅凭静态合并结果视为实机确认。

## 执行顺序

应先安装会提供策略或 bundle 的业务模块，再执行统一入口：

```bash
bash port_main.sh common/fix_mi_account \
  common/fix_nfc \
  features/fix_displayfeature_bridge \
  features/fix_oplus_double_tap_wake \
  common/fix_vendor_avc
```

只传入实际适用于目标设备的业务模块。
