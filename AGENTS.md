# AGENTS.md

本文件适用于 `port/` 及其全部子目录。后续修改应以当前仓库实现为准；如用户给出更具体要求，以用户要求优先。

## 项目定位

这里维护 HyperOS 移植补丁模块，不是通用刷机脚本集合。修改目标是让补丁在明确的来源分区、目标分区和元数据约束下可重复执行，并尽量在写入工作树前暴露错误。

- `common/<patch>/apply.sh`：可组合使用的共享补丁，但不代表适用于所有设备。
- `devices/<device>/<patch>/apply.sh`：依赖指定设备硬件或底包的补丁。
- `auto_port.sh`：补丁发现、选择和隔离执行入口。
- `1+15_port.sh`：一加 15 当前组合流程。
- `tools.sh`：Shell 公共接口、配置模板和安全文件操作。
- `partition_metadata.py`：contexts/fsconfig 的复杂处理工具。

不要把设备专属逻辑下沉到通用工具，也不要把共享能力复制到多个补丁中。

## 只维护当前版本

- 不为旧版脚本、旧函数名、旧环境变量或历史文件命名增加兼容层。
- 不扫描任意 `*_config` 目录，也不增加旧名称自动回退；只支持 `tools.sh` 明确定义的配置 profile。
- 删除或重命名公共接口前，先用 `rg` 检查仓库内全部调用方，并在同一改动中完成迁移。
- 发现当前实现、README 和生成数据不一致时，不要静默兼容；应统一当前规范或明确报告冲突。

## 配置目录与名称模板

配置目录优先级和名称模板必须集中定义在 `tools.sh`，补丁内不得自行拼接 contexts/fsconfig 文件名。当前代码定义为：

| 配置目录 | contexts 模板 | fsconfig 模板 |
| --- | --- | --- |
| `DNA_config` | `{part}_contexts.txt` | `{part}_fsconfig.txt` |
| `config` | `{part}_file_contexts` | `{part}_fs_config` |

两者同时存在时优先 `DNA_config`。如果后续调整模板，必须同时更新 `tools.sh`、README、本文档和相关测试。

补丁必须通过以下接口取路径：

- `get_config_path`
- `get_part_contexts_path`
- `get_part_fsconfig_path`

不得在补丁中硬编码 `DNA_config`、`config` 或具体 metadata 文件名。

## 分区语义

- `odm`、`vendor` 是底包的最终目标工作树。
- `product`、`system`、`system_ext` 是原包的最终目标工作树。
- `mi_odm`、`mi_vendor` 仅是额外来源目录，必须分别映射到最终 `odm`、`vendor`，不能成为最终分区名。
- `mi_ext` 由专用补丁合并到真实目标路径，不能把整个来源分区直接当作最终产物。
- contexts 路径以 `/` 开头；fsconfig 路径不以 `/` 开头。
- 注意工程中的 system 文件树通常位于 `system/system/...`，metadata 路径也必须与真实打包路径一致。

任何跨分区复制或迁移都必须同时检查文件路径、contexts 和 fsconfig 的来源与目标映射。

## 补丁实现规则

- `apply.sh` 由 `auto_port.sh` 加载，不要在每个补丁中重复 `source tools.sh`。
- 补丁开头调用 `init_port_env "${1:-}"`，并根据复杂度启用 `set -euo pipefail` 或等价严格模式。
- 先完成依赖、来源文件、目标分区、metadata 和外部工具校验，再开始修改工作树。
- 补丁应可重复执行：已经完成的状态应安全跳过或得到相同结果，不能不断追加重复条目。
- 使用 `std_print`、`skip_print`、`err_print` 输出简洁中文状态，不输出无意义调试噪声。
- 临时文件必须使用 `mktemp`，并通过 `trap` 或明确清理路径回收。
- 优先使用 `tools.sh` 中已有的安全操作函数，不要重复实现复制、替换、属性合并或受控删除逻辑。
- 删除项目文件必须使用 `remove_path_if_exists`；不得使用宽泛变量、未解析 glob 或面向项目根目录的递归删除。
- 不要修改与当前补丁目标无关的分区内容。

## contexts 与 fsconfig

复杂 metadata 逻辑放在 `partition_metadata.py`，Shell 仅保留参数准备和薄封装。不要重新用大段 awk/sed 实现同一套合并、迁移或去重算法。

必须遵守以下规则：

- 补丁条目按路径覆盖目标旧条目。
- 修改 metadata 时对整个目标文件按路径去重。
- contexts 比较路径时忽略反斜杠转义差异，但写回时保留最终选中条目的原始表达形式。
- 注释和空行不是路径条目，不应因为路径去重而被吞掉。
- 按文件清单迁移时，清单内每个文件都必须同时存在 contexts 与 fsconfig 来源条目；缺少任何一项应在复制前失败。
- 按目录前缀迁移时，同时迁移 contexts 与 fsconfig，并处理 contexts 常见的 `(/.*)?` 等目录正则形式。
- 删除文件或目录时，同步删除该路径及子路径的 contexts/fsconfig 条目。
- 仅修改既有文件内容且不改变路径、所有者、权限或能力字段时，通常不需要改 fsconfig。
- 新增文件、跨分区复制文件、创建符号链接或新目录时，必须补齐最终分区 fsconfig；需要 SELinux 路径时同时补齐 contexts。
- 新生成的二进制、APK、RC 或配置文件不得依赖打包工具猜测权限。
- metadata 写回应保留目标文件模式，并使用原子替换；不要直接截断后原地拼接。

## Shell 规范

- 所有变量展开默认加双引号，数组使用 `"${array[@]}"`。
- 路径参数先验证，再交给 `cp`、`mv`、`chmod`、`find` 等命令，并使用 `--` 分隔选项。
- 搜索文件和文本优先使用 `rg` / `rg --files`。
- 不使用 `eval`，不依赖不受控的命令替换来生成删除或覆盖目标。
- 不覆盖 `HOME`、`PATH` 等通用环境变量作为临时状态。
- ShellCheck 抑制必须靠近对应代码，并注明原因；不要用全文件关闭掩盖新问题。
- 对全局变量或由 `init_port_env` 注入的变量，保持命名一致，不在局部重新定义含义不同的同名变量。

## Python 规范

- `partition_metadata.py` 优先使用 Python 标准库，不为简单 metadata 操作增加第三方依赖。
- CLI 错误输出到 stderr，并返回非零状态；不要打印 Python traceback 作为正常用户错误。
- 路径、manifest、分区映射和输出目标必须在写入前验证。
- 保持操作确定性：相同输入应生成顺序稳定的相同输出。
- 测试或检查时设置 `PYTHONDONTWRITEBYTECODE=1`，不要把 `__pycache__`、`.pyc` 或临时输出留在仓库。

## 文档同步

以下变化必须同步更新 README：

- 配置目录优先级或文件名模板。
- 新增、删除或重命名补丁。
- 补丁所需来源分区、目标分区或外部依赖。
- 补丁新增的 contexts/fsconfig 迁移、权限写入或清理行为。
- 已知的设备限制、签名影响或刷机后才能确认的行为。

不要把未经设备验证的结论写成已经确认生效。

## 最低验证要求

修改 Shell、Python 或 metadata 逻辑后，至少执行：

```bash
git diff --check
rg --files -g '*.sh' -0 | xargs -0 -n1 bash -n
PYTHONDONTWRITEBYTECODE=1 python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("partition_metadata.py").read_text(encoding="utf-8"))'
```

修改过的 Shell 脚本还应运行 ShellCheck。对 `SC2016`、`SC2154` 等确有意图的情况，只允许有依据地局部处理。

metadata 改动还应覆盖以下行为测试：

- `DNA_config` 与 `config` 两套 profile 的检测、优先级和文件名生成。
- contexts/fsconfig 补丁覆盖和重复路径去重。
- contexts 转义路径匹配。
- manifest 迁移、目录前缀迁移和源条目缺失失败。
- 删除路径及子路径条目。
- 写回后目标文件模式保持不变。

可以使用临时工程做集成测试。除非用户明确要求，不要为了验证直接在真实解包分区树上执行整套移植补丁；交付时必须说明验证是静态检查、临时工程测试还是真实分区执行。

## 工作区约束

- 修改前先查看 `git status --short` 和相关文件 diff，保留用户已有改动。
- 不清理、不回滚、不格式化与当前任务无关的文件。
- 不生成提交、分支或推送，除非用户明确要求。
- 交付前再次检查 `git diff --check`、未跟踪临时文件和 Python 缓存。
