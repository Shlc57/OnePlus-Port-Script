# SELinux bundle 交接契约

## 当前职责

`common/fix_mi_account` 拥有账号安全链的服务知识，包括：

- 哪些原包文件必须迁移；
- mtd、mtd_check、mtkeysoter 的 rc 与二进制完整性；
- 独立域 CIL；
- executable、`/data/vendor/images`、property 与 AIDL service contexts；
- 哪些 context 文件必须由下游统一更新。

`common/fix_vendor_avc` 只读取 bundle，验证目标是否完整存在，再将其中的 policy 与 contexts 纳入同一生成事务。它不重新解释 mtd 的 rc、接口或业务依赖。

## 清单格式

当前清单位于 `common/fix_mi_account/config/selinux_bundle.tsv`，每个有效行是三个 Tab 分隔字段：

```text
类型<TAB>目标<TAB>相对路径
```

支持：

- `require<TAB>project<TAB><项目相对文件>`：用于判断上游目标交付物是完整启用、完全未启用还是危险的半套状态；发现部分存在必须失败。
- `policy<TAB>vendor_policy<TAB><相对 fix_mi_account 目录的 CIL>`：加入 normal/debug vendor policy 的统一 managed block。
- `contexts<TAB><逻辑目标><TAB><相对 fix_mi_account 目录的片段>`：按 key 覆盖、全文件去重后写入目标。

当前 contexts 逻辑目标：

| 逻辑目标 | 最终文件 |
| --- | --- |
| `vendor_file_contexts` | `vendor/etc/selinux/vendor_file_contexts` |
| `precompiled_file_contexts` | `odm/etc/selinux/precompiled_file_contexts` |
| `odm_metadata_contexts` | profile 对应的最终 odm contexts |
| `vendor_property_contexts` | `vendor/etc/selinux/vendor_property_contexts` |
| `precompiled_property_contexts` | `odm/etc/selinux/precompiled_property_contexts` |
| `vendor_service_contexts` | `vendor/etc/selinux/vendor_service_contexts` |
| `precompiled_service_contexts` | `odm/etc/selinux/precompiled_service_contexts` |

清单、fragment 和 requirement 都必须是 bundle/project 内的普通文件，拒绝符号链接越界、未知目标、重复条目和不安全相对路径。

## 修改规则

新增服务依赖时，由拥有者补充 `require` 和自身验证；下游不得增加针对该服务的特例。新增 context 目标只有在统一入口确实支持对应生命周期和最终文件时才允许，且要同步扩展目标映射、测试和 README。

上游完成文件迁移后必须重新检查全部 requirement，并验证 rc 中的 service executable、AIDL interface、运行时目录创建等契约。下游写入前验证 context fragment 中每个类型已由生成后的 policy 声明；写入前后都验证 key 唯一、标签准确和再次合并不改变结果。
