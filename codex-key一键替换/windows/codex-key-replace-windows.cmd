@echo off
setlocal EnableExtensions

if /I not "%~1"=="--keep-open" (
  start "codex-key-replace" cmd /k ""%~f0" --keep-open"
  exit /b
)

set "PS1=%~dp0codex-key-replace-windows.ps1"

if not exist "%PS1%" (
  echo Script not found: "%PS1%"
  echo Ensure the .cmd and .ps1 are in the same folder.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

set "exitcode=%errorlevel%"
echo.
echo Exit code: %exitcode%
pause
exit /b %exitcode%
