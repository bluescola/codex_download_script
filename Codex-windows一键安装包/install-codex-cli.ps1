param(
    [switch]$ForceNodeReinstall,
    [switch]$ForceCodexReinstall,
    [switch]$SkipCrsConfig,
    [switch]$RemoveSystemCodex,
    [string]$UninstallSystemCodexPrefix,
    [string]$NpmCommandPath,
    [switch]$DryRun,
    [switch]$VerboseLog,
    [switch]$TraceLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ContainsNonAscii([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return [regex]::IsMatch($Value, '[^\x00-\x7F]')
}

function Resolve-AsciiSafeRoot {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        $env:CODEX_WINDOWS_ASCII_ROOT,
        'C:\Codex'
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            [void]$candidates.Add($candidate)
        }
    }

    foreach ($candidate in $candidates) {
        $trimmed = $candidate.Trim().TrimEnd('\')
        if (-not (Test-ContainsNonAscii $trimmed)) {
            return $trimmed
        }
    }

    return 'C:\Codex'
}

function Test-NeedsAsciiSafePaths {
    foreach ($value in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, $env:TMP)) {
        if (Test-ContainsNonAscii $value) {
            return $true
        }
    }

    return $false
}

function Initialize-CodexPathSettings {
    $script:UseAsciiSafePaths = Test-NeedsAsciiSafePaths
    $script:CodexAsciiRoot = Resolve-AsciiSafeRoot
    $script:CodexNpmPrefix = if ($script:UseAsciiSafePaths -or [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        Join-Path $script:CodexAsciiRoot 'npm'
    } else {
        Join-Path $env:APPDATA 'npm'
    }
    $script:CodexNpmCache = if ($script:UseAsciiSafePaths -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $script:CodexAsciiRoot 'npm-cache'
    } else {
        Join-Path $env:LOCALAPPDATA 'npm-cache'
    }
    $script:CodexTempRoot = if ($script:UseAsciiSafePaths) {
        Join-Path $script:CodexAsciiRoot 'temp'
    } else {
        $env:TEMP
    }
    $script:CodexHome = if ($script:UseAsciiSafePaths -or [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Join-Path $script:CodexAsciiRoot '.codex'
    } else {
        Join-Path $env:USERPROFILE '.codex'
    }
    $script:UserNodeRoot = if ($script:UseAsciiSafePaths) {
        Join-Path $script:CodexAsciiRoot 'nodejs'
    } elseif ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:USERPROFILE '.local\node'
    } else {
        Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
    }
}

function Ensure-CodexPathSettings {
    $requiredNames = @(
        'UseAsciiSafePaths',
        'CodexAsciiRoot',
        'CodexNpmPrefix',
        'CodexNpmCache',
        'CodexTempRoot',
        'CodexHome',
        'UserNodeRoot'
    )

    foreach ($name in $requiredNames) {
        if (-not (Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue)) {
            Write-WarnMsg "Codex path setting missing before use: script:$name. Reinitializing path settings."
            Initialize-CodexPathSettings
            return
        }
    }
}

function Get-CodexNpmPrefix {
    Ensure-CodexPathSettings
    if ([string]::IsNullOrWhiteSpace($script:CodexNpmPrefix)) {
        Initialize-CodexPathSettings
    }

    if ([string]::IsNullOrWhiteSpace($script:CodexNpmPrefix)) {
        throw 'Codex npm prefix is not initialized.'
    }

    return $script:CodexNpmPrefix
}

function Get-CodexNpmCache {
    Ensure-CodexPathSettings
    if ([string]::IsNullOrWhiteSpace($script:CodexNpmCache)) {
        Initialize-CodexPathSettings
    }

    if ([string]::IsNullOrWhiteSpace($script:CodexNpmCache)) {
        throw 'Codex npm cache is not initialized.'
    }

    return $script:CodexNpmCache
}

Initialize-CodexPathSettings
$script:NpmCommandOverride = $NpmCommandPath
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

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LoggingModule = Join-Path $script:RepoRoot 'script-modules\logging\logging.ps1'
if (Test-Path -LiteralPath $script:LoggingModule) {
    . $script:LoggingModule
} else {
    function Initialize-CodexLogging { param([string]$Level = 'normal') $script:CodexLogLevel = $Level }
    function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    function Write-WarnMsg([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
    function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
    function Write-DebugMsg([string]$Message) { if ($script:CodexLogLevel -in @('verbose', 'trace')) { Write-Host "[DEBUG] $Message" -ForegroundColor DarkCyan } }
    function Write-TraceMsg([string]$Message) { if ($script:CodexLogLevel -eq 'trace') { Write-Host "[TRACE] $Message" -ForegroundColor DarkGray } }
}
Initialize-CodexLogging -Level $script:RequestedLogLevel

function Initialize-AsciiSafeEnvironment {
    Ensure-CodexPathSettings

    if (-not $script:UseAsciiSafePaths) {
        return
    }

    Write-WarnMsg 'Detected non-ASCII characters in Windows user paths. Using an ASCII-only Codex root to avoid Node/npm/Codex native path issues.'
    Write-Info "ASCII Codex root: $script:CodexAsciiRoot"

    foreach ($dir in @(
        $script:CodexAsciiRoot,
        $script:CodexNpmPrefix,
        $script:CodexNpmCache,
        $script:CodexTempRoot,
        $script:CodexHome,
        (Split-Path -Parent $UserNodeRoot)
    )) {
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # Lock ASCII-safe root directory to current user only.
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    try {
        $aclArgs = @(
            $script:CodexAsciiRoot, '/inheritance:r', '/grant:r',
            "${currentUser}:(OI)(CI)F", '/Q'
        )
        & icacls @aclArgs 2>$null
        Write-Info "Secured ASCII-safe root to current user: $currentUser"
    } catch {
        Write-WarnMsg "Unable to set ACL on ASCII-safe root. Ensure adequate permissions on: $script:CodexAsciiRoot"
    }

    $env:CODEX_HOME = $script:CodexHome
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $script:CodexHome, 'User')
}

function Get-EnvState([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'not set'
    }

    return 'set'
}

function Get-CommandSummary([string]$Name) {
    $commands = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        return 'not found'
    }

    $paths = @()
    foreach ($command in $commands) {
        foreach ($propertyName in @('Path', 'Source')) {
            $matches = @($command.PSObject.Properties.Match($propertyName))
            if ($matches.Count -gt 0) {
                $value = [string]$matches[0].Value
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $paths += $value
                    break
                }
            }
        }
    }

    if ($paths.Count -eq 0) {
        return 'found, path unknown'
    }

    return (($paths | Select-Object -Unique) -join '; ')
}

function Get-VersionSummary([string]$Name) {
    try {
        $command = Get-Command $Name -ErrorAction Stop
        $path = $command.Path
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = $command.Source
        }
        if ([string]::IsNullOrWhiteSpace($path)) {
            return 'not available'
        }

        $output = & $path --version 2>$null | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($output)) {
            return 'not available'
        }

        return "$output".Trim()
    }
    catch {
        return 'not available'
    }
}

function Write-PreflightSummary {
    Ensure-CodexPathSettings

    Write-Info 'Preflight environment summary:'
    Write-Info "  Platform: Windows $([Environment]::OSVersion.VersionString)"
    Write-Info "  PowerShell: $($PSVersionTable.PSVersion)"
    Write-Info "  User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Info "  Administrator: $(Test-IsAdministrator)"
    Write-Info "  ExecutionPolicy(CurrentUser): $(Get-ExecutionPolicy -Scope CurrentUser)"
    Write-DebugMsg "ExecutionPolicy(UserPolicy): $(Get-ExecutionPolicy -Scope UserPolicy)"
    Write-DebugMsg "ExecutionPolicy(MachinePolicy): $(Get-ExecutionPolicy -Scope MachinePolicy)"
    Write-Info "  ASCII-safe mode: $script:UseAsciiSafePaths"
    Write-Info "  ASCII Codex root: $script:CodexAsciiRoot"
    Write-Info "  CODEX_HOME target: $script:CodexHome"
    Write-Info "  npm prefix target: $script:CodexNpmPrefix"
    Write-DebugMsg "npm cache target: $script:CodexNpmCache"
    Write-DebugMsg "temp root target: $script:CodexTempRoot"
    Write-DebugMsg "user Node root target: $script:UserNodeRoot"
    Write-Info "  node: $(Get-CommandSummary 'node') ($(Get-VersionSummary 'node'))"
    Write-Info "  npm: $(Get-CommandSummary 'npm') ($(Get-VersionSummary 'npm'))"
    Write-Info "  codex: $(Get-CommandSummary 'codex') ($(Get-VersionSummary 'codex'))"
    Write-DebugMsg "NPM_CONFIG_PREFIX: $(Get-EnvState 'NPM_CONFIG_PREFIX')"
    Write-DebugMsg "NPM_CONFIG_CACHE: $(Get-EnvState 'NPM_CONFIG_CACHE')"
    Write-DebugMsg "NPM_CONFIG_USERCONFIG: $(Get-EnvState 'NPM_CONFIG_USERCONFIG')"
    Write-DebugMsg "Proxy env: HTTP_PROXY=$(Get-EnvState 'HTTP_PROXY'), HTTPS_PROXY=$(Get-EnvState 'HTTPS_PROXY'), ALL_PROXY=$(Get-EnvState 'ALL_PROXY'), NO_PROXY=$(Get-EnvState 'NO_PROXY')"
    Write-DebugMsg "Options: ForceNode=$ForceNodeReinstall ForceCodex=$ForceCodexReinstall RemoveSystem=$RemoveSystemCodex SkipCrs=$SkipCrsConfig DryRun=$script:DryRun LogLevel=$script:CodexLogLevel"
    Write-TraceMsg "PATH: $env:Path"
}

function Command-Exists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Format-ExitCodeHex([int]$ExitCode) {
    return ('0x{0:X8}' -f ([uint32]$ExitCode))
}

function Get-CodexRuntimeHint([int]$ExitCode) {
    switch ($ExitCode) {
        -1073741515 {
            $hint = 'Windows could not start the Codex binary because a required DLL is missing. Install or repair Microsoft Visual C++ Redistributable 2015-2022 (x64), then retry.'
            $helperScript = Join-Path $PSScriptRoot 'install-vc-redist-x64.cmd'
            if (Test-Path $helperScript) {
                $hint += ' You can run install-vc-redist-x64.cmd from this package.'
            }
            $hint += ' If the runtime is already installed, inspect antivirus/AppLocker and the native executable under the configured npm prefix (for example %APPDATA%\npm or C:\Codex\npm).'
            return $hint
        }
        default {
            return $null
        }
    }
}

function New-CodexNativeExitMessage([string]$CommandLabel, [int]$ExitCode, [string]$OutputText) {
    $message = "$CommandLabel exited with code $ExitCode ($(Format-ExitCodeHex $ExitCode))."
    if (-not [string]::IsNullOrWhiteSpace($OutputText)) {
        $message += " Output: $OutputText"
    }

    $hint = Get-CodexRuntimeHint $ExitCode
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        $message += " $hint"
    }

    return $message
}

function Invoke-CodexVersionCommand([string]$CommandPath) {
    $savedErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $CommandPath --version 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorAction
    }

    $lines = @(
        @($output) |
        ForEach-Object { "$_".Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    return [pscustomobject]@{
        ExitCode = $exitCode
        ExitCodeHex = (Format-ExitCodeHex $exitCode)
        Output = $lines
        OutputText = ($lines -join ' ')
        Hint = (Get-CodexRuntimeHint $exitCode)
    }
}

function New-CodexVersionFailureMessage([string]$CommandLabel, [object]$Result) {
    if ($Result.ExitCode -ne 0) {
        return (New-CodexNativeExitMessage $CommandLabel $Result.ExitCode $Result.OutputText)
    }

    if ([string]::IsNullOrWhiteSpace($Result.OutputText)) {
        return "$CommandLabel exited with code 0 but returned no version output."
    }

    return $null
}

function Refresh-Path {
    Ensure-CodexPathSettings

    $extraPaths = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($UserNodeRoot)) {
        [void]$extraPaths.Add($UserNodeRoot)
    }
    $nodeInstallDir = Resolve-NodeInstallDir
    if (-not [string]::IsNullOrWhiteSpace($nodeInstallDir)) {
        [void]$extraPaths.Add($nodeInstallDir)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        [void]$extraPaths.Add("$env:ProgramFiles\nodejs")
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CodexNpmPrefix)) {
        [void]$extraPaths.Add($script:CodexNpmPrefix)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        [void]$extraPaths.Add("$env:APPDATA\npm")
    }

    $current = $env:Path -split ';'
    foreach ($p in @($extraPaths | Select-Object -Unique)) {
        if ((Test-Path $p) -and -not ($current -contains $p)) {
            $env:Path = "$env:Path;$p"
        }
    }
}

function Ensure-UserPathContains([string]$PathEntry, [switch]$Prepend) {
    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return
    }

    $normalizedEntry = $PathEntry.Trim().TrimEnd('\')
    if (-not (Test-Path $normalizedEntry)) {
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $parts = $userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $exists = $false
    $remainingParts = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        if ($p.Trim().TrimEnd('\') -ieq $normalizedEntry) {
            $exists = $true
            continue
        }

        [void]$remainingParts.Add($p)
    }

    if ((-not $exists) -or $Prepend) {
        $newParts = New-Object System.Collections.Generic.List[string]
        if ($Prepend) {
            [void]$newParts.Add($normalizedEntry)
            foreach ($p in $remainingParts) { [void]$newParts.Add($p) }
        }
        else {
            foreach ($p in $remainingParts) { [void]$newParts.Add($p) }
            [void]$newParts.Add($normalizedEntry)
        }

        $newUserPath = ($newParts.ToArray() -join ';')
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        if ($exists -and $Prepend) {
            Write-Info "Moved to front of USER PATH: $normalizedEntry"
        }
        else {
            Write-Info "Added to USER PATH: $normalizedEntry"
        }
    }
}

function Ensure-CurrentPathContains([string]$PathEntry, [switch]$Prepend) {
    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return
    }

    $normalizedEntry = $PathEntry.Trim().TrimEnd('\')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($env:Path)) {
        $parts = $env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $exists = $false
    $remainingParts = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        if ($p.Trim().TrimEnd('\') -ieq $normalizedEntry) {
            $exists = $true
            continue
        }

        [void]$remainingParts.Add($p)
    }

    if ((-not $exists) -or $Prepend) {
        $newParts = New-Object System.Collections.Generic.List[string]
        if ($Prepend) {
            [void]$newParts.Add($normalizedEntry)
            foreach ($p in $remainingParts) { [void]$newParts.Add($p) }
        }
        else {
            foreach ($p in $remainingParts) { [void]$newParts.Add($p) }
            [void]$newParts.Add($normalizedEntry)
        }

        $env:Path = ($newParts.ToArray() -join ';')
    }
}

function Resolve-NpmGlobalBinDir {
    Ensure-CodexPathSettings
    return $script:CodexNpmPrefix
}

function Normalize-ComparablePath([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    try {
        return ([System.IO.Path]::GetFullPath($PathValue).TrimEnd([char[]]@('\', '/')))
    }
    catch {
        return ($PathValue.Trim().TrimEnd([char[]]@('\', '/')))
    }
}

function Test-PathUnderRoot([string]$PathValue, [string]$RootValue) {
    $path = Normalize-ComparablePath $PathValue
    $root = Normalize-ComparablePath $RootValue

    if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($root)) {
        return $false
    }

    if ($path -ieq $root) {
        return $true
    }

    return $path.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ProcessesUsingRoots {
    param(
        [string[]]$Roots
    )

    $normalizedRoots = @(
        foreach ($root in @($Roots)) {
            $normalized = Normalize-ComparablePath $root
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                $normalized
            }
        }
    )

    if ($normalizedRoots.Count -eq 0) {
        return @()
    }

    $currentPid = $PID
    $processMatches = @()
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if ($process.ProcessId -eq $currentPid) {
            continue
        }

        $executablePath = [string]$process.ExecutablePath
        $commandLine = [string]$process.CommandLine
        foreach ($root in $normalizedRoots) {
            $commandLineUsesRoot = (-not [string]::IsNullOrWhiteSpace($commandLine)) -and
                ($commandLine.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            if ((Test-PathUnderRoot $executablePath $root) -or $commandLineUsesRoot) {
                $processMatches += [pscustomobject]@{
                    ProcessId = [int]$process.ProcessId
                    Name = [string]$process.Name
                    ExecutablePath = $executablePath
                    CommandLine = $commandLine
                    Root = $root
                }
                break
            }
        }
    }

    return $processMatches
}

function Stop-ProcessesUsingRoots {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Roots,
        [string]$Reason = 'install path replacement'
    )

    $processes = @(Get-ProcessesUsingRoots -Roots $Roots)
    if ($processes.Count -eq 0) {
        return
    }

    Write-WarnMsg "Stopping $($processes.Count) process(es) using paths needed for $Reason."
    foreach ($process in $processes) {
        Write-WarnMsg "Stopping PID $($process.ProcessId) $($process.Name): $($process.ExecutablePath)"
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
        catch {
            Write-WarnMsg "Failed to stop PID $($process.ProcessId): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 1

    $remaining = @(Get-ProcessesUsingRoots -Roots $Roots)
    if ($remaining.Count -gt 0) {
        $details = ($remaining | ForEach-Object { "PID $($_.ProcessId) $($_.Name)" }) -join '; '
        throw "Cannot continue $Reason because these processes still use the target path: $details. Close them and retry."
    }
}

function Get-KnownSystemNpmPrefixes {
    $prefixes = @()
    $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $programData = [Environment]::GetEnvironmentVariable('ProgramData')

    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $prefixes += (Join-Path $programFiles 'nodejs')
    }
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $prefixes += (Join-Path $programFilesX86 'nodejs')
    }
    if (-not [string]::IsNullOrWhiteSpace($programData)) {
        $prefixes += (Join-Path $programData 'npm')
        $prefixes += (Join-Path $programData 'nodejs')
    }

    $seen = @{}
    $result = @()
    foreach ($prefix in $prefixes) {
        $normalized = Normalize-ComparablePath $prefix
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        $key = $normalized.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $normalized
        }
    }

    return $result
}

function Test-IsSystemInstallPath([string]$PathValue) {
    foreach ($prefix in Get-KnownSystemNpmPrefixes) {
        if (Test-PathUnderRoot $PathValue $prefix) {
            return $true
        }
    }

    return $false
}

function Test-IsKnownSystemNpmPrefix([string]$PathValue) {
    $path = Normalize-ComparablePath $PathValue
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    foreach ($prefix in Get-KnownSystemNpmPrefixes) {
        if ($path -ieq $prefix) {
            return $true
        }
    }

    return $false
}

function Test-IsSystemLevelCodexPath([string]$PathValue, [string]$UserNpmBinDir) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    if ((-not [string]::IsNullOrWhiteSpace($UserNpmBinDir)) -and (Test-PathUnderRoot $PathValue $UserNpmBinDir)) {
        return $false
    }

    return (Test-IsSystemInstallPath $PathValue)
}

function Resolve-NpmCommandPath {
    Ensure-CodexPathSettings

    if ((-not [string]::IsNullOrWhiteSpace($script:NpmCommandOverride)) -and (Test-Path -LiteralPath $script:NpmCommandOverride)) {
        return $script:NpmCommandOverride
    }

    foreach ($name in @('npm.cmd', 'npm')) {
        $cmd = @(Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($cmd.Count -eq 0) {
            continue
        }

        foreach ($propertyName in @('Path', 'Source')) {
            $matches = @($cmd[0].PSObject.Properties.Match($propertyName))
            if ($matches.Count -gt 0) {
                $value = [string]$matches[0].Value
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    return $value
                }
            }
        }
    }

    return $null
}

function Add-SystemCodexCandidate {
    param(
        [System.Collections.Generic.List[object]]$Candidates,
        [hashtable]$Seen,
        [Parameter(Mandatory = $true)]
        [string]$CommandPath,
        [string]$PrefixDir,
        [string]$UserNpmBinDir
    )

    if ([string]::IsNullOrWhiteSpace($CommandPath) -or -not (Test-Path -LiteralPath $CommandPath)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($PrefixDir)) {
        $PrefixDir = Split-Path -Parent $CommandPath
    }

    if ([string]::IsNullOrWhiteSpace($PrefixDir) -or -not (Test-IsSystemLevelCodexPath $CommandPath $UserNpmBinDir)) {
        return
    }

    $normalizedPrefix = Normalize-ComparablePath $PrefixDir
    if ([string]::IsNullOrWhiteSpace($normalizedPrefix) -or -not (Test-IsKnownSystemNpmPrefix $normalizedPrefix)) {
        return
    }

    $key = $normalizedPrefix.ToLowerInvariant()
    if ($Seen.ContainsKey($key)) {
        return
    }

    $Seen[$key] = $true
    [void]$Candidates.Add([pscustomobject]@{
        PrefixDir = $normalizedPrefix
        CommandPath = (Normalize-ComparablePath $CommandPath)
    })
}

function Find-SystemCodexInstalls([string]$UserNpmBinDir) {
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}

    foreach ($name in @('codex', 'codex.cmd', 'codex.ps1')) {
        $commands = @(Get-Command $name -All -ErrorAction SilentlyContinue)
        foreach ($cmd in $commands) {
            $commandPath = $null
            foreach ($propertyName in @('Path', 'Source')) {
                $matches = @($cmd.PSObject.Properties.Match($propertyName))
                if ($matches.Count -gt 0) {
                    $value = [string]$matches[0].Value
                    if (-not [string]::IsNullOrWhiteSpace($value)) {
                        $commandPath = $value
                        break
                    }
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
                Add-SystemCodexCandidate -Candidates $candidates -Seen $seen -CommandPath $commandPath -UserNpmBinDir $UserNpmBinDir
            }
        }
    }

    $prefixSeen = @{}
    foreach ($prefix in Get-KnownSystemNpmPrefixes) {
        $normalizedPrefix = Normalize-ComparablePath $prefix
        if ([string]::IsNullOrWhiteSpace($normalizedPrefix)) {
            continue
        }

        $prefixKey = $normalizedPrefix.ToLowerInvariant()
        if ($prefixSeen.ContainsKey($prefixKey)) {
            continue
        }
        $prefixSeen[$prefixKey] = $true

        foreach ($fileName in @('codex.cmd', 'codex.ps1', 'codex')) {
            $candidatePath = Join-Path $normalizedPrefix $fileName
            Add-SystemCodexCandidate -Candidates $candidates -Seen $seen -CommandPath $candidatePath -PrefixDir $normalizedPrefix -UserNpmBinDir $UserNpmBinDir
        }

        $packageDir = Join-Path $normalizedPrefix 'node_modules\@openai\codex'
        Add-SystemCodexCandidate -Candidates $candidates -Seen $seen -CommandPath $packageDir -PrefixDir $normalizedPrefix -UserNpmBinDir $UserNpmBinDir
    }

    return $candidates.ToArray()
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Remove-KnownSystemCodexFiles([string]$PrefixDir) {
    $prefix = Normalize-ComparablePath $PrefixDir
    if ([string]::IsNullOrWhiteSpace($prefix) -or -not (Test-IsKnownSystemNpmPrefix $prefix)) {
        throw "Refusing to remove Codex files outside a system install prefix: $PrefixDir"
    }

    $targets = @(
        (Join-Path $prefix 'codex'),
        (Join-Path $prefix 'codex.cmd'),
        (Join-Path $prefix 'codex.ps1'),
        (Join-Path $prefix 'node_modules\@openai\codex')
    )

    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) {
            continue
        }
        if (-not (Test-PathUnderRoot $target $prefix)) {
            throw "Refusing to remove Codex target outside prefix: $target"
        }

        try {
            $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop
            if ($item.PSIsContainer) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            }
            else {
                Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            }
            Write-Info "Removed system Codex residue: $target"
        }
        catch {
            Write-WarnMsg "Failed to remove system Codex residue ${target}: $($_.Exception.Message)"
        }
    }
}

function ConvertTo-PowerShellSingleQuotedLiteral([string]$Value) {
    if ($null -eq $Value) {
        return '$null'
    }

    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-NpmUninstallCodexAtPrefix([string]$PrefixDir) {
    $prefix = Normalize-ComparablePath $PrefixDir
    if ([string]::IsNullOrWhiteSpace($prefix) -or -not (Test-IsKnownSystemNpmPrefix $prefix)) {
        throw "Refusing npm Codex uninstall outside a system install prefix: $PrefixDir"
    }

    $npmPath = Resolve-NpmCommandPath
    if ([string]::IsNullOrWhiteSpace($npmPath)) {
        Write-WarnMsg 'npm was not found; cannot uninstall system-level Codex with npm.'
        return $false
    }

    Write-Info "Uninstalling system-level Codex CLI from npm prefix: $prefix"
    $savedErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $npmPath uninstall -g --prefix $prefix '@openai/codex'
        $uninstallExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorAction
    }

    if ($uninstallExit -ne 0) {
        Write-WarnMsg "npm uninstall for system-level Codex returned exit code $uninstallExit."
        return $false
    }

    return $true
}

function Invoke-ElevatedSystemCodexUninstall([string]$PrefixDir) {
    $prefix = Normalize-ComparablePath $PrefixDir
    if ([string]::IsNullOrWhiteSpace($prefix) -or -not (Test-IsKnownSystemNpmPrefix $prefix)) {
        throw "Refusing elevated Codex uninstall outside a system install prefix: $PrefixDir"
    }

    $npmPath = Resolve-NpmCommandPath
    if ([string]::IsNullOrWhiteSpace($npmPath)) {
        throw 'npm was not found; cannot launch elevated system-level Codex uninstall.'
    }

    $powershellPath = @(Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($powershellPath.Count -eq 0) {
        throw 'powershell.exe was not found; cannot launch elevated system-level Codex uninstall.'
    }

    $scriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $PSCommandPath
    }
    else {
        $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw 'Current script path could not be resolved for elevated system-level Codex uninstall.'
    }

    $scriptLiteral = ConvertTo-PowerShellSingleQuotedLiteral $scriptPath
    $prefixLiteral = ConvertTo-PowerShellSingleQuotedLiteral $prefix
    $npmLiteral = ConvertTo-PowerShellSingleQuotedLiteral $npmPath
    $payload = "& $scriptLiteral -UninstallSystemCodexPrefix $prefixLiteral -NpmCommandPath $npmLiteral"
    $encodedPayload = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($payload))

    Write-WarnMsg 'System-level Codex removal requires administrator rights. Approve the UAC prompt to continue.'
    try {
        $process = Start-Process -FilePath $powershellPath[0].Source -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            $encodedPayload
        )
    }
    catch {
        throw "Failed to start elevated system-level Codex uninstall: $($_.Exception.Message)"
    }

    if ($process.ExitCode -ne 0) {
        throw "Elevated system-level Codex uninstall failed with exit code $($process.ExitCode)."
    }
}

function Ensure-NoSystemCodex([string]$UserNpmBinDir) {
    $systemInstalls = @(Find-SystemCodexInstalls -UserNpmBinDir $UserNpmBinDir)
    if ($systemInstalls.Count -eq 0) {
        Write-Info 'No system-level Codex CLI detected.'
        return
    }

    foreach ($install in $systemInstalls) {
        Write-WarnMsg "Detected system-level Codex CLI: $($install.PrefixDir)"
    }

    foreach ($install in $systemInstalls) {
        [void](Invoke-NpmUninstallCodexAtPrefix $install.PrefixDir)
        Remove-KnownSystemCodexFiles $install.PrefixDir
    }

    $remaining = @(Find-SystemCodexInstalls -UserNpmBinDir $UserNpmBinDir)
    if (($remaining.Count -gt 0) -and -not (Test-IsAdministrator)) {
        foreach ($install in $remaining) {
            Invoke-ElevatedSystemCodexUninstall $install.PrefixDir
        }
        $remaining = @(Find-SystemCodexInstalls -UserNpmBinDir $UserNpmBinDir)
    }

    if ($remaining.Count -gt 0) {
        $locations = @($remaining | ForEach-Object { $_.PrefixDir }) -join '; '
        throw "System-level Codex CLI is still present: $locations. Remove it with administrator rights and rerun this installer."
    }

    Write-Ok 'System-level Codex CLI removed.'
}

function Warn-SystemCodex([string]$UserNpmBinDir) {
    $systemInstalls = @(Find-SystemCodexInstalls -UserNpmBinDir $UserNpmBinDir)
    if ($systemInstalls.Count -eq 0) {
        Write-Info 'No system-level Codex CLI detected.'
        return
    }

    foreach ($install in $systemInstalls) {
        Write-WarnMsg "Detected system-level Codex CLI: $($install.PrefixDir)"
    }
    Write-WarnMsg 'Leaving system-level Codex untouched. This installer will put the user npm bin directory first in PATH.'
    Write-WarnMsg 'If you explicitly want to remove system-level Codex, rerun with -RemoveSystemCodex.'
}

function Ensure-NpmUserPrefix {
    Ensure-CodexPathSettings

    $target = Get-CodexNpmPrefix
    $cache = Get-CodexNpmCache
    if ([string]::IsNullOrWhiteSpace($target)) {
        return
    }

    New-Item -ItemType Directory -Path $target -Force | Out-Null
    New-Item -ItemType Directory -Path $cache -Force | Out-Null

    Remove-Item Env:NPM_CONFIG_PREFIX -ErrorAction SilentlyContinue
    Remove-Item Env:NPM_CONFIG_CACHE -ErrorAction SilentlyContinue
    Remove-Item Env:NPM_CONFIG_USERCONFIG -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('NPM_CONFIG_PREFIX', $null, 'User')
    [Environment]::SetEnvironmentVariable('NPM_CONFIG_CACHE', $null, 'User')
    [Environment]::SetEnvironmentVariable('NPM_CONFIG_USERCONFIG', $null, 'User')

    Write-Info "Codex npm prefix for this install: $target"
}

function Resolve-NodeInstallDir {
    Ensure-CodexPathSettings

    if (-not [string]::IsNullOrWhiteSpace($UserNodeRoot)) {
        if (Test-Path (Join-Path $UserNodeRoot 'node.exe')) {
            return $UserNodeRoot
        }
    }

    $nodeCmd = @(Get-Command node -All -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } |
        Select-Object -First 1)
    if ($nodeCmd.Count -gt 0) {
        $resolvedDir = Split-Path -Parent $nodeCmd[0].Path
        if (-not [string]::IsNullOrWhiteSpace($resolvedDir) -and (Test-Path (Join-Path $resolvedDir 'node.exe'))) {
            return $resolvedDir
        }
    }

    if (Test-Path 'C:\Program Files\nodejs\node.exe') {
        return 'C:\Program Files\nodejs'
    }

    return $null
}

function Test-PreexistingNodeAndNpm {
    $nodeDir = $null
    try {
        $nodeDir = Resolve-NodeInstallDir
    }
    catch {
        $nodeDir = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($nodeDir)) {
        $nodeExe = Join-Path $nodeDir 'node.exe'
        $npmCmd = Join-Path $nodeDir 'npm.cmd'
        if ((Test-Path $nodeExe) -and (Test-Path $npmCmd)) {
            return $true
        }
    }

    return (Command-Exists 'node') -and (Command-Exists 'npm')
}

function Test-PreexistingCodex {
    Ensure-CodexPathSettings

    if (Command-Exists 'codex') {
        return $true
    }
    if (Command-Exists 'codex.cmd') {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CodexNpmPrefix)) {
        if (Test-Path (Join-Path $script:CodexNpmPrefix 'codex.cmd')) {
            return $true
        }
        if (Test-Path (Join-Path $script:CodexNpmPrefix 'codex.ps1')) {
            return $true
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $appDataNpm = Join-Path $env:APPDATA 'npm'
        if (Test-Path (Join-Path $appDataNpm 'codex.cmd')) {
            return $true
        }
        if (Test-Path (Join-Path $appDataNpm 'codex.ps1')) {
            return $true
        }
    }

    if (Command-Exists 'npm') {
        try {
            $prefix = (& npm config get prefix).Trim()
            if (-not [string]::IsNullOrWhiteSpace($prefix)) {
                if (Test-Path (Join-Path $prefix 'codex.cmd')) {
                    return $true
                }
                if (Test-Path (Join-Path $prefix 'codex.ps1')) {
                    return $true
                }
            }
        }
        catch {
        }
    }

    return $false
}

function Test-PreexistingNodeNpmCodex {
    return (Test-PreexistingNodeAndNpm) -and (Test-PreexistingCodex)
}

function Clear-ExistingCrsConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexDir
    )

    if ([string]::IsNullOrWhiteSpace($CodexDir) -or -not (Test-Path $CodexDir)) {
        return
    }

    Backup-FileIfExists (Join-Path $CodexDir 'config.toml')
    Backup-FileIfExists (Join-Path $CodexDir 'auth.json')

    # Avoid leaking/using stale keys between reconfiguration runs.
    try {
        [Environment]::SetEnvironmentVariable('CRS_OAI_KEY', $null, 'User')
    }
    catch {
        Write-WarnMsg "Failed to clear USER env CRS_OAI_KEY: $($_.Exception.Message)"
    }

    Remove-Item Env:CRS_OAI_KEY -ErrorAction SilentlyContinue
}

function Backup-FileIfExists([string]$PathToBackup) {
    if (-not (Test-Path $PathToBackup)) {
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$PathToBackup.bak.$timestamp"
    Copy-Item -Path $PathToBackup -Destination $backupPath -Force
    Write-Info "Backed up existing file: $backupPath"
    return $backupPath
}

function Remove-CrsBackupsAfterSuccess {
    param(
        [string[]]$BackupPaths
    )

    foreach ($backupPath in @($BackupPaths)) {
        if ([string]::IsNullOrWhiteSpace($backupPath) -or -not (Test-Path -LiteralPath $backupPath)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $backupPath -Force
            Write-Info "Removed successful-write backup: $backupPath"
        }
        catch {
            Write-WarnMsg "Failed to remove successful-write backup ${backupPath}: $($_.Exception.Message)"
        }
    }
}

function Write-CodexConfigFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexDir,
        [Parameter(Mandatory = $true)]
        [string]$ConfigToml,
        [Parameter(Mandatory = $true)]
        [string]$AuthJson,
        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$Encoding,
        [switch]$CleanExistingConfig
    )

    New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null
    $configPath = Join-Path $CodexDir 'config.toml'
    $authPath = Join-Path $CodexDir 'auth.json'

    if ($CleanExistingConfig) {
        Write-Info 'Existing Codex configuration detected; creating temporary backups before writing new CRS files.'
    }
    $backupPaths = @(
        Backup-FileIfExists $configPath
        Backup-FileIfExists $authPath
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    [System.IO.File]::WriteAllText($configPath, $ConfigToml, $Encoding)
    [System.IO.File]::WriteAllText($authPath, $AuthJson, $Encoding)

    Write-Ok "Wrote config file: $configPath"
    Write-Ok "Wrote auth file: $authPath"
    return [string[]]$backupPaths
}

function Invoke-CrsResponsesRouteProbe([string]$BaseUrl) {
    $trimmed = $BaseUrl.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    try {
        $probeUrl = "$trimmed/responses"
        $response = Invoke-WebRequest `
            -Uri $probeUrl `
            -Method Post `
            -Body '{}' `
            -ContentType 'application/json' `
            -TimeoutSec 8 `
            -UseBasicParsing `
            -ErrorAction Stop

        return [pscustomobject]@{
            BaseUrl = $trimmed
            Url = $probeUrl
            StatusCode = [int]$response.StatusCode
            ErrorMessage = $null
        }
    }
    catch {
        $statusCode = $null
        $message = $_.Exception.Message
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        return [pscustomobject]@{
            BaseUrl = $trimmed
            Url = "$trimmed/responses"
            StatusCode = $statusCode
            ErrorMessage = $message
        }
    }
}

function Resolve-CrsBaseUrl([string]$BaseUrl) {
    $trimmed = $BaseUrl.Trim().TrimEnd('/')
    $probe = Invoke-CrsResponsesRouteProbe $trimmed
    if ($probe -and ($null -ne $probe.StatusCode) -and ($probe.StatusCode -ne 404)) {
        Write-Info "CRS Responses route probe: $($probe.StatusCode) $($probe.Url)"
        return $trimmed
    }

    if ($probe -and ($probe.StatusCode -eq 404)) {
        Write-WarnMsg "CRS Responses route probe returned 404: $($probe.Url)"
    }
    elseif ($probe) {
        Write-WarnMsg "Could not verify CRS Responses route: $($probe.Url). $($probe.ErrorMessage)"
    }

    $candidate = $null
    try {
        $uri = [Uri]$trimmed
        if ($uri.AbsolutePath.TrimEnd('/') -ieq '/api') {
            $builder = [UriBuilder]$uri
            $builder.Path = 'openai'
            $builder.Query = ''
            $candidate = $builder.Uri.AbsoluteUri.TrimEnd('/')
        }
    }
    catch {
    }

    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $candidateProbe = Invoke-CrsResponsesRouteProbe $candidate
        if ($candidateProbe -and ($null -ne $candidateProbe.StatusCode) -and ($candidateProbe.StatusCode -ne 404)) {
            Write-WarnMsg "The entered CRS base_url does not expose /responses. Using detected OpenAI-compatible base_url instead: $candidate"
            Write-Info "CRS Responses route probe: $($candidateProbe.StatusCode) $($candidateProbe.Url)"
            return $candidate
        }
    }

    Write-WarnMsg 'Could not verify that the CRS base_url exposes the Responses API. Codex may fail if /responses is not available.'
    return $trimmed
}

function Read-RequiredInput([string]$Prompt) {
    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
        Write-WarnMsg 'Input cannot be empty. Please try again.'
    }
}

function Read-SecretInput([string]$Prompt) {
    while ($true) {
        $secure = Read-Host $Prompt -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        if (-not [string]::IsNullOrWhiteSpace($plain)) {
            return $plain.Trim()
        }
        Write-WarnMsg 'Input cannot be empty. Please try again.'
    }
}

function Node-And-Npm-Ready {
    Ensure-CodexPathSettings

    if ([string]::IsNullOrWhiteSpace($UserNodeRoot)) {
        return $false
    }

    return (Test-Path (Join-Path $UserNodeRoot 'node.exe')) -and (Test-Path (Join-Path $UserNodeRoot 'npm.cmd'))
}

function Get-NodeLtsZipInfo {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $idx = Invoke-RestMethod 'https://nodejs.org/dist/index.json'
    $lts = $idx | Where-Object { $_.lts -and ($_.files -contains 'win-x64-zip') } | Select-Object -First 1

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
        $relatedRoots = @($TargetRoot) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        Stop-ProcessesUsingRoots -Roots $relatedRoots -Reason 'Node.js replacement'

        $backupSuffix = "{0}.{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $backupRoot = "$TargetRoot.bak.$backupSuffix"
        Write-Info "Moving existing Node.js install to backup: $backupRoot"
        try {
            Move-Item -LiteralPath $TargetRoot -Destination $backupRoot -Force
        }
        catch {
            throw "Could not move existing Node.js install to backup. Close applications using Node/Codex and retry. Original error: $($_.Exception.Message)"
        }
    }

    try {
        Move-Item -LiteralPath $ExtractRoot -Destination $TargetRoot -Force
        if (-not (Test-Path -LiteralPath (Join-Path $TargetRoot 'node.exe'))) {
            throw "node.exe not found in: $TargetRoot"
        }

        if ($backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            try {
                Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-WarnMsg "Node.js was replaced successfully, but the old backup could not be removed: $backupRoot"
                Write-WarnMsg "Close applications using old Node.js files and delete that backup later. Original error: $($_.Exception.Message)"
            }
        }
    }
    catch {
        if ((-not (Test-Path -LiteralPath $TargetRoot)) -and $backupRoot -and (Test-Path -LiteralPath $backupRoot)) {
            Move-Item -LiteralPath $backupRoot -Destination $TargetRoot -Force
        }
        throw
    }
}

function Remove-OldNodeBackupsAfterSuccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetRoot
    )

    $parent = Split-Path -Parent $TargetRoot
    $leaf = Split-Path -Leaf $TargetRoot
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf) -or -not (Test-Path -LiteralPath $parent)) {
        return
    }

    $backupDirs = @(Get-ChildItem -LiteralPath $parent -Directory -Filter "$leaf.bak.*" -ErrorAction SilentlyContinue)
    foreach ($backupDir in $backupDirs) {
        try {
            Remove-Item -LiteralPath $backupDir.FullName -Recurse -Force -ErrorAction Stop
            Write-Info "Removed old Node.js backup: $($backupDir.FullName)"
        }
        catch {
            Write-WarnMsg "Node.js was installed successfully, but an old backup could not be removed: $($backupDir.FullName)"
            Write-WarnMsg "Close applications using old Node.js files and delete that backup later. Original error: $($_.Exception.Message)"
        }
    }
}

function Install-NodeUserZip {
    Ensure-CodexPathSettings

    Write-Info 'Installing Node.js LTS to user directory (no admin)...'

    $lts = Get-NodeLtsZipInfo
    $version = $lts.version
    $zipName = "node-$version-win-x64.zip"
    $zipUrl = "https://nodejs.org/dist/$version/$zipName"
    $tempRoot = if ([string]::IsNullOrWhiteSpace($script:CodexTempRoot)) { $env:TEMP } else { $script:CodexTempRoot }
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $workRoot = Join-Path $tempRoot ("codex-node-install-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $zipPath = Join-Path $workRoot $zipName
    $extractRoot = Join-Path $workRoot "node-$version-win-x64"

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        $expectedHash = Get-NodeExpectedSha256 -Version $version -FileName $zipName
        Assert-FileSha256 -Path $zipPath -ExpectedHash $expectedHash

        Expand-Archive -Path $zipPath -DestinationPath $workRoot -Force

        if (-not (Test-Path -LiteralPath $extractRoot)) {
            throw "Extracted Node.js folder not found: $extractRoot"
        }

        Install-ExtractedNodeAtomically -ExtractRoot $extractRoot -TargetRoot $UserNodeRoot
    }
    finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $UserNodeRoot 'node.exe'))) {
        throw "node.exe not found in: $UserNodeRoot"
    }

    Ensure-UserPathContains $UserNodeRoot -Prepend:$script:UseAsciiSafePaths
    Ensure-CurrentPathContains $UserNodeRoot -Prepend

    Write-Ok "Node.js: $(& (Join-Path $UserNodeRoot 'node.exe') -v)"
    Write-Ok "npm: $(& (Join-Path $UserNodeRoot 'npm.cmd') -v)"
    Remove-OldNodeBackupsAfterSuccess -TargetRoot $UserNodeRoot
}

function Ensure-Node {
    Ensure-CodexPathSettings

    # Prefer any existing Node/npm available on PATH (system install or other managed installs).
    # Only fall back to downloading a user-local Node zip if Node/npm are not present.
    Refresh-Path
    $preexistingNodeReady = Test-PreexistingNodeAndNpm
    if ($preexistingNodeReady -and $script:UseAsciiSafePaths) {
        $resolvedNodeDir = Resolve-NodeInstallDir
        if (Test-ContainsNonAscii $resolvedNodeDir) {
            Write-WarnMsg "Existing Node.js path contains non-ASCII characters: $resolvedNodeDir"
            Write-Info "Installing a separate ASCII-safe Node.js copy under: $UserNodeRoot"
            $preexistingNodeReady = $false
        }
    }

    if ($preexistingNodeReady -and -not $ForceNodeReinstall) {
        Write-Info 'Node.js and npm already present.'
        Write-Ok ("Node.js: " + (node -v))
        Write-Ok ("npm: " + (npm -v))
        return
    }

    if ($ForceNodeReinstall -and (Test-Path $UserNodeRoot)) {
        Write-Info "Force reinstall requested; existing user Node.js install will be replaced atomically: $UserNodeRoot"
    }

    Install-NodeUserZip
    Refresh-Path

    if (-not (Node-And-Npm-Ready)) {
        throw 'Node.js/npm still not available after user install. Reopen PowerShell and retry.'
    }
}

function Invoke-PowerShellCodexProbe {
    param(
        [switch]$NoProfile
    )

    $powershell = @(Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $powershell) {
        return -1
    }

    $probe = @'
$ErrorActionPreference = "Stop"
try {
    Get-Command codex -ErrorAction Stop | Out-Null
    codex --version | Out-Null
    $nativeExit = $LASTEXITCODE
    if ($nativeExit -ne 0) {
        Write-Output ("ProbeNativeExit: " + $nativeExit)
        exit $nativeExit
    }
    exit 0
}
catch [System.Management.Automation.CommandNotFoundException] {
    Write-Output "ProbeErrorType: CommandNotFoundException"
    Write-Output ("ProbeMessage: " + $_.Exception.Message)
    exit 12
}
catch [System.Management.Automation.PSSecurityException] {
    Write-Output "ProbeErrorType: PSSecurityException"
    Write-Output ("ProbeMessage: " + $_.Exception.Message)
    if ($_.FullyQualifiedErrorId) {
        Write-Output ("ProbeFQID: " + $_.FullyQualifiedErrorId)
    }
    exit 13
}
catch {
    Write-Output ("ProbeErrorType: " + $_.Exception.GetType().FullName)
    Write-Output ("ProbeMessage: " + $_.Exception.Message)
    if ($_.FullyQualifiedErrorId) {
        Write-Output ("ProbeFQID: " + $_.FullyQualifiedErrorId)
    }
    if ($_.CategoryInfo) {
        Write-Output ("ProbeCategory: " + $_.CategoryInfo.ToString())
    }
    exit 14
}
'@

    $probeBytes = [System.Text.Encoding]::Unicode.GetBytes($probe)
    $probeEncoded = [Convert]::ToBase64String($probeBytes)

    # The installer itself runs with -ExecutionPolicy Bypass.
    # Remove this process override temporarily so the probe reflects a normal PowerShell session.
    $hadPref = Test-Path Env:PSExecutionPolicyPreference
    $savedPref = $null
    if ($hadPref) {
        $savedPref = $env:PSExecutionPolicyPreference
        Remove-Item Env:PSExecutionPolicyPreference -ErrorAction SilentlyContinue
    }

    $savedErrorAction = $ErrorActionPreference
    try {
        # Probe failures should be logged, not terminate installer execution.
        $ErrorActionPreference = 'Continue'
        $probeArgs = @()
        if ($NoProfile) {
            $probeArgs += '-NoProfile'
        }
        $probeArgs += @('-EncodedCommand', $probeEncoded)

        $probeLabel = if ($NoProfile) { 'NoProfile' } else { 'Normal' }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo.FileName = $powershell.Source
        $process.StartInfo.Arguments = ($probeArgs -join ' ')
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $process.StartInfo.CreateNoWindow = $true

        try {
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $probeExit = $process.ExitCode
        }
        catch {
            Write-WarnMsg "[Probe][$probeLabel] Failed to run PowerShell probe: $($_.Exception.Message)"
            return 14
        }
        finally {
            if ($process) {
                $process.Dispose()
            }
        }

        if ($probeExit -ne 0) {
            foreach ($line in @($stdout, $stderr)) {
                foreach ($textLine in ($line -split "`r?`n")) {
                    $text = "$textLine".Trim()
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        Write-WarnMsg "[Probe][$probeLabel] $text"
                    }
                }
            }
        }

        return $probeExit
    }
    finally {
        $ErrorActionPreference = $savedErrorAction
        if ($hadPref) {
            $env:PSExecutionPolicyPreference = $savedPref
        }
    }
}

function Disable-CodexPs1Wrapper([string]$CodexPs1Path) {
    if ([string]::IsNullOrWhiteSpace($CodexPs1Path) -or -not (Test-Path $CodexPs1Path)) {
        return $false
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $disabledPath = "$CodexPs1Path.disabled.$timestamp"
    Rename-Item -Path $CodexPs1Path -NewName (Split-Path -Leaf $disabledPath) -Force
    Write-WarnMsg "Disabled codex.ps1 wrapper due to policy restriction: $disabledPath"
    return $true
}

function Ensure-CodexCommandWorks([string]$NpmBinDir) {
    $codexCmd = Join-Path $NpmBinDir 'codex.cmd'
    $codexPs1 = Join-Path $NpmBinDir 'codex.ps1'

    if (-not (Test-Path $codexCmd)) {
        if (Test-Path $codexPs1) {
            throw "codex.ps1 exists but codex.cmd is missing: $codexPs1"
        }
        throw "codex executable files not found under npm bin: $NpmBinDir"
    }

    try {
        $cmdResult = Invoke-CodexVersionCommand $codexCmd
    }
    catch {
        throw "codex.cmd exists but failed to execute: $($_.Exception.Message)"
    }

    $cmdFailure = New-CodexVersionFailureMessage 'codex.cmd' $cmdResult
    if ($cmdFailure) {
        throw $cmdFailure
    }

    Write-Ok "Codex CLI installed (via codex.cmd): $($cmdResult.OutputText)"

    $profileProbeCode = Invoke-PowerShellCodexProbe
    if ($profileProbeCode -eq 13) {
        Write-WarnMsg "A normal PowerShell session blocks codex.ps1 due to execution policy."
        Write-WarnMsg ("ExecutionPolicy(CurrentUser): " + (Get-ExecutionPolicy -Scope CurrentUser))
        Write-WarnMsg ("ExecutionPolicy(UserPolicy): " + (Get-ExecutionPolicy -Scope UserPolicy))
        Write-WarnMsg ("ExecutionPolicy(MachinePolicy): " + (Get-ExecutionPolicy -Scope MachinePolicy))

        # Try standard fix first.
        try {
            $policy = Get-ExecutionPolicy -Scope CurrentUser
            if ($policy -in @('Undefined', 'Restricted', 'AllSigned')) {
                Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
                Write-Info "Set CurrentUser execution policy to RemoteSigned."
            }
        }
        catch {
            Write-WarnMsg "Could not set execution policy automatically: $($_.Exception.Message)"
        }

        $probeAfterPolicy = Invoke-PowerShellCodexProbe
        if ($probeAfterPolicy -eq 0) {
            $profileProbeCode = 0
        }
        else {
            $profileProbeCode = $probeAfterPolicy
        }

        if (($profileProbeCode -eq 13) -and (Test-Path $codexPs1)) {
            if (Disable-CodexPs1Wrapper $codexPs1) {
                $probeAfterWrapper = Invoke-PowerShellCodexProbe
                if ($probeAfterWrapper -eq 0) {
                    $profileProbeCode = 0
                }
                else {
                    $profileProbeCode = $probeAfterWrapper
                    Write-WarnMsg "codex.ps1 wrapper was disabled, but the normal PowerShell probe still failed with code $probeAfterWrapper."
                }
            }
        }
    }
    elseif ($profileProbeCode -eq 12) {
        Write-WarnMsg 'A normal PowerShell session does not resolve `codex` yet. Reopen PowerShell after install if needed.'
    }
    elseif ($profileProbeCode -eq -1) {
        Write-WarnMsg 'powershell.exe was not found for the normal PowerShell probe.'
    }
    elseif ($profileProbeCode -eq 14) {
        Write-WarnMsg 'Normal PowerShell probe failed with an exception.'
    }
    elseif ($profileProbeCode -ne 0) {
        Write-WarnMsg "Normal PowerShell probe failed with exit code $profileProbeCode."
    }

    if ($profileProbeCode -eq 0) {
        Write-Ok 'Codex command is ready in a normal PowerShell session.'
    }

    $noProfileProbeCode = Invoke-PowerShellCodexProbe -NoProfile
    if ($noProfileProbeCode -eq 0) {
        Write-Ok 'Codex command is also ready in PowerShell -NoProfile.'
    }
    elseif ($noProfileProbeCode -eq 12) {
        Write-WarnMsg 'PowerShell -NoProfile does not resolve `codex`. This is usually a PATH propagation issue until a new shell is opened.'
    }
    elseif ($noProfileProbeCode -eq 13) {
        Write-WarnMsg 'PowerShell -NoProfile still blocks codex.ps1 due to execution policy.'
    }
    elseif ($noProfileProbeCode -eq -1) {
        Write-WarnMsg 'powershell.exe was not found for the PowerShell -NoProfile probe.'
    }
    elseif ($noProfileProbeCode -eq 14) {
        Write-WarnMsg 'PowerShell -NoProfile probe failed with an exception.'
    }
    else {
        Write-WarnMsg "PowerShell -NoProfile probe failed with exit code $noProfileProbeCode."
    }

    if ($profileProbeCode -eq 0) {
        return
    }

    if ($profileProbeCode -eq 12) {
        Write-WarnMsg 'Installation completed, but a freshly opened PowerShell window may be required before `codex` resolves normally.'
        return
    }

    if ($noProfileProbeCode -eq 0) {
        Write-WarnMsg 'Installation completed, but your normal PowerShell profile or startup scripts appear to interfere with `codex`.'
        return
    }

    # Last-resort guidance: codex.cmd works, but normal PowerShell still not healthy.
    try {
        $cmdResult = Invoke-CodexVersionCommand $codexCmd
        $cmdFailure = New-CodexVersionFailureMessage 'codex.cmd' $cmdResult
        if ($cmdFailure) {
            Write-WarnMsg $cmdFailure
        }
        else {
            Write-WarnMsg "A normal PowerShell session is still not ready (probe code: $profileProbeCode). codex.cmd works: $($cmdResult.OutputText)"
        }
    }
    catch {
        Write-WarnMsg "codex.cmd fallback also failed: $($_.Exception.Message)"
    }

    throw "Codex installed but still unavailable in a normal PowerShell session. Reopen PowerShell and retry, or run codex.cmd."
}


function Install-CodexPackage {
    Write-Info 'Installing Codex CLI...'
    Ensure-CodexPathSettings

    $npmPrefixForInstall = Get-CodexNpmPrefix
    $npmCacheForInstall = Get-CodexNpmCache
    & npm install -g --prefix $npmPrefixForInstall --cache $npmCacheForInstall '@openai/codex'
    $installExit = $LASTEXITCODE
    if ($installExit -eq 0) {
        return
    }

    $logDir = Join-Path $npmCacheForInstall '_logs'
    $latestLog = $null
    if (Test-Path $logDir) {
        $latestLog = Get-ChildItem -Path $logDir -Filter '*-debug-0.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    Write-WarnMsg "npm install returned exit code $installExit."
    if ($latestLog) {
        Write-WarnMsg "npm debug log: $($latestLog.FullName)"
    }

    Write-WarnMsg 'Detected npm install failure. Retrying once after stopping codex process...'
    Get-Process -Name codex -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $npmPrefixForInstall = Get-CodexNpmPrefix
    $npmCacheForInstall = Get-CodexNpmCache
    & npm install -g --prefix $npmPrefixForInstall --cache $npmCacheForInstall '@openai/codex'
    $retryExit = $LASTEXITCODE
    if ($retryExit -ne 0) {
        throw "npm install -g @openai/codex failed (exit $retryExit). Close terminals/tools using codex.exe and retry."
    }
}

function Ensure-Codex {
    Ensure-CodexPathSettings

    $userNpmBinDir = Get-CodexNpmPrefix

    Write-Info 'Checking for system-level Codex CLI before user install...'
    if ($RemoveSystemCodex) {
        Ensure-NoSystemCodex $userNpmBinDir
    }
    else {
        Warn-SystemCodex $userNpmBinDir
    }
    Ensure-NpmUserPrefix
    $npmBinDir = Resolve-NpmGlobalBinDir

    if ($ForceCodexReinstall) {
        Write-Info 'Force reinstall requested: uninstalling existing Codex CLI...'
        $npmPrefixForUninstall = Get-CodexNpmPrefix
        npm uninstall -g --prefix $npmPrefixForUninstall '@openai/codex' | Out-Null
    }

    $existingCodexVersion = $null
    if (-not $ForceCodexReinstall) {
        try {
            $userCodexCmd = Join-Path $npmBinDir 'codex.cmd'
            if (Test-Path $userCodexCmd) {
                $existingVersionResult = Invoke-CodexVersionCommand $userCodexCmd
                $existingVersionFailure = New-CodexVersionFailureMessage $userCodexCmd $existingVersionResult
                if (-not $existingVersionFailure) {
                    $existingCodexVersion = $existingVersionResult.OutputText.Trim()
                }
                else {
                    Write-WarnMsg "User Codex CLI probe failed: $existingVersionFailure Reinstalling package."
                    $existingCodexVersion = $null
                }
            }
        }
        catch {
            $existingCodexVersion = $null
        }
    }

    if ($existingCodexVersion) {
        Write-Info "Codex CLI already present: $existingCodexVersion"
    }
    else {
        Install-CodexPackage
    }

    Ensure-UserPathContains $npmBinDir -Prepend
    $nodeInstallDir = Resolve-NodeInstallDir
    if ($nodeInstallDir) {
        Ensure-UserPathContains $nodeInstallDir -Prepend:$script:UseAsciiSafePaths
    }

    Ensure-CurrentPathContains $npmBinDir -Prepend
    if ($nodeInstallDir) {
        Ensure-CurrentPathContains $nodeInstallDir -Prepend:$script:UseAsciiSafePaths
    }
    Refresh-Path

    Ensure-CodexCommandWorks $npmBinDir
}

function Configure-CrsFiles {
    param(
        [switch]$CleanExistingConfig
    )

    Ensure-CodexPathSettings

    $codexDir = $script:CodexHome

    Write-Info 'Starting CRS configuration...'
    Write-Info 'Please provide values for base_url and OPENAI_API_KEY.'

    $baseUrlInput = Read-RequiredInput 'Enter CRS 2.0 base_url (must expose /responses, example: https://your-crs-host:8443)'
    $openAiKey = Read-SecretInput 'Enter OPENAI_API_KEY / CRS 2.0 token (input hidden)'
    $baseUrl = Resolve-CrsBaseUrl $baseUrlInput

    if ($script:UseAsciiSafePaths) {
        $env:CODEX_HOME = $codexDir
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $codexDir, 'User')
    }

    $configToml = @"
model_provider = "OpenAI"
model = "gpt-5.5"
review_model = "gpt-5.4"
model_reasoning_effort = "xhigh"
disable_response_storage = true
network_access = "enabled"

sandbox_mode = "danger-full-access"
approval_policy = "never"
# 正常模式：
# sandbox_mode = "workspace-write"
# approval_policy = "on-request"

[model_providers.OpenAI]
name = "OpenAI"
base_url = "$baseUrl"
wire_api = "responses"
requires_openai_auth = true

[features]
# 实际已去除
tui_app_server = false
# 关闭MCP和 工具 / 列表 / 发现/建议
apps = false

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.4"
"gpt-5.2" = "gpt-5.4"

[windows]
sandbox = "elevated"
"@

    $authJson = (@{
        OPENAI_API_KEY = $openAiKey
    } | ConvertTo-Json -Depth 3)

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if ($CleanExistingConfig) {
        Write-Info 'Detected existing node/npm/codex; cleaning old CRS configuration before regenerating...'
    }

    $backupPaths = Write-CodexConfigFiles `
        -CodexDir $codexDir `
        -ConfigToml $configToml `
        -AuthJson $authJson `
        -Encoding $utf8NoBom `
        -CleanExistingConfig:$CleanExistingConfig

    try {
        [Environment]::SetEnvironmentVariable('CRS_OAI_KEY', $null, 'User')
    }
    catch {
        Write-WarnMsg "Failed to clear legacy CRS_OAI_KEY from USER environment variables: $($_.Exception.Message)"
    }
    Remove-Item Env:CRS_OAI_KEY -ErrorAction SilentlyContinue

    Write-Ok 'Saved OPENAI_API_KEY to auth.json.'
    Remove-CrsBackupsAfterSuccess -BackupPaths $backupPaths
}

Write-Info 'Starting install for Codex CLI and dependencies...'
Write-PreflightSummary

if ($script:DryRun) {
    if (-not [string]::IsNullOrWhiteSpace($UninstallSystemCodexPrefix)) {
        Write-Info "Dry run: would uninstall system-level Codex under: $UninstallSystemCodexPrefix"
    }
    Write-Ok 'Dry run complete. No files, environment variables, packages, processes, or PATH entries were changed.'
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($UninstallSystemCodexPrefix)) {
    [void](Invoke-NpmUninstallCodexAtPrefix $UninstallSystemCodexPrefix)
    Remove-KnownSystemCodexFiles $UninstallSystemCodexPrefix

    $remainingSystemCodex = @(Find-SystemCodexInstalls -UserNpmBinDir $null | Where-Object {
        $_.PrefixDir -ieq (Normalize-ComparablePath $UninstallSystemCodexPrefix)
    })
    if ($remainingSystemCodex.Count -gt 0) {
        throw "System-level Codex CLI remains under: $UninstallSystemCodexPrefix"
    }

    exit 0
}

Initialize-AsciiSafeEnvironment
$cleanExistingConfig = $false
try {
    $cleanExistingConfig = Test-PreexistingNodeNpmCodex
}
catch {
    $cleanExistingConfig = $false
}

Ensure-Node
Ensure-Codex

if (-not $SkipCrsConfig) {
    Configure-CrsFiles -CleanExistingConfig:$cleanExistingConfig
}

Write-Host ''
Write-Host 'Done. If your current shell does not see new PATH/env values, reopen PowerShell.' -ForegroundColor White
