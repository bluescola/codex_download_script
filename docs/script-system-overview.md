# 脚本系统总览

本文给后续 Codex 维护者使用，说明三平台脚本系统的入口、安装链路、日志约定和排查入口。

## 目录边界

- Linux 安装包：`Codex-Linux-一键安装包/`
- macOS 安装包：`Codex-Mac-一键安装包/`
- Windows 安装包：`Codex-windows一键安装包/`
- 独立 NO_PROXY 工具：`codex绕过代理配置/`
- 独立 Node/npm 工具：`Node和npm安装和卸载脚本/`
- 共享脚本模块：`script-modules/`
- 维护文档：`docs/`

## 入口脚本

| 平台 | 用户入口 | 实际主脚本 | 说明 |
| --- | --- | --- | --- |
| Linux | `install-codex-cli-linux.sh` | 同文件 | 安装 nvm LTS、Codex、CRS、NO_PROXY。`run-install.cmd` 只是在 Windows 中提示复制到 Linux/WSL 后运行。 |
| macOS | `install-codex-cli-mac.sh` | 同文件 | 安装或复用 Homebrew `node@24`，安装 Codex、CRS、NO_PROXY。 |
| Windows | `install-codex-cli.cmd` | `install-codex-cli-and-setup-no-proxy.ps1` -> `install-codex-cli.ps1` + `setup_no_proxy_windows.ps1` | `.cmd` 负责用 `-ExecutionPolicy Bypass` 启动组合安装流程。 |
| Windows 修复 | `check-and-repair-codex-env.cmd` | `check-and-repair-codex-env.ps1` | 安装后 PATH、执行策略、`codex.cmd`、PowerShell shim 等问题优先看这里。 |
| VC++ 运行库 | `install-vc-redist-x64.cmd` | `install-vc-redist-x64.ps1` | Windows Codex 原生二进制缺 DLL 时使用。 |

## 共享模块

- `script-modules/logging/logging.sh`：Bash 主安装器日志模块。
- `script-modules/logging/logging.ps1`：PowerShell 主安装器日志模块。
- 主安装器应优先加载共享模块；模块缺失时保留最小兜底日志函数，保证单独复制安装包仍可运行。

## 安装流程

### Linux

1. 拒绝非 Linux 和 root 运行。
2. 加载日志模块，打印 preflight 环境摘要；`--dry-run` 到这里结束。
3. 检查 HOME/TMPDIR 是否含非 ASCII，必要时使用 `/var/tmp/codex-<uid>`。
4. 检查已有 Node/npm/Codex，决定是否为旧 CRS 配置创建临时备份。
5. 通过 nvm 安装或启用 Node.js LTS。
6. 检查系统级 Codex：默认告警；传入 `--remove-system-codex` 才移除。
7. 把 Codex 安装到 nvm npm prefix。
8. 清理旧 PATH 块、旧 `NPM_CONFIG_*`，并在使用 nvm 前移除冲突的 npmrc `prefix/globalconfig` 和旧安装器 cache。
9. 写入 CRS 配置和 `auth.json`。
10. 调用 `setup_no_proxy_linux.sh` 写入 NO_PROXY/no_proxy。

### macOS

1. 拒绝 root 和非 Darwin 运行。
2. 加载日志模块，打印 preflight 环境摘要；`--dry-run` 到这里结束。
3. 检查 HOME/TMPDIR 是否含非 ASCII，必要时使用 `/Users/Shared/Codex-<uid>`。
4. 检查已有 Node/npm/Codex，决定是否为旧 CRS 配置创建临时备份。
5. 安装或复用 Homebrew，安装 `node@24`。
6. 检查系统级 Codex：默认告警；传入 `--remove-system-codex` 才移除。
7. 清理旧安装器 npm 配置；`CODEX_HOME` profile 环境变量只在非默认目录时持久化。
8. 把 Codex 安装到 Homebrew `node@24` npm prefix。
9. 清理旧 PATH 块、旧 `NPM_CONFIG_*` 和默认 `CODEX_HOME`，并把 `node@24/bin` 去重置顶写入 zsh/bash profile。
10. 写入 CRS 配置和 `auth.json`。
11. 调用 `setup_no_proxy_mac.sh` 合并 NO_PROXY/no_proxy，按登录 shell 写入对应 zsh 或 bash profile，并更新 `launchctl` 和 LaunchAgent。

### Windows

1. `.cmd` 以 `powershell.exe -NoProfile -ExecutionPolicy Bypass` 启动组合包装器。
2. `install-codex-cli.ps1` 初始化 ASCII-safe 路径设置，加载日志模块，打印 preflight 环境摘要；`-DryRun` 到这里结束。
3. 如果用户路径含非 ASCII，使用 `C:\Codex` 或 `CODEX_WINDOWS_ASCII_ROOT`，并设置 `CODEX_HOME`。
4. 检查已有 Node/npm/Codex，决定是否清理旧 CRS 配置。
5. 若 Node/npm 不可用，下载 Node.js LTS zip，校验 SHA256，并原子替换到用户目录。
6. 检查系统级 Codex：默认告警；传入 `-RemoveSystemCodex` 才移除。
7. 使用显式 `npm install -g --prefix <prefix> --cache <cache> @openai/codex` 安装。
8. 写入用户 PATH，探测 `codex.cmd`、普通 PowerShell、`PowerShell -NoProfile`。
9. 写入 CRS 配置和 `auth.json`。
10. 组合包装器调用 `setup_no_proxy_windows.ps1`，按 CRS `base_url` 写入用户级 NO_PROXY。

## CRS 配置

三平台都写入同类配置：

- `model_provider = "OpenAI"`
- `wire_api = "responses"`
- `requires_openai_auth = true`
- `disable_response_storage = true`
- `auth.json` 中写入 `OPENAI_API_KEY`

维护重点：

- 写入前为旧 `config.toml`、`auth.json` 创建临时备份；写入成功后删除本次备份，失败时保留。
- base_url 必须探测 `/<base>/responses`。
- 如果用户输入形如 `/api` 且 `/responses` 返回 404，脚本可尝试改为 `/openai`。
- 不要把 CRS key 写入日志。

## NO_PROXY

三平台 NO_PROXY 脚本都应保持幂等：

- 读取 CRS `base_url`，加入 host 和 host:port。
- 固定加入 `localhost`、`127.0.0.1`。
- 移除旧版固定 IP：`3.27.43.117`、`3.27.43.117:10086`。
- 保留用户已有项并去重。

平台差异：

- Linux 同时合并 `NO_PROXY` 和 `no_proxy`，写 shell profile 和 `~/.config/environment.d/99-codex-no-proxy.conf`。
- macOS 同时合并 `NO_PROXY` 和 `no_proxy`，按登录 shell 只写对应的 zsh 或 bash profile，并通过 `launchctl` 和 LaunchAgent 覆盖 GUI 会话。
- Windows 合并 User/Process 级 `NO_PROXY`，写 User 环境变量，更新当前进程，并广播环境变更；当前不维护小写 `no_proxy`。

## 日志级别

- `[INFO]`：步骤和非敏感上下文。
- `[WARN]`：可继续但需要关注。
- `[OK]` / `[ OK ]`：关键步骤通过。
- `[ERROR]` / `[FAIL]`：不可继续。
- 时间戳日志：NO_PROXY 脚本专用，保留现状。

## 维护边界

- 只改对应平台脚本时，不要同步改另一个平台的行为，除非这是明确的跨平台决策。
- 不要把 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE` 长期写入用户环境；Windows 还要继续清理旧版本曾写入的 `NPM_CONFIG_USERCONFIG`。
- Windows npm 安装必须继续显式传 `--prefix` 和 `--cache`。
- Linux Codex 安装目标必须继续在 nvm prefix 下。
- macOS Codex 安装目标必须继续在 Homebrew `node@24` prefix 下。
- 系统级 Codex 默认只告警；删除必须由显式参数触发。
- 包内 README 不属于维护文档任务范围。

## 排查先看哪里

| 问题 | 优先查看 |
| --- | --- |
| Linux 安装失败 | `Codex-Linux-一键安装包/install-codex-cli-linux.sh` 的 `ensure_node_npm`、`ensure_codex`、`resolve_crs_base_url` |
| macOS 安装失败 | `Codex-Mac-一键安装包/install-codex-cli-mac.sh` 的 `ensure_node_npm`、`ensure_homebrew_node_active`、`ensure_codex` |
| Windows 安装失败 | `Codex-windows一键安装包/install-codex-cli.ps1` 的 `Initialize-CodexPathSettings`、`Ensure-Node`、`Ensure-Codex` |
| Windows 安装后 `codex` 不可用 | `Codex-windows一键安装包/check-and-repair-codex-env.ps1` |
| 独立 Node/npm 安装或卸载 | `Node和npm安装和卸载脚本/`，流程见 `docs/graphs/node-npm.drawio` |
| Windows DLL 缺失 | `install-vc-redist-x64.*`，并查看 `Get-CodexRuntimeHint` |
| CRS 不通 | 三平台主安装脚本中的 `Resolve-CrsBaseUrl` / `resolve_crs_base_url` |
| NO_PROXY 不生效 | 对应平台 `setup_no_proxy_*` 脚本 |
| 旧安装污染 | 系统级 Codex 检测函数、旧 `NPM_CONFIG_*` 清理逻辑、旧 PATH block 清理逻辑 |
