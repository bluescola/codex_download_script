# OpenCode 2 一键安装包

本目录安装 OpenCode CLI。请在目标系统的普通用户会话中运行，Linux/macOS 不要使用 `sudo`。保留整个安装包目录；Linux/macOS 入口依赖 `shared/install-opencode.sh`。

目录分工：`windows/` 放 PowerShell 和命令提示符入口，`linux/` 与 `mac/` 放各自的启动脚本，`shared/` 放 Linux/macOS 共用安装逻辑。

## 安装

| 系统 | 命令 |
| --- | --- |
| Windows PowerShell | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\install-opencode.ps1` |
| Windows 命令提示符 | `.\windows\install-opencode.cmd` |
| Linux / WSL | `bash ./linux/install-opencode-linux.sh` |
| macOS | `bash ./mac/install-opencode-mac.sh` |

以上命令从安装包根目录执行。

安装器检查已有 Node.js/npm，并在缺失时安装 Node.js。Linux 使用 nvm 安装 LTS，macOS 使用 Homebrew 的 `node`，Windows 从 Node.js 镜像或官方站下载并校验 LTS zip。OpenCode 2 通过 npm 包 `@opencode/cli` 安装到用户目录，使用可用镜像并在必要时回退官方源。Linux/macOS 的 npm 目录为 `~/.local/share/opencode/npm`；Windows 为 `%LOCALAPPDATA%\Programs\opencode\npm`，遇到非 ASCII 用户路径时使用 `C:\OpenCode\npm`。安装器会把命令目录写入用户 PATH。

安装完成后打开新终端运行：

```text
opencode --version
opencode auth login
opencode
```

也可以在 OpenCode 中运行 `/connect` 添加提供商。全局配置为 `~/.config/opencode/opencode.json`，Windows 对应 `%USERPROFILE%\.config\opencode\opencode.json`。安装器只在没有 `opencode.json` 和 `opencode.jsonc` 时创建合法的最小配置，不覆盖现有配置，也不写入 API Key。

## 参数

| Windows PowerShell | Linux/macOS | 用途 |
| --- | --- | --- |
| `-DryRun` | `--dry-run` | 只显示预检，不安装或写文件 |
| `-ForceNodeReinstall` | `--force-node-reinstall` | 强制重装 Node.js |
| `-ForceOpencodeReinstall` | `--force-opencode-reinstall` | 强制安装当前 OpenCode 包 |
| `-SkipNodeCheck` | `--skip-node-check` | 使用已有 npm，不检查 Node.js |
| `-VerboseLog` | `--verbose` | 输出详细日志 |
| `-Registry URL` | `--registry URL` | 指定 npm registry |

Linux/macOS 可用 `--help` 查看参数。检测到 OpenCode 1 时会升级到 OpenCode 2；已有 OpenCode 2 默认保留，需要重装时传入强制重装参数。`--skip-node-check` 仍要求 npm 可用。Linux/macOS 脚本会拒绝 root 和不匹配的系统。Windows 版支持 x64 和 ARM64 Node.js zip。

当前包名、配置路径及登录命令依据 [OpenCode 安装文档](https://opencode.ai/docs)、[配置文档](https://opencode.ai/docs/config) 和 [提供商文档](https://opencode.ai/docs/cli/providers)。
