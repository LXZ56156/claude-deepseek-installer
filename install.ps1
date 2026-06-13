# ============================================================
# install.ps1 - 兼容入口（已废弃，自动转发到新版入口）
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# 注意:
#   此入口已废弃，请直接使用 Start-Here.ps1 / 开始安装.cmd。
#   本脚本会自动转发到对应新版入口，不会进入旧独立流程。
#
# 合规声明:
#   本脚本仅做本地安装和配置。
#   不提供 Claude 账号、API Key、中转服务。
#   用户需自备 DeepSeek API Key。
# ============================================================

param(
    [switch]$SkipDisclaimer,  # 跳过免责声明（转发到 Start-Here.ps1）
    [switch]$Quiet,           # 安静模式（保留兼容，当前无独立作用）
    [ValidateSet("Menu", "InstallOnly", "InstallAndConfigure", "Doctor", "ConfigureOnly")]
    [string]$Mode = "Menu",
    [switch]$NonInteractive,  # 非交互模式
    [switch]$SkipApiTest,     # 跳过 API 测试
    [switch]$TestSafe         # 测试安全模式（仅转发到 Start-Here.ps1 时生效）
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }

# ============================================================
# 用户提示：旧入口 -> 新版入口
# ============================================================

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host "  [INFO] 检测到你运行的是旧入口 install.ps1。" -ForegroundColor Yellow
Write-Host "  当前推荐入口是 Start-Here.ps1 / 开始安装.cmd。" -ForegroundColor Yellow
Write-Host "  正在自动切换到新版一键安装流程。" -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host ""

# ============================================================
# 转发逻辑
# ============================================================

try {
    switch ($Mode) {
        "Doctor" {
            $doctorPath = Join-Path $EntryScriptDir "doctor.ps1"
            if (-not (Test-Path $doctorPath)) {
                Write-Host "[ERROR] 找不到 doctor.ps1，请确认 ZIP 已完整解压。" -ForegroundColor Red
                exit 1
            }
            # 使用显式参数语法，避免 array splatting 在存在 [string] 位置参数时误绑定
            if ($SkipApiTest) {
                & $doctorPath -SkipApiTest -ShareSafe
            } else {
                & $doctorPath -ShareSafe
            }
            exit $LASTEXITCODE
        }

        "ConfigureOnly" {
            $configPath = Join-Path $EntryScriptDir "configure-deepseek.ps1"
            if (-not (Test-Path $configPath)) {
                Write-Host "[ERROR] 找不到 configure-deepseek.ps1，请确认 ZIP 已完整解压。" -ForegroundColor Red
                exit 1
            }
            if ($NonInteractive -and $SkipApiTest) {
                & $configPath -NonInteractive -SkipApiTest
            } elseif ($NonInteractive) {
                & $configPath -NonInteractive
            } elseif ($SkipApiTest) {
                & $configPath -SkipApiTest
            } else {
                & $configPath
            }
            exit $LASTEXITCODE
        }

        "InstallOnly" {
            Write-Host "[INFO] 旧 InstallOnly 模式已合并到新版入口。正在切换到 Start-Here.ps1。" -ForegroundColor Yellow
        }

        # Menu / InstallAndConfigure / default all fall through to Start-Here.ps1
        default {
            # default: 转发到 Start-Here.ps1
        }
    }

    # 所有非 Doctor / ConfigureOnly 模式均转发到 Start-Here.ps1
    $startHerePath = Join-Path $EntryScriptDir "Start-Here.ps1"
    if (-not (Test-Path $startHerePath)) {
        Write-Host "[ERROR] 找不到 Start-Here.ps1，请确认 ZIP 已完整解压后再运行。" -ForegroundColor Red
        exit 1
    }

    $startHereArgs = @()
    if ($NonInteractive) { $startHereArgs += "-NonInteractive" }
    if ($SkipApiTest) { $startHereArgs += "-SkipApiTest" }
    if ($SkipDisclaimer) { $startHereArgs += "-SkipDisclaimer" }
    if ($TestSafe) { $startHereArgs += "-TestSafe" }

    & $startHerePath @startHereArgs
    exit $LASTEXITCODE
}
catch {
    Write-Host "[ERROR] 转发失败: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
