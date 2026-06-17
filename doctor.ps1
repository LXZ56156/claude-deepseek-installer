# ============================================================
# doctor.ps1 - Claude Code 环境诊断脚本
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\doctor.ps1
#
# 功能:
#   全面检测 Claude Code + DeepSeek 环境，生成诊断报告
#   适合用户在遇到问题时运行，将报告发给技术支持
# ============================================================

param(
    [switch]$SaveReport,   # 兼容旧参数：默认仍保存报告
    [switch]$NoSaveReport, # 不保存 report.txt，仅输出控制台摘要
    [switch]$SkipApiTest,  # 跳过 DeepSeek API 在线测试
    [switch]$NoOpenReport, # 不自动打开或选中诊断报告
    [switch]$ShareSafe,    # 生成脱敏版报告（替换用户名/路径，可安全分享）
    [switch]$Anonymize,    # ShareSafe 的别名
    [switch]$TestSafe,     # 测试安全模式：跳过真实网络请求、WSL 启动、claude doctor 等外部调用
    [switch]$DeepWslCheck, # 深度 WSL 检测：在检查 WSL 时启动 Ubuntu（含 wsl -d 等命令）
    [string]$OutputPath    # 报告输出路径，默认为当前目录 report.txt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }

. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")

# 控制台编码由 Initialize-CcdiScript -> Initialize-Logger ->
# Initialize-ConsoleEncodingSafe 统一处理。
# doctor.ps1 自身不直接设置控制台代码页，避免 Windows PowerShell 5.1 + conhost 中文叠字。
$ScriptDir = Initialize-CcdiScript -ScriptName "doctor"

$ScriptVersion = "1.3.3"

# 测试安全模式：显式 -TestSafe 参数或 CCDI_TEST_MODE 环境变量
$script:DoctorTestSafeMode = $TestSafe -or ($env:CCDI_TEST_MODE -eq "1")
if ($script:DoctorTestSafeMode) {
    $env:CCDI_TEST_MODE = "1"
}

# 报告状态集中放在脚本级对象中，避免函数作用域下 += 丢失内容。
$script:DoctorState = @{
    ReportLines  = New-Object System.Collections.ArrayList
    CheckResults = New-Object System.Collections.ArrayList
    Errors       = New-Object System.Collections.ArrayList
    Warnings     = New-Object System.Collections.ArrayList
    Suggestions  = New-Object System.Collections.ArrayList
}

function Add-ReportLine {
    param([string]$Line)
    [void]$script:DoctorState.ReportLines.Add($Line)
    Write-Log "DEBUG" "[Report] $Line"
}

function Add-Suggestion {
    param([string]$Message)
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        [void]$script:DoctorState.Suggestions.Add($Message)
    }
}

function Add-CheckResult {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )
    [void]$script:DoctorState.CheckResults.Add([PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    })

    switch ($Status) {
        "OK"   { Write-Result $Name "OK" $Detail }
        "WARN" {
            Write-Result $Name "WARN" $Detail
            [void]$script:DoctorState.Warnings.Add("${Name}: $Detail")
        }
        "ERROR"{
            Write-Result $Name "ERROR" $Detail
            [void]$script:DoctorState.Errors.Add("${Name}: $Detail")
        }
        "SKIP" { Write-Result $Name "SKIP" $Detail }
        "INFO" {
            Write-Result $Name "INFO" $Detail
            # INFO 不计入警告/错误，仅做信息提示
        }
    }
}

# ============================================================
# 报告头部
# ============================================================

function Write-ReportHeader {
    Add-ReportLine ("=" * 73)
    Add-ReportLine "  Claude Code 环境诊断报告"
    Add-ReportLine "  生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Add-ReportLine "  脚本版本: $ScriptVersion"
    Add-ReportLine ("=" * 73)
    Add-ReportLine ""
}

# ============================================================
# 1. 最低要求检查
# ============================================================

function Check-MinimumRequirements {
    Write-Step "诊断项目 1/8：最低要求检查"

    $minReq = Test-MinimumRequirements

    # Windows 版本
    $winInfo = $minReq.Details["Windows"]
    if ($winInfo.IsSupported) {
        $osLabel = if ($winInfo.IsWindows11) { "Windows 11" } else { "Windows 10" }
        Add-CheckResult "Windows 版本" "OK" "$osLabel (Build $($winInfo.Build))"
    }
    else {
        if ($winInfo.IsWindows10) {
            Add-CheckResult "Windows 版本" "ERROR" "$($winInfo.Version) (Build $($winInfo.Build) < 17763)"
            Add-Suggestion "Windows 10 Build 需要 >= 17763 (1809)。请通过 Windows Update 升级系统，或升级到 Windows 11。"
        }
        else {
            Add-CheckResult "Windows 版本" "ERROR" "不支持的操作系统: $($winInfo.Version)"
            Add-Suggestion "需要 Windows 10 1809+ 或 Windows 11。当前系统版本不满足要求。"
        }
    }

    # 系统架构
    $archInfo = $minReq.Details["Architecture"]
    if ($archInfo.IsSupported) {
        Add-CheckResult "系统架构" "OK" $archInfo.Architecture
    }
    else {
        Add-CheckResult "系统架构" "ERROR" "$($archInfo.Architecture) - 需要 x64 或 ARM64"
        Add-Suggestion "当前系统架构不支持。Claude Code 需要 64 位系统（x64 或 ARM64）。"
    }

    # 物理内存
    $memInfo = $minReq.Details["Memory"]
    if ($memInfo.IsSufficient) {
        Add-CheckResult "物理内存" "OK" "$($memInfo.TotalGB) GB（满足 >= 4GB 要求）"
    }
    else {
        Add-CheckResult "物理内存" "ERROR" "$($memInfo.TotalGB) GB（需要 4GB 以上）"
        Add-Suggestion "物理内存不足 4GB。请关闭其他程序释放内存，或考虑升级硬件。"
    }

    # PowerShell 版本
    $psInfo = $minReq.Details["PowerShell"]
    if ($psInfo.IsSupported) {
        Add-CheckResult "PowerShell" "OK" "$($psInfo.Version)"
    }
    else {
        Add-CheckResult "PowerShell" "ERROR" "$($psInfo.Version) - 需要 5.1+"
        Add-Suggestion "PowerShell 版本过低。请从 https://aka.ms/PSWindows 升级。"
    }

    # PowerShell 进程架构（32/64 bit）
    $archInfo = $minReq.Details["Architecture"]
    if ($archInfo.IsWow64PowerShell) {
        Add-CheckResult "PowerShell 进程架构" "ERROR" "当前为 32-bit PowerShell，但系统是 64-bit Windows"
        Add-Suggestion "当前打开的是 32 位 PowerShell。请关闭本窗口，重新双击 00-点我开始安装.cmd，或打开普通 Windows PowerShell，不要打开 Windows PowerShell (x86)。"
    }
    elseif ($archInfo.Is64BitProcess) {
        Add-CheckResult "PowerShell 进程架构" "OK" "64-bit"
    }
    else {
        Add-CheckResult "PowerShell 进程架构" "OK" "32-bit (32-bit OS)"
    }

    # 总体最低要求判断
    if ($minReq.IsSupported) {
        Add-CheckResult "最低要求" "OK" "满足安装的最低系统要求"
    }
    else {
        Add-CheckResult "最低要求" "ERROR" "不满足（错误数: $($minReq.Errors.Count)）"
        $totalErrors = $minReq.Errors.Count
        Add-Suggestion "共有 $totalErrors 项不满足最低要求。请逐项解决后重新检测。"
    }
}

# ============================================================
# 2. 系统信息
# ============================================================

function Check-SystemInfo {
    Write-Step "诊断项目 2/8：系统信息"

    $winInfo = Get-WindowsVersionInfo
    Add-CheckResult "Windows 版本" $(if ($winInfo.IsSupported) { "OK" } else { "ERROR" }) "$($winInfo.Version) (Build $($winInfo.Build))"

    $psInfo = Get-PowerShellVersionInfo
    Add-CheckResult "PowerShell 版本" $(if ($psInfo.IsSupported) { "OK" } else { "ERROR" }) "$($psInfo.Version) ($($psInfo.Edition))"

    Add-CheckResult "用户目录" "OK" (Get-UserProfilePath)

    $policy = Get-ExecutionPolicyInfo
    Add-CheckResult "执行策略" "OK" "$policy"

    if (Test-IsAdministrator) {
        Add-CheckResult "管理员权限" "WARN" "当前以管理员权限运行（非必须）"
        Add-Suggestion "建议以普通用户权限运行，本工具不需要管理员权限。"
    }
    else {
        Add-CheckResult "管理员权限" "OK" "普通用户（推荐）"
    }

    # TLS 设置摘要
    try {
        $tlsText = [Net.ServicePointManager]::SecurityProtocol.ToString()
        Add-CheckResult "TLS 设置" "INFO" $tlsText
    }
    catch {
        Add-CheckResult "TLS 设置" "INFO" "无法读取 TLS 设置"
    }
}

# ============================================================
# 2. 命令检测
# ============================================================

function Check-Commands {
    Write-Step "诊断项目 3/8：命令检测"

    # --- 先判断 Native Install 是否已成功（用于后续 Node/npm 分级）---
    $nativeClaudeExe = Get-NativeClaudeExePath
    $nativeBinPath = Get-NativeClaudeBinPath
    $nativeExeExists = Test-Path $nativeClaudeExe
    $nativePathOk = $false
    if ($nativeExeExists) {
        $nativePathCheck = Test-UserPathContains -TargetPath $nativeBinPath
        $nativePathOk = $nativePathCheck.Contains
    }
    # 初步判断 Native Install 可用：文件存在 + PATH 已配
    $isNativeInstallLikely = $nativeExeExists -and $nativePathOk

    # Node.js 检测
    $nodeInfo = Test-NodeJsInstalled
    if ($nodeInfo.IsSupported) {
        Add-CheckResult "Node.js" "OK" $nodeInfo.Version
    }
    elseif ($nodeInfo.Installed) {
        Add-CheckResult "Node.js" "ERROR" "版本 $($nodeInfo.Version) - 需要 >= 18"
        Add-Suggestion "当前 Node.js 版本为 $($nodeInfo.Version)，Claude Code 需要 v18 或更高版本。请升级 Node.js 后重试。"
    }
    else {
        if ($isNativeInstallLikely) {
            Add-CheckResult "Node.js" "INFO" "未安装；当前为 Native Install，已不影响 Claude Code 基础使用，仅影响 npm 备用安装/部分开发工具"
        }
        else {
            Add-CheckResult "Node.js" "ERROR" $nodeInfo.ErrorMessage
            Add-Suggestion "Node.js 未安装。Claude Code 需要 Node.js 18+。请从 https://nodejs.org 下载安装 LTS 版本。"
        }
    }

    # npm 检测
    $npmInfo = Test-NpmInstalled
    if ($npmInfo.Installed) {
        Add-CheckResult "npm" "OK" $npmInfo.Version
    }
    else {
        if ($isNativeInstallLikely) {
            Add-CheckResult "npm" "INFO" "未安装；当前为 Native Install，已不影响 Claude Code 基础使用，仅影响 npm 备用安装"
        }
        else {
            Add-CheckResult "npm" "ERROR" $npmInfo.ErrorMessage
            Add-Suggestion "npm 未找到。请检查 Node.js 安装是否完整，或重新安装 Node.js。"
        }
    }

    $gitVersion = Test-GitInstalled
    if ($gitVersion) {
        Add-CheckResult "Git" "OK" $gitVersion
    }
    else {
        Add-CheckResult "Git" "WARN" "未安装"
        Add-Suggestion "Git 不是安装 Claude Code 的硬性要求，但推荐安装。部分 Bash/Shell 体验、项目操作、Git 仓库功能会更完整。可从 https://git-scm.com 下载安装。"
    }

    $codeVersion = Test-CodeInstalled
    if ($codeVersion) {
        Add-CheckResult "VS Code (code)" "OK" ($codeVersion.Split("`n")[0])
    }
    else {
        Add-CheckResult "VS Code (code)" "WARN" "code 命令不在 PATH 中"
        Add-Suggestion "在 VS Code 中按 Ctrl+Shift+P，搜索并执行 'Shell Command: Install code command in PATH'。"
    }
    # WSL 检测已统一移至 Check-WSL（避免全流程两次 wsl --version 探测），此处不提前调用
    # --- Claude Code 安装文件检测 (v1.3.3 P0-4: 区分 native/npm 安装来源) ---
    $nativeClaudeExe = Get-NativeClaudeExePath
    $nativeBinPath = Get-NativeClaudeBinPath
    $nativeExeExists = Test-Path $nativeClaudeExe

    $npmClaudePath = $null
    $npmGlobalBin = $null
    if ($env:APPDATA) {
        $npmGlobalBin = Join-Path $env:APPDATA "npm"
        $npmClaudePath = Join-Path $npmGlobalBin "claude.cmd"
    }
    $npmExeExists = ($npmClaudePath -and (Test-Path $npmClaudePath))

    $anyClaudeInstallExists = $nativeExeExists -or $npmExeExists

    if ($nativeExeExists) {
        Add-CheckResult "Claude Code 安装文件" "OK" $nativeClaudeExe
    }
    elseif ($npmExeExists) {
        Add-CheckResult "Claude Code 安装文件" "OK" $npmClaudePath
    }
    else {
        Add-CheckResult "Claude Code 安装文件" "WARN" "未找到 claude 安装文件"
    }

    # --- User PATH 检测 (v1.3.3 P0-4: 区分 native/npm 安装来源) ---
    if ($nativeExeExists) {
        $nativePathCheck = Test-UserPathContains -TargetPath $nativeBinPath
        if ($nativePathCheck.Contains) {
            Add-CheckResult "User PATH" "OK" "已包含 Native Install 目录: $nativeBinPath"
        }
        else {
            Add-CheckResult "User PATH" "ERROR" "未包含 Native Install 目录，普通 PowerShell 可能无法直接运行 claude"
            Add-Suggestion "请运行「一键修复依赖」或手动将以下路径加入 User PATH：$nativeBinPath"
        }
    }
    elseif ($npmExeExists) {
        $npmPathCheck = Test-UserPathContains -TargetPath $npmGlobalBin
        if ($npmPathCheck.Contains) {
            Add-CheckResult "User PATH" "OK" "已包含 npm 全局目录: $npmGlobalBin"
        }
        else {
            Add-CheckResult "User PATH" "ERROR" "未包含 npm 全局目录，普通 PowerShell 可能无法直接运行 claude"
            Add-Suggestion "请将以下路径加入 User PATH：$npmGlobalBin"
        }
    }
    else {
        Add-CheckResult "User PATH" "INFO" "未检测到 Claude Code 安装文件，跳过 PATH 安装目录检查"
    }

    # --- Claude Code CLI + 命令来源（只调用一次 Get-ClaudeCommandInventory）---
    $inventory = $null
    $claudeCliOk = $false  # v1.3.3 P5: 跟踪 CLI 是否 OK，用于分级 命令来源
    try {
        $inventory = Get-ClaudeCommandInventory
    }
    catch {
        Write-Log "WARN" "Get-ClaudeCommandInventory 调用失败: $_"
        # $inventory 保持 $null，后续走 fallback
    }

    # Claude Code CLI 判断：优先使用 inventory
    if ($inventory -and $inventory.Active -and $inventory.Active.Usable) {
        $claudeCliOk = $true
        Add-CheckResult "Claude Code CLI" "OK" $inventory.Active.Version

        # claude doctor 不自动运行
        Add-CheckResult "claude doctor" "INFO" "未自动运行（Claude Code doctor 在脚本/重定向环境中不会稳定输出；请按需手动运行）"
        Add-Suggestion "如需 Claude Code 官方诊断，请打开新的 PowerShell 或 Windows Terminal，手动输入：claude doctor。不要通过脚本、管道或重定向运行。运行后请截图，截图前请确认没有完整 API Key。"
    }
    elseif ($inventory -and $inventory.Candidates.Count -gt 0) {
        $usableCount = @($inventory.Candidates | Where-Object { $_.Usable }).Count
        if ($usableCount -gt 0) {
            Add-CheckResult "Claude Code CLI" "WARN" "当前 PATH 命中的 claude 不可用，但检测到其他可用 Claude Code。请查看 Claude 命令来源。"

            Add-CheckResult "claude doctor" "INFO" "未自动运行（Claude Code doctor 在脚本/重定向环境中不会稳定输出；请按需手动运行）"
        }
        else {
            Add-CheckResult "Claude Code CLI" "ERROR" "claude 命令存在但不可用"
            Add-Suggestion "检测到 claude 文件但无法运行，可能是残留 shim、损坏安装或 PATH 冲突。请运行「一键修复依赖.cmd」或查看 Claude 命令来源。"
        }
    }
    else {
        # inventory 不可用或没有候选，fallback 到旧检测
        $claudeVersion = Test-ClaudeInstalled
        if ($claudeVersion) {
            $claudeCliOk = $true
            Add-CheckResult "Claude Code CLI" "OK" $claudeVersion

            Add-CheckResult "claude doctor" "INFO" "未自动运行（Claude Code doctor 在脚本/重定向环境中不会稳定输出；请按需手动运行）"
            Add-Suggestion "如需 Claude Code 官方诊断，请打开新的 PowerShell 或 Windows Terminal，手动输入：claude doctor。不要通过脚本、管道或重定向运行。运行后请截图，截图前请确认没有完整 API Key。"
        }
        else {
            Add-CheckResult "Claude Code CLI" "ERROR" "claude 命令未找到或不可用"
            Add-Suggestion "未检测到 claude 命令。可能是安装失败，或 npm 全局 bin 路径未加入 PATH。请运行 install.ps1 安装，或关闭重开终端。"
        }
    }

    # --- Fresh Shell claude 检测 (v1.3.3 P0-4: 区分安装来源 + P0-3 降级误判) ---
    try {
        $freshShellCheck = Test-ClaudeCommandInFreshShell
        if ($freshShellCheck.Success) {
            Add-CheckResult "Fresh PowerShell claude" "OK" $freshShellCheck.Output
        }
        else {
            if ($anyClaudeInstallExists) {
                # v1.3.3 P0-3: 如果 native exe 存在且 User PATH 已就绪，fresh shell 失败不应判定为 ERROR
                if ($nativeExeExists -and $nativePathOk) {
                    Add-CheckResult "Fresh PowerShell claude" "WARN" "自动验证未通过，但 Claude Code 文件和 PATH 均已就绪。请新开 PowerShell 手动执行 claude --version；如能显示版本号，则可以正常使用。"
                    Add-Suggestion "关闭当前窗口并重新打开 PowerShell，输入 claude --version 手动验证。如果手动验证成功，则无需修复。如仍失败，再运行「一键修复依赖」或「一键诊断」。"
                }
                else {
                    Add-CheckResult "Fresh PowerShell claude" "ERROR" "新 PowerShell 中无法识别 claude 命令"
                    Add-Suggestion "Claude Code 安装文件存在，但 fresh shell 中 claude 不可用。请运行「一键修复依赖」修复 PATH。"
                }
            }
            else {
                Add-CheckResult "Fresh PowerShell claude" "INFO" "未检测到 Claude Code 安装文件，跳过 fresh shell 验证"
            }
        }
    }
    catch {
        Write-Log "WARN" "Fresh Shell 验证异常: $_"
        Add-CheckResult "Fresh PowerShell claude" "WARN" "验证过程中出现异常，已跳过"
    }

    # Claude 命令来源诊断（复用 $inventory）
    if ($inventory) {
        if ($inventory.Candidates.Count -eq 0) {
            Add-CheckResult "Claude 命令来源" "WARN" "未找到任何 claude 命令候选"
        }
        else {
            Add-CheckResult "Claude 命令来源" "INFO" "检测到 $($inventory.Candidates.Count) 个候选"

            # Active claude
            if ($inventory.Active) {
                $activePathSafe = Sanitize-PathForReport -Text $inventory.Active.Path
                $activeStatus = if ($inventory.Active.Usable -and $inventory.Active.Risk -in @("OK", "INFO")) { "OK" }
                elseif ($inventory.Active.Usable) { "WARN" }
                elseif ($inventory.Active.Source -eq "windowsapps") { "WARN" }
                else { "ERROR" }
                Add-CheckResult "当前 claude 来源" $activeStatus "Source=$($inventory.Active.Source), Usable=$($inventory.Active.Usable), Path=$activePathSafe"
            }

            # 候选列表（最多 8 个，只输出 Exists=true 的 Candidates）
            $maxShow = [Math]::Min($inventory.Candidates.Count, 8)
            for ($i = 0; $i -lt $maxShow; $i++) {
                $c = $inventory.Candidates[$i]
                $pathSafe = Sanitize-PathForReport -Text $c.Path
                $candidateName = "claude 候选 $($i + 1)"
                $candidateDetail = "Source=$($c.Source), Risk=$($c.Risk), Usable=$($c.Usable)"
                if ($c.Version) { $candidateDetail += ", Version=$($c.Version)" }
                $candidateDetail += ", Path=$pathSafe"
                if ($c.Error) {
                    $errSafe = Sanitize-PathForReport -Text $c.Error
                    $candidateDetail += ", Error=$errSafe"
                }
                Add-CheckResult $candidateName "INFO" $candidateDetail
            }

            # 冲突检测
            if ($inventory.HasConflict) {
                Add-CheckResult "Claude 命令冲突" "WARN" $inventory.ConflictSummary
                Add-Suggestion "检测到多个 claude 命令来源。建议优先保留官方 Native Install 或 npm 全局安装中的一种，避免 WindowsApps/旧 shim 抢占。"
            }

            # Active 不可用但存在其他可用候选
            if ($inventory.Active -and -not $inventory.Active.Usable) {
                $usableOthers = $inventory.Candidates | Where-Object { $_.Usable -and $_.Path -ne $inventory.Active.Path }
                if ($usableOthers) {
                    Add-Suggestion "当前 PATH 优先级异常：前面的 claude 不可用，但其他路径存在可用 claude。请关闭终端重开，或调整 PATH 后重试。"
                }
            }
        }
    }
    else {
        # inventory 调用失败
        if ($claudeCliOk) {
            Add-CheckResult "Claude 命令来源" "INFO" "命令来源详情收集不完整，不影响当前使用"
        }
        else {
            Add-CheckResult "Claude 命令来源" "WARN" "无法收集 Claude 命令来源信息"
        }
    }

    # npm 安装风险配置检测
    try {
        $npmRisk = Get-NpmInstallRiskConfig
        if ($npmRisk) {
            if ($npmRisk.Registry) {
                Add-CheckResult "npm registry" "INFO" $npmRisk.Registry
            }
            else {
                Add-CheckResult "npm registry" "INFO" "未获取到 registry 配置"
            }

            $optionalStatus = if ($npmRisk.Optional -eq "false") { "WARN" } else { "OK" }
            Add-CheckResult "npm optional" $optionalStatus $(if ($npmRisk.Optional) { $npmRisk.Optional } else { "(默认)" })

            $omitStatus = if ($npmRisk.Omit -match "optional") { "WARN" } else { "INFO" }
            Add-CheckResult "npm omit" $omitStatus $(if ($npmRisk.Omit) { $npmRisk.Omit } else { "(默认)" })

            $ignoreScriptsStatus = if ($npmRisk.IgnoreScripts -eq "true") { "WARN" } else { "OK" }
            Add-CheckResult "npm ignore-scripts" $ignoreScriptsStatus $(if ($npmRisk.IgnoreScripts) { $npmRisk.IgnoreScripts } else { "(默认)" })

            if ($npmRisk.Warnings.Count -gt 0) {
                Add-CheckResult "npm 安装风险配置" "WARN" ($npmRisk.Warnings -join "；")
                foreach ($w in $npmRisk.Warnings) {
                    Add-Suggestion $w
                }
            }
            else {
                Add-CheckResult "npm 安装风险配置" "OK" "未发现 optional/scripts 风险配置"
            }
        }
    }
    catch {
        Write-Log "WARN" "Get-NpmInstallRiskConfig 调用失败: $_"
        # 不阻塞诊断流程
    }
}

# ============================================================
# 3. 文件检测
# ============================================================

function Check-Files {
    Write-Step "诊断项目 4/8：配置文件检测"

    $configPath = Get-ClaudeConfigFile
    $configDir = Get-ClaudeConfigDir

    if (Test-Path $configDir) {
        Add-CheckResult "Claude 配置目录" "OK" $configDir
    }
    else {
        Add-CheckResult "Claude 配置目录" "WARN" "目录不存在"
        Add-Suggestion "Claude 配置目录不存在。请运行 install.ps1 并选择配置 DeepSeek API。"
    }

    $configInfo = Test-ClaudeConfigExists
    if ($configInfo.Exists) {
        if ($configInfo.IsValid) {
            Add-CheckResult "settings.json" "OK" "存在且格式有效"

            # 检查具体字段
            $config = Read-ClaudeConfig
            if ($config) {
                $configProps = @(Get-JsonPropertyNamesSafe -Object $config)
                if ($configProps -contains "env") {
                    $env = $config.env
                    $envProps = @(Get-JsonPropertyNamesSafe -Object $env)
                    Add-CheckResult "env 字段" "OK" "存在 ($($envProps.Count) 个变量)"

                    # 检查关键字段

                    if ($envProps -contains "ANTHROPIC_BASE_URL") {
                        $baseUrl = $env.ANTHROPIC_BASE_URL
                        if ($baseUrl -match "api.deepseek.com") {
                            Add-CheckResult "ANTHROPIC_BASE_URL" "OK" $baseUrl
                        }
                        else {
                            Add-CheckResult "ANTHROPIC_BASE_URL" "WARN" "URL 不是 DeepSeek 官方地址: $baseUrl"
                            Add-Suggestion "ANTHROPIC_BASE_URL 不是 DeepSeek 官方地址，请检查。"
                        }
                    }
                    else {
                        Add-CheckResult "ANTHROPIC_BASE_URL" "ERROR" "字段缺失"
                        Add-Suggestion "缺少 ANTHROPIC_BASE_URL 配置，请运行 configure-deepseek.ps1。"
                    }

                    if ($envProps -contains "ANTHROPIC_AUTH_TOKEN") {
                        $token = $env.ANTHROPIC_AUTH_TOKEN
                        $masked = Mask-ApiKey -Key $token
                        if ([string]::IsNullOrWhiteSpace($token)) {
                            Add-CheckResult "ANTHROPIC_AUTH_TOKEN" "ERROR" "Key 为空"
                            Add-Suggestion "API Key 为空，请运行 configure-deepseek.ps1 设置。"
                        }
                        else {
                            Add-CheckResult "ANTHROPIC_AUTH_TOKEN" "OK" "已设置 ($masked)"
                        }
                    }
                    else {
                        Add-CheckResult "ANTHROPIC_AUTH_TOKEN" "ERROR" "字段缺失"
                        Add-Suggestion "缺少 API Key 配置，请运行 configure-deepseek.ps1。"
                    }

                    # 检查模型配置
                    if ($envProps -contains "ANTHROPIC_MODEL") {
                        Add-CheckResult "ANTHROPIC_MODEL" "OK" $env.ANTHROPIC_MODEL
                    }
                    else {
                        Add-CheckResult "ANTHROPIC_MODEL" "WARN" "未设置（将使用 DeepSeek 默认模型）"
                    }

                    if ($envProps -contains "ANTHROPIC_SMALL_FAST_MODEL") {
                        Add-CheckResult "ANTHROPIC_SMALL_FAST_MODEL" "OK" $env.ANTHROPIC_SMALL_FAST_MODEL
                    }
                    else {
                        Add-CheckResult "ANTHROPIC_SMALL_FAST_MODEL" "INFO" "未设置时将使用默认逻辑；如需稳定体验，可设置 ANTHROPIC_SMALL_FAST_MODEL"
                    }
                }
                else {
                    Add-CheckResult "env 字段" "ERROR" "settings.json 缺少 env 字段"
                    Add-Suggestion "配置文件缺少 env 字段，请运行 configure-deepseek.ps1。"
                }
            }
        }
        else {
            Add-CheckResult "settings.json" "ERROR" "JSON 格式无效！"
            Add-Suggestion "settings.json 格式无效。已自动备份，请运行 configure-deepseek.ps1 重建。"
        }
    }
    else {
        Add-CheckResult "settings.json" "WARN" "配置文件不存在"
        Add-Suggestion "配置文件不存在，请运行 install.ps1 并选择配置 DeepSeek API。"
    }

    # Claude downloads 缓存目录
    $downloadsDir = Join-Path (Join-Path (Get-UserProfilePath) ".claude") "downloads"
    if (Test-Path $downloadsDir) {
        Add-CheckResult "Claude downloads 缓存" "INFO" "目录存在；如 Native Install 报文件占用，可关闭相关进程后删除该 downloads 目录。"
    }
    else {
        Add-CheckResult "Claude downloads 缓存" "INFO" "未发现残留 downloads 目录"
    }
}

# ============================================================
# 4. 网络检测
# ============================================================

function Check-Network {
    Write-Step "诊断项目 5/8：网络检测"

    if ($script:DoctorTestSafeMode) {
        Write-Info "测试安全模式：跳过真实网络请求。"
        Add-CheckResult "网络检测" "SKIP" "测试安全模式已跳过真实网络请求"
        return
    }

    # DNS 检测
    try {
        if (Test-CommandAvailable -CommandName "Resolve-DnsName") {
            $null = Resolve-DnsName "api.deepseek.com" -ErrorAction Stop
        }
        else {
            $null = [System.Net.Dns]::GetHostAddresses("api.deepseek.com")
        }
        Add-CheckResult "DNS: api.deepseek.com" "OK" "解析成功"
    }
    catch {
        Add-CheckResult "DNS: api.deepseek.com" "ERROR" "DNS 解析失败"
        Add-Suggestion "DNS 无法解析 api.deepseek.com。请检查网络/DNS 设置，尝试更换 DNS 服务器。"
    }

    # HTTP 连通性
    $netDeepSeek = Test-NetworkConnectivity -Url "https://api.deepseek.com"
    if ($netDeepSeek.Reachable) {
        Add-CheckResult "HTTPS: api.deepseek.com" "OK" "可访问 (状态码 $($netDeepSeek.StatusCode), 延迟 $($netDeepSeek.LatencyMs)ms)"
    }
    else {
        $errDetail = $netDeepSeek.Error
        Add-CheckResult "HTTPS: api.deepseek.com" "ERROR" $errDetail

        if ($netDeepSeek.Error -match "DNS") {
            Add-Suggestion "DNS 解析失败，请检查网络配置或尝试更换 DNS。"
        }
        elseif ($netDeepSeek.Error -match "超时") {
            Add-Suggestion "连接超时，请检查网络/防火墙/代理设置。"
        }
        elseif ($netDeepSeek.Error -match "ConnectFailure|无法连接到服务器") {
            Add-Suggestion "无法连接到 api.deepseek.com，可能被防火墙阻止或需要代理。"
        }
        else {
            Add-Suggestion "网络连接失败: $errDetail。请检查网络设置。"
        }
    }

    # downloads.claude.ai 轻量检测
    $netDownloads = Test-NetworkConnectivity -Url "https://downloads.claude.ai" -TimeoutSec 10
    if ($netDownloads.Reachable) {
        Add-CheckResult "HTTPS: downloads.claude.ai" "OK" "可访问 (状态码 $($netDownloads.StatusCode))"
    }
    else {
        Add-CheckResult "HTTPS: downloads.claude.ai" "WARN" "$($netDownloads.Error)"
        $deepSeekReachable = $netDeepSeek.Reachable
        if ($deepSeekReachable) {
            Add-Suggestion "Claude 官方下载通道不可达，但 DeepSeek API 可达。这通常只影响 Claude Code 下载，不代表 DeepSeek 配置不可用。"
        }
    }

    # 代理环境变量检测（Process / User / Machine 三层）
    $proxyVars = @("HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY")
    foreach ($var in $proxyVars) {
        $value = [Environment]::GetEnvironmentVariable($var, "Process")
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($var, "User") }
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($var, "Machine") }

        if ($value) {
            Add-CheckResult "代理环境变量 $var" "INFO" (Sanitize-ProxyUrl -Text $value)
        }
    }

    # WinHTTP 代理
    $winhttp = Invoke-CommandSafe -Command "netsh" -Arguments @("winhttp", "show", "proxy") -TimeoutSec 8
    if ($winhttp.Success) {
        Add-CheckResult "WinHTTP 代理" "INFO" (Sanitize-ProxyUrl -Text (Normalize-ExternalCommandOutput -Text $winhttp.Output -MaxLength 1000))
    }
    else {
        Add-CheckResult "WinHTTP 代理" "INFO" "无法读取或未配置"
    }
}

# ============================================================
# 5. DeepSeek API 测试
# ============================================================

function Check-DeepSeekApi {
    Write-Step "诊断项目 6/8：DeepSeek API 测试（Anthropic Format）"

    if ($SkipApiTest) {
        Add-CheckResult "DeepSeek API 测试" "SKIP" "已按参数跳过"
        Add-Suggestion "本次诊断跳过了在线 API 测试。如需验证 Key 和连接，请不带 -SkipApiTest 重新运行 doctor.ps1。"
        return
    }

    # 从配置读取 API Key
    $apiKey = Get-ApiKeyFromConfig

    if (-not $apiKey) {
        Add-CheckResult "API Key" "ERROR" "未从配置文件中读取到 API Key"
        Add-Suggestion "无法读取 API Key。请运行 configure-deepseek.ps1 重新设置。"
        return
    }

    $masked = Mask-ApiKey -Key $apiKey
    Add-CheckResult "API Key" "OK" "已设置 ($masked)"

    # 读取 Base URL 和模型
    $config = Read-ClaudeConfig
    $baseUrl = "https://api.deepseek.com/anthropic"
    $testModel = "deepseek-v4-flash"
    if ($config -and $config.env) {
        $envProps = @(Get-JsonPropertyNamesSafe -Object $config.env)
        if ($envProps -contains "ANTHROPIC_BASE_URL") {
            $baseUrl = $config.env.ANTHROPIC_BASE_URL
        }
        if ($envProps -contains "ANTHROPIC_SMALL_FAST_MODEL") {
            $testModel = $config.env.ANTHROPIC_SMALL_FAST_MODEL
        }
    }

    Write-Info "正在测试 Anthropic Format 接口..."
    Write-Info "  Endpoint: $baseUrl/messages"
    Write-Info "  模型: $testModel"

    $apiTest = Test-DeepSeekApiAnthropic -ApiKey $apiKey -BaseUrl $baseUrl -Model $testModel

    if ($apiTest.Success) {
        Add-CheckResult "Anthropic Format smoke test" "OK" "200 OK - 模型返回: $($apiTest.Content)"
    }
    else {
        $statusMsg = if ($apiTest.StatusCode -gt 0) { "HTTP $($apiTest.StatusCode)" } else { "网络失败" }
        Add-CheckResult "Anthropic Format smoke test" "ERROR" "$statusMsg - $($apiTest.Error)"

        if ($apiTest.Suggestion) {
            Add-Suggestion $apiTest.Suggestion
        }

        switch ($apiTest.StatusCode) {
            401 {
                Add-Suggestion "请到 platform.deepseek.com 重新获取正确的 API Key。确认 Key 是否完整、是否有多余空格、是否已删除。"
            }
            402 {
                Add-Suggestion "请到 platform.deepseek.com 检查余额和计费状态。"
            }
            404 {
                Add-Suggestion "请检查 DeepSeek 官方文档确认当前支持的模型名。当前使用模型: $testModel。"
            }
            429 {
                Add-Suggestion "请求被限流。请稍等几分钟再试，或到 platform.deepseek.com 检查使用限制。"
            }
        }
    }
}

# ============================================================
# 6. VS Code 检测
# ============================================================

function Check-VSCode {
    Write-Step "诊断项目 7/8：VS Code 检测"

    $codeVersion = Test-CodeInstalled
    if ($codeVersion) {
        Add-CheckResult "code 命令" "OK" ($codeVersion.Split("`n")[0])

        $extInstalled = Test-VSCodeExtensionInstalled
        if ($extInstalled) {
            Add-CheckResult "Claude Code VS Code 扩展" "OK" "已安装"
        }
        else {
            Add-CheckResult "Claude Code VS Code 扩展" "INFO" "未安装；仅影响 VS Code 内联体验，不影响终端使用"
            # 不计入核心警告，使用 INFO 级别
            Add-Suggestion "需要 VS Code 内联体验时可安装扩展（Ctrl+Shift+X → 搜索 'Claude Code'）；只用终端则无需处理。"
        }
    }
    else {
        Add-CheckResult "code 命令" "WARN" "不在 PATH 中"
        Add-Suggestion "在 VS Code 中按 Ctrl+Shift+P → 输入 'shell command' → 选择 'Install code command in PATH'。"
    }
}

# ============================================================
# 7. WSL 检测
# ============================================================

function Check-WSL {
    Write-Step "诊断项目 8/8：WSL 检测"

    if ($script:DoctorTestSafeMode) {
        Write-Info "测试安全模式：不启动 WSL，跳过 WSL 检测。"
        Add-CheckResult "WSL 检测" "SKIP" "测试安全模式不启动 WSL"
        return
    }

    $wslInfo = Test-WslInstalled
    if (-not $wslInfo.Installed) {
        Add-CheckResult "WSL" "SKIP" "未启用"
        return
    }

    $wslVersion = $wslInfo.Version.Split("`n")[0]
    Add-CheckResult "WSL" "OK" $wslVersion

    $distroList = ($wslInfo.Distributions | ForEach-Object {
        $marker = if ($_.Default) { "*" } else { " " }
        $state = if ($_.Running) { "Running" } else { "Stopped" }
        "$marker $($_.Name) ($state)"
    }) -join "; "
    Add-CheckResult "WSL 发行版" "OK" $distroList
    Add-CheckResult "WSL 状态" "OK" "已启用"

    $ubuntuInfo = Test-UbuntuInWsl -WslInfo $wslInfo
    if (-not $ubuntuInfo.Exists) {
        Add-CheckResult "Ubuntu" "WARN" "未安装 Ubuntu 发行版"
        Add-Suggestion "如需在 WSL 中使用 Claude Code，请运行: wsl --install -d Ubuntu"
        return
    }

    $ubuntuDistroName = if ($ubuntuInfo.Name) { $ubuntuInfo.Name } else { "Ubuntu" }
    $stateText = if ($ubuntuInfo.Running) { "Running" } else { "已停止" }
    Add-CheckResult "Ubuntu ($ubuntuDistroName)" "OK" $stateText

    # 如果 Ubuntu 未运行且未传 -DeepWslCheck，不启动 WSL
    if (-not $ubuntuInfo.Running -and -not $DeepWslCheck) {
        Add-CheckResult "Ubuntu 可启动" "INFO" "未执行深度启动检测；如需检测请运行 doctor.ps1 -DeepWslCheck"
        Add-Suggestion "WSL 是高级选项，不影响 Windows 原生安装。"
        return
    }

    # DeepWslCheck 模式下，如果 Ubuntu 未运行则尝试临时启动
    if ($DeepWslCheck -and -not $ubuntuInfo.Running) {
        Write-Info "Ubuntu ($ubuntuDistroName) 当前未运行，深度检测将临时启动 WSL 执行只读检测..."
        $wslStartCheck = Invoke-CommandSafe -Command "wsl" -Arguments @(
            "-d", $ubuntuDistroName, "bash", "-c", "echo 'WSL_START_OK'"
        ) -TimeoutSec 15
        if (-not $wslStartCheck.Success -or $wslStartCheck.Output -notmatch "WSL_START_OK") {
            Add-CheckResult "Ubuntu 可启动" "WARN" "发行版 $ubuntuDistroName 当前未运行且无法临时启动"
            Add-Suggestion "请手动运行 'wsl -d $ubuntuDistroName' 启动后重新诊断。"
            return
        }
    }

    # 只有 $DeepWslCheck 为 true 时才执行深度检测
    if (-not $DeepWslCheck) {
        return
    }

    # 检查 WSL 内的 Claude 状态（使用综合检测，传入发行版名称）
    Write-Info "正在检查 WSL 内 Claude Code 状态（多路径综合检测）..."
    $wslClaude = Test-WslClaudeComprehensive -DistroName $ubuntuDistroName

    # 获取 Windows 原生 Claude 安装信息
    $winClaudeVer = Test-ClaudeInstalled

    switch ($wslClaude.Status) {
        "installed_and_in_path" {
            Add-CheckResult "WSL: claude" "OK" "WSL 内已安装且可在 PATH 中调用"
            if ($wslClaude.Version) {
                Add-CheckResult "WSL: claude 版本" "OK" $wslClaude.Version
            }
            if ($winClaudeVer) {
                Add-CheckResult "WSL vs Windows" "INFO" "Windows 原生 Claude Code 也已安装 ($winClaudeVer)；WSL 和 Windows 是不同运行环境"
            }
        }
        "installed_but_not_in_path" {
            Add-CheckResult "WSL: claude" "WARN" "Claude Code 已安装但未加入 PATH"
            if ($wslClaude.InstallPaths.Count -gt 0) {
                $firstPath = $wslClaude.InstallPaths[0]
                $binDir = Split-Path -Parent $firstPath
                Add-CheckResult "WSL: claude 路径" "INFO" "找到: $firstPath"
                Add-Suggestion "WSL 内 Claude Code 已安装但 PATH 未配置。修复方式: echo 'export PATH=`"${binDir}:`$PATH`"' >> ~/.bashrc && source ~/.bashrc"
            }
            if ($winClaudeVer) {
                Add-CheckResult "Windows 原生" "INFO" "Windows 原生 Claude Code 可用 ($winClaudeVer)"
            }
        }
        "found_but_not_executable" {
            Add-CheckResult "WSL: claude" "WARN" "找到 claude 文件但不可执行"
            if ($wslClaude.InstallPaths.Count -gt 0) {
                Add-CheckResult "WSL: claude 路径" "INFO" "找到: $($wslClaude.InstallPaths[0])（不可执行）"
                Add-Suggestion "文件权限不足。修复方式: chmod +x $($wslClaude.InstallPaths[0])"
            }
            if ($winClaudeVer) {
                Add-CheckResult "Windows 原生" "INFO" "Windows 原生 Claude Code 可用 ($winClaudeVer)"
            }
        }
        "not_installed" {
            if ($wslClaude.SettingsExists) {
                Add-CheckResult "WSL: claude" "WARN" "WSL 已有 Claude 配置，但 WSL 内暂未检测到可运行的 claude 命令"
                Add-Suggestion "WSL 中 settings.json 存在但 claude 不可用。如需在 WSL 中使用，请运行 install_wsl.sh。"
            }
            else {
                if ($winClaudeVer) {
                    Add-CheckResult "WSL: claude" "INFO" "WSL 内未安装 Claude Code；Windows 原生 Claude Code 可用 ($winClaudeVer)"
                    Add-Suggestion "当前 Windows 原生 Claude Code 可用；WSL 内需要单独安装后才能在 WSL 终端使用"
                }
                else {
                    Add-CheckResult "WSL: claude" "WARN" "WSL 内未安装 Claude Code"
                    Add-Suggestion "在 WSL Ubuntu 中运行 install_wsl.sh 安装 Claude Code。"
                }
            }
        }
        "not_installed_with_config" {
            Add-CheckResult "WSL: claude" "WARN" "WSL 已有 Claude 配置 (settings.json)，但 WSL 内暂未检测到可运行的 claude 命令"
            Add-Suggestion "WSL 中 settings.json 存在但 claude 不可用。如需在 WSL 中使用，请运行 install_wsl.sh。"
            if ($winClaudeVer) {
                Add-CheckResult "Windows 原生" "INFO" "Windows 原生 Claude Code 可用 ($winClaudeVer)"
            }
        }
        default {
            Add-CheckResult "WSL: claude" "SKIP" $wslClaude.Summary
        }
    }

    # 检查 WSL 配置（使用同一个 $ubuntuDistroName，不依靠默认发行版）
    if ($ubuntuDistroName) {
        $wslConfig = Invoke-CommandSafe -Command "wsl" -Arguments @(
            "-d", $ubuntuDistroName, "bash", "-c",
            "test -f ~/.claude/settings.json && echo 'EXISTS' || echo 'NOT_FOUND'"
        )
    }
    else {
        Write-Info "未能确定 Ubuntu 发行版名称，settings.json 检测使用默认 WSL 发行版。"
        $wslConfig = Invoke-CommandSafe -Command "wsl" -Arguments @(
            "bash", "-c", "test -f ~/.claude/settings.json && echo 'EXISTS' || echo 'NOT_FOUND'"
        )
    }
    if ($wslConfig.Success) {
        if ($wslConfig.Output -match "NOT_FOUND") {
            Add-CheckResult "WSL: settings.json" "WARN" "WSL 内无配置"
        }
        else {
            Add-CheckResult "WSL: settings.json" "OK" "已配置"
        }
    }
}

# ============================================================
# 生成报告
# ============================================================

function Write-AtAGlance {
    <#
    .SYNOPSIS
        v1.3.3 P2: 「一眼结论」— 报告最顶层的用户友好摘要。
        先给结论再给详情，面向小白用户。
        状态判定: 可用 / 基本可用 / 需要修复 / 未完成
    #>
    Add-ReportLine ""
    Add-ReportLine "【一眼结论】"
    Add-ReportLine ""

    # 读取关键检测结果
    $claudeCliCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Claude Code CLI" } | Select-Object -First 1
    $claudeFileCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Claude Code 安装文件" } | Select-Object -First 1
    $claudeSourceCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Claude 命令来源" } | Select-Object -First 1
    $configCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -match "ANTHROPIC_AUTH_TOKEN" } | Select-Object -First 1
    $apiCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -match "Anthropic Format smoke test|DeepSeek API 测试" } | Select-Object -First 1
    $userPathCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "User PATH" } | Select-Object -First 1
    $freshShellCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Fresh PowerShell claude" } | Select-Object -First 1
    $nodeCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Node.js" } | Select-Object -First 1
    $npmCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "npm" } | Select-Object -First 1

    $claudeStatus = if ($claudeCliCheck) { $claudeCliCheck.Status } else { "UNKNOWN" }
    $claudeDetail = if ($claudeCliCheck) { $claudeCliCheck.Detail } else { "" }
    $claudeExeFound = ($claudeFileCheck -and $claudeFileCheck.Status -eq "OK")
    $configOk = ($configCheck -and $configCheck.Status -eq "OK")
    $apiOk = ($apiCheck -and $apiCheck.Status -eq "OK")
    $apiSkipped = ($apiCheck -and $apiCheck.Status -eq "SKIP")
    $userPathOk = ($userPathCheck -and $userPathCheck.Status -eq "OK")
    $freshShellOk = ($freshShellCheck -and $freshShellCheck.Status -eq "OK")
    $freshShellWarn = ($freshShellCheck -and $freshShellCheck.Status -eq "WARN")
    $nativeExeExists = $claudeExeFound
    $nativePathOk = $userPathOk

    # 核心错误计数（排除可选项）
    $coreErrors = @($script:DoctorState.Errors | Where-Object {
        $_ -notmatch "VS Code|Git|WSL" -and
        $_ -notmatch "Node\.js.*Native Install" -and
        $_ -notmatch "npm.*Native Install"
    })

    # --- 逐项状态 ---
    $claudeLabel = switch ($claudeStatus) {
        "OK"    { "可用" }
        "WARN"  { "可用（PATH 冲突）" }
        "ERROR" { "未安装或不可用" }
        default { "未检测" }
    }
    if ($claudeStatus -eq "OK" -and $claudeDetail -match '(\d+\.\d+\.\d+[^\s,]*)') {
        $claudeLabel = "可用 ($($matches[1]))"
    }

    $configLabel = if ($configOk) { "已配置" } else { "未配置" }

    $apiLabel = if ($apiOk) {
        "通过"
    }
    elseif ($apiSkipped) {
        "跳过"
    }
    elseif ($apiCheck) {
        "失败"
    }
    else {
        "未测试"
    }

    $pathLabel = if ($userPathOk) { "正常" } else { "需修复" }

    $freshLabel = if ($freshShellOk) {
        "通过"
    }
    elseif ($freshShellWarn) {
        "建议手动验证"
    }
    elseif ($freshShellCheck) {
        "失败"
    }
    else {
        "未验证"
    }

    $nodeLabel = if ($nodeCheck) {
        if ($nodeCheck.Status -eq "OK") { "已安装" }
        elseif ($nodeCheck.Status -eq "INFO") { "未安装（Native Install 不影响基础使用）" }
        else { "未安装" }
    }
    else { "未检测" }

    Add-ReportLine "  Claude Code：$claudeLabel"
    Add-ReportLine "  DeepSeek 配置：$configLabel"
    Add-ReportLine "  API 测试：$apiLabel"
    Add-ReportLine "  User PATH：$pathLabel"
    Add-ReportLine "  Fresh PowerShell：$freshLabel"
    Add-ReportLine "  Node/npm：$nodeLabel"

    # --- 状态判定 ---
    Add-ReportLine ""
    Add-ReportLine ("=" * 63)

    $overallStatus = "未完成"
    $nextActions = [System.Collections.ArrayList]::new()

    # 判定逻辑
    $claudeUsable = ($claudeStatus -eq "OK" -or $claudeStatus -eq "WARN")
    $deepSeekReady = ($configOk -and ($apiOk -or $apiSkipped))
    $noCoreErrors = ($coreErrors.Count -eq 0)

    if ($claudeUsable -and $deepSeekReady -and $noCoreErrors) {
        if ($freshShellOk) {
            $overallStatus = "可用"
        }
        elseif ($freshShellWarn -and $claudeExeFound -and $userPathOk) {
            $overallStatus = "基本可用"
        }
        else {
            $overallStatus = "可用"
        }
    }
    elseif ($claudeExeFound -and $userPathOk -and $configOk -and $freshShellWarn) {
        $overallStatus = "基本可用"
    }
    elseif ($claudeStatus -eq "ERROR" -or (-not $claudeExeFound -and $claudeStatus -ne "OK") -or $coreErrors.Count -ge 1) {
        $overallStatus = "需要修复"
    }

    Add-ReportLine "  当前状态：$overallStatus"
    Add-ReportLine ("=" * 63)

    # --- 下一步（最多 3 条）---
    Add-ReportLine ""
    Add-ReportLine "  下一步："

    switch ($overallStatus) {
        "可用" {
            if ($freshShellWarn) {
                [void]$nextActions.Add("新开 PowerShell 执行 claude --version 确认可用")
            }
            [void]$nextActions.Add("回到安装助手完成页选择 [1] 启动 Claude Code 测试")
            [void]$nextActions.Add("如果调用模型失败，检查 DeepSeek Key、余额和网络")
        }
        "基本可用" {
            [void]$nextActions.Add("新开 PowerShell 执行 claude --version。如果能显示版本号，可以正常使用")
            [void]$nextActions.Add("如果失败，运行「一键修复依赖.cmd」或重新运行诊断")
            [void]$nextActions.Add("Native Install 已就绪时，Node.js/npm 未安装不影响基础使用")
        }
        "需要修复" {
            if ($claudeStatus -eq "ERROR" -or -not $claudeExeFound) {
                [void]$nextActions.Add("运行「00-点我开始安装.cmd」安装 Claude Code")
            }
            if (-not $userPathOk -and $claudeExeFound) {
                [void]$nextActions.Add("运行「一键修复依赖.cmd」修复 User PATH")
            }
            if (-not $configOk) {
                [void]$nextActions.Add("运行「00-点我开始安装.cmd」配置 DeepSeek API Key")
            }
            if ($apiCheck -and $apiCheck.Status -eq "ERROR" -and $configOk) {
                [void]$nextActions.Add("检查 DeepSeek API Key 是否正确，或账户余额是否充足")
            }
            if ($nextActions.Count -eq 0 -and $coreErrors.Count -gt 0) {
                [void]$nextActions.Add("查看下方 [ERROR] 项目并逐项解决")
            }
            if ($nextActions.Count -eq 0) {
                [void]$nextActions.Add("运行「一键诊断.cmd」获取详细诊断报告")
            }
        }
        default {
            [void]$nextActions.Add("运行「00-点我开始安装.cmd」完成安装")
            [void]$nextActions.Add("运行「一键诊断.cmd」获取详细诊断报告")
        }
    }

    # 最多 3 条
    $shown = 0
    foreach ($action in $nextActions) {
        if ($shown -ge 3) { break }
        $shown++
        Add-ReportLine "    $shown. $action"
    }

    # --- 售后安全提示 ---
    Add-ReportLine ""
    Add-ReportLine "  ---"
    Add-ReportLine "  售后安全：只发送 report.txt，不要发送 logs、backup、settings.json 或完整 API Key。"
    Add-ReportLine ""
}

function Write-QuickSummary {
    <#
    .SYNOPSIS
        生成「总体结论」区，面向普通用户的清晰诊断结论。
        优先使用 Check-Commands 已写入的 CheckResults，与 Claude 命令来源检测保持一致。
    #>
    Add-ReportLine ""
    Add-ReportLine "【总体结论】"
    Add-ReportLine ""

    # 从 CheckResults 读取 Claude Code CLI 状态（由 Check-Commands 写入）
    $claudeCliCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Claude Code CLI" } | Select-Object -First 1
    $activeClaudeCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "当前 claude 来源" } | Select-Object -First 1
    $claudeSourceCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Claude 命令来源" } | Select-Object -First 1

    $claudeStatus = if ($claudeCliCheck) { $claudeCliCheck.Status } else { "UNKNOWN" }
    $claudeDetail = if ($claudeCliCheck) { $claudeCliCheck.Detail } else { "" }

    $claudeVer = $null
    if ($claudeDetail -match '(\d+\.\d+\.\d+[^\s,]*)') {
        $claudeVer = $matches[1]
    }

    $nodeInfo = Test-NodeJsInstalled
    $configInfo = Test-ClaudeConfigExists
    $hasApiErrors = ($script:DoctorState.Errors.Count -gt 0)
    $coreErrorCount = @($script:DoctorState.Errors | Where-Object { $_ -notmatch "VS Code" }).Count

    # --- Windows 原生是否可用 ---
    if ($claudeStatus -eq "OK") {
        if ($nodeInfo.IsSupported) {
            $configCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -match "ANTHROPIC_AUTH_TOKEN" }
            if ($configCheck -and $configCheck.Status -eq "OK") {
                Add-ReportLine "  Windows 原生 Claude Code: 可用 ($claudeVer)"
            }
            else {
                Add-ReportLine "  Windows 原生 Claude Code: CLI 可用 ($claudeVer)，待配置 API Key"
            }
        }
        else {
            # v1.3.3 P0-3: Node.js 未安装但可能是 Native Install 场景
            $nodeCheckForSummary = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Node.js" } | Select-Object -First 1
            if ($nodeCheckForSummary -and $nodeCheckForSummary.Status -eq "INFO") {
                Add-ReportLine "  Windows 原生 Claude Code: 可用 ($claudeVer)，Node.js 未安装（Native Install 不影响基础使用）"
            }
            else {
                Add-ReportLine "  Windows 原生 Claude Code: CLI 可用 ($claudeVer)，Node.js 需升级"
            }
        }
    }
    elseif ($claudeStatus -eq "WARN") {
        $claudeVer = "可用（PATH 冲突）"
        Add-ReportLine "  Windows 原生 Claude Code: 检测到可用安装，但 PATH 可能存在冲突"
        if ($activeClaudeCheck -and $activeClaudeCheck.Detail) {
            Add-ReportLine '    详情见"Claude 命令来源"'
        }
    }
    elseif ($claudeStatus -eq "ERROR") {
        Add-ReportLine "  Windows 原生 Claude Code: 未安装或不可用"
    }
    else {
        # UNKNOWN — fallback 到旧检测（仅兜底）
        $claudeVer = Test-ClaudeInstalled
        if ($claudeVer -and $nodeInfo.IsSupported) {
            $configCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -match "ANTHROPIC_AUTH_TOKEN" }
            if ($configCheck -and $configCheck.Status -eq "OK") {
                Add-ReportLine "  Windows 原生 Claude Code: 可用 ($claudeVer)"
            }
            else {
                Add-ReportLine "  Windows 原生 Claude Code: CLI 可用 ($claudeVer)，待配置 API Key"
            }
        }
        elseif ($claudeVer -and -not $nodeInfo.IsSupported) {
            Add-ReportLine "  Windows 原生 Claude Code: CLI 可用 ($claudeVer)，Node.js 需升级"
        }
        else {
            Add-ReportLine "  Windows 原生 Claude Code: 未安装"
        }
    }

    # --- DeepSeek API 是否可用 ---
    $apiCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -match "Anthropic Format smoke test" }
    if ($apiCheck) {
        if ($apiCheck.Status -eq "OK") {
            Add-ReportLine "  DeepSeek API: 可用"
        }
        elseif ($apiCheck.Status -eq "SKIP") {
            Add-ReportLine "  DeepSeek API: 未测试（已跳过）"
        }
        else {
            Add-ReportLine "  DeepSeek API: 不可用 — $($apiCheck.Detail)"
        }
    }

    # --- WSL 是否可用（从 CheckResults 读取，不再调用 Test-WslInstalled）---
    $wslCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "WSL" } | Select-Object -First 1
    $wslStateCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "WSL 状态" } | Select-Object -First 1
    if ($wslCheck) {
        if ($wslCheck.Status -eq "SKIP") {
            Add-ReportLine "  WSL: 未启用"
        }
        else {
            $wslClaudeCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -match "WSL: claude" }
            if ($wslClaudeCheck -and $wslClaudeCheck.Status -eq "OK") {
                Add-ReportLine "  WSL: 已启用，Claude Code 已安装"
            }
            elseif ($wslClaudeCheck -and $wslClaudeCheck.Status -eq "WARN") {
                Add-ReportLine "  WSL: 已启用，Claude Code 需要配置"
            }
            else {
                Add-ReportLine "  WSL: 已启用，Claude Code 未安装"
            }
        }
    }
    else {
        Add-ReportLine "  WSL: 未检测"
    }

    # --- 是否存在影响使用的问题 ---
    if ($coreErrorCount -gt 0) {
        Add-ReportLine ""
        Add-ReportLine "  存在影响使用的问题（$coreErrorCount 项错误），请查看下方详细信息。"
    }
    elseif ($script:DoctorState.Warnings.Count -gt 0) {
        Add-ReportLine ""
        Add-ReportLine "  存在提示项（$($script:DoctorState.Warnings.Count) 项警告），不影响基础使用。"
    }
    else {
        Add-ReportLine ""
        Add-ReportLine "  未发现影响使用的问题，环境配置正常。"
    }

    # 建议动作
    Add-ReportLine ""
    Add-ReportLine "  建议动作:"
    $pathRisk = Test-UserPathRisk
    if ($pathRisk.IsBlocked) {
        Add-ReportLine "    1. 先完整解压 ZIP 到普通文件夹（如 D:\\ClaudeDeepSeek）"
    }

    # --- PATH 问题检测 (v1.3.3) ---
    $claudeFileCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Claude Code 安装文件" } | Select-Object -First 1
    $userPathCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "User PATH" } | Select-Object -First 1
    $freshShellCheck = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Fresh PowerShell claude" } | Select-Object -First 1

    $claudeExeFound = ($claudeFileCheck -and $claudeFileCheck.Status -eq "OK")
    $userPathMissing = ($userPathCheck -and $userPathCheck.Status -in @("ERROR", "WARN"))
    $freshShellFailed = ($freshShellCheck -and $freshShellCheck.Status -eq "ERROR")

    if ($claudeExeFound -and ($userPathMissing -or $freshShellFailed)) {
        Add-ReportLine ""
        Add-ReportLine "  Claude Code 已安装，但命令未正确加入 PATH。"
        Add-ReportLine "  请运行「一键修复依赖」或重新运行安装工具修复 PATH。"
        Add-ReportLine "  也可以手动将以下路径加入用户 PATH："
        Add-ReportLine "    %USERPROFILE%\\.local\\bin"
    }

    if (-not $nodeInfo.IsSupported) {
        # v1.3.3 P0-3: 如果 Node.js 被分级为 INFO（Native Install 已成功），不要建议安装 Node.js
        $nodeCheckResult = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Node.js" } | Select-Object -First 1
        if (-not $nodeCheckResult -or $nodeCheckResult.Status -eq "ERROR") {
            Add-ReportLine "    - 运行「一键修复依赖.cmd」安装 Node.js"
        }
    }
    if (-not $claudeVer) {
        Add-ReportLine "    - 运行「00-点我开始安装.cmd」安装 Claude Code"
    }
    if (-not $configInfo.Exists -or -not $configInfo.IsValid) {
        Add-ReportLine "    - 运行「00-点我开始安装.cmd」配置 DeepSeek API Key"
    }
    if ($coreErrorCount -gt 0) {
        Add-ReportLine "    - 检查下方 [ERROR] 项目并逐项解决"
    }
    if ($userPathMissing) {
        Add-ReportLine "    - 运行「一键修复依赖.cmd」修复 User PATH"
    }
    if ($claudeVer -and $configInfo.Exists -and $coreErrorCount -eq 0 -and -not $userPathMissing) {
        $nodeCheckForFinal = $script:DoctorState.CheckResults | Where-Object { $_.Name -eq "Node.js" } | Select-Object -First 1
        $nodeDowngraded = ($nodeCheckForFinal -and $nodeCheckForFinal.Status -eq "INFO")
        if ($nodeInfo.IsSupported -or $nodeDowngraded) {
            Add-ReportLine "    - 所有核心检测正常，无需额外操作"
        }
        else {
            Add-ReportLine "    - Claude Code 和 DeepSeek API 基本可用。"
            Add-ReportLine "    - 存在可选环境提示，详见下方。"
        }
    }
    Add-ReportLine ""
}

function Write-ReportSummary {
    Add-ReportLine ""
    Add-ReportLine "【核心环境】"
    Add-ReportLine ""

    $winInfo = Get-WindowsVersionInfo
    Add-ReportLine "  Windows 版本:  $($winInfo.Version) (Build $($winInfo.Build))"
    Add-ReportLine "  PowerShell:    $($PSVersionTable.PSVersion)"
    Add-ReportLine "  用户目录:      $(Sanitize-PathForReport -Text (Get-UserProfilePath))"
    Add-ReportLine ""

    # Node/npm/Git/Claude
    $nodeInfo = Test-NodeJsInstalled
    Add-ReportLine "  Node.js:       $(if ($nodeInfo.IsSupported) { $nodeInfo.Version } else { '未安装或版本过低' })"
    $npmInfo = Test-NpmInstalled
    Add-ReportLine "  npm:           $(if ($npmInfo.Installed) { $npmInfo.Version } else { '不可用' })"
    $gitVer = Test-GitInstalled
    Add-ReportLine "  Git:           $(if ($gitVer) { $gitVer } else { '未安装' })"

    $claudeVer = Test-ClaudeInstalled
    if ($claudeVer) {
        Add-ReportLine "  Claude Code:   $claudeVer"
    }
    else {
        Add-ReportLine "  Claude Code:   未安装"
    }

    # Claude Code 安装路径（脱敏）
    if ($claudeVer) {
        try {
            $claudePath = (Get-Command claude -ErrorAction SilentlyContinue).Source
            if ($claudePath) {
                Add-ReportLine "  安装路径:      $(Sanitize-PathForReport -Text $claudePath)"
            }
        }
        catch { }
    }

    Add-ReportLine ""
}

function Write-ReportChecks {
    Add-ReportLine ""
    Add-ReportLine "【检测详情】"
    Add-ReportLine ""

    # 分组：核心环境 / DeepSeek 配置 / Claude doctor / WSL / 可选增强
    $allChecks = $script:DoctorState.CheckResults

    # --- 1. 核心环境 ---
    $coreNames = @("Windows 版本", "系统架构", "物理内存", "PowerShell", "最低要求",
        "用户目录", "执行策略", "管理员权限", "Node.js", "npm", "Git", "VS Code (code)",
        "Claude Code CLI", "Claude 配置目录", "settings.json",
        "npm registry", "npm optional", "npm omit", "npm ignore-scripts", "npm 安装风险配置")
    $coreChecks = $allChecks | Where-Object { $_.Name -in $coreNames }
    if ($coreChecks) {
        Add-ReportLine "  --- 核心环境 ---"
        foreach ($check in $coreChecks) {
            $icon = Get-StatusIcon -Status $check.Status
            $line = "  $icon $($check.Name)"
            if ($check.Detail) { $line += " - $($check.Detail)" }
            Add-ReportLine $line
        }
        Add-ReportLine ""
    }

    # --- 2. Claude 命令来源 ---
    $claudeInvNames = @("Claude 命令来源", "当前 claude 来源", "Claude 命令冲突",
        "claude 候选 1", "claude 候选 2", "claude 候选 3", "claude 候选 4",
        "claude 候选 5", "claude 候选 6", "claude 候选 7", "claude 候选 8")
    $claudeInvChecks = $allChecks | Where-Object { $_.Name -in $claudeInvNames }
    if ($claudeInvChecks) {
        Add-ReportLine "  --- Claude 命令来源 ---"
        foreach ($check in $claudeInvChecks) {
            $icon = Get-StatusIcon -Status $check.Status
            $line = "  $icon $($check.Name)"
            if ($check.Detail) { $line += " - $($check.Detail)" }
            Add-ReportLine $line
        }
        Add-ReportLine ""
    }

    # --- 3. DeepSeek 配置 ---
    $dsNames = @("env 字段", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "API Key",
        "Anthropic Format smoke test", "DeepSeek API 测试",
        "DNS: api.deepseek.com", "HTTPS: api.deepseek.com", "Windows/WSL 一致性")
    $dsChecks = $allChecks | Where-Object { $_.Name -in $dsNames }
    if ($dsChecks) {
        Add-ReportLine "  --- DeepSeek 配置 ---"
        foreach ($check in $dsChecks) {
            $icon = Get-StatusIcon -Status $check.Status
            $line = "  $icon $($check.Name)"
            if ($check.Detail) { $line += " - $($check.Detail)" }
            Add-ReportLine $line
        }
        Add-ReportLine ""
    }

    # --- 3. Claude doctor 摘要 ---
    $doctorChecks = $allChecks | Where-Object { $_.Name -match "claude doctor" }
    if ($doctorChecks) {
        Add-ReportLine "  --- Claude Doctor 摘要 ---"
        foreach ($check in $doctorChecks) {
            $icon = Get-StatusIcon -Status $check.Status
            $line = "  $icon $($check.Name)"
            if ($check.Detail) { $line += " - $($check.Detail)" }
            Add-ReportLine $line
        }
        Add-ReportLine "  注意: 报告中不包含 Claude 官方 doctor 原始 TUI 输出。"
        Add-ReportLine ""
    }

    # --- 4. WSL 状态 ---
    $wslNames = @("WSL", "WSL 发行版", "WSL 状态", "Ubuntu", "Ubuntu 可启动",
        "WSL: claude", "WSL: claude 版本", "WSL: claude 路径",
        "WSL: settings.json", "WSL vs Windows", "Windows 原生")
    $wslChecks = $allChecks | Where-Object { $_.Name -in $wslNames }
    if ($wslChecks) {
        Add-ReportLine "  --- WSL 状态 ---"
        foreach ($check in $wslChecks) {
            $icon = Get-StatusIcon -Status $check.Status
            $line = "  $icon $($check.Name)"
            if ($check.Detail) { $line += " - $($check.Detail)" }
            Add-ReportLine $line
        }
        Add-ReportLine ""
    }

    # --- 5. 可选增强 ---
    $optionalNames = @("code 命令", "Claude Code VS Code 扩展", "Claude Code 扩展",
        "WSL settings.json")
    $optChecks = $allChecks | Where-Object { $_.Name -in $optionalNames }
    if ($optChecks) {
        Add-ReportLine "  --- 可选增强 ---"
        foreach ($check in $optChecks) {
            $icon = Get-StatusIcon -Status $check.Status
            $line = "  $icon $($check.Name)"
            if ($check.Detail) { $line += " - $($check.Detail)" }
            Add-ReportLine $line
        }
        Add-ReportLine ""
    }

    # --- 剩余未分组的检测项 ---
    $groupedNames = $coreNames + $claudeInvNames + $dsNames + $wslNames + $optionalNames + @("claude doctor")
    $remaining = $allChecks | Where-Object { $_.Name -notin $groupedNames }
    if ($remaining) {
        Add-ReportLine "  --- 其他检测 ---"
        foreach ($check in $remaining) {
            $icon = Get-StatusIcon -Status $check.Status
            $line = "  $icon $($check.Name)"
            if ($check.Detail) { $line += " - $($check.Detail)" }
            Add-ReportLine $line
        }
        Add-ReportLine ""
    }
}

function Get-StatusIcon {
    param([string]$Status)
    switch ($Status) {
        "OK"    { return "[OK]" }
        "WARN"  { return "[WARN]" }
        "ERROR" { return "[ERROR]" }
        "SKIP"  { return "[SKIP]" }
        "INFO"  { return "[INFO]" }
        default { return "[?]" }
    }
}

function Write-ReportErrors {
    if ($script:DoctorState.Errors.Count -eq 0 -and $script:DoctorState.Warnings.Count -eq 0) {
        return
    }

    if ($script:DoctorState.Errors.Count -gt 0) {
        Add-ReportLine ""
        Add-ReportLine "【需处理的问题】"
        Add-ReportLine ""
        foreach ($err in $script:DoctorState.Errors) {
            Add-ReportLine "  [ERROR] $err"
        }
    }

    if ($script:DoctorState.Warnings.Count -gt 0) {
        Add-ReportLine ""
        Add-ReportLine "【提醒事项】"
        Add-ReportLine ""
        foreach ($warn in $script:DoctorState.Warnings) {
            Add-ReportLine "  [WARN] $warn"
        }
    }

    if ($script:DoctorState.Suggestions.Count -gt 0) {
        Add-ReportLine ""
        Add-ReportLine "【修复建议】"
        Add-ReportLine ""
        $i = 1
        foreach ($sg in $script:DoctorState.Suggestions | Select-Object -Unique) {
            Add-ReportLine "  $i. $sg"
            $i++
        }
    }
}

function Write-ReportFooter {
    Add-ReportLine ""
    Add-ReportLine "【隐私说明】"
    $apiKey = Get-ApiKeyFromConfig
    if ($apiKey) {
        $masked = Mask-ApiKey -Key $apiKey
        Add-ReportLine "  API Key: $masked"
    }
    else {
        Add-ReportLine "  API Key: 未设置"
    }
    Add-ReportLine "  完整 API Key 和真实用户路径未记录在本报告中。"
    Add-ReportLine "  报告中不包含 Claude 官方 doctor 原始 TUI 输出。"
    Add-ReportLine "  报告中不包含内部认证字段、完整路径或敏感标识。"
    Add-ReportLine ""
    Add-ReportLine ("=" * 73)
    Add-ReportLine "  报告结束"
    Add-ReportLine ""
    $safeGuidance = Write-SupportSafeGuidance -ForReport
    Add-ReportLine $safeGuidance
    Add-ReportLine ("=" * 73)
}

# ============================================================
# 主流程
# ============================================================

function Main {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "           Claude Code 环境诊断工具 v$ScriptVersion                   " -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""
    # 安全启动 terminal transcript（失败不阻断）
    Start-CcdiTranscriptSafe -Name "doctor"

    Write-Info "正在全面检测您的环境配置..."
    if ($SkipApiTest) {
        Write-Info "本次已按参数跳过 DeepSeek API 在线测试。"
    }
    else {
        Write-Info "API 测试会向 DeepSeek 官方 Anthropic Format 接口发送一个极短测试请求，用于验证 Key、模型和 endpoint 是否可用。完整 API Key 不会写入报告或日志。"
    }
    Write-Host ""

    # 执行所有检测（每一步独立 try/catch，单个步骤异常不影响后续步骤）
    $diagnosticSteps = @(
        @{ Name = "最低要求检查";   Func = ${function:Check-MinimumRequirements} },
        @{ Name = "系统信息";       Func = ${function:Check-SystemInfo} },
        @{ Name = "命令检测";       Func = ${function:Check-Commands} },
        @{ Name = "配置文件检测";   Func = ${function:Check-Files} },
        @{ Name = "网络检测";       Func = ${function:Check-Network} },
        @{ Name = "DeepSeek API";   Func = ${function:Check-DeepSeekApi} },
        @{ Name = "VS Code";        Func = ${function:Check-VSCode} },
        @{ Name = "WSL";            Func = ${function:Check-WSL} }
    )

    foreach ($step in $diagnosticSteps) {
        try {
            Write-Log "INFO" "诊断步骤开始: $($step.Name)"
            & $step.Func
            Write-Log "INFO" "诊断步骤完成: $($step.Name)"
        }
        catch {
            $errorMsg = "诊断步骤 [$($step.Name)] 发生异常: $($_.Exception.Message)"
            Write-Log "ERROR" $errorMsg
            Write-Error-Msg $errorMsg
            Add-CheckResult $step.Name "ERROR" "步骤执行异常，已跳过（不影响后续诊断）"
            Add-Suggestion "诊断步骤 [$($step.Name)] 执行异常，建议重新运行诊断或联系技术支持。错误详情已写入日志。"
            # 继续后续诊断，不中断
        }
    }

    # 生成报告
    Write-ReportHeader
    Write-AtAGlance
    Write-QuickSummary
    Write-ReportSummary
    Write-ReportChecks
    Write-ReportErrors
    Write-ReportFooter

    # 对报告内容进行综合安全处理（脱敏 + 清洗 + 过滤内部字段）
    $rawReport = $script:DoctorState.ReportLines -join "`r`n"
    $safeReport = Convert-ToSafeReportText -Text $rawReport

    # 输出到控制台摘要
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan

    # 一眼结论：当前状态（从 AtAGlance 报告行中提取，避免重复计算）
    $statusLine = $script:DoctorState.ReportLines | Where-Object { $_ -match '当前状态：' } | Select-Object -First 1
    if ($statusLine) {
        $statusText = ($statusLine -replace '.*当前状态：', '').Trim()
        $statusColor = switch -Wildcard ($statusText) {
            "可用"     { "Green" }
            "基本可用" { "Yellow" }
            "需要修复" { "Red" }
            default    { "White" }
        }
        Write-Host "  当前状态：$statusText" -ForegroundColor $statusColor
        Write-Host ("=" * 60) -ForegroundColor Cyan
    }

    $okCount = @($script:DoctorState.CheckResults | Where-Object { $_.Status -eq "OK" }).Count
    $warnCount = @($script:DoctorState.CheckResults | Where-Object { $_.Status -eq "WARN" }).Count
    $errCount = @($script:DoctorState.CheckResults | Where-Object { $_.Status -eq "ERROR" }).Count
    $infoCount = @($script:DoctorState.CheckResults | Where-Object { $_.Status -eq "INFO" }).Count
    $totalCount = $script:DoctorState.CheckResults.Count

    Write-Host "  检测总结: 共 $totalCount 项" -ForegroundColor White
    Write-Host "   正常: $okCount 项" -ForegroundColor Green
    if ($infoCount -gt 0) {
        Write-Host "  [INFO] 信息: $infoCount 项" -ForegroundColor Cyan
    }
    if ($warnCount -gt 0) {
        Write-Host "  [WARN] 警告: $warnCount 项" -ForegroundColor Yellow
    }
    if ($errCount -gt 0) {
        Write-Host "   错误: $errCount 项" -ForegroundColor Red
    }
    Write-Host ("=" * 60) -ForegroundColor Cyan

    # 保存报告文件
    if ($NoSaveReport) {
        Write-Host ""
        Write-Info "已按 -NoSaveReport 跳过保存诊断报告。"
        Write-Info "日志文件: $(Get-LogFilePath)"
        Write-Host ""
        return
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    if ($OutputPath) {
        # 指定输出路径：写入分享版报告
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        $outputDir = Split-Path -Parent $OutputPath
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($OutputPath, $safeReport, $utf8NoBom)

        $fullOutputPath = (Resolve-Path $OutputPath -ErrorAction SilentlyContinue).Path
        if (-not $fullOutputPath) { $fullOutputPath = $OutputPath }
        Write-Success "诊断报告已保存到: $fullOutputPath"
    }
    else {
        # 使用双报告机制
        $isShareSafeMode = ($ShareSafe -or $Anonymize)
        $reportsDir = Join-Path $ScriptDir "reports"
        if (-not (Test-Path $reportsDir)) {
            New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $reportTimestamp = $timestamp

        # 1. 分享版报告（已通过 Convert-ToSafeReportText 完全脱敏清洗）
        $shareRootPath = Join-Path $ScriptDir "report.txt"
        [System.IO.File]::WriteAllText($shareRootPath, $safeReport, $utf8NoBom)

        # 2. 分享版历史
        $historyPath = Join-Path $reportsDir "report-$reportTimestamp.txt"
        [System.IO.File]::WriteAllText($historyPath, $safeReport, $utf8NoBom)

        $fullSharePath = (Resolve-Path $shareRootPath -ErrorAction SilentlyContinue).Path
        if (-not $fullSharePath) { $fullSharePath = $shareRootPath }

        Write-Host ""
        Write-Success "已生成诊断报告:"

        if ($isShareSafeMode) {
            Write-Info "  分享版报告（备用）: $fullSharePath"
            Write-Host ""
            Write-Info "已启用分享安全模式（-ShareSafe），仅生成脱敏报告。"
            Write-Info "报告中已隐藏用户名、路径、API Key 和内部字段，可安全分享。"
        }
        else {
            # 3. 完整版报告（仅脱敏 API Key，保留路径用于本地排错）
            $fullContent = Sanitize-SecretLikeText -Text $rawReport
            $fullReportPath = Join-Path $reportsDir "full-report-$reportTimestamp.txt"
            [System.IO.File]::WriteAllText($fullReportPath, $fullContent, $utf8NoBom)

            $fullHistoryPath = (Resolve-Path $historyPath -ErrorAction SilentlyContinue).Path
            if (-not $fullHistoryPath) { $fullHistoryPath = $historyPath }
            $fullLocalPath = (Resolve-Path $fullReportPath -ErrorAction SilentlyContinue).Path
            if (-not $fullLocalPath) { $fullLocalPath = $fullReportPath }

            Write-Info "  诊断报告（备用）: $fullSharePath"
            Write-Info "  完整版报告（仅本地保存）: $fullLocalPath"
        }

        # --- 提取一眼结论信息用于 support-feedback ---
        $fbOverallStatus = "未完成"
        $fbClaudeStatus = ""
        $fbDeepSeekStatus = ""
        $fbApiTestStatus = ""
        $fbFreshShellStatus = ""
        $fbNextSteps = @()

        $statusLine = $script:DoctorState.ReportLines | Where-Object { $_ -match '当前状态：' } | Select-Object -First 1
        if ($statusLine) { $fbOverallStatus = ($statusLine -replace '.*当前状态：', '').Trim() }

        $claudeCliLine = $script:DoctorState.ReportLines | Where-Object { $_ -match 'Claude Code：' } | Select-Object -First 1
        if ($claudeCliLine) { $fbClaudeStatus = ($claudeCliLine -replace '.*Claude Code：', '').Trim() }

        $configLine = $script:DoctorState.ReportLines | Where-Object { $_ -match 'DeepSeek 配置：' } | Select-Object -First 1
        if ($configLine) { $fbDeepSeekStatus = ($configLine -replace '.*DeepSeek 配置：', '').Trim() }

        $apiLine = $script:DoctorState.ReportLines | Where-Object { $_ -match 'API 测试：' } | Select-Object -First 1
        if ($apiLine) { $fbApiTestStatus = ($apiLine -replace '.*API 测试：', '').Trim() }

        $freshLine = $script:DoctorState.ReportLines | Where-Object { $_ -match 'Fresh PowerShell：' } | Select-Object -First 1
        if ($freshLine) { $fbFreshShellStatus = ($freshLine -replace '.*Fresh PowerShell：', '').Trim() }

        # 提取下一步操作
        $nextLineIdx = -1
        for ($i = 0; $i -lt $script:DoctorState.ReportLines.Count; $i++) {
            if ($script:DoctorState.ReportLines[$i] -match '下一步：') {
                $nextLineIdx = $i
                break
            }
        }
        if ($nextLineIdx -ge 0) {
            $fbNextSteps = @()
            for ($j = $nextLineIdx + 1; $j -lt [Math]::Min($nextLineIdx + 4, $script:DoctorState.ReportLines.Count); $j++) {
                $stepLine = $script:DoctorState.ReportLines[$j].Trim()
                if ($stepLine -match '^\d+\.\s+(.+)$') {
                    $fbNextSteps += $matches[1]
                }
            }
        }

        # --- 生成 support-feedback.txt ---
        try {
            $supportFeedbackResult = New-SupportFeedbackReport `
                -OutputPath (Join-Path $ScriptDir "support-feedback.txt") `
                -ReportText $safeReport `
                -ScriptDir $ScriptDir `
                -IncludeLogTail:$true `
                -IncludeTerminalTail:$true `
                -MaxLogLines 200 `
                -MaxTerminalLines 200 `
                -OverallStatus $fbOverallStatus `
                -ClaudeStatus $fbClaudeStatus `
                -DeepSeekStatus $fbDeepSeekStatus `
                -ApiTestStatus $fbApiTestStatus `
                -FreshShellStatus $fbFreshShellStatus `
                -NextSteps $fbNextSteps

            if ($supportFeedbackResult.Success) {
                Write-Host ""
                $fbPath = (Resolve-Path $supportFeedbackResult.Path -ErrorAction SilentlyContinue).Path
                if (-not $fbPath) { $fbPath = $supportFeedbackResult.Path }
                Write-Success "已生成售后反馈文件（优先发送）: $fbPath"
                Write-Info "如需售后，请优先发送 support-feedback.txt。"
            }
        }
        catch {
            Write-Log "ERROR" "生成 support-feedback.txt 失败: $_"
            # 不阻断主流程
        }

        Write-Host ""
        Write-Info "售后安全提示："
        Write-Info "  优先发送 support-feedback.txt（汇总反馈文件）。"
        Write-Info "  如没有 support-feedback.txt，再发送 report.txt。"
        Write-Warning "不要发送 settings.json、backup/、logs/、reports/full-report-* 或完整 API Key。"
        Write-Info "如果截图，请先确认截图里没有完整 API Key。"
    }

    Write-Info "日志文件: $(Get-LogFilePath)"

    if ($OutputPath) {
        $supportPathForClipboard = $OutputPath
    }
    else {
        $supportPathForClipboard = $shareRootPath
    }

    if (-not $script:DoctorTestSafeMode) {
        if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            try {
                Set-Clipboard -Value $supportPathForClipboard
                Write-Info "报告路径已复制到剪贴板。"
            }
            catch {
                Write-Log "WARN" "复制报告路径到剪贴板失败: $_"
            }
        }

        if (-not $NoOpenReport) {
            try {
                Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$supportPathForClipboard`"" -ErrorAction Stop
                Write-Info "已为您打开报告所在位置。"
            }
            catch {
                Write-Log "WARN" "打开报告所在位置失败: $_"
            }
        }
    }

    # 停止 terminal transcript
    Stop-CcdiTranscriptSafe

    Write-Host ""
}

# 执行
try {
    Main
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
