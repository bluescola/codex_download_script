param(
    [switch]$ForceReinstall
)

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

function Refresh-Path {
    $extraPaths = @(
        $UserNodeRoot,
        "$env:APPDATA\npm"
    )

    $current = $env:Path -split ';'
    foreach ($p in $extraPaths) {
        if ((Test-Path $p) -and -not ($current -contains $p)) {
            $env:Path = "$env:Path;$p"
        }
    }
}

function Ensure-UserPathContains([string]$PathEntry) {
    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return
    }

    if (-not (Test-Path $PathEntry)) {
        return
    }

    $normalizedEntry = $PathEntry.Trim().TrimEnd('\')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $parts = $userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    foreach ($p in $parts) {
        if ($p.Trim().TrimEnd('\') -ieq $normalizedEntry) {
            return
        }
    }

    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
        $normalizedEntry
    } else {
        "$userPath;$normalizedEntry"
    }

    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Write-Info "Added to USER PATH: $normalizedEntry"
}

function Resolve-NodeInstallDir {
    if (-not [string]::IsNullOrWhiteSpace($UserNodeRoot)) {
        if (Test-Path (Join-Path $UserNodeRoot 'node.exe')) {
            return $UserNodeRoot
        }
    }

    return $null
}

function Node-And-Npm-Ready {
    if ([string]::IsNullOrWhiteSpace($UserNodeRoot)) {
        return $false
    }

    return (Test-Path (Join-Path $UserNodeRoot 'node.exe')) -and (Test-Path (Join-Path $UserNodeRoot 'npm.cmd'))
}

function Get-NodeLtsZipInfo {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $idx = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
    $lts = $null
    foreach ($item in $idx) {
        if ($item.lts -and ($item.files -contains 'win-x64-zip')) {
            $lts = $item
            break
        }
    }

    if (-not $lts) {
        throw 'Could not resolve a Node.js LTS x64 zip from nodejs.org'
    }

    return $lts
}

function Install-NodeUserZip {
    Write-Info 'Installing Node.js LTS to user directory (no admin)...'

    $lts = Get-NodeLtsZipInfo
    $version = $lts.version
    $zipUrl = "https://nodejs.org/dist/$version/node-$version-win-x64.zip"
    $zipPath = Join-Path $env:TEMP "node-$version-win-x64.zip"
    $extractRoot = Join-Path $env:TEMP "node-$version-win-x64"

    Write-Info "Version: $version"
    Write-Info "URL: $zipUrl"

    if (Test-Path $extractRoot) {
        Remove-Item -Recurse -Force $extractRoot
    }

    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $env:TEMP -Force

    if (-not (Test-Path $extractRoot)) {
        throw "Extracted Node.js folder not found: $extractRoot"
    }

    if (Test-Path $UserNodeRoot) {
        Remove-Item -Recurse -Force $UserNodeRoot
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $UserNodeRoot) -Force | Out-Null
    Move-Item -Path $extractRoot -Destination $UserNodeRoot

    if (-not (Test-Path (Join-Path $UserNodeRoot 'node.exe'))) {
        throw "node.exe not found in: $UserNodeRoot"
    }

    Write-Info "Installed to: $UserNodeRoot"
    return $true
}

function Ensure-Node {
    if ((Node-And-Npm-Ready) -and -not $ForceReinstall) {
        Ensure-UserPathContains $UserNodeRoot
        if (-not (($env:Path -split ';') -contains $UserNodeRoot)) {
            $env:Path = "$UserNodeRoot;$env:Path"
        }
        Write-Info 'Node.js and npm already present (user install).'
        return $true
    }

    if ($ForceReinstall -and (Test-Path $UserNodeRoot)) {
        Write-Info "Removing previous user Node.js install at $UserNodeRoot"
        Remove-Item -Recurse -Force $UserNodeRoot
    }

    $ok = Install-NodeUserZip
    Ensure-UserPathContains $UserNodeRoot
    if (-not (($env:Path -split ';') -contains $UserNodeRoot)) {
        $env:Path = "$UserNodeRoot;$env:Path"
    }
    Refresh-Path

    if (-not $ok) {
        return $false
    }

    if (-not (Node-And-Npm-Ready)) {
        Write-WarnMsg 'Node.js/npm not detected after install. Reopen PowerShell and retry.'
        return $false
    }

    return $true
}

function Ensure-ExecutionPolicy {
    try {
        $policy = Get-ExecutionPolicy -Scope CurrentUser
        if ($policy -ne 'RemoteSigned') {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Write-Info 'Set CurrentUser execution policy to RemoteSigned.'
        } else {
            Write-Info 'CurrentUser execution policy is already RemoteSigned.'
        }
    }
    catch {
        try {
            $policyAfter = Get-ExecutionPolicy -Scope CurrentUser
            if ($policyAfter -eq 'RemoteSigned') {
                Write-Info 'CurrentUser execution policy is RemoteSigned.'
                return
            }
        }
        catch {
        }

        Write-WarnMsg "Could not set execution policy automatically: $($_.Exception.Message)"
    }
}

function Verify-NodeNpm {
    $sys = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $usr = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$sys;$usr"
    Refresh-Path

    $dir = Resolve-NodeInstallDir
    if (-not $dir) {
        Write-WarnMsg 'Node.js install folder not found under user directory.'
        return
    }

    $nodeExe = Join-Path $dir 'node.exe'
    $npmCmd = Join-Path $dir 'npm.cmd'

    if (Test-Path $nodeExe) {
        Write-Ok "node: $(& $nodeExe -v)"
    } else {
        Write-WarnMsg "node.exe not found in: $dir"
    }

    if (Test-Path $npmCmd) {
        Write-Ok "npm (via npm.cmd): $(& $npmCmd -v)"
    } else {
        Write-WarnMsg "npm.cmd not found in: $dir"
    }
}

Write-Info 'Starting Node.js LTS install...'
$installed = Ensure-Node
Write-Info 'Setting PowerShell execution policy...'
Ensure-ExecutionPolicy
Write-Info 'Verifying node/npm...'
Verify-NodeNpm

if (-not $installed) {
    Write-WarnMsg 'Install was not confirmed. Review the messages above and retry.'
}

Write-Host ''
Write-Host 'Done. If your current shell does not see new PATH values, reopen PowerShell.' -ForegroundColor White
