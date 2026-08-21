---
name: runtime-hot-patch
description: 在本项目已授权的 Android DSU 上规划、执行和验证运行时热修补。用于以 tmpfs + bind mount 临时替换分区文件、准确重载独立 HAL/init 服务或依赖 system_server 的 framework 组件，并用 ksud 依据 AVC 添加最小 SELinux live policy；不用于原系统写分区、永久 SELinux 策略合并或无授权设备操作。
---

# Runtime hot patch

把热修补当成短生命周期实验：先建立可恢复基线，缩小重载边界，验证后再把结论转为仓库补丁。运行时成功不能代替冷启动、metadata、签名或永久策略验证。

## 开始前

1. 阅读项目 `AGENTS.md` 的“真实设备调试与 DSU 约束”。检测到 adb 设备后，若本轮尚未取得明确授权，先请求授权；设备存在性探测是授权前唯一允许的设备检查。
2. 授权后确认唯一目标设备、root shell、DSU 与 Enforcing 状态：

   ```bash
   adb devices -l
   adb shell 'id; getprop ro.gsid.image_running; getprop ro.gsid.dsu_slot; getenforce'
   ```

   只有 `ro.gsid.image_running=1` 的 DSU 可直接热更新。原系统只允许提取文件。需要 root 时在已授权流程中使用 `adb root`；不要用 `su` 是否存在判断 adb root。
3. 在任何写入前记录目标文件的解析路径、类型、模式、owner、SELinux context、hash、挂载点、消费者 PID、init service 状态与 Binder/HIDL 服务状态。先保存验证前日志游标或时间戳。
4. 先确定停止条件与恢复路径。若实验可能导致 adb、zygote、SystemUI、显示或输入不可用，提前说明风险；重启设备永远需要用户再次同意。重载 framework 也可能经 crash loop/RescueParty 升级为硬重启，执行前要单独说明并取得确认。若存在掉出 DSU 的风险，询问用户是否要按项目约束预先设置下次单次 DSU 启动。

## 选择最小重载边界

- 普通配置由服务每次读取或支持显式 reload：只触发该接口，不重启进程。
- 独立 native/HAL 进程加载的二进制、库或配置：只重载其真实 init service；读取 [references/hal-reload.md](references/hal-reload.md)。
- APK/JAR/framework 资源、由 `system_server` 初始化或缓存的 Java 服务：读取 [references/system-server-reload.md](references/system-server-reload.md)。先确认是否有更小的 package/process/reload 边界；只有必须重建 framework 状态时才重启 zygote/framework。
- 在 `system_server` 进程中实现的 Binder 服务不是独立 init service。不要把 `service list` 中的 Binder 名传给 `setprop ctl.restart`。
- `hwservicemanager`、`servicemanager`、`vndservicemanager` 是注册中心，不是通用 HAL 刷新按钮；不要为加载单个补丁而重启它们。

## 替换文件

1. 所有 mount 源必须放在设备 `tmpfs`。不得从 `/data` 直接 bind mount；DSU 的 F2FS 在本项目中不适合作为热修补 mount backing。用 `mktemp -d` 建立专用目录，并验证其挂载类型：

   ```bash
   adb shell 'work=$(mktemp -d /dev/runtime-hot-patch.XXXXXX) && stat -f -c %T "$work" && printf "%s\n" "$work"'
   ```

2. 在 host 校验候选文件，再推入该目录。设备上校验普通文件、hash、ELF/APK/JAR 类型、ABI/依赖，并从目标复制 mode/owner/context；不要凭扩展名猜 metadata。
3. 不覆盖底层只读分区文件。对解析后的单个目标执行 bind mount，并立即用 `/proc/self/mountinfo`、hash 和 context 复核：

   ```bash
   adb shell 'mount --bind /dev/runtime-hot-patch.XXXXXX/candidate /resolved/target'
   ```

   只有本轮明确验证过的具体路径可作为 mount target；不要用通配符或宽泛目录。若目标本身是 symlink，先解析并确认真实文件。
4. 先 mount、再重载消费者。恢复时先停止消费者（若它会持续访问文件），卸载该精确目标，再按原状态启动并复验。不要删除仍被 zygote/system_server 持有的 idmap、APK 或 JAR；需要替换缓存文件时用同目录原子替换，保持 inode/FD 生命周期安全。
5. 新增路径、rc、service context、fsconfig 或永久 SELinux policy 不能靠 bind mount 证明最终打包正确；这些仍要回到项目补丁和 metadata 流程验证。

## SELinux 临时豁免

遇到 AVC 时读取 [references/ksud-selinux.md](references/ksud-selinux.md)。保持全局 Enforcing，只根据实际 `scontext`、`tcontext`、`tclass` 和权限添加最小 allow。先用 `ksud sepolicy check` 验证语法，再 `patch`/`apply`；不得以 `setenforce 0`、wildcard allow、整域 permissive、`dontaudit` 或盲目 `audit2allow` 代替分析。

注入前先确认同一个被拒绝操作能在当前启动中安全重放。发生在 `adb`/`ksud` 可用前、只执行一次的早期启动路径，或依赖开机装载新类型、contexts、标签和 domain transition 的拒绝，不能用启动后的 live policy 判定永久补丁是否有效；停止该热测分支，转交 `$android-selinux-port-policy` 做完整策略静态验证并保留干净冷启动确认。能够独立重放的下游行为仍可热测，但只能作为局部证据。

当前 DSU 与原系统不共享 `/data`；只探测当前 DSU 的 `ksud`。若当前环境没有可执行的 ksud 或该版本没有 `sepolicy` 子命令，报告阻塞并停止该分支，不要从 host APK 临时抽取陌生 `ksud` 到设备执行。

## 验证与交付

至少验证以下事实，并区分“已观察”与“未验证”：

- 新 PID/启动时间或明确 reload 证据，init 状态稳定为预期值；
- 预期 AIDL/HIDL/Binder 实例重新注册且接口调用成功；
- 日志中没有 crash loop、linker/ABI 错误、新 AVC、watchdog/ANR；
- 用户可见功能按最短复现步骤验证；需要交互时直接请用户操作并返回现象；
- 恢复路径可执行，或明确说明临时 bind mount / ksud live policy 需重启清除；
- 最终仓库改动仍满足 contexts/fsconfig、CIL、签名、完整性和冷启动要求。

交付中列出设备/DSU/Enforcing 状态、替换路径、重载的 init service（不要只写进程名）、SELinux 规则、验证证据、恢复方式，以及是否只做了运行时验证。未经冷启动确认的结论不得写成永久补丁已生效。

若 adb 中途断开或设备重新枚举，首先重新检查 serial、`adb devices -l`、boot ID、boot mode 和 `ro.gsid.image_running`。只要设备已进入 recovery/原系统，就立即停止所有写操作；不得把“设备重新连上”误判为仍处于可热修补的 DSU。
