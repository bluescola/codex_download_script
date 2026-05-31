function Initialize-CodexLogging {
    param(
        [string]$Level = 'normal'
    )

    if ([string]::IsNullOrWhiteSpace($Level)) {
        $Level = 'normal'
    }

    switch ($Level) {
        'normal' { $script:CodexLogLevel = 'normal' }
        'verbose' { $script:CodexLogLevel = 'verbose' }
        'trace' { $script:CodexLogLevel = 'trace' }
        default {
            $script:CodexLogLevel = 'normal'
            Write-Host "[WARN] Unknown log level `"$Level`"; using normal." -ForegroundColor Yellow
        }
    }
}

function Write-CodexLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Level,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    Write-Host "[$Level] $Message" -ForegroundColor $Color

    $dryRunVariable = Get-Variable -Scope Script -Name DryRun -ErrorAction SilentlyContinue
    $isDryRun = $dryRunVariable -and [bool]$dryRunVariable.Value
    if ((-not $isDryRun) -and (-not [string]::IsNullOrWhiteSpace($env:CODEX_INSTALL_LOG_FILE))) {
        try {
            $logDir = Split-Path -Parent $env:CODEX_INSTALL_LOG_FILE
            if (-not [string]::IsNullOrWhiteSpace($logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
            Add-Content -LiteralPath $env:CODEX_INSTALL_LOG_FILE -Value $line -Encoding UTF8
        }
        catch {
        }
    }
}

function Write-Info([string]$Message) {
    Write-CodexLog -Level 'INFO' -Message $Message -Color Cyan
}

function Write-WarnMsg([string]$Message) {
    Write-CodexLog -Level 'WARN' -Message $Message -Color Yellow
}

function Write-Ok([string]$Message) {
    Write-CodexLog -Level 'OK' -Message $Message -Color Green
}

function Write-DebugMsg([string]$Message) {
    if ($script:CodexLogLevel -in @('verbose', 'trace')) {
        Write-CodexLog -Level 'DEBUG' -Message $Message -Color DarkCyan
    }
}

function Write-TraceMsg([string]$Message) {
    if ($script:CodexLogLevel -eq 'trace') {
        Write-CodexLog -Level 'TRACE' -Message $Message -Color DarkGray
    }
}
