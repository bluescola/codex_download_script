@echo off
setlocal
rem Wrapper: manually restart the Windows Codex app-server daemon.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-codex-app-server.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if "%EXIT_CODE%"=="0" (
  echo [OK] restart-codex-app-server completed.
) else (
  echo [ERROR] restart-codex-app-server failed with exit code %EXIT_CODE%.
)
echo [INFO] Exit code: %EXIT_CODE%
echo Press any key to close this window...
pause >nul
exit /b %EXIT_CODE%
