param(
  # 读取 base_url 的 config.toml 路径；不传时按 CODEX_HOME 和用户目录自动查找。
  [string]$ConfigPath,
  # 手动指定 CRS 2.0 / OpenAI-compatible base_url；会透传给目标 NO_PROXY 脚本。
  [string]$BaseUrl
)

$scriptPath = Join-Path $PSScriptRoot '..\..\Codex-windows一键安装包\setup_no_proxy_windows.ps1'
& $scriptPath -ConfigPath $ConfigPath -BaseUrl $BaseUrl
