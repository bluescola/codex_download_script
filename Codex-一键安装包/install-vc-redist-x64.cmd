@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-vc-redist-x64.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" echo [ERROR] install-vc-redist-x64 exited with code %EXIT_CODE%
echo Press any key to close this window...
pause >nul
exit /b %EXIT_CODE%
