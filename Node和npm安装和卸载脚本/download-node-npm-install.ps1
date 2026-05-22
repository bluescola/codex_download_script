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

function Get-NodeExpectedSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $shaUrl = "https://nodejs.org/dist/$Version/SHASUMS256.txt"
    Write-Info "Downloading checksum manifest: $shaUrl"
    $manifest = Invoke-WebRequest -Uri $shaUrl -UseBasicParsing
    foreach ($line in ($manifest.Content -split "`r?`n")) {
        if ($line -match '^([0-9a-fA-F]{64})\s+(.+)$' -and $matches[2] -eq $FileName) {
            return $matches[1].ToLowerInvariant()
        }
    }

    throw "Could not find checksum for $FileName in $shaUrl"
}

function Assert-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedHash
    )

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedHash.ToLowerInvariant()) {
        throw "SHA256 verification failed for $Path. Expected $ExpectedHash, got $actual"
    }

    Write-Ok "SHA256 verified: $actual"
}

function Install-ExtractedNodeAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtractRoot,
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot
    )

    $parent = Split-Path -Parent $TargetRoot
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    $backupRoot = $null
    if (Test-Path -LiteralPath $TargetRoot) {
        $backupSuffix = "{0}.{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $backupRoot = "$TargetRoot.bak.$backupSuffix"
        Write-Info "Moving existing Node.js install to backup: $backupRoot"
        Move-Item -LiteralPath $TargetRoot -Destination $backupRoot -Force
    }

    try {
        Move-Item -LiteralPath $ExtractRoot -Destination $TargetRoot -Force
        if (-not (Test-Path -LiteralPath (Join-Path $TargetRoot 'node.exe'))) {
            throw "node.exe not found in: $TargetRoot"
        }

        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
        }
    }
    catch {
        if ((-not (Test-Path -LiteralPath $TargetRoot)) -and $backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $TargetRoot -Force
        }
        throw
    }
}

function Install-NodeUserZip {
    Write-Info 'Installing Node.js LTS to user directory (no admin)...'

    $lts = Get-NodeLtsZipInfo
    $version = $lts.version
    $zipName = "node-$version-win-x64.zip"
    $zipUrl = "https://nodejs.org/dist/$version/$zipName"
    $tempRoot = Join-Path $env:TEMP ("codex-node-install-{0}" -f ([guid]::NewGuid().ToString('N')))
    $zipPath = Join-Path $tempRoot $zipName
    $extractRoot = Join-Path $tempRoot "node-$version-win-x64"

    Write-Info "Version: $version"
    Write-Info "URL: $zipUrl"

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        $expectedHash = Get-NodeExpectedSha256 -Version $version -FileName $zipName
        Assert-FileSha256 -Path $zipPath -ExpectedHash $expectedHash

        Expand-Archive -Path $zipPath -DestinationPath $tempRoot -Force

        if (-not (Test-Path -LiteralPath $extractRoot)) {
            throw "Extracted Node.js folder not found: $extractRoot"
        }

        Install-ExtractedNodeAtomically -ExtractRoot $extractRoot -TargetRoot $UserNodeRoot
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

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
        Write-Info "Force reinstall requested; existing user Node.js install will be replaced atomically: $UserNodeRoot"
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
