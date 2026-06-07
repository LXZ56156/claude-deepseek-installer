@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
echo.
echo Press any key to exit...
pause >nul
