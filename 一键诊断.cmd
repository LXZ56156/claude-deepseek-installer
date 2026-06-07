@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo ================================================================
echo   Claude Code + DeepSeek 一键诊断 v1.3.0
echo ================================================================
echo.
echo   正在运行系统诊断...
echo   诊断完成后会生成 report.txt 文件。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ================================================================
    echo   诊断脚本执行异常（退出码: %ERRORLEVEL%）
    echo   请截图此窗口并发给技术支持。
    echo ================================================================
)
echo.
echo   诊断报告已保存到当前目录下的 report-YYYYMMDD-HHMMSS.txt 文件。
echo   请将此报告发给技术支持（报告中不包含完整 API Key）。
echo.
pause
