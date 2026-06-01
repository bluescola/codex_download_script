$ErrorActionPreference = 'Stop'

function Confirm-Create {
  param([string]$Target)
  $reply = Read-Host "未找到 $Target，是否创建？[y/N]"
  if ($reply -match '^[yY]') { return $true }
  Write-Host "已中止：需要 $Target"
  exit 1
}

function Backup-IfExists {
  param([string]$PathValue)
  if (Test-Path -LiteralPath $PathValue) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $PathValue -Destination ($PathValue + ".bak.$timestamp") -Force
  }
}

$baseUrl = Read-Host '请输入 base_url'
$openAiKey = Read-Host '请输入 OPENAI_API_KEY'

$codexDir = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }
$configPath = Join-Path $codexDir 'config.toml'
$authPath = Join-Path $codexDir 'auth.json'

if (-not (Test-Path -LiteralPath $codexDir)) {
  if (Confirm-Create $codexDir) {
    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
  }
}

if (-not (Test-Path -LiteralPath $configPath)) {
  if (Confirm-Create $configPath) {
    New-Item -ItemType File -Path $configPath -Force | Out-Null
  }
}

if (-not (Test-Path -LiteralPath $authPath)) {
  if (Confirm-Create $authPath) {
    New-Item -ItemType File -Path $authPath -Force | Out-Null
  }
}

Backup-IfExists $configPath
Backup-IfExists $authPath

$configToml = @"
model_provider = "OpenAI"
model = "gpt-5.4"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"
disable_response_storage = true
network_access = "enabled"

sandbox_mode = "danger-full-access"
approval_policy = "never"
# 正常模式：
# sandbox_mode = "workspace-write"
# approval_policy = "on-request"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "$baseUrl"
wire_api = "responses"
requires_openai_auth = true

[features]
# 实际已去除
tui_app_server = false
# 关闭 MCP / 工具 / 列表 / 发现/建议（可避免 codex_apps 相关报错）
apps = false

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.4"
"gpt-5.2" = "gpt-5.4"
"@

$authJson = (@{
  OPENAI_API_KEY = $openAiKey
} | ConvertTo-Json -Depth 3)

Set-Content -LiteralPath $configPath -Value $configToml -Encoding UTF8
Set-Content -LiteralPath $authPath -Value $authJson -Encoding UTF8

try {
  [Environment]::SetEnvironmentVariable('CRS_OAI_KEY', $null, 'User')
  Remove-Item Env:CRS_OAI_KEY -ErrorAction SilentlyContinue
} catch {
  Write-Host "清理旧 CRS_OAI_KEY 失败：$($_.Exception.Message)"
}

Write-Host "已更新：$configPath"
Write-Host "已更新：$authPath"
Write-Host 'Updated with current CRS 2.0 / OpenAI-compatible config format.'
