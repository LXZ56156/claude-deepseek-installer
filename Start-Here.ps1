# ============================================================
# Start-Here.ps1 - Claude Code + DeepSeek 一键安装总控入口 (v1.3.3)
#
# 用法:
#   双击 "00-点我开始安装.cmd" 或:
#   powershell -ExecutionPolicy Bypass -File .\Start-Here.ps1
#
# 功能:
#   一键检测、安装、配置、测试、生成报告
#   替代 install.ps1 菜单作为小白用户主入口
#
# 合规声明:
#   本脚本仅做本地安装和配置。
#   不提供 Claude 账号、API Key、中转服务。
#   用户需自备 DeepSeek API Key。
# ============================================================

param(
    [switch]$NonInteractive,
    [switch]$SkipApiTest,
    [switch]$SkipDisclaimer,
    [switch]$StepPause,
    [switch]$TestSafe,
    [switch]$DryRun,
    [switch]$FixDeps,
    [switch]$DeepWslCheck
)

# ============================================================
# 初始化
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }
. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")
$ScriptDir = Initialize-CcdiScript -ScriptName "start-here"

$ScriptVersion = "1.3.3"

# 状态变量
$script:ClaudeInstalled = $false
$script:ClaudeInstallMethod = ""
$script:ClaudeInstallStatus = ""
$script:ConfigWritten = $false
$script:ApiTestPassed = $false
$script:ApiTestSkipped = $false
$script:ApiTestFailed = $false
$script:ApiTestFailReason = ""
$script:TestProjectPath = $null
$script:ReportPath = $null
$script:EnvSnapshot = $null
$script:UnsupportedSystem = $false
$script:TestSafeMode = $TestSafe -or $DryRun -or ($env:CCDI_TEST_MODE -eq "1")
$script:EffectiveSkipApiTest = $SkipApiTest -or $script:TestSafeMode

# ============================================================
# 辅助函数
# ============================================================

function Write-Step {
    param([string]$Title)
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
}

function Write-ResultLine {
    param(
        [string]$Label,
        [string]$Status,
        [string]$Detail = ""
    )
    $icon = switch ($Status) {
        "OK"   { "[OK]" }
        "WARN" { "[WARN]" }
        "ERROR" { "[ERROR]" }
        "SKIP" { "[SKIP]" }
        "INFO" { "[INFO]" }
        default { "[$Status]" }
    }
    $color = switch ($Status) {
        "OK"   { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SKIP" { "Gray" }
        "INFO" { "Cyan" }
        default { "White" }
    }
    $line = "  $icon $Label"
    if ($Detail) {
        $line += " - $Detail"
    }
    Write-Host $line -ForegroundColor $color
    Write-Log "INFO" "[$Status] $Label - $Detail"
}

function Write-CheckProgress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Name
    )
    Write-Info "[$Current/$Total] 正在检测 $Name..."
}

function Pause-ForUser {
    param([switch]$Force)

    if (-not $NonInteractive -and ($Force -or $StepPause)) {
        Write-Host ""
        Read-Host "按回车键继续..."
    }
}

function Pause-ForNextStep {
    <#
    .SYNOPSIS
        显示多行说明后暂停，仅在交互模式下生效。
        不影响 NonInteractive，不破坏 StepPause 参数。
    .PARAMETER Messages
        要显示的多行说明文本。
    .PARAMETER Force
        强制暂停（忽略 StepPause 开关）。
    #>
    param(
        [string[]]$Messages,
        [switch]$Force
    )

    if ($NonInteractive) {
        Write-Log "DEBUG" "Pause-ForNextStep: 非交互模式，跳过暂停"
        return
    }

    if (-not ($Force -or $StepPause)) {
        Write-Log "DEBUG" "Pause-ForNextStep: StepPause 未启用且非强制，跳过暂停"
        return
    }

    Write-Host ""
    foreach ($msg in $Messages) {
        Write-Info $msg
    }
    Write-Host ""
    Read-Host "按回车键继续..."
}

function Convert-ClaudeInstallMethodForReport {
    <#
    .SYNOPSIS
        将内部安装方式值映射为用户可读的中文描述。
        避免在 report 中直接暴露 ExternalScript/Application/Cmdlet 等 PowerShell 内部词。
    .PARAMETER Method
        $script:ClaudeInstallMethod 的值。
    .PARAMETER Source
        Test-ClaudeCommandExisting 返回的 Source 字段。
    .PARAMETER Path
        Test-ClaudeCommandExisting 返回的 Path 字段。
    #>
    param(
        [string]$Method,
        [string]$Source = "",
        [string]$Path = ""
    )

    switch -Regex ($Method) {
        '^official_native$' { return 'Claude 官方 Native Install' }
        '^existing_native$' { return '已存在：Claude 官方 Native Install' }
        '^winget$' { return 'winget 安装' }
        '^npm_npmmirror$' { return '备用下载方式（npm 镜像）' }
        '^existing$' { return '已存在，跳过安装' }
        '^native_local_bin$' { return 'Claude 官方 Native Install' }
        '^npm_global$' { return 'npm 全局安装' }
        '^final_fallback$' { return '最终验证检测到 Claude Code' }
        '^skipped_existing$' { return '已存在，跳过安装' }
        '^skipped_test_safe' { return '测试安全模式（未执行真实安装）' }
        default {
            # 路径判断优先于 Source。因为 PowerShell CommandType/Source 可能只是 ExternalScript，
            # 但 Path 才能准确说明 claude 来自 npm 目录还是 Native Install 目录。
            if ($Path -match '\\AppData\\Roaming\\npm\\claude\.cmd$') { return 'npm 全局安装' }
            if ($Path -match '\\\.local\\bin\\claude\.exe$') { return 'Claude 官方 Native Install' }

            # 再处理 PowerShell CommandType / Source 内部词，不暴露给用户
            if ($Source -eq 'ExternalScript') { return '系统 PATH 中检测到 Claude Code' }
            if ($Source -eq 'Application') { return '本机应用路径检测到 Claude Code' }
            if ($Source -eq 'Function') { return '系统函数或别名中检测到 Claude Code' }
            if ($Source -eq 'Cmdlet') { return 'PowerShell 命令中检测到 Claude Code' }

            # Method 本身也可能是 PowerShell 内部词（兜底）
            if ($Method -in @('ExternalScript', 'Application', 'Function', 'Cmdlet')) {
                return '系统 PATH 中检测到 Claude Code'
            }

            if ($Method) { return $Method }
            return '未知'
        }
    }
}

# ============================================================
# UX 文案 helper 函数
# ============================================================

function Write-UserFriendlyInstallMessage {
    <#
    .SYNOPSIS
        把安装阶段用户可见文案统一成普通用户语言。
        技术细节通过 Detail 写日志，不直接显示。
    #>
    param(
        [ValidateSet(
            "AutoSelect",
            "SwitchFallback",
            "ConfirmInstall",
            "NeedRestart",
            "PathVerify",
            "InstallSuccess",
            "InstallPartial",
            "InstallFailed"
        )]
        [string]$Type,
        [string]$Detail = ""
    )

    switch ($Type) {
        "AutoSelect" {
            Write-Info "正在自动选择可用的安装方式。"
        }
        "SwitchFallback" {
            Write-Info "当前方式连接较慢，已自动切换备用方式。"
        }
        "ConfirmInstall" {
            Write-Info "正在确认安装结果。"
        }
        "NeedRestart" {
            Write-Warning "当前窗口还没有识别到最新命令。"
            Write-Info "请关闭此窗口后重新打开安装助手继续。"
        }
        "PathVerify" {
            Write-Info "正在确认新打开的 PowerShell 是否能直接使用 Claude Code。"
        }
        "InstallSuccess" {
            Write-Success "Claude Code 已安装并确认可用。"
        }
        "InstallPartial" {
            Write-Warning "Claude Code 已安装，但还需要重新打开 PowerShell 验证。"
        }
        "InstallFailed" {
            Write-Warning "Claude Code 暂未确认安装成功。"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-Log "INFO" "UserFriendlyInstallMessage[$Type]: $Detail"
    }
}

function Write-LongStepHint {
    <#
    .SYNOPSIS
        所有可能超过 30 秒的步骤，统一提示，避免用户以为卡死。
    #>
    param(
        [string]$Action = "这一步"
    )

    Write-Info "$Action 可能需要几分钟。"
    Write-Info "如果短时间没有新输出，这是正常的，请不要关闭窗口。"
}

function Write-NextStepCard {
    <#
    .SYNOPSIS
        失败/部分成功场景统一成 "自修复优先" 的卡片。
        先修复 → 再诊断 → 最后才提示 report.txt。
    .PARAMETER Status
        当前状态描述。
    .PARAMETER Tried
        已自动尝试的操作列表。
    .PARAMETER NextSteps
        建议操作列表（会按编号显示）。
    .PARAMETER IncludeSupportFallback
        是否附加 "如需人工协助，只发送 report.txt"。
    #>
    param(
        [string]$Status,
        [string[]]$Tried = @(),
        [string[]]$NextSteps = @(),
        [switch]$IncludeSupportFallback
    )

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  下一步建议" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow

    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        Write-Info "当前状态：$Status"
    }

    if ($Tried.Count -gt 0) {
        Write-Host ""
        Write-Info "已自动尝试："
        foreach ($item in $Tried) {
            Write-Host "  - $item" -ForegroundColor DarkGray
        }
    }

    if ($NextSteps.Count -gt 0) {
        Write-Host ""
        Write-Info "建议操作："
        for ($i = 0; $i -lt $NextSteps.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $NextSteps[$i]) -ForegroundColor White
        }
    }

    if ($IncludeSupportFallback) {
        Write-Host ""
        Write-Info "如果以上方法仍无法解决，再生成诊断报告。"
        Write-Info "如需人工协助，优先发送 support-feedback.txt（没有时发 report.txt）。"
        Write-Info "不要发送 settings.json、完整 API Key、backup 或 logs。"
    }

    Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
}

function Write-ApiKeySkipGuidance {
    <#
    .SYNOPSIS
        输出统一的 "已跳过 API Key 配置" 友好提示。
        用于菜单 [3] 暂时跳过 和 输入取消 两条路径。
    #>
    Write-Host ""
    Write-Info "已跳过 API Key 配置。"
    Write-Info "可稍后运行：00-点我开始安装.cmd → 高级选项 → 仅配置 DeepSeek API。"
    Write-Info "也可以运行 configure-deepseek.ps1 单独配置。"
}

# ============================================================
# 免责声明
# ============================================================

function Show-Disclaimer {
    if ($NonInteractive) {
        Write-Log "INFO" "非交互模式：跳过免责声明"
        return $true
    }

    Clear-Host
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "   Claude Code + DeepSeek API 本地配置助手 v$ScriptVersion            " -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  本工具将帮助你完成：" -ForegroundColor White
    Write-Host "    1. 检查系统环境" -ForegroundColor White
    Write-Host "    2. 安装 Claude Code CLI" -ForegroundColor White
    Write-Host "    3. 配置你自己的 DeepSeek API Key" -ForegroundColor White
    Write-Host "    4. 测试 API 是否可用" -ForegroundColor White
    Write-Host "    5. 生成安装完成报告" -ForegroundColor White
    Write-Host "    6. 创建测试项目" -ForegroundColor White
    Write-Host ""
    Write-Host "  【重要声明】" -ForegroundColor Yellow
    Write-Host "     本工具不提供 Claude 账号" -ForegroundColor Red
    Write-Host "     本工具不提供 DeepSeek API Key" -ForegroundColor Red
    Write-Host "     本工具不做 API 中转" -ForegroundColor Red
    Write-Host "     API Key 只写入本机 Claude Code 配置" -ForegroundColor Green
    Write-Host "     如进行 API 测试，Key 只发送到 DeepSeek 官方接口" -ForegroundColor Green
    Write-Host "     API 调用费用由用户和 DeepSeek 官方结算" -ForegroundColor Green
    Write-Host ""

    if (-not $SkipDisclaimer) {
        $agree = Read-Host "请输入 Y 确认已阅读并同意 (输入 N 退出)"
        if ($agree -ne "Y" -and $agree -ne "y" -and $agree -ne "是") {
            Write-Host "已取消。感谢您的关注！" -ForegroundColor Cyan
            Write-Log "INFO" "用户拒绝免责声明"
            return $false
        }
    }

    Write-Log "INFO" "用户已同意免责声明"
    return $true
}

# ============================================================
# Step 1: 基础环境检查
# ============================================================

function Step-CheckEnvironment {
    Write-Step "Step 1/7：基础环境检查"

    Write-Info "正在检查您的系统环境（只检测，不修改）..."
    Write-Host ""

    # ============================================================
    # 最低要求检测（硬性判断）
    # ============================================================
    Write-CheckProgress -Current 1 -Total 7 -Name "最低系统要求"
    Write-Host ""

    $minReq = Test-MinimumRequirements

    # Windows 版本
    $winInfo = $minReq.Details["Windows"]
    $minReqFailureStatus = if ($script:TestSafeMode) { "WARN" } else { "ERROR" }
    if ($winInfo.IsSupported) {
        $osLabel = if ($winInfo.IsWindows11) { "Windows 11" } else { "Windows 10" }
        Write-ResultLine "Windows 版本" "OK" "$osLabel (Build $($winInfo.Build))"
    }
    else {
        Write-ResultLine "Windows 版本" $minReqFailureStatus "不支持的系统: $($winInfo.Version) (Build $($winInfo.Build))"
        Write-Warning "需要 Windows 10 1809+ (Build >= 17763) 或 Windows 11"
    }

    # 系统架构
    $archInfo = $minReq.Details["Architecture"]
    if ($archInfo.IsSupported) {
        Write-ResultLine "系统架构" "OK" $archInfo.Architecture
    }
    else {
        Write-ResultLine "系统架构" $minReqFailureStatus "不支持: $($archInfo.Architecture)（需要 x64 或 ARM64）"
    }

    # 物理内存
    $memInfo = $minReq.Details["Memory"]
    if ($memInfo.IsSufficient) {
        Write-ResultLine "物理内存" "OK" "$($memInfo.TotalGB) GB"
    }
    else {
        Write-ResultLine "物理内存" $minReqFailureStatus "$($memInfo.TotalGB) GB（需要 4GB 以上）"
        Write-Warning "请关闭其他程序释放内存，或升级硬件。"
    }

    # PowerShell 版本
    $psInfo = $minReq.Details["PowerShell"]
    if ($psInfo.IsSupported) {
        Write-ResultLine "PowerShell 版本" "OK" "$($psInfo.Version)"
    }
    else {
        Write-ResultLine "PowerShell 版本" $minReqFailureStatus "版本过低"
    }

    # 管理员权限
    if (Test-IsAdministrator) {
        Write-ResultLine "管理员权限" "WARN" "以管理员运行（非必须）"
    }
    else {
        Write-ResultLine "管理员权限" "OK" "普通用户权限（推荐）"
    }

    Write-Host ""

    # 如果硬性要求不满足，真实安装模式停止；TestSafe 继续做沙盒验证。
    if (-not $minReq.IsSupported) {
        if ($script:TestSafeMode) {
            Write-Warning "测试安全模式：最低系统要求检测未通过，但不会执行真实安装，继续沙盒配置验证。"
        }
        else {
        Write-Host ""
        Write-Error-Msg "当前电脑不满足最低系统要求，无法继续安装。"
        Write-Host ""
        foreach ($err in $minReq.Errors) {
            Write-Warning $err
        }
        Write-Host ""
        Write-Info "建议:"
        Write-Info "  - 升级到 Windows 10 1809 或更高版本"
        Write-Info "  - 确保系统为 64 位（x64 或 ARM64）"
        Write-Info "  - 确保至少 4GB 内存"
        Write-Info "  - 升级 PowerShell 到 5.1 或更高版本"
        Write-Info "  - 运行「一键诊断.cmd」获取详细诊断报告"
        $script:UnsupportedSystem = $true
        return @{
            DeepSeekReachable = $false
            ClaudeExists      = $false
            WslInstalled      = $false
            MinReqFailed      = $true
        }
        }
    }

    Write-Host ""
    Write-CheckProgress -Current 2 -Total 7 -Name "DeepSeek 网络"
    Write-Host ""

    # 网络检测
    if ($script:TestSafeMode) {
        Write-ResultLine "DeepSeek 网络" "SKIP" "测试安全模式未请求 DeepSeek"
        $netDeepSeek = @{
            Reachable = $false
            LatencyMs = 0
            Error     = "skipped_test_safe"
        }
    }
    else {
        Write-Info "检测网络连通性..."
        $netDeepSeek = Test-NetworkConnectivity -Url "https://api.deepseek.com"
        if ($netDeepSeek.Reachable) {
            Write-ResultLine "DeepSeek 网络" "OK" "可访问 ($($netDeepSeek.LatencyMs)ms)"
        }
        else {
            Write-ResultLine "DeepSeek 网络" "ERROR" "无法访问: $($netDeepSeek.Error)"
        }
    }

    # Claude Code 检测
    Write-CheckProgress -Current 3 -Total 7 -Name "Claude Code"
    $claudeVersion = Test-ClaudeInstalled
    if ($claudeVersion) {
        Write-ResultLine "Claude Code" "OK" "已安装: $claudeVersion"
    }
    else {
        Write-ResultLine "Claude Code" "WARN" "未安装（将在下一步安装）"
    }

    # Native Install 预判：在检测 Node.js/npm 前判断是否已有 Native Install 可用
    # 避免将 Node/npm 缺失误报为核心问题
    $nativeBinDir = Get-NativeClaudeBinPath
    $nativeExePath = Get-NativeClaudeExePath
    $nativePathCheck = Test-UserPathContains -TargetPath $nativeBinDir
    $nativePreCheckOk = (Test-Path $nativeExePath) -and $nativePathCheck.Contains

    # Node.js 检测
    Write-CheckProgress -Current 4 -Total 7 -Name "Node.js"
    $nodeInfo = Test-NodeJsInstalled
    if ($nodeInfo.Installed) {
        if ($nodeInfo.IsSupported) {
            Write-ResultLine "Node.js" "OK" $nodeInfo.Version
        }
        else {
            Write-ResultLine "Node.js" "WARN" "$($nodeInfo.Version)（建议 >= 18）"
        }
    }
    else {
        if ($nativePreCheckOk) {
            Write-ResultLine "Node.js" "INFO" "未安装（官方安装方式已就绪，不影响基础使用）"
        }
        else {
            Write-ResultLine "Node.js" "WARN" "未安装（如官方安装方式不可用将自动安装）"
        }
    }

    # npm 检测
    Write-CheckProgress -Current 5 -Total 7 -Name "npm"
    $npmInfo = Test-NpmInstalled
    if ($npmInfo.Installed) {
        Write-ResultLine "npm" "OK" $npmInfo.Version
    }
    else {
        if ($nativePreCheckOk) {
            Write-ResultLine "npm" "INFO" "未安装（官方安装方式已就绪，不影响基础使用）"
        }
        else {
            Write-ResultLine "npm" "SKIP" "未安装"
        }
    }

    # winget 检测
    Write-CheckProgress -Current 6 -Total 7 -Name "系统安装工具"
    $wingetOk = Test-CommandAvailable -CommandName "winget"
    if ($wingetOk) {
        Write-ResultLine "系统安装工具" "OK" "可用"
    }
    else {
        Write-ResultLine "系统安装工具" "WARN" "未检测到（不影响主流程）"
    }

    # VS Code（可选增强项，只在日志记录，不在终端逐项刷屏）
    $codeVersion = Test-CodeInstalled
    Write-Log "INFO" "VS Code: $(if ($codeVersion) { ($codeVersion -split "`n")[0] } else { '未检测到（可选增强项）' })"

    # Git（可选增强项，只在日志记录，不在终端逐项刷屏）
    $gitVersion = Test-GitInstalled
    Write-Log "INFO" "Git: $(if ($gitVersion) { $gitVersion } else { '未安装（可选）' })"

    # WSL（可选增强项，只在日志记录，不在终端逐项刷屏）
    if ($DeepWslCheck) {
        # 深度 WSL 检测（仅 -DeepWslCheck 或一键诊断时执行）
        $wslInfo = Test-WslInstalled
        if ($wslInfo.Installed) {
            $ubuntuInfo = Test-UbuntuInWsl -WslInfo $wslInfo
            if ($ubuntuInfo.Exists) {
                Write-Log "INFO" "WSL Ubuntu: 已安装"
            }
            else {
                Write-Log "INFO" "WSL: 已安装（无 Ubuntu 发行版）"
            }
        }
        else {
            Write-Log "INFO" "WSL: 未启用或不可用（高级选项，不影响 Windows 原生安装）"
        }
    }
    else {
        # 默认一键安装：跳过 WSL 深度检测，避免卡顿和刷屏
        $wslInfo = @{
            Installed = $false
            Version   = ""
            Status    = "skipped_default"
            Message   = "默认一键安装跳过 WSL 深度检测（可选）"
        }
        Write-Log "INFO" "WSL: 默认跳过深度检测（可选，不影响安装）"
    }

    # 配置文件
    Write-CheckProgress -Current 7 -Total 7 -Name "Claude 配置"
    $configInfo = Test-ClaudeConfigExists
    if ($configInfo.Exists) {
        if ($configInfo.IsValid) {
            Write-ResultLine "Claude 配置" "OK" "已存在（将备份后合并）"
        }
        else {
            Write-ResultLine "Claude 配置" "WARN" "存在但格式无效（将备份后重建）"
        }
    }
    else {
        Write-ResultLine "Claude 配置" "SKIP" "尚未创建"
    }

    Write-Host ""
    Write-Info "环境检查完成。"

    # 可选增强项汇总：将不影响核心安装的项集中展示，避免小白误以为安装失败
    $optionalItems = [System.Collections.ArrayList]::new()
    if (-not $codeVersion) { [void]$optionalItems.Add("VS Code：未检测到（可选增强项）") }
    if (-not $gitVersion) { [void]$optionalItems.Add("Git：未安装（可选，不影响基础使用）") }
    if (-not $wslInfo.Installed) { [void]$optionalItems.Add("WSL：未启用（高级选项，仅 WSL 用户需要）") }
    if (-not $nodeInfo.Installed -and $nativePreCheckOk) { [void]$optionalItems.Add("Node.js/npm：未安装（Native Install 已就绪，不影响基础使用）") }
    if ($optionalItems.Count -gt 0) {
        Write-Host ""
        Write-Info "可选增强项（缺失不影响安装和使用）："
        foreach ($item in $optionalItems) {
            Write-Host "    - $item" -ForegroundColor DarkGray
        }
    }

    # 缓存环境快照，供 Step-GenerateReport 复用，避免重复检测
    $script:EnvSnapshot = @{
        DeepSeekNetwork = $netDeepSeek
        ClaudeVersion   = $claudeVersion
        NodeInfo        = $nodeInfo
        NpmInfo         = $npmInfo
        WslInfo         = $wslInfo
        CodeVersion     = $codeVersion
        GitVersion      = $gitVersion
        ConfigInfo      = $configInfo
        MinReq          = $minReq
    }

    # 返回网络检测结果供后续使用
    return @{
        DeepSeekReachable = $netDeepSeek.Reachable
        ClaudeExists      = ($null -ne $claudeVersion)
        WslInstalled      = $wslInfo.Installed
        MinReqFailed      = $false
    }
}

# ============================================================
# Step 2: 安装 Claude Code（Install-ClaudeCodeAuto）
#
# 策略（由 lib/claude-install.ps1 实现）:
#   1. claude 已存在 → 跳过（不覆盖、不重装、不自动更新）
#   2. 官方 Native Install 可用 → 优先使用
#   3. 官方不可用或安装失败 → 尝试 winget install Anthropic.ClaudeCode
#   4. winget 不可用或失败 → 自动切换 npmmirror npm 镜像
#   5. npm 镜像需要 Node.js >= 18 + npm（通过 npm.cmd 执行）
# ============================================================

function Step-InstallClaudeCode {
    Write-Step "Step 2/7：安装 Claude Code"

    # 安装策略说明（用户友好版）
    Write-UserFriendlyInstallMessage -Type "AutoSelect" -Detail "official_native -> winget -> npm_npmmirror"
    Write-LongStepHint -Action "安装 Claude Code"
    Write-Log "INFO" "详细策略: 官方 Native Install 优先，失败后尝试 winget，最后 npm 镜像（npmmirror.com/@anthropic-ai/claude-code）兜底"
    Write-Host ""

    # 调用统一安装函数
    $installResult = Install-ClaudeCodeAuto -TestSafe:$script:TestSafeMode -NonInteractive:$NonInteractive

    # 映射结果到 script 级别变量
    $script:ClaudeInstalled = $installResult.Success
    $script:ClaudeInstallMethod = $installResult.Method
    $script:ClaudeInstallStatus = $installResult.Status

    Write-Log "INFO" "Claude Code 安装结果: Success=$($installResult.Success), Method=$($installResult.Method), Status=$($installResult.Status)"

    # 处理特殊状态
    if ($installResult.Status -eq "node_installed_needs_restart" -or
        $installResult.Status -eq "installed_needs_restart") {
        Write-UserFriendlyInstallMessage -Type "NeedRestart"
        Write-NextStepCard `
            -Status "必要运行环境已安装，当前窗口还没有识别到最新命令。" `
            -Tried @(
                "已重新检测安装结果",
                "已刷新当前窗口的命令路径"
            ) `
            -NextSteps @(
                "关闭当前窗口",
                "重新双击「00-点我开始安装.cmd」继续安装",
                "如果仍提示相同问题，再运行「一键修复依赖.cmd」"
            )
        return $false
    }

    if ($script:TestSafeMode -and $installResult.Status -match "^skipped_test_safe_") {
        Write-Warning "测试安全模式：未执行 Claude Code 安装，继续验证沙盒配置写入。"
        Write-ResultLine "Claude Code 安装" "SKIP" "测试安全模式，未执行真实安装"
        return $true
    }

    if (-not $installResult.Success) {
        # 兜底检测：即使 Install-ClaudeCodeAuto 返回失败，
        # 也要以 claude --version 的实际可用性为准（防止旧快照误判）。
        Refresh-CurrentProcessPath
        $finalCheck = Test-ClaudeCommandExisting

        if ($finalCheck.Exists -and $finalCheck.Usable) {
            # v1.3.3 P1-2: 兜底检测必须包含 fresh shell 验证
            $freshFinal = Test-ClaudeCommandInFreshShell

            # 优先保留 installResult.Method（如 npm_npmmirror），不被 Source=ExternalScript 覆盖
            $knownInstallMethods = @("official_native", "winget", "npm_npmmirror", "existing", "existing_native")
            $resolvedMethod = if ($installResult.Method -in $knownInstallMethods) {
                $installResult.Method
            }
            elseif ($script:ClaudeInstallMethod -in $knownInstallMethods) {
                $script:ClaudeInstallMethod
            }
            else {
                "final_fallback"
            }
            Write-Log "INFO" "final fallback source=$($finalCheck.Source), path=$($finalCheck.Path), preservedMethod=$resolvedMethod"

            if ($freshFinal.Success) {
                $script:ClaudeInstalled = $true
                $script:ClaudeInstallMethod = $resolvedMethod
                $script:ClaudeInstallStatus = "installed"
                Write-Success "Claude Code 已安装并确认可用。"
                Write-Log "INFO" "final verification succeeded: version=$($finalCheck.Version), fresh shell OK"
                Write-Log "INFO" "兜底检测通过: fresh shell 可用, 覆盖安装结果 Success=true"
            }
            else {
                $script:ClaudeInstalled = $true
                $script:ClaudeInstallMethod = $resolvedMethod
                $script:ClaudeInstallStatus = "installed_needs_restart_or_path_fix"
                Write-Warning "当前窗口可以识别 Claude Code，但新打开的 PowerShell 还没有确认可用。"
                Write-Info "本工具会继续配置 DeepSeek API Key。"
                Write-NextStepCard `
                    -Status "当前窗口可以识别 Claude Code，但新打开的 PowerShell 还没有确认可用。" `
                    -Tried @(
                        "已确认 Claude Code 文件可以运行",
                        "已尝试在新 PowerShell 中验证命令"
                    ) `
                    -NextSteps @(
                        "安装结束后先选择完成页 [1] 启动测试",
                        "如果 [1] 启动失败，运行「一键修复依赖.cmd」"
                    )
                Write-Log "WARN" "兜底检测部分通过: current process usable, fresh shell failed: $($freshFinal.Error)"
            }

            $configStatus = Get-DeepSeekConfigStatus
            if (-not $configStatus.IsConfigured) {
                Write-Warning "Claude Code 已安装，但 DeepSeek API Key 尚未配置或配置不完整。"
                if ($configStatus.ErrorMessage) {
                    Write-Info "原因: $($configStatus.ErrorMessage)"
                }
                Write-Info "下一步：继续配置 DeepSeek API Key。"
            }
            return $true
        }

        Write-UserFriendlyInstallMessage -Type "InstallFailed"
        Write-NextStepCard `
            -Status "Claude Code 暂未确认安装成功。" `
            -Tried @(
                "已自动切换可用安装方式",
                "已刷新命令路径并重新检测安装结果"
            ) `
            -NextSteps @(
                "先运行「一键修复依赖.cmd」自动修复常见问题",
                "修复后重新运行「00-点我开始安装.cmd」",
                "如果仍失败，再运行「一键诊断.cmd」生成 report.txt"
            ) `
            -IncludeSupportFallback
        return $false
    }

    return $true
}


# ============================================================
# Step 3: DeepSeek API Key 获取和输入
# ============================================================

function Step-GetApiKey {
    Write-Step "Step 3/7：获取 DeepSeek API Key"

    Write-Info "Claude Code 需要 DeepSeek API Key 才能使用。"
    Write-Host ""

    if ($NonInteractive) {
        $envKey = Get-ApiKeyFromEnvironment
        if (-not $envKey.Found) {
            Write-Error-Msg "$($envKey.Error)。非交互模式需要设置环境变量。"
            return $null
        }
        Write-Info "已从环境变量 $($envKey.Source) 读取 API Key: $(Mask-ApiKey -Key $envKey.Key)"
        return $envKey.Key
    }

    # 自动打开 DeepSeek API Key 页面（首次）
    Write-Info "正在为您打开 DeepSeek API Key 页面..."
    try {
        Start-Process "https://platform.deepseek.com/api_keys"
        Write-Info "如果浏览器未自动打开，请手动访问: https://platform.deepseek.com/api_keys"
    }
    catch {
        Write-Info "请手动在浏览器中打开: https://platform.deepseek.com/api_keys"
    }

    # 预备菜单循环
    :menu while ($true) {
        Write-Host ""
        Write-Host "==============================================================" -ForegroundColor Cyan
        Write-Host "  DeepSeek API Key 准备" -ForegroundColor Cyan
        Write-Host "==============================================================" -ForegroundColor Cyan
        Write-Host "已为你打开 DeepSeek API Key 页面。"
        Write-Host "请在浏览器中登录 / 创建 API Key，然后回到本窗口继续。"
        Write-Host ""
        Write-Host "  [1] 我已复制 Key，开始粘贴"
        Write-Host "  [2] 重新打开 DeepSeek API Key 页面"
        Write-Host "  [3] 暂时跳过，稍后配置"
        Write-Host "  [4] 查看获取 Key 的简明步骤"
        Write-Host ""

        $choice = Read-Host "请输入选项编号（直接回车默认 1）"

        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = "1"
        }

        switch ($choice) {
            "1" {
                Write-Host ""
                Write-Warning "请不要把 API Key 发给卖家或任何第三方！"
                Write-Info "输入时不会显示字符，这是正常的安全保护。"
                Write-Info "请直接粘贴后按回车。"
                Write-Info "下一步会显示脱敏后的 Key，可选择 R 重新粘贴。"
                Write-Host ""

                $apiKey = Read-ApiKeyWithMaskedConfirmation -Prompt "请粘贴您的 DeepSeek API Key"

                if ([string]::IsNullOrWhiteSpace($apiKey)) {
                    Write-Info "已取消 API Key 输入。"
                    Write-ApiKeySkipGuidance
                    return $null
                }

                # 格式检查
                if (-not (Is-ApiKeyFormatValid -Key $apiKey)) {
                    Write-Warning "API Key 格式看起来不典型（DeepSeek Key 通常以 sk- 开头，长度 >= 32 字符）"
                    if (-not (Confirm-UserChoice -Message "是否仍然使用此 Key？" -Default "No")) {
                        Write-Info "已取消。您可以稍后重新运行配置。"
                        return $null
                    }
                }

                return $apiKey
            }
            "2" {
                Write-Info "正在重新打开 DeepSeek API Key 页面..."
                try {
                    Start-Process "https://platform.deepseek.com/api_keys"
                }
                catch {
                    Write-Info "请手动在浏览器中打开: https://platform.deepseek.com/api_keys"
                }
                continue menu
            }
            "3" {
                Write-ApiKeySkipGuidance
                return $null
            }
            "4" {
                Write-Host ""
                Write-Info "获取 DeepSeek API Key 步骤："
                Write-Info "  1. 打开 https://platform.deepseek.com/api_keys"
                Write-Info "  2. 登录 DeepSeek 账号"
                Write-Info "  3. 点击创建 API Key"
                Write-Info "  4. 复制以 sk- 开头的 Key"
                Write-Info "  5. 回到此窗口选择 1 粘贴"
                continue menu
            }
            default {
                Write-Warning "无效选项，请输入 1-4。"
                continue menu
            }
        }
    }
}

# ============================================================
# Step 4: 写入 DeepSeek 配置
# ============================================================

function Step-WriteConfig {
    param([string]$ApiKey)

    Write-Step "Step 4/7：写入 DeepSeek 配置"

    Write-Info "正在写入配置文件..."
    Write-Log "INFO" "配置文件路径: $(Get-ClaudeConfigFile)"
    Write-Host ""

    $writeResult = Write-DeepSeekConfig -ApiKey $ApiKey -NonInteractive:$NonInteractive

    if ($writeResult.Success) {
        # Write-DeepSeekConfig 内部已输出完整的成功信息和脱敏 Key，这里只做状态更新
        $script:ConfigWritten = $true
        Update-CcdiState -Updates @{
            configPath     = $writeResult.ConfigPath
            lastBackupPath = if ($writeResult.BackupPath) { $writeResult.BackupPath } else { "" }
        } | Out-Null
        return $true
    }
    else {
        Write-Error-Msg "配置写入失败: $($writeResult.Error)"
        $script:ConfigWritten = $false
        return $false
    }
}

# ============================================================
# Step 5: API smoke test
# ============================================================

function Step-TestApi {
    param([string]$ApiKey)

    Write-Step "Step 5/7：测试 DeepSeek API 连接"

    if ($script:EffectiveSkipApiTest) {
        if ($script:TestSafeMode) {
            Write-ResultLine "API 测试" "SKIP" "测试安全模式，未请求 DeepSeek"
            Write-Info "测试安全模式流程完成后仍不代表真实 API 已验证。"
        }
        else {
            Write-ResultLine "API 测试" "SKIP" "已按参数跳过"
            Write-Info "注意: 未验证 API 是否可用。可稍后运行 doctor.ps1 测试。"
        }
        $script:ApiTestSkipped = $true
        Update-CcdiState -Updates @{ lastApiTest = "skipped" } | Out-Null
        return
    }

    Write-Log "INFO" "测试模型: deepseek-v4-flash, 测试消息: 'Reply OK only.'"
    Write-Info "正在进行 API 连接测试。"
    Write-Info "最长等待约 30 秒。如果失败，配置仍会保留，可稍后重新测试。"
    Write-Host ""

    $apiTest = Test-DeepSeekApiAnthropic -ApiKey $ApiKey -Model "deepseek-v4-flash"

    if ($apiTest.Success) {
        Write-Success "DeepSeek API Anthropic Format smoke test 通过！"
        if ($apiTest.Content) {
            Write-Info "模型返回: $($apiTest.Content)"
        }
        $script:ApiTestPassed = $true
        Update-CcdiState -Updates @{ lastApiTest = "passed" } | Out-Null
    }
    else {
        Write-ResultLine "API 测试" "WARN" $apiTest.Error
        if ($apiTest.Suggestion) {
            Write-Warning $apiTest.Suggestion
        }

        # 分类错误给出中文建议
        switch ($apiTest.StatusCode) {
            401 { Write-Info "请到 platform.deepseek.com 检查 API Key 是否正确、是否已删除。" }
            402 { Write-Info "请到 DeepSeek 控制台检查账户余额是否充足。" }
            403 { Write-Info "请检查 API Key 权限设置。" }
            429 { Write-Info "请求太频繁，请稍等几分钟再试。" }
            { $_ -ge 500 } { Write-Info "这是 DeepSeek 官方服务端问题，不是您的配置问题，稍后重试即可。" }
        }

        # 不中断：配置已写入，API 测试失败也允许继续
        Write-Warning "API 测试未通过，但配置已保留。"
        Write-NextStepCard `
            -Status "Claude Code 已配置完成，但 DeepSeek API 暂未测试通过。" `
            -Tried @(
                "已写入 DeepSeek 配置",
                "已尝试连接 DeepSeek API"
            ) `
            -NextSteps @(
                "到 platform.deepseek.com 检查 API Key 是否正确",
                "检查 DeepSeek 账户余额是否充足",
                "稍后重新运行「一键诊断.cmd」测试 API"
            )
        $script:ApiTestFailed = $true
        $script:ApiTestFailReason = $apiTest.Error
        Update-CcdiState -Updates @{ lastApiTest = "failed" } | Out-Null
    }
}

# ============================================================
# Step 6: 创建测试项目
# ============================================================

function Step-CreateTestProject {
    Write-Step "Step 6/7：创建测试项目"

    $desktopPath = Get-DesktopPath
    $testDir = Join-Path $desktopPath "ClaudeCode-Test"

    # 如果目录已存在，使用带时间戳的备用名
    if (Test-Path $testDir) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $testDir = Join-Path $desktopPath "ClaudeCode-Test-$timestamp"
        Write-Info "ClaudeCode-Test 目录已存在，创建备用目录: $testDir"
    }

    try {
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        Write-Success "测试项目目录已创建: $testDir"

        # README.md
        $readmeContent = @"
# Claude Code 测试项目

这个文件夹只是用来验证 Claude Code 是否安装成功。

你可以删除这个文件夹，删除后不会影响：
- Claude Code 安装
- DeepSeek API 配置
- 你的 API Key
- 其他项目

## 如何测试

1. 在本文件夹打开 PowerShell
2. 输入：

```
claude
```

3. 进入 Claude Code 后，输入：

```
请用一句话说明当前项目是做什么的。
```

如果 Claude Code 能正常回复，说明安装和配置基本可用。

## 如果失败

请返回安装工具，选择：
[4] 运行一键诊断

然后只发送诊断 support-feedback.txt（优先）或 report.txt 给技术支持。
不要发送 backup、logs、full-report，也不要发送完整 API Key。
"@
        $readmePath = Join-Path $testDir "README.md"
        [System.IO.File]::WriteAllText($readmePath, $readmeContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Info "已创建 README.md"

        # CLAUDE.md
        $claudeMdContent = @"
# 项目说明

这是 Claude Code + DeepSeek API 本地配置助手创建的测试项目。
请优先使用中文回复。
修改文件前先说明计划。
不要删除用户已有文件。
"@
        $claudeMdPath = Join-Path $testDir "CLAUDE.md"
        [System.IO.File]::WriteAllText($claudeMdPath, $claudeMdContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Info "已创建 CLAUDE.md"

        # hello.md
        $helloContent = @"
# Hello World

这是一个测试文件。

你可以在 `claude` 中让我基于此文件生成一个网页。
"@
        $helloPath = Join-Path $testDir "hello.md"
        [System.IO.File]::WriteAllText($helloPath, $helloContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Info "已创建 hello.md"

        $script:TestProjectPath = $testDir
        Write-Success "测试项目创建完成！"
        return $true
    }
    catch {
        Write-Error-Msg "创建测试项目失败: $($_.Exception.Message)"
        Write-Log "ERROR" "创建测试项目异常: $_"
        return $false
    }
}

# ============================================================
# Step 7: 生成报告
# ============================================================

function Step-GenerateReport {
    param(
        [string]$ApiKey,
        $EnvCheckResult
    )

    if ($script:TestSafeMode) {
        Write-Step "Step 7/7：生成测试安全模式报告"
    }
    else {
        Write-Step "Step 7/7：生成安装完成报告"
    }

    Write-Info "正在生成安装报告（通常 1-3 秒）..."

    # 确保 reports 目录存在
    $reportsDir = Join-Path $ScriptDir "reports"
    if (-not (Test-Path $reportsDir)) {
        New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportPath = Join-Path $reportsDir "install-report-$timestamp.txt"
    $script:ReportPath = $reportPath

    # 收集信息：优先使用 EnvSnapshot 缓存，缺失字段 fallback 到实时检测
    # 使用 Get-Variable 防御式读取：即使未来重构导致变量未定义也不抛异常
    $snapVar = Get-Variable -Name EnvSnapshot -Scope Script -ErrorAction SilentlyContinue
    $snap = if ($snapVar) { $snapVar.Value } else { $null }
    $winInfo = Get-WindowsVersionInfo
    $psInfo = Get-PowerShellVersionInfo

    # Claude Code 版本：允许重新检测一次（安装步骤可能已改变状态）
    $claudeVer = Test-ClaudeInstalled

    # VS Code / WSL 可使用缓存（本工具不会安装它们），Node.js/npm 必须实时检测
    if ($snap) {
        $codeVer = if ($snap.CodeVersion) { $snap.CodeVersion } else { Test-CodeInstalled }
        $wslInfo = if ($snap.WslInfo) { $snap.WslInfo } else { Test-WslInstalled }
    }
    else {
        # fallback: EnvSnapshot 不存在时（如旧版调用路径），回退到实时检测
        $codeVer = Test-CodeInstalled
        $wslInfo = Test-WslInstalled
    }

    # Node.js/npm 必须实时检测：安装流程可能刚刚安装了 Node.js，缓存已过期
    $nodeInfo = Test-NodeJsInstalled
    $npmInfo = Test-NpmInstalled
    $maskedKey = Mask-ApiKey -Key $ApiKey

    $apiTestStatus = if ($script:ApiTestPassed) { "通过" }
        elseif ($script:ApiTestSkipped) { "跳过" }
        elseif ($script:ApiTestFailed) { "失败" }
        else { "未执行" }

    # --- PATH 验证 + 安装位置 (v1.3.3) ---
    $nativeBinPath = Get-NativeClaudeBinPath
    $nativeClaudeExe = Get-NativeClaudeExePath
    $claudeCmdCheck = Test-ClaudeCommandExisting
    $claudeInstallLocation = if ($script:ClaudeInstallMethod -eq "npm_npmmirror" -and $claudeCmdCheck.Path) {
        Sanitize-PathForReport -Path $claudeCmdCheck.Path
    }
    elseif ($script:ClaudeInstallMethod -in @("official_native", "existing_native") -and (Test-Path $nativeClaudeExe)) {
        Sanitize-PathForReport -Path $nativeClaudeExe
    }
    elseif (Test-Path $nativeClaudeExe) {
        Sanitize-PathForReport -Path $nativeClaudeExe
    }
    elseif ($claudeCmdCheck.Path -and $claudeCmdCheck.Usable) {
        Sanitize-PathForReport -Path $claudeCmdCheck.Path
    }
    elseif ($claudeCmdCheck.Path) {
        Sanitize-PathForReport -Path $claudeCmdCheck.Path
    }
    elseif ($claudeVer) {
        "已安装（路径未识别）"
    }
    else {
        "未安装"
    }
    $userPathStatus = if (Test-Path $nativeClaudeExe) {
        $check = Test-UserPathContains -TargetPath $nativeBinPath
        if ($check.Contains) { "已包含 $nativeBinPath" } else { "未包含 $nativeBinPath" }
    }
    else { "N/A（非 Native Install）" }

    # v1.3.3 P0-3: 动态 fresh shell 状态，用于报告和完成页
    $freshShellOk = $false
    $freshShellResult = if ($claudeVer -and (Test-Path $nativeClaudeExe)) {
        $fs = Test-ClaudeCommandInFreshShell
        $freshShellOk = $fs.Success
        if ($fs.Success) { "通过 - $($fs.Output)" } else { "失败" }
    }
    elseif ($claudeVer) {
        $fs2 = Test-ClaudeCommandInFreshShell
        $freshShellOk = $fs2.Success
        if ($fs2.Success) { "通过 - $($fs2.Output)" } else { "失败" }
    }
    else { "N/A（Claude Code 未安装）" }

    $userPathOk = $false
    if (Test-Path $nativeClaudeExe) {
        $userPathCheck = Test-UserPathContains -TargetPath $nativeBinPath
        $userPathOk = $userPathCheck.Contains
    }
    elseif ($claudeVer) {
        # 非 Native Install 的 PATH 状态不适用于 Native PATH
        $userPathOk = $true
    }

    # v1.3.3 P0-R2: fresh shell 状态分级（userPathOk+freshShellFail → WARN 而非 ERROR）
    $freshShellStatusTag = if ($freshShellOk) {
        "[OK]"
    }
    elseif ($script:ClaudeInstalled -and $userPathOk) {
        "[WARN]"
    }
    else {
        "[ERROR]"
    }
    $freshShellStatusText = if ($freshShellOk) {
        $freshShellResult
    }
    elseif ($script:ClaudeInstalled -and $userPathOk) {
        "$($freshShellResult)（自动验证未通过；请新开 PowerShell 手动验证）"
    }
    else {
        $freshShellResult
    }

    $claudeCommandUsable = if ($claudeVer) {
        if ($freshShellOk) { "可直接运行" }
        elseif ($userPathOk) { "PATH 已配置，但需重启终端验证" }
        elseif (Test-Path $nativeClaudeExe) { "需要修复 PATH" }
        else { "可运行（需验证）" }
    }
    else { "N/A" }

    $overallStatus = if ($script:TestSafeMode -and $script:ConfigWritten) { "测试安全模式完成" }
        elseif ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestPassed) {
            # v1.3.3 P0-3: 完整成功还需要 User PATH OK 且 fresh shell 通过
            if ($userPathOk -and $freshShellOk) {
                "完整成功"
            }
            elseif ($userPathOk -and -not $freshShellOk) {
                "部分成功：Claude Code 已安装，PATH 已配置，但新 PowerShell 验证未通过"
            }
            else {
                "部分成功：Claude Code 已安装，但 PATH 未正确配置"
            }
        }
        elseif ($script:ClaudeInstalled -and $script:ConfigWritten) { "部分成功" }
        else { "未完成" }

    $reportTitle = if ($script:TestSafeMode) { "Claude Code + DeepSeek 测试安全模式报告" } else { "Claude Code + DeepSeek 安装完成报告" }
    $configWriteDetail = if ($script:TestSafeMode) { "已在沙盒路径验证" } else { "已写入" }
    $claudeInstallSummary = if ($script:TestSafeMode) { "[SKIP] Claude Code 安装：测试安全模式，未执行真实安装" }
        elseif ($claudeVer) { "[OK] Claude Code 安装：已安装" }
        else { "[ERROR] Claude Code 安装：未完成" }
    $deepSeekConfigSummary = if ($script:ConfigWritten) { "[OK] DeepSeek 配置写入：$configWriteDetail" }
        else { "[ERROR] DeepSeek 配置写入：未完成" }
    $apiTestSummary = if ($script:TestSafeMode) { "[SKIP] API 测试：测试安全模式，未请求 DeepSeek" }
        elseif ($script:ApiTestPassed) { "[OK] API 测试：通过" }
        elseif ($script:ApiTestSkipped) { "[SKIP] API 测试：已跳过" }
        else { "[WARN] API 测试：$apiTestStatus" }
    $claudeLaunchSummary = if ($script:TestSafeMode) {
        "[SKIP] Claude 启动：未验证"
    }
    elseif ($script:ClaudeInstalled -and $freshShellOk) {
        "[OK] Claude 启动：新 PowerShell 可直接运行 claude"
    }
    elseif ($script:ClaudeInstalled -and -not $freshShellOk) {
        "[WARN] Claude 启动：Claude Code 文件已安装，但新 PowerShell 尚未验证通过"
    }
    else {
        "[SKIP] Claude 启动：未验证"
    }
    $testSafeNotice = if ($script:TestSafeMode) { "测试安全模式流程完成，不代表真实安装/API 已验证。" } else { "" }

    # 安装方式映射：内部值 → 用户可读中文
    $installMethodForReport = Convert-ClaudeInstallMethodForReport -Method $script:ClaudeInstallMethod -Source $claudeCmdCheck.Source -Path $claudeCmdCheck.Path

    # 官方 Native Install 成功时 Node.js/npm 标注"无需"
    $isOfficialNativeSuccess = ($script:ClaudeInstallMethod -in @("official_native", "existing_native")) -or
                               ($installMethodForReport -match "Native")

    $reportContent = @"
$reportTitle
======================================

生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
脚本版本: v$ScriptVersion
运行模式: $(if ($script:TestSafeMode) { "测试安全模式" } else { "一键安装" })

【一眼结论】
--------------------------------------
运行环境: Windows ($($winInfo.Version))
Claude Code: $(if ($script:TestSafeMode) { "测试安全模式未执行真实安装" } elseif ($claudeVer) { "已安装 ($claudeVer)" } elseif (($script:ClaudeInstallStatus -in @("node_installed_needs_restart", "installed_needs_restart"))) { "已安装但需重开终端" } else { "未安装" })
Claude Code 安装位置: $claudeInstallLocation
Node.js: $(if ($nodeInfo.Installed) { "$($nodeInfo.Version)" } elseif ($isOfficialNativeSuccess) { "未安装（当前官方安装方式无需 Node.js）" } else { "未安装" })
npm: $(if ($npmInfo.Installed) { "$($npmInfo.Version)" } elseif ($isOfficialNativeSuccess) { "不可用（当前官方安装方式无需 npm）" } else { "不可用" })
DeepSeek 配置: $(if ($script:ConfigWritten) { "已配置" } else { "未配置" })
API 测试: $apiTestStatus$(if ($script:ApiTestFailed) { " ($script:ApiTestFailReason)" } elseif ($script:ApiTestSkipped) { " - 未验证 API 是否可用" } else { "" })
User PATH: $userPathStatus
Fresh PowerShell 验证: $freshShellStatusText
整体状态: $overallStatus
$(if ($script:TestSafeMode) { "测试安全模式流程完成，不代表真实安装/API 已验证。" } else { "" })
$(if (($script:ClaudeInstallStatus -in @("node_installed_needs_restart", "installed_needs_restart"))) { "NEEDS_RESTART - 需要关闭窗口重新运行「00-点我开始安装.cmd」继续安装。" } else { "" })

一、系统信息
--------------------------------------
Windows 版本: $($winInfo.Version)
PowerShell 版本: $($psInfo.Version) ($($psInfo.Edition))
是否管理员权限: $(if (Test-IsAdministrator) { "是" } else { "否" })
用户目录: $(Get-UserProfilePath)
运行路径: $(Get-Location)

二、安装结果
--------------------------------------
Claude Code: $(if ($script:TestSafeMode) { "测试安全模式未执行真实安装" } elseif ($claudeVer) { "已安装" } else { "未安装" })
Claude Code 版本: $(if ($claudeVer) { $claudeVer } else { "-" })
安装方式: $installMethodForReport
测试安全模式: $(if ($script:TestSafeMode) { "是（未执行安装/更新/卸载）" } else { "否" })
VS Code: $(if ($codeVer) { "已检测" } else { "未检测" })
WSL: $(if ($wslInfo.Installed) { "已检测" } else { "未检测" })

三、DeepSeek 配置
--------------------------------------
配置文件路径: $(Get-ClaudeConfigFile)
ANTHROPIC_BASE_URL: https://api.deepseek.com/anthropic
ANTHROPIC_MODEL: deepseek-v4-pro[1m]
ANTHROPIC_SMALL_FAST_MODEL: deepseek-v4-flash
API Key: $maskedKey

四、API 测试
--------------------------------------
是否执行: $(if ($script:ApiTestSkipped) { "否（跳过）" } else { "是" })
结果: $apiTestStatus
$(if ($script:ApiTestFailed) { "错误分类: $script:ApiTestFailReason" } else { "" })
$(if ($script:ApiTestFailed) { "建议: 请检查 Key 是否正确、余额是否充足、网络是否正常。运行一键诊断获取详细信息。" } else { "" })
$(if ($script:TestSafeMode) { "说明: 测试安全模式强制跳过真实 API 调用。" } else { "" })

五、测试项目
--------------------------------------
路径: $(if ($script:TestProjectPath) { $script:TestProjectPath } else { "未创建" })
说明: 测试项目只用于验证 Claude Code 是否能正常使用，可以随时删除。
删除测试项目不会影响 Claude Code 安装和 DeepSeek 配置。

六、整体状态
--------------------------------------
$claudeInstallSummary
$deepSeekConfigSummary
$apiTestSummary
$claudeLaunchSummary
	$(if ($userPathOk) { "[OK]" } else { "[ERROR]" }) User PATH: $userPathStatus
	$freshShellStatusTag Fresh PowerShell 验证: $freshShellStatusText

Claude 命令可用性: $claudeCommandUsable
$overallStatus
$testSafeNotice

七、下一步说明
--------------------------------------
$(if ($script:TestSafeMode) {
"测试安全模式未执行真实安装，也未验证真实 API。
本结果只代表沙盒配置流程通过。"
} elseif (($script:ClaudeInstallStatus -in @("node_installed_needs_restart", "installed_needs_restart"))) {
"关闭该窗口后重新双击「00-点我开始安装.cmd」继续安装流程。
脚本会继续安装 Claude Code 并配置 DeepSeek。"
} elseif ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestPassed -and $userPathOk -and -not $freshShellOk) {
"安装和配置已完成，但自动启动验证未通过。

请关闭当前窗口，新开 PowerShell 手动执行：
claude --version

如果能显示版本号，可以正常使用。

如果仍失败，请运行：
1. 「一键修复依赖.cmd」
2. 「一键诊断.cmd」

如需售后，优先发送 support-feedback.txt；没有时发送 report.txt。不要发送 logs、backup、settings.json 或完整 API Key。"
} elseif ($script:ClaudeInstalled -and $script:ConfigWritten) {
"安装完成不代表 API 永久可用。
如果 Claude Code 能启动但模型调用失败，请优先检查：
1. DeepSeek API Key 是否正确
2. DeepSeek 账户余额是否充足
3. 当前网络是否能访问 api.deepseek.com
4. DeepSeek 官方接口或模型名是否发生变化

本工具只负责本地安装和配置，不销售 API，不保证第三方接口永久可用。"
} else {
"请继续完成安装流程，或运行「一键诊断.cmd」获取详细信息。"
})

八、售后提示
--------------------------------------
$(Write-SupportSafeGuidance -ForReport)
API Key 始终只保存在您的本机，不会上传或分享。

报告生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@

    try {
        [System.IO.File]::WriteAllText($reportPath, $reportContent, (New-Object System.Text.UTF8Encoding($false)))
        if ($script:TestSafeMode) {
            Write-Success "测试安全模式报告已生成: $reportPath"
        }
        else {
            Write-Success "安装完成报告已生成: $reportPath"
        }
        Write-Log "INFO" "安装报告已保存: $reportPath"

        # --- 生成 support-feedback.txt ---
        try {
            $fbOverallStatus = $overallStatus
            $fbClaudeStatus = if ($script:TestSafeMode) { "测试安全模式未执行真实安装" } elseif ($claudeVer) { "已安装 ($claudeVer)" } else { "未安装" }
            $fbDeepSeekStatus = if ($script:ConfigWritten) { "已配置" } else { "未配置" }
            $fbApiTestStatus = $apiTestStatus
            $fbFreshShellStatus = if ($freshShellOk) { "通过" } elseif ($script:ClaudeInstalled -and $userPathOk) { "建议手动验证" } else { "未验证" }
            $fbNextSteps = @()
            if ($script:TestSafeMode) {
                $fbNextSteps = @("测试安全模式未执行真实安装，不代表真实环境状态", "真实安装请使用「00-点我开始安装.cmd」")
            }
            elseif ($script:ClaudeInstalled -and $script:ConfigWritten) {
                if (-not $freshShellOk) { $fbNextSteps += "新开 PowerShell 执行 claude --version 确认可用" }
                $fbNextSteps += "回到安装助手完成页选择 [1] 启动 Claude Code 测试"
                if ($script:ApiTestFailed) { $fbNextSteps += "检查 DeepSeek Key 和余额" }
            }
            else {
                $fbNextSteps += "运行「00-点我开始安装.cmd」完成安装"
                $fbNextSteps += "运行「一键诊断.cmd」获取详细报告"
            }

            $safeReportForFb = Convert-ToSafeReportText -Text $reportContent
            $fbNodeJsStatus = if ($nodeInfo.Installed) { $nodeInfo.Version } elseif ($isOfficialNativeSuccess) { "未安装（当前安装方式无需）" } else { "" }
            $supportFeedbackResult = New-SupportFeedbackReport `
                -OutputPath (Join-Path $ScriptDir "support-feedback.txt") `
                -ReportText $safeReportForFb `
                -ScriptDir $ScriptDir `
                -IncludeLogTail:$true `
                -IncludeTerminalTail:$true `
                -MaxLogLines 120 `
                -MaxTerminalLines 120 `
                -OverallStatus $fbOverallStatus `
                -ClaudeStatus $fbClaudeStatus `
                -DeepSeekStatus $fbDeepSeekStatus `
                -ApiTestStatus $fbApiTestStatus `
                -FreshShellStatus $fbFreshShellStatus `
                -InstallMethod $installMethodForReport `
                -NodeJsStatus $fbNodeJsStatus `
                -NextSteps $fbNextSteps

            if ($supportFeedbackResult.Success) {
                $fbPath = (Resolve-Path $supportFeedbackResult.Path -ErrorAction SilentlyContinue).Path
                if (-not $fbPath) { $fbPath = $supportFeedbackResult.Path }
                Write-Success "售后反馈文件已生成: $fbPath"
                Write-Info "如需反馈问题，优先发送此文件。"
            }
        }
        catch {
            Write-Log "ERROR" "生成 support-feedback.txt 失败: $_"
            # 不阻断主流程
        }
    }
    catch {
        Write-Error-Msg "报告生成失败: $($_.Exception.Message)"
        Write-Log "ERROR" "报告写入失败: $_"
    }
}

# ============================================================
# P1-1: 自动启动 Claude Code 测试终端
# ============================================================

function Start-ClaudeTestTerminal {
    <#
    .SYNOPSIS
        v1.3.3 P1-1: 自动新开 PowerShell 终端，工作目录进入测试项目，直接运行 claude。
        仅在用户主动选择完成页 [1] 后调用。
    .PARAMETER ProjectPath
        测试项目的完整路径。
    .RETURNS
        成功启动新终端返回 $true，否则返回 $false。
    #>
    param(
        [string]$ProjectPath
    )

    # 校验 ProjectPath
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        Write-Warning "测试项目路径为空，无法启动。"
        return $false
    }

    if (-not (Test-Path $ProjectPath)) {
        Write-Warning "测试项目目录不存在。"
        return $false
    }

    # 解析 powershell.exe 路径
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $psExe)) {
        $psExe = "powershell.exe"
    }

    # 构造新终端中执行的脚本
    # 单引号内中文路径安全转义
    $projectPathLiteral = $ProjectPath.Replace("'", "''")

    $launchScript = @"
`$ErrorActionPreference = 'Continue'
try {
    `$Host.UI.RawUI.WindowTitle = 'Claude Code 测试 - DeepSeek 配置助手'
} catch {}

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '  Claude Code 测试终端' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ''

try {
    `$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    `$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    `$pathParts = @()
    if (`$userPath) { `$pathParts += `$userPath }
    if (`$machinePath) { `$pathParts += `$machinePath }
    `$env:Path = (`$pathParts -join ';')
} catch {
    Write-Host '[提示] PATH 刷新失败，将继续尝试启动 claude。' -ForegroundColor Yellow
}

try {
    Set-Location -LiteralPath '$projectPathLiteral'
} catch {
    Write-Host '[错误] 无法进入测试项目目录：$projectPathLiteral' -ForegroundColor Red
    Write-Host '请回到安装助手选择 [4] 一键诊断。' -ForegroundColor Yellow
    Write-Host ''
    Read-Host '按回车键关闭窗口'
    exit 1
}

Write-Host '[信息] 当前测试项目目录：' -ForegroundColor Gray
Write-Host "  `$PWD" -ForegroundColor Green
Write-Host ''
Write-Host '[信息] 正在启动 Claude Code...' -ForegroundColor Gray
Write-Host ''

Write-Host '--------------------------------------------------------------' -ForegroundColor Yellow
Write-Host '  [提示] Claude Code 首次启动可能出现以下界面：' -ForegroundColor Yellow
Write-Host '' -ForegroundColor Yellow
Write-Host '  1. 颜色/主题选择：' -ForegroundColor White
Write-Host '     如果看到 "Choose the text style that looks best with your terminal"' -ForegroundColor Gray
Write-Host '     这是 Claude Code 第一次启动的颜色主题选择。' -ForegroundColor Yellow
Write-Host '     可以直接按回车使用默认项，或选择 Dark mode。' -ForegroundColor Green
Write-Host ''
Write-Host '  2. 安全提示：' -ForegroundColor White
Write-Host '     如果看到 "Security notes"' -ForegroundColor Gray
Write-Host '     这是 Claude Code 的安全提示。' -ForegroundColor Yellow
Write-Host '     阅读后按 Enter 继续。' -ForegroundColor Green
Write-Host ''
Write-Host '  3. 信任当前文件夹：' -ForegroundColor White
Write-Host '     如果看到 "Claude Code will be able to read, edit, and execute files here."' -ForegroundColor Gray
Write-Host '     这是 Claude Code 在问你是否信任当前文件夹。' -ForegroundColor Yellow
Write-Host '     确认当前目录是 ClaudeCode-Test 测试项目，按回车继续。' -ForegroundColor Green
Write-Host ''
Write-Host '  进入 Claude Code 后可以输入：' -ForegroundColor White
Write-Host '     请用一句话说明当前项目是做什么的。' -ForegroundColor Gray
Write-Host '  如果模型能回复，说明基础可用。' -ForegroundColor Green
Write-Host '--------------------------------------------------------------' -ForegroundColor Yellow
Write-Host ''

`$cmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not `$cmd) {
    Write-Host '[错误] 当前终端未识别 claude 命令。' -ForegroundColor Red
    Write-Host ''
    Write-Host '请尝试：' -ForegroundColor Yellow
    Write-Host '1. 关闭此窗口，重新打开 PowerShell，执行 claude --version'
    Write-Host '2. 如果 claude --version 失败，回到安装助手选择 [4] 一键诊断'
    Write-Host '3. 或运行「一键修复依赖.cmd」'
    Write-Host ''
    Read-Host '按回车键关闭窗口'
    exit 10
}

try {
    & claude
    `$exitCode = `$LASTEXITCODE
    if (`$null -ne `$exitCode -and `$exitCode -ne 0) {
        Write-Host ''
        Write-Host "[提示] Claude Code 已退出，退出码：`$exitCode" -ForegroundColor Yellow
        Write-Host '如果刚才没有正常进入 Claude Code，请回到安装助手选择 [4] 一键诊断。' -ForegroundColor Yellow
        Write-Host ''
        Read-Host '按回车键关闭窗口'
    }
} catch {
    Write-Host ''
    Write-Host '[错误] Claude Code 启动过程中发生异常。' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host '请回到安装助手选择 [4] 一键诊断，优先发送 support-feedback.txt。' -ForegroundColor Yellow
    Write-Host ''
    Read-Host '按回车键关闭窗口'
    exit 20
}
"@

    # 使用 UTF-16LE (Unicode) 编码为 Base64，避免中文、空格、引号转义问题
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launchScript))

    try {
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList @("-NoExit", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCommand) `
            -WorkingDirectory $ProjectPath `
            -PassThru `
            -ErrorAction Stop

        Write-Log "INFO" "Start-ClaudeTestTerminal: 已启动 PowerShell 测试终端 (PID=$($proc.Id), Path=$ProjectPath)"
        return $true
    }
    catch {
        Write-Warning "无法启动 PowerShell 测试终端。"
        Write-Log "ERROR" "Start-ClaudeTestTerminal: Start-Process 失败: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# 最终完成页
# ============================================================

function Show-CompletionPage {
    Write-Host ""
    Write-Host ""

    if ($script:UnsupportedSystem) {
        Write-Host "==============================================================" -ForegroundColor Red
        Write-Host "                                                              " -ForegroundColor Red
        Write-Host "           当前电脑不满足最低要求，未继续安装                  " -ForegroundColor Red
        Write-Host "                                                              " -ForegroundColor Red
        Write-Host "==============================================================" -ForegroundColor Red
        Write-Host ""
        Write-Info "建议:"
        Write-Info "  - 升级到 Windows 10 1809 或更高版本"
        Write-Info "  - 确保系统为 64 位（x64 或 ARM64）"
        Write-Info "  - 确保至少 4GB 内存"
        Write-Info "  - 升级 PowerShell 到 5.1 或更高版本"
        Write-Info "  - 运行「一键诊断.cmd」获取详细诊断报告"
    }
    elseif ($script:TestSafeMode -and $script:ConfigWritten) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "                                                              " -ForegroundColor Yellow
        Write-Host "            测试安全模式流程完成                              " -ForegroundColor Yellow
        Write-Host "                                                              " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-ResultLine "Claude Code 安装" "SKIP" "测试安全模式，未执行真实安装"
        Write-ResultLine "DeepSeek 配置写入" "OK" "已在沙盒路径验证"
        Write-ResultLine "API 测试" "SKIP" "测试安全模式，未请求 DeepSeek"
        Write-ResultLine "Claude 启动" "SKIP" "未验证"
        if ($script:TestProjectPath) {
            Write-Success "测试项目已创建"
        }
        Write-Host ""
        Write-Info "测试安全模式不会安装、更新或卸载 Claude Code。"
        Write-Info "测试安全模式流程完成，不代表真实安装/API 已验证。"
        Write-Info "报告: $($script:ReportPath)"
    }
    elseif ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestPassed) {
        # v1.3.3 P0-3: 完整成功必须 User PATH OK 且 fresh shell 通过
        $nativeExeOk = Test-Path (Get-NativeClaudeExePath)
        $pathOk = $true
        $freshOk = $false
        if ($nativeExeOk) {
            $pathCheckLocal = Test-UserPathContains -TargetPath (Get-NativeClaudeBinPath)
            $pathOk = $pathCheckLocal.Contains
        }

        # Fresh shell 验证（所有安装方式都应该验证）
        $freshCheckLocal = Test-ClaudeCommandInFreshShell
        $freshOk = $freshCheckLocal.Success

        if ($pathOk -and $freshOk) {
            Write-Host "==============================================================" -ForegroundColor Green
            Write-Host "                                                              " -ForegroundColor Green
            Write-Host "                 安装流程已完成                                " -ForegroundColor Green
            Write-Host "                                                              " -ForegroundColor Green
            Write-Host "==============================================================" -ForegroundColor Green
            Write-Host ""
            Write-Success "Claude Code 已安装。"
            Write-Success "DeepSeek API 已配置。"
            Write-Success "新打开的 PowerShell 已确认可用。"
            Write-Host ""
            Write-Info "下一步：选择 [1] 启动 Claude Code 测试。"
        }
        elseif ($pathOk -and -not $freshOk) {
            Write-Host "==============================================================" -ForegroundColor Yellow
            Write-Host "                                                              " -ForegroundColor Yellow
            Write-Host "   安装和配置已完成，建议启动测试确认                        " -ForegroundColor Yellow
            Write-Host "                                                              " -ForegroundColor Yellow
            Write-Host "==============================================================" -ForegroundColor Yellow
            Write-Host ""
            Write-Success "Claude Code 文件已安装。"
            Write-Success "DeepSeek API 已配置。"
            Write-Info "命令路径已配置，但新打开的 PowerShell 暂未确认可用。"
            Write-Host ""
            Write-Info "下一步："
            Write-Info "选择 [1] 启动 Claude Code 测试。"
            Write-Info "如果新窗口无法进入 Claude Code，再选择 [4] 一键诊断。"
        }
        else {
            Write-Host "==============================================================" -ForegroundColor Yellow
            Write-Host "                                                              " -ForegroundColor Yellow
            Write-Host "    Claude Code 已安装，但命令路径需要修复                    " -ForegroundColor Yellow
            Write-Host "                                                              " -ForegroundColor Yellow
            Write-Host "==============================================================" -ForegroundColor Yellow
            Write-Host ""
            Write-Success "Claude Code 文件已安装。"
            Write-Success "DeepSeek API 已配置。"
            Write-Warning "当前还不能直接运行 claude。"
            Write-Host ""
            Write-Info "下一步："
            Write-Info "先选择 [4] 一键诊断，或运行「一键修复依赖.cmd」。"
            Write-Info "修复后再选择 [1] 启动测试。"
        }
    }
    elseif ($script:ClaudeInstalled -and $script:ConfigWritten) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "            安装部分完成，API 测试未通过                     " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Success "Claude Code 已安装。"
        Write-Success "DeepSeek 配置已写入。"
        Write-Warning "API 测试未通过，但安装和配置已保留。"

        Write-NextStepCard `
            -Status "Claude Code 已安装，DeepSeek 配置已写入，但 API 暂未测试通过。" `
            -Tried @(
                "已写入 DeepSeek 配置",
                "已尝试连接 DeepSeek API"
            ) `
            -NextSteps @(
                "先检查 DeepSeek API Key 是否正确",
                "检查 DeepSeek 账户余额是否充足",
                "稍后选择 [4] 一键诊断重新测试 API"
            )
        Write-Host ""
        Write-Info "安装完成报告: $($script:ReportPath)"
    }
    elseif ($script:ClaudeInstalled) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "            安装部分完成                                      " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Success "Claude Code 已安装。"
        Write-Warning "DeepSeek 配置未完成。"
        Write-Info "请稍后运行 configure-deepseek.ps1 或在主菜单选择高级选项配置 API Key。"
    }
    elseif ($script:ClaudeInstallStatus -in @("node_installed_needs_restart", "installed_needs_restart")) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "            需要重开终端后继续                                " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Warning "当前窗口还没有识别到新安装的命令。"
        Write-Info "这是第一阶段完成，不是失败。"
        Write-Info "下一步：关闭此窗口，重新双击「00-点我开始安装.cmd」继续。"
        Write-Info "重新打开后，安装助手会继续完成后续步骤。"
        Write-Info "类比：就像手机安装完 App 后需要点图标打开。"
    }
    else {
        # 最终兜底：即使在所有安装通道都失败的情况下，也做一次最终检测。
        # 避免因为中间状态误判导致用户看到"安装未完成"。
        Refresh-CurrentProcessPath
        $finalClaude = Test-ClaudeCommandExisting
        $finalConfig = Test-ClaudeConfigExists

        if ($finalClaude.Exists -and $finalClaude.Usable) {
            $script:ClaudeInstalled = $true
            Write-Host "==============================================================" -ForegroundColor Yellow
            Write-Host "            Claude Code 已安装，尚未配置 DeepSeek API Key     " -ForegroundColor Yellow
            Write-Host "==============================================================" -ForegroundColor Yellow
            Write-Host ""
            Write-Success "Claude Code 已安装: $($finalClaude.Version)"
            Write-Success "已检测到可用的 Claude Code。"
            $configStatus = Get-DeepSeekConfigStatus
            if (-not $configStatus.IsConfigured) {
                Write-Warning "DeepSeek API Key 尚未配置或配置不完整。"
                if ($configStatus.ErrorMessage) {
                    Write-Info "原因: $($configStatus.ErrorMessage)"
                }
                Write-Info "请运行 configure-deepseek.ps1 配置 API Key，"
                Write-Info "或在主菜单中选择 [1] 一键安装后配置。"
            }
        }
        else {
            Write-Host "==============================================================" -ForegroundColor Red
            Write-Host "            安装未完成                                        " -ForegroundColor Red
            Write-Host "==============================================================" -ForegroundColor Red
            Write-Host ""
            Write-Error-Msg "Claude Code 暂未确认安装成功。"

            Write-NextStepCard `
                -Status "Claude Code 暂未确认安装成功。" `
                -Tried @(
                    "已自动尝试可用安装方式",
                    "已刷新命令路径并重新检测安装结果"
                ) `
                -NextSteps @(
                    "先运行「一键修复依赖.cmd」自动修复常见问题",
                    "修复后重新运行「00-点我开始安装.cmd」",
                    "如果仍失败，再运行「一键诊断.cmd」生成 report.txt"
                ) `
                -IncludeSupportFallback
        }
    }

    Write-Host ""
    Write-Info "日志文件: $(Get-LogFilePath)"
    Write-Host ""

    # 完成页快捷操作菜单（仅交互模式）
    if (-not $NonInteractive) {
        Show-CompletionMenu
    }
}

function Show-CompletionMenu {
    <#
    .SYNOPSIS
        v1.3.3 UX: 完成页快捷操作菜单。循环显示直到用户选择退出。
        [1] 自动打开测试项目终端并直接运行 claude（推荐）。
        [2] 仅打开测试项目文件夹，不启动 claude。
        不自动启动 claude——仅在用户主动选择 [1] 后才启动。
    #>
    while ($true) {
        Write-Host ""
        Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "  请选择下一步：" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan

        # 选项 1: 启动 Claude Code 测试（推荐）
        $testProjectAvailable = ($script:TestProjectPath -and (Test-Path $script:TestProjectPath))
        $canRecommendClaudeTest = $script:ClaudeInstalled -and $testProjectAvailable
        if ($canRecommendClaudeTest) {
            Write-Host ""
            Write-Info "推荐下一步：直接输入 1，然后按回车，启动 Claude Code 测试。"
        }
        if ($testProjectAvailable) {
            Write-Host "  [1] 启动 Claude Code 测试（推荐）" -ForegroundColor Green
            Write-Host "      自动打开测试项目终端，并直接运行 claude。" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  [1] 启动 Claude Code 测试（测试项目未创建）" -ForegroundColor DarkGray
        }

        # 选项 2: 打开测试项目文件夹
        if ($testProjectAvailable) {
            Write-Host "  [2] 打开测试项目文件夹" -ForegroundColor White
            Write-Host "      仅浏览文件夹内容，不启动 claude。" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  [2] 打开测试项目文件夹（不可用）" -ForegroundColor DarkGray
        }

        # 选项 3: 打开安装报告
        $reportAvailable = ($script:ReportPath -and (Test-Path $script:ReportPath))
        if ($reportAvailable) {
            Write-Host "  [3] 打开安装报告" -ForegroundColor White
        }
        else {
            Write-Host "  [3] 打开安装报告（不可用）" -ForegroundColor DarkGray
        }

        # 选项 4: 运行一键诊断
        Write-Host "  [4] 运行一键诊断" -ForegroundColor White

        # 选项 5: 退出
        Write-Host "  [5] 退出" -ForegroundColor White

        Write-Host ""
        Write-Host "  测试项目只是用来确认 Claude Code 能正常启动和调用模型。" -ForegroundColor DarkGray
        Write-Host "  删除测试项目不会影响 Claude Code 安装和 DeepSeek 配置。" -ForegroundColor DarkGray

        Write-Host ""

        $choice = Read-Host "请输入选项编号 (1-5)"

        switch ($choice) {
            "1" {
                if (-not $testProjectAvailable) {
                    Write-Info "测试项目未创建，正在自动创建..."
                    $created = Step-CreateTestProject
                    if (-not $created) {
                        Write-Warning "无法自动创建测试项目。"
                        Write-Info "请手动在任意位置新建文件夹，然后在文件夹中打开 PowerShell 输入 claude。"
                        continue
                    }
                    $testProjectAvailable = ($script:TestProjectPath -and (Test-Path $script:TestProjectPath))
                }

                Write-Info "正在打开 Claude Code 测试终端..."
                $started = Start-ClaudeTestTerminal -ProjectPath $script:TestProjectPath

                if ($started) {
                    Write-Success "已打开 Claude Code 测试终端。"
                    Write-Info "接下来请看新打开的 Claude Code 窗口。"
                    Write-Info "本窗口可以输入 5 退出，或输入 4 运行诊断。"
                }
                else {
                    Write-Warning "自动启动测试终端失败。"
                    Write-Host ""
                    Write-Info "你可以按下面方式手动测试："
                    Write-Info "  1. 选择 [2] 打开测试项目文件夹"
                    Write-Info "  2. 在文件夹地址栏输入 powershell，然后按回车"
                    Write-Info "  3. 在新打开的终端里输入 claude"
                    Write-Info "  4. 如果仍失败，返回本窗口选择 [4] 一键诊断"
                }
            }
            "2" {
                if (-not $testProjectAvailable) {
                    Write-Info "测试项目未创建。"
                    continue
                }
                Write-Info "正在打开测试项目文件夹（仅浏览文件，不启动 claude）..."
                try {
                    explorer.exe $script:TestProjectPath
                    Write-Info "已打开: $($script:TestProjectPath)"
                }
                catch {
                    Write-Warning "无法自动打开文件夹，请手动打开: $($script:TestProjectPath)"
                }
            }
            "3" {
                if (-not $reportAvailable) {
                    Write-Info "报告未生成。"
                    continue
                }
                Write-Info "正在打开安装报告..."
                try {
                    Start-Process -FilePath "notepad.exe" -ArgumentList @($script:ReportPath) -ErrorAction Stop
                    Write-Info "已打开报告: $($script:ReportPath)"
                }
                catch {
                    try {
                        Invoke-Item -Path $script:ReportPath -ErrorAction Stop
                        Write-Info "已打开报告: $($script:ReportPath)"
                    }
                    catch {
                        Write-Warning "无法自动打开报告，请手动打开: $($script:ReportPath)"
                    }
                }
            }
            "4" {
                Write-Info "正在运行一键诊断..."
                $doctorScript = Join-Path $ScriptDir "doctor.ps1"
                if (Test-Path $doctorScript) {
                    $doctorArgs = @("-File", $doctorScript, "-ShareSafe")
                    if ($script:EffectiveSkipApiTest) {
                        $doctorArgs += "-SkipApiTest"
                    }
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass @doctorArgs
                }
                else {
                    Write-Error-Msg "找不到 doctor.ps1，请确认文件完整。"
                }
                Write-Host ""
                Read-Host "按回车键返回..."
            }
            "5" {
                Write-Info "感谢使用！"
                return
            }
            default {
                Write-Warning "无效选项，请输入 1-5。"
            }
        }
    }
}

# ============================================================
# 一键安装流程（模式 1）
# ============================================================

function Start-LazyInstall {
    Write-Log "INFO" "开始一键安装流程"

    # 初始化/更新状态文件
    Initialize-CcdiState -ScriptVersion $ScriptVersion | Out-Null

    # Step 1: 环境检查
    $envResult = Step-CheckEnvironment

    # 硬性要求不满足，停止安装
    if ($envResult.MinReqFailed) {
        Write-Error-Msg "当前电脑不满足最低系统要求，已停止安装。"
        Write-Info "请运行「一键诊断.cmd」获取详细诊断报告。"
        $script:UnsupportedSystem = $true
        Show-CompletionPage
        return
    }

    Pause-ForUser

    # Step 2: 安装 Claude Code
    $claudeOk = Step-InstallClaudeCode
    if (-not $claudeOk) {
        if (($script:ClaudeInstallStatus -in @("node_installed_needs_restart", "installed_needs_restart"))) {
            Write-Warning "当前需要重开终端后继续，已跳过后续配置步骤。"
        }
        else {
            # 最后一次兜底检测：也许 Claude 已可用但中间流程误判
            Refresh-CurrentProcessPath
            $finalCheck = Test-ClaudeCommandExisting
            if ($finalCheck.Exists -and $finalCheck.Usable) {
                # v1.3.3 P1-2: 兜底检测必须包含 fresh shell 验证
                $freshFinal = Test-ClaudeCommandInFreshShell

                # 优先保留 installResult.Method（如 npm_npmmirror），不被 Source=ExternalScript 覆盖
                $knownInstallMethods = @("official_native", "winget", "npm_npmmirror", "existing", "existing_native")
                $resolvedMethod = if ($script:ClaudeInstallMethod -in $knownInstallMethods) {
                    $script:ClaudeInstallMethod
                }
                else {
                    "final_fallback"
                }
                Write-Log "INFO" "Start-LazyInstall final fallback source=$($finalCheck.Source), path=$($finalCheck.Path), preservedMethod=$resolvedMethod"

                if ($freshFinal.Success) {
                    $script:ClaudeInstalled = $true
                    $script:ClaudeInstallMethod = $resolvedMethod
                    $script:ClaudeInstallStatus = "installed"
                    Write-UserFriendlyInstallMessage -Type "InstallSuccess" -Detail "final check version: $($finalCheck.Version)"
                    Write-Log "INFO" "Start-LazyInstall 兜底通过: fresh shell 可用, 继续流程"
                }
                else {
                    $script:ClaudeInstalled = $true
                    $script:ClaudeInstallMethod = $resolvedMethod
                    $script:ClaudeInstallStatus = "installed_needs_restart_or_path_fix"

                    Write-Warning "当前窗口可以识别 Claude Code，但新打开的 PowerShell 还没有确认可用。"
                    Write-Info "本工具会继续配置 DeepSeek API Key。"
                    Write-Info "安装结束后请先选择完成页 [1] 启动测试。"
                    Write-Info "如果测试失败，再运行「一键修复依赖.cmd」。"
                    Write-Log "WARN" "Start-LazyInstall 兜底部分通过: current process usable, fresh shell failed: $($freshFinal.Error)"
                }

                $configStatus = Get-DeepSeekConfigStatus
                if (-not $configStatus.IsConfigured) {
                    Write-Warning "Claude Code 已安装，但 DeepSeek API Key 尚未配置或配置不完整。"
                    if ($configStatus.ErrorMessage) {
                        Write-Info "原因: $($configStatus.ErrorMessage)"
                    }
                    Write-Info "下一步：继续配置 DeepSeek API Key。"
                }

                # 不 return，继续后续 API Key 配置
            }
            else {
                Write-UserFriendlyInstallMessage -Type "InstallFailed"
                Write-NextStepCard `
                    -Status "Claude Code 暂未确认安装成功。" `
                    -Tried @(
                        "已自动切换可用安装方式",
                        "已刷新命令路径并重新检测安装结果"
                    ) `
                    -NextSteps @(
                        "先运行「一键修复依赖.cmd」自动修复常见问题",
                        "修复后重新运行「00-点我开始安装.cmd」",
                        "如果仍失败，再运行「一键诊断.cmd」生成 report.txt"
                    ) `
                    -IncludeSupportFallback
                Show-CompletionPage
                return
            }
        }
        # needs_restart 分支仍然需要 return
        # v1.3.3 P0-3: installed_needs_restart_or_path_fix 表示已安装完毕仅需手动验证，不应阻断后续流程
        if ($script:ClaudeInstallStatus -in @("node_installed_needs_restart", "installed_needs_restart")) {
            Show-CompletionPage
            return
        }
    }

    # 安装成功后暂停：根据安装状态分类显示提示
    $partialClaudeStatus = $script:ClaudeInstallStatus -in @(
        "installed_needs_restart_or_path_fix",
        "installed_needs_path_fix"
    )

    if ($script:ClaudeInstallMethod -eq "existing" -or $script:ClaudeInstallStatus -eq "skipped_existing") {
        Write-Info "检测到 Claude Code 已安装，继续配置 DeepSeek。"
        Pause-ForUser
    }
    elseif ($partialClaudeStatus) {
        Pause-ForNextStep -Force -Messages @(
            "Claude Code 文件已安装，但新打开的 PowerShell 还没有确认可用。",
            "本工具会继续配置 DeepSeek API Key。",
            "安装结束后请先选择完成页 [1] 启动测试。",
            "如果测试失败，再运行「一键修复依赖.cmd」。"
        )
    }
    else {
        Pause-ForNextStep -Force -Messages @(
            "Claude Code 安装验证已通过。",
            "下一步将打开 DeepSeek API Key 页面。",
            "现在不用粘贴 API Key；请先按回车继续。",
            "下一屏会让你选择 [1] 我已复制 Key，开始粘贴。"
        )
    }

    # Step 3: 获取 API Key
    $apiKey = Step-GetApiKey
    if ($null -eq $apiKey) {
        Write-Info "未配置 API Key，已跳过 DeepSeek 配置步骤。"
        Write-Info "Claude Code 安装状态不受影响。"
        Show-CompletionPage
        return
    }

    Pause-ForUser

    # Step 4: 写入配置
    $configOk = Step-WriteConfig -ApiKey $apiKey
    if (-not $configOk) {
        Show-CompletionPage
        return
    }

    Pause-ForUser

    # Step 5: API 测试
    Step-TestApi -ApiKey $apiKey

    Pause-ForUser

    # Step 6: 创建测试项目
    [void](Step-CreateTestProject)

    Pause-ForUser

    # Step 7: 生成报告
    Step-GenerateReport -ApiKey $apiKey -EnvCheckResult $envResult

    # 最终完成页
    Show-CompletionPage
}

# ============================================================
# 其他模式
# ============================================================

function Start-ConfigureOnly {
    Write-Step "仅配置 DeepSeek API"

    & (Join-Path $ScriptDir "configure-deepseek.ps1")
    # configure-deepseek.ps1 有自己的完整交互流程
    exit 0
}

function Start-DoctorOnly {
    Write-Step "环境诊断"

    $doctorScript = Join-Path $ScriptDir "doctor.ps1"
    if (Test-Path $doctorScript) {
        & $doctorScript -ShareSafe -SkipApiTest:$script:EffectiveSkipApiTest
    }
    else {
        Write-Error-Msg "找不到 doctor.ps1，请确认文件完整。"
    }
}

function Start-WslSetup {
    Write-Step "配置 WSL Ubuntu 环境"

    Write-Info "WSL 是高级选项。默认先配置 Windows 原生环境。"
    Write-Host ""

    $wslInfo = Test-WslInstalled
    if (-not $wslInfo.Installed) {
        Write-Warning "未检测到 WSL。"
        Write-Info "如需启用 WSL，请以管理员身份运行 PowerShell 并执行:"
        Write-Host "  wsl --install" -ForegroundColor Cyan
        Write-Info "安装完成后重新运行本脚本选择此选项。"
        return
    }

    $ubuntuInfo = Test-UbuntuInWsl -WslInfo $wslInfo
    if (-not $ubuntuInfo.Exists) {
        Write-Warning "WSL 已启用但未检测到 Ubuntu 发行版。"
        Write-Info "请在 Microsoft Store 搜索 Ubuntu 安装，或运行:"
        Write-Host "  wsl --install -d Ubuntu" -ForegroundColor Cyan
        return
    }

    # 检查 WSL Ubuntu 版本
    $wslUbuntuVer = Get-WslUbuntuVersionInfo
    if ($wslUbuntuVer.Exists) {
        if ($wslUbuntuVer.IsSupported) {
            Write-ResultLine "WSL Ubuntu" "OK" "版本 $($wslUbuntuVer.Version)"
        }
        elseif ($wslUbuntuVer.IsUbuntu) {
            Write-ResultLine "WSL Ubuntu" "ERROR" "版本 $($wslUbuntuVer.Version) 低于 20.04"
            Write-Warning "建议升级 Ubuntu 到 20.04 或更高版本。"
        }
        else {
            Write-ResultLine "WSL 发行版" "WARN" "非 Ubuntu，未充分测试"
        }
    }

    Write-Host ""
    Write-Info "为避免 Windows 路径、权限、WSL 发行版差异导致失败，新版不再默认"
    Write-Info "从 Windows 端自动调用 WSL。请按以下方式手动操作："
    Write-Host ""
    Write-Host "  推荐方式：打开 WSL Ubuntu 终端，手动运行 install_wsl.sh" -ForegroundColor Green
    Write-Host "    1. 打开 WSL 终端（开始菜单搜索 'Ubuntu'）" -ForegroundColor White
    Write-Host "    2. cd 到本项目目录" -ForegroundColor White
    Write-Host "    3. 运行: chmod +x install_wsl.sh && ./install_wsl.sh" -ForegroundColor White
    Write-Host ""
    Write-Info "如果在 WSL 中遇到网络或权限问题，请参考 README.md 中的 WSL 章节。"

}

function Start-UninstallMenu {
    Write-Step "恢复或卸载配置"

    $uninstallScript = Join-Path $ScriptDir "uninstall-config.ps1"
    if (Test-Path $uninstallScript) {
        & $uninstallScript
    }
    else {
        Write-Error-Msg "找不到 uninstall-config.ps1，请确认文件完整。"
    }
}

# ============================================================
# 主菜单
# ============================================================

function Show-MainMenu {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "                    请选择要执行的操作                        " -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  [1] 一键安装（推荐）                                        " -ForegroundColor Green
    Write-Host "      自动检测 → 安装 → 配置 → 测试 → 生成报告               " -ForegroundColor White
    Write-Host "  [2] 遇到问题：一键诊断（生成 support-feedback.txt / report.txt）    " -ForegroundColor White
    Write-Host "  [3] 缺少依赖：一键修复依赖（Node.js/npm/Claude）            " -ForegroundColor White
    Write-Host "  [4] 修改 / 恢复 / 卸载配置                                  " -ForegroundColor White
    Write-Host "  [5] 高级选项                                                " -ForegroundColor White
    Write-Host "  [6] 退出                                                    " -ForegroundColor White
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""

    $choice = Read-Host "请输入选项编号 (1-6，直接回车默认选 1)"

    if ([string]::IsNullOrWhiteSpace($choice)) {
        $choice = "1"
    }

    switch ($choice) {
        "1" {
            Write-Log "INFO" "用户选择: 一键安装"
            Start-LazyInstall
        }
        "2" {
            Write-Log "INFO" "用户选择: 仅运行诊断"
            Start-DoctorOnly
        }
        "3" {
            Write-Log "INFO" "用户选择: 一键修复依赖"
            $repairScript = Join-Path $ScriptDir "repair-deps.ps1"
            if (Test-Path $repairScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript
            }
            else {
                Write-Error-Msg "找不到 repair-deps.ps1，请确认文件完整。"
            }
        }
        "4" {
            Write-Log "INFO" "用户选择: 恢复或卸载配置"
            Start-UninstallMenu
        }
        "5" {
            Write-Log "INFO" "用户选择: 高级选项"
            Show-AdvancedMenu
        }
        "6" {
            Write-Log "INFO" "用户选择: 退出"
            Write-Info "感谢使用！"
            Write-Info "如遇问题请运行「一键诊断.cmd」获取诊断报告。"
            exit 0
        }
        default {
            Write-Error-Msg "无效选项，请输入 1-6。"
            Show-MainMenu
        }
    }
}

function Show-AdvancedMenu {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "                         高级选项                             " -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  [1] 仅配置 DeepSeek API                                     " -ForegroundColor White
    Write-Host "  [2] 配置 WSL Ubuntu 环境                                    " -ForegroundColor White
    Write-Host "  [3] 返回主菜单                                              " -ForegroundColor White
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""

    $choice = Read-Host "请输入选项编号 (1-3)"

    switch ($choice) {
        "1" {
            Write-Log "INFO" "用户选择: 仅配置 DeepSeek API"
            Start-ConfigureOnly
        }
        "2" {
            Write-Log "INFO" "用户选择: WSL 配置"
            Start-WslSetup
        }
        "3" {
            Write-Log "INFO" "用户选择: 从高级选项返回主菜单"
            Show-MainMenu
        }
        default {
            Write-Error-Msg "无效选项，请输入 1-3。"
            Show-AdvancedMenu
        }
    }
}

# ============================================================
# 主入口
# ============================================================

function Main {
    # 安全启动 terminal transcript（失败不阻断，finally 兜底停止）
    [void](Start-CcdiTranscriptSafe -Name "start-here")

    try {
        # ============================================================
        # 路径安全检查（所有模式均执行）
        # ============================================================
        $pathRisk = Test-UserPathRisk

        if ($pathRisk.IsBlocked) {
            Write-Host ""
            Write-Host "==============================================================" -ForegroundColor Red
            Write-Host "  [ERROR] 检测到你可能正在压缩包预览窗口中直接运行" -ForegroundColor Red
            Write-Host "==============================================================" -ForegroundColor Red
            Write-Host ""
            Write-Warning "请先右键 ZIP 文件 -> 全部解压缩。"
            Write-Warning "然后打开解压后的文件夹，再双击 00-点我开始安装.cmd。"
            Write-Warning "不要在压缩包预览窗口中直接运行。"
            Write-Host ""
            Write-Info "本次运行日志: $(Get-LogFilePath)"
            Write-Info "如需排查问题，请运行「一键诊断.cmd」并优先发送 support-feedback.txt。"
            Write-Host ""
            if (-not $NonInteractive) {
                Read-Host "按回车键退出..."
            }
            exit 1
        }

        # 日志路径前置：交互模式下尽早显示
        if (-not $NonInteractive) {
            Write-Info "本次运行日志: $(Get-LogFilePath)"
            Write-Info "窗口异常关闭时，可重新运行「一键诊断.cmd」生成 support-feedback.txt。"
            Write-Host ""
        }

        # -FixDeps 模式：转发到 repair-deps.ps1
        if ($FixDeps) {
            Write-Log "INFO" "-FixDeps 模式：转发到 repair-deps.ps1"
            $repairScript = Join-Path $ScriptDir "repair-deps.ps1"
            if (Test-Path $repairScript) {
                $repairArgs = @("-File", $repairScript)
                if ($NonInteractive) { $repairArgs += "-NonInteractive" }
                if ($TestSafe) { $repairArgs += "-TestSafe" }
                if ($DryRun) { $repairArgs += "-DryRun" }
                & powershell.exe -NoProfile -ExecutionPolicy Bypass @repairArgs
            }
            else {
                Write-Error-Msg "找不到 repair-deps.ps1，请确认文件完整。"
            }
            exit 0
        }

        # 显示免责声明
        $agreed = Show-Disclaimer
        if (-not $agreed) {
            exit 0
        }

        if ($NonInteractive) {
            Write-Info "非交互模式：自动开始一键安装..."
            Start-LazyInstall
            return
        }

        # 显示主菜单
        Show-MainMenu
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
    finally {
        Stop-CcdiTranscriptSafe
    }
}

# 执行主流程
Main
