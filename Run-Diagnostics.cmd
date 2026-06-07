@echo off
cd /d "%~dp0"
if not exist "%~dp0doctor.ps1" (
    echo Missing doctor.ps1.
    echo Please extract the full ZIP package first, then run this file again.
    pause
    exit /b 1
)
if not exist "%~dp0lib\bootstrap.ps1" (
    echo Missing lib\bootstrap.ps1.
    echo Please extract the full ZIP package first, then run this file again.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
echo.
echo Press any key to exit...
pause >nul
