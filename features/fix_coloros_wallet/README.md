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

## 依赖与限制

- 镜像侧不修改任何钱包 APK（签名红线：eSE ARA-M 与 TSM 服务端均校验原始签名）。
- 进程内兼容走**无 LSP 路线**：身份由底包 odm/vendor 原生真值满足（cuptsm/prjname 等），
  NFC eSE 路由与 SecureElement 白名单按需固化进系统 APK（Nfc_st.apk / com.android.se，
  无签名约束），钱包初始化由伴生脚本完成；详见设计文档 §6。
- eID 卡功能为后置项（无 LSP 路线下桥选择依赖平台签名推断，预期不可用）。
- 本模块不改 `odm`/`vendor`；NFC HAL 服务契约由 `features/fix_nci_nfc`（NXP 栈机型）负责。
