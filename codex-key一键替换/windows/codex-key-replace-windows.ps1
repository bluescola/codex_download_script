$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Confirm-Create {
  param([string]$Target)
  $reply = Read-Host "未找到 $Target，是否创建？[y/N]"
  if ($reply -match '^[yY]') { return $true }
  Write-Host "已中止：需要 $Target"
  exit 1
}

function Read-SecretPlain {
  param([string]$Prompt)
  $secure = Read-Host $Prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Escape-TomlBasicString {
  param([string]$Value)
  if ($null -eq $Value) { return '' }
  return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Backup-FileIfExists {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  Copy-Item -LiteralPath $Path -Destination "$Path.bak.$timestamp" -Force
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function New-DefaultCodexConfig {
  param([string]$EscapedBaseUrl)
  return @"
model_provider = "crs"
model = "gpt-5.2"
model_reasoning_effort = "xhigh"
disable_response_storage = true
preferred_auth_method = "apikey"

sandbox_mode = "workspace-write"
approval_policy = "on-request"

[model_providers.crs]
name = "crs"
base_url = "$EscapedBaseUrl"
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"

[features]
tui_app_server = false
apps = false
"@
}

function Upsert-TomlKeyInSection {
  param(
    [string]$Content,
    [string]$Section,
    [string]$Key,
    [string]$NewLine
  )

  $lines = if ([string]::IsNullOrEmpty($Content)) { @() } else { $Content -split "`r?`n" }
  $result = New-Object System.Collections.Generic.List[string]
  $sectionFound = $false
  $inTarget = $false
  $keyWritten = $false
  $escapedKey = [regex]::Escape($Key)

  foreach ($line in $lines) {
    if ($line -match '^\s*\[([^\]]+)\]\s*$') {
      if ($inTarget -and -not $keyWritten) {
        [void]$result.Add($NewLine)
        $keyWritten = $true
      }
      $inTarget = ($matches[1].Trim() -ieq $Section)
      if ($inTarget) {
        $sectionFound = $true
        $keyWritten = $false
      }
      [void]$result.Add($line)
      continue
    }

    if ($inTarget -and ($line -match "^\s*$escapedKey\s*=")) {
      if (-not $keyWritten) {
        [void]$result.Add($NewLine)
        $keyWritten = $true
      }
      continue
    }

    [void]$result.Add($line)
  }

  if ($inTarget -and -not $keyWritten) {
    [void]$result.Add($NewLine)
  }

  if (-not $sectionFound) {
    if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
      [void]$result.Add('')
    }
    [void]$result.Add('[model_providers.crs]')
    [void]$result.Add($NewLine)
  }

  return (($result.ToArray() -join "`r`n").TrimEnd("`r", "`n") + "`r`n")
}

$baseUrl = (Read-Host '请输入 base_url').Trim()
$crsKey = (Read-SecretPlain '请输入 CRS_OAI_KEY（隐藏输入）').Trim()
if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($crsKey)) {
  Write-Host 'base_url 和 CRS_OAI_KEY 不能为空'
  exit 1
}

$codexDir = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
  $env:CODEX_HOME
} else {
  Join-Path $HOME '.codex'
}
$configPath = Join-Path $codexDir 'config.toml'
$authPath = Join-Path $codexDir 'auth.json'

if (-not (Test-Path -LiteralPath $codexDir)) {
  if (Confirm-Create $codexDir) {
    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
  }
}

$escapedBase = Escape-TomlBasicString $baseUrl
$content = ''
if (Test-Path -LiteralPath $configPath) {
  $content = Get-Content -LiteralPath $configPath -Raw -ErrorAction SilentlyContinue
  Backup-FileIfExists $configPath
}
elseif (Confirm-Create $configPath) {
  $content = New-DefaultCodexConfig $escapedBase
}

$wasRequiresTrue = $content -match '(?im)^\s*requires_openai_auth\s*=\s*true\s*$'
if (-not [string]::IsNullOrWhiteSpace($content)) {
  $content = Upsert-TomlKeyInSection -Content $content -Section 'model_providers.crs' -Key 'base_url' -NewLine "base_url = `"$escapedBase`""
  $content = Upsert-TomlKeyInSection -Content $content -Section 'model_providers.crs' -Key 'requires_openai_auth' -NewLine 'requires_openai_auth = false'
}

Write-Utf8NoBom -Path $configPath -Content $content

if (Test-Path -LiteralPath $authPath) {
  Backup-FileIfExists $authPath
}
Write-Utf8NoBom -Path $authPath -Content "{`r`n  `"OPENAI_API_KEY`": null`r`n}`r`n"

try {
  [Environment]::SetEnvironmentVariable('CRS_OAI_KEY', $crsKey, 'User')
  $env:CRS_OAI_KEY = $crsKey
} catch {
  Write-Host "设置 CRS_OAI_KEY 失败：$($_.Exception.Message)"
  exit 1
}

Write-Host "已更新：$configPath"
Write-Host "已确认：$authPath"
Write-Host '已设置：CRS_OAI_KEY（用户环境变量，隐藏输入）'
Write-Host '如需在当前终端立即生效，请重新打开终端。'
if ($wasRequiresTrue) {
  Write-Host '提示：requires_openai_auth 原为 true，已改为 false。'
}
