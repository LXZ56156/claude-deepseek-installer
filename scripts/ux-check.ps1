# ============================================================
# scripts/ux-check.ps1 - 用户体验验证脚本
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ux-check.ps1
#
# 功能:
#   在 .sandbox 目录中隔离验证项目完整性，不污染真实用户配置。
#   全部通过 exit 0，任一失败 exit 1。
# ============================================================

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $PSScriptRoot
$SandboxDir = Join-Path $ScriptRoot ".sandbox"
$TotalPassed = 0
$TotalFailed = 0
$TestApiKey = "sk-test" + "1234567890abcdef" + "1234567890abcdef" + "1234567890ab"  # 假 Key

function Write-CheckHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
}

function Assert {
    param(
        [string]$TestName,
        [scriptblock]$Condition,
        [string]$FailMessage = ""
    )
    try {
        $result = & $Condition
        if ($result) {
            Write-Host "  [PASS] $TestName" -ForegroundColor Green
            $script:TotalPassed++
        }
        else {
            Write-Host "  [FAIL] $TestName - $FailMessage" -ForegroundColor Red
            $script:TotalFailed++
        }
    }
    catch {
        Write-Host "  [FAIL] $TestName - 异常: $($_.Exception.Message)" -ForegroundColor Red
        $script:TotalFailed++
    }
}

function Assert-Throws {
    param(
        [string]$TestName,
        [scriptblock]$ScriptBlock,
        [string]$FailMessage = ""
    )
    try {
        & $ScriptBlock | Out-Null
        Write-Host "  [FAIL] $TestName - 未抛出预期错误" -ForegroundColor Red
        $script:TotalFailed++
    }
    catch {
        Write-Host "  [PASS] $TestName" -ForegroundColor Green
        $script:TotalPassed++
    }
}

# 初始化沙盒
function Initialize-Sandbox {
    if (Test-Path $SandboxDir) {
        Remove-Item -Path $SandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $SandboxDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $SandboxDir "backup") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $SandboxDir "reports") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $SandboxDir "logs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $SandboxDir ".claude") -Force | Out-Null

    # 设置测试环境
    $env:CCDI_TEST_MODE = "1"
    $env:CCDI_TEST_USERPROFILE = $SandboxDir
    $env:CCDI_TEST_DESKTOP = $SandboxDir
    $env:CCDI_TEST_USERNAME = "TestUser"
}

# 清理沙盒
function Cleanup-Sandbox {
    Remove-Item -Path $SandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\CCDI_TEST_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\CCDI_TEST_USERPROFILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CCDI_TEST_DESKTOP -ErrorAction SilentlyContinue
    Remove-Item Env:\CCDI_TEST_USERNAME -ErrorAction SilentlyContinue
}

try {
    Initialize-Sandbox

    # ============================================================
    # 1. 入口文件存在性
    # ============================================================
    Write-CheckHeader "1. 入口文件存在性检查"

    $entryFiles = @(
        "开始安装.cmd",
        "一键诊断.cmd",
        "恢复或卸载配置.cmd",
        "Start-Install.cmd",
        "Run-Diagnostics.cmd",
        "Restore-Config.cmd",
        "Start-Here.ps1",
        "configure-deepseek.ps1",
        "doctor.ps1",
        "uninstall-config.ps1",
        "install_wsl.sh",
        "install.ps1",
        "lib/bootstrap.ps1",
        "lib/common.ps1",
        "lib/env-check.ps1",
        "lib/config-writer.ps1",
        "lib/logger.ps1",
        "lib/state.ps1",
        "lib/deepseek-env.defaults.json",
        "README.md",
        "QUICK_START.md",
        "LICENSE"
    )

    foreach ($file in $entryFiles) {
        $path = Join-Path $ScriptRoot $file
        Assert "文件存在: $file" { Test-Path $path } "文件缺失: $file"
    }

    # ============================================================
    # 2. README/QUICK_START 中提到的文件真实存在
    # ============================================================
    Write-CheckHeader "2. 文档中引用的文件存在性检查"

    $docFiles = @(
        "README.md",
        "QUICK_START.md"
    )
    foreach ($docFile in $docFiles) {
        $docPath = Join-Path $ScriptRoot $docFile
        if (Test-Path $docPath) {
            $content = Get-Content $docPath -Raw -Encoding UTF8
            # 查找引用的文件路径模式
            $refs = [regex]::Matches($content, '(?:`|["''])([^`"''\s]+\.(?:cmd|ps1|sh|md|json))(?:\b|["'']|\s)')
            foreach ($ref in $refs) {
                $refFile = $ref.Groups[1].Value.Trim()
                if ($refFile -match '^%') { continue }  # Skip env var references like %USERPROFILE%
                if ($refFile -match '\.(cmd|ps1|sh|md|json)$') {
                    # 如果有路径分隔符，检查文件
                    if ($refFile -match '[\\/]') {
                        $refPath = Join-Path $ScriptRoot $refFile
                    }
                    else {
                        $refPath = Join-Path $ScriptRoot $refFile
                    }
                    # 只检查看起来像文件引用的
                    if ($refFile -notmatch '^(http|https|www\.)') {
                        Assert "文档引用: $refFile" { Test-Path $refPath } "引用文件不存在: $refFile"
                    }
                }
            }
        }
    }

    # ============================================================
    # 3. .ps1 语法解析
    # ============================================================
    Write-CheckHeader "3. PowerShell 语法解析检查"

    $psFiles = Get-ChildItem -Path $ScriptRoot -Filter "*.ps1" -Recurse |
        Where-Object { $_.FullName -notmatch "\\(\.sandbox|\.git|logs|backup|release|reports|node_modules)\\" }

    foreach ($file in $psFiles) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        $shortName = $file.FullName.Substring($ScriptRoot.Length + 1)
        Assert "语法解析: $shortName" { $errors.Count -eq 0 } "解析错误: $($errors[0].Message)"
    }

    # ============================================================
    # 4. .cmd 对应 .ps1 存在
    # ============================================================
    Write-CheckHeader "4. .cmd 与 .ps1 对应关系检查"

    $cmdMappings = @{
        "开始安装.cmd"        = "Start-Here.ps1"
        "一键诊断.cmd"        = "doctor.ps1"
        "恢复或卸载配置.cmd"  = "uninstall-config.ps1"
        "Start-Install.cmd"   = "Start-Here.ps1"
        "Run-Diagnostics.cmd" = "doctor.ps1"
        "Restore-Config.cmd"  = "uninstall-config.ps1"
    }

    foreach ($cmdFile in $cmdMappings.Keys) {
        $cmdPath = Join-Path $ScriptRoot $cmdFile
        $ps1Path = Join-Path $ScriptRoot $cmdMappings[$cmdFile]
        Assert ".cmd 对应: $cmdFile -> $($cmdMappings[$cmdFile])" { (Test-Path $cmdPath) -and (Test-Path $ps1Path) } "对应关系断裂"
    }

    # ============================================================
    # 5. .gitignore 检查
    # ============================================================
    Write-CheckHeader "5. .gitignore 排除检查"

    $gitignorePath = Join-Path $ScriptRoot ".gitignore"
    $gitignoreContent = Get-Content $gitignorePath -Raw

    $requiredExcludes = @("logs/", "backup/", "reports/", "release/", "report*.txt")
    foreach ($exclude in $requiredExcludes) {
        Assert ".gitignore 排除: $exclude" { $gitignoreContent -match [regex]::Escape($exclude) } "缺少排除: $exclude"
    }

    # ============================================================
    # 6. Release 白名单文件存在
    # ============================================================
    Write-CheckHeader "6. Release 白名单文件存在性"

    # 读取 build-release.ps1 中的白名单
    $buildScript = Get-Content (Join-Path $ScriptRoot "scripts\build-release.ps1") -Raw
    $allowedBlock = [regex]::Match($buildScript, '\$AllowedEntries\s*=\s*@\((.*?)\)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($allowedBlock.Success) {
        $entries = [regex]::Matches($allowedBlock.Groups[1].Value, '"([^"]+)"')
        foreach ($entry in $entries) {
            $entryPath = $entry.Groups[1].Value
            $fullPath = Join-Path $ScriptRoot $entryPath
            # 跳过目录白名单
            if ($entryPath -notmatch '\.(cmd|ps1|sh|json|md|txt)$' -and $entryPath -notmatch '\.') {
                Assert "白名单目录: $entryPath" { Test-Path $fullPath } "目录缺失: $entryPath"
            }
            else {
                Assert "白名单文件: $entryPath" { Test-Path $fullPath } "文件缺失: $entryPath"
            }
        }
    }

    # ============================================================
    # 7. 仓库中无真实 API Key
    # ============================================================
    Write-CheckHeader "7. 仓库 API Key 扫描"

    $safePlaceholders = @(
        "sk-你的DeepSeekKey",
        "sk-xxxx",
        "__API_KEY__",
        "sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        ("sk-" + "1234567890abcdef" + "1234567890abcdef"),
        ("sk-test" + "1234567890abcdef" + "1234567890abcdef" + "1234567890ab"),
        ("sk-fake" + "1234567890abcdef" + "1234567890abcdef" + "1234567890ab"),
        ("sk-" + "1234567890abcdef" + "1234567890abcdef" + "1234567890ab")
    )

    $textFiles = Get-ChildItem -Path $ScriptRoot -Recurse -Include "*.ps1", "*.psm1", "*.sh", "*.json", "*.md", "*.txt", "*.cmd" |
        Where-Object { $_.FullName -notmatch "\\(\.sandbox|\.git|logs|backup|release|reports|node_modules)\\" }

    $realKeyFound = $false
    foreach ($file in $textFiles) {
        try {
            $content = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            $keyMatches = [regex]::Matches($content, 'sk-[A-Za-z0-9]{32,}')
            foreach ($m in $keyMatches) {
                $isSafe = $false
                foreach ($safe in $safePlaceholders) {
                    if ($m.Value -eq $safe) {
                        $isSafe = $true
                        break
                    }
                }
                if (-not $isSafe) {
                    $shortName = $file.FullName.Substring($ScriptRoot.Length + 1)
                    Write-Host "  [WARN] 疑似真实 Key: $shortName - $($m.Value.Substring(0, [Math]::Min(12, $m.Value.Length)))..." -ForegroundColor Yellow
                    $realKeyFound = $true
                }
            }
        }
        catch {}
    }

    Assert "无真实 API Key" { -not $realKeyFound } "仓库中可能存在真实 API Key"

    # ============================================================
    # 8. 配置写入不污染真实用户目录
    # ============================================================
    Write-CheckHeader "8. 配置写入隔离测试"

    # ---- 记录真实配置状态（测试前） ----
    $realUserProfile = [System.Environment]::GetFolderPath('UserProfile')
    $realSettingsPath = Join-Path $realUserProfile ".claude\settings.json"
    $realBeforeExists = Test-Path $realSettingsPath
    $realBeforeHash = if ($realBeforeExists) {
        (Get-FileHash $realSettingsPath -Algorithm SHA256).Hash
    }
    else {
        $null
    }

    # 加载库（CCDI_TEST_USERPROFILE 已设为沙盒，dot-source 不影响真实目录）
    . (Join-Path $ScriptRoot "lib\bootstrap.ps1")
    Initialize-CcdiScript -ScriptName "ux-check" | Out-Null

    # 记录到日志（此时 logger 已加载）
    Write-Log "DEBUG" "真实配置前状态: Exists=$realBeforeExists, Hash=$realBeforeHash"

    $testConfigPath = Join-Path $SandboxDir ".claude\settings.json"

    # 验证 CCDI_TEST_USERPROFILE 重定向生效
    $configDir = Get-ClaudeConfigDir
    Assert "CCDI_TEST_USERPROFILE 重定向生效" { $configDir -eq (Join-Path $SandboxDir ".claude") } "配置目录未重定向: $configDir"

    # 测试配置写入（写入沙盒，不写真实目录）
    $writeResult = Write-DeepSeekConfig -ApiKey $TestApiKey -ConfigPath $testConfigPath -NonInteractive
    Assert "配置写入成功" { $writeResult.Success } "写入失败: $($writeResult.Error)"

    # ---- 验证真实配置未被修改（测试后） ----
    $realAfterExists = Test-Path $realSettingsPath
    $realAfterHash = if ($realAfterExists) {
        (Get-FileHash $realSettingsPath -Algorithm SHA256).Hash
    }
    else {
        $null
    }
    Write-Log "DEBUG" "真实配置后状态: Exists=$realAfterExists, Hash=$realAfterHash"

    Assert "未污染真实 settings.json" {
        ($realBeforeExists -eq $realAfterExists) -and ($realBeforeHash -eq $realAfterHash)
    } "真实 settings.json 被修改或创建（前: Exists=$realBeforeExists Hash=$realBeforeHash, 后: Exists=$realAfterExists Hash=$realAfterHash）"

    # ============================================================
    # 9. 损坏 settings.json 备份重建
    # ============================================================
    Write-CheckHeader "9. 损坏 settings.json 备份重建测试"

    $corruptPath = Join-Path $SandboxDir ".claude\corrupt-settings.json"
    "{ this is not valid json !!!" | Set-Content $corruptPath -Encoding UTF8

    # 验证损坏 JSON 能正确识别
    $isValid = Test-JsonValid -FilePath $corruptPath
    Assert "损坏 JSON 识别" { -not $isValid } "损坏 JSON 未被识别"

    # 测试合并（损坏文件应触发备份后重建）
    $testEnv = @{
        ANTHROPIC_AUTH_TOKEN = $TestApiKey
        ANTHROPIC_BASE_URL   = "https://api.deepseek.com/anthropic"
    }
    $merged = Merge-SettingsJson -ExistingPath $corruptPath -NewEnv $testEnv
    Assert "损坏文件合并成功" { $null -ne $merged } "合并失败"
    Assert "合并后包含 API Key" { $merged.env.ANTHROPIC_AUTH_TOKEN -eq $TestApiKey } "合并内容不正确"

    # ============================================================
    # 10. 已有 settings.json 自定义字段不丢失
    # ============================================================
    Write-CheckHeader "10. 自定义字段保留测试"

    $customPath = Join-Path $SandboxDir ".claude\custom-settings.json"
    $customConfig = [PSCustomObject]@{
        permissions = [PSCustomObject]@{ allow = @("npm", "git") }
        hooks       = [PSCustomObject]@{ PostToolUse = @("echo done") }
        mcpServers  = [PSCustomObject]@{ testServer = [PSCustomObject]@{ command = "test" } }
        env         = [PSCustomObject]@{
            CUSTOM_VAR    = "keep-me"
            ANOTHER_VAR   = "also-keep"
            MY_SECRET     = "do-not-delete"
        }
    }
    Write-JsonFileSafe -FilePath $customPath -Data $customConfig | Out-Null

    # 写入 DeepSeek 配置
    $writeResult = Write-DeepSeekConfig -ApiKey $TestApiKey -ConfigPath $customPath -NonInteractive
    Assert "自定义配置写入成功" { $writeResult.Success } "写入失败"

    # 验证自定义字段保留
    $mergedConfig = Read-JsonFileSafe -FilePath $customPath
    Assert "permissions 保留" { $mergedConfig.permissions.allow -contains "npm" } "permissions 丢失"
    Assert "hooks 保留" { $mergedConfig.hooks.PostToolUse -contains "echo done" } "hooks 丢失"
    Assert "mcpServers 保留" { $mergedConfig.mcpServers.testServer.command -eq "test" } "mcpServers 丢失"
    Assert "自定义 env CUSTOM_VAR 保留" { $mergedConfig.env.CUSTOM_VAR -eq "keep-me" } "CUSTOM_VAR 丢失"
    Assert "自定义 env ANOTHER_VAR 保留" { $mergedConfig.env.ANOTHER_VAR -eq "also-keep" } "ANOTHER_VAR 丢失"
    Assert "DeepSeek env 已写入" { $mergedConfig.env.ANTHROPIC_AUTH_TOKEN -eq $TestApiKey } "DeepSeek 配置未写入"

    # ============================================================
    # 11. uninstall "仅移除 DeepSeek env" 不删自定义 env
    # ============================================================
    Write-CheckHeader "11. 仅移除 DeepSeek env 测试"

    # 模拟 uninstall 逻辑
    $managedFields = @(
        "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_EFFORT_LEVEL"
    )

    $config = Read-JsonFileSafe -FilePath $customPath
    $envHash = @{}
    $removedCount = 0
    if ($config.env -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $config.env.PSObject.Properties) {
            if ($prop.Name -in $managedFields) {
                $removedCount++
            }
            else {
                $envHash[$prop.Name] = $prop.Value
            }
        }
    }

    Assert "DeepSeek env 已移除" { $removedCount -gt 0 } "未移除任何 DeepSeek 字段"
    Assert "CUSTOM_VAR 未删除" { $envHash["CUSTOM_VAR"] -eq "keep-me" } "CUSTOM_VAR 误删"
    Assert "ANOTHER_VAR 未删除" { $envHash["ANOTHER_VAR"] -eq "also-keep" } "ANOTHER_VAR 误删"
    Assert "MY_SECRET 未删除" { $envHash["MY_SECRET"] -eq "do-not-delete" } "MY_SECRET 误删"

    # ============================================================
    # 12. 报告脱敏验证
    # ============================================================
    Write-CheckHeader "12. 报告脱敏验证"

    $fullReportText = @"
诊断报告
操作系统: Windows 11
用户目录: C:\Users\TestUser
ANTHROPIC_AUTH_TOKEN: $TestApiKey
CCDI_API_KEY: $TestApiKey
x-api-key: $TestApiKey
正常文本不包含敏感信息
"@

    $sanitized = Sanitize-ReportText -Text $fullReportText

    $fullTestKey = "sk-test" + "1234567890abcdef" + "1234567890abcdef" + "1234567890ab"
    Assert "分享版不含完整 API Key" { $sanitized -notmatch [regex]::Escape($fullTestKey) } "分享版包含完整 Key"
    Assert "分享版不含用户名" { $sanitized -notmatch 'C:\\Users\\TestUser' } "分享版包含真实用户名: $sanitized"
    Assert "分享版正常文本保留" { $sanitized -match '正常文本' } "分享版丢失正常文本"

    # 脱敏后包含占位符
    Assert "分享版路径已替换" { $sanitized -match '%USERPROFILE%' } "路径未替换为占位符"

    # ============================================================
    # 13. 状态文件读写
    # ============================================================
    Write-CheckHeader "13. 状态文件读写测试"

    $stateDir = Get-CcdiStateDir
    Assert "状态目录路径正确" { $stateDir -eq (Join-Path $SandboxDir ".claude-deepseek-installer") } "状态目录路径不正确"

    # 初始化状态
    $initialState = Initialize-CcdiState -ScriptVersion "1.3.1"
    Assert "状态初始化成功" { $null -ne $initialState } "初始化失败"
    Assert "版本正确" { $initialState.scriptVersion -eq "1.3.1" } "版本不正确"

    # 更新状态
    $updated = Update-CcdiState -Updates @{
        claudeInstallMethod = "native"
        claudeInstallStatus = "Installed"
        lastApiTest         = "passed"
    }
    Assert "状态更新成功" { $updated.claudeInstallMethod -eq "native" } "更新失败"
    Assert "lastApiTest 正确" { $updated.lastApiTest -eq "passed" } "lastApiTest 不正确"

    # 重新读取验证持久化
    $reRead = Read-CcdiState
    Assert "状态持久化" { $reRead.claudeInstallMethod -eq "native" } "持久化失败"
    Assert "持久化 lastApiTest" { $reRead.lastApiTest -eq "passed" } "持久化 lastApiTest 失败"

    # ============================================================
    # 14. Mask-ApiKey 脱敏
    # ============================================================
    Write-CheckHeader "14. Mask-ApiKey 脱敏"

    $maskTestKey = "sk-" + "1234567890abcdef" + "1234567890abcdef" + "1234567890ab"
    $masked = Mask-ApiKey -Key $maskTestKey
    Assert "脱敏不是原文" { $masked -ne $maskTestKey } "脱敏结果等于原文"
    Assert "脱敏包含掩码" { $masked -match '\*\*\*\*' } "脱敏没有掩码标记"
    Assert "脱敏保留前缀" { $masked.StartsWith("sk-1") } "脱敏丢失前缀"
    Assert "脱敏保留后缀" { $masked.EndsWith("90ab") } "脱敏丢失后缀"

    # ============================================================
    # 15. Sanitize-PathForReport 路径脱敏
    # ============================================================
    Write-CheckHeader "15. 路径脱敏"

    $pathText = "C:\Users\TestUser\.claude\settings.json and /home/TestUser/.claude/settings.json"
    $sanitizedPath = Sanitize-PathForReport -Text $pathText
    Assert "Windows 路径脱敏" { $sanitizedPath -notmatch 'C:\\Users\\TestUser' } "Windows 路径未脱敏"
    Assert "WSL 路径脱敏" { $sanitizedPath -notmatch '/home/TestUser' } "WSL 路径未脱敏"

    # ============================================================
    # 最终汇总
    # ============================================================
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "                      验证完成                                " -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  通过: $TotalPassed 项" -ForegroundColor Green
    Write-Host "  失败: $TotalFailed 项" -ForegroundColor $(if ($TotalFailed -gt 0) { "Red" } else { "Green" })
    Write-Host ""

    if ($TotalFailed -gt 0) {
        Write-Host "存在失败项，请修复后重新验证。" -ForegroundColor Red
    }

    Cleanup-Sandbox

    if ($TotalFailed -gt 0) {
        exit 1
    }
    else {
        Write-Host "全部通过！" -ForegroundColor Green
        exit 0
    }
}
catch {
    Write-Host ""
    Write-Host "[FATAL] 验证脚本自身异常: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Cleanup-Sandbox
    exit 1
}
