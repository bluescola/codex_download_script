# 脚本系统维护决策

本文记录三平台 Codex 安装脚本的维护决策、原因和废弃方案。后续修改脚本时，先确认是否会破坏这里的约束。

## 目标边界

- 安装包面向普通用户，优先使用当前用户目录，不要求管理员或 root 权限。
- 三个平台都要能重复运行，重复运行不应破坏用户已有配置。
- Codex CLI、CRS 配置和 NO_PROXY 配置是同一条安装链路中的关键结果。
- 维护文档描述脚本系统边界；安装包内 README 只保留入口、行为摘要、参数和维护链接。

## Linux：使用 nvm LTS

决策：Linux 安装脚本使用 `nvm install --lts`、`nvm use --lts` 和 `nvm alias default 'lts/*'` 管理 Node.js/npm，并把 Codex 安装到 nvm Node.js 的 npm prefix 下。

原因：

- 发行版包管理器里的 Node.js 版本差异大，Debian/Ubuntu/RHEL/Arch 等分支无法用一套命令稳定覆盖。
- nvm 是用户级安装，不需要 `sudo npm install -g`，能避开系统目录权限和全局包污染。
- Codex 安装路径可以被限定在 `NVM_DIR` 下，脚本能拒绝安装到系统 prefix，降低误删和覆盖风险。
- 非 ASCII HOME/TMPDIR 场景下，脚本可以切换到 `/var/tmp/codex-<uid>` 作为 ASCII-safe 根目录，并同步设置 `CODEX_HOME`。

废弃方案：

- 废弃用 `apt/yum/dnf/pacman` 直接安装 Node.js 作为主流程。
- 废弃 `sudo npm install -g @openai/codex`。
- 废弃长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE` 到 shell rc 的方案。
- 废弃旧版 `# >>> codex user paths >>>` PATH 注入块；当前脚本会清理。

## macOS：使用 Homebrew node@24

决策：macOS 安装脚本使用 Homebrew `node@24` 作为目标 Node.js/npm 来源，Codex 只允许安装在 `brew --prefix node@24` 下的 npm prefix。

原因：

- macOS 默认 shell、Homebrew 路径和 Apple Silicon/Intel 前缀差异可由 `brew --prefix node@24` 统一解析。
- `node@24` 是明确的 LTS 线，避免 `node` formula 随上游主线变化带来的行为漂移。
- Homebrew 是 macOS 用户普遍接受的用户级工具链，适合安装 npm 全局包。
- 脚本可以检查 npm prefix 是否位于 `node@24` 前缀下，并在 prefix 不可写时明确失败。
- 因为 `node@24` 是 keg-only，脚本只持久化一个专用 PATH 块，把 `node@24/bin` 去重后置顶，不恢复旧版 npm prefix 环境变量方案。

废弃方案：

- 废弃使用系统自带 Node.js 或随机 PATH 中 Node.js 作为最终安装目标。
- 废弃通过 nvm 管理 macOS 主流程；macOS 统一交给 Homebrew。
- 废弃 `sudo npm install -g @openai/codex`。
- 废弃长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE` 到 zsh/bash profile。

## Windows：ASCII-safe 与显式 npm 参数

决策：Windows 脚本检测 `USERPROFILE`、`APPDATA`、`LOCALAPPDATA`、`TEMP`、`TMP` 是否含非 ASCII 字符；需要时切换到 `C:\Codex` 或 `CODEX_WINDOWS_ASCII_ROOT`。安装 Codex 时显式使用：

```powershell
npm install -g --prefix <CodexNpmPrefix> --cache <CodexNpmCache> @openai/codex
```

原因：

- Windows 上 Node/npm/Codex 原生可执行文件更容易受中文用户名、空格、特殊字符、临时目录编码影响。
- `--prefix` 和 `--cache` 只约束本次 npm 调用，不污染用户全局 npm 配置。
- ASCII-safe 根目录同时承载 npm prefix、npm cache、临时目录、`CODEX_HOME` 和用户级 Node.js zip 安装目录，排查路径问题更直接。
- 脚本会将 Codex npm bin 目录写入用户 PATH，并优先检查 `codex.cmd`，降低 PowerShell `codex.ps1` 执行策略造成的误判。

废弃方案：

- 废弃长期设置用户级或机器级 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE`。
- 废弃依赖系统级 Node.js 安装目录作为 Codex 全局包目标。
- 废弃在系统 npm prefix 中直接覆盖 Codex；检测到系统级 Codex 时默认只告警，只有显式参数才移除。
- 废弃默认要求管理员权限安装 Node.js 或 Codex。

## 不长期写 NPM_CONFIG_*

决策：安装脚本可以在单次命令中显式指定 npm prefix/cache，但不应长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE`。

原因：

- 长期环境变量会影响用户后续所有 npm 命令，导致其他 Node.js 项目安装位置异常。
- 多个 Node 管理器并存时，长期 prefix 会覆盖工具自己的 prefix 解析。
- 删除长期变量后，Linux/macOS 由 nvm/Homebrew 决定 prefix，Windows 由显式 `--prefix` 决定本次安装目标。

维护要求：

- 新增 npm 调用时优先使用显式参数或当前 Node 管理器默认 prefix。
- 如果发现旧版 profile 中存在 `NPM_CONFIG_PREFIX` 或 `NPM_CONFIG_CACHE`，应继续清理。
- 不要把 npm 配置写入 `.npmrc` 作为安装脚本的持久副作用。

## 统一 preflight

决策：三平台脚本都应在写配置、安装 Codex、修改 PATH 前先完成 preflight。当前已落地为各平台内部函数，后续维护时应保持同一检查顺序和语义。

统一检查顺序：

1. 平台检查：Linux 检查 `uname -s = Linux`；macOS 检查 `uname -s = Darwin`；Windows 检查 PowerShell 运行环境。
2. 权限检查：Linux/macOS 拒绝 root；Windows 主流程不默认要求管理员。
3. ASCII-safe 检查：Windows 必须检查；Linux/macOS 在 HOME/TMPDIR 含非 ASCII 时切换用户级安全根目录。
4. 既有安装检查：识别 Node/npm/Codex 是否可用，决定是否重装或为旧 CRS 配置创建临时备份。
5. 系统级 Codex 检查：默认告警，显式参数才移除。
6. CRS base_url 检查：探测 `/responses`，必要时把 `/api` 自动修正为 `/openai`。

废弃方案：

- 废弃先写 CRS/NO_PROXY 再安装 Codex 的流程。
- 废弃静默忽略平台不匹配或 root/admin 权限问题。
- 废弃多个脚本各自定义冲突的检查语义。

## 日志级别

决策：安装脚本统一使用少量、稳定、可 grep 的日志级别。共享实现放在 `script-modules/logging/`，平台脚本只负责加载和调用。

- `[INFO]`：正在执行的步骤、解析出的路径、非敏感版本信息。
- `[WARN]`：可以继续但需要用户关注的问题，例如系统级 Codex、PATH 尚未刷新、CRS route 无法确认。
- `[OK]` 或 `[ OK ]`：关键检查通过或文件写入成功。
- `[ERROR]` 或 `[FAIL]`：无法继续的错误，脚本应以非零退出码结束。
- 时间戳日志：NO_PROXY 脚本使用时间戳，保留即可；不要混入更多等级体系。
- Bash 主安装器加载 `script-modules/logging/logging.sh`。
- PowerShell 主安装器加载 `script-modules/logging/logging.ps1`。
- 如果单独复制安装包导致模块缺失，主安装器应保留最小兜底日志函数，不能直接失败。

维护要求：

- 不打印 `OPENAI_API_KEY`、完整 token 或其他敏感值。
- 对可恢复问题使用 WARN，不要误用 ERROR。
- 对会改变系统状态的步骤，日志要包含目标路径或作用域，例如 User scope、nvm prefix、Homebrew node@24 prefix。

## dry-run

决策：主安装脚本提供 dry-run 维护接口，用于先看环境摘要和计划动作，避免排查时误写环境。

建议语义：

- Linux/macOS 使用 `--dry-run`。
- Windows 使用 `-DryRun`，组合包装器也必须透传，并跳过 NO_PROXY 写入。
- dry-run 只做检测和计划输出，不写文件、不改 PATH、不安装包、不删除系统级 Codex。
- dry-run 输出复用统一日志级别，结束时明确说明没有修改文件、环境变量、包、进程或 PATH。
- dry-run 不能读取或回显密钥；涉及 CRS 时只提示将写入的文件路径和 base_url 检测结果。

废弃方案：

- 废弃“用环境变量临时绕过写操作”的隐式 dry-run。
- 废弃只跳过部分写入、但仍安装包或修改 PATH 的半 dry-run。
- 废弃把 `-AsJson` 或 `--skip-*` 当作 dry-run；它们用途不同。
