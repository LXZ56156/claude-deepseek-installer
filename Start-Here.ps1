# ============================================================
# Start-Here.ps1 - Claude Code + DeepSeek 一键安装总控入口 (v1.3.1)
#
# 用法:
#   双击 "开始安装.cmd" 或:
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
    [switch]$DryRun
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

$ScriptVersion = "1.3.1"

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
        default { "[$Status]" }
    }
    $color = switch ($Status) {
        "OK"   { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SKIP" { "Gray" }
        default { "White" }
    }
    $line = "  $icon $Label"
    if ($Detail) {
        $line += " - $Detail"
    }
    Write-Host $line -ForegroundColor $color
    Write-Log "INFO" "[$Status] $Label - $Detail"
}

function Pause-ForUser {
    param([switch]$Force)

    if (-not $NonInteractive -and ($Force -or $StepPause)) {
        Write-Host ""
        Read-Host "按回车键继续..."
    }
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
    Write-Info "【最低系统要求检测】"
    Write-Host ""

    $minReq = Test-MinimumRequirements

    # Windows 版本
    $winInfo = $minReq.Details["Windows"]
    if ($winInfo.IsSupported) {
        $osLabel = if ($winInfo.IsWindows11) { "Windows 11" } else { "Windows 10" }
        Write-ResultLine "Windows 版本" "OK" "$osLabel (Build $($winInfo.Build))"
    }
    else {
        Write-ResultLine "Windows 版本" "ERROR" "不支持的系统: $($winInfo.Version) (Build $($winInfo.Build))"
        Write-Warning "需要 Windows 10 1809+ (Build >= 17763) 或 Windows 11"
    }

    # 系统架构
    $archInfo = $minReq.Details["Architecture"]
    if ($archInfo.IsSupported) {
        Write-ResultLine "系统架构" "OK" $archInfo.Architecture
    }
    else {
        Write-ResultLine "系统架构" "ERROR" "不支持: $($archInfo.Architecture)（需要 x64 或 ARM64）"
    }

    # 物理内存
    $memInfo = $minReq.Details["Memory"]
    if ($memInfo.IsSufficient) {
        Write-ResultLine "物理内存" "OK" "$($memInfo.TotalGB) GB"
    }
    else {
        Write-ResultLine "物理内存" "ERROR" "$($memInfo.TotalGB) GB（需要 4GB 以上）"
        Write-Warning "请关闭其他程序释放内存，或升级硬件。"
    }

    # PowerShell 版本
    $psInfo = $minReq.Details["PowerShell"]
    if ($psInfo.IsSupported) {
        Write-ResultLine "PowerShell 版本" "OK" "$($psInfo.Version)"
    }
    else {
        Write-ResultLine "PowerShell 版本" "ERROR" "版本过低"
    }

    # 管理员权限
    if (Test-IsAdministrator) {
        Write-ResultLine "管理员权限" "WARN" "以管理员运行（非必须）"
    }
    else {
        Write-ResultLine "管理员权限" "OK" "普通用户权限（推荐）"
    }

    Write-Host ""

    # 如果硬性要求不满足，停止后续流程
    if (-not $minReq.IsSupported) {
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

    Write-Info "【其他环境检测】"
    Write-Host ""

    # 网络检测
    Write-Info "检测网络连通性..."
    $netDeepSeek = Test-NetworkConnectivity -Url "https://api.deepseek.com"
    if ($netDeepSeek.Reachable) {
        Write-ResultLine "DeepSeek 网络" "OK" "可访问 ($($netDeepSeek.LatencyMs)ms)"
    }
    else {
        Write-ResultLine "DeepSeek 网络" "ERROR" "无法访问: $($netDeepSeek.Error)"
    }

    # Claude Code 检测
    $claudeVersion = Test-ClaudeInstalled
    if ($claudeVersion) {
        Write-ResultLine "Claude Code" "OK" "已安装: $claudeVersion"
    }
    else {
        Write-ResultLine "Claude Code" "WARN" "未安装（将在下一步安装）"
    }

    # Node.js 检测
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
        Write-ResultLine "Node.js" "WARN" "未安装（如 Native Install 不可用将自动安装）"
    }

    # npm 检测
    $npmInfo = Test-NpmInstalled
    if ($npmInfo.Installed) {
        Write-ResultLine "npm" "OK" $npmInfo.Version
    }
    else {
        Write-ResultLine "npm" "SKIP" "未安装"
    }

    # winget 检测
    $wingetOk = Test-CommandAvailable -CommandName "winget"
    if ($wingetOk) {
        Write-ResultLine "winget" "OK" "可用"
    }
    else {
        Write-ResultLine "winget" "WARN" "未检测到（不影响主流程）"
    }

    # VS Code
    $codeVersion = Test-CodeInstalled
    if ($codeVersion) {
        $codeShort = ($codeVersion -split "`n")[0]
        Write-ResultLine "VS Code" "OK" $codeShort
    }
    else {
        Write-ResultLine "VS Code" "SKIP" "未检测到 code 命令（可选增强项）"
    }

    # Git
    $gitVersion = Test-GitInstalled
    if ($gitVersion) {
        Write-ResultLine "Git" "OK" $gitVersion
    }
    else {
        Write-ResultLine "Git" "SKIP" "未安装（可选）"
    }

    # WSL
    $wslInfo = Test-WslInstalled
    if ($wslInfo.Installed) {
        $ubuntuInfo = Test-UbuntuInWsl
        if ($ubuntuInfo.Exists) {
            Write-ResultLine "WSL Ubuntu" "OK" "已安装"
        }
        else {
            Write-ResultLine "WSL" "OK" "已安装（无 Ubuntu 发行版）"
        }
    }
    else {
        Write-ResultLine "WSL" "SKIP" "未启用（高级选项）"
    }

    # 配置文件
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
    Write-Info "环境检查完成。以上 WARN/SKIP 项不会阻止安装流程。"

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
#   3. 官方不可用或安装失败 → 自动切换 npmmirror npm 镜像
#   4. npm 镜像需要 Node.js >= 18 + npm
# ============================================================

function Step-InstallClaudeCode {
    Write-Step "Step 2/7：安装 Claude Code"

    # 显示安装策略说明
    Write-Info "安装策略: 优先 Claude 官方 Native Install → 不可用时自动切换 npmmirror 镜像"
    Write-Info "npm 镜像使用 Anthropic 官方发布的 @anthropic-ai/claude-code 包"
    Write-Info "镜像只提高 Claude Code 下载成功率，不保证登录、鉴权、模型调用一定可用"
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
        Write-Warning "当前需要重开终端后继续，已跳过后续配置步骤。"
        Write-Info "下一步: 关闭此窗口，重新双击「开始安装.cmd」。"
        return $false
    }

    if (-not $installResult.Success) {
        Write-Error-Msg "Claude Code 安装未成功。"
        Write-Info "请先解决安装问题后重新运行本脚本。"
        Write-Info "如果仍不行，请运行「一键诊断.cmd」获取诊断报告。"
        return $false
    }

    return $true
}


# ============================================================
# Step 3: DeepSeek API Key 获取和输入
# ============================================================

function Step-GetApiKey {
    Write-Step "Step 3/7：获取 DeepSeek API Key"

    Write-Info "Claude Code 需要连接 DeepSeek API 才能使用。"
    Write-Info "现在需要您的 DeepSeek API Key。"
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

    # 提示获取方式
    Write-Host "  ---------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "    获取 API Key 步骤:                                     " -ForegroundColor Cyan
    Write-Host "    1. 打开 https://platform.deepseek.com/api_keys          " -ForegroundColor Cyan
    Write-Host "    2. 注册/登录 DeepSeek 账号                              " -ForegroundColor Cyan
    Write-Host "    3. 点击「创建 API Key」                                 " -ForegroundColor Cyan
    Write-Host "    4. 复制生成的 Key（通常以 sk- 开头）                    " -ForegroundColor Cyan
    Write-Host "    5. 回到此窗口粘贴                                       " -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""

    # 自动打开 DeepSeek API Key 页面
    Write-Info "正在为您打开 DeepSeek API Key 页面..."
    try {
        Start-Process "https://platform.deepseek.com/api_keys"
        Write-Info "如果浏览器未自动打开，请手动访问: https://platform.deepseek.com/api_keys"
    }
    catch {
        Write-Info "请手动在浏览器中打开: https://platform.deepseek.com/api_keys"
    }
    Write-Host ""

    Write-Warning "请不要把 API Key 发给卖家或任何第三方！"
    Write-Info "输入时不会显示字符，这是正常的安全保护。"
    Write-Info "请直接粘贴后按回车。"
    Write-Host ""

    $apiKey = Read-ApiKeyWithMaskedConfirmation -Prompt "请粘贴您的 DeepSeek API Key"

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Error-Msg "API Key 不能为空！"
        Write-Info "您可以稍后运行 configure-deepseek.ps1 单独配置。"
        return $null
    }

    # 格式检查
    if (-not (Is-ApiKeyFormatValid -Key $apiKey)) {
        Write-Warning "API Key 格式看起来不典型（DeepSeek Key 通常以 sk- 开头，长度 >= 32 字符）"
        if (-not (Confirm-UserChoice -Message "是否仍然使用此 Key？")) {
            Write-Info "已取消。您可以稍后重新运行配置。"
            return $null
        }
    }

    return $apiKey
}

# ============================================================
# Step 4: 写入 DeepSeek 配置
# ============================================================

function Step-WriteConfig {
    param([string]$ApiKey)

    Write-Step "Step 4/7：写入 DeepSeek 配置"

    Write-Info "正在将 DeepSeek API 配置写入 Claude Code..."
    Write-Info "配置文件位置: $(Get-ClaudeConfigFile)"
    Write-Host ""

    $writeResult = Write-DeepSeekConfig -ApiKey $ApiKey -NonInteractive:$NonInteractive

    if ($writeResult.Success) {
        Write-Success "DeepSeek 配置写入成功！"
        Write-Info "API Key: $(Mask-ApiKey -Key $ApiKey)"
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
        Write-ResultLine "API 测试" "SKIP" "已按参数跳过"
        Write-Info "注意: 未验证 API 是否可用。可稍后运行 doctor.ps1 测试。"
        $script:ApiTestSkipped = $true
        Update-CcdiState -Updates @{ lastApiTest = "skipped" } | Out-Null
        return
    }

    Write-Info "正在使用 Anthropic Format 接口验证 DeepSeek API..."
    Write-Info "测试模型: deepseek-v4-flash（快速模型，响应快，成本低）"
    Write-Info "这只发送极短测试消息 'Reply OK only.'"
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
        Write-Info "配置已写入但 API 测试未通过。以下步骤将继续，但安装报告会标注「部分成功」。"
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

这是安装完成后自动创建的测试目录。

你可以在此目录运行：

```
claude
```

然后输入：

```
请读取 README.md，并帮我生成一个简单的 hello world 网页。
```

## 快速测试

在终端中进入此目录，运行 `claude` 即可开始使用 Claude Code + DeepSeek API。

## 常见命令

- `claude` - 启动 Claude Code 交互模式
- `claude --version` - 查看版本
- `claude doctor` - 运行诊断

## 注意事项

- API 调用费用由 DeepSeek 官方结算
- 请勿将 API Key 分享给他人
- 如遇问题请运行「一键诊断.cmd」
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
# Step 7: 生成安装完成报告
# ============================================================

function Step-GenerateReport {
    param(
        [string]$ApiKey,
        $EnvCheckResult
    )

    Write-Step "Step 7/7：生成安装完成报告"

    # 确保 reports 目录存在
    $reportsDir = Join-Path $ScriptDir "reports"
    if (-not (Test-Path $reportsDir)) {
        New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportPath = Join-Path $reportsDir "install-report-$timestamp.txt"
    $script:ReportPath = $reportPath

    # 收集信息
    $winInfo = Get-WindowsVersionInfo
    $psInfo = Get-PowerShellVersionInfo
    $claudeVer = Test-ClaudeInstalled
    $codeVer = Test-CodeInstalled
    $wslInfo = Test-WslInstalled
    $maskedKey = Mask-ApiKey -Key $ApiKey

    $apiTestStatus = if ($script:ApiTestPassed) { "通过" }
        elseif ($script:ApiTestSkipped) { "跳过" }
        elseif ($script:ApiTestFailed) { "失败" }
        else { "未执行" }

    $overallStatus = if ($script:TestSafeMode -and $script:ConfigWritten) { "测试安全模式完成" }
        elseif ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestPassed) { "完整成功" }
        elseif ($script:ClaudeInstalled -and $script:ConfigWritten) { "部分成功" }
        else { "未完成" }

    $reportContent = @"
Claude Code + DeepSeek 安装完成报告
======================================

生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
脚本版本: v$ScriptVersion
运行模式: $(if ($script:TestSafeMode) { "测试安全模式" } else { "一键安装" })

一、系统信息
--------------------------------------
Windows 版本: $($winInfo.Version)
PowerShell 版本: $($psInfo.Version) ($($psInfo.Edition))
是否管理员权限: $(if (Test-IsAdministrator) { "是" } else { "否" })
用户目录: $(Get-UserProfilePath)

二、安装结果
--------------------------------------
Claude Code: $(if ($claudeVer) { "已安装" } else { "未安装" })
Claude Code 版本: $(if ($claudeVer) { $claudeVer } else { "-" })
安装方式: $($script:ClaudeInstallMethod)
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
下一步命令:

  cd "$(if ($script:TestProjectPath) { $script:TestProjectPath } else { "桌面\ClaudeCode-Test" })"
  claude

六、整体状态
--------------------------------------
$overallStatus

七、售后提示
--------------------------------------
如遇问题，请运行「一键诊断.cmd」，把生成的 report.txt 发给技术支持。
请不要发送完整 API Key。
API Key 始终只保存在您的本机，不会上传或分享。

报告生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
"@

    try {
        [System.IO.File]::WriteAllText($reportPath, $reportContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Success "安装完成报告已生成: $reportPath"
        Write-Log "INFO" "安装报告已保存: $reportPath"
    }
    catch {
        Write-Error-Msg "报告生成失败: $($_.Exception.Message)"
        Write-Log "ERROR" "报告写入失败: $_"
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
        Write-Host "            测试安全模式已完成                                " -ForegroundColor Yellow
        Write-Host "                                                              " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host ""
        if ($script:ClaudeInstalled) {
            Write-Success "Claude Code 已检测到"
        }
        else {
            Write-Warning "测试安全模式：未安装 Claude Code"
            Write-ResultLine "Claude Code 启动" "SKIP" "未验证"
        }
        Write-Success "DeepSeek 配置写入已验证"
        Write-ResultLine "API 测试" "SKIP" "测试安全模式强制跳过"
        if ($script:TestProjectPath) {
            Write-Success "测试项目已创建"
        }
        Write-Host ""
        Write-Info "测试安全模式不会安装、更新或卸载 Claude Code。"
        Write-Info "安装完成报告: $($script:ReportPath)"
    }
    elseif ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestPassed) {
        Write-Host "==============================================================" -ForegroundColor Green
        Write-Host "                                                              " -ForegroundColor Green
        Write-Host "                 安装流程全部完成！                            " -ForegroundColor Green
        Write-Host "                                                              " -ForegroundColor Green
        Write-Host "==============================================================" -ForegroundColor Green
        Write-Host ""
        Write-Success "Claude Code 已安装"
        Write-Success "DeepSeek 配置已写入"
        Write-Success "API 测试通过"
        Write-Success "测试项目已创建"
        Write-Host ""
        Write-Info "您现在可以运行 claude 开始使用！"
        if ($script:TestProjectPath) {
            Write-Info "建议进入测试项目目录:"
            Write-Host "  cd `"$($script:TestProjectPath)`"" -ForegroundColor Cyan
            Write-Host "  claude" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Info "安装完成报告: $($script:ReportPath)"
        Write-Info "如遇问题请运行「一键诊断.cmd」"
    }
    elseif ($script:ClaudeInstalled -and $script:ConfigWritten) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "                                                              " -ForegroundColor Yellow
        Write-Host "            安装部分完成（API 测试未通过）                     " -ForegroundColor Yellow
        Write-Host "                                                              " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Success "Claude Code 已安装"
        Write-Success "DeepSeek 配置已写入"
        Write-Warning "API 测试: $script:ApiTestFailReason"
        Write-Host ""
        Write-Warning "当前未完全验证可用，请确认:"
        Write-Info "  1. API Key 是否正确"
        Write-Info "  2. DeepSeek 账户余额是否充足"
        Write-Info "  3. 网络是否正常"
        Write-Info "  4. 运行「一键诊断.cmd」获取详细信息"
        Write-Host ""
        Write-Info "安装完成报告: $($script:ReportPath)"
    }
    elseif ($script:ClaudeInstalled) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "            安装部分完成                                      " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Success "Claude Code 已安装"
        Write-Warning "DeepSeek 配置未完成"
        Write-Info "请稍后运行 configure-deepseek.ps1 配置 API Key。"
    }
    elseif ($script:ClaudeInstallStatus -match "needs_restart") {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "            需要重开终端后继续                                " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Warning "当前终端还无法识别新安装的命令。"
        Write-Info "下一步: 关闭此窗口，重新双击「开始安装.cmd」。"
    }
    else {
        Write-Host "==============================================================" -ForegroundColor Red
        Write-Host "            安装未完成                                        " -ForegroundColor Red
        Write-Host "==============================================================" -ForegroundColor Red
        Write-Host ""
        Write-Error-Msg "Claude Code 安装未成功。"
        Write-Info "下一步: 运行「一键诊断.cmd」生成 report.txt，并将报告发给技术支持。"
    }

    Write-Host ""
    Write-Info "日志文件: $(Get-LogFilePath)"
    Write-Host ""
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
        if ($script:ClaudeInstallStatus -match "needs_restart") {
            Write-Warning "当前需要重开终端后继续，已跳过后续配置步骤。"
        }
        else {
            Write-Error-Msg "Claude Code 安装未成功，跳过后续配置步骤。"
            Write-Info "请先解决安装问题后重新运行本脚本。"
        }
        Show-CompletionPage
        return
    }

    Pause-ForUser -Force

    # Step 3: 获取 API Key
    $apiKey = Step-GetApiKey
    if ($null -eq $apiKey) {
        Write-Warning "未提供 API Key，跳过配置步骤。"
        Write-Info "您可以稍后运行 configure-deepseek.ps1 单独配置。"
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
        & $doctorScript -SkipApiTest:$script:EffectiveSkipApiTest
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

    $ubuntuInfo = Test-UbuntuInWsl
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
    Write-Info "有两种配置方式:"
    Write-Host ""
    Write-Host "  方式 A（推荐）: 在 WSL 终端中手动运行" -ForegroundColor Green
    Write-Host "    1. 打开 WSL 终端（开始菜单搜索 'Ubuntu'）" -ForegroundColor White
    Write-Host "    2. cd 到本项目目录" -ForegroundColor White
    Write-Host "    3. 运行: chmod +x install_wsl.sh && ./install_wsl.sh" -ForegroundColor White
    Write-Host ""
    Write-Host "  方式 B（实验性，不推荐新手使用）: Windows 端调用 WSL" -ForegroundColor DarkGray
    Write-Host "    （将自动转换路径并执行，但可能因路径/权限问题失败）" -ForegroundColor White

    if (-not (Confirm-UserChoice -Message "是否使用方式 A（推荐）在 WSL 终端中手动运行？")) {
        # 方式 B：二次确认
        Write-Warning "您选择了方式 B（实验性，不推荐新手使用）。"
        Write-Warning "此方式可能因路径含特殊字符、WSL 配置差异等原因失败。"
        if (-not (Confirm-UserChoice -Message "确认使用方式 B（实验性）？建议选择 N 改用方式 A")) {
            Write-Info "请在 WSL 终端中手动运行 install_wsl.sh。"
            return
        }

        # 安全检查：路径是否包含危险字符
        if (-not (Test-WslPathSafe -WindowsPath $ScriptDir)) {
            Write-Error-Msg "无法安全地自动传递路径到 WSL。"
            Write-Info "请改用方式 A：在 WSL 终端中手动运行 install_wsl.sh。"
            return
        }

        # 使用 wslpath 转换路径
        $wslPath = Convert-WindowsPathToWslPath -WindowsPath $ScriptDir
        if ($null -eq $wslPath) {
            Write-Error-Msg "无法自动转换 Windows 路径到 WSL 路径。"
            Write-Info "请改用方式 A：在 WSL 终端中手动运行 install_wsl.sh。"
            return
        }

        Write-Info "正在 WSL 中执行 install_wsl.sh（可能需要几分钟）..."
        Write-Info "WSL 路径: $wslPath"
        $wslResult = Invoke-CommandSafe -Command "wsl" -Arguments @(
            "bash", "-lc",
            "cd '$wslPath' && chmod +x install_wsl.sh && ./install_wsl.sh"
        ) -TimeoutSec 600 -ProgressMessage "仍在 WSL 中执行配置，请勿关闭窗口。"

        if ($wslResult.Success) {
            Write-Success "WSL 配置完成！"
            Write-Host $wslResult.Output
        }
        else {
            Write-Error-Msg "WSL 自动配置过程中出现错误。"
            Write-Info "请改用方式 A：在 WSL 终端中手动运行 install_wsl.sh。"
            Write-Info "具体方法: 打开 Ubuntu 终端，cd 到本项目目录，运行:"
            Write-Host "  chmod +x install_wsl.sh && ./install_wsl.sh" -ForegroundColor Cyan
        }
    }
    else {
        Write-Info "请在 WSL 终端中手动运行 install_wsl.sh。"
        Write-Info "具体方法: 打开 Ubuntu 终端，cd 到本项目目录，运行:"
        Write-Host "  chmod +x install_wsl.sh && ./install_wsl.sh" -ForegroundColor Cyan
    }
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
    Write-Host "  [2] 遇到问题：一键诊断                                      " -ForegroundColor White
    Write-Host "  [3] 修改 / 恢复 / 卸载配置                                  " -ForegroundColor White
    Write-Host "  [4] 高级选项                                                " -ForegroundColor White
    Write-Host "  [5] 退出                                                    " -ForegroundColor White
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""

    $choice = Read-Host "请输入选项编号 (1-5，直接回车默认选 1)"

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
            Write-Log "INFO" "用户选择: 恢复或卸载配置"
            Start-UninstallMenu
        }
        "4" {
            Write-Log "INFO" "用户选择: 高级选项"
            Show-AdvancedMenu
        }
        "5" {
            Write-Log "INFO" "用户选择: 退出"
            Write-Info "感谢使用！"
            Write-Info "如遇问题请运行「一键诊断.cmd」获取诊断报告。"
            exit 0
        }
        default {
            Write-Error-Msg "无效选项，请输入 1-5。"
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
    try {
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
}

# 执行主流程
Main
