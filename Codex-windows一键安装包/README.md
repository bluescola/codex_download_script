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
    - 下载 Node.js zip 后会校验 Node 官方 `SHASUMS256.txt` 中的 SHA256，校验失败会中止
    - 替换用户级 Node 时先备份旧目录，移动新目录失败会回滚，避免安装失败后没有 Node 可用
  - Step 2：调用同目录的 `setup_no_proxy_windows.ps1`（把需要绕过代理的地址追加到 `NO_PROXY`，会优先读取 `CODEX_HOME\config.toml` 里的 CRS `base_url`，缺少才加，不重复）

适用场景：
- 第一次安装 Codex CLI
- 想重新跑一遍安装流程，并确保 `NO_PROXY` 设置到位

中文用户目录兼容：
- 如果检测到 `USERPROFILE` / `APPDATA` / `LOCALAPPDATA` / `TEMP` 等路径包含中文或其他非 ASCII 字符，安装脚本会自动启用“ASCII 安全路径”。
- 启用后，Node、npm 全局包、npm 缓存和 Codex 配置会放到类似 `C:\Codex` 的英文路径下，且该目录会自动设置 ACL 仅当前用户可访问，避免 Codex 原生程序或 npm wrapper 在中文用户目录中启动失败。
- 脚本安装 Codex 时会显式使用 ASCII 安全 npm prefix/cache，但不会长期写入 `NPM_CONFIG_PREFIX`、`NPM_CONFIG_CACHE`、`NPM_CONFIG_USERCONFIG`；只会按需写入 `CODEX_HOME`，并把对应 npm bin 目录加入用户 `Path`。
- 如需自定义英文根目录，可在运行前设置用户/进程环境变量 `CODEX_WINDOWS_ASCII_ROOT`，例如 `C:\CodexData`。

系统级 Codex 处理：
- 默认只检测并提示系统级 Codex，不再自动卸载或删除，安装器会把当前用户 npm bin 目录放到 `Path` 前面。
- 如确实需要移除系统级 Codex，请显式传入 `-RemoveSystemCodex`，并确认输出中列出的路径。

## 2) `check-and-repair-codex-env.cmd`

用途：检查（并尽量修复）运行 Codex CLI 所需的环境是否正常。

它实际运行的是：
- `check-and-repair-codex-env.ps1`
  - 检查 `node` / `npm` / `codex` 命令是否可用、路径是否正确
  - 检查/修复 `PATH`（把 codex 的 npm bin 目录加入用户 Path，必要时刷新当前进程 Path）
  - 检查 PowerShell 执行策略导致的 `codex.ps1` 受限问题，并给出修复建议（部分情况下会尝试自动修复）
  - 在中文用户目录场景下优先检查 ASCII 安全 npm prefix，并提示是否需要重新运行安装脚本迁移

说明：这个脚本的定位就是“检查并纠正环境”，所以会写用户 `Path`、必要时修复 PowerShell profile/wrapper。改名为 `check-and-repair-*` 是为了避免被误认为纯只读检查。

常用参数（会透传给 `check-and-repair-codex-env.ps1`）：
- `-AsJson`：以 JSON 输出结果（便于复制/上报）
- `-FailOnWarning`：把警告也当失败（用于更严格的检测）

## 3) `install-vc-redist-x64.cmd`

用途：下载并安装/修复 Microsoft Visual C++ Redistributable 2015-2022（x64）。

它实际运行的是：
- `install-vc-redist-x64.ps1`
  - 下载 `vc_redist.x64.exe`（来自 `https://aka.ms/vc14/vc_redist.x64.exe`）
  - 执行前校验 Authenticode 签名，必须是有效的 Microsoft 签名
  - 根据检测结果选择 `/install` 或 `/repair`，并执行安装

常用参数（会透传给 `install-vc-redist-x64.ps1`）：
- `-Quiet`：静默安装（默认是被动安装 `/passive`）
- `-Repair`：强制走修复流程
- `-DownloadOnly`：只下载，不执行安装

## 下载校验的意义

- Node.js 包使用官方 SHA256 清单校验；VC++ 安装包使用 Authenticode 签名校验。
- 如果没有校验，下载被代理/CDN/缓存污染、被篡改、或只下载到损坏文件时，脚本可能继续解压或执行错误的二进制，轻则安装失败，重则有供应链安全风险。
- 校验失败时不要手动跳过，请重新下载或检查网络代理/杀毒软件/镜像源。
