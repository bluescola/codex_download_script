param(
    [switch]$ForceNodeReinstall,
    [switch]$ForceCodexReinstall,
    [switch]$RemoveSystemCodex,
    [switch]$SkipCrsConfig,
    [switch]$DryRun,
    [switch]$VerboseLog,
    [switch]$TraceLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:DryRun = [bool]$DryRun
$script:RequestedLogLevel = if ($TraceLog) {
    'trace'
} elseif ($VerboseLog) {
    'verbose'
} elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_INSTALL_LOG_LEVEL)) {
    $env:CODEX_INSTALL_LOG_LEVEL
} else {
    'normal'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$loggingModule = Join-Path $repoRoot 'script-modules\logging\logging.ps1'
if (Test-Path -LiteralPath $loggingModule) {
    . $loggingModule
} else {
    function Initialize-CodexLogging { param([string]$Level = 'normal') $script:CodexLogLevel = $Level }
    function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    function Write-WarnMsg([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
    function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
    function Write-DebugMsg([string]$Message) { if ($script:CodexLogLevel -in @('verbose', 'trace')) { Write-Host "[DEBUG] $Message" -ForegroundColor DarkCyan } }
    function Write-TraceMsg([string]$Message) { if ($script:CodexLogLevel -eq 'trace') { Write-Host "[TRACE] $Message" -ForegroundColor DarkGray } }
}
Initialize-CodexLogging -Level $script:RequestedLogLevel

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
        -RemoveSystemCodex:$RemoveSystemCodex `
        -SkipCrsConfig:$SkipCrsConfig `
        -DryRun:$DryRun `
        -VerboseLog:$VerboseLog `
        -TraceLog:$TraceLog

    if ($DryRun) {
        Write-Ok 'Dry run complete. Skipping NO_PROXY setup.'
        exit 0
    }

    Write-Host ''
    Write-Info 'Step 2/2: Configure NO_PROXY bypass (User scope)...'
    Write-Info 'NO_PROXY will be derived from config.toml base_url, plus localhost / 127.0.0.1.'
    $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }
    $configPath = Join-Path $codexHome 'config.toml'
    & $noProxyScript -ConfigPath $configPath

    Write-Host ''
    Write-Ok 'Done. Restart apps (VS Code/Codex/terminals) to pick up updated NO_PROXY.'
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
