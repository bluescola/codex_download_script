@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "PS1_SCRIPT=%SCRIPT_DIR%uninstall-codex-cli-and-node-npm.ps1"

if not exist "%PS1_SCRIPT%" (
  echo [FAIL] Script not found: "%PS1_SCRIPT%"
  echo.
  pause
  exit /b 2
)

where powershell.exe >nul 2>nul
if errorlevel 1 (
  echo [FAIL] powershell.exe not found.
  echo.
  pause
  exit /b 2
)

echo.
echo === Codex CLI and Node.js/npm Uninstall ===
echo [INFO] Running "%PS1_SCRIPT%"
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" goto :ok
goto :fail

:ok
echo [ OK ] Uninstall completed.
goto :done

:fail
echo [FAIL] Uninstall failed.

goto :done

:done
echo [INFO] Exit code: %EXIT_CODE%
echo.
pause
exit /b %EXIT_CODE%
