@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Here.ps1"
echo.
echo Press any key to exit...
pause >nul
