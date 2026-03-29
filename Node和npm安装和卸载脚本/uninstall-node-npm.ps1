Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Ok([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Resolve-NodeInstallDir {
    if (Test-Path "$env:ProgramFiles\nodejs\node.exe") {
        return "$env:ProgramFiles\nodejs"
    }

    $alt = Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
    if (Test-Path (Join-Path $alt 'node.exe')) {
        return $alt
    }

    return $null
}

function Find-NodeUninstallEntry {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $apps = @()
    foreach ($key in $keys) {
        $items = $null
        try {
            $items = Get-ItemProperty $key -ErrorAction SilentlyContinue
        }
        catch {
            continue
        }

        if (-not $items) {
            continue
        }

        foreach ($item in $items) {
            if (-not $item) {
                continue
            }

            if (-not $item.PSObject.Properties['DisplayName']) {
                continue
            }

            if ($item.DisplayName -like 'Node.js*') {
                $apps += $item
            }
        }
    }

    if (-not $apps -or $apps.Count -eq 0) {
        return $null
    }

    return ($apps | Select-Object -First 1)
}

function Get-MsiGuidFromUninstallString([string]$UninstallString) {
    if ([string]::IsNullOrWhiteSpace($UninstallString)) {
        return $null
    }

    if ($UninstallString -match '(?i)\{[0-9A-F-]+\}') {
        return $matches[0]
    }

    return $null
}

function Uninstall-Node {
    $entry = Find-NodeUninstallEntry
    if (-not $entry) {
        Write-WarnMsg 'Node.js uninstall entry not found.'
        return $false
    }

    Write-Info "Found: $($entry.DisplayName)"

    $guid = Get-MsiGuidFromUninstallString $entry.UninstallString
    if (-not $guid) {
        Write-WarnMsg "Could not parse MSI GUID from UninstallString: $($entry.UninstallString)"
        return $false
    }

    Write-Info "Uninstalling MSI: $guid"
    $proc = Start-Process msiexec.exe -Wait -Verb RunAs -PassThru -ArgumentList "/x $guid /qn /norestart"
    if ($proc.ExitCode -ne 0) {
        Write-WarnMsg "msiexec exited with code $($proc.ExitCode)"
        return $false
    }
    return $true
}

Write-Info 'Starting Node.js uninstall...'
$did = Uninstall-Node

$dir = Resolve-NodeInstallDir
if ($dir -and (Test-Path (Join-Path $dir 'node.exe'))) {
    Write-WarnMsg "Node.js still present at: $dir"
} else {
    Write-Ok 'Node.js appears removed.'
}

if (-not $did) {
    Write-WarnMsg 'Uninstall may not have run. If Node is still present, uninstall manually via Apps & Features.'
}

Write-Host ''
Write-Host 'Done. Reopen PowerShell/cmd before re-checking node/npm.' -ForegroundColor White
