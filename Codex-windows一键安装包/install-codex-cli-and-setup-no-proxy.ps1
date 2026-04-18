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
    # This wrapper lives under the installer folder. Use its parent as repo root so we can also find
    # the NO_PROXY setup script located elsewhere in this repo.
    $repoRoot = Split-Path -Parent $PSScriptRoot

    function Resolve-UniqueScriptPath([string]$Root, [string]$FileName) {
        $matches = @(Get-ChildItem -Path $Root -Recurse -File -Filter $FileName -ErrorAction Stop)
        if ($matches.Count -eq 0) {
            throw "Required script not found: $FileName"
        }
        if ($matches.Count -gt 1) {
            $list = ($matches | Select-Object -ExpandProperty FullName) -join '; '
            throw "Multiple matches found for ${FileName}: $list"
        }
        return $matches[0].FullName
    }

    # Keep this wrapper ASCII-only so it works even in legacy Windows PowerShell encodings.
    $installScript = Resolve-UniqueScriptPath $repoRoot 'install-codex-cli.ps1'
    $noProxyScript = Resolve-UniqueScriptPath $repoRoot 'setup_no_proxy_windows.ps1'

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
