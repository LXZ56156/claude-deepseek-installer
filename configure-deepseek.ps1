# ============================================================
# configure-deepseek.ps1 - DeepSeek API 配置脚本
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\configure-deepseek.ps1
#
# 功能:
#   独立配置 DeepSeek API Key 到 Claude Code
#   适用于已安装 Claude Code，只需要配置/更新 API Key 的场景
# ============================================================

param(
    [switch]$NonInteractive,
    [switch]$SkipApiTest
)

try {

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }
. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")
$ScriptDir = Initialize-CcdiScript -ScriptName "configure-deepseek"

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "           DeepSeek API 配置工具                              " -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

# 检查 Claude Code 是否已安装
$claudeVersion = Test-ClaudeInstalled
if (-not $claudeVersion) {
    Write-Warning "未检测到 Claude Code CLI。"
    Write-Info "您可以先配置 API Key，但 Claude Code 需要安装后才能使用。"
    if (-not $NonInteractive -and -not (Confirm-UserChoice -Message "是否继续配置？")) {
        Write-Info "已取消。请先运行 install.ps1 安装 Claude Code。"
        exit 0
    }
}
else {
    Write-Success "检测到 Claude Code: $claudeVersion"
}

# 显示当前配置状态
Write-Host ""
Write-Info "正在检查当前配置..."
$currentConfig = Get-DeepSeekConfigStatus

if ($currentConfig.IsConfigured) {
    Write-Info "当前已配置 DeepSeek API。"
    Write-Info "  Base URL: $($currentConfig.BaseUrl)"
    Write-Info "  API Key:  $($currentConfig.MaskedKey)"
    Write-Host ""

    if (-not $NonInteractive -and -not (Confirm-UserChoice -Message "是否更新现有配置？")) {
        Write-Info "保持现有配置不变。"
        exit 0
    }
}
else {
    if ($currentConfig.ErrorMessage) {
        Write-Info "当前配置状态: $($currentConfig.ErrorMessage)"
    }
}

# 获取 API Key
if ($NonInteractive) {
    $envKey = Get-ApiKeyFromEnvironment
    if (-not $envKey.Found) {
        Write-Error-Msg "$($envKey.Error)。非交互模式不会读取明文命令行参数。"
        exit 1
    }
    $apiKey = $envKey.Key
    Write-Info "已从环境变量 $($envKey.Source) 读取 API Key: $(Mask-ApiKey -Key $apiKey)"
}
else {
    Write-Host ""
    Write-Info "请输入您的 DeepSeek API Key。"
    Write-Info "获取地址: https://platform.deepseek.com → API Keys"
    Write-Warning "输入时字符不会显示（安全保护），请粘贴后按回车。"
    Write-Warning "如选择 API 测试，Key 会发送到 DeepSeek 官方接口验证，不会发送给第三方。"
    Write-Host ""

    $apiKey = Read-SecretInput -Prompt "API Key"
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Error-Msg "API Key 不能为空，已取消配置。"
    exit 1
}

# 检查格式
$validFormat = Is-ApiKeyFormatValid -Key $apiKey
if (-not $validFormat) {
    Write-Warning "API Key 格式不典型（通常以 sk- 开头）"
    if ($NonInteractive) {
        Write-Error-Msg "非交互模式下拒绝使用格式异常的 API Key。"
        exit 1
    }
    if (-not (Confirm-UserChoice -Message "是否继续使用此 Key？")) {
        Write-Info "已取消配置。"
        exit 0
    }
}

# 写入配置
Write-Host ""
Write-Info "正在保存配置..."

$writeResult = Write-DeepSeekConfig -ApiKey $apiKey -NonInteractive:$NonInteractive

if (-not $writeResult.Success) {
    Write-Error-Msg "配置失败: $($writeResult.Error)"
    Write-Info "请检查:"
    Write-Info "  1. 磁盘是否有足够空间"
    Write-Info "  2. 是否有对 %USERPROFILE%\.claude\ 目录的写入权限"
    exit 1
}

Write-Host ""
if ($SkipApiTest) {
    Write-Result "API 测试" "SKIP" "已按参数跳过"
}
else {
    # 测试 API 连接
    Write-Info "正在测试 DeepSeek API 连接（Anthropic Format）..."
    $apiTest = Test-DeepSeekApiAnthropic -ApiKey $apiKey

    Write-Host ""
    if ($apiTest.Success) {
        Write-Success "DeepSeek API Anthropic Format smoke test 通过！"
        if ($apiTest.Content) {
            Write-Info "模型返回: $($apiTest.Content)"
        }
    }
    else {
        Write-Result "API 测试" "WARN" $apiTest.Error
        if ($apiTest.Suggestion) {
            Write-Warning $apiTest.Suggestion
        }
    }
}

Write-Host ""
# 根据 Claude Code 安装状态和 API 测试结果给出针对性提示
if (-not $claudeVersion) {
    Write-Warning "配置已写入，但请先安装 Claude Code 才能使用。"
    Write-Info "运行 install.ps1 安装 Claude Code CLI 后即可启动。"
}
elseif ($SkipApiTest) {
    Write-Success "配置已写入！但未验证 API 是否可用。"
    Write-Info "建议运行 doctor.ps1 诊断 API 连接状态。"
}
elseif ($apiTest.Success) {
    Write-Success "配置完成！您现在可以运行 'claude' 开始使用。"
}
else {
    Write-Warning "配置已写入，但 API 测试未通过。"
    Write-Info "常见原因:"
    Write-Info "  1. API Key 不正确（401）→ 请重新获取 Key"
    Write-Info "  2. 余额不足（402）→ 请充值后重试"
    Write-Info "  3. 网络问题 → 请检查是否能访问 api.deepseek.com"
    Write-Info "  4. 如需诊断，请运行 doctor.ps1"
}

Write-Host ""
Write-Info "日志文件: $(Get-LogFilePath)"
Write-Info "如需恢复旧配置，请运行: uninstall-config.ps1"
}
catch {
    $msg = "脚本执行过程中发生未预期的错误：$($_.Exception.Message)"

    if (Get-Command Write-Error-Msg -ErrorAction SilentlyContinue) {
        Write-Error-Msg $msg
    }
    else {
        Write-Host "[ERROR] $msg" -ForegroundColor Red
    }

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log "ERROR" $_
    }

    exit 1
}
