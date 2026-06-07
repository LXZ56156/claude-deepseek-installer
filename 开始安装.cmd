@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo ================================================================
echo   Claude Code + DeepSeek API 本地配置助手 v1.3.0
echo ================================================================
echo.
echo   正在启动安装向导...
echo   如果弹出 PowerShell 窗口，请允许运行。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Here.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ================================================================
    echo   脚本执行异常（退出码: %ERRORLEVEL%）
    echo   请截图此窗口并发给技术支持。
    echo   也可以尝试右键 "Start-Here.ps1" -> "使用 PowerShell 运行"
    echo ================================================================
)
pause
