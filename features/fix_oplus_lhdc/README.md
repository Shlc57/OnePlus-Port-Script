# Bluetooth APEX LHDC V5 注入

本特性补丁把用户提供的 LHDC V5 backend、wrapper 和 cold bridge 整理成 Bluetooth APEX 补丁。它不生成 Mountify 模块，而是在临时目录中重打包并通过 `replace_file_if_different` 原子替换：

```text
system/system/apex/com.android.bt.apex
```

同时，模块会在原包 `system/system/build.prop` 中幂等写入 `log.tag.BTAudioSessionAidl=S`，压低 `GetPresentationPosition` 的重复日志；该属性步骤与 APEX 重打包独立，目标属性文件不存在时只警告并跳过。

## OTA 输入契约

模块不保存或依赖原始/输出 APEX、`apex_payload.img`、`libbluetooth_jni.so` 或三份自带库的 SHA-256、固定尺寸、固定 Build ID、时间戳、完整成员快照或二进制文件偏移。因此 OTA 更新后不会只因非语义文件身份变化而失败。

每次执行都从当前 APEX 动态检查：

1. ZIP 中不存在重复成员名；`apex_payload.img`、`apex_pubkey`、`AndroidManifest.xml`、`apex_manifest.pb` 及 `META-INF/MANIFEST.MF` 都存在，且 `META-INF` 中至少有一组同名 `.SF` 与 `.RSA`/`.DSA`/`.EC` 签名块。签名别名和其余成员可随 OTA 变化，并按本次输入顺序保留。
2. payload 是带 AVB footer 的 ext 文件系统，且 `/lib64/libbluetooth_jni.so` 是 AArch64 ELF。
3. JNI 中与 `source/lhdc_cold.cpp` 完全相同的 LHDC V5 stub cluster 恰好命中一次，对应的 8-slot interface table 也恰好命中一次。无法证明 cold bridge 的运行时扫描可唯一定位时安全拒绝。
4. 原始状态必须是 JNI 不含 `DT_NEEDED libop13_lhdc_cold.so`，且三份注入库全部不存在。
5. 完成状态必须是三份注入库全部存在，与本次模块输入即时逐字节相同，且 ELF/ABI 结构、SONAME、依赖、必要导出、uid/gid、模式和 SELinux xattr 均正确；JNI 恰好含一个 cold bridge `DT_NEEDED`。该比较不生成或保存摘要、尺寸等身份值。任何局部、混合或未知状态都拒绝，不尝试覆盖修复。

原始状态下，只为从当前 payload 提取的 JNI 副本添加一个 `DT_NEEDED libop13_lhdc_cold.so`。`patchelf` 前后都会重新验证 V5 stub、interface table、SONAME 与 `DT_NEEDED` 依赖，确认 ABI 和依赖契约仍成立；不读取或比较底包 ELF 的 Build ID。

补丁使用 `keys/com.android.bt.avb.pem` 中的项目 AVB RSA-4096 私钥。每次重打包都会重新生成 payload 的 hashtree、vbmeta 和 footer，并把同一私钥导出的二进制公钥写入 APEX 的 `apex_pubkey`。私钥是项目资源，不是原包或输出文件的身份元信息；应限制其访问权限，不要上传到公开仓库。

## 模块自带载荷

模块提供 `/lib64/liblhdcv5.so`、`/lib64/liblhdcv5BT_enc.so` 和 `/lib64/libop13_lhdc_cold.so`，但不为它们登记文件身份。每次执行都要求它们是普通的 little-endian ELF64 AArch64 shared object，SONAME 与文件名一致，`DT_NEEDED` 无重复或路径项，且没有动态 `libstdc++.so` 或 `libc++_shared.so` 依赖。

core 必须导出 wrapper 实际消费的关键 `lhdcv5_util_*` 接口；wrapper 必须恰好依赖一次 `liblhdcv5.so` 并导出 cold bridge 动态加载的十个 `lhdcv5BT_*` 接口；cold bridge 必须导出两个诊断 JNI 入口。cold bridge 源码和 NDK makefile 保存在 `source/`，本轮使用 zip 中的预编译库。

四个最终库都会设置为 uid/gid `1000:1000`、模式 `0644`，并写入包含结尾 NUL 的 `u:object_r:system_lib_file:s0` xattr；补丁不固定 inode 时间字段。

## payload 与签名边界

写入前会先用 `avbtool erase_footer` 动态得到当前 OTA 的 ext 文件系统长度。ext 文件系统临时扩容 16 MiB，执行 `unshare_blocks`、写入和 fsck 后，再用项目私钥通过 `avbtool add_hashtree_footer` 生成新的 sha256 hashtree、RSA-4096 vbmeta 与 footer；不保留旧 AVB 尾部。

对预装 APEX，apeXd 启动时从同名预装包的 `apex_pubkey` 取得期望公钥，再校验 payload vbmeta 的签名和公钥字节。因此这里不修改系统 CA、`apexkeys.txt` 或其他全局 trust store，而是把 `apex_pubkey` 替换为项目私钥对应的公钥。这是让同一个预装包自洽通过 apeXd AVB 校验所需的最小信任变更。

外层 ZIP 中 `apex_payload.img` 与 `apex_pubkey` 会被替换；成员顺序、`META-INF` 和其余成员内容保持不变。输入 APEX 的 APK v2/v3 Signing Block 也会原样回插并逐字节校验。`META-INF` 的 JAR 签名和 Signing Block 内签名不会重新生成，仍是旧签名材料；修改 payload 后这些签名的内容完整性校验可能失效，但 PMS 至少仍能识别 v2/v3 签名方案。本补丁的启动验证目标是 payload AVB，不能据此宣称外层 APK/JAR 签名有效。

## 工具与功能边界

主机需要 Python 3、`debugfs`、`e2fsck`、`resize2fs`、`truncate`、`patchelf`、`readelf`、`avbtool`、`zipalign`，以及项目内的 `common/apk_signing_block.py`。可通过 `AVBTOOL`、`ZIPALIGN` 指定后两项。目标 APEX 不存在时按替换语义警告并跳过；输入缺少有效 APK Signing Block 时会在写入工程树前停止，因为 PMS 会直接报 `No APK Signature Scheme v2 signature`。

该载荷只补齐 Bluetooth APEX 内的 LHDC V5 软件编码 bridge/backend。它不自动补齐或证明最终 `vendor` 的 Android 17 AIDL Audio HAL、PAL、resource manager、usecase 和 audio policy LHDC 全链路，也没有证据支持新增 SELinux allow。

## 验证边界

`tests/test_contract.py` 在主机临时目录中验证当前 APEX 的原始到完成状态转换、完成状态幂等、任意附加外层成员按顺序保留、重复成员拒绝、动态 V5 ABI 契约、混合状态拒绝，以及三份模块载荷的结构契约。测试还确认不影响 ELF 结构的尾部字节变化不会被当作文件身份不匹配；测试与报告不登记文件哈希、尺寸、Build ID、时间戳或固定偏移。

这些检查不是设备运行、Enforcing、`apexd` 加载、PMS 证书扫描、LHDC 耳机播放或冷启动验证。用户已明确本轮无需额外运行验证，因此没有真实设备生效结论。
