@echo off
setlocal
rem Wrapper: install Codex + write config, then set NO_PROXY bypass (User scope).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-codex-cli-and-setup-no-proxy.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" echo [ERROR] install-codex-cli exited with code %EXIT_CODE%
echo Press any key to close this window...
pause >nul
exit /b %EXIT_CODE%
