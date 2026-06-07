@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo ================================================================
echo   Claude Code + DeepSeek 配置管理 v1.3.0
echo ================================================================
echo.
echo   正在启动配置管理工具...
echo   您可以恢复备份配置、移除 API Key 或删除配置文件。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-config.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ================================================================
    echo   脚本执行异常（退出码: %ERRORLEVEL%）
    echo   请截图此窗口并发给技术支持。
    echo ================================================================
)
pause
