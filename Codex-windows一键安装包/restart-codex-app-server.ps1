param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:CRS_OAI_KEY)) {
    Write-Host '[ERROR] CRS_OAI_KEY 未设置' -ForegroundColor Red
    exit 1
}

$loggingModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'script-modules\logging\logging.ps1'
if (Test-Path -LiteralPath $loggingModule -PathType Leaf) {
    . $loggingModule
    Initialize-CodexLogging -Level 'normal'
}
else {
    function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    function Write-WarnMsg([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
    function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
}

function Write-ErrorLog([string]$Message) {
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Get-CommandPathValue([object]$Command) {
    if ($null -eq $Command) {
        return $null
    }

    foreach ($propertyName in @('Path', 'Source')) {
        $property = $Command.PSObject.Properties[$propertyName]
        if ($null -eq $property) {
            continue
        }

        $value = [string]$property.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function ConvertTo-ExistingDirectoryPath([string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }

    try {
        $normalized = [System.IO.Path]::GetFullPath($Candidate.Trim())
    }
    catch {
        return $null
    }

    if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
        return $null
    }

    return $normalized
}

function Resolve-CodexHome {
    $candidates = @(
        [pscustomobject]@{ Source = '当前进程 CODEX_HOME'; Value = $env:CODEX_HOME },
        [pscustomobject]@{ Source = '当前用户持久化 CODEX_HOME'; Value = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') },
        [pscustomobject]@{ Source = 'USERPROFILE\.codex'; Value = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $null } else { Join-Path $env:USERPROFILE '.codex' } }
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) {
            continue
        }

        $path = ConvertTo-ExistingDirectoryPath $candidate.Value
        if ($null -eq $path) {
            throw "CODEX_HOME 候选路径不存在或不是目录（来源：$($candidate.Source)）：$($candidate.Value)"
        }

        return [pscustomobject]@{
            Path = $path
            Source = $candidate.Source
        }
    }

    throw '无法确定 CODEX_HOME：当前进程、当前用户持久化环境变量和 USERPROFILE\.codex 均不可用。'
}

function Add-CommandCandidate([System.Collections.Generic.List[string]]$Candidates, [string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($PathValue.Trim().Trim([char]34))
    }
    catch {
        return
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return
    }

    foreach ($existing in $Candidates) {
        if ($existing -ieq $fullPath) {
            return
        }
    }

    [void]$Candidates.Add($fullPath)
}

function Get-NpmPrefix {
    $npmCommand = @(Get-Command 'npm.cmd' -All -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -eq $npmCommand) {
        $npmCommand = @(Get-Command 'npm' -All -ErrorAction SilentlyContinue) | Select-Object -First 1
    }

    $npmPath = Get-CommandPathValue $npmCommand
    if ([string]::IsNullOrWhiteSpace($npmPath)) {
        return $null
    }

    try {
        $prefixOutput = @(& $npmPath config get prefix 2>$null)
        $lastExitCode = Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
        if (($null -eq $lastExitCode -or [int]$lastExitCode -eq 0) -and $prefixOutput.Count -gt 0) {
            $prefix = ([string]$prefixOutput[0]).Trim()
            if (-not [string]::IsNullOrWhiteSpace($prefix) -and $prefix -notin @('undefined', 'null')) {
                return $prefix
            }
        }
    }
    catch {
    }

    return $null
}

function Resolve-CodexCommand {
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    # Prefer the .cmd shim PowerShell resolves from PATH. It avoids selecting a
    # stale npm prefix or a PowerShell shim blocked by another execution policy.
    foreach ($command in @(Get-Command 'codex.cmd' -All -ErrorAction SilentlyContinue)) {
        Add-CommandCandidate -Candidates $candidates -PathValue (Get-CommandPathValue $command)
    }

    foreach ($command in @(Get-Command 'codex' -All -ErrorAction SilentlyContinue)) {
        $commandPath = Get-CommandPathValue $command
        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            continue
        }

        $commandDirectory = Split-Path -Parent $commandPath
        Add-CommandCandidate -Candidates $candidates -PathValue (Join-Path $commandDirectory 'codex.cmd')
        Add-CommandCandidate -Candidates $candidates -PathValue $commandPath
    }

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    $npmPrefix = Get-NpmPrefix
    foreach ($directory in @(
        $npmPrefix,
        $(if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { $null } else { Join-Path $env:APPDATA 'npm' }),
        $(if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $null } else { Join-Path $env:LOCALAPPDATA 'npm' })
    )) {
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            Add-CommandCandidate -Candidates $candidates -PathValue (Join-Path $directory 'codex.cmd')
            Add-CommandCandidate -Candidates $candidates -PathValue (Join-Path $directory 'codex.exe')
            Add-CommandCandidate -Candidates $candidates -PathValue (Join-Path $directory 'codex.ps1')
        }
    }

    if ($candidates.Count -eq 0) {
        throw '找不到 codex 命令。请先确认 Codex CLI 已安装且 codex.cmd 或 Codex npm bin 目录已加入当前 PowerShell 的 PATH。'
    }

    return $candidates[0]
}

function Invoke-CodexCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @()
    $exitCode = 0
    try {
        $output = @(& $CommandPath @Arguments 2>&1 | ForEach-Object { "$_" })
        $lastExitCode = Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $lastExitCode) {
            $exitCode = [int]$lastExitCode
        }
    }
    catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
        OutputText = ($output -join [Environment]::NewLine)
    }
}

function Write-CommandOutput([object]$Result) {
    foreach ($line in @($Result.Output)) {
        Write-Host $line
    }
}

function Test-UnsupportedDaemonCommand([string]$OutputText) {
    if ([string]::IsNullOrWhiteSpace($OutputText)) {
        return $false
    }

    return $OutputText -match '(?is)(unknown|unrecognized|invalid|unsupported|not supported|does not support|no such command|unexpected).{0,120}(command|subcommand|app-server|daemon|stop|start)|(command|subcommand|app-server|daemon|stop|start).{0,120}(unknown|unrecognized|invalid|unsupported|not supported|does not support|no such command|unexpected)'
}

function Invoke-DaemonCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('stop', 'start')]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [string]$CommandPath
    )

    Write-Info "执行：codex app-server daemon $Action"
    $result = Invoke-CodexCommand -CommandPath $CommandPath -Arguments @('app-server', 'daemon', $Action)
    Write-CommandOutput -Result $result
    if ($result.ExitCode -ne 0) {
        if (Test-UnsupportedDaemonCommand $result.OutputText) {
            throw "当前 Codex 版本不支持 app-server daemon $Action（退出码：$($result.ExitCode)）。"
        }

        throw "app-server daemon $Action 失败（退出码：$($result.ExitCode)）。"
    }
}

function Write-TroubleshootingHints {
    Write-WarnMsg '命令失败时，请分别检查：'
    Write-Host '  CRS_OAI_KEY'
    Write-Host '  codex login status'
    Write-Host '  codex app-server daemon version'
    Write-Host '  CODEX_HOME'
    Write-Host '  config.toml'
    Write-Host '  auth.json'
}

$resultCode = 0
$existingProcessValue = Get-Item -LiteralPath 'Env:CODEX_HOME' -ErrorAction SilentlyContinue
$hadProcessCodexHome = $null -ne $existingProcessValue
$previousProcessCodexHome = if ($hadProcessCodexHome) { [string]$existingProcessValue.Value } else { $null }

try {
    $codexHome = Resolve-CodexHome
    Write-Info "CODEX_HOME: $($codexHome.Path)（来源：$($codexHome.Source)）"

    $codexCommand = Resolve-CodexCommand
    Write-Info "Codex 命令路径: $codexCommand"

    $env:CODEX_HOME = $codexHome.Path

    $versionResult = Invoke-CodexCommand -CommandPath $codexCommand -Arguments @('--version')
    Write-Info '当前 Codex 版本：'
    Write-CommandOutput -Result $versionResult
    if ($versionResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($versionResult.OutputText)) {
        throw "无法读取 Codex 版本（退出码：$($versionResult.ExitCode)）。"
    }

    Write-Host ''
    Write-Info '即将停止并重新启动 codex app-server daemon'
    Write-WarnMsg '重启可能中断正在运行的 app-server 任务，请先确认没有重要任务执行。'
    $cancelled = $false
    if (-not $Force) {
        $confirmation = Read-Host '确认继续重启 app-server daemon？输入 Y 继续，其他输入取消'
        if ($confirmation -notmatch '^(?i:y|yes)$') {
            Write-WarnMsg '用户取消了 app-server daemon 重启。'
            $resultCode = 1
            $cancelled = $true
        }
    }

    if (-not $cancelled) {
        Invoke-DaemonCommand -Action 'stop' -CommandPath $codexCommand
        Invoke-DaemonCommand -Action 'start' -CommandPath $codexCommand

        Write-Info '执行 app-server daemon version，以下为原样输出：'
        $daemonVersionResult = Invoke-CodexCommand -CommandPath $codexCommand -Arguments @('app-server', 'daemon', 'version')
        Write-CommandOutput -Result $daemonVersionResult
        if ($daemonVersionResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($daemonVersionResult.OutputText)) {
            throw "重启成功但 app-server daemon version 检查失败（退出码：$($daemonVersionResult.ExitCode)）。"
        }

        Write-Ok 'app-server daemon version 检查通过。'
    }
}
catch {
    Write-ErrorLog $_.Exception.Message
    Write-TroubleshootingHints
    $resultCode = 1
}
finally {
    if ($hadProcessCodexHome) {
        $env:CODEX_HOME = $previousProcessCodexHome
    }
    else {
        Remove-Item -LiteralPath 'Env:CODEX_HOME' -ErrorAction SilentlyContinue
    }
}

exit $resultCode
