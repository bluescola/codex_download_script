@echo off
setlocal

title Codex NO_PROXY Bypass Setup (Windows)
echo.
echo [Codex] This script will derive NO_PROXY from .codex\config.toml base_url,
echo [Codex] and append localhost / 127.0.0.1 plus the matching host and host:port.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_no_proxy_windows.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
  echo [Codex][ERROR] setup_no_proxy_windows.ps1 exited with code %EXIT_CODE%.
  echo.
  pause
  endlocal
  exit /b %EXIT_CODE%
)
echo [Codex] Done. If VS Code/Codex is running, restart it to pick up the change.
echo.
pause

endlocal
exit /b 0
