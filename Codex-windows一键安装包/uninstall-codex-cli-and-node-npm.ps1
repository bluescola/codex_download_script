param(
    [Alias('h', '?')]
    [switch]$Help,
    [switch]$KeepCodexHome,
    [switch]$KeepNpmCache,
    [switch]$SkipNodeUninstall,
    [switch]$ForceRemoveCodexHome
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

function Show-Usage {
    Write-Host @'
Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall-codex-cli-and-node-npm.ps1 [options]

Uninstalls in this order:
  1. Stop Codex/installer-owned Node/npm processes
  2. Uninstall @openai/codex and remove Codex config/profile residue
  3. Remove user-level Node.js/npm only when it is in the installer target path

Options:
  -KeepCodexHome          Keep CODEX_HOME / .codex files
  -KeepNpmCache           Keep installer npm cache
  -SkipNodeUninstall      Remove Codex only; leave Node.js/npm untouched
  -ForceRemoveCodexHome   Remove the whole .codex directory, not just config/auth files
  -Help, -h, -?           Show this help
'@
}

if ($Help) {
    Show-Usage
    exit 0
}

function Test-ContainsNonAscii([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return [regex]::IsMatch($Value, '[^\x00-\x7F]')
}

function Test-NeedsAsciiSafePaths {
    foreach ($value in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, $env:TMP)) {
        if (Test-ContainsNonAscii $value) {
            return $true
        }
    }

    return $false
}

function ConvertTo-ApprovedAsciiSafeRoot([string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or (Test-ContainsNonAscii $Candidate)) {
        return $null
    }

    try {
        $normalized = [System.IO.Path]::GetFullPath($Candidate.Trim()).TrimEnd([char[]]@('\', '/'))
    }
    catch {
        return $null
    }

    if ($normalized -notmatch '^[A-Za-z]:\\Codex(?:-[A-Za-z0-9._-]+)?$') {
        return $null
    }

    if (Test-Path -LiteralPath $normalized) {
        try {
            $item = Get-Item -LiteralPath $normalized -Force -ErrorAction Stop
            if ((-not $item.PSIsContainer) -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                return $null
            }
        }
        catch {
            return $null
        }
    }

    return $normalized
}

function Resolve-AsciiSafeRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_WINDOWS_ASCII_ROOT)) {
        $customRoot = ConvertTo-ApprovedAsciiSafeRoot $env:CODEX_WINDOWS_ASCII_ROOT
        if ([string]::IsNullOrWhiteSpace($customRoot)) {
            throw "CODEX_WINDOWS_ASCII_ROOT must be an ASCII-only local drive root named Codex or Codex-<name>: $env:CODEX_WINDOWS_ASCII_ROOT"
        }
        return $customRoot
    }

    return 'C:\Codex'
}

function Test-ManagedCodexHomePath([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    try {
        $normalized = [System.IO.Path]::GetFullPath($PathValue).TrimEnd([char[]]@('\', '/'))
    }
    catch {
        return $false
    }

    if ((Split-Path -Leaf $normalized) -ine '.codex') {
        return $false
    }

    return -not [string]::IsNullOrWhiteSpace((ConvertTo-ApprovedAsciiSafeRoot (Split-Path -Parent $normalized)))
}

function Initialize-CodexPathSettings {
    $script:UseAsciiSafePaths = Test-NeedsAsciiSafePaths
    $script:CodexAsciiRoot = Resolve-AsciiSafeRoot
    $script:CodexNpmPrefix = if ($script:UseAsciiSafePaths -or [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        Join-Path $script:CodexAsciiRoot 'npm'
    }
    else {
        Join-Path $env:APPDATA 'npm'
    }
    $script:CodexNpmCache = if ($script:UseAsciiSafePaths -or [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $script:CodexAsciiRoot 'npm-cache'
    }
    else {
        Join-Path $env:LOCALAPPDATA 'npm-cache'
    }
    $script:CodexHome = if ($script:UseAsciiSafePaths -or [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Join-Path $script:CodexAsciiRoot '.codex'
    }
    else {
        Join-Path $env:USERPROFILE '.codex'
    }
    $script:UserNodeRoot = if ($script:UseAsciiSafePaths) {
        Join-Path $script:CodexAsciiRoot 'nodejs'
    }
    elseif ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:USERPROFILE '.local\node'
    }
    else {
        Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
    }
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

function Select-UniquePath {
    param([string[]]$Paths)

    $seen = @{}
    $result = @()
    foreach ($path in @($Paths)) {
        $normalized = Normalize-ComparablePath $path
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        $key = $normalized.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $result += $normalized
    }

    return $result
}

function Get-KnownSystemNpmPrefixes {
    $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $programData = [Environment]::GetEnvironmentVariable('ProgramData')

    return Select-UniquePath @(
        $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'nodejs' }),
        $(if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) { Join-Path $programFilesX86 'nodejs' }),
        $(if (-not [string]::IsNullOrWhiteSpace($programData)) { Join-Path $programData 'npm' }),
        $(if (-not [string]::IsNullOrWhiteSpace($programData)) { Join-Path $programData 'nodejs' })
    )
}

function Resolve-NpmCommandPath {
    $candidates = @(
        $(if (-not [string]::IsNullOrWhiteSpace($script:UserNodeRoot)) { Join-Path $script:UserNodeRoot 'npm.cmd' }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'Programs\nodejs\npm.cmd' }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { Join-Path $env:ProgramFiles 'nodejs\npm.cmd' })
    )

    foreach ($candidate in @($candidates)) {
        if ((-not [string]::IsNullOrWhiteSpace($candidate)) -and (Test-Path -LiteralPath $candidate)) {
            return (Normalize-ComparablePath $candidate)
        }
    }

    foreach ($name in @('npm.cmd', 'npm')) {
        $cmd = @(Get-Command $name -All -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($cmd.Count -eq 0) {
            continue
        }

        foreach ($propertyName in @('Path', 'Source')) {
            $matches = @($cmd[0].PSObject.Properties.Match($propertyName))
            if ($matches.Count -gt 0) {
                $value = [string]$matches[0].Value
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    return (Normalize-ComparablePath $value)
                }
            }
        }
    }

    return $null
}

function Get-NpmConfigValue([string]$Name) {
    $npmPath = Resolve-NpmCommandPath
    if ([string]::IsNullOrWhiteSpace($npmPath)) {
        return $null
    }

    try {
        $value = & $npmPath config get $Name 2>$null | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
            return $null
        }

        $trimmed = "$value".Trim()
        if ($trimmed -eq 'undefined' -or $trimmed -eq 'null') {
            return $null
        }

        return $trimmed
    }
    catch {
        return $null
    }
}

function Get-CandidateNpmPrefixes {
    return Select-UniquePath @(
        $script:CodexNpmPrefix,
        $(if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { Join-Path $env:APPDATA 'npm' }),
        $env:NPM_CONFIG_PREFIX,
        (Get-NpmConfigValue 'prefix'),
        $script:UserNodeRoot,
        (Get-KnownSystemNpmPrefixes)
    )
}

function Get-InstallerNpmPrefixes {
    return Select-UniquePath @(
        $script:CodexNpmPrefix,
        (Join-Path $script:CodexAsciiRoot 'npm')
    )
}

function Get-CandidateCodexHomes {
    $userCodexHome = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Join-Path $env:USERPROFILE '.codex'
    }
    else {
        $null
    }

    $envCodexHome = $null
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        if ((Normalize-ComparablePath $env:CODEX_HOME) -ieq (Normalize-ComparablePath $script:CodexHome)) {
            $envCodexHome = $env:CODEX_HOME
        }
        elseif (Test-ManagedCodexHomePath $env:CODEX_HOME) {
            $envCodexHome = $env:CODEX_HOME
        }
        else {
            Write-WarnMsg "Leaving custom CODEX_HOME directory untouched because it is outside known installer roots: $env:CODEX_HOME"
        }
    }

    return Select-UniquePath @(
        $script:CodexHome,
        $userCodexHome,
        (Join-Path $script:CodexAsciiRoot '.codex'),
        $envCodexHome
    )
}

function Test-CodexPresentInPrefix([string]$PrefixDir) {
    if ([string]::IsNullOrWhiteSpace($PrefixDir)) {
        return $false
    }

    foreach ($target in @(
        (Join-Path $PrefixDir 'codex'),
        (Join-Path $PrefixDir 'codex.cmd'),
        (Join-Path $PrefixDir 'codex.ps1'),
        (Join-Path $PrefixDir 'codex.exe'),
        (Join-Path $PrefixDir 'node_modules\@openai\codex')
    )) {
        if (Test-Path -LiteralPath $target) {
            return $true
        }
    }

    return $false
}

function Get-ProcessMatchesForRoots {
    param([string[]]$Roots)

    $normalizedRoots = Select-UniquePath $Roots
    $matches = @()
    $currentPid = [int]$PID
    $targetNames = @('codex.exe', 'node.exe', 'npm.exe', 'npx.exe')

    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if (-not $process -or [int]$process.ProcessId -eq $currentPid) {
            continue
        }

        $name = [string]$process.Name
        $executablePath = [string]$process.ExecutablePath
        $commandLine = [string]$process.CommandLine
        $isCodexProcess = ($name -ieq 'codex.exe') -or
            ($commandLine.IndexOf('@openai/codex', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
            ($commandLine.IndexOf('@openai\codex', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)

        if ($isCodexProcess) {
            $matches += $process
            continue
        }

        if ($targetNames -notcontains $name) {
            continue
        }

        foreach ($root in $normalizedRoots) {
            $commandLineUsesRoot = (-not [string]::IsNullOrWhiteSpace($commandLine)) -and
                ($commandLine.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            if ((Test-PathUnderRoot $executablePath $root) -or $commandLineUsesRoot) {
                $matches += $process
                break
            }
        }
    }

    return @($matches | Sort-Object ProcessId -Unique)
}

function Stop-CodexAndNodeProcesses {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($codexHomePath in @(Get-CandidateCodexHomes)) {
        [void]$roots.Add($codexHomePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($script:UserNodeRoot)) {
        [void]$roots.Add($script:UserNodeRoot)
    }
    foreach ($prefix in @(Get-CandidateNpmPrefixes)) {
        if (-not (Test-CodexPresentInPrefix $prefix)) {
            continue
        }

        foreach ($target in @(
            (Join-Path $prefix 'codex'),
            (Join-Path $prefix 'codex.cmd'),
            (Join-Path $prefix 'codex.ps1'),
            (Join-Path $prefix 'node_modules\@openai\codex')
        )) {
            [void]$roots.Add($target)
        }
    }

    $processes = @(Get-ProcessMatchesForRoots -Roots $roots)
    if ($processes.Count -eq 0) {
        Write-Info 'No running Codex/Node/npm processes found for known installer paths.'
        return
    }

    Write-WarnMsg "Stopping $($processes.Count) Codex/Node/npm process(es) before uninstall."
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
    $remaining = @(Get-ProcessMatchesForRoots -Roots $roots)
    if ($remaining.Count -gt 0) {
        $details = ($remaining | ForEach-Object { "PID $($_.ProcessId) $($_.Name)" }) -join '; '
        throw "Cannot continue because these processes are still running: $details"
    }
}

function Invoke-NpmUninstallCodexAtPrefix([string]$PrefixDir) {
    $prefix = Normalize-ComparablePath $PrefixDir
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return $false
    }

    if (-not (Test-CodexPresentInPrefix $prefix)) {
        return $false
    }

    $npmPath = Resolve-NpmCommandPath
    if ([string]::IsNullOrWhiteSpace($npmPath)) {
        Write-WarnMsg "npm was not found; removing Codex residue directly for prefix: $prefix"
        return $false
    }

    Write-Info "Uninstalling @openai/codex from npm prefix: $prefix"
    $savedErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $npmPath uninstall -g --prefix $prefix '@openai/codex'
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorAction
    }

    if ($exitCode -ne 0) {
        Write-WarnMsg "npm uninstall returned exit code $exitCode for prefix: $prefix"
        return $false
    }

    return $true
}

function Remove-PathIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [string]$SafetyRoot
    )

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return
    }

    if ((-not [string]::IsNullOrWhiteSpace($SafetyRoot)) -and -not (Test-PathUnderRoot $TargetPath $SafetyRoot)) {
        throw "Refusing to remove path outside safety root. Target: $TargetPath Root: $SafetyRoot"
    }

    try {
        $item = Get-Item -LiteralPath $TargetPath -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            Remove-Item -LiteralPath $TargetPath -Recurse -Force -ErrorAction Stop
        }
        else {
            Remove-Item -LiteralPath $TargetPath -Force -ErrorAction Stop
        }
        Write-Info "Removed: $TargetPath"
    }
    catch {
        Write-WarnMsg "Failed to remove ${TargetPath}: $($_.Exception.Message)"
    }
}

function Remove-EmptyDirectoryIfExists([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue) -or -not (Test-Path -LiteralPath $PathValue)) {
        return
    }

    try {
        $items = @(Get-ChildItem -LiteralPath $PathValue -Force -ErrorAction Stop)
        if ($items.Count -eq 0) {
            Remove-Item -LiteralPath $PathValue -Force -ErrorAction Stop
            Write-Info "Removed empty directory: $PathValue"
        }
    }
    catch {
        Write-WarnMsg "Failed to remove empty directory ${PathValue}: $($_.Exception.Message)"
    }
}

function Remove-CodexFilesAtPrefix([string]$PrefixDir) {
    $prefix = Normalize-ComparablePath $PrefixDir
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return
    }

    $targets = @(
        (Join-Path $prefix 'codex'),
        (Join-Path $prefix 'codex.cmd'),
        (Join-Path $prefix 'codex.ps1'),
        (Join-Path $prefix 'codex.exe'),
        (Join-Path $prefix 'node_modules\@openai\codex')
    )

    foreach ($target in $targets) {
        Remove-PathIfExists -TargetPath $target -SafetyRoot $prefix
    }

    foreach ($disabledWrapper in @(Get-ChildItem -LiteralPath $prefix -Filter 'codex.ps1.disabled*' -Force -ErrorAction SilentlyContinue)) {
        Remove-PathIfExists -TargetPath $disabledWrapper.FullName -SafetyRoot $prefix
    }

    Remove-EmptyDirectoryIfExists (Join-Path $prefix 'node_modules\@openai')
    Remove-EmptyDirectoryIfExists (Join-Path $prefix 'node_modules')
}

function Uninstall-CodexPackage {
    Write-Info 'Uninstalling Codex CLI first...'
    $prefixes = @(Get-CandidateNpmPrefixes)
    foreach ($prefix in $prefixes) {
        if (-not (Test-CodexPresentInPrefix $prefix)) {
            continue
        }

        [void](Invoke-NpmUninstallCodexAtPrefix $prefix)
        Remove-CodexFilesAtPrefix $prefix
    }

    foreach ($cmdName in @('codex', 'codex.cmd', 'codex.ps1')) {
        foreach ($cmd in @(Get-Command $cmdName -All -ErrorAction SilentlyContinue)) {
            $path = $null
            foreach ($propertyName in @('Path', 'Source')) {
                $matches = @($cmd.PSObject.Properties.Match($propertyName))
                if ($matches.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$matches[0].Value)) {
                    $path = [string]$matches[0].Value
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }
            $prefix = Split-Path -Parent $path
            if (Test-CodexPresentInPrefix $prefix) {
                [void](Invoke-NpmUninstallCodexAtPrefix $prefix)
                Remove-CodexFilesAtPrefix $prefix
            }
        }
    }
}

function Remove-UserPathEntries {
    param([string[]]$Entries)

    $normalizedEntries = @(Select-UniquePath $Entries)
    if ($normalizedEntries.Count -eq 0) {
        return
    }

    foreach ($scope in @('User')) {
        $pathValue = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ([string]::IsNullOrWhiteSpace($pathValue)) {
            continue
        }

        $changed = $false
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($part in ($pathValue -split ';')) {
            if ([string]::IsNullOrWhiteSpace($part)) {
                continue
            }

            $normalizedPart = Normalize-ComparablePath $part
            $remove = $false
            foreach ($entry in $normalizedEntries) {
                if ($normalizedPart -ieq $entry) {
                    $remove = $true
                    break
                }
            }

            if ($remove) {
                Write-Info "Removing from USER PATH: $part"
                $changed = $true
            }
            else {
                [void]$kept.Add($part)
            }
        }

        if ($changed) {
            [Environment]::SetEnvironmentVariable('Path', ($kept.ToArray() -join ';'), $scope)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:Path)) {
        $current = New-Object System.Collections.Generic.List[string]
        foreach ($part in ($env:Path -split ';')) {
            if ([string]::IsNullOrWhiteSpace($part)) {
                continue
            }
            $normalizedPart = Normalize-ComparablePath $part
            $remove = $false
            foreach ($entry in $normalizedEntries) {
                if ($normalizedPart -ieq $entry) {
                    $remove = $true
                    break
                }
            }
            if (-not $remove) {
                [void]$current.Add($part)
            }
        }
        $env:Path = ($current.ToArray() -join ';')
    }
}

function Remove-TextBlockFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$MarkerStart,
        [Parameter(Mandatory = $true)]
        [string]$MarkerEnd
    )

    if ([string]::IsNullOrWhiteSpace($PathValue) -or -not (Test-Path -LiteralPath $PathValue)) {
        return
    }

    try {
        $content = Get-Content -LiteralPath $PathValue -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content) -or -not $content.Contains($MarkerStart)) {
            return
        }

        $startPattern = [regex]::Escape($MarkerStart)
        $endPattern = [regex]::Escape($MarkerEnd)
        $pattern = "(?ms)\r?\n?$startPattern.*?$endPattern\r?\n?"
        $updated = [regex]::Replace($content, $pattern, [Environment]::NewLine)
        if ($updated -ne $content) {
            Set-Content -LiteralPath $PathValue -Value $updated -Encoding UTF8 -ErrorAction Stop
            Write-Info "Removed profile block from: $PathValue"
        }
    }
    catch {
        Write-WarnMsg "Failed to clean profile block from ${PathValue}: $($_.Exception.Message)"
    }
}

function Remove-CodexProfileShims {
    $profileCandidates = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('CurrentUserAllHosts', 'CurrentUserCurrentHost')) {
        try {
            $value = [string]$PROFILE.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                [void]$profileCandidates.Add($value)
            }
        }
        catch {
        }
    }
    try {
        $value = [string]$PROFILE
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            [void]$profileCandidates.Add($value)
        }
    }
    catch {
    }

    foreach ($profilePath in @(Select-UniquePath $profileCandidates.ToArray())) {
        Remove-TextBlockFromFile -PathValue $profilePath -MarkerStart '# >>> codex shim >>>' -MarkerEnd '# <<< codex shim <<<'
    }
}

function Clear-UserEnvIfPathMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string[]]$KnownPaths
    )

    $known = @(Select-UniquePath $KnownPaths)
    $userValue = [Environment]::GetEnvironmentVariable($Name, 'User')
    $processValue = [Environment]::GetEnvironmentVariable($Name, 'Process')

    foreach ($scopeInfo in @(
        [pscustomobject]@{ Scope = 'User'; Value = $userValue },
        [pscustomobject]@{ Scope = 'Process'; Value = $processValue }
    )) {
        if ([string]::IsNullOrWhiteSpace($scopeInfo.Value)) {
            continue
        }

        $normalized = Normalize-ComparablePath $scopeInfo.Value
        $matches = $false
        foreach ($path in $known) {
            if (($normalized -ieq $path) -or (Test-PathUnderRoot $normalized $path) -or (Test-PathUnderRoot $normalized $script:CodexAsciiRoot)) {
                $matches = $true
                break
            }
        }

        if ($matches) {
            [Environment]::SetEnvironmentVariable($Name, $null, $scopeInfo.Scope)
            Write-Info "Cleared $Name from $($scopeInfo.Scope) environment."
        }
    }
}

function Clear-CodexEnvironment {
    Write-Info 'Cleaning Codex-related environment variables and PATH entries...'

    $prefixes = @(Get-CandidateNpmPrefixes)
    $installerPrefixes = @(Get-InstallerNpmPrefixes)
    $homes = @(Get-CandidateCodexHomes)
    $caches = @(Select-UniquePath @($script:CodexNpmCache, $env:NPM_CONFIG_CACHE, (Get-NpmConfigValue 'cache')))

    Clear-UserEnvIfPathMatches -Name 'CODEX_HOME' -KnownPaths $homes
    Clear-UserEnvIfPathMatches -Name 'NPM_CONFIG_PREFIX' -KnownPaths $installerPrefixes
    Clear-UserEnvIfPathMatches -Name 'NPM_CONFIG_CACHE' -KnownPaths @(Select-UniquePath @((Join-Path $script:CodexAsciiRoot 'npm-cache'), $(if ($script:UseAsciiSafePaths) { $script:CodexNpmCache })))
    Clear-UserEnvIfPathMatches -Name 'NPM_CONFIG_USERCONFIG' -KnownPaths @($script:CodexAsciiRoot)

    [Environment]::SetEnvironmentVariable('CRS_OAI_KEY', $null, 'User')
    Remove-Item Env:CRS_OAI_KEY -ErrorAction SilentlyContinue
    Remove-CodexProfileShims

    $pathEntriesToRemove = @()
    if ($script:UseAsciiSafePaths -or (Test-PathUnderRoot $script:CodexNpmPrefix $script:CodexAsciiRoot)) {
        $pathEntriesToRemove += $script:CodexNpmPrefix
    }
    else {
        $remainingNpmItems = @()
        if (Test-Path -LiteralPath $script:CodexNpmPrefix) {
            $remainingNpmItems = @(Get-ChildItem -LiteralPath $script:CodexNpmPrefix -Force -ErrorAction SilentlyContinue)
        }
        if ($remainingNpmItems.Count -eq 0) {
            $pathEntriesToRemove += $script:CodexNpmPrefix
        }
        else {
            Write-WarnMsg "Keeping USER PATH entry because npm prefix still contains non-Codex items: $script:CodexNpmPrefix"
        }
    }

    Remove-UserPathEntries $pathEntriesToRemove

    $npmPath = Resolve-NpmCommandPath
    if (-not [string]::IsNullOrWhiteSpace($npmPath)) {
        $prefixValue = Get-NpmConfigValue 'prefix'
        if (-not [string]::IsNullOrWhiteSpace($prefixValue)) {
            foreach ($prefix in $installerPrefixes) {
                if ((Normalize-ComparablePath $prefixValue) -ieq (Normalize-ComparablePath $prefix)) {
                    & $npmPath config delete prefix --location user 2>$null | Out-Null
                    Write-Info 'Removed installer npm prefix from user npm config.'
                    break
                }
            }
        }

        $cacheValue = Get-NpmConfigValue 'cache'
        if (-not [string]::IsNullOrWhiteSpace($cacheValue)) {
            foreach ($cache in @(Select-UniquePath @((Join-Path $script:CodexAsciiRoot 'npm-cache'), $(if ($script:UseAsciiSafePaths) { $script:CodexNpmCache })))) {
                if ((Normalize-ComparablePath $cacheValue) -ieq (Normalize-ComparablePath $cache)) {
                    & $npmPath config delete cache --location user 2>$null | Out-Null
                    Write-Info 'Removed installer npm cache from user npm config.'
                    break
                }
            }
        }
    }
}

function Remove-FileIfExists([string]$TargetPath) {
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return
    }

    try {
        Remove-Item -LiteralPath $TargetPath -Force -ErrorAction Stop
        Write-Info "Removed: $TargetPath"
    }
    catch {
        Write-WarnMsg "Failed to remove ${TargetPath}: $($_.Exception.Message)"
    }
}

function Remove-CodexConfigFilesInHome([string]$CodexHomePath) {
    if ([string]::IsNullOrWhiteSpace($CodexHomePath) -or -not (Test-Path -LiteralPath $CodexHomePath)) {
        return
    }

    foreach ($name in @('config.toml', 'auth.json')) {
        Remove-FileIfExists (Join-Path $CodexHomePath $name)
    }

    foreach ($backup in @(Get-ChildItem -LiteralPath $CodexHomePath -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'config.toml.bak.*' -or $_.Name -like 'auth.json.bak.*'
    })) {
        if (-not $backup.PSIsContainer) {
            Remove-FileIfExists $backup.FullName
        }
    }
}

function Remove-CodexHomeAndCaches {
    if ($KeepCodexHome) {
        Write-WarnMsg 'Keeping Codex home/config because -KeepCodexHome was specified.'
    }
    else {
        foreach ($codexHomePath in @(Get-CandidateCodexHomes)) {
            if ((Test-PathUnderRoot $codexHomePath $script:CodexAsciiRoot) -or $ForceRemoveCodexHome) {
                Remove-PathIfExists -TargetPath $codexHomePath
            }
            elseif ((-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) -and (Test-PathUnderRoot $codexHomePath $env:USERPROFILE)) {
                Remove-CodexConfigFilesInHome $codexHomePath
                Remove-EmptyDirectoryIfExists $codexHomePath
            }
            else {
                Write-WarnMsg "Skipping Codex home outside known safe roots: $codexHomePath"
            }
        }
    }

    if ($KeepNpmCache) {
        Write-WarnMsg 'Keeping npm cache because -KeepNpmCache was specified.'
    }
    elseif ($script:UseAsciiSafePaths -or (Test-PathUnderRoot $script:CodexNpmCache $script:CodexAsciiRoot)) {
        Remove-PathIfExists -TargetPath $script:CodexNpmCache -SafetyRoot $script:CodexAsciiRoot
    }
    else {
        Write-WarnMsg "Keeping shared npm cache: $script:CodexNpmCache"
    }

    Remove-EmptyDirectoryIfExists $script:CodexAsciiRoot
}

function Invoke-NodeNpmUninstall {
    if ($SkipNodeUninstall) {
        Write-WarnMsg 'Skipping Node.js/npm uninstall because -SkipNodeUninstall was specified.'
        return
    }

    Write-Info 'Uninstalling npm and Node.js after Codex cleanup...'

    if (Test-Path -LiteralPath $script:UserNodeRoot) {
        $safetyRoot = if ($script:UseAsciiSafePaths) {
            $script:CodexAsciiRoot
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            Join-Path $env:LOCALAPPDATA 'Programs'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            Join-Path $env:USERPROFILE '.local'
        }
        else {
            $null
        }

        Write-Info "Removing user-level Node.js/npm install: $script:UserNodeRoot"
        Remove-PathIfExists -TargetPath $script:UserNodeRoot -SafetyRoot $safetyRoot
        Remove-UserPathEntries @($script:UserNodeRoot)
        Remove-EmptyDirectoryIfExists $script:CodexAsciiRoot
        return
    }

    $nodeCmd = @(Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1)
    $npmCmd = @(Get-Command npm -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($nodeCmd.Count -gt 0 -or $npmCmd.Count -gt 0) {
        Write-WarnMsg 'node/npm still resolve on PATH, but they are outside the user-level install path owned by this package.'
        Write-WarnMsg 'System/shared Node.js was left installed. Remove it manually from Apps & Features if that is intended.'
    }
    else {
        Write-Ok 'Node.js/npm are not found on PATH.'
    }
}

function Write-FinalSummary {
    Write-Host ''
    foreach ($name in @('codex', 'node', 'npm')) {
        $cmd = @(Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($cmd.Count -eq 0) {
            Write-Ok "$name is not found on PATH."
        }
        else {
            $path = if (-not [string]::IsNullOrWhiteSpace($cmd[0].Path)) { $cmd[0].Path } else { $cmd[0].Source }
            Write-WarnMsg "$name still resolves on PATH: $path"
        }
    }

    Write-Host ''
    Write-Host 'Done. Reopen PowerShell/cmd before re-checking codex/node/npm.' -ForegroundColor White
}

Initialize-CodexPathSettings
Write-Info 'Starting Codex CLI + Node.js/npm uninstall...'
Write-Info "Codex npm prefix: $script:CodexNpmPrefix"
Write-Info "Codex home: $script:CodexHome"
Write-Info "Node root: $script:UserNodeRoot"

Stop-CodexAndNodeProcesses
Uninstall-CodexPackage
Clear-CodexEnvironment
Remove-CodexHomeAndCaches
Invoke-NodeNpmUninstall
Write-FinalSummary
