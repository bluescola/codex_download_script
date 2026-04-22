param(
    [switch]$ForceNodeReinstall,
    [switch]$ForceCodexReinstall,
    [switch]$SkipCrsConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

try {
    # Keep this wrapper ASCII-only so it works even in legacy Windows PowerShell encodings.
    # Depend only on scripts in the same folder so this installer can be copied around standalone.
    $installScript = Join-Path $PSScriptRoot 'install-codex-cli.ps1'
    $noProxyScript = Join-Path $PSScriptRoot 'setup_no_proxy_windows.ps1'

    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "Required script not found next to installer: install-codex-cli.ps1"
    }
    if (-not (Test-Path -LiteralPath $noProxyScript)) {
        throw "Required script not found next to installer: setup_no_proxy_windows.ps1"
    }

    Write-Info "Installer script: $installScript"
    Write-Info "NO_PROXY setup script: $noProxyScript"
    Write-Host ''

    Write-Info 'Step 1/2: Install Codex CLI and write config files...'
    & $installScript `
        -ForceNodeReinstall:$ForceNodeReinstall `
        -ForceCodexReinstall:$ForceCodexReinstall `
        -SkipCrsConfig:$SkipCrsConfig

    Write-Host ''
    Write-Info 'Step 2/2: Configure NO_PROXY bypass (User scope)...'
    Write-Info 'NO_PROXY will include (added if missing):'
    Write-Host '  - 3.27.43.117'
    Write-Host '  - 3.27.43.117:10086'
    Write-Host '  - localhost'
    Write-Host '  - 127.0.0.1'
    & $noProxyScript

    Write-Host ''
    Write-Ok 'Done. Restart apps (VS Code/Codex/terminals) to pick up updated NO_PROXY.'
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
