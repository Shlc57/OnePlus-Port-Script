# 一加 15 修补脚本使用说明

本说明只适用于 `port/OP15_port.sh`。脚本会直接修改已经解包的分区目录，不负责解包、打包或刷机。

## 准备工作

1. 使用 Linux，并准备以下工具：Bash、Python 3、Java、Apktool、`zip`、`unzip`、`debugfs`、`e2fsck`、`resize2fs`、`truncate`、`patchelf`、`readelf`、`avbtool` 和 Android SDK Build Tools 中的 `zipalign`。其中 ext2 工具通常由 `e2fsprogs` 提供；`avbtool` 也可以使用工程工具目录中的版本。

   Ubuntu/Debian 可以先尝试：

   ```bash
   sudo apt update
   sudo apt install bash python3 default-jre apktool zip unzip zipalign e2fsprogs patchelf binutils
   ```

2. 先备份工程。脚本会原地修改文件，并在成功合并后删除 `mi_ext` 来源目录。

3. 使用 D.N.A 解包好分区，并确认目录结构如下：

   ```text
   DNA_hyper/
   ├── port/          # 本补丁目录
   ├── odm/           # 一加 15 底包
   ├── vendor/        # 一加 15 底包
   ├── product/       # 小米原包
   ├── system/        # 小米原包
   ├── system_ext/    # 小米原包
   ├── mi_odm/        # 小米原包的 odm
   ├── mi_vendor/     # 小米原包的 vendor
   ├── mi_ext/        # 小米原包的 mi_ext
   └── DNA_config/    # D.N.A 生成的 metadata
   ```

   首次运行时不要把 `mi_odm`、`mi_vendor` 或 `mi_ext` 当成最终分区覆盖到底包中。

4. `DNA_config/` 中必须保留上述各分区对应的 `{分区名}_contexts.txt` 和 `{分区名}_fsconfig.txt`。也支持 `config/`，对应文件名为 `{分区名}_file_contexts` 和 `{分区名}_fs_config`；两者同时存在时优先使用 `DNA_config/`。

5. 确认小米原包至少包含 `mi_odm/etc/build.prop`。脚本会在修改分区前自动识别底包与原包设备；一加 15 组合流程还会明确尝试合并额外配置 `mi_odm/etc/nezha_5.9.9.prop`，该文件不存在时只输出弱警告并忽略，不影响基础设备标识写入和后续补丁。

6. 一加 15 的其余显示/触控策略、NFC、线性触感、超声波指纹和双击亮屏硬件参数保存在 `port/devices/oneplus15/config/` 下的 `.props` 文件，由 `OP15_port.sh` 显式传给对应补丁；4 个刷新率数值属性和分辨率由 `common/fix_boot_refresh_rate` 自动读取底包显示栈生成，`display_odm.props` 与 `display_vendor.props` 中不维护这些值。更换底包或目标机型时应重新核对目标设备配置和底包显示能力，不能照搬旧列表。

7. 自动亮度模块通过 `PORT_TARGET_DISPLAY_ID` 接收目标设备的物理 Display ID。`OP15_port.sh` 默认使用当前一加 15 实机值 `4630946903293830803`；更换面板或底包时应使用实机 `dumpsys SurfaceFlinger --display-id` 的主屏结果覆盖该值。

8. `devices/oneplus15/fix_refresh_rate_switch` 复用 MISettings 的 DC/PWM 链路：关闭 Pro 时完整保留 60/90/120/144/165Hz，底层面板按刷新率使用 60–120Hz DC、144/165Hz PWM；开启 Pro 时保留原有 mode 20 全局 PWM 请求。补丁只保留 144/165Hz 与显式 DC 状态的既有互斥链路，移除 `mimotion_pwm_enable` 对列表和刷新率写入的过滤/120Hz 回退。该策略已完成主机静态迁移检查，真实设备仍需重启后验证 Pro 开关对应的面板调光结果。

9. `features/fix_displayfeature_bridge` 的 Xiaomi mode 20 会通过底包 `vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default` 设置 DC Alpha (`0x0e`) 与 PWM Turbo (`0xc7`)，每次请求显式关闭另一模式。该 AIDL/feature 映射已完成静态和主机交叉编译验证，面板 `0/1` 最终语义及 SELinux 冷启动仍待真实设备确认。

10. 组合流程会修补 `system_ext/lib64` 下两个 64 位音频策略库的 3+5 个 `appname` 参数发送调用点。补丁按 ELF、调用点及周边指令契约判断状态，不登记原包或修补后文件的固定哈希、尺寸、Build ID、时间戳或偏移；OTA 后若契约不再唯一匹配会安全失败，必须重新反汇编核对，不能直接套用旧坐标。

11. 组合流程还会直接重打包 `system/system/apex/com.android.bt.apex`，从当前 APEX 提取并轻量修改其 `libbluetooth_jni.so`，再注入项目自带的 LHDC V5 backend、wrapper 与 cold bridge；同时在 `system/system/build.prop` 幂等设置 `log.tag.BTAudioSessionAidl=S` 以压低重复日志。它不会使用工具包中另一 OTA 的 JNI，也不会生成 KSU/Mountify 覆盖；补丁只按动态结构和本次输入判定状态，不保存固定文件元信息。payload 会使用项目 `features/fix_lhdc/keys/com.android.bt.avb.pem` 重新生成 AVB hashtree/vbmeta/footer，并将对应公钥写入 `apex_pubkey`。这是预装 APEX 自洽通过 apeXd AVB 校验所需的最小信任变更，不改系统 CA 或 `apexkeys.txt`；外层 `META-INF` 与 APK v2/v3 Signing Block 会原样保留，以便 PMS 仍能识别 APK Signature Scheme v2；这些旧签名内容本身不重新生成，完整性校验可能失效。本轮只包含主机临时副本检查，不包含设备、apeXd、PMS、耳机播放或冷启动验证。

12. Millet 核心桥由 `features/fix_millet_core_bridge` 接入。`OP15_port.sh` 固定导出 `KMI=android16-6.12`，从仓库对应目录把预编译 KO 安装到普通 `system_ext/lib64/modules`，并把归档 KernelSU 的加载动作转换为 vendor `init.rc`；不会写入 `/system/lib64/modules`、`/vendor/lib64/modules` 所指向的 DLKM 物理分区，其 SELinux 规则随后由 `common/fix_vendor_avc` 统一合并。

## 电脑 Linux 使用方法

进入 `port` 目录，执行整套一加 15 修补脚本：

```bash
cd /你的路径/DNA_hyper/port
bash OP15_port.sh
```

不要直接运行各补丁目录中的 `apply.sh`。脚本遇到错误会立即停止；根据终端提示补齐缺失文件或工具后，再重新执行同一条命令即可。

如果 Apktool、`zipalign` 或 `avbtool` 没有加入 `PATH`，可以手动指定：

```bash
APKTOOL_JAR=/你的路径/apktool.jar \
ZIPALIGN=/你的路径/zipalign \
AVBTOOL=/你的路径/avbtool \
bash OP15_port.sh
```

## Termux 使用方法

Termux 理论上可以运行本脚本，但目前没有经过手机端完整流程验证。必须使用 Bash 显式启动，不能使用 `sh OP15_port.sh` 或 `./OP15_port.sh`。

1. 建议安装 F-Droid 或 GitHub 发布的新版 Termux，然后安装依赖：

   ```bash
   pkg update
   pkg install bash python openjdk-21 apktool aapt zip unzip coreutils diffutils findutils gawk grep sed e2fsprogs patchelf binutils
   ```

   Termux 的 `aapt` 包中已经包含 `zipalign`。

2. 如需读取手机存储，执行：

   ```bash
   termux-setup-storage
   ```

3. 将工程解包到 Termux 私有目录，例如 `$HOME/DNA_hyper`。不要直接在 `/sdcard`、`~/storage/shared` 或下载目录中运行，Android 共享存储不能可靠保留符号链接和文件权限。

4. 另行准备可执行的 `avbtool`，需要时通过 `AVBTOOL=/绝对路径/avbtool` 传入。然后检查依赖是否可用：

   ```bash
   command -v bash python3 java apktool zip unzip zipalign debugfs e2fsck resize2fs truncate patchelf readelf
   ```

   每项都能输出路径后，进入补丁目录运行：

   ```bash
   cd "$HOME/DNA_hyper/port"
   bash ./OP15_port.sh
   ```

Termux 下同样不要直接运行各目录中的 `apply.sh`。手机内存或剩余空间不足时，Apktool 处理大型 APK 可能失败。
