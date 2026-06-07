# ============================================================
# install.ps1 - Claude Code + DeepSeek 一键安装配置脚本
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# 功能:
#   1. 环境检测
#   2. Claude Code 安装
#   3. DeepSeek API 配置
#   4. 诊断
#
# 合规声明:
#   本脚本仅做本地安装和配置。
#   不提供 Claude 账号、API Key、中转服务。
#   用户需自备 DeepSeek API Key。
# ============================================================

param(
    [switch]$SkipDisclaimer,  # 跳过免责声明（仅供高级用户）
    [switch]$Quiet,           # 安静模式（减少输出）
    [ValidateSet("Menu", "InstallOnly", "InstallAndConfigure", "Doctor", "ConfigureOnly")]
    [string]$Mode = "Menu",
    [switch]$NonInteractive,
    [switch]$SkipApiTest
)

# ============================================================
# 初始化
# ============================================================

Set-StrictMode -Version Latest
# 使用 Continue 模式：所有错误由显式 try/catch 处理，避免非预期崩溃
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }
. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")
$ScriptDir = Initialize-CcdiScript -ScriptName "install"

# 脚本版本
$ScriptVersion = "1.3.0"

# 状态变量（用于最终摘要）
$script:ClaudeInstalled = $false
$script:ConfigWritten = $false
$script:ApiTestPassed = $false
$script:ApiTestSkipped = $false
$script:ApiTestFailed = $false
$script:ApiTestFailReason = ""

# ============================================================
# 免责声明
# ============================================================

function Show-Disclaimer {
    if ($NonInteractive) {
        Write-Log "INFO" "非交互模式：跳过免责声明确认"
        return
    }

    Clear-Host
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "     Claude Code + DeepSeek 一键安装配置助手 v$ScriptVersion         " -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "【重要免责声明】" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  本工具是一个本地安装配置助手，仅帮助您在本地电脑上:" -ForegroundColor White
    Write-Host "    1. 安装 Claude Code CLI 工具" -ForegroundColor White
    Write-Host "    2. 配置 DeepSeek API 连接" -ForegroundColor White
    Write-Host "    3. 诊断环境问题" -ForegroundColor White
    Write-Host ""
    Write-Host "  本工具不提供以下内容:" -ForegroundColor Yellow
    Write-Host "     不出售 Claude 账号" -ForegroundColor Red
    Write-Host "     不出售 Anthropic API Key" -ForegroundColor Red
    Write-Host "     不出售 DeepSeek API Key" -ForegroundColor Red
    Write-Host "     不做 API 中转/代理服务" -ForegroundColor Red
    Write-Host "     不做账号共享" -ForegroundColor Red
    Write-Host "     不做任何破解或绕过限制" -ForegroundColor Red
    Write-Host ""
    Write-Host "  您需要自行准备:" -ForegroundColor Green
    Write-Host "     一台 Windows 10/11 电脑" -ForegroundColor Green
    Write-Host "     自己的 DeepSeek API Key (在 platform.deepseek.com 获取)" -ForegroundColor Green
    Write-Host "     基本的网络连接" -ForegroundColor Green
    Write-Host ""
    Write-Host "  API 费用、余额、限流由 DeepSeek 官方管理，与本站无关。" -ForegroundColor Yellow
    Write-Host "  本工具不会把您的 API Key 发送给第三方或服务提供者。" -ForegroundColor Yellow
    Write-Host "  如选择 API 测试，Key 会发送到 DeepSeek 官方接口验证。" -ForegroundColor Yellow
    Write-Host "  所有配置仅保存在您的本机。" -ForegroundColor Yellow
    Write-Host ""

    if (-not $SkipDisclaimer) {
        $agree = Read-Host "请输入 Y 确认您已阅读并同意以上声明 (输入 N 退出)"
        if ($agree -ne "Y" -and $agree -ne "y" -and $agree -ne "是") {
            Write-Host "已取消安装。感谢您的关注！" -ForegroundColor Cyan
            Write-Log "INFO" "用户拒绝免责声明，脚本退出"
            exit 0
        }
    }

    Write-Log "INFO" "用户已同意免责声明"
}

# ============================================================
# 步骤 1: 系统环境检测
# ============================================================

function Step-CheckEnvironment {
    Write-Step "第 1 步：系统环境检测"

    $checks = @()

    # Windows 版本
    $winInfo = Get-WindowsVersionInfo
    if ($winInfo.IsSupported) {
        $osLabel = if ($winInfo.IsWindows11) { "Windows 11" } else { "Windows 10" }
        Write-Result "Windows 版本" "OK" "$osLabel (Build $($winInfo.Build))"
        $checks += @{ Name = "Windows 版本"; Status = "OK" }
    }
    else {
        Write-Result "Windows 版本" "ERROR" "不支持的操作系统: $($winInfo.Version)"
        Write-Warning "本工具仅支持 Windows 10/11。其他系统请使用 WSL 或手动安装。"
        $checks += @{ Name = "Windows 版本"; Status = "ERROR" }
    }

    # PowerShell 版本
    $psInfo = Get-PowerShellVersionInfo
    if ($psInfo.IsSupported) {
        Write-Result "PowerShell 版本" "OK" "$($psInfo.Version) ($($psInfo.Edition))"
        $checks += @{ Name = "PowerShell"; Status = "OK" }
    }
    else {
        Write-Result "PowerShell 版本" "ERROR" "$($psInfo.Version) - 版本过低"
        Write-Warning "请升级 PowerShell 到 5.1 或更高版本。"
        Write-Info "下载地址: https://aka.ms/powershell (选择最新版安装)"
        $checks += @{ Name = "PowerShell"; Status = "ERROR" }
    }

    # 用户权限
    if (Test-IsAdministrator) {
        Write-Result "用户权限" "WARN" "以管理员权限运行（非必须）"
        Write-Warning "当前以管理员权限运行，但本工具不需要管理员权限。"
        $checks += @{ Name = "用户权限"; Status = "WARN" }
    }
    else {
        Write-Result "用户权限" "OK" "普通用户权限（推荐）"
        $checks += @{ Name = "用户权限"; Status = "OK" }
    }

    # Git
    $gitVersion = Test-GitInstalled
    if ($gitVersion) {
        Write-Result "Git" "OK" $gitVersion
        $checks += @{ Name = "Git"; Status = "OK" }
    }
    else {
        Write-Result "Git" "WARN" "未检测到 Git"
        Write-Warning "Git 不是必须的，但推荐安装。可从 https://git-scm.com 下载。"
        $checks += @{ Name = "Git"; Status = "WARN" }
    }

    # VS Code
    $codeVersion = Test-CodeInstalled
    if ($codeVersion) {
        Write-Result "VS Code" "OK" $codeVersion.Split("`n")[0]
        $checks += @{ Name = "VS Code"; Status = "OK" }
    }
    else {
        Write-Result "VS Code" "WARN" "未检测到 code 命令"
        Write-Warning "如果您安装了 VS Code，请在 VS Code 中按 Ctrl+Shift+P，"
        Write-Warning "搜索 'Shell Command: Install code command in PATH' 并执行。"
        $checks += @{ Name = "VS Code"; Status = "WARN" }
    }

    # WSL
    $wslInfo = Test-WslInstalled
    if ($wslInfo.Installed) {
        Write-Result "WSL" "OK" "已安装"
        $ubuntuInfo = Test-UbuntuInWsl
        if ($ubuntuInfo.Exists) {
            $statusText = if ($ubuntuInfo.Running) { "Running" } else { "已停止" }
            Write-Result "Ubuntu (WSL)" "OK" $statusText
            $checks += @{ Name = "Ubuntu"; Status = "OK" }
        }
        else {
            Write-Result "Ubuntu (WSL)" "WARN" "未安装 Ubuntu 发行版"
            $checks += @{ Name = "Ubuntu"; Status = "WARN" }
        }
    }
    else {
        Write-Result "WSL" "SKIP" "未启用（可选功能）"
        $checks += @{ Name = "WSL"; Status = "SKIP" }
    }

    # Claude Code 检测
    $claudeVersion = Test-ClaudeInstalled
    if ($claudeVersion) {
        Write-Result "Claude Code CLI" "OK" $claudeVersion
        $checks += @{ Name = "Claude Code"; Status = "OK" }
    }
    else {
        Write-Result "Claude Code CLI" "WARN" "未安装"
        $checks += @{ Name = "Claude Code"; Status = "WARN" }
    }

    # 配置文件检测
    $configInfo = Test-ClaudeConfigExists
    if ($configInfo.Exists) {
        if ($configInfo.IsValid) {
            if ($configInfo.HasEnv) {
                Write-Result "Claude 配置文件" "OK" "已存在 ($($configInfo.EnvCount) 个环境变量)"
            }
            else {
                Write-Result "Claude 配置文件" "WARN" "存在但缺少 env 配置"
            }
            $checks += @{ Name = "配置文件"; Status = "OK" }
        }
        else {
            Write-Result "Claude 配置文件" "ERROR" "JSON 格式无效"
            $checks += @{ Name = "配置文件"; Status = "ERROR" }
        }
    }
    else {
        Write-Result "Claude 配置文件" "SKIP" "尚未创建（将在配置时创建）"
        $checks += @{ Name = "配置文件"; Status = "SKIP" }
    }

    # 网络检测
    Write-Info "正在检测网络连通性..."
    $netDeepSeek = Test-NetworkConnectivity -Url "https://api.deepseek.com"
    if ($netDeepSeek.Reachable) {
        Write-Result "DeepSeek API" "OK" "可访问 (延迟 $($netDeepSeek.LatencyMs)ms)"
        $checks += @{ Name = "DeepSeek 网络"; Status = "OK" }
    }
    else {
        Write-Result "DeepSeek API" "ERROR" "无法访问: $($netDeepSeek.Error)"
        Write-Warning "请检查："
        Write-Warning "  1. 网络是否正常连接"
        Write-Warning "  2. 是否需要配置代理/VPN"
        Write-Warning "  3. 在浏览器中打开 https://api.deepseek.com 看是否能访问"
        $checks += @{ Name = "DeepSeek 网络"; Status = "ERROR" }
    }

    Write-Host ""
    Write-Info "环境检测完成。"

    return $checks
}

# ============================================================
# 步骤 2: 安装 Claude Code
# ============================================================

function Step-InstallClaudeCode {
    Write-Step "第 2 步：安装 Claude Code"

    # 检查是否已安装
    $existingVersion = Test-ClaudeInstalled
    if ($existingVersion) {
        Write-Success "Claude Code 已安装: $existingVersion"

        if (-not $NonInteractive) {
            $updateChoice = Read-Host "是否更新到最新版本？(Y/N，直接回车跳过)"
            if ($updateChoice -eq "Y" -or $updateChoice -eq "y") {
                Write-Info "正在更新 Claude Code..."
                $updateResult = Invoke-CommandSafe -Command "npm" -Arguments @("install", "-g", "@anthropic-ai/claude-code@latest") -TimeoutSec 900
                if ($updateResult.Success) {
                    Write-Success "Claude Code 已更新到最新版本。"
                }
                else {
                    Write-Warning "更新失败，将继续使用现有版本。"
                }
            }
            else {
                Write-Info "跳过更新，保持现有版本。"
            }
        }
        else {
            Write-Info "非交互模式：跳过更新询问，保持现有版本。"
        }

        # 运行 claude doctor 检查状态
        Write-Info "正在运行 claude doctor..."
        $doctorResult = Invoke-CommandSafe -Command "claude" -Arguments @("doctor") -TimeoutSec 180
        if ($doctorResult.Success) {
            Write-Host $doctorResult.Output
        }
        else {
            Write-Warning "claude doctor 未返回正常结果（这可能是正常的）"
        }

        $script:ClaudeInstalled = $true
        return $true
    }

    # ============================================================
    # Node.js 检查（安装 Claude Code 前必须通过）
    # ============================================================

    Write-Info "正在检查 Node.js 环境..."

    $nodeInfo = Test-NodeJsInstalled
    if (-not $nodeInfo.Installed) {
        Write-Result "Node.js" "ERROR" $nodeInfo.ErrorMessage
        Write-Info "安装 Node.js 后，重新运行本脚本即可。"
        Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
        Write-Info "安装完成后，请关闭并重新打开 PowerShell 终端。"

        # 尝试使用 winget 安装 Node.js
        $wingetAvailable = Test-CommandAvailable -CommandName "winget"
        if ($wingetAvailable) {
            Write-Info "检测到 winget，可尝试自动安装 Node.js。"
            if (Confirm-UserChoice -Message "是否使用 winget 安装 Node.js？（将修改系统环境）") {
                Write-Info "正在使用 winget 安装 Node.js..."
                $installResult = Invoke-CommandSafe -Command "winget" -Arguments @("install", "OpenJS.NodeJS.LTS", "--silent", "--accept-package-agreements") -TimeoutSec 900
                if ($installResult.Success) {
                    Write-Success "Node.js 安装完成！"
                    Write-Warning "请关闭并重新打开 PowerShell 终端，然后重新运行本脚本。"
                    Write-Warning "这样 Node.js 和 npm 命令才能被正确识别。"
                }
                else {
                    Write-Error-Msg "Node.js 自动安装失败，请手动安装。"
                    Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
                }
            }
        }
        else {
            Write-Info "请手动下载安装 Node.js: https://nodejs.org (选择 LTS 版本)"
            Write-Info "安装完成后，重新打开 PowerShell 并运行本脚本。"
        }
        return $false
    }

    if (-not $nodeInfo.IsSupported) {
        Write-Result "Node.js 版本" "ERROR" $nodeInfo.ErrorMessage
        Write-Info "请升级 Node.js 到 v18 或更高版本后重试。"
        Write-Info "下载地址: https://nodejs.org (选择 LTS 版本)"
        return $false
    }

    Write-Result "Node.js" "OK" $nodeInfo.Version

    # 检查 npm
    $npmInfo = Test-NpmInstalled
    if (-not $npmInfo.Installed) {
        Write-Result "npm" "ERROR" $npmInfo.ErrorMessage
        Write-Info "请检查 Node.js 安装是否完整。"
        return $false
    }

    Write-Result "npm" "OK" $npmInfo.Version

    Write-Info "正在安装 Claude Code..."
    Write-Info "执行: npm install -g @anthropic-ai/claude-code@latest"

    $installResult = Invoke-CommandSafe -Command "npm" -Arguments @("install", "-g", "@anthropic-ai/claude-code@latest") -TimeoutSec 900

    if ($installResult.Success) {
        Write-Success "Claude Code 安装成功！"
    }
    else {
        Write-Error-Msg "安装过程中出现错误:"
        Write-Host $installResult.Error -ForegroundColor Red

        if ($installResult.Error -match "EACCES" -or $installResult.Error -match "permission") {
            Write-Warning "可能是 npm 全局安装权限问题。建议使用 nvm 管理 Node.js，或使用官方 Native Install 方式。"
            Write-Warning "参考 Claude Code 官方文档修复 npm 权限。"
        }

        return $false
    }

    # 验证安装
    Write-Info "验证安装..."
    $newVersion = Test-ClaudeInstalled
    if ($newVersion) {
        Write-Success "Claude Code 版本: $newVersion"

        # 运行 doctor
        Write-Info "运行 claude doctor..."
        $doctorResult = Invoke-CommandSafe -Command "claude" -Arguments @("doctor") -TimeoutSec 180
        if ($doctorResult.Success) {
            Write-Host $doctorResult.Output
        }
        $script:ClaudeInstalled = $true
    }
    else {
        Write-Warning "claude 命令未找到，正在刷新 PATH 并重新检测..."
        Refresh-CurrentProcessPath
        $newVersion = Test-ClaudeInstalled
        if ($newVersion) {
            Write-Success "Claude Code 检测成功（PATH 刷新后）: $newVersion"
            $script:ClaudeInstalled = $true
            return $true
        }

        Write-Warning "Claude Code 可能已安装，但当前终端还没有刷新 PATH。"
        Write-Warning "请关闭此窗口后重新打开 PowerShell，或运行 [开始安装.cmd]。"
        Write-Info "如果仍不行，请运行 [一键诊断.cmd] 获取诊断报告。"

        $npmPrefix = Invoke-CommandSafe -Command "npm" -Arguments @("prefix", "-g")
        if ($npmPrefix.Success) {
            $npmBinPath = $npmPrefix.Output.Trim()
            Write-Info "npm 全局安装路径: $npmBinPath"
        }

        $script:ClaudeInstalled = $false
        return $false
    }

    return $true
}

# ============================================================
# 步骤 3: 安装 VS Code 扩展
# ============================================================

function Step-InstallVSCodeExtension {
    Write-Step "第 3 步：配置 VS Code"

    $codeVersion = Test-CodeInstalled
    if (-not $codeVersion) {
        Write-Warning "未检测到 code 命令，跳过 VS Code 扩展安装。"
        Write-Info "请在 VS Code 中手动安装 Claude Code 扩展:"
        Write-Info "  1. 打开 VS Code"
        Write-Info "  2. 按 Ctrl+Shift+X 打开扩展面板"
        Write-Info "  3. 搜索 'Claude Code'"
        Write-Info "  4. 点击安装"
        return $false
    }

    $codeVerShort = ($codeVersion -split "`n")[0]
    Write-Info "检测到 VS Code: $codeVerShort"

    # 检查扩展是否已安装
    $extInstalled = Test-VSCodeExtensionInstalled
    if ($extInstalled) {
        Write-Success "Claude Code VS Code 扩展已安装。"
        return $true
    }

    Write-Info "正在安装 Claude Code VS Code 扩展..."
    $installResult = Invoke-CommandSafe -Command "code" -Arguments @("--install-extension", "anthropic.claude-code") -TimeoutSec 180

    if ($installResult.Success) {
        Write-Success "Claude Code VS Code 扩展安装成功！"
        return $true
    }
    else {
        Write-Warning "VS Code 扩展安装可能未成功（这不影响 Claude Code 命令行使用）"
        Write-Info "您可以稍后在 VS Code 中手动安装:"
        Write-Info "  扩展 ID: anthropic.claude-code"
        return $false
    }
}

# ============================================================
# 步骤 4: 配置 DeepSeek
# ============================================================

function Step-ConfigureDeepSeek {
    Write-Step "第 4 步：配置 DeepSeek API"

    if ($NonInteractive) {
        $envKey = Get-ApiKeyFromEnvironment
        if (-not $envKey.Found) {
            Write-Error-Msg "$($envKey.Error)。非交互模式不会读取明文命令行参数。"
            return $false
        }
        $apiKey = $envKey.Key
        Write-Info "已从环境变量 $($envKey.Source) 读取 API Key: $(Mask-ApiKey -Key $apiKey)"
    }
    else {
        Write-Info "现在需要配置您的 DeepSeek API Key。"
        Write-Info ""
        Write-Info "获取方式:"
        Write-Info "  1. 访问 https://platform.deepseek.com"
        Write-Info "  2. 注册/登录账号"
        Write-Info "  3. 进入 'API Keys' 页面"
        Write-Info "  4. 创建新的 API Key"
        Write-Info "  5. 复制 Key（通常以 sk- 开头）"
        Write-Info ""
        Write-Warning "注意: API Key 只会保存在您的本机配置中。"
        Write-Warning "如选择 API 测试，Key 会发送到 DeepSeek 官方接口验证，不会发送给第三方。"
        Write-Warning "输入时不会显示字符，这是安全保护，请直接粘贴后按回车。"
        Write-Host ""

        $apiKey = Read-SecretInput -Prompt "请粘贴您的 DeepSeek API Key"
    }

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Error-Msg "API Key 不能为空！配置已取消。"
        return $false
    }

    # 检查格式
    if (-not (Is-ApiKeyFormatValid -Key $apiKey)) {
        Write-Warning "API Key 格式看起来不典型。"
        if ($NonInteractive) {
            Write-Error-Msg "非交互模式下拒绝使用格式异常的 API Key。"
            return $false
        }
        if (-not (Confirm-UserChoice -Message "是否仍然使用此 Key？")) {
            Write-Info "配置已取消。"
            return $false
        }
    }

    Write-Info "正在写入配置..."

    # 写入配置
    $writeResult = Write-DeepSeekConfig -ApiKey $apiKey -NonInteractive:$NonInteractive

    if ($writeResult.Success) {
        Write-Success "DeepSeek API 配置完成！"
        $script:ConfigWritten = $true

        if ($SkipApiTest) {
            Write-Result "DeepSeek API 测试" "SKIP" "已按参数跳过"
            Write-Info "注意: 未验证 API 是否可用。"
            $script:ApiTestSkipped = $true
            return $true
        }

        # 验证 API 连接（使用 Anthropic Format）
        Write-Info "正在验证 DeepSeek API 连接（Anthropic Format）..."
        $apiTest = Test-DeepSeekApiAnthropic -ApiKey $apiKey

        if ($apiTest.Success) {
            Write-Success "DeepSeek API Anthropic Format smoke test 通过！"
            if ($apiTest.Content) {
                Write-Info "模型返回: $($apiTest.Content)"
            }
            $script:ApiTestPassed = $true
        }
        else {
            Write-Result "DeepSeek API 测试" "WARN" $apiTest.Error
            if ($apiTest.Suggestion) {
                Write-Warning $apiTest.Suggestion
            }
            $script:ApiTestFailed = $true
            $script:ApiTestFailReason = $apiTest.Error
        }

        # 配置已写入，即使 API 测试失败也返回 true（但最终摘要会区分状态）
        return $true
    }
    else {
        Write-Error-Msg "配置写入失败: $($writeResult.Error)"
        return $false
    }
}

# ============================================================
# 菜单
# ============================================================

function Show-Menu {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "                    请选择要执行的操作                        " -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  [1] 仅安装 Claude Code（不配置 DeepSeek）                   " -ForegroundColor White
    Write-Host "  [2] 安装 Claude Code 并配置 DeepSeek API（推荐）            " -ForegroundColor White
    Write-Host "  [3] 仅运行环境诊断（不安装任何东西）                        " -ForegroundColor White
    Write-Host "  [4] 仅配置 DeepSeek API（Claude Code 已安装的情况）         " -ForegroundColor White
    Write-Host "  [5] 退出                                                    " -ForegroundColor White
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""

    $choice = Read-Host "请输入选项编号 (1-5)"

    switch ($choice) {
        "1" {
            Write-Log "INFO" "用户选择: 仅安装 Claude Code"
            $claudeOk = Step-InstallClaudeCode
            if (-not $claudeOk) {
                Write-Warning "Claude Code 安装未成功，跳过后续步骤。"
                Write-Info "请先解决安装问题后重新运行本脚本。"
                Show-FinalSummary
                break
            }
            Step-InstallVSCodeExtension
            Show-FinalSummary
        }
        "2" {
            Write-Log "INFO" "用户选择: 安装 Claude Code 并配置 DeepSeek"
            $claudeOk = Step-InstallClaudeCode
            if (-not $claudeOk) {
                Write-Warning "Claude Code 安装未成功，跳过后续配置步骤。"
                Write-Info "请先解决安装问题后重新运行本脚本。"
                Show-FinalSummary
                break
            }
            Step-InstallVSCodeExtension
            Step-ConfigureDeepSeek
            Show-FinalSummary
        }
        "3" {
            Write-Log "INFO" "用户选择: 仅运行诊断"
            Write-Info "正在启动诊断脚本..."
            $doctorScript = Join-Path $ScriptDir "doctor.ps1"
            if (Test-Path $doctorScript) {
                & $doctorScript -SkipApiTest:$SkipApiTest
            }
            else {
                Write-Error-Msg "找不到 doctor.ps1，请确认文件完整。"
            }
        }
        "4" {
            Write-Log "INFO" "用户选择: 仅配置 DeepSeek"
            Step-ConfigureDeepSeek
            Show-FinalSummary
        }
        "5" {
            Write-Log "INFO" "用户选择: 退出"
            Write-Info "感谢使用！如有问题请运行 doctor.ps1 获取诊断报告。"
            exit 0
        }
        default {
            Write-Error-Msg "无效选项，请输入 1-5。"
            Show-Menu
        }
    }
}

# ============================================================
# 最终摘要
# ============================================================

function Show-FinalSummary {
    Write-Host ""

    # 根据状态显示真实结果
    if ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestPassed) {
        Write-Host "==============================================================" -ForegroundColor Green
        Write-Host "                     安装流程全部完成！                       " -ForegroundColor Green
        Write-Host "==============================================================" -ForegroundColor Green
    }
    elseif ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestSkipped) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "           安装完成（未验证 API 可用）                        " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
    }
    elseif ($script:ClaudeInstalled -and $script:ConfigWritten -and $script:ApiTestFailed) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "           安装部分完成（API 测试未通过）                      " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
    }
    elseif ($script:ClaudeInstalled) {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host "           安装部分完成                                      " -ForegroundColor Yellow
        Write-Host "==============================================================" -ForegroundColor Yellow
    }
    else {
        Write-Host "==============================================================" -ForegroundColor Red
        Write-Host "           安装未完成，请检查上述错误                          " -ForegroundColor Red
        Write-Host "==============================================================" -ForegroundColor Red
    }
    Write-Host ""

    # 显示当前状态
    $claudeVer = Test-ClaudeInstalled
    if ($claudeVer) {
        Write-Success "Claude Code: $claudeVer"
    }
    else {
        Write-Warning "Claude Code: 可能未成功安装，请重新打开终端后再试"
    }

    $configStatus = Get-DeepSeekConfigStatus
    if ($configStatus.IsConfigured) {
        Write-Success "DeepSeek 配置: 已配置 (Key: $($configStatus.MaskedKey))"
    }
    else {
        Write-Warning "DeepSeek 配置: $($configStatus.ErrorMessage)"
    }

    # API 测试状态
    if ($script:ApiTestPassed) {
        Write-Success "API 测试: 通过"
    }
    elseif ($script:ApiTestSkipped) {
        Write-Warning "API 测试: 已跳过（未验证 API 可用）"
    }
    elseif ($script:ApiTestFailed) {
        Write-Error-Msg "API 测试: 失败 - $($script:ApiTestFailReason)"
        Write-Info "配置已写入但 API 未通过验证。请确认:"
        Write-Info "  1. API Key 是否正确"
        Write-Info "  2. 账户余额是否充足"
        Write-Info "  3. 网络是否正常"
        Write-Info "  4. 运行 doctor.ps1 获取详细信息"
    }

    Write-Host ""
    Write-Info "下一步建议:"
    if ($script:ClaudeInstalled) {
        Write-Info "  1. 关闭并重新打开 PowerShell/VS Code 终端"
        Write-Info "  2. 运行 claude 启动 Claude Code"
    }
    Write-Info "  3. 如果遇到问题，运行 doctor.ps1 获取诊断报告"
    Write-Info "  4. 查看 docs/用户使用教程.md 了解更多"
    Write-Info "  5. 换 Key: configure-deepseek.ps1 | 恢复配置: uninstall-config.ps1"
    Write-Host ""
    Write-Info "日志已保存到: $(Get-LogFilePath)"
}

# ============================================================
# 主流程
# ============================================================

function Main {
    try {
        # 显示免责声明
        Show-Disclaimer

        if ($Mode -eq "Doctor") {
            $doctorScript = Join-Path $ScriptDir "doctor.ps1"
            if (Test-Path $doctorScript) {
                & $doctorScript -SkipApiTest:$SkipApiTest
                return
            }
            Write-Error-Msg "找不到 doctor.ps1，请确认文件完整。"
            exit 1
        }

        # 检测环境
        Step-CheckEnvironment

        switch ($Mode) {
            "InstallOnly" {
                $claudeOk = Step-InstallClaudeCode
                if ($claudeOk) { Step-InstallVSCodeExtension }
                Show-FinalSummary
                return
            }
            "InstallAndConfigure" {
                $claudeOk = Step-InstallClaudeCode
                if (-not $claudeOk) {
                    Write-Warning "Claude Code 安装未成功，跳过后续配置步骤。"
                    Show-FinalSummary
                    return
                }
                Step-InstallVSCodeExtension
                Step-ConfigureDeepSeek
                Show-FinalSummary
                return
            }
            "ConfigureOnly" {
                Step-ConfigureDeepSeek
                Show-FinalSummary
                return
            }
            "Menu" {
                # 继续显示菜单
            }
        }

        # 显示菜单
        Show-Menu
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
