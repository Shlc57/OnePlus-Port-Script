# 补齐小米账号、支付与安全环境资源

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 从 `mi_odm` 按清单复制资源，并转换、合并 ODM contexts 与 fsconfig。 |
| `vendor` | 从 `mi_vendor` 按清单复制资源，并转换、合并 vendor contexts 与 fsconfig。 |

`mi_odm`、`mi_vendor` 只作为原包来源，不是最终分区。

## 模块说明

模块按 `config/mi_odm_sources.tsv` 与 `config/mi_vendor_sources.tsv` 动态提取账号、支付及安全环境资源，把源路径和 metadata 转换到真实的 `odm`、`vendor` 目标。来源目录、清单文件、contexts 或 fsconfig 权限条目缺失时会在首次写入前失败，不回退到模块内二进制载荷。

模块同时维护 mtd、mtd_check、mtkeysoter 的二进制与 rc 完整性契约，并在本目录中提供三个独立域的最小 CIL，以及 executable、`/data/vendor/images`、精确 property 和 AIDL service contexts bundle。账号安全链已拥有原包 `vendor_deviceid_prop`，因此这里同时恢复 `persist.vendor.radio.imei`、`persist.vendor.radio.meid`、`persist.vendor.eid.record` 与对应只读 OEM 标识键，并允许 `rild` 按原包契约读写该类型；不使用宽泛 `persist.vendor.radio.` 前缀或 `vendor_default_prop`。`apply.sh` 不直接修改最终 vendor policy；它只要求当前文件交付形成完整 bundle，随后由 `common/fix_vendor_avc` 在同一事务中统一合并 normal/debug vendor CIL 与七类 contexts 目标。

2026-08-21 在一加 15 DSU 的 Enforcing 复现中，手动启动 one-shot `vendor.mtd_check` 会稳定命中 `hal_mtdservice_check -> self:qipcrtr_socket create`，并触发 updatable-crashing；本模块因此只为该独立域补充 `create` 权限。设备当时没有可执行的 `ksud` userspace，无法临时注入规则验证修复后行为；永久 CIL 仍需下一次未污染 DSU 冷启动确认。

2026-08-22 的 Enforcing DSU 中，`*#06#` 入口无法取得 IMEI，而 Permissive 下正常。电话、设备标识与 radio 服务均已注册，当前内核没有 `radio`/`rild` AVC；原包策略对照确认目标缺少上述精确 property contexts，以及 `rild -> vendor_deviceid_prop` 的读写权限，相关属性在当前启动中均为空。由于 property contexts 与电话进程启动缓存不能在当前启动中等价重载，本修补仅完成静态固化，仍须下一次未污染 DSU 软重启验证 IMEI。

半套 requirement、未知目标、缺失类型、重复 key、内容不匹配或非幂等结果都会失败。DisplayFeature 显示链由独立桥模块处理。

## 执行顺序

```bash
bash port_main.sh common/fix_mi_account common/fix_vendor_avc
```

如果由组合入口分步调用，必须保证 `common/fix_vendor_avc` 位于本模块之后。
