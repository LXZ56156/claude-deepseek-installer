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
    [string]$OutputPath    # 报告输出路径，默认为当前目录 report.txt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }
. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")
$ScriptDir = Initialize-CcdiScript -ScriptName "doctor"

$ScriptVersion = "1.3.2"

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
}

# ============================================================
# 2. 命令检测
# ============================================================

function Check-Commands {
    Write-Step "诊断项目 3/8：命令检测"

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
        Add-CheckResult "Node.js" "ERROR" $nodeInfo.ErrorMessage
        Add-Suggestion "Node.js 未安装。Claude Code 需要 Node.js 18+。请从 https://nodejs.org 下载安装 LTS 版本。"
    }

    # npm 检测
    $npmInfo = Test-NpmInstalled
    if ($npmInfo.Installed) {
        Add-CheckResult "npm" "OK" $npmInfo.Version
    }
    else {
        Add-CheckResult "npm" "ERROR" $npmInfo.ErrorMessage
        Add-Suggestion "npm 未找到。请检查 Node.js 安装是否完整，或重新安装 Node.js。"
    }

    $gitVersion = Test-GitInstalled
    if ($gitVersion) {
        Add-CheckResult "Git" "OK" $gitVersion
    }
    else {
        Add-CheckResult "Git" "WARN" "未安装"
        Add-Suggestion "Git 未安装。可从 https://git-scm.com 下载安装。"
    }

    $codeVersion = Test-CodeInstalled
    if ($codeVersion) {
        Add-CheckResult "VS Code (code)" "OK" ($codeVersion.Split("`n")[0])
    }
    else {
        Add-CheckResult "VS Code (code)" "WARN" "code 命令不在 PATH 中"
        Add-Suggestion "在 VS Code 中按 Ctrl+Shift+P，搜索并执行 'Shell Command: Install code command in PATH'。"
    }

    $wslInfo = Test-WslInstalled
    if ($wslInfo.Installed) {
        $wslDetail = $wslInfo.Version.Split("`n")[0]
        Add-CheckResult "WSL" "OK" $wslDetail

        $distroList = ($wslInfo.Distributions | ForEach-Object {
            $marker = if ($_.Default) { "*" } else { " " }
            $state = if ($_.Running) { "Running" } else { "Stopped" }
            "$marker $($_.Name) ($state)"
        }) -join "; "
        Add-CheckResult "WSL 发行版" "OK" $distroList
    }
    else {
        Add-CheckResult "WSL" "SKIP" "未安装或未启用"
    }

    $claudeVersion = Test-ClaudeInstalled
    if ($claudeVersion) {
        Add-CheckResult "Claude Code CLI" "OK" $claudeVersion

        # 运行 claude doctor
        Write-Info "正在运行 claude doctor..."
        $claudeDoctor = Invoke-CommandSafe -Command "claude" -Arguments @("doctor")
        if ($claudeDoctor.Success) {
            Add-CheckResult "claude doctor" "OK" "已执行"
        }
        else {
            Add-CheckResult "claude doctor" "WARN" "执行返回非零退出码"
        }
    }
    else {
        Add-CheckResult "Claude Code CLI" "ERROR" "claude 命令未找到"
        Add-Suggestion "未检测到 claude 命令。可能是安装失败，或 npm 全局 bin 路径未加入 PATH。请运行 install.ps1 安装，或关闭重开终端。"
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
                if ($config.PSObject.Properties.Name -contains "env") {
                    $env = $config.env
                    Add-CheckResult "env 字段" "OK" "存在 ($(($env.PSObject.Properties | Measure-Object).Count) 个变量)"

                    # 检查关键字段
                    $envProps = $env.PSObject.Properties.Name

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
                        Add-CheckResult "ANTHROPIC_SMALL_FAST_MODEL" "WARN" "未设置（将使用默认快速模型）"
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

    # 检查 WSL 配置
    $ubuntuInfo = Test-UbuntuInWsl
    if ($ubuntuInfo.Exists) {
        # 尝试检查 WSL 内的配置
        $wslConfigCheck = Invoke-CommandSafe -Command "wsl" -Arguments @("bash", "-c", "test -f ~/.claude/settings.json && echo 'EXISTS' || echo 'NOT_FOUND'")
        if ($wslConfigCheck.Success) {
            if ($wslConfigCheck.Output -match "EXISTS") {
                Add-CheckResult "WSL settings.json" "OK" "~/.claude/settings.json 存在"

                # 检查 Windows 和 WSL 配置是否一致
                if ($configInfo.Exists) {
                    Add-CheckResult "Windows/WSL 一致性" "WARN" "两个环境都有配置，请注意一致性"
                    Add-Suggestion "Windows 和 WSL 中都有 Claude 配置。如果遇到问题，请确认两个环境的配置一致。"
                }
            }
            else {
                Add-CheckResult "WSL settings.json" "WARN" "WSL 中无配置"
                if ($configInfo.Exists) {
                    Add-Suggestion "Windows 有配置但 WSL 中没有。如果使用 WSL，请运行 install_wsl.sh。"
                }
            }
        }
        else {
            Add-CheckResult "WSL settings.json" "SKIP" "无法检查 WSL 内部"
        }
    }
}

# ============================================================
# 4. 网络检测
# ============================================================

function Check-Network {
    Write-Step "诊断项目 5/8：网络检测"

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
        if ($config.env.PSObject.Properties.Name -contains "ANTHROPIC_BASE_URL") {
            $baseUrl = $config.env.ANTHROPIC_BASE_URL
        }
        if ($config.env.PSObject.Properties.Name -contains "ANTHROPIC_SMALL_FAST_MODEL") {
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
            Add-CheckResult "Claude Code 扩展" "OK" "已安装"
        }
        else {
            Add-CheckResult "Claude Code 扩展" "WARN" "未安装"
            Add-Suggestion "在 VS Code 中按 Ctrl+Shift+X，搜索 'Claude Code' 并安装。"
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

    $wslInfo = Test-WslInstalled
    if (-not $wslInfo.Installed) {
        Add-CheckResult "WSL" "SKIP" "未启用"
        return
    }

    Add-CheckResult "WSL 状态" "OK" "已启用"

    $ubuntuInfo = Test-UbuntuInWsl
    if (-not $ubuntuInfo.Exists) {
        Add-CheckResult "Ubuntu" "WARN" "未安装 Ubuntu 发行版"
        Add-Suggestion "如需在 WSL 中使用 Claude Code，请运行: wsl --install -d Ubuntu"
        return
    }

    $stateText = if ($ubuntuInfo.Running) { "Running" } else { "已停止" }
    Add-CheckResult "Ubuntu" "OK" $stateText

    # 如果 Ubuntu 未运行，尝试检查是否可启动
    if (-not $ubuntuInfo.Running) {
        Add-CheckResult "Ubuntu 可启动" "WARN" "当前未运行"
        Add-Suggestion "请在 PowerShell 中运行 'wsl' 启动 Ubuntu。"
        return
    }

    # 检查 WSL 内的 Claude 状态
    Write-Info "正在检查 WSL 内 Claude Code 状态..."
    $wslClaude = Invoke-CommandSafe -Command "wsl" -Arguments @("bash", "-c", "command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null || echo 'NOT_FOUND'")
    if ($wslClaude.Success) {
        if ($wslClaude.Output -match "NOT_FOUND") {
            Add-CheckResult "WSL: claude" "WARN" "WSL 内未安装 Claude Code"
            Add-Suggestion "在 WSL Ubuntu 中运行 install_wsl.sh 安装 Claude Code。"
        }
        else {
            Add-CheckResult "WSL: claude" "OK" ($wslClaude.Output.Trim() -replace "`n", " ")
        }
    }
    else {
        Add-CheckResult "WSL: claude" "SKIP" "无法检查"
    }

    # 检查 WSL 配置
    $wslConfig = Invoke-CommandSafe -Command "wsl" -Arguments @("bash", "-c", "test -f ~/.claude/settings.json && echo 'EXISTS' || echo 'NOT_FOUND'")
    if ($wslConfig.Success) {
        if ($wslConfig.Output -match "NOT_FOUND") {
            Add-CheckResult "WSL: settings.json" "WARN" "WSL 内无配置"
        }
        else {
            # 安全显示配置（不输出完整内容到控制台）
            Add-CheckResult "WSL: settings.json" "OK" "已配置"
        }
    }
}

# ============================================================
# 生成报告
# ============================================================

function Write-ReportSummary {
    Add-ReportLine ""
    Add-ReportLine "【环境摘要】"
    Add-ReportLine ""

    $winInfo = Get-WindowsVersionInfo
    Add-ReportLine "  操作系统:     $($winInfo.Version) (Build $($winInfo.Build))"
    Add-ReportLine "  PowerShell:   $($PSVersionTable.PSVersion)"
    Add-ReportLine "  用户目录:     $(Get-UserProfilePath)"
    Add-ReportLine "  当前用户:     $env:USERNAME ($(if (Test-IsAdministrator) { '管理员' } else { '普通用户' }))"
    Add-ReportLine "  执行策略:     $(Get-ExecutionPolicyInfo)"
    Add-ReportLine ""
}

function Write-ReportChecks {
    Add-ReportLine ""
    Add-ReportLine "【检测结果】"
    Add-ReportLine ""

    foreach ($check in $script:DoctorState.CheckResults) {
        $icon = switch ($check.Status) {
            "OK"    { "[OK]" }
            "WARN"  { "[WARN]" }
            "ERROR" { "[ERROR]" }
            "SKIP"  { "[SKIP]" }
        }
        $line = "  $icon $($check.Name)"
        if ($check.Detail) {
            $line += " - $($check.Detail)"
        }
        Add-ReportLine $line
    }
}

function Write-ReportErrors {
    if ($script:DoctorState.Errors.Count -eq 0 -and $script:DoctorState.Warnings.Count -eq 0) {
        Add-ReportLine ""
        Add-ReportLine "【结论】"
        Add-ReportLine "  所有检测项目通过，环境配置正常。"
        return
    }

    if ($script:DoctorState.Errors.Count -gt 0) {
        Add-ReportLine ""
        Add-ReportLine "【错误 ([ERROR])】"
        Add-ReportLine ""
        foreach ($err in $script:DoctorState.Errors) {
            Add-ReportLine "  [ERROR] $err"
        }
    }

    if ($script:DoctorState.Warnings.Count -gt 0) {
        Add-ReportLine ""
        Add-ReportLine "【警告 ([WARN])】"
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
    Add-ReportLine "【API Key 说明】"
    $apiKey = Get-ApiKeyFromConfig
    if ($apiKey) {
        $masked = Mask-ApiKey -Key $apiKey
        Add-ReportLine "  API Key 已设置: $masked"
    }
    else {
        Add-ReportLine "  API Key 未设置"
    }
    Add-ReportLine "  完整 Key 未记录在本报告中，以保护您的隐私。"
    Add-ReportLine ""
    Add-ReportLine ("=" * 73)
    Add-ReportLine "  报告结束"
    Add-ReportLine "  如需技术支持，请将此报告（report.txt）发送给服务提供者。"
    Add-ReportLine "  请勿发送您的 API Key！"
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
    Write-Info "正在全面检测您的环境配置..."
    if ($SkipApiTest) {
        Write-Info "本次已按参数跳过 DeepSeek API 在线测试。"
    }
    else {
        Write-Info "API 测试会向 DeepSeek 官方 Anthropic Format 接口发送一个极短测试请求，用于验证 Key、模型和 endpoint 是否可用。完整 API Key 不会写入报告或日志。"
    }
    Write-Host ""

    # 执行所有检测
    Check-MinimumRequirements
    Check-SystemInfo
    Check-Commands
    Check-Files
    Check-Network
    Check-DeepSeekApi
    Check-VSCode
    Check-WSL

    # 生成报告
    Write-ReportHeader
    Write-ReportSummary
    Write-ReportChecks
    Write-ReportErrors
    Write-ReportFooter

    # 输出到控制台摘要
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    $okCount = @($script:DoctorState.CheckResults | Where-Object { $_.Status -eq "OK" }).Count
    $warnCount = @($script:DoctorState.CheckResults | Where-Object { $_.Status -eq "WARN" }).Count
    $errCount = @($script:DoctorState.CheckResults | Where-Object { $_.Status -eq "ERROR" }).Count
    $totalCount = $script:DoctorState.CheckResults.Count

    Write-Host "  检测总结: 共 $totalCount 项" -ForegroundColor White
    Write-Host "   正常: $okCount 项" -ForegroundColor Green
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
        $reportContent = $script:DoctorState.ReportLines -join "`r`n"
        $shareContent = Sanitize-ReportText -Text $reportContent
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

        $outputDir = Split-Path -Parent $OutputPath
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($OutputPath, $shareContent, $utf8NoBom)

        $fullOutputPath = (Resolve-Path $OutputPath -ErrorAction SilentlyContinue).Path
        if (-not $fullOutputPath) { $fullOutputPath = $OutputPath }
        Write-Success "诊断报告已保存到: $fullOutputPath"
    }
    else {
        # 使用双报告机制
        $isShareSafeMode = ($ShareSafe -or $Anonymize)
        $reportResult = Write-DiagnosticReports -ReportLines $script:DoctorState.ReportLines -ScriptDir $ScriptDir -Timestamp $timestamp -IncludeFullReport:(-not $isShareSafeMode)

        $fullSharePath = (Resolve-Path $reportResult.SharePath -ErrorAction SilentlyContinue).Path
        if (-not $fullSharePath) { $fullSharePath = $reportResult.SharePath }

        Write-Host ""
        Write-Success "已生成诊断报告:"

        if ($isShareSafeMode) {
            # 分享安全模式：仅输出脱敏版，不生成完整版路径提示
            Write-Info "  分享版报告（可发送）: $fullSharePath"
            Write-Host ""
            Write-Info "已启用分享安全模式（-ShareSafe），仅生成脱敏报告。"
            Write-Info "报告中已隐藏用户名和项目路径，可安全分享。"
        }
        else {
            $fullHistoryPath = (Resolve-Path $reportResult.HistoryPath -ErrorAction SilentlyContinue).Path
            if (-not $fullHistoryPath) { $fullHistoryPath = $reportResult.HistoryPath }

            $fullLocalPath = (Resolve-Path $reportResult.FullPath -ErrorAction SilentlyContinue).Path
            if (-not $fullLocalPath) { $fullLocalPath = $reportResult.FullPath }

            Write-Info "  分享版报告（可发送）: $fullSharePath"
            Write-Info "  分享版历史: $fullHistoryPath"
            Write-Info "  完整版报告（仅本地保存）: $fullLocalPath"
            Write-Host ""
            Write-Info "请发送 report.txt 给技术支持。"
            Write-Warning "不要发送 full-report-xxx.txt（包含完整路径信息）！"
        }
        Write-Warning "不要发送您的 API Key！报告中已自动脱敏处理。"
        Write-Warning "请只发送 report.txt。不要发送 backup/、logs/ 或 reports/full-report-*.txt。"
    }

    Write-Info "日志文件: $(Get-LogFilePath)"

    if ($OutputPath) {
        $supportPathForClipboard = $OutputPath
    }
    else {
        $supportPathForClipboard = $reportResult.SharePath
    }

    if ($env:CCDI_TEST_MODE -ne "1") {
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
