Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$UserNodeRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Join-Path $env:USERPROFILE '.local\node'
} else {
    Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
}

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
    if (-not [string]::IsNullOrWhiteSpace($UserNodeRoot)) {
        if (Test-Path (Join-Path $UserNodeRoot 'node.exe')) {
            return $UserNodeRoot
        }
    }

    if (Test-Path "$env:ProgramFiles\nodejs\node.exe") {
        return "$env:ProgramFiles\nodejs"
    }

    $alt = Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
    if (Test-Path (Join-Path $alt 'node.exe')) {
        return $alt
    }

    return $null
}

function Resolve-UserNpmRoot {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        return $null
    }

    return (Join-Path $env:APPDATA 'npm')
}

function Test-PathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
        return ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($fullRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))
    }
    catch {
        return $false
    }
}

function Get-NodeBlockingProcesses {
    $roots = @(
        $UserNodeRoot,
        (Resolve-NodeInstallDir),
        "$env:ProgramFiles\nodejs",
        (Resolve-UserNpmRoot)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $processNames = @('node.exe', 'npm.exe', 'npx.exe', 'codex.exe')
    $currentPid = [int]$PID
    $matches = @()

    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    }
    catch {
        Write-WarnMsg "Could not inspect running processes: $($_.Exception.Message)"
        return @()
    }

    foreach ($process in $processes) {
        if (-not $process -or [int]$process.ProcessId -eq $currentPid) {
            continue
        }

        if ($processNames -notcontains $process.Name) {
            continue
        }

        foreach ($root in $roots) {
            if (Test-PathUnderRoot -Path $process.ExecutablePath -Root $root) {
                $matches += $process
                break
            }
        }
    }

    return $matches
}

function Stop-NodeBlockingProcesses {
    $processes = @(Get-NodeBlockingProcesses)
    if ($processes.Count -eq 0) {
        return
    }

    Write-WarnMsg 'Detected running Node/npm/Codex processes that may lock uninstall files. They will be stopped first.'
    foreach ($process in $processes) {
        $path = if ([string]::IsNullOrWhiteSpace($process.ExecutablePath)) { '(path unavailable)' } else { $process.ExecutablePath }
        Write-WarnMsg "Stopping PID $($process.ProcessId) $($process.Name): $path"
        try {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        }
        catch {
            Write-WarnMsg "Failed to stop PID $($process.ProcessId): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Milliseconds 800

    $remaining = @(Get-NodeBlockingProcesses)
    if ($remaining.Count -gt 0) {
        foreach ($process in $remaining) {
            Write-WarnMsg "Still running PID $($process.ProcessId) $($process.Name): $($process.ExecutablePath)"
        }
        throw 'Some Node/npm/Codex processes are still running. Close Codex, terminals, VS Code, and retry as Administrator if needed.'
    }
}

function Uninstall-NodeUser {
    if ([string]::IsNullOrWhiteSpace($UserNodeRoot)) {
        return $false
    }

    if (-not (Test-Path $UserNodeRoot)) {
        return $false
    }

    Write-Info "Removing user Node.js install: $UserNodeRoot"
    Stop-NodeBlockingProcesses
    try {
        Remove-Item -LiteralPath $UserNodeRoot -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-WarnMsg "Failed to remove user Node.js install: $($_.Exception.Message)"
        Write-WarnMsg 'If access is denied, close Codex/Node/npm terminals and retry from an Administrator PowerShell.'
        throw
    }
    return $true
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
    if (Uninstall-NodeUser) {
        return $true
    }

    $entry = Find-NodeUninstallEntry
    if (-not $entry) {
        Write-WarnMsg 'Node.js uninstall entry not found (system install).'
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
