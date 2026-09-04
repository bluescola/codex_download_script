# Codex Windows 一键安装包

本目录的 `*.cmd` 是给双击运行准备的包装器，会用 `powershell.exe -NoProfile -ExecutionPolicy Bypass` 调用对应 `*.ps1`，并在结束时暂停显示退出码。

## 入口

- `install-codex-cli.cmd`：安装 Codex CLI，写 CRS 配置，并配置 NO_PROXY。
- `uninstall-codex-cli-and-node-npm.cmd`：卸载 Codex CLI，并在确认属于本安装包目标路径时清理用户级 Node.js/npm。
- `check-and-repair-codex-env.cmd`：安装后检查并修复 PATH、PowerShell 执行策略、`codex.cmd`/`codex.ps1` 等问题。
- `install-vc-redist-x64.cmd`：安装或修复 Microsoft Visual C++ Redistributable 2015-2022 x64。

## 行为摘要

- 主安装脚本开头打印 preflight 环境摘要，便于排查 Node/npm/Codex、PowerShell、PATH、执行策略和 ASCII-safe 路径问题。
- 中文或非 ASCII 用户路径场景下使用 `C:\Codex` 或受限的 `CODEX_WINDOWS_ASCII_ROOT`。自定义目录只能是本地盘符根下的 `Codex` 或 `Codex-<name>`，拒绝重解析点；仅新建根目录时设置当前用户 ACL，已有目录保留原 ACL。
- Node.js 不可用时下载官方 LTS zip，校验 SHA256 后安装到用户目录。
- 安装 Codex 时显式使用 npm `--prefix` 和 `--cache`，不长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE`、`NPM_CONFIG_USERCONFIG`。
- 系统级 Codex 默认只告警；只有显式传 `-RemoveSystemCodex` 才移除。
- 组合安装入口会在 Codex 安装后调用 `setup_no_proxy_windows.ps1`，合并用户级 NO_PROXY。

## 常用参数

安装参数可追加在 `install-codex-cli.cmd` 或 `install-codex-cli.ps1` 后面：

- `-DryRun`：只打印环境摘要，不安装、不写文件、不改环境、不配置 NO_PROXY。
- `-VerboseLog`：打印详细诊断。
- `-TraceLog`：打印 trace 级诊断。
- `-ForceNodeReinstall`：强制重装 Node.js/npm。
- `-ForceCodexReinstall`：强制重装 `@openai/codex`。
- `-RemoveSystemCodex`：显式移除检测到的系统级 Codex。
- `-SkipCrsConfig`：跳过 CRS 配置交互。

卸载参数可追加在 `uninstall-codex-cli-and-node-npm.cmd` 或 `uninstall-codex-cli-and-node-npm.ps1` 后面：

- `-KeepCodexHome`：保留 `CODEX_HOME` / `.codex` 文件。
- `-KeepNpmCache`：保留本安装包使用的 npm cache。
- `-SkipNodeUninstall`：只卸载 Codex CLI，保留 Node.js/npm。
- `-ForceRemoveCodexHome`：移除整个 `.codex` 目录，而不只是配置和认证文件。

## 维护入口

- 总览：[../docs/script-system-overview.md](../docs/script-system-overview.md)
- 决策记录：[../docs/decisions.md](../docs/decisions.md)
- 流程图：[../docs/graphs/windows-install.drawio](../docs/graphs/windows-install.drawio)
- 用户配置指南：[../Codex-CLI-配置指南-windows.md](../Codex-CLI-配置指南-windows.md)
