此目录用于存放目标机型底包的钱包五件套预置产物（由使用者从底包 system.img 提取）：

    system/app/FinShellWallet/    # FinShellWallet.apk + lib/arm64/*.so
    system/app/TasWallet/         # TasWallet.apk + lib/arm64/*.so
    system/app/UPTsmService/      # UPTsmService.apk + lib/arm64/*.so
    system/app/HeytapHTMS/        # HeytapHTMS.apk + lib/arm64/*.so
    system_ext/app/EidService/    # EidService.apk

要求：

- 保持 ColorOS 底包原始布局与文件名（app/<App>/<App>.apk）。
- 不得修改、重签名 APK；来源树中不允许出现符号链接。
- 五件套任一缺失时，模块整体跳过安装（不部分安装）。
