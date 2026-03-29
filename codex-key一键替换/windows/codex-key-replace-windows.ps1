$ErrorActionPreference = 'Stop'

function Confirm-Create {
  param([string]$Target)
  $reply = Read-Host "未找到 $Target，是否创建？[y/N]"
  if ($reply -match '^[yY]') { return $true }
  Write-Host "已中止：需要 $Target"
  exit 1
}

$baseUrl = Read-Host '请输入 base_url'
$crsKey = Read-Host '请输入 CRS_OAI_KEY'

$codexDir = Join-Path $HOME '.codex'
$configPath = Join-Path $codexDir 'config.toml'

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

$content = ''
if (Test-Path -LiteralPath $configPath) {
  $content = Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue
}

$wasRequiresTrue = $false
if ($content -match '(?im)^\s*requires_openai_auth\s*=\s*true\s*$') {
  $wasRequiresTrue = $true
}

function Upsert-ConfigLine {
  param(
    [string]$Content,
    [string]$Key,
    [string]$Value
  )
  $escapedKey = [regex]::Escape($Key)
  if ($Content -match "(?m)^\s*$escapedKey\s*=") {
    return [regex]::Replace($Content, "(?m)^\s*$escapedKey\s*=.*$", "$Key = $Value")
  }
  if ($Content -and $Content -notmatch "(\r?\n)$") { $Content += "`r`n" }
  return $Content + "$Key = $Value`r`n"
}

$escapedBase = $baseUrl -replace '"','\"'
$content = Upsert-ConfigLine -Content $content -Key 'base_url' -Value "`"$escapedBase`""
$content = Upsert-ConfigLine -Content $content -Key 'requires_openai_auth' -Value 'false'

Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8

try {
  setx CRS_OAI_KEY $crsKey | Out-Null
  $env:CRS_OAI_KEY = $crsKey
} catch {
  Write-Host "设置 CRS_OAI_KEY 失败：$($_.Exception.Message)"
  exit 1
}

Write-Host "已更新：$configPath"
Write-Host '已设置：CRS_OAI_KEY（用户环境变量）'
Write-Host '如需在当前终端立即生效，请重新打开终端。'
if ($wasRequiresTrue) {
  Write-Host '提示：requires_openai_auth 原为 true，已改为 false。'
}
