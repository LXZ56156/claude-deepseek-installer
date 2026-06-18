@echo off
setlocal
pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Cannot enter script directory.
    echo You may be running inside a ZIP preview window.
    echo Please extract the full ZIP to a normal folder first,
    echo then open the extracted folder and double-click this file.
    echo.
    echo Do NOT run from inside the ZIP preview.
    echo.
    pause
    exit /b 1
)
if not exist "%~dp0Start-Here.ps1" (
    echo [ERROR] Missing Start-Here.ps1.
    echo Please extract the complete ZIP package first.
    pause
    popd >nul 2>&1
    exit /b 1
)
if not exist "%~dp0lib\bootstrap.ps1" (
    echo [ERROR] Missing lib\bootstrap.ps1.
    echo Please use "Extract All" to extract the complete ZIP.
    pause
    popd >nul 2>&1
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Here.ps1"
set "PS_EXIT=%ERRORLEVEL%"
echo.
echo Press any key to close this window...
pause >nul
popd >nul 2>&1
endlocal & exit /b %PS_EXIT%