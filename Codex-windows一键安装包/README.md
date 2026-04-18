# Codex-一键安装包（Windows）里的 3 个 CMD 脚本是做什么的

本目录下的 `*.cmd` 主要是给“直接双击运行”准备的包装器：它们会调用同名/对应的 `*.ps1`，并在结束时 `pause`，方便你看到输出结果与错误码。

通用行为：
- 都会使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...` 运行对应的 PowerShell 脚本（仅对本次运行生效）。
- 都会透传参数：你在 `cmd` 后面加的参数会原样传给 `ps1`。
- 都会在窗口里显示退出码（Exit code），便于排查失败原因。

## 1) `install-codex-cli.cmd`

用途：一键安装 Codex CLI，并顺带配置 Windows 的 `NO_PROXY` 绕过代理（用户级环境变量）。

它实际运行的是：
- `install-codex-cli-and-setup-no-proxy.ps1`
  - Step 1：调用 `install-codex-cli.ps1`（安装/修复 Node、安装 codex、写入相关配置等）
  - Step 2：调用仓库里的 `setup_no_proxy_windows.ps1`（把需要绕过代理的地址追加到 `NO_PROXY`，缺少才加，不重复）

适用场景：
- 第一次安装 Codex CLI
- 想重新跑一遍安装流程，并确保 `NO_PROXY` 设置到位

## 2) `check-codex-env.cmd`

用途：检查（并尽量修复）运行 Codex CLI 所需的环境是否正常。

它实际运行的是：
- `check-codex-env.ps1`
  - 检查 `node` / `npm` / `codex` 命令是否可用、路径是否正确
  - 检查/修复 `PATH`（把 codex 的 npm bin 目录加入用户 Path，必要时刷新当前进程 Path）
  - 检查 PowerShell 执行策略导致的 `codex.ps1` 受限问题，并给出修复建议（部分情况下会尝试自动修复）

常用参数（会透传给 `check-codex-env.ps1`）：
- `-AsJson`：以 JSON 输出结果（便于复制/上报）
- `-FailOnWarning`：把警告也当失败（用于更严格的检测）

## 3) `install-vc-redist-x64.cmd`

用途：下载并安装/修复 Microsoft Visual C++ Redistributable 2015-2022（x64）。

它实际运行的是：
- `install-vc-redist-x64.ps1`
  - 下载 `vc_redist.x64.exe`（来自 `https://aka.ms/vc14/vc_redist.x64.exe`）
  - 根据检测结果选择 `/install` 或 `/repair`，并执行安装

常用参数（会透传给 `install-vc-redist-x64.ps1`）：
- `-Quiet`：静默安装（默认是被动安装 `/passive`）
- `-Repair`：强制走修复流程
- `-DownloadOnly`：只下载，不执行安装

