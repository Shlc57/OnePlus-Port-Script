# 回退到 system_dlkm 的 zram 模块

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `vendor` | 仅修改 `bin/vendor_modprobe.sh` 的 blocklist。 |

`gki.modprobe` 会先加载 `/system_dlkm/lib/modules`，随后 `vendor.modprobe` 才处理 `/vendor_dlkm/lib/modules`。本模块在 vendor 脚本中屏蔽 `zram` 和 `zsmalloc`，因此 vendor_dlkm 中的同名模块不会再次加载，实际使用 system_dlkm 已有的正常版本。

同时保留并幂等补齐以下 Oplus 优化模块拦截：

```text
oplus_bsp_hybridswap_zram
oplus_bsp_zram_opt
oplus_bsp_fg_protect
oplus_exit_mm_optimize
oplus_bsp_zsmalloc
```

本方案不再安装固定 `zram.ko`，不修改 `vendor_dlkm`，不使用 bind mount，也不需要新增 SELinux mount 权限。

## 执行

```bash
bash port_main.sh devices/oneplus15/fix_zram_module
# 一加 15 完整流程会自动执行该模块
bash OP15_port.sh
```

重复执行不会重复追加 blocklist 条目。最终能否加载 system_dlkm 的 `zram.ko` 仍取决于该分区确实包含可用模块及其 `zsmalloc` 依赖。
