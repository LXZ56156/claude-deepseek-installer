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

# --- 编码初始化（防止 Windows PowerShell 5.1 控制台乱码）---
try {
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $null = & chcp 65001 2>$null
}
catch {
    # 编码设置失败不阻塞脚本执行
}

Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
$ScriptRoot = Split-Path -Parent $PSScriptRoot
$SandboxDir = Join-Path $ScriptRoot ".sandbox"
$TotalPassed = 0
$TotalFailed = 0
$TestApiKey = "sk-test" + ("x" * 42)  # 假 Key

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
        "00-点我开始安装.cmd",
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
        "lib/claude-install.ps1",
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
                if ($refFile -eq "install.sh") { continue }  # External Claude installer URL path fragment.
                if ($refFile -eq "settings.json") { continue }  # User config file, not a repo file.
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
        "00-点我开始安装.cmd"        = "Start-Here.ps1"
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
        ("sk-" + ("x" * 32)),
        ("sk-test" + ("x" * 42)),
        ("sk-fake" + ("x" * 42)),
        ("sk-" + ("x" * 46))
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

    $fullTestKey = "sk-test" + ("x" * 42)
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

    $maskTestKey = "sk-" + ("x" * 46)
    $masked = Mask-ApiKey -Key $maskTestKey
    Assert "脱敏不是原文" { $masked -ne $maskTestKey } "脱敏结果等于原文"
    Assert "脱敏包含掩码" { $masked -match '\*\*\*\*' } "脱敏没有掩码标记"
    Assert "脱敏保留前缀" { $masked.StartsWith("sk-x") } "脱敏丢失前缀"
    Assert "脱敏保留后缀" { $masked.EndsWith("xxxx") } "脱敏丢失后缀"

    # ============================================================
    # 15. Sanitize-PathForReport 路径脱敏
    # ============================================================
    Write-CheckHeader "15. 路径脱敏"

    $pathText = "C:\Users\TestUser\.claude\settings.json and /home/TestUser/.claude/settings.json"
    $sanitizedPath = Sanitize-PathForReport -Text $pathText
    Assert "Windows 路径脱敏" { $sanitizedPath -notmatch 'C:\\Users\\TestUser' } "Windows 路径未脱敏"
    Assert "WSL 路径脱敏" { $sanitizedPath -notmatch '/home/TestUser' } "WSL 路径未脱敏"

    # ============================================================
    # 16. install.ps1 兼容入口验证
    # ============================================================
    Write-CheckHeader "16. install.ps1 兼容入口验证"

    $installPs1Path = Join-Path $ScriptRoot "install.ps1"
    $installContent = Get-Content $installPs1Path -Raw -Encoding UTF8

    Assert "install.ps1 包含弃用提示" {
        ($installContent -match '旧入口') -or ($installContent -match '推荐入口是 Start-Here\.ps1')
    } "install.ps1 缺少弃用提示"

    Assert "install.ps1 转发到 Start-Here.ps1" {
        $installContent -match 'Start-Here\.ps1'
    } "install.ps1 未转发到 Start-Here.ps1"

    Assert "install.ps1 不包含 Show-Menu" {
        $installContent -notmatch 'function Show-Menu'
    } "install.ps1 包含旧 Show-Menu 函数"

    Assert "install.ps1 不包含 VS Code 扩展安装" {
        $installContent -notmatch 'Step-InstallVSCodeExtension' -and
        $installContent -notmatch 'code[\s\S]{0,100}--install-extension'
    } "install.ps1 包含旧 VS Code 扩展安装逻辑"

    Assert "install.ps1 不包含旧安装步骤函数" {
        $installContent -notmatch 'function Step-InstallClaudeCode' -and
        $installContent -notmatch 'function Step-ConfigureDeepSeek' -and
        $installContent -notmatch 'function Step-CheckEnvironment'
    } "install.ps1 包含旧独立安装步骤函数"

    Assert "install.ps1 是轻量转发入口" {
        ($installContent -split "`n").Count -le 120
    } "install.ps1 超过 120 行，不是轻量入口"

    Assert "install.ps1 不依赖 LASTEXITCODE" {
        $installContent -notmatch 'exit\s+\$LASTEXITCODE'
    } "install.ps1 使用不可靠的 exit `$LASTEXITCODE"

    Assert "install.ps1 包含安全转发函数" {
        $installContent -match 'function Invoke-CcdiScriptAndExit'
    } "install.ps1 缺少 Invoke-CcdiScriptAndExit 安全转发函数"

    Assert "install.ps1 Doctor 分支使用安全转发" {
        $installContent -match 'Invoke-CcdiScriptAndExit[\s\S]{0,50}\$doctorPath'
    } "install.ps1 Doctor 分支未使用安全转发函数"

    Assert "install.ps1 ConfigureOnly 分支使用安全转发" {
        $installContent -match 'Invoke-CcdiScriptAndExit[\s\S]{0,50}\$configPath'
    } "install.ps1 ConfigureOnly 分支未使用安全转发函数"

    Assert "install.ps1 Start-Here 分支使用安全转发" {
        $installContent -match 'Invoke-CcdiScriptAndExit[\s\S]{0,50}\$startHerePath'
    } "install.ps1 Start-Here 分支未使用安全转发函数"

    Assert "install.ps1 Doctor 模式文案准确" {
        $installContent -match '"Doctor"\s+\{\s*"正在切换到新版诊断入口'
    } "install.ps1 Doctor 模式使用了不准确的'一键安装流程'文案"

    Assert "install.ps1 ConfigureOnly 模式文案准确" {
        $installContent -match '"ConfigureOnly"\s+\{\s*"正在切换到 DeepSeek 单独配置入口'
    } "install.ps1 ConfigureOnly 模式使用了不准确的'一键安装流程'文案"

    # ============================================================
    # 17. UX 文案检查（v1.3.2 API Key 引导和等待提示）
    # ============================================================
    Write-CheckHeader "17. UX 文案检查"

    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $configurePath = Join-Path $ScriptRoot "configure-deepseek.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8
    $configureText = Get-Content $configurePath -Raw -Encoding UTF8

    # Step-GetApiKey 菜单文案必须存在
    $menuTexts = @(
        "我已复制 Key，开始粘贴",
        "重新打开 DeepSeek API Key 页面",
        "暂时跳过，稍后配置",
        "查看获取 Key 的简明步骤"
    )
    foreach ($mt in $menuTexts) {
        Assert "Step-GetApiKey 包含菜单文案: $mt" { $startHereText -match [regex]::Escape($mt) } "缺失菜单文案"
    }

    # Step-TestApi 等待提示
    Assert "Step-TestApi 包含『最长等待 30 秒』" { $startHereText -match [regex]::Escape("最长等待 30 秒") } "缺失等待提示"
    Assert "Step-TestApi 包含『配置仍会保留』" { $startHereText -match [regex]::Escape("配置仍会保留") } "缺失保留说明"

    # Start-LazyInstall Step 2 后有上下文文案
    Assert "Step 2 后有 Claude Code 安装验证已通过" { $startHereText -match "Claude Code 安装验证已通过" } "缺失安装成功文案"
    Assert "Step 2 后有下一步说明" { $startHereText -match "下一步将配置 DeepSeek API Key" } "缺失下一步说明"
    Assert "Step 2 后有已安装检测" { $startHereText -match "检测到 Claude Code 已安装，继续配置 DeepSeek" } "缺失已安装检测"

    # configure-deepseek.ps1 提示
    Assert "configure-deepseek.ps1 包含最长等待 30 秒" { $configureText -match [regex]::Escape("最长等待 30 秒") } "缺失等待提示"
    Assert "configure-deepseek.ps1 包含配置仍会保留" { $configureText -match [regex]::Escape("如果失败，配置仍会保留") } "缺失保留说明"
    Assert "configure-deepseek.ps1 包含安全提示" { $configureText -match "输入时不会显示字符，这是正常的安全保护" } "缺失安全提示"
    Assert "configure-deepseek.ps1 包含重新粘贴提示" { $configureText -match "下一步会显示脱敏后的 Key，可选择 R 重新粘贴" } "缺失重新粘贴提示"

    # SkipApiTest / TestSafe / NonInteractive 路径未受影响
    Assert "Step-GetApiKey NonInteractive 路径存在" {
        $startHereText -match 'if\s*\(\$NonInteractive\)\s*\{[\s\S]{0,300}Get-ApiKeyFromEnvironment'
    } "NonInteractive 路径缺失"
    Assert "Step-TestApi EffectiveSkipApiTest 存在" {
        $startHereText -match '\$script:EffectiveSkipApiTest'
    } "EffectiveSkipApiTest 缺失"

    # 取消输入不再显示错误文案
    Assert "Step-GetApiKey 不包含 API Key 不能为空错误" {
        $startHereText -notmatch [regex]::Escape('Write-Error-Msg "API Key 不能为空！"')
    } "取消路径仍显示错误文案"
    Assert "Step-GetApiKey 包含『已取消 API Key 输入』" {
        $startHereText -match "已取消 API Key 输入。"
    } "缺失取消输入提示"

    # 统一使用中文箭头 →
    Assert "Start-Here.ps1 使用中文箭头 →" {
        $startHereText -match [regex]::Escape('00-点我开始安装.cmd → 高级选项 → 仅配置 DeepSeek API')
    } "缺失中文箭头路径"
    Assert "Start-Here.ps1 不使用 ASCII ->" {
        $startHereText -notmatch '00-点我开始安装\.cmd\s*->\s*高级选项'
    } "仍使用 ASCII 箭头 ->"

    # Write-ApiKeySkipGuidance 函数
    Assert "Write-ApiKeySkipGuidance 函数存在" {
        $startHereText -match 'function Write-ApiKeySkipGuidance'
    } "缺失 Write-ApiKeySkipGuidance 函数"

    # Start-LazyInstall 跳过文案柔和化
    Assert "Start-LazyInstall 包含柔和跳过文案" {
        $startHereText -match "未配置 API Key，已跳过 DeepSeek 配置步骤"
    } "缺失柔和跳过文案"
    Assert "Start-LazyInstall 包含安装不受影响安抚" {
        $startHereText -match "Claude Code 安装状态不受影响"
    } "缺失安装不受影响安抚"

    # configure-deepseek.ps1 交互式取消
    Assert "configure-deepseek.ps1 包含已取消 API Key 输入" {
        $configureText -match "已取消 API Key 输入。"
    } "缺失取消提示"
    Assert "configure-deepseek.ps1 包含配置未更改" {
        $configureText -match "配置未更改。"
    } "缺失配置未更改"
    Assert "configure-deepseek.ps1 交互式取消 exit 0" {
        $configureText -match 'if\s*\(\$NonInteractive\)\s*\{[\s\S]{0,200}Write-Error-Msg[\s\S]{0,200}exit 1[\s\S]{0,300}exit 0'
    } "交互式取消未 exit 0 或 NonInteractive 未 exit 1"

    Write-Host ""

    # ============================================================
    # 18. UX 增强检查（v1.3.2 第三批）
    # ============================================================
    Write-CheckHeader "18. UX 增强检查（Confirm-UserChoice/EnvSnapshot/CompletionMenu/Privacy）"

    $commonPath = Join-Path $ScriptRoot "lib\common.ps1"
    $commonText = Get-Content $commonPath -Raw -Encoding UTF8
    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8
    $doctorPath = Join-Path $ScriptRoot "doctor.ps1"
    $doctorText = Get-Content $doctorPath -Raw -Encoding UTF8

    # Confirm-UserChoice Default 参数
    Assert "Confirm-UserChoice 支持 Default 参数" {
        $commonText -match '\[ValidateSet\("Yes",\s*"No",\s*"None"\)\]'
    } "Confirm-UserChoice 必须支持 Default 参数"

    Assert "Confirm-UserChoice 识别 yes/no/确认/取消/继续" {
        ($commonText -match '"是"' -and $commonText -match '"确认"' -and
         $commonText -match '"否"' -and $commonText -match '"取消"')
    } "Confirm-UserChoice 必须识别中文 yes/no 关键词"

    Assert "Confirm-UserChoice 无效输入重新提示" {
        $commonText -match '未识别输入，请输入 Y 或 N。'
    } "Confirm-UserChoice 必须对无效输入重新提示"

    # Step-CheckEnvironment 写入 EnvSnapshot
    Assert "Step-CheckEnvironment 写入 EnvSnapshot" {
        $startHereText -match '\$script:EnvSnapshot\s*=\s*@\{'
    } "Step-CheckEnvironment 必须写入 EnvSnapshot"

    # 状态变量区必须预初始化 EnvSnapshot
    Assert "状态变量区预初始化 EnvSnapshot = null" {
        $startHereText -match '\$script:EnvSnapshot\s*=\s*\$null'
    } "Start-Here.ps1 状态变量区必须预初始化 `$script:EnvSnapshot = `$null"

    # Step-GenerateReport 必须使用 Get-Variable 防御式读取
    Assert "Step-GenerateReport 使用 Get-Variable 防御式读取 EnvSnapshot" {
        $startHereText -match 'Get-Variable\s+-Name\s+EnvSnapshot\s+-Scope\s+Script\s+-ErrorAction\s+SilentlyContinue'
    } "Step-GenerateReport 必须使用 Get-Variable 读取 EnvSnapshot"

    Assert "Step-GenerateReport 不得无条件重复完整环境检测" {
        $startHereText -match 'if\s*\(\$snap\)' -and
        $startHereText -match 'EnvSnapshot 不存在时'
    } "Step-GenerateReport 必须有 EnvSnapshot fallback 逻辑"

    # Show-CompletionPage 快捷菜单
    $requiredMenuItems = @(
        "打开测试项目文件夹",
        "打开安装报告",
        "运行一键诊断",
        "退出"
    )
    foreach ($item in $requiredMenuItems) {
        Assert "Show-CompletionPage 包含快捷菜单: $item" {
            $startHereText -match [regex]::Escape($item)
        } "缺失快捷菜单项: $item"
    }
    Assert "Show-CompletionMenu 函数存在" {
        $startHereText -match 'function Show-CompletionMenu'
    } "Start-Here.ps1 必须定义 Show-CompletionMenu 函数"

    # Show-CompletionMenu 打开报告安全
    Assert "Show-CompletionMenu 不使用 $LASTEXITCODE 检查 notepad" {
        $startHereText -notmatch 'Show-CompletionMenu[\s\S]{0,800}\$LASTEXITCODE'
    } "Show-CompletionMenu 不得使用 `$LASTEXITCODE 检查 GUI 程序退出码"

    Assert "Show-CompletionMenu 使用 Start-Process 打开报告" {
        $startHereText -match 'Start-Process\s+-FilePath\s+"notepad\.exe"'
    } "Show-CompletionMenu 必须使用 Start-Process 打开 notepad"

    Assert "Show-CompletionMenu 有 Invoke-Item fallback" {
        $startHereText -match 'Invoke-Item\s+-Path\s+\$script:ReportPath'
    } "Show-CompletionMenu 必须有 Invoke-Item fallback"

    # Privacy: report 正文不出现 OAuth 列举
    Assert "doctor.ps1 隐私声明不列举 OAuth" {
        $doctorText -notmatch '报告中不包含 OAuth'
    } "隐私声明正文不应列举 OAuth 作为隐私声明项"

    Assert "doctor.ps1 隐私声明使用新通用措辞" {
        $doctorText -match '内部认证字段、完整路径或敏感标识'
    } "隐私声明应使用新通用措辞"

    # 允许脱敏逻辑内部扫描 OAuth
    Assert "脱敏逻辑仍可内部扫描 OAuth" {
        $commonText -match 'OAuth'
    } "Convert-ToSafeReportText 脱敏逻辑仍应内部过滤 OAuth"

    Write-Host ""

    # ============================================================
    # 19. 第四批 UX 优化检查（进度感/日志路径/WSL 收口/timeout）
    # ============================================================
    Write-CheckHeader "19. 第四批 UX 优化检查"

    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8
    $repairDepsPath = Join-Path $ScriptRoot "repair-deps.ps1"
    $repairDepsText = Get-Content $repairDepsPath -Raw -Encoding UTF8

    # Write-CheckProgress 函数存在
    Assert "Write-CheckProgress 函数存在" {
        $startHereText -match 'function Write-CheckProgress'
    } "Start-Here.ps1 缺失 Write-CheckProgress 函数"

    # 日志路径前置显示
    Assert "Start-Here.ps1 前置显示日志路径" {
        $startHereText -match '本次运行日志.*Get-LogFilePath'
    } "Start-Here.ps1 未前置显示日志路径"

    Assert "Start-Here.ps1 包含日志路径指引文案" {
        $startHereText -match '如果窗口异常关闭，可把此文件发给技术支持'
    } "Start-Here.ps1 缺失日志路径指引文案"

    # Step-CheckEnvironment 使用 Write-CheckProgress（至少 10 个进度调用）
    Assert "Step-CheckEnvironment 包含 Write-CheckProgress -Current 1" {
        $startHereText -match 'Write-CheckProgress\s+-Current\s+1\s+-Total\s+10'
    } "Step-CheckEnvironment 缺失第 1 项进度提示"

    Assert "Step-CheckEnvironment 包含 Write-CheckProgress -Current 10" {
        $startHereText -match 'Write-CheckProgress\s+-Current\s+10\s+-Total\s+10'
    } "Step-CheckEnvironment 缺失第 10 项进度提示"

    # WSL 方式 B 已移除
    Assert "Start-WslSetup 不再包含 Windows 端自动调用 WSL" {
        $startHereText -notmatch 'Start-WslSetup[\s\S]{0,3000}Invoke-CommandSafe\s+-Command\s+"wsl"'
    } "Start-WslSetup 仍包含 Invoke-CommandSafe wsl 调用"

    Assert "Start-WslSetup 不显示过期的方式 B" {
        $startHereText -notmatch '方式\s*B[\s\S]{0,50}实验性'
    } "Start-WslSetup 仍显示方式 B"

    Assert "Start-WslSetup 包含新版说明" {
        $startHereText -match '为避免 Windows 路径、权限、WSL 发行版差异导致失败'
    } "Start-WslSetup 缺失新版 WSL 说明文案"

    # repair-deps.ps1 npm prefix -g TimeoutSec 8
    Assert "repair-deps.ps1 npm prefix -g 有显式 TimeoutSec 8" {
        $repairDepsText -match 'Invoke-CommandSafe[\s\S]{0,500}"prefix"[\s\S]{0,200}\-g[\s\S]{0,30}\-TimeoutSec\s+8'
    } "repair-deps.ps1 npm prefix -g 未设置 TimeoutSec 8"

    Write-Host ""

    # ============================================================
    # 20. v1.3.2 最终补修 UX 检查（Timeout/后验/文案/配置状态）
    # ============================================================
    Write-CheckHeader "20. v1.3.2 最终补修 UX 检查"

    $claudeInstallPath = Join-Path $ScriptRoot "lib\claude-install.ps1"
    $claudeInstallText = Get-Content $claudeInstallPath -Raw -Encoding UTF8

    # 20a. 下载超时友好提示
    Assert "Invoke-VisibleFileDownload 提示超时而非长时间无响应" {
        $claudeInstallText -match '如果下载超时，将自动切换备用安装通道'
    } "下载超时提示文案未更新"

    # 20b. Native 失败后不再误导"直接切换npm"
    Assert "Native Install 失败不写'自动切换国内 npm 镜像安装'" {
        $claudeInstallText -notmatch 'Claude 官方安装通道执行失败，正在自动切换国内 npm 镜像安装'
    } "仍包含过时文案'自动切换国内 npm 镜像安装'"

    # 20c. 必须写"备用安装通道"或"备用安装方式"
    Assert "Native Install 失败使用'备用安装通道'措辞" {
        ($claudeInstallText -match '备用安装通道') -or ($claudeInstallText -match '备用安装方式')
    } "未出现'备用安装通道'措辞"

    # 20d. 必须提到 winget 在 npmmirror 之前
    Assert "fallback 说明 winget 优先于 npm" {
        $claudeInstallText -match 'winget.*npmmirror|winget.*npm 镜像'
    } "fallback 文案未体现 winget → npm 顺序"

    # 20e. 全失败时提到三个通道
    Assert "全部失败时提到 Native/winget/npm 三个通道" {
        $claudeInstallText -notmatch '官方 Native Install 和 npm 镜像安装均失败'
    } "仍写'官方 Native Install 和 npm 镜像安装均失败'，遗漏 winget"

    # 20f. 完成页配置状态检查
    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8

    Assert "完成页不再用 HasEnv 判断 API Key" {
        $startHereText -notmatch 'HasEnv[\s\S]{0,200}DeepSeek API Key 尚未配置'
    } "完成页仍用 HasEnv 判断 API Key 状态"

    Assert "完成页使用 Get-DeepSeekConfigStatus" {
        $startHereText -match 'Get-DeepSeekConfigStatus'
    } "完成页未调用 Get-DeepSeekConfigStatus"

    Assert "配置不完整提示更详细" {
        $startHereText -match '尚未配置或配置不完整'
    } "配置不完整时提示未区分具体原因"

    # 20g. 空 env 对象场景
    $configWriterPath = Join-Path $ScriptRoot "lib\config-writer.ps1"
    $configWriterText = Get-Content $configWriterPath -Raw -Encoding UTF8

    Assert "Get-DeepSeekConfigStatus 检测空 env" {
        $configWriterText -match 'env 字段为空对象|env 字段为空（null）'
    } "Get-DeepSeekConfigStatus 未检测空 env"

    Assert "Get-DeepSeekConfigStatus 检测缺失 API Key" {
        $configWriterText -match '未设置 API Key'
    } "Get-DeepSeekConfigStatus 未检测缺失 ANTHROPIC_AUTH_TOKEN"

    Write-Host ""

    # ============================================================
    # 21. v1.3.2 最终补漏 UX 检查（一键诊断编码策略）
    # ============================================================
    Write-CheckHeader "21. 一键诊断编码策略检查"

    $doctorPath = Join-Path $ScriptRoot "doctor.ps1"
    $doctorText = Get-Content $doctorPath -Raw -Encoding UTF8
    $doctorCmdPath = Join-Path $ScriptRoot "一键诊断.cmd"
    $doctorCmdText = Get-Content $doctorCmdPath -Raw -Encoding ASCII

    Assert "doctor.ps1 不直接 chcp 65001" {
        $doctorText -notmatch '(?m)^[^#\r\n]*chcp\s+65001'
    } "doctor.ps1 不得直接执行 chcp 65001，否则 PS5.1/cmd 下可能中文叠字"

    Assert "doctor.ps1 不直接设置 Console Encoding" {
        $doctorText -notmatch '\[Console\]::InputEncoding\s*=' -and
        $doctorText -notmatch '\[Console\]::OutputEncoding\s*='
    } "doctor.ps1 应通过 logger 的 Initialize-ConsoleEncodingSafe 统一处理编码"

    Assert "doctor.ps1 通过 bootstrap 初始化" {
        $doctorText -match 'lib\\bootstrap\.ps1|lib/bootstrap\.ps1'
    } "doctor.ps1 必须加载 bootstrap.ps1"

    Assert "doctor.ps1 调用 Initialize-CcdiScript" {
        $doctorText -match 'Initialize-CcdiScript\s+-ScriptName\s+"doctor"'
    } "doctor.ps1 必须调用 Initialize-CcdiScript -ScriptName doctor"

    Assert "一键诊断.cmd 不包含 chcp 65001" {
        $doctorCmdText -notmatch 'chcp\s+65001'
    } "一键诊断.cmd 不得设置 chcp 65001"

    Assert "一键诊断.cmd 调用 doctor.ps1 -ShareSafe" {
        $doctorCmdText -match 'doctor\.ps1' -and $doctorCmdText -match '-ShareSafe'
    } "一键诊断.cmd 必须调用 doctor.ps1 -ShareSafe"

    Write-Host ""

    # ============================================================
    # 22. 编码初始化单一入口检查
    # ============================================================
    Write-CheckHeader "22. 编码初始化单一入口检查"

    $bootstrapPath = Join-Path $ScriptRoot "lib\bootstrap.ps1"
    $bootstrapText = Get-Content $bootstrapPath -Raw -Encoding UTF8
    $loggerPath = Join-Path $ScriptRoot "lib\logger.ps1"
    $loggerText = Get-Content $loggerPath -Raw -Encoding UTF8

    Assert "Initialize-Logger 负责调用 Initialize-ConsoleEncodingSafe" {
        $loggerText -match 'function Initialize-Logger' -and
        $loggerText -match 'Initialize-ConsoleEncodingSafe'
    } "logger.ps1 的 Initialize-Logger 必须负责统一编码初始化"

    Assert "Initialize-CcdiScript 不重复调用 Initialize-ConsoleEncodingSafe" {
        $bootstrapText -notmatch 'Initialize-CcdiScript[\s\S]{0,500}Initialize-ConsoleEncodingSafe'
    } "bootstrap.ps1 不应重复调用 Initialize-ConsoleEncodingSafe，避免同一入口重复编码初始化"

    Assert "doctor.ps1 仍通过 Initialize-CcdiScript 初始化" {
        $doctorText -match 'Initialize-CcdiScript\s+-ScriptName\s+"doctor"'
    } "doctor.ps1 必须继续通过 Initialize-CcdiScript 初始化"

    Write-Host ""

    # ============================================================
    # 23. v1.3.3 第一批 UX 收尾修复检查
    # ============================================================
    Write-CheckHeader "23. v1.3.3 UX 收尾修复：Start/成功文案去重 + 文档同步"

    $claudeInstallPath = Join-Path $ScriptRoot "lib\claude-install.ps1"
    $nativeBlock = Get-Content $claudeInstallPath -Raw -Encoding UTF8

    # --- 23a: Invoke-InstallCommandCaptured 必须使用 PSBoundParameters ---
    $capturedBlock = if ($nativeBlock -match '(?s)(function Invoke-InstallCommandCaptured\s*\{.*?\r?\n\})') {
        $matches[1]
    } else { "" }
    Assert "Invoke-InstallCommandCaptured 使用 PSBoundParameters 判断 StartMessage" {
        $capturedBlock -match '\$PSBoundParameters\.ContainsKey\("StartMessage"\)'
    } "Invoke-InstallCommandCaptured 必须用 PSBoundParameters.ContainsKey 区分未传参数和传空字符串"
    Assert "Invoke-InstallCommandCaptured 使用 PSBoundParameters 判断 HeartbeatMessage" {
        $capturedBlock -match '\$PSBoundParameters\.ContainsKey\("HeartbeatMessage"\)'
    } "Invoke-InstallCommandCaptured 必须用 PSBoundParameters.ContainsKey 判断 HeartbeatMessage"
    Assert "Invoke-InstallCommandCaptured 使用 PSBoundParameters 判断 TimeoutMessage" {
        $capturedBlock -match '\$PSBoundParameters\.ContainsKey\("TimeoutMessage"\)'
    } "Invoke-InstallCommandCaptured 必须用 PSBoundParameters.ContainsKey 判断 TimeoutMessage"
    Assert "Invoke-InstallCommandCaptured 空 StartMessage 不输出" {
        $capturedBlock -match 'IsNullOrWhiteSpace\(\$StartMessage\)'
    } "Invoke-InstallCommandCaptured 必须用 IsNullOrWhiteSpace 检查 StartMessage，-StartMessage '' 必须静默"

    # --- 23b: Install-ClaudeCodeNative 中 Write-NativeInstallUserMessage -Phase "Start" 只出现一次 ---
    # 全文件搜索：该模式只应在 Install-ClaudeCodeNative 中出现恰好一次
    # （函数定义的 switch 中 "Start" 不带 Write-NativeInstallUserMessage 前缀，不会被匹配）
    $startCountAll = ([regex]::Matches($nativeBlock, 'Write-NativeInstallUserMessage\s+-Phase\s+"Start"')).Count
    Assert "Install-ClaudeCodeNative 中 Native Start 消息只输出一次" {
        $startCountAll -eq 1
    } "Write-NativeInstallUserMessage -Phase Start 应在 claude-install.ps1 中出现恰好 1 次，当前 $startCountAll 次"

    # --- 23c: Native Install 后验验证成功路径不可同时有 Write-Success 和 Write-NativeInstallUserMessage -Phase "Success" ---
    # 检查后验验证区域（$verifyResult.Usable 之后）不应再有 Write-Success "Claude Code 已安装:"
    # 注意：existing_native 路径（已安装跳过）允许保留 Write-Success "Claude Code 已安装: $($existingCheck.Version)"
    # 只检查 $verifyResult 上下文（Native Install 新安装后验验证路径）
    $postVerifyArea = if ($nativeBlock -match '(?s)\$verifyResult\.Usable.*?Write-NativeInstallUserMessage\s+-Phase\s+"Fallback"') {
        $matches[0]
    } else { "" }
    Assert "Native Install 后验验证成功不再重复 Write-Success 版本信息" {
        $postVerifyArea -notmatch 'Write-Success\s+"Claude Code 已安装:'
    } "后验验证成功路径($verifyResult.Usable 块)应将 Write-Success 改为 Write-Log，避免与 Success Phase 重复"
    Assert "Native Install fresh shell 成功不用 Write-Success 重复" {
        $nativeBlock -notmatch 'Write-Success\s+"新 PowerShell 可直接运行 claude:'
    } "Fresh shell 结果应写入日志而非重复成功结论"
    Assert "Write-NativeInstallUserMessage -Phase Success 作为唯一成功结论存在" {
        $nativeBlock -match 'Write-NativeInstallUserMessage\s+-Phase\s+"Success"'
    } "Native Install 成功路径必须保留 Write-NativeInstallUserMessage -Phase Success 作为唯一用户可见成功结论"

    # --- 23d: README 版本检查 ---
    $readmePath = Join-Path $ScriptRoot "README.md"
    $readmeText = Get-Content $readmePath -Raw -Encoding UTF8
    Assert "README.md 不包含 Version-1.3.2" {
        $readmeText -notmatch 'Version-1\.3\.2'
    } "README.md 主说明区不允许再出现 Version-1.3.2"
    Assert "README.md 包含 Version-1.3.3" {
        $readmeText -match 'Version-1\.3\.3'
    } "README.md 必须包含 Version-1.3.3"
    Assert "README.md 包含 v1.3.3 一键版" {
        $readmeText -match 'v1\.3\.3 一键版'
    } "README.md 标题必须包含 v1.3.3 一键版"
    Assert "README.md 网络与安装策略 v1.3.3" {
        $readmeText -match '网络与安装策略.*v1\.3\.3'
    } "README.md 网络与安装策略标题必须是 v1.3.3"

    # --- 23e: QUICK_START 版本检查 ---
    $qsPath = Join-Path $ScriptRoot "QUICK_START.md"
    $qsText = Get-Content $qsPath -Raw -Encoding UTF8
    Assert "QUICK_START.md 包含 v1.3.3" {
        $qsText -match '快速开始指南.*v1\.3\.3'
    } "QUICK_START.md 标题必须包含 v1.3.3"
    Assert "QUICK_START.md 不包含 v1.3.2" {
        $qsText -notmatch 'v1\.3\.2'
    } "QUICK_START.md 不允许再出现 v1.3.2"
    Assert "QUICK_START.md 网络与安装策略 v1.3.3" {
        $qsText -match '网络与安装策略.*v1\.3\.3'
    } "QUICK_START.md 网络与安装策略标题必须是 v1.3.3"

    # --- 23f: 文档新 CTA 检查 ---
    Assert "README.md 包含新完成页 CTA" {
        $readmeText -match '立即验证 Claude Code 是否能正常使用（推荐）'
    } "README.md 必须包含完成页 [1] CTA"
    Assert "QUICK_START.md 包含新完成页 CTA" {
        $qsText -match '立即验证 Claude Code 是否能正常使用（推荐）'
    } "QUICK_START.md 必须包含完成页 [1] CTA"
    Assert "README.md 包含右键终端提示" {
        $readmeText -match '在终端中打开'
    } "README.md 必须包含右键→在终端中打开的提示"
    Assert "QUICK_START.md 包含右键终端提示" {
        $qsText -match '在终端中打开'
    } "QUICK_START.md 必须包含右键→在终端中打开的提示"

    # --- 23g: 文档售后模板检查 ---
    Assert "README.md 包含统一售后安全提示" {
        $readmeText -match '只发送生成的 report\.txt' -and
        $readmeText -match '不要发送 backup.*logs.*reports/full-report' -and
        $readmeText -match '不要发送完整 API Key' -and
        $readmeText -match '如果截图，请先确认截图里没有完整 API Key'
    } "README.md 必须包含统一售后安全提示模板"
    Assert "QUICK_START.md 包含统一售后安全提示" {
        $qsText -match '只发送生成的 report\.txt' -and
        $qsText -match '不要发送 backup.*logs.*reports/full-report' -and
        $qsText -match '不要发送完整 API Key' -and
        $qsText -match '如果截图，请先确认截图里没有完整 API Key'
    } "QUICK_START.md 必须包含统一售后安全提示模板"

    # --- 23h: 后验验证口径检查 ---
    Assert "README.md 包含'后验验证为准'" {
        $readmeText -match '后验验证为准'
    } "README.md 必须包含后验验证为准的安装策略描述"
    Assert "README.md 包含 ExitCode 不直接决定成败" {
        $readmeText -match 'ExitCode 不直接决定成败|安装包 ExitCode'
    } "README.md 必须说明安装包 ExitCode 不直接决定成败"
    Assert "README.md 包含 fresh shell 验证" {
        $readmeText -match 'fresh shell'
    } "README.md 必须包含 fresh shell 验证描述"

    Write-Host ""

    # ============================================================
    # 24. P10 路径 UX 反回归：常见用户目录允许，ZIP 临时目录阻断
    # ============================================================
    Write-CheckHeader "24. 路径 UX 反回归：常见目录允许 + ZIP 临时阻断"

    $realDesktop = [Environment]::GetFolderPath("Desktop")
    $realUserProfile = [Environment]::GetFolderPath("UserProfile")

    # 24a: 桌面路径允许
    $desktopPath = Join-Path $realDesktop "ClaudeCode-DeepSeek-本地配置助手"
    $r = Test-UserPathRisk -PathToCheck $desktopPath
    Assert "桌面路径允许: IsBlocked=false" { $r.IsBlocked -eq $false } "桌面路径被阻断: $($r.RiskLevel)"
    Assert "桌面路径 RiskLevel=INFO" { $r.RiskLevel -eq "INFO" } "桌面路径 RiskLevel 异常: $($r.RiskLevel)"
    Assert "桌面路径 RiskItems 为空" { $r.RiskItems.Count -eq 0 } "桌面路径仍有风险项: $($r.RiskItems -join '; ')"

    # 24b: 下载目录允许
    $downloadsPath = Join-Path $realUserProfile "Downloads\ClaudeCode-DeepSeek"
    $r2 = Test-UserPathRisk -PathToCheck $downloadsPath
    Assert "下载目录允许: IsBlocked=false" { $r2.IsBlocked -eq $false } "下载目录被阻断"
    Assert "下载目录 RiskLevel=INFO" { $r2.RiskLevel -eq "INFO" } "下载目录 RiskLevel 异常: $($r2.RiskLevel)"

    # 24c: OneDrive 路径允许
    $oneDrivePath = Join-Path $realUserProfile "OneDrive\Desktop\ClaudeCode-DeepSeek"
    $r3 = Test-UserPathRisk -PathToCheck $oneDrivePath
    Assert "OneDrive 路径允许: IsBlocked=false" { $r3.IsBlocked -eq $false } "OneDrive 路径被阻断"
    Assert "OneDrive 路径 RiskLevel=INFO" { $r3.RiskLevel -eq "INFO" } "OneDrive 路径 RiskLevel 异常: $($r3.RiskLevel)"

    # 24d: 微信路径允许
    $wechatPath = Join-Path $realUserProfile "Documents\WeChat Files\FileStorage\File\ClaudeCode-DeepSeek"
    $r4 = Test-UserPathRisk -PathToCheck $wechatPath
    Assert "微信路径允许: IsBlocked=false" { $r4.IsBlocked -eq $false } "微信路径被阻断"
    Assert "微信路径 RiskLevel=INFO" { $r4.RiskLevel -eq "INFO" } "微信路径 RiskLevel 异常: $($r4.RiskLevel)"

    # 24e: QQ 路径允许
    $qqPath = Join-Path $realUserProfile "Documents\Tencent Files\123456\FileRecv\ClaudeCode-DeepSeek"
    $r5 = Test-UserPathRisk -PathToCheck $qqPath
    Assert "QQ 路径允许: IsBlocked=false" { $r5.IsBlocked -eq $false } "QQ 路径被阻断"
    Assert "QQ 路径 RiskLevel=INFO" { $r5.RiskLevel -eq "INFO" } "QQ 路径 RiskLevel 异常: $($r5.RiskLevel)"

    # 24f: 空格+括号路径允许
    $spaceParenPath = Join-Path $realDesktop "Claude Code (DeepSeek)"
    $r6 = Test-UserPathRisk -PathToCheck $spaceParenPath
    Assert "空格+括号路径允许: IsBlocked=false" { $r6.IsBlocked -eq $false } "空格+括号路径被阻断"
    Assert "空格+括号路径 RiskLevel=INFO" { $r6.RiskLevel -eq "INFO" } "空格+括号路径 RiskLevel 异常: $($r6.RiskLevel)"

    # 24g: ZIP 临时目录仍 BLOCK
    $zipTempPath = Join-Path $env:TEMP "Temp1_ClaudeCode.zip\ClaudeCode-DeepSeek"
    $r7 = Test-UserPathRisk -PathToCheck $zipTempPath
    Assert "ZIP 临时目录 BLOCK: IsBlocked=true" { $r7.IsBlocked -eq $true } "ZIP 临时目录未被阻断"
    Assert "ZIP 临时目录 RiskLevel=BLOCK" { $r7.RiskLevel -eq "BLOCK" } "ZIP 临时目录 RiskLevel 异常: $($r7.RiskLevel)"
    Assert "ZIP 临时目录包含全部解压提示" {
        ($r7.Suggestions -join ' ') -match '全部解压|不要在压缩包预览窗口中直接运行'
    } "ZIP 临时目录建议缺少解压提示: $($r7.Suggestions -join ' ')"

    # 24h: 7-Zip 临时目录仍 BLOCK
    $sevenZipTempPath = Join-Path $env:TEMP "7zABC123\ClaudeCode-DeepSeek"
    $r8 = Test-UserPathRisk -PathToCheck $sevenZipTempPath
    Assert "7-Zip 临时目录 BLOCK: IsBlocked=true" { $r8.IsBlocked -eq $true } "7-Zip 临时目录未被阻断"
    Assert "7-Zip 临时目录 RiskLevel=BLOCK" { $r8.RiskLevel -eq "BLOCK" } "7-Zip 临时目录 RiskLevel 异常: $($r8.RiskLevel)"

    # 24i: WinRAR 临时目录仍 BLOCK
    $rarTempPath = Join-Path $env:TEMP "Rar`$ABC123.456\ClaudeCode-DeepSeek"
    $r9 = Test-UserPathRisk -PathToCheck $rarTempPath
    Assert "WinRAR 临时目录 BLOCK: IsBlocked=true" { $r9.IsBlocked -eq $true } "WinRAR 临时目录未被阻断"
    Assert "WinRAR 临时目录 RiskLevel=BLOCK" { $r9.RiskLevel -eq "BLOCK" } "WinRAR 临时目录 RiskLevel 异常: $($r9.RiskLevel)"

    # 24j: 普通目录名含 compressed 不应阻断（仅 TEMP 下 compressed 才 BLOCK）
    $normalCompressedPath = "D:\compressed\ClaudeCode-DeepSeek"
    $r10 = Test-UserPathRisk -PathToCheck $normalCompressedPath
    Assert "普通 compressed 目录允许: IsBlocked=false" { $r10.IsBlocked -eq $false } "compressed 目录被误判为临时目录"
    Assert "普通 compressed 目录 RiskLevel=INFO" { $r10.RiskLevel -eq "INFO" } "compressed 目录 RiskLevel 异常: $($r10.RiskLevel)"

    # 24k: 文案反回归——用户文档不再包含旧误导文案（编号调整：原 24j→24k，插入 compressed 测试）
    $userDocsToCheck = @(
        (Join-Path $ScriptRoot "README.md"),
        (Join-Path $ScriptRoot "QUICK_START.md"),
        (Join-Path $ScriptRoot "docs\用户使用教程.md")
    )
    $forbiddenPhrases = @(
        "不要解压到桌面",
        "不要解压到下载目录",
        "不要解压到 OneDrive",
        "不要解压到微信/QQ",
        "风险自担",
        "路径包含空格，可能影响某些脚本执行",
        "路径在桌面目录中",
        "建议将项目文件夹移动到 D:\\ClaudeDeepSeek（或类似不含空格、特殊字符的路径）"
    )
    foreach ($docPath in $userDocsToCheck) {
        if (-not (Test-Path $docPath)) { continue }
        $docContent = Get-Content $docPath -Raw -Encoding UTF8
        foreach ($phrase in $forbiddenPhrases) {
            $docName = Split-Path -Leaf $docPath
            Assert "文档 $docName 不含: $phrase" {
                $docContent -notmatch [regex]::Escape($phrase)
            } "文档 $docName 仍然包含旧路径限制文案: $phrase"
        }
    }

    Write-Host ""

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
