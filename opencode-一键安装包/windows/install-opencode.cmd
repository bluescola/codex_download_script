@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-opencode.ps1" %*
exit /b %errorlevel%
