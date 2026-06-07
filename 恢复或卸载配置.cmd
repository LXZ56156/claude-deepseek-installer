@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-config.ps1"
echo.
echo Press any key to exit...
pause >nul
