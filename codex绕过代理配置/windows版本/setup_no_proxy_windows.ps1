# Codex NO_PROXY bypass setup (Windows)
# - Adds 3.27.43.117, 3.27.43.117:10086, localhost, and 127.0.0.1 to NO_PROXY at User scope.
# - Idempotent: safe to run multiple times.
# - Persists across reboot for the current Windows user.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log([string]$Message) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Write-Host "[$ts] $Message"
}

$Required = @(
  "3.27.43.117",
  "3.27.43.117:10086",
  "localhost",
  "127.0.0.1"
)

function Normalize-List([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  return $Value.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

function Add-Unique([System.Collections.Generic.List[string]]$List, [string]$Item) {
  if (-not $List.Contains($Item)) { [void]$List.Add($Item) }
}

Write-Log "Reading current NO_PROXY..."
$CurrentUser = [Environment]::GetEnvironmentVariable("NO_PROXY", "User")
$Current = if ([string]::IsNullOrWhiteSpace($CurrentUser)) { $env:NO_PROXY } else { $CurrentUser }
$CurrentSafe = if ($null -eq $Current) { "" } else { $Current }

Write-Log "Current NO_PROXY (User/Process):"
Write-Host ("  " + $CurrentSafe)

$Items = New-Object System.Collections.Generic.List[string]
foreach ($v in (Normalize-List $CurrentSafe)) { Add-Unique $Items $v }

foreach ($v in $Required) {
  if ($Items.Contains($v)) {
    Write-Log "Already present: $v"
  } else {
    Write-Log "Adding: $v"
    [void]$Items.Add($v)
  }
}

$NewValue = ($Items -join ",")

if ($NewValue -eq $CurrentSafe) {
  Write-Log "NO_PROXY already up-to-date. No changes written."
} else {
  Write-Log "Writing NO_PROXY to User environment variables (persistent)..."
  [Environment]::SetEnvironmentVariable("NO_PROXY", $NewValue, "User")

  # Also update the current PowerShell process so later commands in this window see it.
  $env:NO_PROXY = $NewValue

  Write-Log "Write complete."
}

Write-Log "New NO_PROXY:"
Write-Host ("  " + $NewValue)

# Broadcast WM_SETTINGCHANGE so new processes launched from Explorer pick up the change.
# (Not required for persistence; without it you may need to re-login / restart apps.)
try {
  if (-not ("Codex.NativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Codex {
  public static class NativeMethods {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
      IntPtr hWnd, int Msg, IntPtr wParam, string lParam,
      int fuFlags, int uTimeout, out IntPtr lpdwResult);
  }
}
"@ -ErrorAction Stop
  }

  $HWND_BROADCAST = [IntPtr]0xffff
  $WM_SETTINGCHANGE = 0x1A
  $SMTO_ABORTIFHUNG = 0x0002
  $result = [IntPtr]::Zero
  [void][Codex.NativeMethods]::SendMessageTimeout(
    $HWND_BROADCAST,
    $WM_SETTINGCHANGE,
    [IntPtr]::Zero,
    "Environment",
    $SMTO_ABORTIFHUNG,
    5000,
    [ref]$result
  )
  Write-Log "Broadcasted environment change (Explorer/new processes should pick it up)."
} catch {
  Write-Log "Warning: failed to broadcast environment change (safe to ignore)."
  Write-Log $_.Exception.Message
}

Write-Log "Note: restart apps (VS Code/Codex/terminals) to pick up updated NO_PROXY."
