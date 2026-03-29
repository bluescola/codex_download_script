@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-node-npm.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Script failed with code %RC%. See messages above.
)

echo.
pause
exit /b %RC%
