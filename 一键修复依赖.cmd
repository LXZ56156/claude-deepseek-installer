@echo off
pushd "%~dp0"
echo ==============================================================
echo   Repair Dependencies (Node.js / npm / Claude Code)
echo ==============================================================
echo.
echo Detecting and repairing missing system dependencies...
echo Chinese prompts will be shown in the PowerShell window.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\repair-deps.ps1"
popd
pause
