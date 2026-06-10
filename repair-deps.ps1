# ============================================================
# repair-deps.ps1 - 一键修复依赖 (v1.3.2)
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\repair-deps.ps1
#   或双击 "一键修复依赖.cmd"
#
# 功能:
#   检测并修复缺失的系统依赖（Node.js、npm、Claude Code）
#   生成 repair-deps-report.txt
#
# 安全策略:
#   - 不静默安装系统软件，必须用户确认或显式参数授权
#   - TestSafe/DryRun 模式不执行真实安装
#   - 不静默 sudo / winget
# ============================================================

param(
    [switch]$NonInteractive,
    [switch]$TestSafe,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$AllowInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }
. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")
$ScriptDir = Initialize-CcdiScript -ScriptName "repair-deps"

$ScriptVersion = "1.3.2"
$IsTestSafe = $TestSafe -or $DryRun -or ($env:CCDI_TEST_MODE -eq "1")

# 报告收集
$script:ReportLines = New-Object System.Collections.ArrayList
$script:CheckResults = New-Object System.Collections.ArrayList

function Add-RL {
    param([string]$Line)
    [void]$script:ReportLines.Add($Line)
}

function Add-CR {
    param([string]$Name, [string]$Status, [string]$Detail = "")
    [void]$script:CheckResults.Add([PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $icon = switch ($Status) {
        "OK"    { "[OK]" }
        "WARN"  { "[WARN]" }
        "ERROR" { "[ERROR]" }
        "SKIP"  { "[SKIP]" }
        "NEEDS_RESTART" { "[NEEDS_RESTART]" }
        default { "[$Status]" }
    }
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "Gray" }
        "NEEDS_RESTART" { "Yellow" }
        default { "White" }
    }
    $line = "  $icon $Name"
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $color
    Write-Log "INFO" "$icon $Name - $Detail"
}

# ============================================================
# 主流程
# ============================================================

function Start-RepairDeps {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "        一键修复依赖工具 v$ScriptVersion" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""

    if ($IsTestSafe) {
        Write-Warning "测试安全模式：只检测，不执行任何安装操作。"
        Write-Host ""
    }

    Write-Info "正在检测系统依赖状态..."
    Write-Host ""

    # ============================================================
    # 1. 检测 winget
    # ============================================================
    Write-Info "--- winget ---"
    $wingetOk = Test-CommandAvailable -CommandName "winget"
    if ($wingetOk) {
        Add-CR "winget" "OK" "可用"
    }
    else {
        Add-CR "winget" "WARN" "未检测到（将无法自动安装 Node.js）"
    }

    # ============================================================
    # 2. 检测 Node.js
    # ============================================================
    Write-Info "--- Node.js ---"
    $nodeInfo = Test-NodeJsInstalled
    if ($nodeInfo.IsSupported) {
        Add-CR "Node.js" "OK" $nodeInfo.Version
    }
    elseif ($nodeInfo.Installed) {
        Add-CR "Node.js" "ERROR" "版本 $($nodeInfo.Version) - 需要 >= 18"
    }
    else {
        Add-CR "Node.js" "ERROR" "未安装"
    }

    # ============================================================
    # 3. 检测 npm
    # ============================================================
    Write-Info "--- npm ---"
    $npmInfo = Test-NpmInstalled
    if ($npmInfo.Installed) {
        Add-CR "npm" "OK" $npmInfo.Version
    }
    else {
        # 使用增强的状态信息
        $npmStatus = if ($npmInfo.Status -eq "failed_missing_npm") {
            "npm 不可用（Node.js 存在但 npm 缺失，安装不完整或 PATH 未刷新）"
        }
        elseif ($npmInfo.Status -eq "failed_missing_node") {
            "Node.js 未安装（npm 伴随 Node.js 安装）"
        }
        elseif ($npmInfo.Status -eq "failed_node_too_old") {
            "Node.js 版本过低"
        }
        elseif ($npmInfo.Status -eq "failed_npm_broken") {
            "npm 命令存在但无法执行（环境异常）"
        }
        else {
            $npmInfo.ErrorMessage
        }
        Add-CR "npm" "ERROR" $npmStatus
    }

    # ============================================================
    # 4. 检测 Claude Code
    # ============================================================
    Write-Info "--- Claude Code ---"
    $claudeVer = Test-ClaudeInstalled
    if ($claudeVer) {
        Add-CR "Claude Code" "OK" $claudeVer
    }
    else {
        Add-CR "Claude Code" "ERROR" "未安装"
    }

    # ============================================================
    # 5. 检测 PATH
    # ============================================================
    Write-Info "--- PATH ---"
    $npmGlobalPath = ""
    $npmPrefix = Invoke-CommandSafe -Command "npm" -Arguments @("prefix", "-g")
    if ($npmPrefix.Success) {
        $npmGlobalPath = $npmPrefix.Output.Trim()
        if ($env:Path -contains $npmGlobalPath -or $env:Path.ToLowerInvariant().Contains($npmGlobalPath.ToLowerInvariant())) {
            Add-CR "npm 全局 PATH" "OK" "已在 PATH 中"
        }
        else {
            Add-CR "npm 全局 PATH" "WARN" "$npmGlobalPath 不在当前 PATH 中"
        }
    }
    else {
        Add-CR "npm 全局 PATH" "SKIP" "无法获取（可能 npm 不可用）"
    }

    Write-Host ""

    # ============================================================
    # 修复逻辑
    # ============================================================

    $needsRestart = $false

    # --- 缺 Node.js ---
    if (-not $nodeInfo.Installed -or -not $nodeInfo.IsSupported) {
        Write-Host ""
        Write-Warning "============================================================"
        Write-Warning "  需要安装/升级 Node.js LTS（v18 或更高版本）"
        Write-Warning "============================================================"
        Write-Host ""

        if ($IsTestSafe) {
            Write-Info "测试安全模式：将跳过 Node.js 安装。"
            if ($wingetOk) {
                Write-Info "真实安装时将会执行: winget install OpenJS.NodeJS.LTS"
            }
            else {
                Write-Info "真实安装时将会提示手动下载: https://nodejs.org"
            }
        }
        elseif ($wingetOk) {
            $canInstall = if ($NonInteractive) { $AllowInstall } else { $true }
            if (-not $canInstall) {
                Write-Info "非交互模式下未授权安装。"
                Write-Info "请手动下载安装 Node.js LTS: https://nodejs.org"
                Write-Info "或使用 -AllowInstall 参数授权自动安装。"
            }
            else {
                if ($NonInteractive) {
                    Write-Info "非交互模式 -AllowInstall：将自动安装 Node.js LTS。"
                }
                else {
                    if (-not (Confirm-UserChoice -Message "是否使用 winget 安装 Node.js LTS？（将修改系统环境）")) {
                        Write-Info "已取消。请手动安装 Node.js 后重新运行。"
                        Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
                        Write-Host ""
                        Write-Info "安装完成后关闭此窗口，重新双击 [开始安装.cmd]。"
                        Generate-Report
                        return
                    }
                }

                Write-Info "正在使用 winget 安装 Node.js LTS（可能需要几分钟）..."
                $installResult = Invoke-CommandSafe -Command "winget" -Arguments @(
                    "install", "OpenJS.NodeJS.LTS",
                    "--accept-package-agreements",
                    "--accept-source-agreements",
                    "--silent"
                ) -TimeoutSec 900 -ProgressMessage "仍在安装 Node.js LTS，请勿关闭窗口。"

                if ($installResult.Success) {
                    Write-Success "Node.js LTS 安装完成！"
                    Write-Host ""
                    Write-Warning "============================================================"
                    Write-Warning "  Node.js 已安装完成。"
                    Write-Warning "  这是第一阶段完成，不是失败。"
                    Write-Warning "  请关闭当前窗口，再重新双击 [开始安装.cmd]。"
                    Write-Warning "  脚本会继续安装 Claude Code 并配置 DeepSeek。"
                    Write-Warning "============================================================"
                    $needsRestart = $true
                }
                else {
                    Write-Error-Msg "Node.js 自动安装失败。"
                    Write-Info "请手动下载安装: https://nodejs.org (选择 LTS 版本)"
                    Write-Info "安装完成后重新运行本脚本。"
                }
            }
        }
        else {
            Write-Info "未检测到 winget。请手动安装 Node.js："
            Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
            Write-Info "安装完成后关闭此窗口，重新双击 [开始安装.cmd]。"
        }
    }

    # --- Node 存在但 npm 缺失 ---
    if ($nodeInfo.Installed -and -not $npmInfo.Installed -and -not $needsRestart) {
        Write-Host ""
        Write-Warning "检测到 Node.js 存在，但 npm 不可用。"
        Write-Warning "这通常表示 Node.js 安装不完整，或当前终端 PATH 未刷新。"
        Write-Info "请先关闭此窗口重新打开后再试。"
        Write-Info "如果仍失败，请重新安装 Node.js LTS: https://nodejs.org"
    }

    # --- 缺 Claude Code ---
    if ($claudeVer) {
        Add-CR "Claude Code 状态" "OK" "已安装可用"
    }
    elseif (-not $needsRestart) {
        Write-Host ""
        Write-Warning "Claude Code 未安装。"
        Write-Info "请在修复 Node.js 后，重新运行 [开始安装.cmd]。"
        Write-Info "该脚本会自动检测并安装 Claude Code。"
    }

    # ============================================================
    # 生成报告
    # ============================================================

    Generate-Report

    if (-not $NonInteractive) {
        Write-Host ""
        Read-Host "按回车键退出..."
    }
}

function Generate-Report {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportsDir = Join-Path $ScriptDir "reports"
    if (-not (Test-Path $reportsDir)) {
        New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    }
    $reportPath = Join-Path $reportsDir "repair-deps-report-$timestamp.txt"

    Add-RL ("=" * 73)
    Add-RL "  一键修复依赖 报告"
    Add-RL "  生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-RL "  脚本版本: $ScriptVersion"
    Add-RL "  运行模式: $(if ($IsTestSafe) { '测试安全模式（未执行安装）' } else { '正常模式' })"
    Add-RL ("=" * 73)
    Add-RL ""
    Add-RL "【一眼结论】"
    Add-RL ""

    # 生成摘要
    $nodeStatus = if ($nodeInfo.IsSupported) { "正常" }
        elseif ($nodeInfo.Installed) { "版本过低" }
        else { "未安装" }
    $npmStatus = if ($npmInfo.Installed) { "正常" }
        elseif ($npmInfo.Status) { $npmInfo.Status }
        else { "不可用" }
    $claudeStatus = if ($claudeVer) { "已安装" } else { "未安装" }

    Add-RL "  Node.js:     $nodeStatus"
    Add-RL "  npm:         $npmStatus"
    Add-RL "  Claude Code: $claudeStatus"
    Add-RL "  winget:      $(if ($wingetOk) { '可用' } else { '未检测到' })"

    if ($needsRestart) {
        Add-RL ""
        Add-RL "  状态: NEEDS_RESTART - 需要关闭窗口重新打开 [开始安装.cmd]。"
    }
    elseif ($nodeInfo.IsSupported -and $npmInfo.Installed -and $claudeVer) {
        Add-RL ""
        Add-RL "  状态: 所有依赖已就绪。"
    }
    else {
        Add-RL ""
        Add-RL "  状态: 有依赖缺失，请按照下方建议修复。"
    }

    Add-RL ""
    Add-RL "【检测详情】"
    Add-RL ""
    foreach ($check in $script:CheckResults) {
        $icon = switch ($check.Status) {
            "OK"    { "[OK]" }
            "WARN"  { "[WARN]" }
            "ERROR" { "[ERROR]" }
            "SKIP"  { "[SKIP]" }
            "NEEDS_RESTART" { "[NEEDS_RESTART]" }
            default { "[$($check.Status)]" }
        }
        $line = "  $icon $($check.Name)"
        if ($check.Detail) { $line += " - $($check.Detail)" }
        Add-RL $line
    }

    Add-RL ""
    Add-RL "【建议动作】"
    Add-RL ""

    if ($needsRestart) {
        Add-RL "  1. 关闭当前窗口"
        Add-RL "  2. 重新双击 [开始安装.cmd]"
        Add-RL "  3. 脚本会继续安装 Claude Code 并配置 DeepSeek"
    }
    elseif (-not $nodeInfo.IsSupported) {
        Add-RL "  1. 安装 Node.js LTS: https://nodejs.org"
        Add-RL "  2. 或运行本工具自动安装（需要 winget）"
        Add-RL "  3. 安装完成后重新运行 [开始安装.cmd]"
    }
    elseif (-not $npmInfo.Installed) {
        Add-RL "  1. 关闭当前窗口重新打开（PATH 可能未刷新）"
        Add-RL "  2. 如仍不可用，重新安装 Node.js LTS"
    }
    elseif (-not $claudeVer) {
        Add-RL "  1. 运行 [开始安装.cmd] 自动安装 Claude Code"
    }
    else {
        Add-RL "  所有依赖已就绪，无需进一步操作。"
    }

    Add-RL ""
    Add-RL "【注意】"
    Add-RL "  本报告不包含 API Key 或敏感信息。"
    Add-RL "  如需完整诊断，请运行 [一键诊断.cmd]。"
    Add-RL ""
    Add-RL ("=" * 73)
    Add-RL "  报告结束"
    Add-RL ("=" * 73)

    # 写入报告（脱敏处理）
    $reportContent = $script:ReportLines -join "`r`n"
    $shareContent = Sanitize-ReportText -Text $reportContent
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($reportPath, $shareContent, $utf8NoBom)

    Write-Host ""
    Write-Success "修复依赖报告已生成: $reportPath"
    Write-Log "INFO" "repair-deps report: $reportPath"
}

# 执行
try {
    Start-RepairDeps
}
catch {
    $msg = "脚本执行过程中发生未预期的错误：$($_.Exception.Message)"
    if (Get-Command Write-FatalError -ErrorAction SilentlyContinue) {
        Write-FatalError -Message $msg
    }
    else {
        Write-Host "[ERROR] $msg" -ForegroundColor Red
    }
    exit 1
}
