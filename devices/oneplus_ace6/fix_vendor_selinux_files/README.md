# Ace 6 vendor SELinux 基础设施补齐（devices/oneplus_ace6/fix_vendor_selinux_files）

## 背景

Ace 6 底包 vendor 分区缺 `genfs_labels_version.txt` 与 `plat_sepolicy_vers.txt`
（ColorOS 部分版本不生成这些文件），`common/fix_vendor_avc` 的 `check_file_exists`
硬性要求两者存在 → FAIL。

## 方案（已内置，不依赖外部工程）

两个版本号文件经实机验证固化为 `202504`，**直接内置在本模块 apply.sh 中**写入：

| 文件 | 内置内容 | 说明 |
| --- | --- | --- |
| `plat_sepolicy_vers.txt` | `202504` | vendor sepolicy 基线版本，与原包（mi_vendor）一致 |
| `genfs_labels_version.txt` | `202504` | genfs 标签格式版本；必须与 plat 同值，否则 init 解析 policy 启动失败（实测 Ace 6 DSU 一屏后 fastboot） |

两者同值后，底包与原包 SELinux 版本标记一致，`common/fix_vendor_avc` 的
`--allow-version-mismatch` 跨 ABI 降级分支在 Ace 6 上不再触发（逻辑保留作保险）。

## 使用

- 应排在 `common/fix_vendor_avc` 之前运行
- 幂等：文件已存在时跳过，不覆盖底包或前次补丁的值
- 写入后校验两文件同值且为纯数字；已存在但为空、为符号链接或非普通文件时失败
- 无外部依赖（参考工程早期的 `ACE6T_PROJECT` 环境变量方案已废弃）

## 6T 底包是否需要？

**不需要。** 参考工程只在 Ace 6（sun 底包）流程使用本补丁；Ace 6T（canoe 底包）
的 vendor 分区自带这两个版本标记文件，不缺失，无需加入 Ace 6T 组合流程。
即使误加到其他流程，文件已存在时本补丁也会自动跳过（幂等、无副作用）。

## 其他缺失文件

若 `fix_vendor_avc` 仍报缺其他文件（如 `plat_pub_versioned.cil`），说明底包 vendor
解包不完整或版本特殊，需手动从底包重新解包；**不要**从其他机型复制平台专属文件
（`vendor_sepolicy.cil`、`plat_pub_versioned.cil`、`vendor_file_contexts` 等，
Ace 6=sun / 6T=canoe，复制会破坏 ABI 合并）。
