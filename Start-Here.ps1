# ============================================================
# Start-Here.ps1 - Claude Code + DeepSeek 懒人安装总控入口 (v1.3.0)
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
    [switch]$SkipDisclaimer
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

$ScriptVersion = "1.3.0"

# 状态变量
$script:ClaudeInstalled = $false
$script:ClaudeInstallMethod = ""
$script:ConfigWritten = $false
$script:ApiTestPassed = $false
$script:ApiTestSkipped = $false
$script:ApiTestFailed = $false
$script:ApiTestFailReason = ""
$script:TestProjectPath = $null
$script:ReportPath = $null

# ============================================================
# 辅助函数
# ============================================================

function Write-Step {
    param([string]$Title)
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
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
    if (-not $NonInteractive) {
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
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║   Claude Code + DeepSeek API 本地配置助手 v$ScriptVersion            ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
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
    Write-Host "    ❌ 本工具不提供 Claude 账号" -ForegroundColor Red
    Write-Host "    ❌ 本工具不提供 DeepSeek API Key" -ForegroundColor Red
    Write-Host "    ❌ 本工具不做 API 中转" -ForegroundColor Red
    Write-Host "    ✅ API Key 只写入本机 Claude Code 配置" -ForegroundColor Green
    Write-Host "    ✅ 如进行 API 测试，Key 只发送到 DeepSeek 官方接口" -ForegroundColor Green
    Write-Host "    ✅ API 调用费用由用户和 DeepSeek 官方结算" -ForegroundColor Green
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

    # Windows 版本
    $winInfo = Get-WindowsVersionInfo
    if ($winInfo.IsSupported) {
        $osLabel = if ($winInfo.IsWindows11) { "Windows 11" } else { "Windows 10" }
        Write-ResultLine "Windows 版本" "OK" "$osLabel (Build $($winInfo.Build))"
    }
    else {
        Write-ResultLine "Windows 版本" "ERROR" "不支持的系统: $($winInfo.Version)"
    }

    # PowerShell 版本
    $psInfo = Get-PowerShellVersionInfo
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
    }
}

# ============================================================
# Step 2: 安装 Claude Code（Native Install 优先）
# ============================================================

function Step-InstallClaudeCode {
    Write-Step "Step 2/7：安装 Claude Code"

    # 检查是否已安装
    $existingVersion = Test-ClaudeInstalled
    if ($existingVersion) {
        Write-Success "Claude Code 已安装: $existingVersion"

        if (-not $NonInteractive) {
            $updateChoice = Read-Host "是否更新到最新版本？(Y/N，直接回车跳过)"
            if ($updateChoice -eq "Y" -or $updateChoice -eq "y") {
                Write-Info "正在更新 Claude Code..."
                Update-ClaudeCode
            }
            else {
                Write-Info "跳过更新，保持现有版本。"
            }
        }

        Write-Info "运行 claude doctor..."
        $doctorResult = Invoke-CommandSafe -Command "claude" -Arguments @("doctor") -TimeoutSec 180
        if ($doctorResult.Success) {
            Write-Host $doctorResult.Output
        }
        else {
            Write-Log "DEBUG" "claude doctor 输出: $($doctorResult.Error)"
        }

        $script:ClaudeInstalled = $true
        $script:ClaudeInstallMethod = "已存在"
        return $true
    }

    # ============================================================
    # 尝试 Native Install（官方推荐）
    # ============================================================
    Write-Info "默认采用 Claude 官方推荐的 Native Install 方式安装..."
    Write-Info "如环境不兼容，将使用 npm 方式作为备用。"
    Write-Host ""

    $nativeOk = $false
    try {
        Write-Info "正在从 Claude 官方下载安装脚本..."
        Write-Info "执行: irm https://claude.ai/install.ps1 | iex"

        $tempInstallScript = Join-Path $env:TEMP "claude_native_install_$PID.ps1"
        $downloadResult = Invoke-CommandSafe -Command "powershell" -Arguments @(
            "-NoProfile", "-Command",
            "Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -OutFile '$tempInstallScript'"
        ) -TimeoutSec 180

        if ($downloadResult.Success -and (Test-Path $tempInstallScript)) {
            $installResult = Invoke-CommandSafe -Command "powershell" -Arguments @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tempInstallScript
            ) -TimeoutSec 600
            Remove-Item $tempInstallScript -Force -ErrorAction SilentlyContinue

            if ($installResult.Success) {
                Write-Success "Native Install 方式安装成功！"
                $nativeOk = $true
            }
            else {
                Write-Warning "Native Install 未成功完成。"
                Write-Log "WARN" "Native Install 输出: $($installResult.Error)"
            }
        }
        else {
            Write-Warning "无法下载 Claude 官方安装脚本（网络问题或官方服务异常）"
            Write-Log "WARN" "下载 install.ps1 失败: $($downloadResult.Error)"
        }
    }
    catch {
        Write-Warning "Native Install 尝试异常: $($_.Exception.Message)"
        Write-Log "ERROR" "Native Install 异常: $_"
    }

    # ============================================================
    # Native Install 成功，验证
    # ============================================================
    if ($nativeOk) {
        $newVersion = Test-ClaudeInstalled
        if ($newVersion) {
            Write-Success "Claude Code 安装验证通过: $newVersion"
            $script:ClaudeInstalled = $true
            $script:ClaudeInstallMethod = "Native Install"
            return $true
        }
        else {
            Write-Warning "安装脚本已执行但 claude 命令未找到。"
            Write-Warning "（新安装的软件需要重启终端才能被识别，就像刚装完 App 要点一下图标一样）"
        }
    }

    # ============================================================
    # npm fallback
    # ============================================================
    Write-Info ""
    Write-Info "正在使用 npm 备用方式安装 Claude Code..."
    Write-Info "这种安装方式在 DeepSeek 官方集成文档中也有采用。"
    Write-Host ""

    # 检查 Node.js >= 18
    $nodeInfo = Test-NodeJsInstalled
    if (-not $nodeInfo.Installed -or -not $nodeInfo.IsSupported) {
        Write-Warning "Claude Code 需要 Node.js 18 或更高版本。"

        # 尝试 winget 安装
        $wingetOk = Test-CommandAvailable -CommandName "winget"
        if ($wingetOk) {
            Write-Info "检测到 winget，可以自动安装 Node.js LTS。"
            if ($NonInteractive -or (Confirm-UserChoice -Message "是否使用 winget 安装 Node.js LTS？（将修改系统环境）")) {
                Write-Info "正在使用 winget 安装 Node.js LTS（可能需要几分钟）..."
                $installResult = Invoke-CommandSafe -Command "winget" -Arguments @(
                    "install", "OpenJS.NodeJS.LTS",
                    "--accept-package-agreements",
                    "--accept-source-agreements",
                    "--silent"
                ) -TimeoutSec 900
                if ($installResult.Success) {
                    Write-Success "Node.js 安装完成！"
                    Write-Warning "请关闭并重新打开 PowerShell/命令提示符，然后重新运行本脚本。"
                    Write-Warning "这样 Node.js 和 npm 命令才能被正确识别。"
                }
                else {
                    Write-Error-Msg "Node.js 自动安装失败。"
                    Write-Info "请手动下载安装: https://nodejs.org (选择 LTS 版本)"
                    Write-Info "安装完成后重新运行本脚本。"
                }
            }
            else {
                Write-Info "请手动安装 Node.js 后重新运行本脚本。"
                Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
            }
        }
        else {
            Write-Info "未检测到 winget，请手动安装 Node.js:"
            Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
            Write-Info "安装完成后，关闭并重新打开终端，然后重新运行本脚本。"
        }

        $script:ClaudeInstalled = $false
        return $false
    }

    # npm 安装
    Write-Info "执行: npm install -g @anthropic-ai/claude-code@latest（首次下载可能需要几分钟）"
    $installResult = Invoke-CommandSafe -Command "npm" -Arguments @("install", "-g", "@anthropic-ai/claude-code@latest") -TimeoutSec 900

    if ($installResult.Success) {
        Write-Success "npm 安装 Claude Code 成功！"
    }
    else {
        Write-Error-Msg "npm 安装过程中出现错误:"
        Write-Host $installResult.Error -ForegroundColor Red

        if ($installResult.Error -match "EACCES|permission|权限") {
            Write-Warning "可能是 npm 全局安装权限问题。"
            Write-Warning "建议使用 nvm 管理 Node.js，或使用官方 Native Install 方式。"
        }
        $script:ClaudeInstalled = $false
        return $false
    }

    # 验证
    $newVersion = Test-ClaudeInstalled
    if ($newVersion) {
        Write-Success "Claude Code 安装验证通过: $newVersion"
        Write-Info "运行 claude doctor..."
        $doctorResult = Invoke-CommandSafe -Command "claude" -Arguments @("doctor") -TimeoutSec 180
        if ($doctorResult.Success) {
            Write-Host $doctorResult.Output
        }
        $script:ClaudeInstalled = $true
        $script:ClaudeInstallMethod = "npm fallback"
        return $true
    }
    else {
        Write-Warning "claude 命令未找到！"
        Write-Warning "这可能是因为 PowerShell 的 PATH 没有刷新。"
        Write-Warning "（新安装的软件需要重启终端才能被识别）"
        Write-Info "请尝试:"
        Write-Info "  1. 关闭并重新打开 PowerShell / 命令提示符"
        Write-Info "  2. 或运行: refreshenv (如果安装了 Chocolatey)"
        Write-Info "  3. 或手动将 npm 全局 bin 目录添加到 PATH"

        $npmPrefix = Invoke-CommandSafe -Command "npm" -Arguments @("prefix", "-g")
        if ($npmPrefix.Success) {
            Write-Info "npm 全局安装路径: $($npmPrefix.Output.Trim())"
        }

        $script:ClaudeInstalled = $false
        return $false
    }
}

function Update-ClaudeCode {
    # 尝试 Native Install 方式更新
    try {
        Write-Info "尝试通过官方 Native Install 更新..."
        $tempScript = Join-Path $env:TEMP "claude_update_$PID.ps1"
        Invoke-CommandSafe -Command "powershell" -Arguments @(
            "-NoProfile", "-Command",
            "Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' -OutFile '$tempScript'"
        ) -TimeoutSec 180
        if (Test-Path $tempScript) {
            $result = Invoke-CommandSafe -Command "powershell" -Arguments @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tempScript
            ) -TimeoutSec 600
            Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
            if ($result.Success) {
                Write-Success "Claude Code 已更新（Native Install）。"
                return
            }
        }
    }
    catch {
        Write-Log "DEBUG" "Native Install 更新失败，尝试 npm: $_"
    }

    # npm fallback
    Write-Info "使用 npm 更新..."
    $result = Invoke-CommandSafe -Command "npm" -Arguments @("install", "-g", "@anthropic-ai/claude-code@latest") -TimeoutSec 900
    if ($result.Success) {
        Write-Success "Claude Code 已更新（npm）。"
    }
    else {
        Write-Warning "更新失败，将继续使用现有版本。"
    }
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
    Write-Host "  ┌─────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │  获取 API Key 步骤:                                     │" -ForegroundColor Cyan
    Write-Host "  │  1. 打开 https://platform.deepseek.com/api_keys          │" -ForegroundColor Cyan
    Write-Host "  │  2. 注册/登录 DeepSeek 账号                              │" -ForegroundColor Cyan
    Write-Host "  │  3. 点击「创建 API Key」                                 │" -ForegroundColor Cyan
    Write-Host "  │  4. 复制生成的 Key（通常以 sk- 开头）                    │" -ForegroundColor Cyan
    Write-Host "  │  5. 回到此窗口粘贴                                       │" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
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

    $apiKey = Read-SecretInput -Prompt "请粘贴您的 DeepSeek API Key"

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

    if ($SkipApiTest) {
        Write-ResultLine "API 测试" "SKIP" "已按参数跳过"
        Write-Info "注意: 未验证 API 是否可用。可稍后运行 doctor.ps1 测试。"
        $script:ApiTestSkipped = $true
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
    }
}

# ============================================================
# Step 6: 创建测试项目
# ============================================================

function Step-CreateTestProject {
    Write-Step "Step 6/7：创建测试项目"

    $desktopPath = [Environment]::GetFolderPath("Desktop")
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

    $overallStatus = if ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestPassed) { "完整成功" }
        elseif ($script:ClaudeInstalled -and $script:ConfigWritten) { "部分成功" }
        else { "未完成" }

    $reportContent = @"
Claude Code + DeepSeek 安装完成报告
======================================

生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
脚本版本: v$ScriptVersion
运行模式: 懒人一键安装

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

    if ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestPassed) {
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                                                              ║" -ForegroundColor Green
        Write-Host "║                 安装流程全部完成！                            ║" -ForegroundColor Green
        Write-Host "║                                                              ║" -ForegroundColor Green
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
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
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║                                                              ║" -ForegroundColor Yellow
        Write-Host "║            安装部分完成（API 测试未通过）                     ║" -ForegroundColor Yellow
        Write-Host "║                                                              ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
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
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║            安装部分完成                                      ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""
        Write-Success "Claude Code 已安装"
        Write-Warning "DeepSeek 配置未完成"
        Write-Info "请稍后运行 configure-deepseek.ps1 配置 API Key。"
    }
    else {
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "║            安装未完成                                        ║" -ForegroundColor Red
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host ""
        Write-Error-Msg "Claude Code 安装未成功。"
        Write-Info "请尝试以下操作:"
        Write-Info "  1. 检查上述错误信息"
        Write-Info "  2. 手动安装 Node.js 后重试"
        Write-Info "  3. 运行「一键诊断.cmd」获取诊断报告"
        Write-Info "  4. 将诊断报告发给技术支持"
    }

    Write-Host ""
    Write-Info "日志文件: $(Get-LogFilePath)"
    Write-Host ""
}

# ============================================================
# 懒人一键安装流程（模式 1）
# ============================================================

function Start-LazyInstall {
    Write-Log "INFO" "开始懒人一键安装流程"

    # Step 1: 环境检查
    $envResult = Step-CheckEnvironment

    Pause-ForUser

    # Step 2: 安装 Claude Code
    $claudeOk = Step-InstallClaudeCode
    if (-not $claudeOk) {
        Write-Error-Msg "Claude Code 安装未成功，跳过后续配置步骤。"
        Write-Info "请先解决安装问题后重新运行本脚本。"
        Show-CompletionPage
        return
    }

    Pause-ForUser

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
    Step-CreateTestProject

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

    . (Join-Path $ScriptDir "configure-deepseek.ps1")
    # configure-deepseek.ps1 有自己的完整交互流程
    exit 0
}

function Start-DoctorOnly {
    Write-Step "环境诊断"

    $doctorScript = Join-Path $ScriptDir "doctor.ps1"
    if (Test-Path $doctorScript) {
        & $doctorScript -SkipApiTest:$SkipApiTest
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

    Write-Info "检测到 WSL Ubuntu。"
    Write-Info "有两种配置方式:"
    Write-Host ""
    Write-Host "  方式 A（推荐）: 在 WSL 终端中手动运行" -ForegroundColor Cyan
    Write-Host "    1. 打开 WSL 终端（开始菜单搜索 'Ubuntu'）" -ForegroundColor White
    Write-Host "    2. cd 到本项目目录" -ForegroundColor White
    Write-Host "    3. 运行: chmod +x install_wsl.sh && ./install_wsl.sh" -ForegroundColor White
    Write-Host ""
    Write-Host "  方式 B: Windows 端调用 WSL" -ForegroundColor Cyan
    Write-Host "    （将自动转换路径并执行）" -ForegroundColor White

    if (Confirm-UserChoice -Message "是否使用方式 B 自动在 WSL 中运行安装脚本？") {
        # Windows 路径转 WSL 路径
        $winPath = $ScriptDir
        $wslPath = $winPath -replace '\\', '/' -replace '^([A-Za-z]):', '/mnt/$1'
        $wslPath = $wslPath.ToLower() -replace '^/mnt/([a-z])/', { "/mnt/$($_.Groups[1].Value.ToLower())/" }

        Write-Info "正在 WSL 中执行 install_wsl.sh（可能需要几分钟）..."
        $wslResult = Invoke-CommandSafe -Command "wsl" -Arguments @(
            "bash", "-lc",
            "cd '$wslPath' && chmod +x install_wsl.sh && ./install_wsl.sh"
        ) -TimeoutSec 600

        if ($wslResult.Success) {
            Write-Success "WSL 配置完成！"
            Write-Host $wslResult.Output
        }
        else {
            Write-Error-Msg "WSL 配置过程中出现错误:"
            Write-Host $wslResult.Error -ForegroundColor Red
            Write-Info "请尝试方式 A（在 WSL 终端中手动运行）。"
        }
    }
    else {
        Write-Info "请在 WSL 终端中手动运行 install_wsl.sh。"
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
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                    请选择要执行的操作                        ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  [1] 懒人一键安装（推荐）                                    ║" -ForegroundColor Green
    Write-Host "║      自动检测 → 安装 → 配置 → 测试 → 生成报告               ║" -ForegroundColor White
    Write-Host "║  [2] 仅配置 DeepSeek API                                    ║" -ForegroundColor White
    Write-Host "║      （Claude Code 已安装的情况）                            ║" -ForegroundColor White
    Write-Host "║  [3] 仅运行环境诊断（不安装任何东西）                        ║" -ForegroundColor White
    Write-Host "║  [4] 配置 WSL Ubuntu 环境（高级选项）                        ║" -ForegroundColor White
    Write-Host "║  [5] 恢复或卸载配置                                          ║" -ForegroundColor White
    Write-Host "║  [6] 退出                                                    ║" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    $choice = Read-Host "请输入选项编号 (1-6，直接回车默认选 1)"

    if ([string]::IsNullOrWhiteSpace($choice)) {
        $choice = "1"
    }

    switch ($choice) {
        "1" {
            Write-Log "INFO" "用户选择: 懒人一键安装"
            Start-LazyInstall
        }
        "2" {
            Write-Log "INFO" "用户选择: 仅配置 DeepSeek API"
            Start-ConfigureOnly
        }
        "3" {
            Write-Log "INFO" "用户选择: 仅运行诊断"
            Start-DoctorOnly
        }
        "4" {
            Write-Log "INFO" "用户选择: WSL 配置"
            Start-WslSetup
        }
        "5" {
            Write-Log "INFO" "用户选择: 恢复或卸载配置"
            Start-UninstallMenu
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
            Write-Info "非交互模式：自动开始懒人一键安装..."
            Start-LazyInstall
            return
        }

        # 显示主菜单
        Show-MainMenu
    }
    catch {
        Write-Error-Msg "脚本执行过程中发生未预期的错误。"
        Write-Info "  1. 关闭窗口后重新打开"
        Write-Info "  2. 重新运行「开始安装.cmd」"
        Write-Info "  3. 如问题持续，运行「一键诊断.cmd」并将 report.txt 发给技术支持"
        Write-Log "ERROR" "未预期错误: $($_.Exception.Message)"
        Write-Log "ERROR" "堆栈: $($_.ScriptStackTrace)"
        Write-Info "日志文件: $(Get-LogFilePath)"
        Pause-ForUser
        exit 1
    }
}

# 执行主流程
Main
