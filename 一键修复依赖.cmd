@echo off
setlocal
chcp 65001 >nul 2>&1
pushd "%~dp0" >nul 2>&1
if errorlevel 1 (
    echo [错误] 无法进入脚本所在目录。
    echo 当前路径：%~dp0
    echo 你可能是在 ZIP 压缩包预览窗口里直接运行了本工具。请先完整解压 ZIP 到普通文件夹（例如桌面），再双击入口文件。
    echo 按任意键关闭窗口... & pause >nul
    exit /b 1
)
if not exist "%~dp0repair-deps.ps1" (
    echo [错误] 缺少 repair-deps.ps1。
    echo 请先完整解压 ZIP 后再运行本文件。
    echo 按任意键关闭窗口... & pause >nul
    popd >nul 2>&1
    exit /b 1
)
if not exist "%~dp0lib\bootstrap.ps1" (
    echo [错误] 缺少 lib\bootstrap.ps1。
    echo 请右键 ZIP 选择"全部解压"，解压到普通文件夹后再运行。
    echo 按任意键关闭窗口... & pause >nul
    popd >nul 2>&1
    exit /b 1
)
echo ==============================================================
echo   一键修复依赖 (Node.js / npm / Claude Code)
echo ==============================================================
echo.
echo 正在检测并修复缺失的系统依赖...
echo 中文提示将在 PowerShell 窗口中显示。
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-deps.ps1"
set "PS_EXIT=%ERRORLEVEL%"
echo.
echo 按任意键关闭窗口...
pause >nul
popd >nul 2>&1
endlocal & exit /b %PS_EXIT%
