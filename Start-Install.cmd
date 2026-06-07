@echo off
cd /d "%~dp0"
if not exist "%~dp0Start-Here.ps1" (
    echo Missing Start-Here.ps1.
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Here.ps1"
set "PS_EXIT=%ERRORLEVEL%"
echo.
echo Press any key to exit...
pause >nul
exit /b %PS_EXIT%
