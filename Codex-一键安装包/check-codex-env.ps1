param(
    [switch]$AsJson,
    [switch]$FailOnWarning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-WarnMsg([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Split-PathEntries([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return @()
    }

    return @(
        $PathValue -split ';' |
        ForEach-Object { $_.Trim().Trim('"') } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Normalize-Path([string]$PathText) {
    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return ''
    }

    return $PathText.Trim().Trim('"').TrimEnd('\\').ToLowerInvariant()
}

function New-PathSet([string]$PathValue) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in Split-PathEntries $PathValue) {
        [void]$set.Add((Normalize-Path $entry))
    }
    return $set
}

function Add-PathToCurrentProcess([string]$PathEntry) {
    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return
    }

    $normalized = Normalize-Path $PathEntry
    $currentSet = New-PathSet $env:Path
    if (-not $currentSet.Contains($normalized)) {
        if ([string]::IsNullOrWhiteSpace($env:Path)) {
            $env:Path = $PathEntry
        }
        else {
            $env:Path = "$env:Path;$PathEntry"
        }
    }
}

function Ensure-UserPathContains([string]$PathEntry) {
    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return $false
    }

    if (-not (Test-Path $PathEntry)) {
        return $false
    }

    $normalized = Normalize-Path $PathEntry
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userSet = New-PathSet $userPath

    if ($userSet.Contains($normalized)) {
        return $true
    }

    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
        $PathEntry
    }
    else {
        "$userPath;$PathEntry"
    }

    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    return $true
}

function Try-GetNpmPrefix {
    try {
        $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
        if (-not $npmCmd) {
            return $null
        }

        $prefix = (& npm config get prefix 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($prefix)) {
            return $prefix.Trim()
        }
    }
    catch {
    }

    return $null
}

function Resolve-CodexBinDir {
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $appDataNpm = Join-Path $env:APPDATA 'npm'
        [void]$candidates.Add($appDataNpm)
    }

    $npmPrefix = Try-GetNpmPrefix
    if (-not [string]::IsNullOrWhiteSpace($npmPrefix)) {
        [void]$candidates.Add($npmPrefix)
    }

    $codexCommands = @(Get-Command codex -All -ErrorAction SilentlyContinue)
    foreach ($cmd in $codexCommands) {
        if ([string]::IsNullOrWhiteSpace($cmd.Path)) {
            continue
        }

        $dir = Split-Path -Parent $cmd.Path
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            [void]$candidates.Add($dir)
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $normalized = Normalize-Path $candidate
        if ($seen.Contains($normalized)) {
            continue
        }
        [void]$seen.Add($normalized)

        $codexCmd = Join-Path $candidate 'codex.cmd'
        $codexPs1 = Join-Path $candidate 'codex.ps1'
        if ((Test-Path $codexCmd) -or (Test-Path $codexPs1)) {
            return $candidate
        }
    }

    return $null
}

function Resolve-CodexCmdPath([string]$CodexBinDir) {
    if (-not [string]::IsNullOrWhiteSpace($CodexBinDir)) {
        $candidate = Join-Path $CodexBinDir 'codex.cmd'
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $allCodex = @(Get-Command codex -All -ErrorAction SilentlyContinue)
    foreach ($c in $allCodex) {
        if ([string]::IsNullOrWhiteSpace($c.Path)) {
            continue
        }
        if ((Split-Path -Leaf $c.Path).ToLowerInvariant() -eq 'codex.cmd') {
            return $c.Path
        }
    }

    return $null
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
            $hint += ' If the runtime is already installed, inspect antivirus/AppLocker and the native executable under %APPDATA%\npm\node_modules\@openai\codex.'
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

function Try-FixExecutionPolicyForCodex {
    try {
        $currentUserPolicy = Get-ExecutionPolicy -Scope CurrentUser
        if ($currentUserPolicy -in @('Undefined', 'Restricted', 'AllSigned')) {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Write-Ok 'Execution policy updated: CurrentUser = RemoteSigned'
        }
        else {
            Write-Info "CurrentUser execution policy is already $currentUserPolicy"
        }
        return $true
    }
    catch {
        Write-WarnMsg "Failed to update execution policy automatically: $($_.Exception.Message)"
        return $false
    }
}

function Ensure-CodexProfileShim([string]$CodexCmdPath) {
    if ([string]::IsNullOrWhiteSpace($CodexCmdPath)) {
        return $false
    }

    if (-not (Test-Path $CodexCmdPath)) {
        return $false
    }

    $profilePath = $PROFILE.CurrentUserAllHosts
    if ([string]::IsNullOrWhiteSpace($profilePath)) {
        $profilePath = $PROFILE
    }
    if ([string]::IsNullOrWhiteSpace($profilePath)) {
        Write-WarnMsg 'Cannot resolve PowerShell profile path.'
        return $false
    }

    $profileDir = Split-Path -Parent $profilePath
    if (-not [string]::IsNullOrWhiteSpace($profileDir) -and -not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $markerStart = '# >>> codex shim >>>'
    $markerEnd = '# <<< codex shim <<<'
    $escapedCmdPath = $CodexCmdPath.Replace("'", "''")
    $shimBlock = @(
        $markerStart,
        'function global:codex {',
        '    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)',
        "    & '$escapedCmdPath' @Args",
        '}',
        $markerEnd
    ) -join [Environment]::NewLine

    $profileContent = ''
    try {
        $profileContent = Get-Content -Path $profilePath -Raw -ErrorAction Stop
    }
    catch {
        $profileContent = ''
    }

    if ($profileContent -match [regex]::Escape($markerStart)) {
        $pattern = [regex]::Escape($markerStart) + '.*?' + [regex]::Escape($markerEnd)
        $newContent = [regex]::Replace(
            $profileContent,
            $pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $shimBlock },
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($profileContent) -and -not $profileContent.EndsWith([Environment]::NewLine)) {
            $profileContent += [Environment]::NewLine
        }
        $newContent = $profileContent + $shimBlock + [Environment]::NewLine
    }

    Set-Content -Path $profilePath -Value $newContent -Encoding UTF8
    Write-Ok "PowerShell profile shim saved: $profilePath"
    return $true
}

function Set-CodexSessionShim([string]$CodexCmdPath) {
    if ([string]::IsNullOrWhiteSpace($CodexCmdPath)) {
        return $false
    }
    if (-not (Test-Path $CodexCmdPath)) {
        return $false
    }

    try {
        $escapedCmdPath = $CodexCmdPath.Replace("'", "''")
        $scriptText = "param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Args) & '$escapedCmdPath' @Args"
        $sb = [ScriptBlock]::Create($scriptText)
        Set-Item -Path Function:global:codex -Value $sb
        Write-Info 'Applied codex shim in current PowerShell session.'
        return $true
    }
    catch {
        Write-WarnMsg "Failed to apply session shim: $($_.Exception.Message)"
        return $false
    }
}

function Disable-CodexPs1Wrapper([string]$CodexBinDir) {
    if ([string]::IsNullOrWhiteSpace($CodexBinDir)) {
        return $false
    }

    $ps1Path = Join-Path $CodexBinDir 'codex.ps1'
    if (-not (Test-Path $ps1Path)) {
        return $false
    }

    $disabledPath = "$ps1Path.disabled"
    try {
        if (Test-Path $disabledPath) {
            Remove-Item -Path $disabledPath -Force -ErrorAction SilentlyContinue
        }
        Rename-Item -Path $ps1Path -NewName (Split-Path -Leaf $disabledPath) -Force
        Write-Ok "Disabled blocked wrapper: $ps1Path -> $disabledPath"
        return $true
    }
    catch {
        Write-WarnMsg "Failed to disable codex.ps1 wrapper: $($_.Exception.Message)"
        return $false
    }
}

function Test-CodexInPowerShell {
    param(
        [switch]$NoProfile
    )

    $ps = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $ps) {
        return -1
    }

    $probe = @'
try {
    Get-Command codex -ErrorAction Stop | Out-Null
    codex --version | Out-Null
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    exit 0
} catch [System.Management.Automation.CommandNotFoundException] {
    exit 12
} catch [System.Management.Automation.PSSecurityException] {
    exit 13
} catch {
    exit 14
}
'@
    $hadPref = Test-Path Env:PSExecutionPolicyPreference
    $savedPref = $null
    if ($hadPref) {
        $savedPref = $env:PSExecutionPolicyPreference
        Remove-Item Env:PSExecutionPolicyPreference -ErrorAction SilentlyContinue
    }

    try {
        $probeArgs = @()
        if ($NoProfile) {
            $probeArgs += '-NoProfile'
        }
        $probeArgs += @('-Command', $probe)

        & powershell.exe @probeArgs | Out-Null
        return $LASTEXITCODE
    }
    finally {
        if ($hadPref) {
            $env:PSExecutionPolicyPreference = $savedPref
        }
    }
}

$warnings = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]
$codexPathStatus = 'unknown'
$codexBinDir = $null

Write-Host ''
Write-Host '=== Codex Env Check ===' -ForegroundColor White
Write-Info "PowerShell: $($PSVersionTable.PSVersion)"
Write-Info "User: $env:USERNAME"
Write-Info "Host: $env:COMPUTERNAME"

Write-Host ''
Write-Info 'Checking Codex PATH entry...'
$codexBinDir = Resolve-CodexBinDir

if ([string]::IsNullOrWhiteSpace($codexBinDir)) {
    $codexPathStatus = 'codex_not_installed'
    $msg = 'Codex CLI does not appear to be installed (codex.cmd not found).'
    $failures.Add($msg)
    Write-Fail $msg
}
else {
    $normalizedCodex = Normalize-Path $codexBinDir
    $currentSet = New-PathSet $env:Path
    $userSet = New-PathSet ([Environment]::GetEnvironmentVariable('Path', 'User'))
    $machineSet = New-PathSet ([Environment]::GetEnvironmentVariable('Path', 'Machine'))

    $inCurrent = $currentSet.Contains($normalizedCodex)
    $inUser = $userSet.Contains($normalizedCodex)
    $inMachine = $machineSet.Contains($normalizedCodex)

    if ($inCurrent -or $inUser -or $inMachine) {
        $codexPathStatus = 'present'
        Write-Ok "Codex PATH already exists: $codexBinDir"

        if (-not $inCurrent -and ($inUser -or $inMachine)) {
            Add-PathToCurrentProcess $codexBinDir
            $msg = 'PATH exists in persistent env but not current shell; current shell PATH was refreshed.'
            $warnings.Add($msg)
            Write-WarnMsg $msg
        }
    }
    else {
        Write-WarnMsg "Codex PATH is missing: $codexBinDir"

        if (Ensure-UserPathContains $codexBinDir) {
            Add-PathToCurrentProcess $codexBinDir
            $codexPathStatus = 'added'
            Write-Ok "Codex PATH has been added to USER Path: $codexBinDir"
        }
        else {
            $codexPathStatus = 'add_failed'
            $msg = "Codex appears installed, but failed to add USER Path: $codexBinDir"
            $failures.Add($msg)
            Write-Fail $msg
        }
    }
}

Write-Host ''
Write-Info 'Command checks:'
foreach ($cmd in @('node', 'npm', 'codex')) {
    $found = @(Get-Command $cmd -All -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) {
        $msg = "Command missing: $cmd"
        $failures.Add($msg)
        Write-Fail $msg
        continue
    }

    $paths = @(
        $found |
        ForEach-Object { $_.Path } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
    Write-Ok "$cmd -> $($paths -join ', ')"
}

$codexVersionOk = $false
$defaultContextOk = $false
$blockedByPolicy = $false
$needsProfileShim = $false
$codexRuntimeFailure = $null
$profileProbeCode = $null
$noProfileProbeCode = $null
$codexCommandPresent = [bool](Get-Command codex -ErrorAction SilentlyContinue)
$codexCmdPath = Resolve-CodexCmdPath $codexBinDir
$profileProbeCode = Test-CodexInPowerShell

if ($profileProbeCode -eq 0) {
    Write-Ok 'codex works in a normal PowerShell session.'
    $codexVersionOk = $true
    $defaultContextOk = $true
}
elseif ($profileProbeCode -eq 12) {
    Write-WarnMsg 'A normal PowerShell session could not resolve `codex`. Reopen PowerShell or verify USER Path includes the Codex npm bin directory.'
}
elseif ($profileProbeCode -eq 13) {
    Write-WarnMsg 'A normal PowerShell session blocks codex.ps1 by execution policy.'
    $blockedByPolicy = $true
    $needsProfileShim = $true
}
elseif ($profileProbeCode -eq -1) {
    Write-WarnMsg 'powershell.exe not found for the PowerShell session probe.'
}
else {
    if ($profileProbeCode -eq 14) {
        Write-WarnMsg 'Normal PowerShell session probe failed with an exception.'
    }
    else {
        $profileProbeFailure = New-CodexNativeExitMessage 'codex in a normal PowerShell session' $profileProbeCode $null
        Write-WarnMsg $profileProbeFailure
        $codexRuntimeFailure = $profileProbeFailure
    }
}

$noProfileProbeCode = Test-CodexInPowerShell -NoProfile
if ($noProfileProbeCode -eq 0) {
    Write-Ok 'codex also works in PowerShell -NoProfile.'
}
elseif ($noProfileProbeCode -eq 12) {
    Write-WarnMsg 'PowerShell -NoProfile does not resolve `codex`. Normal interactive PowerShell may still work if PATH or profile shims are applied there.'
}
elseif ($noProfileProbeCode -eq 13) {
    Write-WarnMsg 'PowerShell -NoProfile blocks codex.ps1 by execution policy.'
    if (-not $defaultContextOk) {
        $blockedByPolicy = $true
        $needsProfileShim = $true
    }
}
elseif ($noProfileProbeCode -eq -1) {
    Write-WarnMsg 'powershell.exe not found for the PowerShell -NoProfile probe.'
}
elseif ($noProfileProbeCode -eq 14) {
    Write-WarnMsg 'PowerShell -NoProfile probe failed with an exception.'
}
else {
    Write-WarnMsg (New-CodexNativeExitMessage 'codex in PowerShell -NoProfile' $noProfileProbeCode $null)
}

if ($codexCommandPresent) {
    try {
        $verResult = Invoke-CodexVersionCommand 'codex'
        $verFailure = New-CodexVersionFailureMessage 'codex' $verResult
        if (-not $verFailure) {
            if ($defaultContextOk) {
                Write-Ok "codex --version: $($verResult.OutputText)"
                $codexVersionOk = $true
            }
            else {
                Write-Info "codex works in current script context: $($verResult.OutputText)"
                Write-Info 'Normal PowerShell session still needs remediation.'
            }
        }
        else {
            Write-WarnMsg $verFailure
            $codexRuntimeFailure = $verFailure
        }
    }
    catch [System.Management.Automation.PSSecurityException] {
        Write-WarnMsg 'PowerShell blocked codex.ps1 by execution policy.'
        $blockedByPolicy = $true
        $needsProfileShim = $true
    }
    catch {
        Write-WarnMsg "Direct codex invocation failed: $($_.Exception.Message)"
    }
}

if ($blockedByPolicy -and -not $defaultContextOk) {
    $fixedPolicy = Try-FixExecutionPolicyForCodex
    if ($fixedPolicy) {
        $probeAfterPolicy = Test-CodexInPowerShell
        if ($probeAfterPolicy -eq 0) {
            Write-Ok 'codex works in a normal PowerShell session after execution policy update.'
            $defaultContextOk = $true
            $codexVersionOk = $true
            $blockedByPolicy = $false
        }
        elseif ($probeAfterPolicy -eq 13) {
            Write-WarnMsg 'A normal PowerShell session still blocks codex after policy update.'
            $blockedByPolicy = $true
            $needsProfileShim = $true
        }
        else {
            Write-WarnMsg "Normal PowerShell session probe still failing after policy update (exit $probeAfterPolicy)."
        }
    }
}

if ($blockedByPolicy -and -not [string]::IsNullOrWhiteSpace($codexBinDir)) {
    $disabled = Disable-CodexPs1Wrapper $codexBinDir
    if ($disabled) {
        $probeAfterDisable = Test-CodexInPowerShell
        if ($probeAfterDisable -eq 0) {
            Write-Ok 'codex works in a normal PowerShell session after disabling codex.ps1 wrapper.'
            $codexVersionOk = $true
            $defaultContextOk = $true
            $blockedByPolicy = $false
            $needsProfileShim = $false
        }
        else {
            Write-WarnMsg "Normal PowerShell session probe is still failing after disabling codex.ps1 (exit $probeAfterDisable)."
        }
    }
}

if (-not $defaultContextOk -and -not [string]::IsNullOrWhiteSpace($codexCmdPath) -and (Test-Path $codexCmdPath)) {
    try {
        $verResult = Invoke-CodexVersionCommand $codexCmdPath
        $verFailure = New-CodexVersionFailureMessage 'codex.cmd' $verResult
        if (-not $verFailure) {
            Write-Ok "codex.cmd --version: $($verResult.OutputText)"
            if ($blockedByPolicy) {
                $needsProfileShim = $true
            }
            $probeAfterCmd = Test-CodexInPowerShell
            if ($probeAfterCmd -eq 0) {
                Write-Ok 'codex works in a normal PowerShell session after codex.cmd fallback.'
                $defaultContextOk = $true
                $codexVersionOk = $true
                $needsProfileShim = $false
            }
            elseif ($probeAfterCmd -eq 12) {
                Write-WarnMsg 'A normal PowerShell session still does not resolve `codex` after codex.cmd fallback. Reopen PowerShell or verify USER Path.'
            }
            else {
                Write-WarnMsg "Normal PowerShell session probe still failing after codex.cmd fallback (exit $probeAfterCmd)."
            }
        }
        else {
            Write-WarnMsg $verFailure
            $codexRuntimeFailure = $verFailure
        }
    }
    catch {
        Write-WarnMsg "codex.cmd fallback failed: $($_.Exception.Message)"
    }
}

if ($needsProfileShim -and $codexVersionOk -and -not [string]::IsNullOrWhiteSpace($codexCmdPath)) {
    $saved = Ensure-CodexProfileShim $codexCmdPath
    $sessionApplied = Set-CodexSessionShim $codexCmdPath
    if ($saved -or $sessionApplied) {
        Write-WarnMsg 'PowerShell shim is ready. Reopen PowerShell and run `codex` again.'
    }
}

if (-not $defaultContextOk) {
    if (-not ($codexPathStatus -eq 'codex_not_installed' -and -not $codexCommandPresent -and [string]::IsNullOrWhiteSpace($codexCmdPath))) {
        if (-not [string]::IsNullOrWhiteSpace($codexRuntimeFailure)) {
            $msg = $codexRuntimeFailure
        }
        elseif ($profileProbeCode -eq 12) {
            $msg = "codex is installed, but a new PowerShell session still does not resolve `codex`. Reopen PowerShell and verify USER Path includes: $codexBinDir"
        }
        elseif ($profileProbeCode -eq 13 -or $blockedByPolicy) {
            $msg = 'codex is installed but PowerShell blocks the `codex.ps1` wrapper. Run: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force, or use codex.cmd'
        }
        elseif ($noProfileProbeCode -eq 0) {
            $msg = 'codex is installed and works in PowerShell -NoProfile, but your normal PowerShell profile or startup scripts are interfering.'
        }
        else {
            $msg = 'codex is installed but cannot run in a normal PowerShell session. Reopen PowerShell and retry.'
        }
        $failures.Add($msg)
        Write-Fail $msg
    }
}

Write-Host ''
if ($failures.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Ok 'Check passed with no issues.'
    $exitCode = 0
}
elseif ($failures.Count -eq 0) {
    Write-WarnMsg "Check completed with $($warnings.Count) warning(s)."
    $exitCode = if ($FailOnWarning) { 1 } else { 0 }
}
else {
    Write-Fail "Check failed with $($failures.Count) error(s) and $($warnings.Count) warning(s)."
    $exitCode = 2
}

if ($AsJson) {
    $result = [ordered]@{
        timestamp = (Get-Date).ToString('s')
        codex_bin_dir = $codexBinDir
        codex_path_status = $codexPathStatus
        failures = @($failures)
        warnings = @($warnings)
        exit_code = $exitCode
    }
    $result | ConvertTo-Json -Depth 5
}

exit $exitCode
