param(
    [switch]$ForceReinstall
)

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

function Refresh-Path {
    $extraPaths = @(
        "$env:ProgramFiles\nodejs",
        "$env:APPDATA\npm"
    )

    $current = $env:Path -split ';'
    foreach ($p in $extraPaths) {
        if ((Test-Path $p) -and -not ($current -contains $p)) {
            $env:Path = "$env:Path;$p"
        }
    }
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

function Node-And-Npm-Ready {
    $dir = Resolve-NodeInstallDir
    if (-not $dir) {
        return $false
    }

    return (Test-Path (Join-Path $dir 'node.exe')) -and (Test-Path (Join-Path $dir 'npm.cmd'))
}

function Install-Node-WithMsi {
    Write-Info "Downloading Node.js LTS MSI..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $idx = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
    $lts = $null
    foreach ($item in $idx) {
        if ($item.lts -and ($item.files -contains 'win-x64-msi')) {
            $lts = $item
            break
        }
    }

    if (-not $lts) {
        throw 'Could not resolve a Node.js LTS x64 MSI from nodejs.org'
    }

    $version = $lts.version
    $url = "https://nodejs.org/dist/$version/node-$version-x64.msi"
    $msi = Join-Path $env:USERPROFILE "Desktop\node-$version-x64.msi"

    Write-Info "Version: $version"
    Write-Info "URL: $url"
    Write-Info "Saving to: $msi"

    if (-not (Test-Path $msi)) {
        Invoke-WebRequest -Uri $url -OutFile $msi
        Write-Info 'Download complete.'
    } else {
        Write-Info 'Installer already exists.'
    }

    Write-Info 'Starting silent install (UAC may prompt)...'
    $proc = Start-Process msiexec.exe -Wait -Verb RunAs -PassThru -ArgumentList "/i `"$msi`" /qn /norestart"
    $code = $proc.ExitCode

    if ($code -ne 0) {
        if ($code -eq 1602) {
            Write-WarnMsg 'Install was canceled (UAC prompt denied or closed).'
        } else {
            Write-WarnMsg "msiexec exited with code $code"
        }
        return $false
    }

    Write-Info 'Install finished.'
    return $true
}

function Ensure-Node {
    if ((Node-And-Npm-Ready) -and -not $ForceReinstall) {
        Write-Info 'Node.js and npm already present.'
        return $true
    }

    $ok = Install-Node-WithMsi
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
        Write-WarnMsg 'Node.js install folder not found (Program Files or LocalAppData).'
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
    Write-WarnMsg 'Install was not confirmed. If you saw a UAC prompt, please accept it and rerun.'
}

Write-Host ''
Write-Host 'Done. If your current shell does not see new PATH values, reopen PowerShell.' -ForegroundColor White
