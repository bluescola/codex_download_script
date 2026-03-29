param(
    [switch]$Quiet,
    [switch]$Repair,
    [switch]$DownloadOnly
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

function Write-Fail([string]$Message) {
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Get-VcRuntimeRegistryInfo {
    foreach ($path in @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )) {
        if (-not (Test-Path $path)) {
            continue
        }

        try {
            $item = Get-ItemProperty -Path $path -ErrorAction Stop
            return [pscustomobject]@{
                Path = $path
                Installed = [int]$item.Installed
                Version = "$($item.Version)"
                Bld = "$($item.Bld)"
                Major = "$($item.Major)"
                Minor = "$($item.Minor)"
            }
        }
        catch {
        }
    }

    return $null
}

function Resolve-InstallerAction {
    param(
        [switch]$RepairRequested
    )

    if ($RepairRequested) {
        return '/repair'
    }

    $runtime = Get-VcRuntimeRegistryInfo
    if ($runtime -and $runtime.Installed -eq 1) {
        return '/repair'
    }

    return '/install'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$downloadUrl = 'https://aka.ms/vc14/vc_redist.x64.exe'
$downloadPath = Join-Path $env:TEMP 'vc_redist.x64.latest.exe'
$logPath = Join-Path $env:TEMP ("vc_redist_x64_install_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$action = Resolve-InstallerAction -RepairRequested:$Repair

Write-Info "Microsoft Visual C++ Redistributable helper"
Write-Info "Download URL: $downloadUrl"
Write-Info "Package path: $downloadPath"

$runtime = Get-VcRuntimeRegistryInfo
if ($runtime) {
    Write-Info "Detected VC++ runtime registry entry: $($runtime.Path)"
    if (-not [string]::IsNullOrWhiteSpace($runtime.Version)) {
        Write-Info "Detected runtime version: $($runtime.Version)"
    }
    Write-Info "Selected action: $action"
}
else {
    Write-Info 'VC++ runtime registry entry not found. Selected action: /install'
}

Write-Info 'Downloading Microsoft Visual C++ Redistributable 2015-2022 (x64)...'
Invoke-WebRequest -Uri $downloadUrl -OutFile $downloadPath

if (-not (Test-Path $downloadPath)) {
    throw "Download failed: $downloadPath"
}

Write-Ok "Downloaded installer: $downloadPath"

if ($DownloadOnly) {
    Write-Ok 'Download-only mode complete.'
    exit 0
}

$args = New-Object System.Collections.Generic.List[string]
[void]$args.Add($action)
if ($Quiet) {
    [void]$args.Add('/quiet')
}
else {
    [void]$args.Add('/passive')
}
[void]$args.Add('/norestart')
[void]$args.Add('/log')
[void]$args.Add($logPath)

Write-Info "Installer log: $logPath"
Write-Info "Running installer with arguments: $($args -join ' ')"

$process = Start-Process -FilePath $downloadPath -ArgumentList $args -Wait -PassThru
$exitCode = $process.ExitCode

switch ($exitCode) {
    0 {
        Write-Ok 'Microsoft Visual C++ Redistributable installed successfully.'
        exit 0
    }
    3010 {
        Write-WarnMsg 'Microsoft Visual C++ Redistributable installed successfully. A reboot is required.'
        exit 0
    }
    default {
        Write-Fail "Installer exited with code $exitCode. See log: $logPath"
        exit $exitCode
    }
}
