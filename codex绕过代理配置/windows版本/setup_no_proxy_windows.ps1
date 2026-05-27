param(
  [string]$ConfigPath,
  [string]$BaseUrl
)

$scriptPath = Join-Path $PSScriptRoot '..\..\Codex-windows一键安装包\setup_no_proxy_windows.ps1'
& $scriptPath -ConfigPath $ConfigPath -BaseUrl $BaseUrl
