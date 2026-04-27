param(
    [switch]$ForceNodeReinstall,
    [switch]$ForceCodexReinstall,
    [switch]$SkipCrsConfig,
    [string]$UninstallSystemCodexPrefix,
    [string]$NpmCommandPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$UserNodeRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Join-Path $env:USERPROFILE '.local\node'
} else {
    Join-Path $env:LOCALAPPDATA 'Programs\nodejs'
}
$script:NpmCommandOverride = $NpmCommandPath

function Write-Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnMsg([string]$Message) {
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Ok([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
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

function Refresh-Path {
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

function Ensure-UserPathContains([string]$PathEntry) {
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
    foreach ($p in $parts) {
        if ($p.Trim().TrimEnd('\') -ieq $normalizedEntry) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
            $normalizedEntry
        } else {
            "$userPath;$normalizedEntry"
        }
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        Write-Info "Added to USER PATH: $normalizedEntry"
    }
}

function Resolve-NpmGlobalBinDir {
    try {
        $prefix = (& npm config get prefix).Trim()
        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
            return $prefix
        }
    }
    catch {
    }

    return (Join-Path $env:APPDATA 'npm')
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

function Ensure-NpmUserPrefix {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        return
    }

    $target = Join-Path $env:APPDATA 'npm'
    $current = $null
    try {
        $current = (& npm config get prefix).Trim()
    }
    catch {
    }

    if ([string]::IsNullOrWhiteSpace($current) -or ($current -ne $target)) {
        & npm config set prefix $target | Out-Null
        Write-Info "Set npm prefix to user directory: $target"
    }
}

function Resolve-NodeInstallDir {
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
    if (Command-Exists 'codex') {
        return $true
    }
    if (Command-Exists 'codex.cmd') {
        return $true
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

    $targets = @(
        Join-Path $CodexDir 'config.toml'
        Join-Path $CodexDir 'auth.json'
    )

    foreach ($file in $targets) {
        if (Test-Path $file) {
            try {
                Remove-Item -LiteralPath $file -Force -ErrorAction Stop
                Write-Info "Removed old config: $file"
            }
            catch {
                Write-WarnMsg "Failed to remove ${file}: $($_.Exception.Message)"
            }
        }
    }

    foreach ($pattern in @('config.toml.bak.*', 'auth.json.bak.*')) {
        try {
            $matches = @(Get-ChildItem -Path $CodexDir -Force -File -Filter $pattern -ErrorAction SilentlyContinue)
            foreach ($m in $matches) {
                try {
                    Remove-Item -LiteralPath $m.FullName -Force -ErrorAction Stop
                    Write-Info "Removed old backup: $($m.FullName)"
                }
                catch {
                    Write-WarnMsg "Failed to remove $($m.FullName): $($_.Exception.Message)"
                }
            }
        }
        catch {
        }
    }

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
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$PathToBackup.bak.$timestamp"
    Copy-Item -Path $PathToBackup -Destination $backupPath -Force
    Write-Info "Backed up existing file: $backupPath"
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

function Install-NodeUserZip {
    Write-Info 'Installing Node.js LTS to user directory (no admin)...'

    $lts = Get-NodeLtsZipInfo
    $version = $lts.version
    $zipUrl = "https://nodejs.org/dist/$version/node-$version-win-x64.zip"
    $zipPath = Join-Path $env:TEMP "node-$version-win-x64.zip"
    $extractRoot = Join-Path $env:TEMP "node-$version-win-x64"

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

    Ensure-UserPathContains $UserNodeRoot
    if (-not (($env:Path -split ';') -contains $UserNodeRoot)) {
        $env:Path = "$UserNodeRoot;$env:Path"
    }

    Write-Ok "Node.js: $(& (Join-Path $UserNodeRoot 'node.exe') -v)"
    Write-Ok "npm: $(& (Join-Path $UserNodeRoot 'npm.cmd') -v)"
}

function Ensure-Node {
    # Prefer any existing Node/npm available on PATH (system install or other managed installs).
    # Only fall back to downloading a user-local Node zip if Node/npm are not present.
    Refresh-Path
    if ((Test-PreexistingNodeAndNpm) -and -not $ForceNodeReinstall) {
        Write-Info 'Node.js and npm already present.'
        Write-Ok ("Node.js: " + (node -v))
        Write-Ok ("npm: " + (npm -v))
        return
    }

    if ($ForceNodeReinstall -and (Test-Path $UserNodeRoot)) {
        Write-Info "Removing previous user Node.js install at $UserNodeRoot"
        Remove-Item -Recurse -Force $UserNodeRoot
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

    if (-not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
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

        $probeOutput = & powershell.exe @probeArgs 2>&1
        $probeExit = $LASTEXITCODE
        $probeLabel = if ($NoProfile) { 'NoProfile' } else { 'Normal' }

        foreach ($line in @($probeOutput)) {
            $text = "$line".Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                Write-WarnMsg "[Probe][$probeLabel] $text"
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
    & npm i -g @openai/codex
    $installExit = $LASTEXITCODE
    if ($installExit -eq 0) {
        return
    }

    $logDir = Join-Path $env:LOCALAPPDATA 'npm-cache\_logs'
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

    & npm i -g @openai/codex
    $retryExit = $LASTEXITCODE
    if ($retryExit -ne 0) {
        throw "npm install -g @openai/codex failed (exit $retryExit). Close terminals/tools using codex.exe and retry."
    }
}

function Ensure-Codex {
    $userNpmBinDir = $null
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $userNpmBinDir = Join-Path $env:APPDATA 'npm'
    }

    Write-Info 'Checking for system-level Codex CLI before user install...'
    Ensure-NoSystemCodex $userNpmBinDir
    Ensure-NpmUserPrefix
    $npmBinDir = Resolve-NpmGlobalBinDir

    if ($ForceCodexReinstall) {
        Write-Info 'Force reinstall requested: uninstalling existing Codex CLI...'
        npm uninstall -g @openai/codex | Out-Null
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

    Ensure-UserPathContains $npmBinDir
    $nodeInstallDir = Resolve-NodeInstallDir
    if ($nodeInstallDir) {
        Ensure-UserPathContains $nodeInstallDir
    }

    if (-not (($env:Path -split ';') -contains $npmBinDir)) {
        $env:Path = "$env:Path;$npmBinDir"
    }
    if ($nodeInstallDir -and -not (($env:Path -split ';') -contains $nodeInstallDir)) {
        $env:Path = "$env:Path;$nodeInstallDir"
    }
    Refresh-Path

    Ensure-CodexCommandWorks $npmBinDir
}

function Configure-CrsFiles {
    param(
        [switch]$CleanExistingConfig
    )

    $codexDir = Join-Path $env:USERPROFILE '.codex'
    $configPath = Join-Path $codexDir 'config.toml'
    $authPath = Join-Path $codexDir 'auth.json'

    Write-Info 'Starting CRS configuration...'
    Write-Info 'Please provide values for base_url and CRS_OAI_KEY.'

    $baseUrl = Read-RequiredInput 'Enter CRS base_url (example: http://x.x.x.x:10086/openai)'
    $crsKey = Read-SecretInput 'Enter CRS_OAI_KEY (input hidden)'

    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
    if ($CleanExistingConfig) {
        Write-Info 'Detected existing node/npm/codex; cleaning old CRS configuration before regenerating...'
        Clear-ExistingCrsConfig -CodexDir $codexDir
    }
    else {
        Backup-FileIfExists $configPath
        Backup-FileIfExists $authPath
    }

    $configToml = @"
model_provider = "crs"
model = "gpt-5.2"
model_reasoning_effort = "xhigh"
disable_response_storage = true
preferred_auth_method = "apikey"

sandbox_mode = "danger-full-access"
approval_policy = "on-request"
# 或者更激进：
# approval_policy = "never"

[model_providers.crs]
name = "crs"
base_url = "$baseUrl"
wire_api = "responses"
requires_openai_auth = false
env_key = "CRS_OAI_KEY"

[features]
# 实际已去除
tui_app_server = false
# 关闭MCP和 工具 / 列表 / 发现/建议
apps = false

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.4"
"gpt-5.2" = "gpt-5.4"
"@

    $authJson = @"
{
  "OPENAI_API_KEY": null
}
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($configPath, $configToml, $utf8NoBom)
    [System.IO.File]::WriteAllText($authPath, $authJson, $utf8NoBom)

    [Environment]::SetEnvironmentVariable('CRS_OAI_KEY', $crsKey, 'User')
    $env:CRS_OAI_KEY = $crsKey

    Write-Ok "Wrote config file: $configPath"
    Write-Ok "Wrote auth file: $authPath"
    Write-Ok 'Saved CRS_OAI_KEY to USER environment variables.'
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

Write-Info 'Starting install for Codex CLI and dependencies...'
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
