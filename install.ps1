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
    [switch]$SkipDisclaimer,
    [switch]$Quiet,
    [ValidateSet("Menu", "InstallOnly", "InstallAndConfigure", "Doctor", "ConfigureOnly")]
    [string]$Mode = "Menu",
    [switch]$NonInteractive,
    [switch]$SkipApiTest,
    [switch]$TestSafe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }

# ============================================================
# 安全转发函数 —— 不依赖 $LASTEXITCODE
# ============================================================

function Invoke-CcdiScriptAndExit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    try {
        & $ScriptPath @Arguments
        if ($?) { exit 0 } else { exit 1 }
    }
    catch {
        Write-Host "[ERROR] 转发失败: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# ============================================================
# 用户提示：旧入口 -> 新版入口（文案根据 Mode 区分）
# ============================================================

$forwardMessage = switch ($Mode) {
    "Doctor"        { "正在切换到新版诊断入口 doctor.ps1。" }
    "ConfigureOnly" { "正在切换到 DeepSeek 单独配置入口 configure-deepseek.ps1。" }
    default         { "正在自动切换到新版一键安装流程。" }
}
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host "  [INFO] 检测到你运行的是旧入口 install.ps1。" -ForegroundColor Yellow
Write-Host "  当前推荐入口是 Start-Here.ps1 / 开始安装.cmd。" -ForegroundColor Yellow
Write-Host "  $forwardMessage" -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host ""

# ============================================================
# 转发逻辑
# ============================================================

switch ($Mode) {
    "Doctor" {
        $doctorPath = Join-Path $EntryScriptDir "doctor.ps1"
        if (-not (Test-Path $doctorPath)) {
            Write-Host "[ERROR] 找不到 doctor.ps1，请确认 ZIP 已完整解压。" -ForegroundColor Red
            exit 1
        }
        $doctorArgs = @()
        if ($SkipApiTest) { $doctorArgs += "-SkipApiTest" }
        $doctorArgs += "-ShareSafe"
        Invoke-CcdiScriptAndExit -ScriptPath $doctorPath -Arguments $doctorArgs
    }

    "ConfigureOnly" {
        $configPath = Join-Path $EntryScriptDir "configure-deepseek.ps1"
        if (-not (Test-Path $configPath)) {
            Write-Host "[ERROR] 找不到 configure-deepseek.ps1，请确认 ZIP 已完整解压。" -ForegroundColor Red
            exit 1
        }
        $configArgs = @()
        if ($NonInteractive) { $configArgs += "-NonInteractive" }
        if ($SkipApiTest) { $configArgs += "-SkipApiTest" }
        Invoke-CcdiScriptAndExit -ScriptPath $configPath -Arguments $configArgs
    }

    "InstallOnly" {
        Write-Host "[INFO] 旧 InstallOnly 模式已合并到新版入口。正在切换到 Start-Here.ps1。" -ForegroundColor Yellow
    }

    # Menu / InstallAndConfigure / default all fall through to Start-Here.ps1
    default {}
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

Invoke-CcdiScriptAndExit -ScriptPath $startHerePath -Arguments $startHereArgs