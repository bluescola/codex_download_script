$ErrorActionPreference = 'Stop'

function Confirm-Create {
  param([string]$Target)
  $reply = Read-Host "Not found: $Target. Create it? [y/N]"
  if ($reply -match '^[yY]') { return $true }
  Write-Host "Aborted: $Target is required."
  exit 1
}

function Backup-IfExists {
  param([string]$PathValue)
  if (Test-Path -LiteralPath $PathValue) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $PathValue -Destination ($PathValue + ".bak.$timestamp") -Force
  }
}

$codexDir = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }
$configPath = Join-Path $codexDir 'config.toml'
$authPath = Join-Path $codexDir 'auth.json'

function Get-CurrentBaseUrl {
  param([string]$PathValue)
  if (-not (Test-Path -LiteralPath $PathValue)) { return $null }
  $match = Select-String -LiteralPath $PathValue -Pattern '^\s*base_url\s*=\s*"([^"]+)"' -List -ErrorAction SilentlyContinue
  if ($match) { return $match.Matches[0].Groups[1].Value }
  return $null
}

function Get-CurrentOpenAiKey {
  param([string]$PathValue)
  if (-not (Test-Path -LiteralPath $PathValue)) { return $null }
  try {
    $raw = Get-Content -Raw -LiteralPath $PathValue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $auth = $raw | ConvertFrom-Json
    if ($auth.PSObject.Properties.Name -contains 'OPENAI_API_KEY') {
      return [string]$auth.OPENAI_API_KEY
    }
  }
  catch {
    return $null
  }
  return $null
}

function Format-MaskedSecret {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '<not found>' }
  if ($Value.Length -le 10) { return '***' }
  return ($Value.Substring(0, [Math]::Min(6, $Value.Length)) + '...' + $Value.Substring($Value.Length - 4))
}

function Show-Crs2ReferenceConfig {
  param(
    [string]$BaseUrl,
    [string]$OpenAiKey
  )

  Write-Host ''
  Write-Host 'Current CRS 2.0 reference config from config.toml/auth.json (key masked):'
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    Write-Host '  base_url = <not found>'
  }
  else {
    Write-Host "  base_url = `"$BaseUrl`""
  }
  Write-Host ("  OPENAI_API_KEY = {0}" -f (Format-MaskedSecret $OpenAiKey))
  Write-Host 'Enter the new CRS 2.0 / OpenAI-compatible config. Press Enter to keep the current value.'
  Write-Host ''
}

function Read-RequiredValue {
  param(
    [string]$Prompt,
    [string]$DefaultValue
  )

  while ($true) {
    $displayPrompt = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [Enter keeps current]" }
    $value = (Read-Host $displayPrompt).Trim()
    if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace($DefaultValue)) {
      return $DefaultValue
    }
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
    Write-Host 'Input cannot be empty. Please try again.'
  }
}

function Read-SecretValue {
  param(
    [string]$Prompt,
    [string]$DefaultValue
  )

  while ($true) {
    $displayPrompt = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { $Prompt } else { "$Prompt [Enter keeps current]" }
    $secure = Read-Host $displayPrompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
      $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace($DefaultValue)) {
      return $DefaultValue
    }
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
    Write-Host 'Input cannot be empty. Please try again.'
  }
}

$currentBaseUrl = Get-CurrentBaseUrl $configPath
$currentOpenAiKey = Get-CurrentOpenAiKey $authPath
Show-Crs2ReferenceConfig -BaseUrl $currentBaseUrl -OpenAiKey $currentOpenAiKey

$baseUrl = Read-RequiredValue 'Enter CRS 2.0 base_url (example: https://your-crs-host:8443)' $currentBaseUrl
$openAiKey = Read-SecretValue 'Enter OPENAI_API_KEY / CRS 2.0 token' $currentOpenAiKey

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
model = "gpt-5.5"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"
disable_response_storage = true
network_access = "enabled"

sandbox_mode = "danger-full-access"
approval_policy = "never"
# Normal mode:
# sandbox_mode = "workspace-write"
# approval_policy = "on-request"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "$baseUrl"
wire_api = "responses"
requires_openai_auth = true

[features]
# Removed in current Codex builds.
tui_app_server = false
# Disable app discovery to avoid codex_apps related errors.
apps = false

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.4"
"gpt-5.2" = "gpt-5.4"

[windows]
sandbox = "elevated"
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
  Write-Host "Failed to clear legacy CRS_OAI_KEY: $($_.Exception.Message)"
}

Write-Host "Updated: $configPath"
Write-Host "Updated: $authPath"
Write-Host 'Updated with current CRS 2.0 / OpenAI-compatible config format.'
