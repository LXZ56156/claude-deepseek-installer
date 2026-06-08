@echo off
setlocal
pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
    echo Failed to enter script directory:
    echo %~dp0
    echo Please extract the full ZIP package to a local disk folder, for example Desktop, then run again.
    pause
    exit /b 1
)
if not exist "%~dp0Start-Here.ps1" (
    echo Missing Start-Here.ps1.
    echo Please extract the full ZIP package first, then run this file again.
    popd >nul 2>&1
    pause
    exit /b 1
)
if not exist "%~dp0lib\bootstrap.ps1" (
    echo Missing lib\bootstrap.ps1.
    echo Please extract the full ZIP package first, then run this file again.
    popd >nul 2>&1
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Here.ps1"
set "PS_EXIT=%ERRORLEVEL%"
echo.
echo Press any key to exit...
pause >nul
popd >nul 2>&1
endlocal & exit /b %PS_EXIT%
