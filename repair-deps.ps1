# ============================================================
# repair-deps.ps1 - 一键修复依赖 (v1.3.3)
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
    [switch]$AllowInstall,
    [switch]$NoFinalPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }
. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")
$ScriptDir = Initialize-CcdiScript -ScriptName "repair-deps"

$ScriptVersion = "1.3.3"
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
# Claude Code 修复函数
# ============================================================

function Invoke-ClaudeRepair {
    param(
        [bool]$NodeReady,
        [bool]$NpmReady,
        [bool]$ClaudeMissingOrBroken
    )

    # 如果 Claude 已安装，无需修复
    if (-not $ClaudeMissingOrBroken) {
        Add-CR "Claude Code 修复" "OK" "已安装可用"
        return
    }

    # TestSafe 模式：报告但不安装。mock decision 模式仍走完整决策树，
    # 便于 host functional tests 覆盖官方 Native 与 npm fallback 分支。
    $mockDecision = ($env:CCDI_TEST_MODE -eq "1" -and $env:CCDI_MOCK_INSTALL_DECISION -eq "1")
    if ($IsTestSafe -and -not $mockDecision) {
        Add-CR "Claude Code 修复" "SKIP" "测试安全模式：真实模式下会询问是否安装 Claude Code"
        return
    }

    # 确定是否可以安装
    $canInstall = $false
    if ($IsTestSafe -and -not $mockDecision) {
        $canInstall = $false
    }
    elseif ($NonInteractive) {
        $canInstall = $AllowInstall
    }
    elseif ($Yes -and $AllowInstall) {
        $canInstall = $true
    }
    else {
        # 交互模式：询问用户
        Write-Host ""
        Write-Warning "检测到 Claude Code 未安装。"
        Write-Info "是否现在安装 Claude Code？这将下载并安装 Anthropic 官方 Claude Code 工具。"
        $canInstall = Confirm-UserChoice -Message "是否现在安装 Claude Code？" -Default "No"
    }

    if (-not $canInstall) {
        if ($NonInteractive) {
            Add-CR "Claude Code 修复" "SKIP" "非交互模式未授权安装；如需安装请使用 -AllowInstall"
            Write-Info "非交互模式下未授权安装。"
            Write-Info "如需自动安装 Claude Code，请使用 -AllowInstall 参数。"
        }
        else {
            Add-CR "Claude Code 修复" "SKIP" "用户取消安装，可稍后运行00-点我开始安装.cmd"
        }
        return
    }

    Write-Info "正在安装 Claude Code..."
    $installResult = Install-ClaudeCodeAuto -TestSafe:$IsTestSafe -NonInteractive:$NonInteractive

    # 根据安装结果分类处理
    switch ($installResult.Status) {
        "installed" {
            Add-CR "Claude Code 修复" "OK" "安装完成: $($installResult.Version)"
        }
        "installed_postcheck_usable" {
            Add-CR "Claude Code 修复" "OK" "安装命令返回异常，但固定路径验证可用: $($installResult.Version)"
        }
        "skipped_existing" {
            Add-CR "Claude Code 修复" "OK" "已安装: $($installResult.Version)"
        }
        "node_install_failed" {
            $message = if ($installResult.UserMessage) { $installResult.UserMessage } else { "Node.js 自动安装失败，请检查网络或稍后重试" }
            Add-CR "Claude Code 修复" "ERROR" $message
        }
        "claude_install_failed" {
            Add-CR "Claude Code 修复" "ERROR" "Claude Code 安装未完成，请运行一键诊断.cmd"
        }
        "node_installed_needs_restart" {
            Add-CR "Claude Code 修复" "WARN" "安装结果未确认，将重新检测固定路径"
            return $installResult
        }
        "installed_needs_restart" {
            Add-CR "Claude Code 修复" "WARN" "Claude Code 安装结果未确认，将重新检测固定路径"
            return $installResult
        }
        "failed_missing_node_or_npm" {
            Add-CR "Claude Code 修复" "ERROR" "缺少 Node.js/npm，无法安装 Claude"
        }
        "failed_npmmirror_unreachable" {
            Add-CR "Claude Code 修复" "ERROR" "官方和镜像通道不可达，请检查网络后重试"
        }
        "failed_official_and_mirror" {
            Add-CR "Claude Code 修复" "ERROR" "官方安装和镜像安装均失败，请运行一键诊断.cmd"
        }
        "skipped_test_safe_missing" {
            Add-CR "Claude Code 修复" "SKIP" "测试安全模式未安装"
        }
        default {
            Add-CR "Claude Code 修复" "WARN" "状态: $($installResult.Status)"
        }
    }

    # 安装完成后，由调用方刷新 claudeVer 变量
    return $installResult
}

# ============================================================
# Claude PATH 修复（Native Install 固定路径可用时补 User PATH）
# ============================================================

function Repair-ClaudePathIfNeeded {
    <#
    .SYNOPSIS
        当 Claude Code 通过 Native Install 固定路径（%USERPROFILE%\.local\bin\claude.exe）
        可用、但该目录未加入 User PATH 时，补写 User PATH 并做 fresh shell 验证。
        Claude 不可用、或 Claude 来自 PATH/npm_global 等非 native 固定路径时，不处理。
        必须在 Claude 可用早退之前调用，否则会跳过 PATH 修复（ACC-048）。
    .PARAMETER ClaudeCheck
        Test-ClaudeCommandExisting 返回的检测对象（含 Usable/Path/Source）。
    .PARAMETER IsTestSafe
        测试安全模式：不写真实 User PATH，不做真实 fresh shell 验证。
    .PARAMETER NonInteractive
        非交互模式（当前仅用于语义记录，不改变修复逻辑）。
    .RETURNS
        包含 NativeBinPath, PathWriteFailed, PathWriteAttempted,
        PathWritten, FreshShellRan, FreshShellOk 的哈希表。
    #>
    param(
        $ClaudeCheck,
        [switch]$IsTestSafe,
        [switch]$NonInteractive
    )

    $outcome = @{
        NativeBinPath      = ""
        PathWriteFailed    = $false
        PathWriteAttempted = $false
        PathWritten        = $false
        FreshShellRan      = $false
        FreshShellOk       = $false
    }

    # Claude 不可用 -> 不处理
    if (-not $ClaudeCheck -or -not $ClaudeCheck.Usable) {
        return $outcome
    }

    $nativeBinPath = Get-NativeClaudeBinPath
    $outcome.NativeBinPath = $nativeBinPath

    # 仅当 Claude 通过 native_local_bin 固定路径找到时才需要补 User PATH。
    # Path 为空、或不在 native bin 目录下，通常说明 Claude 已在 PATH 中，不处理。
    $claudePath = $ClaudeCheck.Path
    $isNativeSourced = $false
    if ($ClaudeCheck.Source -eq "native_local_bin") {
        $isNativeSourced = $true
    }
    elseif ($claudePath) {
        try {
            $claudeDir = Split-Path -Parent $claudePath
            $normClaudeDir = ([System.IO.Path]::GetFullPath($claudeDir)).TrimEnd('\').ToLowerInvariant()
            $normNativeBin = ([System.IO.Path]::GetFullPath($nativeBinPath)).TrimEnd('\').ToLowerInvariant()
            if ($normClaudeDir -eq $normNativeBin) {
                $isNativeSourced = $true
            }
        }
        catch {
            # 路径规范化失败，保守不处理
        }
    }

    if (-not $isNativeSourced) {
        return $outcome
    }

    # 检查 User PATH 是否已包含 native bin
    $pathCheck = Test-UserPathContains -TargetPath $nativeBinPath
    $mockDecision = ($env:CCDI_TEST_MODE -eq "1" -and $env:CCDI_MOCK_INSTALL_DECISION -eq "1")

    if ($pathCheck.Contains -or ($IsTestSafe -and $mockDecision -and $env:CCDI_MOCK_USER_PATH_NATIVE -eq "present")) {
        Add-CR "Native Install PATH" "OK" "已在 User PATH 中"
    }
    else {
        Add-CR "Native Install PATH" "WARN" "Claude Code 已安装，但安装目录未加入 User PATH"
        $outcome.PathWriteAttempted = $true

        if ($IsTestSafe) {
            # 测试安全模式：不写真实 User PATH
            if ($mockDecision -and $env:CCDI_MOCK_PATH_WRITE -eq "fail") {
                # 模拟写入失败，覆盖 ERROR 分支
                $outcome.PathWriteFailed = $true
                Add-CR "Native Install PATH 写入" "ERROR" "PATH 自动修复失败（测试安全模式 mock）：实际运行时会尝试写入 User PATH"
            }
            else {
                Add-CR "Native Install PATH 写入" "SKIP" "测试安全模式未写入 PATH（实际运行时会写入）"
            }
        }
        else {
            $ensure = Ensure-UserPathEntry -PathToAdd $nativeBinPath
            if ($ensure.Success) {
                $outcome.PathWritten = $true
                if ($ensure.Changed) {
                    Add-CR "Native Install PATH 写入" "OK" "User PATH 已写入 Native Install 目录"
                }
                else {
                    Add-CR "Native Install PATH 写入" "OK" "Native Install 目录已在 User PATH 中"
                }
                Refresh-CurrentProcessPath
            }
            else {
                $outcome.PathWriteFailed = $true
                Add-CR "Native Install PATH 写入" "ERROR" "PATH 自动修复失败: $($ensure.Error)"
            }
        }
    }

    # fresh shell 验证：仅在非 TestSafe 且未发生 PATH 写入失败时运行
    if (-not $IsTestSafe -and -not $outcome.PathWriteFailed) {
        $fresh = Test-ClaudeCommandInFreshShell
        $outcome.FreshShellRan = $true
        if ($fresh.Success) {
            $outcome.FreshShellOk = $true
            Add-CR "Fresh PowerShell claude" "OK" "新 PowerShell 可直接运行 claude: $($fresh.Version)"
        }
        else {
            Add-CR "Fresh PowerShell claude" "WARN" "User PATH 已配置，但 fresh shell 验证未通过: $($fresh.Error)；如果新终端仍不可用，请运行一键诊断.cmd。"
        }
    }

    return $outcome
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
    Refresh-CurrentProcessPath

    # ============================================================
    # 1. 优先检测 Claude Code
    # ============================================================
    Write-Info "--- Claude Code ---"
    $claudeCheck = Test-ClaudeCommandExisting
    $claudeAvailable = [bool]$claudeCheck.Usable
    $claudeVer = if ($claudeAvailable) { $claudeCheck.Version } else { $null }
    $claudeDetailParts = New-Object System.Collections.ArrayList
    if ($claudeCheck.Version) { [void]$claudeDetailParts.Add("version=$($claudeCheck.Version)") }
    if ($claudeCheck.Path) { [void]$claudeDetailParts.Add("path=$($claudeCheck.Path)") }
    if ($claudeCheck.Source) { [void]$claudeDetailParts.Add("source=$($claudeCheck.Source)") }
    $claudeDetail = if ($claudeDetailParts.Count -gt 0) { $claudeDetailParts -join "; " } else { "已确认可用" }

    if ($claudeAvailable) {
        Add-CR "Claude Code" "OK" $claudeDetail
    }
    elseif ($claudeCheck.Exists) {
        Add-CR "Claude Code" "ERROR" "检测到但不可用: $($claudeCheck.Error)"
    }
    else {
        Add-CR "Claude Code" "ERROR" "未安装或不可用"
    }

    # ============================================================
    # 2. 检测 winget
    # ============================================================
    Write-Info "--- winget ---"
    $wingetOk = Test-CommandAvailable -CommandName "winget"
    if ($wingetOk) {
        Add-CR "winget" "OK" "可用"
    }
    elseif ($claudeAvailable) {
        Add-CR "winget" "INFO" "未检测到；Claude Code 已可用，当前无需修复。"
    }
    else {
        Add-CR "winget" "WARN" "未检测到；官方 Native Install 不需要预先安装 winget，备用安装方式可能受限。"
    }

    # ============================================================
    # 3. 检测 Node.js（Claude 可用时仅作为可选信息）
    # ============================================================
    Write-Info "--- Node.js ---"
    $nodeInfo = Test-NodeJsInstalled
    if ($nodeInfo.IsSupported) {
        $nodeDetail = if ($nodeInfo.Path) { "$($nodeInfo.Version); path=$($nodeInfo.Path); source=$($nodeInfo.Source)" } else { $nodeInfo.Version }
        Add-CR "Node.js" "OK" $nodeDetail
    }
    elseif ($claudeAvailable) {
        $nodeOptionalDetail = if ($nodeInfo.Installed) { "检测到版本 $($nodeInfo.Version)，但 Claude Code 已可用；Node.js 仅 npm fallback/开发场景需要，当前无需修复。" }
            else { "未检测到；Claude Code 已可用，Node.js 仅 npm fallback/开发场景需要，当前无需修复。" }
        Add-CR "Node.js" "INFO" $nodeOptionalDetail
    }
    elseif ($nodeInfo.Installed) {
        Add-CR "Node.js" "INFO" "检测到版本 $($nodeInfo.Version)；只有 npm fallback/开发场景需要 Node.js 18+。"
    }
    else {
        Add-CR "Node.js" "INFO" "未检测到；官方 Native Install 不需要预先安装 Node.js，只有 npm fallback/开发场景需要。"
    }

    # ============================================================
    # 4. 检测 npm（Claude 可用时仅作为可选信息）
    # ============================================================
    Write-Info "--- npm ---"
    $npmInfo = Test-NpmInstalled
    if ($npmInfo.Installed) {
        $npmDetail = if ($npmInfo.Path) { "$($npmInfo.Version); path=$($npmInfo.Path); source=$($npmInfo.Source)" } else { $npmInfo.Version }
        Add-CR "npm" "OK" $npmDetail
    }
    elseif ($claudeAvailable) {
        Add-CR "npm" "INFO" "未检测到；Claude Code 已可用，npm 仅 npm fallback/开发场景需要，当前无需修复。"
    }
    else {
        $npmStatus = if ($npmInfo.Status -eq "failed_missing_npm") {
            "npm fallback 需要 npm；如果你只使用已安装的 Claude Code，则无需处理。"
        }
        elseif ($npmInfo.Status -eq "failed_missing_node") {
            "Node.js 未检测到；官方 Native Install 不需要预先安装 Node.js，只有 npm fallback/开发场景需要。"
        }
        elseif ($npmInfo.Status -eq "failed_node_too_old") {
            "Node.js 版本低于 npm fallback 要求。"
        }
        elseif ($npmInfo.Status -eq "failed_npm_broken") {
            "npm 命令存在但无法执行；仅 npm fallback 需要处理。"
        }
        else {
            $npmInfo.ErrorMessage
        }
        Add-CR "npm" "INFO" $npmStatus
    }

    $needsRestart = $false
    $pathWriteFailed = $false
    $nativeBinPath = ""

    # ============================================================
    # Claude PATH 修复阶段：Claude 可用且为 Native Install 固定路径时，
    # 确保 User PATH 包含 native bin，避免新开终端 claude not found。
    # 必须在 Claude 可用早退之前完成，否则会跳过 PATH 修复（ACC-048）。
    # ============================================================
    $pathRepair = Repair-ClaudePathIfNeeded -ClaudeCheck $claudeCheck -IsTestSafe:$IsTestSafe -NonInteractive:$NonInteractive
    if ($pathRepair) {
        $pathWriteFailed = [bool]$pathRepair.PathWriteFailed
        if ($pathRepair.NativeBinPath) { $nativeBinPath = [string]$pathRepair.NativeBinPath }
    }

    if ($claudeAvailable) {
        Write-Host ""
        if (-not $pathWriteFailed) {
            Write-Success "Claude Code 已可用，无需修复。"
        }
        else {
            Write-Warning "Claude Code 当前固定路径可用，但 PATH 自动修复失败。"
        }
        Generate-Report
        if (-not $NonInteractive -and -not $IsTestSafe -and -not $NoFinalPause) {
            Write-Host ""
            Read-Host "按回车键退出..."
        }
        return
    }

    # ============================================================
    # 5. 检测 PATH（仅 npm fallback 辅助信息）
    # ============================================================
    Write-Info "--- PATH ---"
    if ($IsTestSafe) {
        Add-CR "npm 全局 PATH" "SKIP" "测试安全模式"
    }
    else {
        $npmGlobalPath = ""
        $npmResolved = Resolve-NpmCmdPath
        $npmPrefix = if ($npmResolved.Found) {
            Invoke-CommandSafe -Command $npmResolved.Path -Arguments @("prefix", "-g") -TimeoutSec 8
        } else {
            @{ Success = $false; Output = ""; Error = $npmResolved.Error }
        }
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
            Add-CR "npm 全局 PATH" "SKIP" "无法获取；仅 npm fallback 需要。"
        }
    }

    Write-Host ""

    # ============================================================
    # 修复逻辑
    # ============================================================

    # --- Node 存在但 npm 缺失：仅说明 npm fallback 场景 ---
    if ($nodeInfo.Installed -and -not $npmInfo.Installed -and -not $needsRestart) {
        Write-Host ""
        Write-Info "npm fallback 需要 npm；如果你只使用已安装的 Claude Code，则无需处理。"
    }

    # --- 缺 Claude Code ---
    if (-not $needsRestart) {
        $repairResult = Invoke-ClaudeRepair -NodeReady:($nodeInfo.IsSupported) -NpmReady:$npmInfo.Installed -ClaudeMissingOrBroken:(-not $claudeVer)
        Refresh-CurrentProcessPath
        $postRepairClaude = Test-ClaudeCommandExisting
        if ($repairResult -and $repairResult.Success) {
            $claudeAvailable = $true
            $claudeVer = $repairResult.Version
            foreach ($cr in $script:CheckResults) {
                if ($cr.Name -eq "Claude Code" -and $cr.Status -eq "ERROR") {
                    $cr.Status = "OK"
                    $cr.Detail = "已可用: version=$($repairResult.Version); method=$($repairResult.Method); status=$($repairResult.Status)"
                }
            }
            Add-CR "Claude Code 状态" "OK" "已可用: version=$($repairResult.Version); method=$($repairResult.Method); status=$($repairResult.Status)"
        }
        elseif ($postRepairClaude.Usable) {
            $claudeAvailable = $true
            $claudeVer = $postRepairClaude.Version
            foreach ($cr in $script:CheckResults) {
                if ($cr.Name -eq "Claude Code" -and $cr.Status -eq "ERROR") {
                    $cr.Status = "OK"
                    $cr.Detail = "已可用: version=$($postRepairClaude.Version); path=$($postRepairClaude.Path); source=$($postRepairClaude.Source)"
                }
            }
            Add-CR "Claude Code 状态" "OK" "已可用: version=$($postRepairClaude.Version); path=$($postRepairClaude.Path); source=$($postRepairClaude.Source)"
        }
    }

    # ============================================================
    # 生成报告
    # ============================================================

    Generate-Report

    if (-not $NonInteractive -and -not $IsTestSafe -and -not $NoFinalPause) {
        Write-Host ""
        Read-Host "按回车键退出..."
    }
}

function Generate-Report {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportRoot = $ScriptDir
    if ($env:CCDI_TEST_MODE -eq "1" -and -not [string]::IsNullOrWhiteSpace($env:CCDI_TEST_ARTIFACT_ROOT)) {
        $reportRoot = $env:CCDI_TEST_ARTIFACT_ROOT
    }
    $reportsDir = Join-Path $reportRoot "reports"
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
    $claudeStatus = if ($claudeAvailable) { "已可用" } elseif ($claudeVer) { "已安装" } else { "未安装" }

    Add-RL "  Node.js:     $nodeStatus"
    Add-RL "  npm:         $npmStatus"
    Add-RL "  Claude Code: $claudeStatus"
    Add-RL "  winget:      $(if ($wingetOk) { '可用' } else { '未检测到' })"

    if ($claudeAvailable) {
        Add-RL ""
        if (-not $pathWriteFailed) {
            Add-RL "  状态: Claude Code 已可用，无需修复。"
            if (-not $nodeInfo.IsSupported -or -not $npmInfo.Installed) {
                Add-RL "  说明: Node.js/npm 仅 npm fallback/开发场景需要，当前无需修复。"
            }
        }
        else {
            Add-RL "  状态: Claude Code 当前可用，但 PATH 自动修复失败。"
            if ($nativeBinPath) {
                Add-RL "  安装目录: $nativeBinPath"
            }
            Add-RL "  说明: Node.js/npm 缺失不构成主错误（仅 npm fallback/开发场景需要）。"
        }
    }
    elseif ($needsRestart) {
        Add-RL ""
        Add-RL "  状态: NEEDS_RESTART - 需要关闭窗口重新打开 [00-点我开始安装.cmd]。"
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

    if ($claudeAvailable) {
        if ($pathWriteFailed) {
            if ($nativeBinPath) {
                Add-RL "  1. 手动将 $nativeBinPath 加入用户 PATH"
            }
            else {
                Add-RL "  1. 手动将 Claude Code 安装目录（%USERPROFILE%\.local\bin）加入用户 PATH"
            }
            Add-RL "  2. 或运行 [一键诊断.cmd] 生成反馈"
        }
        else {
            Add-RL "  无需进一步操作。"
        }
    }
    elseif ($needsRestart) {
        Add-RL "  1. 重新打开 PowerShell"
        Add-RL "  2. 运行 [一键修复依赖.cmd]"
        Add-RL "  3. 如果仍失败，请运行 [一键诊断.cmd]"
    }
    elseif (-not $claudeVer) {
        Add-RL "  1. 重新运行本工具安装或修复 Claude Code。"
        Add-RL "  2. 如果官方安装不可用且需要 npm fallback，再按提示安装 Node.js/npm。"
    }
    else {
        Add-RL "  所有依赖已就绪，无需进一步操作。"
    }

    Add-RL ""
    Add-RL "【注意】"
    Add-RL "  本报告不包含 API Key 或敏感信息。"
    Add-RL "  如需完整诊断，请运行 [一键诊断.cmd]。"
    Add-RL ""
    Add-RL "【售后提示】"
    Add-RL "  如需售后，请运行「一键诊断.cmd」。"
    Add-RL "  只发送生成的 report.txt。"
    Add-RL "  不要发送 backup/、logs/、reports/full-report-*、settings.json。"
    Add-RL "  不要发送完整 API Key。"
    Add-RL "  如果截图，请先确认截图里没有完整 API Key。"
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
