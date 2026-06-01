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

## macOS：复用可用 Node/npm，缺失时使用 Homebrew

决策：macOS 安装脚本优先复用当前用户已有且可用的 Node.js/npm；缺失或显式强制重装时，再用 Homebrew 作为 Node.js/npm 来源。Codex 安装到用户 npm prefix（如 `~/.local`，非 ASCII HOME/TMPDIR 时使用 ASCII-safe prefix），不要求落在 Homebrew `node@24` prefix 下，后续更新不需要 `sudo`。

原因：

- 许多 macOS 用户已经通过 Homebrew、nvm、fnm、Volta 或官网安装包拥有可用 Node/npm，重复安装或强制切换会破坏既有工具链预期。
- Homebrew 仍是缺失 Node/npm 时的统一兜底来源，可覆盖 Apple Silicon/Intel 路径差异。
- Codex 放在用户 npm prefix 下可避免系统目录权限和 Homebrew Cellar 权限问题，更新 `@openai/codex` 不需要 `sudo`。
- 非 ASCII HOME/TMPDIR 场景下，用户 npm prefix 可以切到 ASCII-safe 根目录，降低 Node/npm/Codex 路径兼容风险。
- 脚本应检查最终 prefix 是用户可写、非系统级安装目标；PATH 持久化用户 npm bin，只有脚本本次通过 Homebrew 安装 Node.js 时才补充对应 Node bin。

废弃方案：

- 废弃强制安装或激活 Homebrew `node@24` 作为唯一 Node/npm 来源。
- 废弃要求 Codex 必须安装在 `brew --prefix node@24` 下。
- 废弃为了安装 Codex 强行覆盖用户已有 Node 管理器或可用 PATH 中的 Node/npm。
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
- 删除长期变量后，Linux 由 nvm 决定 prefix，macOS 使用用户 npm prefix，Windows 由显式 `--prefix` 决定本次安装目标。

维护要求：

- 新增 npm 调用时优先使用显式参数或当前 Node 管理器默认 prefix。
- 如果发现旧版 profile 中存在 `NPM_CONFIG_PREFIX` 或 `NPM_CONFIG_CACHE`，应继续清理。
- macOS 允许通过用户级 npm 配置持久化 `prefix`，以保证后续 `npm update -g @openai/codex` 继续落在用户 prefix；不要把 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE` 写入 shell profile。

## macOS：profile 写入范围

决策：macOS 默认只写登录 shell 对应 profile。登录 shell 为 zsh 时写 `~/.zprofile`、`~/.zshrc`；登录 shell 为 bash 时写 `~/.bash_profile`、`~/.bashrc`。不提供自定义写入范围开关，也不为了兼容而默认同时更新 zsh/bash。

原因：

- 现代 macOS 默认 shell 是 zsh，默认更新 bash 文件会造成“脚本到处改环境”的误解。
- bash 文件只应在用户登录 shell 是 bash 时追加新配置。
- profile 写入范围应跟随登录 shell，可解释、可审计，避免实机日志出现不必要的跨 shell 写入。

维护要求：

- Codex PATH、`CODEX_HOME`、`CRS_OAI_KEY` 和 NO_PROXY/no_proxy 在 macOS 上都应遵循同一登录 shell 判断。
- 旧脚本标记块可以清理；但“发现并清理旧块”不等于允许默认向另一个 shell 追加新块。
- 新增 profile 写入逻辑时必须先判断登录 shell，不能通过“文件已存在”作为默认追加到另一个 shell 的理由。

## NO_PROXY 合并语义

决策：NO_PROXY/no_proxy 配置应保留用户已有条目，移除旧版固定 IP `3.27.43.117`、`3.27.43.117:10086`，并追加 `localhost`、`127.0.0.1` 和 CRS base_url 解析出的 host、host:port。

原因：

- 用户可能已有公司代理、内网域名或本地开发地址，安装脚本不应覆盖。
- 旧固定 IP 是历史安装器遗留值，继续保留会误导排查并可能绕过不相关地址。
- 同时加入 CRS host 和 host:port 可以覆盖不同代理实现对 NO_PROXY 端口匹配的差异。

维护要求：

- 三平台 NO_PROXY 脚本都应保持幂等，重复运行不得产生重复项。
- 新增 CRS 地址解析逻辑时必须继续保留既有用户项并清理旧固定 IP。
- 不要把 NO_PROXY 语义改成“整段覆盖为脚本内置默认值”。

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

- 不打印 `CRS_OAI_KEY`、完整 token 或其他敏感值。
- 对可恢复问题使用 WARN，不要误用 ERROR。
- 对会改变系统状态的步骤，日志要包含目标路径或作用域，例如 User scope、nvm prefix、macOS 用户 npm prefix。

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
