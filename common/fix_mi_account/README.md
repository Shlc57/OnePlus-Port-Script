# 补齐小米账号、支付与安全环境资源

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 从 `mi_odm` 按清单复制资源，并转换、合并 ODM contexts 与 fsconfig。 |
| `vendor` | 从 `mi_vendor` 按清单复制资源，并转换、合并 vendor contexts 与 fsconfig。 |

`mi_odm`、`mi_vendor` 只作为原包来源，不是最终分区。

## 模块说明

模块按 `config/mi_odm_sources.tsv` 与 `config/mi_vendor_sources.tsv` 动态提取账号、支付及安全环境资源，把源路径和 metadata 转换到真实的 `odm`、`vendor` 目标。来源目录、清单文件、contexts 或 fsconfig 权限条目缺失时会在首次写入前失败，不回退到模块内二进制载荷。

模块同时维护 mtd、mtd_check、mtkeysoter 的二进制与 rc 完整性契约，并在本目录中提供三个独立域的最小 CIL，以及 executable、`/data/vendor/images`、精确 property 和 AIDL service contexts bundle。`apply.sh` 不直接修改最终 vendor policy；它只要求当前文件交付形成完整 bundle，随后由 `common/fix_vendor_avc` 在同一事务中统一合并 normal/debug vendor CIL 与七类 contexts 目标。

2026-08-21 在一加 15 DSU 的 Enforcing 复现中，手动启动 one-shot `vendor.mtd_check` 会稳定命中 `hal_mtdservice_check -> self:qipcrtr_socket create`，并触发 updatable-crashing；本模块因此只为该独立域补充 `create` 权限。设备当时没有可执行的 `ksud` userspace，无法临时注入规则验证修复后行为；永久 CIL 仍需下一次未污染 DSU 冷启动确认。

半套 requirement、未知目标、缺失类型、重复 key、内容不匹配或非幂等结果都会失败。DisplayFeature 显示链由独立桥模块处理。

## 执行顺序

```bash
bash port_main.sh common/fix_mi_account common/fix_vendor_avc
```

如果由组合入口分步调用，必须保证 `common/fix_vendor_avc` 位于本模块之后。
