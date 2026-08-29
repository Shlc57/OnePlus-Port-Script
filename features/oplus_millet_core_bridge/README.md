# Millet 核心桥

将归档中的 `millet_core` 内核桥接模块接入本项目，并把 KernelSU 的加载逻辑转换为 vendor `init.rc`。KO 存放在普通可写的 `system_ext` 分区，不触碰 `system_dlkm` 或 `vendor_dlkm` 物理分区。

## 内容

- `src/`：归档中的 Millet 协议、网络唤醒、信号和 Binder hook 源码。
- `prebuilt/<KMI>/millet_core.ko`：按 KMI 目录保存的预编译模块。
- `config/init.millet_core.rc`：开机一次性加载模块并触发已有 `millet_monitor`。
- `config/selinux_policy.cil.in`：归档 `sepolicy.rule` 的项目 CIL 形式。
- `config/*contexts`、`config/*fsconfig`：新增 KO 与 init 脚本的打包 metadata。

KO 的最终路径是 `/system_ext/lib64/modules/millet_core.ko`。`/system/lib64/modules` 和 `/vendor/lib64/modules` 是分别指向 DLKM 物理分区的软链接，因此本补丁不会使用这两个路径；`apply.sh` 也会拒绝 `system_ext/lib64/modules` 目标目录中的符号链接。

## 使用

通过 `KMI` 选择预编译目录。当前一加 15 入口已经指定 DDK 标签 `android16-6.12`：

```bash
KMI=android16-6.12 \
bash port_main.sh features/oplus_millet_core_bridge common/fix_vendor_avc
```

`common/fix_vendor_avc` 必须在本模块之后执行，以便合并 CIL。`apply.sh` 不读取底包模块 hash、Build ID、vermagic 或其他外部文件身份信息；选择的 KO 只由仓库内 KMI 目录决定。

## 重新构建预编译模块

本模块使用本机 Docker DDK。`KMI` 的值同时作为 DDK target 和 `prebuilt/` 子目录名：

```bash
KMI=android16-6.12 bash build.sh
```

构建完成后，脚本只把 `millet_core.ko` 放入对应的 `prebuilt/<KMI>/`，不会写入外部内核身份信息。

## SELinux / init 说明

归档中的 `allow millet millet netlink_socket { getopt setopt }` 以及 init 从 `system_ext` 加载 KO 所需的 `vendor_init -> system_lib_file:system module_load` 规则，通过 `common/fix_vendor_avc` 的 bundle 机制合并；已有 `millet` 域、文件类型和 monitor 服务契约直接复用。KernelSU 的冲突探测、等待循环、卸载脚本和 live `magiskpolicy` 不再保留，默认启动条件成立时由 `init.millet_core.rc` 完成一次加载。
