@echo off
setlocal

title Codex NO_PROXY Bypass Setup (Windows)
echo.
echo [Codex] This script will add the following entries to NO_PROXY (User scope):
echo   - 3.27.43.117
echo   - 3.27.43.117:10086
echo   - localhost
echo   - 127.0.0.1
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_no_proxy_windows.ps1"

echo.
echo [Codex] Done. If VS Code/Codex is running, restart it to pick up the change.
echo.
pause

endlocal
